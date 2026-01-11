`timescale 1ns / 1ps
//`default_nettype none

module hdmi_top(

	input wire clk,
	input wire ds80,

	input wire reset,
	
	input wire [23:0] vga_rgb,
	input wire vga_hs,
	input wire vga_vs,
	input wire vga_de,
	
	input wire audio_en,
	input wire [15:0] audio_l,
	input wire [15:0] audio_r,
	
	output wire [3:0] tmds_p,
	output wire [3:0] tmds_n,
	
	output wire [7:0] freq,
	output wire clk_pix
);

parameter SAMPLERATE = 44100;

// clocks
wire clk_hdmi, clk_hdmi_n;
wire p_clk_int, p_clk_div2;
wire [7:0] hdmi_freq;
wire lockedx5;
wire pll_reset;

assign clk_pix = p_clk_int;

hdmi_pll hdmi_pll (
	.clk(clk),
	.reset(reset),
	.ds80(ds80),
	.clk_hdmi(clk_hdmi),
	.clk_hdmi_n(clk_hdmi_n),
	.clk_pix(p_clk_int),
	.clk_pix2(p_clk_div2),
	.freq(hdmi_freq),
	.locked(lockedx5),
	.o_reset(pll_reset)
);
assign freq = hdmi_freq;

// reg signals in p_clk_int clock
reg [23:0] host_vga_rgb;
reg host_vga_hs, host_vga_vs, host_vga_blank;
reg [15:0] audio_out_l, audio_out_r;

always @(posedge p_clk_int)
begin
	host_vga_rgb <= (vga_de) ? vga_rgb : 24'b0;
	host_vga_hs <= vga_hs;
	host_vga_vs <= vga_vs;
	host_vga_blank <= ~vga_de;
	audio_out_l <= audio_l;
	audio_out_r <= audio_r;
end

// hdmi

wire [9:0] tmds_red, tmds_green, tmds_blue;
wire audio_sample; // audio sample locked strobe by hdmi module

hdmi #(.FS(SAMPLERATE), .N(6144)) hdmi(
	.I_CLK_PIXEL(p_clk_int),
	.I_RESET(pll_reset),
	.I_FREQ(hdmi_freq),
	.I_R(host_vga_rgb[23:16]),
	.I_G(host_vga_rgb[15:8]),
	.I_B(host_vga_rgb[7:0]),
	.I_BLANK(host_vga_blank),
	.I_HSYNC(host_vga_hs),
	.I_VSYNC(host_vga_vs),
	.I_AUDIO_ENABLE(1'b1),
	.I_AUDIO_PCM_L(audio_out_l),
	.I_AUDIO_PCM_R(audio_out_r),
	.O_SAMPLE(audio_sample),
	.O_RED(tmds_red),
	.O_GREEN(tmds_green),
	.O_BLUE(tmds_blue)
);

// dvi only

wire [9:0] dvi_red, dvi_green, dvi_blue;

dvi dvi(
	.CLK(p_clk_int),
	.RESET(pll_reset),
	.RGB(host_vga_rgb),
	.HSYNC(host_vga_hs),
	.VSYNC(host_vga_vs),
	.DE(~host_vga_blank),
	.ENC_RED(dvi_red),
	.ENC_GREEN(dvi_green),
	.ENC_BLUE(dvi_blue)
);

hdmi_out_xilinx hdmiio(
	.clock_pixel_i(p_clk_int),
	.clock_tdms_i(clk_hdmi),
	.clock_tdms_n_i(clk_hdmi_n),
	.red_i(audio_en ? tmds_red : dvi_red),
	.green_i(audio_en ? tmds_green : dvi_green),
	.blue_i(audio_en ? tmds_blue : dvi_blue),
	.tmds_out_p(tmds_p),
	.tmds_out_n(tmds_n)
);

endmodule
