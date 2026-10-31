`timescale 1ns / 1ps

/*
 tb_fdd_phys.v

 pcxt_fdd_phys (rtl/fdd) on two drive models (fdd_model.v), at a faster scale (an MFM cell of
 10 / 17 / 20 clocks, short step / settle / spin times):
 - drive A on DS1: 500 kbit/s, 4 sectors, 2 heads, the rotation 1 % slow, write protect off;
 - drive B on DS0: 250 kbit/s, 5 sectors, 1 head, 2 % fast, write protected.
 Probe of both (the geometry), reads (head 0 / 1, after a seek), a write and its read back, a
 format of a track and its read back, a sector on an unformatted track (not found), a probe
 without a disk. Ends with "tb_fdd_phys: N errors".
*/

module tb_fdd_phys;

reg clk = 1'b0;
always #10 clk = ~clk;
reg reset = 1'b1;

reg [1:0] map0 = 2'd0, map1 = 2'd0;
reg [1:0] probe = 2'b00;
reg [1:0] dor_motor = 2'b00;
reg dor_drive = 1'b0;
reg op_go = 1'b0;
reg [1:0] op_kind = 2'd0;
reg op_n = 1'b0;
reg [15:0] op_lba = 16'd0;
wire op_done;
wire [1:0] op_err;
wire [1:0] geo_upd;
reg geo_n = 1'b0;
wire geo_present, geo_wp;
wire [7:0] geo_cyl, geo_spt;
wire [15:0] geo_secs;
wire [1:0] geo_heads;
wire buf_we;
wire [8:0] buf_a;
wire [7:0] buf_wd;
reg [7:0] buf_q = 8'd0;
reg [7:0] bufm [0:511];
always @(posedge clk) begin
	if (buf_we) bufm[buf_a] <= buf_wd;
	buf_q <= bufm[buf_a];
end

wire [3:0] fdd_in, in_a, in_b;
wire [7:0] fdd_out;
assign fdd_in = in_a | in_b;

pcxt_fdd_phys #(
	.STEP_US(20), .SETTLE_US(50), .SPIN_US(500), .NOIDX_US(60000), .OP_US(400000),
	.CELL_500(7'd10), .CELL_300(7'd17), .CELL_250(7'd20)
) dut (
	.clk(clk), .reset(reset),
	.map0(map0), .map1(map1), .probe(probe), .dor_motor(dor_motor), .dor_drive(dor_drive),
	.op_go(op_go), .op_kind(op_kind), .op_n(op_n), .op_lba(op_lba), .op_done(op_done), .op_err(op_err),
	.geo_upd(geo_upd), .geo_n(geo_n), .geo_present(geo_present), .geo_wp(geo_wp), .geo_cyl(geo_cyl),
	.geo_spt(geo_spt), .geo_secs(geo_secs), .geo_heads(geo_heads),
	.buf_we(buf_we), .buf_a(buf_a), .buf_wd(buf_wd), .buf_q(buf_q),
	.fdd_in(fdd_in), .fdd_out(fdd_out)
);

fdd_model #(.DS(1), .CELL(10), .SPT(4), .HEADS(2), .TRK_BYTES(3000), .SPEED(1.01), .CYL0(5)) drv_a (
	.fdd_out(fdd_out), .fdd_in(in_a));
fdd_model #(.DS(0), .CELL(20), .SPT(5), .HEADS(1), .TRK_BYTES(3700), .SPEED(0.98), .CYL0(2)) drv_b (
	.fdd_out(fdd_out), .fdd_in(in_b));

integer errors = 0;
integer i;

task check_geo;
	input nn;
	input pres;
	input [7:0] spt;
	input [1:0] heads;
	input [7:0] cyl;
	input wp;
	begin
		geo_n = nn;
		#1;
		$display("geometry %0d: present %0d, %0d cyl, %0d heads, %0d spt, %0d sectors, wp %0d", nn,
			geo_present, geo_cyl, geo_heads, geo_spt, geo_secs, geo_wp);
		if (geo_present !== pres || (pres && (geo_spt !== spt || geo_heads !== heads ||
				geo_cyl !== cyl || geo_wp !== wp || geo_secs !== cyl * heads * spt))) begin
			$display("ERROR: geometry %0d", nn);
			errors = errors + 1;
		end
	end
endtask

task do_probe;
	input nn;
	begin
		@(posedge clk) probe[nn] <= 1'b1;
		@(posedge clk) probe <= 2'b00;
		@(posedge clk);
		while (geo_upd[nn] !== 1'b1) @(posedge clk);
		@(posedge clk);
	end
endtask

task do_op;
	input [1:0] k;
	input nn;
	input [15:0] lba;
	input [1:0] err_exp;
	begin
		@(posedge clk) begin
			op_go <= 1'b1;
			op_kind <= k;
			op_n <= nn;
			op_lba <= lba;
		end
		@(posedge clk) op_go <= 1'b0;
		while (op_done !== 1'b1) @(posedge clk);
		$display("%0t: op %0d drive %0d lba %0d: error %0d", $time, k, nn, lba, op_err);
		if (op_err !== err_exp) begin
			$display("ERROR: op error %0d, expected %0d", op_err, err_exp);
			errors = errors + 1;
		end
	end
endtask

// the buffer holds the sector c / h / r of the pattern of the model (or the byte f)
task check_buf;
	input integer c, h, r;
	input integer f;
	integer e;
	begin
		e = 0;
		for (i = 0; i < 512; i = i + 1)
			if (bufm[i] !== ((f >= 0) ? f : (c * 7 + h * 13 + r * 3 + i) & 255)) e = e + 1;
		if (e != 0) begin
			$display("ERROR: sector %0d/%0d/%0d: %0d bytes differ (byte 0 %h)", c, h, r, e, bufm[0]);
			errors = errors + 1;
		end
	end
endtask

initial begin
	if ($test$plusargs("vcd")) begin
		$dumpfile("build/tb_fdd_phys.vcd");
		$dumpvars(0, tb_fdd_phys);
	end
	repeat (10) @(posedge clk);
	reset <= 1'b0;

	// A on DS1, B on DS0
	map0 = 2'd2;
	map1 = 2'd1;
	drv_b.wprot = 1'b1;
	drv_a.unfmt_c = 7;
	do_probe(0);
	check_geo(0, 1, 4, 2, 80, 0);
	do_probe(1);
	check_geo(1, 1, 5, 1, 80, 1);

	// floppy.v has A selected with the motor on (as the BIOS does it)
	dor_drive = 1'b0;
	dor_motor = 2'b01;

	// reads: c 0 h 0 r 1, c 0 h 1 r 2, c 3 h 1 r 4 (lba = (c * 2 + h) * 4 + r - 1)
	do_op(2'd1, 0, 16'd0, 2'd0);   check_buf(0, 0, 1, -1);
	do_op(2'd1, 0, 16'd5, 2'd0);   check_buf(0, 1, 2, -1);
	do_op(2'd1, 0, 16'd31, 2'd0);  check_buf(3, 1, 4, -1);

	// a write of c 2 h 0 r 3 (lba 18), read back
	for (i = 0; i < 512; i = i + 1) bufm[i] = (i * 5 + 1) & 255;
	do_op(2'd2, 0, 16'd18, 2'd0);
	for (i = 0; i < 512; i = i + 1) bufm[i] = 8'h00;
	do_op(2'd1, 0, 16'd18, 2'd0);
	for (i = 0; i < 512; i = i + 1)
		if (bufm[i] !== ((i * 5 + 1) & 255)) begin
			if (errors < 20) $display("ERROR: written byte %0d: %h", i, bufm[i]);
			errors = errors + 1;
		end
	// its neighbours are as they were
	do_op(2'd1, 0, 16'd17, 2'd0);  check_buf(2, 0, 2, -1);
	do_op(2'd1, 0, 16'd19, 2'd0);  check_buf(2, 0, 4, -1);

	// a format of c 5 h 1 with E5 (lba 44..47), read back
	for (i = 0; i < 512; i = i + 1) bufm[i] = 8'hE5;
	do_op(2'd3, 0, 16'd44, 2'd0);
	do_op(2'd3, 0, 16'd45, 2'd0);
	do_op(2'd3, 0, 16'd46, 2'd0);
	do_op(2'd3, 0, 16'd47, 2'd0);
	if (drv_a.fmt_ids !== 4) begin
		$display("ERROR: format wrote %0d IDs", drv_a.fmt_ids);
		errors = errors + 1;
	end
	for (i = 0; i < 512; i = i + 1) bufm[i] = 8'h00;
	do_op(2'd1, 0, 16'd46, 2'd0);  check_buf(5, 1, 3, 8'hE5);
	do_op(2'd1, 0, 16'd40, 2'd0);  check_buf(5, 0, 1, -1);

	// an unformatted track: not found
	do_op(2'd1, 0, 16'd56, 2'd1);

	// B: a read (250 kbit/s, one head: lba = c * 5 + r - 1)
	dor_drive = 1'b1;
	dor_motor = 2'b10;
	do_op(2'd1, 1, 16'd13, 2'd0);  check_buf(2, 0, 4, -1);

	// no disk in A
	dor_motor = 2'b00;
	drv_a.disk_in = 1'b0;
	do_probe(0);
	check_geo(0, 0, 0, 0, 0, 0);

	if (drv_a.crc_errs != 0 || drv_b.crc_errs != 0) begin
		$display("ERROR: CRC errors in the written fields: %0d / %0d", drv_a.crc_errs, drv_b.crc_errs);
		errors = errors + 1;
	end
	$display("tb_fdd_phys: %0d errors", errors);
	$finish;
end

initial begin
	#2000000000;
	$display("ERROR: timeout");
	$display("tb_fdd_phys: 1 errors");
	$finish;
end

endmodule
