`timescale 1ns / 1ps
`default_nettype none

// karabas: a Roland MPU-401 in UART mode, output only (MIDI OUT to the synthesizer of the board).
// Ports 330h (data) / 331h (status / command), as mpu401.sv of MiSTer PCXT (d66cfc0) does them
// on uart_16750, without the receiver and the FIFO:
// - a command (331h) other than 3Fh in intelligent mode is acknowledged with FEh on the data port
//   (FFh reset returns to intelligent mode, 3Fh enters UART mode); a driver detects the card so;
// - status bit 7 (DSR) is 0 while the acknowledge waits, bit 6 (DRR) is 0 when a byte can be
//   written: the byte is shifted out at 31250 baud, 8N1, one byte buffered behind it.
// No IRQ (DOS drivers in UART mode poll the status port).

module mpu401_tx #(
	parameter CLK_HZ = 50000000
) (
	input wire clk,
	input wire reset,

	input wire address,       // 0: data (330h), 1: status / command (331h)
	input wire write,         // a one-clock strobe, writedata valid
	input wire [7:0] writedata,
	input wire read,          // a one-clock strobe at the start of a read
	output wire [7:0] readdata,

	output reg midi_tx = 1'b1
);

localparam [10:0] BIT_LAST = CLK_HZ / 31250 - 1; // clocks of a bit - 1

reg read_ack = 1'b0;
reg uart_mode = 1'b0;
reg [7:0] buf_data = 8'h00;
reg buf_full = 1'b0;

always @(posedge clk or posedge reset)
	if (reset) begin
		read_ack <= 1'b0;
		uart_mode <= 1'b0;
	end
	else if (write && address) begin
		read_ack <= ~uart_mode;
		if (writedata == 8'hFF) uart_mode <= 1'b0;
		if (writedata == 8'h3F) uart_mode <= 1'b1;
	end
	else if (read && !address)
		read_ack <= 1'b0;

assign readdata = address ? {~read_ack, buf_full, 6'd0} : (read_ack ? 8'hFE : 8'h00);

// the shifter: start bit, 8 data bits LSB first, stop bit
reg [10:0] bit_cnt = 11'd0;
reg [3:0] bit_idx = 4'd0;
reg [8:0] shift = 9'h1FF;
wire shifting = (bit_idx != 4'd0);

always @(posedge clk or posedge reset)
	if (reset) begin
		buf_full <= 1'b0;
		bit_idx <= 4'd0;
		bit_cnt <= 11'd0;
		shift <= 9'h1FF;
		midi_tx <= 1'b1;
	end
	else begin
		if (write && !address && !buf_full) begin
			buf_data <= writedata;
			buf_full <= 1'b1;
		end
		if (!shifting) begin
			midi_tx <= 1'b1;
			if (buf_full) begin
				buf_full <= 1'b0;
				shift <= {1'b1, buf_data};
				midi_tx <= 1'b0;
				bit_idx <= 4'd10;
				bit_cnt <= BIT_LAST;
			end
		end
		else if (bit_cnt != 11'd0)
			bit_cnt <= bit_cnt - 11'd1;
		else begin
			bit_idx <= bit_idx - 4'd1;
			bit_cnt <= BIT_LAST;
			midi_tx <= (bit_idx == 4'd1) ? 1'b1 : shift[0];
			shift <= {1'b1, shift[8:1]};
		end
	end

endmodule
