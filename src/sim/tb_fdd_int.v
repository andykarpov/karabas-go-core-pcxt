`timescale 1ns / 1ps

// The physical floppy drives through the whole path: floppy.v on its own bus (io / DMA pulses,
// as in tb_fdd.v), pcxt_disks (PHYS_FDD 1: pcxt_fdd + pcxt_fdd_phys, the times of the phys made
// short), a drive model (fdd_model.v) on DS1, mapped to drive A by CMD_IMG_PHYS (slot 2, DS1).
// Checks the geometry in floppy.v, a read of two sectors, a write and its read back, a format of
// a track and a read of it, a sector on an unformatted track (ST0 40h, ST1 04h), a format with
// other sectors per track (taken, the new geometry), the write protect, a mount of an image over
// the drive. Run: sim/run_fdd_phys_sim.sh (after tb_fdd_phys).

module tb_fdd_int;

reg clk = 1'b0;
always #10 clk = ~clk;

reg reset = 1'b1;
integer errors = 0;

task check(input [255:0] what, input [31:0] got, input [31:0] exp);
	if (got !== exp) begin
		$display("ERROR %0s: %h, expected %h", what, got, exp);
		errors = errors + 1;
	end
endtask

// ---------------- floppy.v ----------------

reg [2:0] io_address = 3'd0;
reg io_read = 1'b0, io_write = 1'b0;
reg [7:0] io_writedata = 8'd0;
wire [7:0] io_readdata;
wire irq;
wire dma_req;
reg dma_ack = 1'b0, dma_tc = 1'b0;
reg [7:0] dma_readdata = 8'd0;
wire [7:0] dma_writedata;

wire [3:0] mgmt_address;
wire mgmt_fddn, mgmt_write, mgmt_read;
wire [15:0] mgmt_writedata, mgmt_readdata;
wire [1:0] fdd_request;

floppy fdc(
	.clk(clk), .rst_n(~reset),
	.dma_req(dma_req), .dma_ack(dma_ack), .dma_tc(dma_tc & dma_ack),
	.dma_readdata(dma_readdata), .dma_writedata(dma_writedata),
	.irq(irq),
	.io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
	.io_write(io_write), .io_writedata(io_writedata),
	.fdd0_inserted(),
	.mgmt_address(mgmt_address), .mgmt_fddn(mgmt_fddn), .mgmt_write(mgmt_write),
	.mgmt_writedata(mgmt_writedata), .mgmt_read(mgmt_read), .mgmt_readdata(mgmt_readdata),
	.wp(2'b00), .clock_rate(28'd50000000), .request(fdd_request)
);

// ---------------- pcxt_disks, the drive ----------------

reg [7:0] img_mounted = 8'd0;
reg [63:0] img_size = 64'd0;
reg img_phys_wr = 1'b0;
reg [15:0] img_phys = 16'd0;
wire [15:0] cf_d;
wire [3:0] fdd_in;
wire [7:0] fdd_out;

pcxt_disks #(.PHYS_FDD(1)) dut(
	.clk(clk), .areset(reset), .hdd0_image(1'b1),
	.sys_cs_n(2'b11), .sys_rd_n(1'b1), .sys_wr_n(1'b1), .sys_a(3'd0),
	.sys_dout(16'h0000), .sys_din(), .sys_reset_n(~reset),
	.fdd_mgmt_address(mgmt_address), .fdd_mgmt_fddn(mgmt_fddn), .fdd_mgmt_write(mgmt_write),
	.fdd_mgmt_writedata(mgmt_writedata), .fdd_mgmt_read(mgmt_read),
	.fdd_mgmt_readdata(mgmt_readdata), .fdd_request(fdd_request),
	.cf_cs_n(), .cf_rd_n(), .cf_wr_n(), .cf_a(), .cf_d(cf_d), .cf_reset_n(),
	.img_mounted(img_mounted), .img_size(img_size),
	.img_data_wr(1'b0), .img_data_addr(9'd0), .img_data(8'd0),
	.img_result_wr(1'b0), .img_result(8'd0), .img_sum(16'd0),
	.img_q_wr(), .img_q_di(), .img_q_ack(1'b0),
	.img_phys_wr(img_phys_wr), .img_phys(img_phys),
	.fdd_in(fdd_in), .fdd_out(fdd_out)
);
assign (weak1, weak0) cf_d = 16'hFFFF;

defparam dut.u_fdd.g_phys.u_phys.STEP_US = 20;
defparam dut.u_fdd.g_phys.u_phys.SETTLE_US = 50;
defparam dut.u_fdd.g_phys.u_phys.SPIN_US = 500;
defparam dut.u_fdd.g_phys.u_phys.NOIDX_US = 60000;
defparam dut.u_fdd.g_phys.u_phys.OP_US = 400000;
defparam dut.u_fdd.g_phys.u_phys.CELL_500 = 7'd10;
defparam dut.u_fdd.g_phys.u_phys.CELL_300 = 7'd17;
defparam dut.u_fdd.g_phys.u_phys.CELL_250 = 7'd20;

// 500 kbit/s, 6 sectors, 2 heads
fdd_model #(.DS(1), .CELL(10), .SPT(6), .HEADS(2), .TRK_BYTES(4200), .SPEED(1.01), .CYL0(3)) drv(
	.fdd_out(fdd_out), .fdd_in(fdd_in));

function [7:0] pat(input integer c, input integer h, input integer r, input integer i);
	pat = (c * 7 + h * 13 + r * 3 + i) & 255;
endfunction

// ---------------- the BIOS: the FDC ports (as tb_fdd.v) ----------------

reg [7:0] rbyte;
task fdc_wr(input [2:0] a, input [7:0] d);
	begin
		@(posedge clk); io_address <= a; io_writedata <= d; io_write <= 1'b1;
		@(posedge clk); io_write <= 1'b0;
		repeat (4) @(posedge clk);
	end
endtask

task fdc_rd(input [2:0] a);
	begin
		@(posedge clk); io_address <= a; io_read <= 1'b1;
		@(posedge clk); io_read <= 1'b0;
		#1 rbyte = io_readdata;
		repeat (4) @(posedge clk);
	end
endtask

task fdc_cmd(input [7:0] d);
	integer t;
	begin
		t = 0;
		fdc_rd(3'd4);
		while (!rbyte[7] || rbyte[6]) begin
			fdc_rd(3'd4);
			t = t + 1;
			if (t > 100000) begin $display("ERROR fdc not ready for %h", d); errors = errors + 1; disable fdc_cmd; end
		end
		fdc_wr(3'd5, d);
	end
endtask

reg [7:0] res [0:6];
task fdc_result(input integer n);
	integer i, t;
	begin
		for (i = 0; i < n; i = i + 1) begin
			t = 0;
			fdc_rd(3'd4);
			while (!rbyte[7] || !rbyte[6]) begin
				fdc_rd(3'd4);
				t = t + 1;
				if (t > 100000) begin $display("ERROR no result byte %0d", i); errors = errors + 1; disable fdc_result; end
			end
			fdc_rd(3'd5);
			res[i] = rbyte;
		end
	end
endtask

reg dma_on = 1'b0, dma_to_fdc = 1'b0;
integer dma_count = 0, dma_n = 0;
reg [7:0] mem [0:4095];
initial begin : dma_model
	forever begin
		@(posedge clk);
		if (dma_on && dma_req && dma_n < dma_count) begin
			@(posedge clk);
			if (dma_to_fdc)
				dma_readdata <= mem[dma_n];
			repeat (6) @(posedge clk);
			if (!dma_to_fdc)
				mem[dma_n] = dma_writedata;
			dma_ack <= 1'b1;
			dma_tc <= (dma_n == dma_count - 1);
			@(posedge clk);
			dma_ack <= 1'b0;
			dma_tc <= 1'b0;
			dma_n = dma_n + 1;
			repeat (4) @(posedge clk);
		end
	end
end

task wait_irq;
	integer t;
	begin
		t = 0;
		while (!irq && t < 40000000) begin @(posedge clk); t = t + 1; end
		if (!irq) begin $display("ERROR no irq"); errors = errors + 1; end
	end
endtask

task fdc_rw(input wr, input drive, input [7:0] c, input [7:0] h, input [7:0] r, input [7:0] eot, input integer count);
	begin
		dma_n = 0; dma_count = count; dma_to_fdc = wr; dma_on = 1'b1;
		fdc_cmd(wr ? 8'h45 : 8'h46);
		fdc_cmd({ 5'd0, h[0], 1'b0, drive });
		fdc_cmd(c);
		fdc_cmd(h);
		fdc_cmd(r);
		fdc_cmd(8'd2);
		fdc_cmd(eot);
		fdc_cmd(8'h1B);
		fdc_cmd(8'hFF);
		wait_irq;
		fdc_result(7);
		dma_on = 1'b0;
		$display("%0t: %s C%0d H%0d R%0d-%0d: ST0 %h ST1 %h ST2 %h, %0d bytes", $time, wr ? "write" : "read",
			c, h, r, eot, res[0], res[1], res[2], dma_n);
	end
endtask

integer i, errs0;
reg [7:0] dbg_lo, dbg_hi;
initial begin
	if ($test$plusargs("vcd")) begin
		$dumpfile("build/tb_fdd_int.vcd");
		$dumpvars(0, tb_fdd_int);
	end
	repeat (10) @(posedge clk);
	reset = 1'b0;
	repeat (10) @(posedge clk);
	drv.unfmt_c = 9;

	// the mcu: slot 2 (A) size 0, then CMD_IMG_PHYS 46 02 02 (DS1)
	@(posedge clk); img_size <= 64'd0; img_mounted <= 8'h04;
	@(posedge clk); img_mounted <= 8'h00;
	repeat (20) @(posedge clk);
	@(posedge clk); img_phys <= 16'h0202; img_phys_wr <= 1'b1;
	@(posedge clk); img_phys_wr <= 1'b0;
	while (fdc.media_present[0] !== 1'b1) @(posedge clk);
	repeat (20) @(posedge clk);
	check("A cylinders", fdc.media_cylinders[0], 80);
	check("A spt", fdc.media_sectors_per_track[0], 6);
	check("A heads", fdc.media_heads[0], 2);
	check("A sectors", fdc.media_sector_count[0], 960);
	$display("%0t: A geometry %0d/%0d/%0d, %0d sectors", $time, fdc.media_cylinders[0], fdc.media_heads[0],
		fdc.media_sectors_per_track[0], fdc.media_sector_count[0]);

	// the diagnostics at 3F0h / 3F1h: page 4 (drive A: present, two heads, 500 kbit/s, 6 sectors),
	// page 0 (IDs with a good CRC seen by the probe)
	repeat (40) @(posedge clk);
	fdc_wr(3'd3, 8'd4);
	fdc_rd(3'd0); dbg_lo = rbyte;
	fdc_rd(3'd1); dbg_hi = rbyte;
	check("diag page 4", {dbg_hi, dbg_lo}, 16'h6006);
	fdc_wr(3'd3, 8'd0);
	fdc_rd(3'd0); dbg_lo = rbyte;
	fdc_rd(3'd1); dbg_hi = rbyte;
	$display("%0t: diagnostics: page 4 %h, page 0: %0d good IDs, %0d bad", $time, 16'h6006, dbg_lo, dbg_hi);
	if (dbg_lo == 8'd0) begin $display("ERROR no good IDs in the diagnostics"); errors = errors + 1; end

	// DOR: motor A on, DMA; specify
	fdc_wr(3'd2, 8'h1C);
	fdc_cmd(8'h03); fdc_cmd(8'hDF); fdc_cmd(8'h02);

	// read C 2 H 1 R 5..6
	fdc_rw(1'b0, 1'b0, 8'd2, 8'd1, 8'd5, 8'd6, 1024);
	check("read st0", res[0] & 8'hC0, 8'h00);
	errs0 = errors;
	for (i = 0; i < 1024; i = i + 1)
		if (mem[i] !== pat(2, 1, 5 + i / 512, i % 512) && errors < errs0 + 4) begin
			$display("ERROR read byte %0d: %h", i, mem[i]);
			errors = errors + 1;
		end

	// write C 4 H 0 R 2, read back
	for (i = 0; i < 512; i = i + 1) mem[i] = (i * 3 + 7) & 255;
	fdc_rw(1'b1, 1'b0, 8'd4, 8'd0, 8'd2, 8'd2, 512);
	check("write st0", res[0] & 8'hC0, 8'h00);
	for (i = 0; i < 512; i = i + 1) mem[i] = 8'h00;
	fdc_rw(1'b0, 1'b0, 8'd4, 8'd0, 8'd2, 8'd2, 512);
	errs0 = errors;
	for (i = 0; i < 512; i = i + 1)
		if (mem[i] !== ((i * 3 + 7) & 255) && errors < errs0 + 4) begin
			$display("ERROR read back byte %0d: %h", i, mem[i]);
			errors = errors + 1;
		end

	// format C 9 H 0 (the unformatted track): first a read of it, not found
	fdc_rw(1'b0, 1'b0, 8'd9, 8'd0, 8'd1, 8'd1, 512);
	check("unformatted st0", res[0] & 8'hC0, 8'h40);
	check("unformatted st1", res[1], 8'h04);
	for (i = 0; i < 6; i = i + 1) begin
		mem[i*4] = 8'd9; mem[i*4+1] = 8'd0; mem[i*4+2] = i + 1; mem[i*4+3] = 8'd2;
	end
	dma_n = 0; dma_count = 24; dma_to_fdc = 1'b1; dma_on = 1'b1;
	fdc_cmd(8'h4D); fdc_cmd(8'h00); fdc_cmd(8'h02); fdc_cmd(8'd6); fdc_cmd(8'h54); fdc_cmd(8'hF6);
	wait_irq;
	fdc_result(7);
	dma_on = 1'b0;
	check("format st0", res[0] & 8'hC0, 8'h00);
	check("format IDs", drv.fmt_ids, 6);
	$display("%0t: format C9 H0: ST0 %h, %0d IDs written", $time, res[0], drv.fmt_ids);
	drv.unfmt_c = 255;
	fdc_rw(1'b0, 1'b0, 8'd9, 8'd0, 8'd4, 8'd4, 512);
	check("formatted st0", res[0] & 8'hC0, 8'h00);
	check("formatted byte", mem[300], 8'hF6);

	// a format of C 10 H 1 with 12 sectors (the disk has 6): floppy.v takes it, its geometry
	// becomes 12 sectors (the probe below makes it 6 again)
	for (i = 0; i < 12; i = i + 1) begin
		mem[i*4] = 8'd10; mem[i*4+1] = 8'd1; mem[i*4+2] = i + 1; mem[i*4+3] = 8'd2;
	end
	dma_n = 0; dma_count = 48; dma_to_fdc = 1'b1; dma_on = 1'b1;
	fdc_cmd(8'h4D); fdc_cmd(8'h04); fdc_cmd(8'h02); fdc_cmd(8'd12); fdc_cmd(8'h54); fdc_cmd(8'hE5);
	wait_irq;
	fdc_result(7);
	dma_on = 1'b0;
	check("format 12 st0", res[0] & 8'hC0, 8'h00);
	check("format 12 IDs", drv.fmt_ids, 12);
	check("format 12 spt", fdc.media_sectors_per_track[0], 12);
	check("format 12 sectors", fdc.media_sector_count[0], 1920);
	$display("%0t: format C10 H1 with 12 sectors: ST0 %h, %0d IDs, spt %0d, %0d sectors", $time, res[0],
		drv.fmt_ids, fdc.media_sectors_per_track[0], fdc.media_sector_count[0]);

	// write protected: probe again (the mcu maps the slot again)
	drv.wprot = 1'b1;
	@(posedge clk); img_phys <= 16'h0202; img_phys_wr <= 1'b1;
	@(posedge clk); img_phys_wr <= 1'b0;
	repeat (100) @(posedge clk);
	while (dut.u_fdd.g_phys.u_phys.st != 0) @(posedge clk);
	repeat (100) @(posedge clk);
	fdc_rw(1'b1, 1'b0, 8'd4, 8'd0, 8'd2, 8'd2, 512);
	check("wp st0", res[0] & 8'hC0, 8'h40);
	check("wp st1", res[1] & 8'h02, 8'h02);

	// an image over it: 1.44M from the size
	@(posedge clk); img_size <= 64'd1474560; img_mounted <= 8'h04;
	@(posedge clk); img_mounted <= 8'h00;
	repeat (40) @(posedge clk);
	check("image spt", fdc.media_sectors_per_track[0], 18);
	check("image map", dut.u_fdd.map0, 0);

	if (drv.crc_errs != 0) begin
		$display("ERROR: %0d CRC errors in the written fields", drv.crc_errs);
		errors = errors + 1;
	end
	$display("tb_fdd_int: %0d errors", errors);
	$finish;
end

initial begin
	#2000000000;
	$display("ERROR timeout");
	$display("tb_fdd_int: %0d errors", errors + 1);
	$finish;
end

endmodule
