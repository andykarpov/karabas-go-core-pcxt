`timescale 1ns / 1ps
`default_nettype none

// The HDMI frame buffer (rtl/fb/pcxt_fb.v + fb_sdram.v) with a model of the SDRAM (CAS latency 2,
// tAC 6 ns, tOH 3 ns, 2 ns of traces each way): a CGA raster of 1820 x 262 clocks with the pattern
// ((pixel + line) & 15) in; the output must be 910 x 525 clocks in every line and frame and show the
// pattern of the window (H_START, V_START, 720 x 240, each line twice) once frames are complete.
// Frame 3 of the source loses the hsync of a line and frame 4 is short (200 lines): the raster of the
// output must not change, and the picture must be right again two output frames later.

module tb_fb;

reg clk_vga = 1'b0, clk_50 = 1'b0;
always #17.5 clk_vga = ~clk_vga;     // 28.571 MHz
always #10 clk_50 = ~clk_50;

reg reset = 1'b1;
initial #1000 reset = 1'b0;

localparam H_START = 152, V_START = 18;

// the source
reg [10:0] gh = 11'd0;
reg [9:0] gl = 10'd0;
reg [3:0] frame_no = 4'd0;
wire [9:0] lines = (frame_no == 4'd4) ? 10'd200 : 10'd262;
wire skip_hs = (frame_no == 4'd3) && (gl == 10'd100);
wire hs_i = (gh < 11'd160) && !skip_hs;
wire vs_i = (gl < 10'd3);
wire [3:0] video = ((gh >> 1) + gl) & 4'hF;
always @(posedge clk_vga) begin
	if (gh == 11'd1819) begin
		gh <= 11'd0;
		if (gl == lines - 1'd1) begin
			gl <= 10'd0;
			frame_no <= frame_no + 1'd1;
		end else
			gl <= gl + 1'd1;
	end else
		gh <= gh + 1'd1;
end

wire [17:0] rgb;
wire hs, vs, de, ovl_hs, ovl_vs;
wire sdr_clk, sdr_ras_n, sdr_cas_n, sdr_we_n;
wire [12:0] sdr_a;
wire [1:0] sdr_ba, sdr_dqm;
wire [15:0] sdr_dq;

pcxt_fb #(.H_START(H_START), .V_START(V_START)) dut(
	.clk_vga(clk_vga), .clk_50(clk_50), .reset(reset),
	.video(video), .hs_i(hs_i), .vs_i(vs_i),
	.rgb(rgb), .hs(hs), .vs(vs), .de(de), .ovl_hs(ovl_hs), .ovl_vs(ovl_vs),
	.sdr_clk(sdr_clk), .sdr_a(sdr_a), .sdr_ba(sdr_ba), .sdr_dq(sdr_dq), .sdr_dqm(sdr_dqm),
	.sdr_ras_n(sdr_ras_n), .sdr_cas_n(sdr_cas_n), .sdr_we_n(sdr_we_n)
);

// the SDRAM: bank 0, rows of 512 words
reg [15:0] mem [0:(1<<19)-1];
reg [12:0] row = 13'd0;
reg [15:0] dq_drv = 16'd0;
reg dq_en = 1'b0;
assign #2 sdr_dq = dq_en ? dq_drv : 16'bz;
wire #2 clk_d = sdr_clk;
wire [2:0] c;
assign #2 c = {sdr_ras_n, sdr_cas_n, sdr_we_n};
wire [12:0] a_d;
assign #2 a_d = sdr_a;
wire [15:0] dq_in = sdr_dq;
reg [8:0] rd_col1 = 9'd0;
reg rd1 = 1'b0;
integer errors = 0, rds = 0, wrs = 0;
always @(posedge clk_d) begin
	// a READ of the edge before: its data from tAC after this edge to tOH after the next one
	if (rd1) begin
		dq_drv <= #6 mem[{row[9:0], rd_col1}];
		dq_en <= #6 1'b1;
	end else
		dq_en <= #3 1'b0;
	rd1 <= 1'b0;
	case (c)
		3'b011: row <= a_d;                              // ACTIVE
		3'b100: begin mem[{row[9:0], a_d[8:0]}] <= dq_in; wrs = wrs + 1; end  // WRITE
		3'b101: begin rd1 <= 1'b1; rd_col1 <= a_d[8:0]; rds = rds + 1; end  // READ
		default: ;
	endcase
end

// the palette of cga_vgaport
function [17:0] pal(input [3:0] i);
	case (i)
		4'h0: pal = 18'b000000_000000_000000; 4'h1: pal = 18'b000000_000000_101010;
		4'h2: pal = 18'b000000_101010_000000; 4'h3: pal = 18'b000000_101010_101010;
		4'h4: pal = 18'b101010_000000_000000; 4'h5: pal = 18'b101010_000000_101010;
		4'h6: pal = 18'b101010_010101_000000; 4'h7: pal = 18'b101010_101010_101010;
		4'h8: pal = 18'b010101_010101_010101; 4'h9: pal = 18'b010101_010101_111111;
		4'hA: pal = 18'b010101_111111_010101; 4'hB: pal = 18'b010101_111111_111111;
		4'hC: pal = 18'b111111_010101_010101; 4'hD: pal = 18'b111111_010101_111111;
		4'hE: pal = 18'b111111_111111_010101; default: pal = 18'b111111_111111_111111;
	endcase
endfunction

// the output: the raster and the picture (the capture sees the rising hsync a clock late, so its
// pixel p is the source pixel p + 1 here)
integer x = 0, y = 0, hcnt = 0, vcnt = 0, oframe = 0, bad = 0, frame_bad = 0, checked = 0;
reg hs_d = 1'b1, vs_d = 1'b1, de_d = 1'b0;
reg check_on = 1'b0;
always @(posedge clk_vga) begin
	hs_d <= hs;
	vs_d <= vs;
	de_d <= de;
	hcnt = hcnt + 1;
	if (!hs && hs_d) begin
		if (oframe > 0 && hcnt != 910) begin
			$display("ERROR: output line of %0d clocks", hcnt);
			errors = errors + 1;
		end
		hcnt = 0;
		vcnt = vcnt + 1;
	end
	if (!vs && vs_d) begin
		if (oframe > 1 && vcnt != 525) begin
			$display("ERROR: output frame of %0d lines", vcnt);
			errors = errors + 1;
		end
		if (check_on) begin
			checked = checked + 1;
			if (frame_bad != 0) bad = bad + 1;
			$display("output frame %0d: %0d wrong pixels (source frame %0d)", oframe, frame_bad, frame_no);
		end
		vcnt = 0;
		oframe = oframe + 1;
		frame_bad = 0;
		y = 0;
	end
	if (de) begin
		if (rgb !== pal(((H_START + 1 + x) + (V_START + y / 2)) & 15)) begin
			if (check_on && frame_bad < 4 && $test$plusargs("dbg"))
				$display("  x %0d y %0d: %h, expected %h (index %0d)", x, y, rgb,
					pal(((H_START + 1 + x) + (V_START + y / 2)) & 15), ((H_START + 1 + x) + (V_START + y / 2)) & 15);
			frame_bad = frame_bad + 1;
		end
		x = x + 1;
	end
	if (!de && de_d) begin
		if (x != 720) begin $display("ERROR: %0d active pixels", x); errors = errors + 1; end
		x = 0;
		y = y + 1;
	end
end

initial begin
	// frames 0, 1 of the source fill the buffer; check the output frames shown from source frame 2 on
	wait (frame_no == 4'd2);
	check_on = 1'b1;
	wait (frame_no == (($test$plusargs("dbg")) ? 4'd4 : 4'd8));
	check_on = 1'b0;
	$display("%0d output frames checked, %0d with wrong pixels; SDRAM %0d writes, %0d reads", checked, bad, wrs, rds);
	// the frames of source frames 3 and 4 (no hsync in a line, a short frame) may show them;
	// all others must be right
	if (bad > 3) begin
		$display("ERROR: too many wrong frames");
		errors = errors + 1;
	end
	if (checked < 5) begin
		$display("ERROR: too few frames");
		errors = errors + 1;
	end
	$display("tb_fb: %0d errors", errors);
	$finish;
end

endmodule
