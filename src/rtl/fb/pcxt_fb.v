`timescale 1ns / 1ps
`default_nettype none
/*
 pcxt_fb.v
 The HDMI frame buffer of Mini / Mini G: the CGA picture (15 kHz, before the scandoubler) into the
 SDRAM, out again with a fixed raster, so that programs that change the CRTC timing on the fly
 (Area 5150) no longer change the HDMI timing.
 - Capture (clk_vga, 28.571 MHz; a CGA pixel is 2 clocks): a window of W x H pixels (720 x 240: the
   640 x 200 picture and its border) at H_START pixels after the rising hsync and V_START lines after
   the rising vsync of the CRTC. A line without hsync ends after LINE_MAX clocks, a frame without vsync
   after FRAME_MAX lines. 4 bits (IRGB) per pixel, 4 pixels per word (pixel 0 in bits 3:0): a line
   is 180 words in a capture buffer of two lines, then a request to the SDRAM side (a toggle).
 - SDRAM (clk_50, fb_sdram.v): a line per row, row = {frame, line}, three frames: the line 0 of a
   new frame ends the frame before (done) and moves the writer to the frame that is neither done nor
   being shown. The output takes done at its frame start: whole frames only, no tearing; a frame of
   the PC is repeated or dropped when the rates differ.
 - Output (clk_vga): 910 x 525 clocks, 720 x 480 active (hsync low at 736..799, vsync low at lines
   489..494: about 59.8 Hz), each captured line twice; the line s + 1 is read into the other half of
   the output buffer while the line s shows (the first one in the last line of the frame).
   The palette of cga_vgaport. Black until a frame is complete.
 - ovl_hs / ovl_vs: syncs for kg_osd_overlay (H_OFFSET 48 / V_OFFSET 18 of the direct VGA path):
   rising 96 clocks before the OSD centred on 720 (at 104) and 36 lines before it centred on 480.
*/
module pcxt_fb #(
	parameter H_START = 10'd152,      // pixels from the rising hsync to the window
	parameter V_START = 9'd18,        // lines from the rising vsync to the window
	parameter LINE_MAX = 12'd2000,    // clocks (a line is 1820)
	parameter FRAME_MAX = 10'd330     // lines (a frame is 262)
) (
	input wire clk_vga,
	input wire clk_50,
	input wire reset,                 // in clk_50

	// the CGA picture before the scandoubler (clk_vga)
	input wire [3:0] video,
	input wire hs_i,                  // the CRTC HSYNC, high active
	input wire vs_i,                  // the CRTC VSYNC, high active

	// the fixed raster (clk_vga)
	output wire [17:0] rgb,
	output reg hs = 1'b1,
	output reg vs = 1'b1,
	output reg de = 1'b0,
	output reg ovl_hs = 1'b0,
	output reg ovl_vs = 1'b0,

	// SDRAM
	output wire sdr_clk,
	output wire [12:0] sdr_a,
	output wire [1:0] sdr_ba,
	inout wire [15:0] sdr_dq,
	output wire [1:0] sdr_dqm,
	output wire sdr_ras_n,
	output wire sdr_cas_n,
	output wire sdr_we_n
);

localparam W = 10'd720;
localparam H = 9'd240;

//---------- Capture (clk_vga) ----------

reg hs_d = 1'b0, vs_d = 1'b0;
reg [11:0] hclk = 12'd0;              // clocks since the line began
reg [9:0] vline = 10'd0;              // lines since the frame began
reg cbuf = 1'b0;
reg [15:0] cword = 16'd0;
reg cap_tgl = 1'b0;
reg [7:0] cap_line = 8'd0;
reg cap_buf = 1'b0;
reg cb_we = 1'b0;
reg [8:0] cb_waddr = 9'd0;
reg [15:0] cb_wdata = 16'd0;

wire line_start = (hs_i && !hs_d) || (hclk == LINE_MAX);
wire frame_start = (vs_i && !vs_d) || (vline == FRAME_MAX);
wire [10:0] px = hclk[11:1];
wire [10:0] p = px - {1'b0, H_START};
wire [9:0] l = vline - {1'b0, V_START};
wire in_win = (px >= {1'b0, H_START}) && (p < {1'b0, W}) && (vline >= {1'b0, V_START}) && (l < {1'b0, H});

always @(posedge clk_vga) begin
	hs_d <= hs_i;
	vs_d <= vs_i;
	cb_we <= 1'b0;
	if (line_start) begin
		hclk <= 12'd0;
		vline <= frame_start ? 10'd0 : vline + 1'd1;
	end else begin
		hclk <= hclk + 1'd1;
		if (frame_start) vline <= 10'd0;
	end
	// a pixel in the second clock of the two
	if (hclk[0] && in_win) begin
		cword <= {video, cword[15:4]};
		if (p[1:0] == 2'd3) begin
			cb_we <= 1'b1;
			cb_waddr <= {cbuf, p[9:2]};
			cb_wdata <= {video, cword[15:4]};
		end
		if (p == W - 1'd1) begin
			cap_line <= l[7:0];
			cap_buf <= cbuf;
			cap_tgl <= ~cap_tgl;
			cbuf <= ~cbuf;
		end
	end
end

//---------- SDRAM side (clk_50) ----------

wire [8:0] cb_raddr;
wire [15:0] cb_rdata;
kg_sdpram #(.DW(16), .AW(9)) u_cbuf(
	.clka(clk_vga), .wea(cb_we), .addra(cb_waddr), .dina(cb_wdata),
	.clkb(clk_50), .enb(1'b1), .addrb(cb_raddr), .doutb(cb_rdata)
);

reg [2:0] cap_s = 3'd0, out_s = 3'd0;
reg out_tgl = 1'b0;
reg [7:0] out_line = 8'd0;
reg out_fs = 1'b0;
always @(posedge clk_50) begin
	cap_s <= {cap_s[1:0], cap_tgl};
	out_s <= {out_s[1:0], out_tgl};
end
wire cap_ev = cap_s[2] != cap_s[1];
wire out_ev = out_s[2] != out_s[1];

// the frames: wf written, df the last complete one, rf shown; three different ones but at the start
reg [1:0] wf = 2'd0, df = 2'd1, rf = 2'd2;
reg valid = 1'b0;
reg wr_req = 1'b0, rd_req = 1'b0;
reg [12:0] wr_row = 13'd0, rd_row = 13'd0;
reg wr_buf = 1'b0, rd_buf = 1'b0;

function [1:0] other(input [1:0] a, input [1:0] b);   // the frame that is neither a nor b
	other = (a != 2'd0 && b != 2'd0) ? 2'd0 : (a != 2'd1 && b != 2'd1) ? 2'd1 : 2'd2;
endfunction

// a frame start of the output takes df; a new frame of the capture (its line 0) completes wf and
// moves to the frame that is neither the new df nor the frame shown from now on (both may come in
// the same clock: the output still takes the old df then)
wire out_new = out_ev && out_fs;
wire cap_new = cap_ev && (cap_line == 8'd0);
wire [1:0] rf_n = out_new ? df : rf;
wire [1:0] wf_n = cap_new ? other(wf, rf_n) : wf;

always @(posedge clk_50) begin
	wr_req <= 1'b0;
	rd_req <= 1'b0;
	rf <= rf_n;
	wf <= wf_n;
	if (cap_new) begin
		df <= wf;
		valid <= 1'b1;
	end
	if (cap_ev) begin
		wr_req <= 1'b1;
		wr_buf <= cap_buf;
		wr_row <= {3'b000, wf_n, cap_line};
	end
	if (out_ev) begin
		rd_req <= 1'b1;
		rd_buf <= out_line[0];
		rd_row <= {3'b000, rf_n, out_line};
	end
	if (reset) valid <= 1'b0;
end

wire lb_we;
wire [8:0] lb_addr;
wire [15:0] lb_data;
fb_sdram u_sdram(
	.clk(clk_50),
	.reset(reset),
	.wr_req(wr_req), .wr_row(wr_row), .wr_buf(wr_buf),
	.cb_addr(cb_raddr), .cb_data(cb_rdata),
	.rd_req(rd_req), .rd_row(rd_row), .rd_buf(rd_buf),
	.lb_we(lb_we), .lb_addr(lb_addr), .lb_data(lb_data),
	.ready(),
	.sdr_a(sdr_a), .sdr_ba(sdr_ba), .sdr_dq(sdr_dq), .sdr_dqm(sdr_dqm),
	.sdr_ras_n(sdr_ras_n), .sdr_cas_n(sdr_cas_n), .sdr_we_n(sdr_we_n)
);

// SDR_CLK: clk_50 at 180 degrees
ODDR2 u_sdr_clk(.Q(sdr_clk), .C0(clk_50), .C1(~clk_50), .CE(1'b1), .D0(1'b0), .D1(1'b1),
	.R(1'b0), .S(1'b0));

//---------- Output (clk_vga) ----------

reg [9:0] h = 10'd0;
reg [9:0] v = 10'd0;
wire [7:0] s = v[8:1];                // the captured line of output line v

always @(posedge clk_vga) begin
	if (h == 10'd909) begin
		h <= 10'd0;
		v <= (v == 10'd524) ? 10'd0 : v + 1'd1;
	end else
		h <= h + 1'd1;
	// the line reads: s + 1 at the start of the first of the two lines of s, line 0 in the last
	// line of the frame
	if (h == 10'd0) begin
		if (v == 10'd524) begin
			out_line <= 8'd0;
			out_fs <= 1'b1;
			out_tgl <= ~out_tgl;
		end else if (v < 10'd478 && !v[0]) begin
			out_line <= s + 1'd1;
			out_fs <= 1'b0;
			out_tgl <= ~out_tgl;
		end
	end
end

wire [15:0] ob_rdata;
kg_sdpram #(.DW(16), .AW(9)) u_obuf(
	.clka(clk_50), .wea(lb_we), .addra(lb_addr), .dina(lb_data),
	.clkb(clk_vga), .enb(1'b1), .addrb({s[0], h[9:2]}), .doutb(ob_rdata)
);

wire valid_v;
kg_sync #(.W(1)) u_sync_valid(.clk(clk_vga), .d(valid), .q(valid_v));

// the pipeline: h / v (clock 0) -> the buffer word (1) -> the palette (2)
reg [1:0] nib_d = 2'd0;
reg de1 = 1'b0, hs1 = 1'b1, vs1 = 1'b1;
reg [9:0] h1 = 10'd0, v1 = 10'd0;
reg de2 = 1'b0, hs2 = 1'b1, vs2 = 1'b1;
reg [9:0] h2 = 10'd0, v2 = 10'd0;
reg [3:0] pix = 4'd0;
wire [5:0] pr, pg, pb;
cga_vgaport u_palette(.clk(clk_vga), .video(pix), .red(pr), .green(pg), .blue(pb));

always @(posedge clk_vga) begin
	nib_d <= h[1:0];
	de1 <= (h < 10'd720) && (v < 10'd480);
	hs1 <= !(h >= 10'd736 && h < 10'd800);
	vs1 <= !(v >= 10'd489 && v < 10'd495);
	h1 <= h;
	v1 <= v;
	// clock 1: the word is there; the pixel to the palette
	case (nib_d)
		2'd0: pix <= ob_rdata[3:0];
		2'd1: pix <= ob_rdata[7:4];
		2'd2: pix <= ob_rdata[11:8];
		default: pix <= ob_rdata[15:12];
	endcase
	if (!de1 || !valid_v) pix <= 4'd0;
	de2 <= de1;
	hs2 <= hs1;
	vs2 <= vs1;
	h2 <= h1;
	v2 <= v1;
	// clock 2: the colour
	de <= de2;
	hs <= hs2;
	vs <= vs2;
	ovl_hs <= (h2 >= 10'd8);
	ovl_vs <= (v2 >= 10'd521);
end

assign rgb = {pr, pg, pb};

endmodule
