`timescale 1ns / 1ps
`default_nettype none

// The flags of ADD / ADC / SUB / SBB on the MCL86 (i8088 of HW/8088/mcl86_2026, with OLD=1 of HW/8088): the program
// of gen_cpu_flags.py runs from F0000 and pushes the flags after every operation; the stack
// (0000:0FFE down) is compared with the flags a real 8088 sets. The bus as the status lines give it
// (the address at the start of a cycle, the write data at its end), no 8288, no wait states.

module tb_cpu_flags;

reg clk_100 = 1'b0;
always #5 clk_100 = ~clk_100;

// the CPU clock as in system.v: 14.3 MHz, here 100 / 7
reg clk_cpu = 1'b0;
reg [2:0] div = 3'd0;
always @(posedge clk_100) begin
	div <= (div == 3'd6) ? 3'd0 : div + 3'd1;
	clk_cpu <= (div < 3'd3);
end

reg reset = 1'b1;
wire [19:0] ad_out;
wire [7:0] dout;
wire [2:0] status;
reg [7:0] din;

i8088 cpu(
	.CORE_CLK(clk_100), .CLK(clk_cpu), .RESET(reset), .READY(1'b1), .INTR(1'b0), .NMI(1'b0),
	.ad_out(ad_out), .dout(dout), .din(din),
	.lock_n(), .s6_3_mux(), .s2_s0_out(status), .SEGMENT(), .biu_done(),
`ifdef MCL86_2026
	.cycle_accrate(1'b1), .clock_cycle_counter_division_ratio(8'd0),
	.clock_cycle_counter_decrement_value(8'd1), .shift_read_timing(1'b0), .is8086(1'b0),
	.fake286_flags(1'b0), .word_read_request(), .word_write_request(), .data_bus_word_out(),
	.data_bus_word(16'h0000), .word_access_possible(1'b0));
`else
	.turbo_mode(1'b0));
`endif

reg [7:0] ram [0:16'hFFFF];  // 00000-0FFFF
reg [7:0] rom [0:16'hFFFF];  // F0000-FFFFF
reg [15:0] exp [0:2047];
integer i;
initial begin
	for (i = 0; i < 65536; i = i + 1) ram[i] = 8'h00;
	for (i = 0; i < 2048; i = i + 1) exp[i] = 16'hxxxx;
	$readmemh("cpu_flags_rom.hex", rom);
	$readmemh("cpu_flags_exp.hex", exp);
end

reg [2:0] status_q = 3'b111;
reg [19:0] addr = 20'h0;
reg [2:0] cycle = 3'b111;
always @(posedge clk_100) begin
	status_q <= status;
	if (status_q == 3'b111 && status != 3'b111) begin
		addr <= ad_out;
		cycle <= status;
	end
	if (status_q != 3'b111 && status == 3'b111 && cycle == 3'b110 && addr[19:16] == 4'h0)
		ram[addr[15:0]] <= dout;
end
always @(*)
	din = (addr[19:16] == 4'hF) ? rom[addr[15:0]] : (addr[19:16] == 4'h0) ? ram[addr[15:0]] : 8'hFF;

integer n, errors;
reg [15:0] got;
initial begin
	errors = 0;
	#200 reset = 1'b0;
	wait (ram[16'h2000] == 8'h55 || $time > 400_000_000);
	if (ram[16'h2000] != 8'h55) begin
		$display("ERROR: the program did not finish");
		errors = errors + 1;
	end
	for (n = 0; exp[n] !== 16'hxxxx; n = n + 1) begin
		got = {ram[16'h0FFF - 2 * n], ram[16'h0FFE - 2 * n]};
		if ((got & 16'h08D5) != exp[n]) begin
			$display("ERROR: test %0d flags %04x expected %04x (OF SF ZF AF PF CF = 08D5)",
				n, got & 16'h08D5, exp[n]);
			errors = errors + 1;
		end
	end
	$display("%0d tests", n);
	$display("tb_cpu_flags: %0d errors", errors);
	$finish;
end

endmodule
