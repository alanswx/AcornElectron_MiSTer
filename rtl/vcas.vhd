--
-- Copyright 2017 Gary Preston <gary@mups.co.uk>
-- All rights reserved
--
-- Redistribution and use in source and synthesized forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- Redistributions in synthesized form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- Neither the name of the author nor the names of other contributors may
-- be used to endorse or promote products derived from this software without
-- specific prior written permission.
--
-- License is granted for non-commercial use only.  A fee may not be charged
-- for redistributions as source code or in synthesized/hardware form without
-- specific prior written permission.
--
-- THIS CODE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
--
-- You are responsible for any legal issues arising from your use of this code.
--

-- Interface the frequency based ULA cassette i/o pins with SD Card based
-- files using Generic FileIO.
--
-- File IO only handles 0 or 1 states where as tape has pulses of 0's,
-- 1's and gaps with level 0. Gaps will end up generating
-- pulses of 0's with the current setup. Although this should hopefully
-- not cause too big a problem as the first gap/run of 0's will cause the
-- stop bit check to fail and a return to looking for a high tone.
-- There will be a single byte that generates a RX full interrupt however.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

  use work.Replay_Pack.all;
  use work.Replay_CoreIO_Pack.all;

entity Virtual_Cassette is
  port (
    -- Clocks (Assumes 32MHz sys with 1:4 enable)
    i_clk                : in bit1;
    i_ena                : in bit1;
    i_rst                : in bit1;

    -- Tape Controls
    i_motor              : in bit1;
    i_play               : in bit1;
    i_rec                : in bit1;
    i_ffwd               : in bit1;
    i_rwnd               : in bit1;

    -- Pulse based cassette i/o (0 = 1200Hz and 1 = 2400Hz)
    i_cas_to_fch         : in bit1;
    o_cas_fm_fch         : out bit1;

    -- When true, requests switch of o_cas_fm_fch from pulse to avail/taken protocol
    i_cas_turbo          : in boolean;
    i_cas_taken          : in boolean;

    o_cas_turbo          : out boolean;
    o_cas_avail          : out boolean;

    o_debug              : out word(15 downto 0)
  );
end;

architecture RTL of Virtual_Cassette is

  -- tape
  signal cas_to_fch_t1           : bit1;
  signal cas_to_fch_negedge     : boolean;
  signal bit_taken_r            : boolean;

  signal ula_to_fileio          : bit1;
  signal freq_encoded_bit       : bit1;

  -- Doubtful anyone will want a 500MB tape but why not :)
  signal tape_position          : unsigned(31 downto 0);  -- in bits
  signal freq_cnt               : integer range 6666 downto 0;

  -- current 16 bit data buffer for read / write of tape position
  signal cur_data               : word(7 downto 0);
  signal cur_data_r_valid       : boolean;

  signal cas_turbo_latch        : boolean;

  
   type t_fileio_req_state is (S_IDLE, S_W_IDLE, S_R_IDLE, S_W_WAIT, S_R_WAIT, S_HALT);
  signal fileio_req_state       : t_fileio_req_state;
 
  
begin
  -- TODO: [Gary] Adapt uef2raw to emit a small header to start of virtual tape.
  --       tape read/write should skip this. On eject, write to this location
  --       the current tape position. On insert, read it and set tape_position
  --       accordingly.

  o_debug(15 downto 0) <= (others => '0');

  p_turbo_latch : process(i_clk, i_rst, i_cas_turbo)
  begin
    if (i_rst = '1') then
      cas_turbo_latch <= i_cas_turbo;
    elsif rising_edge(i_clk) then
      if (i_ena = '1') then
        -- Leaving turbo mode is restricted to when motor is not active due to
        -- tricky timing issues. Entering via freq_cnt = 0 is safe during playback.
        if i_motor = '0' or freq_cnt = 0 then
          cas_turbo_latch <= i_cas_turbo;
        end if;
      end if;
    end if;
  end process;

  o_cas_turbo <= cas_turbo_latch;

  -- 1/8MHz = 125ns. 1/1200Hz = 833.333us
  -- 833.33us/125ns = 6666 cycles
  -- 1200Hz with 50% duty cycle = 3333 cycles high.
  p_freq_cnt : process(i_clk, i_rst, cas_turbo_latch)
  begin
    if (i_rst = '1' or cas_turbo_latch) then
      freq_cnt <= 6666;
    elsif rising_edge(i_clk) then
      if (i_ena = '1') then

        if i_fch_to_core.inserted(0) = '0' or i_play = '0' or i_motor = '0' or not cur_data_r_valid then
          freq_cnt <= 6666;
        else
          freq_cnt <= freq_cnt - 1;

          if freq_cnt = 0 then
            freq_cnt <= 6666;
          end if;
        end if;

      end if;
    end if;
  end process;

  -- Frequency encode current bit and output to o_cas
  p_read_encode : process(i_clk, i_ena, i_rst, cas_turbo_latch)
    variable cur_bit : integer range 7 downto 0;
  begin
    if (i_rst = '1' or cas_turbo_latch) then
      bit_taken_r <= false;
      freq_encoded_bit <= '0';
    elsif rising_edge(i_clk) then
      if (i_ena = '1') then

        freq_encoded_bit <= '0';
        bit_taken_r <= false;

        -- Read active
        if i_fch_to_core.inserted(0) = '1' and i_play = '1' and i_motor = '1' and i_rec = '0' and cur_data_r_valid then
          cur_bit := to_integer(unsigned(tape_position(2 downto 0)));

          -- Take on 1 as p_tape_readwrite will not react to taken flag until next tick and
          -- new data will then appear one tick after that e.g in sync with freq_cnt wrap to 6666
          if (freq_cnt = 1) then
            bit_taken_r <= true;
          end if;

          -- Pulse generation cnt 0..6666: 2400Hz = 0, 2x1200Hz = 1
          if (cur_data(7-cur_bit) = '1' and freq_cnt > 1666 and freq_cnt < 3333) or
              (cur_data(7-cur_bit) = '1' and freq_cnt > 4999) or
              (cur_data(7-cur_bit) = '0' and freq_cnt > 3333) then
            freq_encoded_bit <= '1';
          else
            freq_encoded_bit <= '0';
          end if;
        end if;

      end if;
    end if;
  end process;

  -- Frequency encoding (authentic mode)
  -- Direct bit transfer (turbo mode)
  -- Constant 0 when inactive in authentic mode due to no edges. Turbo mode relies
  -- on receiver checking avail as a 0 here would otherwise be taken as a full 0 bit
  -- due to lack of pulse encoding in turbo mode. The 0 here is purely to match authentic
  -- mode for LED usage by the core, as long as avail is checked last bit could be sent forever.
  o_cas_fm_fch <= freq_encoded_bit when not cas_turbo_latch else
                  '0' when (i_fch_to_core.inserted(0) = '0' or i_play = '0' or i_motor = '0') and i_rec = '0' else
                  cur_data(15 - to_integer(unsigned(tape_position(3 downto 0))));



  cas_to_fch_negedge <= true when (not i_cas_to_fch and cas_to_fch_t1) = '1' else false;

  -- Authentic Mode:
  --   Tape is one way sync'd with read/write process and one way
  --   sync'd to FileIO request process. Whilst FIFO empty can cause a stall
  --   ULA will not yield resulting in data corruption. Transfer is slow enough
  --   and buffer large enough this should never occur.
  -- Turbo Mode (read only):
  --   Tape is read as fast as ULA requests and may safely stall if FIFO
  --   queue runs out.
  --
  p_tape_readwrite : process(i_clk, i_rst, i_ena)
    variable cur_bit : integer range 7 downto 0;
  begin
    if (i_rst = '1') then
      tape_position <= (others => '0');
      cur_data <= (others => '0');
      o_cas_avail <= false;
    elsif rising_edge(i_clk) then
      if (i_ena = '1') then
        o_cas_avail <= false;

        if (i_fch_to_core.inserted(0) = '0') then
          tape_position <= (others => '0');
          cur_data <= (others => '0');
        else

          cur_bit := to_integer(unsigned(tape_position(2 downto 0)));

          if cas_turbo_latch and i_play = '1' and i_motor = '1' and i_rec = '0' then
              o_cas_avail <= true;
          end if;

          -- Reading
          if i_rec = '0' and (bit_taken_r or i_cas_taken) then

            if cur_bit = 7  then

                -- spi transfers in big endian and uef2raw writes big endian
                cur_data <= fileio_data(7 downto 0);

              end if;
            end if;


          if ( bit_taken_r or i_cas_taken) then
            tape_position <= tape_position + 1;
          end if;

          -- TODO: [Gary] Handle ffwd/rwnd. Will need to cause fileio read and write address changes.
        end if;

      end if;
    end if;
  end process;



end RTL;