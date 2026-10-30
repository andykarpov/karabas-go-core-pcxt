`timescale 1ns / 1ps
`default_nettype none

module zhdmi_top(

	input wire clk,

	input wire reset,
	
	input wire [23:0] vga_rgb,
	input wire vga_hs,
	input wire vga_vs,
	input wire vga_de,
	
	input wire audio_en,
	input wire [15:0] audio_l,
	input wire [15:0] audio_r,
	
	output wire [3:0] tmds_p,
	output wire [3:0] tmds_n	
);

parameter SAMPLERATE = 32000;
parameter CLKRATE = 28571429; // karabas: pcxt clk_vga

// clocks
wire clk_hdmi, clk_hdmi_n;
wire p_clk_int, p_clk_div2;
wire [7:0] hdmi_freq;
wire lockedx5;
wire pll_reset;
hdmi_pll hdmi_pll (
	.clk(clk),
	.reset(reset),
	.clk_hdmi(clk_hdmi),
	.clk_hdmi_n(clk_hdmi_n),
	.clk_pix(p_clk_int),
	.clk_pix2(p_clk_div2),
	.locked(lockedx5),
	.o_reset(pll_reset)
);

// audio: a sample strobe every CLKRATE / SAMPLERATE clocks on average (audio_samplerate gave fs / 2,
// karabas-go-modules docs/PLAN.md), the mix of clk_cpu taken into the pixel clock when it is the
// same on two clocks
reg [24:0] audio_acc = 25'd0;
reg audio_clk = 1'b0;
reg [15:0] audio_l1, audio_l2, audio_ls_l, audio_r1, audio_r2, audio_ls_r;
reg signed [23:0] hdmi_audio_l, hdmi_audio_r;
always @(posedge p_clk_int) begin
	audio_l1 <= audio_l;
	audio_l2 <= audio_l1;
	if (audio_l1 == audio_l2) audio_ls_l <= audio_l2;
	audio_r1 <= audio_r;
	audio_r2 <= audio_r1;
	if (audio_r1 == audio_r2) audio_ls_r <= audio_r2;
	if (audio_acc + SAMPLERATE >= CLKRATE) begin
		audio_acc <= audio_acc + SAMPLERATE - CLKRATE;
		audio_clk <= 1'b1;
	end else begin
		audio_acc <= audio_acc + SAMPLERATE;
		audio_clk <= 1'b0;
	end
	if (audio_clk) begin
		hdmi_audio_l <= { audio_ls_l, 8'h00 };
		hdmi_audio_r <= { audio_ls_r, 8'h00 };
	end
end

// hdmi tx
hdmi_tx #(.SAMPLE_FREQ(SAMPLERATE)) hdmi_tx(
	.clk(p_clk_int),
	.sclk(clk_hdmi),
	.sclk_n(clk_hdmi_n),
	.reset(reset || ~lockedx5),
	.rgb(vga_rgb),
	.vsync(vga_vs),
	.hsync(vga_hs),
	.de(vga_de),
	
	.audio_en(audio_en),
	.audio_l(hdmi_audio_l),
	.audio_r(hdmi_audio_r),
	.audio_clk(audio_clk),
	
	.tx_clk_n(tmds_n[3]),
	.tx_clk_p(tmds_p[3]),
	.tx_d_n(tmds_n[2:0]),
	.tx_d_p(tmds_p[2:0]) // 0:blue, 1:green, 2:red
);

endmodule
