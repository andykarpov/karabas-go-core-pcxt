`timescale 1ns / 1ps
`default_nettype none

// karabas: 12 MHz for the MIDI synthesizer of Go and Mini (MIDI_CLK; Mini G has its own crystal):
// a DCM on clk_50, CLKFX = 50 * 6 / 25 = 12.000 MHz, out through an ODDR2.

module midi_clk (
	input wire clk_50,
	output wire midi_clk
);

wire clkfx, clk_12;

DCM_SP #(
	.CLKIN_PERIOD(20.0),
	.CLKFX_MULTIPLY(6),
	.CLKFX_DIVIDE(25),
	.CLK_FEEDBACK("NONE"),
	.STARTUP_WAIT("FALSE")
) dcm_midi (
	.CLKIN(clk_50),
	.CLKFB(1'b0),
	.RST(1'b0),
	.PSEN(1'b0),
	.PSINCDEC(1'b0),
	.PSCLK(1'b0),
	.DSSEN(1'b0),
	.CLKFX(clkfx),
	.CLK0(), .CLK90(), .CLK180(), .CLK270(), .CLK2X(), .CLK2X180(), .CLKDV(), .CLKFX180(),
	.LOCKED(), .PSDONE(), .STATUS()
);

BUFG bufg_midi (.I(clkfx), .O(clk_12));

ODDR2 oddr_midi (
	.Q(midi_clk),
	.C0(clk_12),
	.C1(~clk_12),
	.CE(1'b1),
	.D0(1'b1),
	.D1(1'b0),
	.R(1'b0),
	.S(1'b0)
);

endmodule
