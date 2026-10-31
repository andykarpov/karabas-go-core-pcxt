`timescale 1ns / 1ps
`default_nettype none

/*
 HDMI PLL chain to produce a pixelclock as well as x5 clock pair for hdmi serializer based on 
 detected frequency from the input clock clk.
*/

module hdmi_pll(
	input wire clk, // karabas: 28.571 MHz (pcxt clk_vga)
	input wire reset,
	output wire clk_hdmi, // x5
	output wire clk_hdmi_n, // x5 180deg
	output wire clk_pix, // x1
	output wire clk_pix2, // x1/2
	output wire [7:0] freq, // detected frequency 
	output wire locked,
	output wire o_reset
);

// freq counter
wire [7:0] hdmi_freq = 28;
assign freq = hdmi_freq;

// pll resetter
wire pll_rst;
pll_reset pll_reset(
	.clk(clk),
	.i_reset(reset),
	.o_reset(pll_rst)
);
assign o_reset = pll_rst;

// pll to produce x5 clock
wire clk0, clkfx, clkfx180, clkdv, clkfbout, lockedx5;

DCM_SP
  #(.CLKDV_DIVIDE          (2.000),
    .CLKFX_DIVIDE          (1),
    .CLKFX_MULTIPLY        (5),
    .CLKIN_DIVIDE_BY_2     ("FALSE"),
    .CLKIN_PERIOD          (35.000), // karabas: clk_vga of pcxt, 28.571 MHz
    .CLKOUT_PHASE_SHIFT    ("NONE"),
    .CLK_FEEDBACK          ("1X"),
    .DESKEW_ADJUST         ("SYSTEM_SYNCHRONOUS"),
    .PHASE_SHIFT           (0),
    .STARTUP_WAIT          ("FALSE"))
  dcm_sp_inst
    // Input clock
   (.CLKIN                 (clk),
    .CLKFB                 (clkfbout),
    // Output clocks
    .CLK0                  (clk0),
    .CLK90                 (),
    .CLK180                (),
    .CLK270                (),
    .CLK2X                 (),
    .CLK2X180              (),
    .CLKFX                 (clkfx),
    .CLKFX180              (clkfx180),
    .CLKDV                 (clkdv),
    // Ports for dynamic phase shift
    .PSCLK                 (1'b0),
    .PSEN                  (1'b0),
    .PSINCDEC              (1'b0),
    .PSDONE                (),
    // Other control and status signals
    .LOCKED                (lockedx5),
    .STATUS                (),
    .RST                   (pll_rst),
    .DSSEN                 (1'b0));

// feedback buf
BUFG clkf_buf(.O (clkfbout), .I (clk0));

// output bufs
BUFG clkout1_buf (.O(clk_hdmi), .I(clkfx));
BUFG clkout2_buf (.O(clk_hdmi_n), .I(clkfx180));
BUFG clkout3_buf (.O(clk_pix), .I(clk0));
BUFG clkout4_buf (.O(clk_pix2), .I(clkdv));
assign locked = lockedx5;

endmodule
