`timescale 1ns / 1ns
`default_nettype wire

/*
 mfm_tx.v

 The write side of a physical floppy drive: an MFM encoder.
 - en high: the byte in data / kind is taken at once (ld, one clock), then the next one after
   each 16 cells (ld again); the source changes data / kind on ld. ld while the source has no
   more bytes: the last one is written, en can go down.
 - kind 0: a data byte (clock bit = neither this nor the last data bit), 1: the sync A1 with a
   missing clock (4489h), 2: the index sync C2 (5224h).
 - pulse: a quarter cell high at each 1 cell (the write data at the pin, high = active).
*/

module mfm_tx (
	input wire clk,
	input wire en,
	input wire [6:0] cell_clks,
	input wire [7:0] data,
	input wire [1:0] kind,

	output reg ld = 1'b0,
	output reg pulse = 1'b0
);

reg run = 1'b0;
reg [6:0] ph = 7'd0;
reg [3:0] cnt = 4'd0;
reg [15:0] word = 16'd0;
reg last = 1'b0;            // the last data bit written

// MFM of a data byte after the data bit p
function [15:0] mfm;
	input [7:0] d;
	input p;
	integer i;
	reg q;
	begin
		q = p;
		for (i = 7; i >= 0; i = i - 1) begin
			mfm[2*i+1] = ~(q | d[i]);
			mfm[2*i] = d[i];
			q = d[i];
		end
	end
endfunction

wire [15:0] word_n = (kind == 2'd1) ? 16'h4489 : (kind == 2'd2) ? 16'h5224 : mfm(data, last);

always @(posedge clk) begin
	ld <= 1'b0;
	if (!en) begin
		run <= 1'b0;
		pulse <= 1'b0;
		last <= 1'b0;
	end
	else if (!run || (ph == cell_clks - 7'd1 && cnt == 4'd15)) begin
		// the next word
		run <= 1'b1;
		ld <= 1'b1;
		word <= word_n;
		last <= word_n[0];
		ph <= 7'd0;
		cnt <= 4'd0;
		pulse <= word_n[15];
	end
	else if (ph == cell_clks - 7'd1) begin
		ph <= 7'd0;
		cnt <= cnt + 4'd1;
		word <= {word[14:0], 1'b0};
		pulse <= word[14];
	end
	else begin
		ph <= ph + 7'd1;
		if (ph == {2'b00, cell_clks[6:2]})
			pulse <= 1'b0;
	end
end

endmodule
