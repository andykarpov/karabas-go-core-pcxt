`timescale 1ns / 1ps
`default_nettype none
/*
 game_port.v
 karabas: the game port (200h-207h) with two joysticks from the USB pads of the mcu (kg_mcu JOY_L /
 JOY_R, Sega MD2 bits: 0 connected, 1 up, 2 down, 3 left, 4 right, 5 start, 6 A, 7 B, 8 C, 9 X,
 10 Y, 11 Z, 12 mode). As tandy_pcjr_joy.sv of MiSTer PCXT in its digital mode: a write starts the
 four one-shots, each stays 1 for its axis value x PULSE_DIV clocks (50 MHz: 5.3 us a step, 0..1.36
 ms, the centre 0.68 ms); a digital pad gives 00h / 80h / FFh. A pad that is not connected (bit 0)
 keeps its axis bits at 1, as the open resistors of a missing joystick do. Read: bits 0-3 joystick 1 X, Y,
 joystick 2 X, Y (1 while the one-shot runs), bits 4-7 the buttons 1 and 2 of joystick 1 and 2, low
 when pressed: A or C or X is button 1, B or Y or Z button 2.
*/
module game_port #(
	parameter PULSE_DIV = 9'd265
) (
	input wire clk,                   // clk_chipset, 50 MHz
	input wire reset,
	input wire start,                 // a write to the port (a one-clock strobe)
	input wire [12:0] joy0,
	input wire [12:0] joy1,
	output wire [7:0] d_out
);

function [7:0] axis(input lo, input hi);
	axis = lo ? 8'h00 : hi ? 8'hFF : 8'h80;
endfunction

reg [7:0] x0 = 8'd0, y0 = 8'd0, x1 = 8'd0, y1 = 8'd0;
reg [8:0] div = 9'd0;
reg c0 = 1'b0, c1 = 1'b0;            // connected at the start

always @(posedge clk) begin
	if (reset) begin
		{x0, y0, x1, y1} <= 32'd0;
		div <= 9'd0;
	end else if (start) begin
		c0 <= joy0[0];
		c1 <= joy1[0];
		x0 <= axis(joy0[3], joy0[4]);
		y0 <= axis(joy0[1], joy0[2]);
		x1 <= axis(joy1[3], joy1[4]);
		y1 <= axis(joy1[1], joy1[2]);
		div <= 9'd0;
	end else if (div == PULSE_DIV) begin
		div <= 9'd0;
		if (x0 != 8'd0) x0 <= x0 - 1'd1;
		if (y0 != 8'd0) y0 <= y0 - 1'd1;
		if (x1 != 8'd0) x1 <= x1 - 1'd1;
		if (y1 != 8'd0) y1 <= y1 - 1'd1;
	end else
		div <= div + 1'd1;
end

wire b0_1 = joy0[6] | joy0[8] | joy0[9];
wire b0_2 = joy0[7] | joy0[10] | joy0[11];
wire b1_1 = joy1[6] | joy1[8] | joy1[9];
wire b1_2 = joy1[7] | joy1[10] | joy1[11];

assign d_out = {~b1_2, ~b1_1, ~b0_2, ~b0_1, |y1 | ~c1, |x1 | ~c1, |y0 | ~c0, |x0 | ~c0};

endmodule
