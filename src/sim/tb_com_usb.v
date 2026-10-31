`timescale 1ns / 1ps
`default_nettype none

// com_usb.v: THR to the mcu and the time of a character (divisor 1 and 2), received bytes from the
// mcu (a new index), RBR / DR, IIR and irq (received data, THR empty, OUT2), overrun, loopback.

module tb_com_usb;

reg clk = 1'b0;
always #10 clk = ~clk;   // 50 MHz

reg reset = 1'b1, write = 1'b0, read = 1'b0;
reg [2:0] address = 3'd0;
reg [7:0] writedata = 8'd0;
wire [7:0] readdata;
wire irq, tx_wr;
wire [7:0] tx_data;
reg [7:0] rx_data = 8'd0, rx_idx = 8'd0;

com_usb dut(.clk(clk), .reset(reset), .address(address), .write(write), .read(read),
	.writedata(writedata), .readdata(readdata), .irq(irq),
	.rx_data(rx_data), .rx_idx(rx_idx), .tx_wr(tx_wr), .tx_data(tx_data));

integer errors = 0, i;
reg [7:0] v;
task wr(input [2:0] a, input [7:0] d);
	begin @(posedge clk) begin address <= a; writedata <= d; write <= 1'b1; end @(posedge clk) write <= 1'b0; end
endtask
task rd(input [2:0] a, output [7:0] d);
	begin @(posedge clk) begin address <= a; read <= 1'b1; end #1 d = readdata; @(posedge clk) read <= 1'b0; end
endtask
task check(input [7:0] got, input [7:0] exp, input [8*24-1:0] what);
	begin if (got !== exp) begin $display("ERROR: %0s %h, expected %h", what, got, exp); errors = errors + 1; end end
endtask
task mcu_byte(input [7:0] d);
	begin @(posedge clk) begin rx_data <= d; rx_idx <= rx_idx + 1'd1; end repeat (3) @(posedge clk); end
endtask

integer t_wr, t_free;
reg seen_tx = 1'b0;
reg [7:0] tx_got = 8'd0;
always @(posedge clk) if (tx_wr) begin seen_tx <= 1'b1; tx_got <= tx_data; end

initial begin
	#100 reset = 1'b0;
	// 115200: DLAB, DLL 1, DLM 0, 8N1
	wr(3, 8'h83); wr(0, 8'h01); wr(1, 8'h00); wr(3, 8'h03);
	rd(5, v); check(v & 8'h60, 8'h60, "LSR empty");
	wr(0, 8'h41);
	t_wr = $time;
	repeat (2) @(posedge clk);
	if (!seen_tx || tx_got !== 8'h41) begin $display("ERROR: no byte to the mcu"); errors = errors + 1; end
	rd(5, v); check(v & 8'h60, 8'h00, "LSR busy");
	wait (dut.thr_busy == 1'b0); t_free = $time;
	if (t_free - t_wr < 86000 || t_free - t_wr > 88000) begin $display("ERROR: character time %0d ns", t_free - t_wr); errors = errors + 1; end
	// divisor 2: twice as long
	wr(3, 8'h83); wr(0, 8'h02); wr(3, 8'h03);
	wr(0, 8'h42); t_wr = $time;
	@(posedge clk);
	wait (dut.thr_busy == 1'b0); t_free = $time;
	if (t_free - t_wr < 173000 || t_free - t_wr > 175000) begin $display("ERROR: character time at divisor 2 %0d ns", t_free - t_wr); errors = errors + 1; end
	// received bytes, the interrupt of received data with OUT2
	wr(1, 8'h01); wr(4, 8'h08);
	if (irq) begin $display("ERROR: irq without data"); errors = errors + 1; end
	mcu_byte(8'h55); mcu_byte(8'hAA);
	if (!irq) begin $display("ERROR: no irq with data"); errors = errors + 1; end
	rd(2, v); check(v, 8'h04, "IIR received data");
	rd(5, v); check(v[0], 1'b1, "DR");
	rd(0, v); check(v, 8'h55, "RBR 1");
	rd(0, v); check(v, 8'hAA, "RBR 2");
	rd(5, v); check(v[0], 1'b0, "DR after the reads");
	if (irq) begin $display("ERROR: irq after the reads"); errors = errors + 1; end
	// THR empty interrupt: enabling it with THR empty raises it, reading IIR clears it
	wr(1, 8'h02);
	rd(2, v); check(v, 8'h02, "IIR THR empty");
	rd(2, v); check(v, 8'h01, "IIR after its read");
	// overrun: 17 bytes
	wr(1, 8'h04);
	for (i = 0; i < 17; i = i + 1) mcu_byte(i);
	rd(2, v); check(v, 8'h06, "IIR line status");
	rd(5, v); check(v[1], 1'b1, "LSR overrun");
	rd(5, v); check(v[1], 1'b0, "overrun cleared");
	for (i = 0; i < 16; i = i + 1) begin rd(0, v); check(v, i, "FIFO order"); end
	// loopback: THR comes back as RBR, nothing to the mcu
	seen_tx = 1'b0;
	wr(4, 8'h10); wr(0, 8'h99);
	repeat (3) @(posedge clk);
	if (seen_tx) begin $display("ERROR: loopback byte went to the mcu"); errors = errors + 1; end
	rd(0, v); check(v, 8'h99, "loopback RBR");
	$display("tb_com_usb: %0d errors", errors);
	$finish;
end

endmodule
