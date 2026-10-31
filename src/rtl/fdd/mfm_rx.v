`timescale 1ns / 1ns
`default_nettype wire

/*
 mfm_rx.v

 The read side of a physical floppy drive: a digital PLL on the read data and an MFM decoder.
 - The PLL counts the clocks of a cell (cell_clks: 50 / 83 / 100 at 50 MHz for 500 / 300 / 250 kbit/s);
   a flux pulse marks the cell as 1 and pulls the count half way to the middle of the cell.
 - The cells go into a 16-bit shift register; the sync word 4489h (A1 with a missing clock)
   aligns the bytes: sync is one clock at its end, then stb / data every 16 cells (the data bits
   are the odd cells).
 rd is the read data synchronised to clk, high = a flux pulse.
*/

module mfm_rx (
	input wire clk,
	input wire en,
	input wire [6:0] cell_clks,
	input wire rd,

	output reg sync = 1'b0,
	output reg stb = 1'b0,
	output reg [7:0] data = 8'd0
);

reg rd_q = 1'b0;
reg [6:0] ph = 7'd0;
reg seen = 1'b0;
reg [15:0] raw = 16'd0;
reg [3:0] cnt = 4'd0;

wire edge_rd = rd & ~rd_q;
wire bit_end = (ph >= cell_clks - 7'd1);
wire [7:0] ph_mid = {1'b0, ph} + {2'b00, cell_clks[6:1]};  // pulled half way to the middle
wire [15:0] raw_n = {raw[14:0], seen | edge_rd};

always @(posedge clk) begin
	rd_q <= rd;
	sync <= 1'b0;
	stb <= 1'b0;
	if (!en) begin
		ph <= 7'd0;
		seen <= 1'b0;
		cnt <= 4'd0;
	end
	else if (bit_end) begin
		ph <= 7'd0;
		seen <= 1'b0;
		raw <= raw_n;
		if (raw_n == 16'h4489) begin
			sync <= 1'b1;
			cnt <= 4'd0;
		end
		else begin
			cnt <= cnt + 4'd1;
			if (cnt == 4'd15) begin
				stb <= 1'b1;
				data <= {raw_n[14], raw_n[12], raw_n[10], raw_n[8], raw_n[6], raw_n[4], raw_n[2], raw_n[0]};
			end
		end
	end
	else if (edge_rd) begin
		seen <= 1'b1;
		ph <= ph_mid[7:1];
	end
	else
		ph <= ph + 7'd1;
end

endmodule
