`timescale 1ns / 1ns

// The floppy disks of the core: floppy.v (HW/common, the controller of Peripherals.v under
// FLOPPY) on its own bus (io / dma pulses, as the glue of Peripherals.v makes them), pcxt_disks.v
// (pcxt_fdd + img_sdc) on its management bus and a model of the mcu firmware on the IMG_* frames,
// reads and writes. Checks the geometry from the image size, a read of two sectors (logical
// sector from C / H / R), a write and its read back, drive B, a format of a track.
// Run: sim/run_fdd_sim.sh

module tb_fdd;

reg clk = 1'b0;
always #10 clk = ~clk; // 50 MHz, the chipset

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

// ---------------- pcxt_disks + mcu firmware model ----------------

reg [7:0] img_mounted = 8'd0;
reg [63:0] img_size = 64'd0;
reg img_data_wr = 1'b0, img_result_wr = 1'b0;
reg [8:0] img_data_addr = 9'd0;
reg [7:0] img_data = 8'd0, img_result = 8'd0;
reg [15:0] img_sum = 16'd0;
wire img_q_wr;
wire [23:0] img_q_di;
reg img_q_ack = 1'b0;

wire [15:0] cf_d;
pcxt_disks dut(
	.clk(clk), .areset(reset), .hdd0_image(1'b1),
	.sys_cs_n(2'b11), .sys_rd_n(1'b1), .sys_wr_n(1'b1), .sys_a(3'd0),
	.sys_dout(16'h0000), .sys_din(), .sys_reset_n(~reset),
	.fdd_mgmt_address(mgmt_address), .fdd_mgmt_fddn(mgmt_fddn), .fdd_mgmt_write(mgmt_write),
	.fdd_mgmt_writedata(mgmt_writedata), .fdd_mgmt_read(mgmt_read),
	.fdd_mgmt_readdata(mgmt_readdata), .fdd_request(fdd_request),
	.cf_cs_n(), .cf_rd_n(), .cf_wr_n(), .cf_a(), .cf_d(cf_d), .cf_reset_n(),
	.img_mounted(img_mounted), .img_size(img_size),
	.img_data_wr(img_data_wr), .img_data_addr(img_data_addr), .img_data(img_data),
	.img_result_wr(img_result_wr), .img_result(img_result), .img_sum(img_sum),
	.img_q_wr(img_q_wr), .img_q_di(img_q_di), .img_q_ack(img_q_ack)
);
assign (weak1, weak0) cf_d = 16'hFFFF;

// the image: a pattern, and up to 16 written sectors over it
function [7:0] dbyte(input [7:0] slot, input [31:0] lba, input [8:0] i);
	dbyte = lba[7:0] ^ i[7:0] ^ 8'h5A ^ { 7'd0, i[8] } ^ { slot[2:0], 5'd0 } ^ lba[15:8];
endfunction
reg [7:0] wsec [0:16*512-1];
reg [31:0] wsec_lba [0:15];
reg [7:0] wsec_slot [0:15];
integer wsec_n = 0;
integer mcu_reads = 0, mcu_writes = 0;
reg [31:0] last_lba = 0;
reg [7:0] last_slot = 0;

function [7:0] ibyte(input [7:0] slot, input [31:0] lba, input [8:0] i);
	integer j;
	begin
		ibyte = dbyte(slot, lba, i);
		for (j = 0; j < wsec_n; j = j + 1)
			if (wsec_lba[j] == lba && wsec_slot[j] == slot)
				ibyte = wsec[j*512 + i];
	end
endfunction

reg [31:0] q_lba = 0;
reg [7:0] q_slot = 0, q_op = 0;
reg q_sec = 0;
reg [7:0] wbuf [0:511];
reg wbank = 0;
reg [15:0] wsum_got = 0, wsum_calc = 0;
reg wdone = 0;
integer k;
always @(posedge clk) begin
	img_q_ack <= 1'b0;
	if (img_q_wr && !img_q_ack) begin
		img_q_ack <= 1'b1;
		case (img_q_di[23:16])
			8'h42: q_lba[img_q_di[9:8]*8 +: 8] = img_q_di[7:0];
			8'h43: begin q_slot = img_q_di[15:8]; q_op = img_q_di[7:0]; q_sec = 1; end
			8'h44:
				if (img_q_di[15:8] == 8'h00) wbank = img_q_di[0];
				else if (img_q_di[15:8] == 8'h10) wsum_got[7:0] = img_q_di[7:0];
				else if (img_q_di[15:8] == 8'h11) begin wsum_got[15:8] = img_q_di[7:0]; wdone = 1; end
			8'h45: wbuf[{ wbank, img_q_di[15:8] }] = img_q_di[7:0];
			default: ;
		endcase
	end
end

task mcu_result(input [7:0] r);
	begin
		@(posedge clk); img_result <= r; img_result_wr <= 1'b1;
		@(posedge clk); img_result_wr <= 1'b0;
	end
endtask

reg [7:0] b;
reg [15:0] s;
initial begin : mcu_model
	forever begin
		@(posedge clk);
		if (q_sec && q_op == 8'd1) begin
			q_sec = 0;
			#20000;
			mcu_reads = mcu_reads + 1;
			last_lba = q_lba;
			last_slot = q_slot;
			s = 0;
			for (k = 0; k < 512; k = k + 1) begin
				b = ibyte(q_slot, q_lba, k);
				s = s + b;
				@(posedge clk); img_data_wr <= 1'b1; img_data_addr <= k; img_data <= b;
				@(posedge clk); img_data_wr <= 1'b0;
			end
			img_sum <= s;
			mcu_result(8'd1);
		end
		else if (q_sec && q_op == 8'd2 && wdone) begin
			q_sec = 0;
			wdone = 0;
			#20000;
			wsum_calc = 0;
			for (k = 0; k < 512; k = k + 1)
				wsum_calc = wsum_calc + wbuf[k];
			check("write sum", wsum_got, wsum_calc);
			for (k = 0; k < 512; k = k + 1)
				wsec[wsec_n*512 + k] = wbuf[k];
			wsec_lba[wsec_n] = q_lba;
			wsec_slot[wsec_n] = q_slot;
			wsec_n = wsec_n + 1;
			mcu_writes = mcu_writes + 1;
			last_lba = q_lba;
			last_slot = q_slot;
			mcu_result(8'd1);
		end
	end
end

task mount(input [2:0] slot, input [63:0] size);
	begin
		@(posedge clk); img_size <= size; img_mounted <= 8'h01 << slot;
		@(posedge clk); img_mounted <= 8'h00;
		repeat (20) @(posedge clk);
	end
endtask

// ---------------- the BIOS: the FDC ports ----------------

reg [7:0] rbyte;
task fdc_wr(input [2:0] a, input [7:0] d);
	begin
		@(posedge clk); io_address <= a; io_writedata <= d; io_write <= 1'b1;
		@(posedge clk); io_write <= 1'b0;
		repeat (4) @(posedge clk);
	end
endtask

// io_readdata is a register of the state before the read
task fdc_rd(input [2:0] a);
	begin
		@(posedge clk); io_address <= a; io_read <= 1'b1;
		@(posedge clk); io_read <= 1'b0;
		#1 rbyte = io_readdata;
		repeat (4) @(posedge clk);
	end
endtask

// main status: RQM, then a command byte
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

// ---------------- the 8237, channel 2 ----------------

reg dma_on = 1'b0, dma_to_fdc = 1'b0;
integer dma_count = 0, dma_n = 0;
reg [7:0] mem [0:4095];      // the memory the DMA reads / writes
reg [7:0] wpat_seed = 8'h00; // pattern of the sectors written
initial begin : dma_model
	forever begin
		@(posedge clk);
		if (dma_on && dma_req && dma_n < dma_count) begin
			@(posedge clk);
			if (dma_to_fdc)
				dma_readdata <= mem[dma_n];
			repeat (6) @(posedge clk);  // the cycle, DACK low (the glue gives floppy.v its end)
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

task wait_writes(input integer n);
	integer t;
	begin
		t = 0;
		while (mcu_writes < n && t < 1000000) begin @(posedge clk); t = t + 1; end
	end
endtask

task wait_irq;
	integer t;
	begin
		t = 0;
		while (!irq && t < 2000000) begin @(posedge clk); t = t + 1; end
		if (!irq) begin $display("ERROR no irq"); errors = errors + 1; end
	end
endtask

// read (06) / write (05) of sectors R..eot of C / H, with DMA
task fdc_rw(input wr, input drive, input [7:0] c, input [7:0] h, input [7:0] r, input [7:0] eot, input integer count);
	begin
		dma_n = 0; dma_count = count; dma_to_fdc = wr; dma_on = 1'b1;
		fdc_cmd(wr ? 8'h45 : 8'h46);           // MFM
		fdc_cmd({ 5'd0, h[0], 1'b0, drive });
		fdc_cmd(c);
		fdc_cmd(h);
		fdc_cmd(r);
		fdc_cmd(8'd2);                          // 512 bytes
		fdc_cmd(eot);
		fdc_cmd(8'h1B);
		fdc_cmd(8'hFF);
		wait_irq;
		fdc_result(7);
		dma_on = 1'b0;
		check("dma bytes", dma_n, count);
		check("st0", res[0] & 8'hC0, 8'h00);
	end
endtask

// trace: +trace
reg [3:0] fdc_state_q = 0, fdd_state_q = 0;
always @(posedge clk)
	if ($test$plusargs("trace")) begin
		fdc_state_q <= fdc.state;
		fdd_state_q <= dut.u_fdd.state;
		if (fdc.state != fdc_state_q)
			$display("%t fdc state %0d req %b fifo %0d", $time, fdc.state, fdd_request, fdc.fifo_count);
		if (dut.u_fdd.state != fdd_state_q)
			$display("%t pcxt_fdd state %0d", $time, dut.u_fdd.state);
	end

integer i, r0, w0, errs0;
reg [31:0] lba;
initial begin
	if ($test$plusargs("vcd")) begin
		$dumpfile("build/tb_fdd.vcd");
		$dumpvars(0, tb_fdd);
	end
	repeat (10) @(posedge clk);
	reset = 1'b0;
	repeat (10) @(posedge clk);

	// drive A: 1.44M, drive B: 360K
	mount(3'd2, 64'd1474560);
	mount(3'd3, 64'd368640);
	check("A cylinders", fdc.media_cylinders[0], 80);
	check("A spt", fdc.media_sectors_per_track[0], 18);
	check("A heads", fdc.media_heads[0], 2);
	check("A sectors", fdc.media_sector_count[0], 2880);
	check("A present", fdc.media_present[0], 1);
	check("B cylinders", fdc.media_cylinders[1], 40);
	check("B spt", fdc.media_sectors_per_track[1], 9);
	check("B heads", fdc.media_heads[1], 2);
	check("B present", fdc.media_present[1], 1);

	// DOR: motors A and B on, DMA, not in reset; specify (DMA mode)
	fdc_wr(3'd2, 8'h3C);
	fdc_cmd(8'h03); fdc_cmd(8'hDF); fdc_cmd(8'h02);

	// A: C 1, H 1, R 3 and 4 = logical sectors 56, 57
	r0 = mcu_reads;
	fdc_rw(1'b0, 1'b0, 8'd1, 8'd1, 8'd3, 8'd4, 1024);
	check("A read sectors", mcu_reads - r0, 2);
	errs0 = errors;
	for (i = 0; i < 1024; i = i + 1)
		if (mem[i] !== dbyte(8'd2, 56 + i / 512, i % 512) && errors < errs0 + 4) begin
			$display("ERROR A read byte %0d: %h", i, mem[i]);
			errors = errors + 1;
		end
	check("A read result C", res[3], 8'd2); // after R = EOT: the next cylinder, R 1
	check("A read result R", res[5], 8'd1);
	$display("A read C1 H1 R3-4: lba %0d, %0d errors", last_lba, errors - errs0);

	// A: write C 2, H 0, R 7 (lba 2*36 + 6 = 78), then read it back
	for (i = 0; i < 512; i = i + 1)
		mem[i] = i[7:0] ^ 8'hC3 ^ { 7'd0, i[8] };
	w0 = mcu_writes;
	fdc_rw(1'b1, 1'b0, 8'd2, 8'd0, 8'd7, 8'd7, 512);
	wait_writes(w0 + 1); // the controller ends the command before the sector reaches the mcu
	check("A write sectors", mcu_writes - w0, 1);
	check("A write lba", last_lba, 78);
	check("A write slot", last_slot, 2);
	for (i = 0; i < 512; i = i + 1)
		mem[i] = 8'h00;
	fdc_rw(1'b0, 1'b0, 8'd2, 8'd0, 8'd7, 8'd7, 512);
	errs0 = errors;
	for (i = 0; i < 512; i = i + 1)
		if (mem[i] !== (i[7:0] ^ 8'hC3 ^ { 7'd0, i[8] }) && errors < errs0 + 4) begin
			$display("ERROR A read back byte %0d: %h", i, mem[i]);
			errors = errors + 1;
		end
	$display("A write + read back lba 78: %0d errors", errors - errs0);

	// B: C 39, H 1, R 9 = the last sector, 719
	fdc_wr(3'd2, 8'h3D); // drive B selected
	fdc_rw(1'b0, 1'b1, 8'd39, 8'd1, 8'd9, 8'd9, 512);
	check("B read lba", last_lba, 719);
	check("B read slot", last_slot, 3);
	errs0 = errors;
	for (i = 0; i < 512; i = i + 1)
		if (mem[i] !== dbyte(8'd3, 719, i) && errors < errs0 + 4) begin
			$display("ERROR B read byte %0d: %h", i, mem[i]);
			errors = errors + 1;
		end
	$display("B read C39 H1 R9: lba %0d, %0d errors", last_lba, errors - errs0);

	// B: format C 0, H 0 (9 sectors of F6): 4 bytes C H R N per sector by DMA
	for (i = 0; i < 9; i = i + 1) begin
		mem[i*4] = 8'd0; mem[i*4+1] = 8'd0; mem[i*4+2] = i + 1; mem[i*4+3] = 8'd2;
	end
	w0 = mcu_writes;
	dma_n = 0; dma_count = 36; dma_to_fdc = 1'b1; dma_on = 1'b1;
	fdc_cmd(8'h4D); fdc_cmd(8'h01); fdc_cmd(8'h02); fdc_cmd(8'd9); fdc_cmd(8'h54); fdc_cmd(8'hF6);
	wait_irq;
	fdc_result(7);
	dma_on = 1'b0;
	wait_writes(w0 + 9);
	check("B format sectors", mcu_writes - w0, 9);
	check("B format byte", wsec[(wsec_n - 1)*512 + 100], 8'hF6);
	check("B format st0", res[0] & 8'hC0, 8'h00);
	check("B format last lba", last_lba, 8);
	$display("B format C0 H0: %0d sectors written, last lba %0d", mcu_writes - w0, last_lba);

	// unmount A: not present
	mount(3'd2, 64'd0);
	check("A present after unmount", fdc.media_present[0], 0);

	$display("tb_fdd: %0d errors", errors);
	$finish;
end

initial begin
	#50000000;
	$display("ERROR timeout");
	$display("tb_fdd: %0d errors", errors + 1);
	$finish;
end

endmodule
