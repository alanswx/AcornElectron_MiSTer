
module cassette(

  input clk,
  input rewind,
  input en,

  input [23:0] stp,
  
  output reg [24:0] sdram_addr,
  input [7:0] sdram_data,
  output reg sdram_rd,

  output data,
  output [2:0] status

);


wire [7:0] r_sdram_data;
assign r_sdram_data[0] = sdram_data[7];
assign r_sdram_data[1] = sdram_data[6];
assign r_sdram_data[2] = sdram_data[5];
assign r_sdram_data[3] = sdram_data[4];
assign r_sdram_data[4] = sdram_data[3];
assign r_sdram_data[5] = sdram_data[2];
assign r_sdram_data[6] = sdram_data[1];
assign r_sdram_data[7] = sdram_data[0];



assign status = state;

reg old_en;
reg ffrewind;

reg [23:0] seq;
reg [7:0] ibyte;
reg [2:0] state;
reg sq_start;
reg [1:0] eof;
reg name;
wire done;
reg [18:0] hold;

parameter
  IDLE      = 3'h0,
  NEXT      = 3'h2,
  READ1     = 3'h3,
  READ2     = 3'h4,
  READ3     = 3'h5,
  READ4     = 3'h6,
  WAIT      = 3'h7;


always @(posedge clk) begin

    old_en <= en;
    if (old_en ^ en) begin
      state <= state == IDLE ? WAIT : IDLE;
      hold <= 19'd001;
      seq <= 24'd0;
    end

    ffrewind <= rewind;

    case (state)
    WAIT: begin
      ibyte <= 8'd0;
      hold <= hold - 19'd1;
      state <= hold == 0 ? NEXT : WAIT;
    end
    NEXT: begin
      state <= READ1;
      sdram_rd <= 1'b0;
      //if (seq == 24'h553c00) name <= 1'd1;
      //if (seq == 24'h555555 && name) begin
      //  name <= 1'd0;
      //  state <= WAIT;
      //  hold <= 19'd445000; // 0.5s
      //  sdram_addr <= sdram_addr - 25'd3;
      //end
      //if (seq == 24'h000000) eof <= 2'd1;
      //if (seq == 24'h000000 && eof == 2'd1) eof <= 2'd2;
      if (~en) state <= IDLE;
    end
    READ1: begin
      sdram_rd <= 1'b1;
      state <= READ2;
    end
    READ2: begin
      ibyte <= r_sdram_data;
      sdram_rd <= 1'b0;
      state <= READ3;
      sq_start <= 1'b1;
    end
    READ3: begin
      sq_start <= 1'b0;
      state <= done ? READ4 : READ3;
    end
    READ4: begin
      seq <= { seq[15:0], sdram_data };
      sdram_addr <= sdram_addr + 25'd1;
      state <= eof == 2'd2 ? IDLE : NEXT;
    end
    endcase

    if (ffrewind ^ rewind) begin
      seq <= 24'd0;
      sdram_addr <= 25'd0;
      state <= IDLE;
      eof <= 2'd0;
    end

end
/*
square_gen2 sq(
  .clk(clk),
  .start(sq_start),
  .din(ibyte),
  .done(done),
  .freq_encoded_bit(data),
);
*/
square_gen sq(
  .clk(clk),
  .start(sq_start),
  .din(ibyte),
  .done(done),
  .dout (data),
);


endmodule
module square_gen2(
  input clk,
  input start,
  input [7:0] din,
  output reg done,
  output reg freq_encoded_bit
);




reg [12:0]freq_cnt;
reg [2:0]cur_bit;
reg divider=1'b0;
reg en = 1'b0;

always @(posedge clk or posedge start)
begin
   if (start)
		freq_cnt<='d6666;
	else
	begin
		if (divider)
		begin
			freq_cnt<=freq_cnt-'d1;
		
			if (freq_cnt=='d0) 
				freq_cnt<='d6666;
		end
  	divider<=~divider;
	end
end


// with help from Gary Preston's https://github.com/Sector14/acorn-electron-core - virtual_cassette_fi
//-- Copyright 2017 Gary Preston <gary@mups.co.uk>

 // -- 1/8MHz = 125ns. 1/1200Hz = 833.333us
 // -- 833.33us/125ns = 6666 cycles
 // -- 1200Hz with 50% duty cycle = 3333 cycles high.

//  -- Frequency encode current bit and output to o_cas
always @(posedge clk or posedge start)
begin
	if (start)
	begin
		freq_encoded_bit<=1'b0;
		cur_bit<='d0;
		en<=1'b1;
		done<=1'b0;
	end 
	else if (divider && en)
	begin
		freq_encoded_bit<=1'b0;
		
		if (freq_cnt == 1'b1)
			// increment the curbit
			cur_bit<=cur_bit+1'd1;
			

       //   -- Pulse generation cnt 0..6666: 2400Hz = 0, 2x1200Hz = 1
        if ((din[7-cur_bit] == 1'b1 && freq_cnt > 'd1666 && freq_cnt < 'd3333) ||
              (din[7-cur_bit] ==  1'b1 && freq_cnt > 'd4999) ||
              (din[7-cur_bit] ==  1'b0 && freq_cnt > 'd3333) )
            freq_encoded_bit <= 1'b1;
        else
            freq_encoded_bit <= 1'b0;
          

        if (cur_bit == 'd7 )
		  begin
			done<=1'b1;
			en<=1'b0;
		  end
		
	end
end	
	

endmodule