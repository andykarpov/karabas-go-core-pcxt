`timescale 1ns / 1ps
`default_nettype none

// mpu401_tx: the acknowledge of a reset command, UART mode, two bytes sent back to back (the
// second written while the first shifts) and received by a 31250 baud 8N1 receiver here.

module tb_mpu401;

reg clk = 1'b0;
always #10 clk = ~clk;  // 50 MHz

reg reset = 1'b1, address = 1'b0, write = 1'b0, read = 1'b0;
reg [7:0] writedata = 8'h00;
wire [7:0] readdata;
wire midi_tx;

mpu401_tx dut(.clk(clk), .reset(reset), .address(address), .write(write), .writedata(writedata),
	.read(read), .readdata(readdata), .midi_tx(midi_tx));

integer errors = 0;
task wr(input a, input [7:0] d);
	begin
		@(posedge clk); address <= a; writedata <= d; write <= 1'b1;
		@(posedge clk); write <= 1'b0;
	end
endtask
task rd(input a, output [7:0] d);
	begin
		@(posedge clk); address <= a; read <= 1'b1;
		@(posedge clk); read <= 1'b0; d = readdata;
	end
endtask

// receiver: the middle of each bit
reg [7:0] rx [0:3];
integer nrx = 0, b;
reg [7:0] r;
always begin
	@(negedge midi_tx);
	#16000;  // half a bit
	if (midi_tx !== 1'b0) begin $display("ERROR: start bit"); errors = errors + 1; end
	for (b = 0; b < 8; b = b + 1) begin #32000; r[b] = midi_tx; end
	#32000;
	if (midi_tx !== 1'b1) begin $display("ERROR: stop bit"); errors = errors + 1; end
	rx[nrx] = r; nrx = nrx + 1;
end

reg [7:0] d;
initial begin
	#100 reset = 1'b0;
	rd(1, d); if (d[7] !== 1'b1) begin $display("ERROR: DSR before a command %02x", d); errors = errors + 1; end
	wr(1, 8'hFF);
	rd(1, d); if (d[7] !== 1'b0) begin $display("ERROR: no acknowledge %02x", d); errors = errors + 1; end
	rd(0, d); if (d !== 8'hFE) begin $display("ERROR: acknowledge %02x", d); errors = errors + 1; end
	rd(1, d); if (d[7] !== 1'b1) begin $display("ERROR: acknowledge not cleared %02x", d); errors = errors + 1; end
	wr(1, 8'h3F);
	rd(0, d); if (d !== 8'hFE) begin $display("ERROR: UART mode acknowledge %02x", d); errors = errors + 1; end
	wr(1, 8'h3F);
	rd(1, d); if (d[7] !== 1'b1) begin $display("ERROR: acknowledge in UART mode %02x", d); errors = errors + 1; end
	wr(0, 8'h90);
	repeat (3) @(posedge clk);
	rd(1, d); if (d[6] !== 1'b0) begin $display("ERROR: DRR busy with the buffer empty %02x", d); errors = errors + 1; end
	wr(0, 8'h3C);
	rd(1, d); if (d[6] !== 1'b1) begin $display("ERROR: DRR not busy %02x", d); errors = errors + 1; end
	wait (nrx == 2);
	#40000;
	if (rx[0] !== 8'h90 || rx[1] !== 8'h3C) begin
		$display("ERROR: received %02x %02x", rx[0], rx[1]); errors = errors + 1;
	end
	$display("tb_mpu401: %0d errors", errors);
	$finish;
end

endmodule
