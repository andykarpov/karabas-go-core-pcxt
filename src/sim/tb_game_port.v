`timescale 1ns / 1ps
`default_nettype none

// game_port.v: pad 1 right + up + A, pad 2 centred + B, then pad 2 not connected; the time of each
// one-shot after a write and the button bits.

module tb_game_port;

reg clk = 1'b0;
always #10 clk = ~clk;   // 50 MHz

reg reset = 1'b1, start = 1'b0;
reg [12:0] joy0 = 13'd0, joy1 = 13'd0;
wire [7:0] d;
game_port dut(.clk(clk), .reset(reset), .start(start), .joy0(joy0), .joy1(joy1), .d_out(d));

integer errors = 0;
integer t0, t[0:3], i;
task fire;
	begin
		@(posedge clk) start <= 1'b1;
		@(posedge clk) start <= 1'b0;
		t0 = $time;
		for (i = 0; i < 4; i = i + 1) t[i] = -1;
		repeat (80000) begin
			@(posedge clk);
			for (i = 0; i < 4; i = i + 1)
				if (t[i] < 0 && !d[i]) t[i] = ($time - t0) / 1000;
		end
	end
endtask
task expect_us(input integer n, input integer lo, input integer hi);
	begin
		if (t[n] < lo || t[n] > hi) begin
			$display("ERROR: axis %0d after %0d us, expected %0d..%0d", n, t[n], lo, hi);
			errors = errors + 1;
		end
	end
endtask

initial begin
	#100 reset = 1'b0;
	// pad 1: connected, up (bit 1), right (bit 4), A (bit 6); pad 2: connected, centred, B (bit 7)
	joy0 = 13'b0_0000_0101_0011;
	joy1 = 13'b0_0000_1000_0001;
	fire;
	expect_us(0, 1340, 1370);   // X right: FFh
	expect_us(1, 0, 1);         // Y up: 00h
	expect_us(2, 670, 690);     // X centre: 80h
	expect_us(3, 670, 690);     // Y centre
	if (d[7:4] !== 4'b0110) begin $display("ERROR: buttons %b", d[7:4]); errors = errors + 1; end
	// pad 2 not connected: its axes stay 1
	joy1 = 13'd0;
	fire;
	if (t[2] != -1 || t[3] != -1) begin $display("ERROR: a missing pad timed out"); errors = errors + 1; end
	if (d[7:6] !== 2'b11) begin $display("ERROR: buttons of the missing pad %b", d[7:6]); errors = errors + 1; end
	$display("tb_game_port: %0d errors", errors);
	$finish;
end

endmodule
