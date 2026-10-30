`timescale 1ns / 1ps

// The image disks of the PCXT core: the 8-bit XT bus as the XTIDE BIOS drives it, XT2IDE.v (from
// HW/), pcxt_disks.v (hdf_ata + img_sdc behind it) and a model of the mcu firmware on the IMG_*
// ports (from tb_ata.v of next186).
// - the chip select of XT2IDE ends with the strobe (iorq of Peripherals.v), as on the core;
// - a 16-bit data word is two port accesses: base+0 (the low byte, the IDE read / write) and
//   base+8 (the high byte, latched in XT2IDE); a write puts the high byte first;
// - HDD0 = Image: mount, IDENTIFY, READ SECTORS of LBA 0 and 63, a CHS read and the same sector by
//   LBA, then the reset of the PC and the reads again;
// - HDD0 = CF card: device 1 (the HDD1 image) reads its sectors, device 0 (the card, not here)
//   gets no data from hdf_ata.
// Ends with "tb_disks: N errors".

module tb_disks;

reg clk = 1'b0;
always #10 clk = ~clk; // 50 MHz, the chipset

reg reset = 1'b1;   // areset
reg pc_reset = 1'b1;
reg hdd0_image = 1'b1;
integer errors = 0;
task check(input [255:0] what, input [31:0] got, input [31:0] exp);
	if (got !== exp) begin
		errors = errors + 1;
		if (errors < 30) $display("%t ERROR %0s: %0x, expected %0x", $time, what, got, exp);
	end
endtask

// ---------------- the XT bus and XT2IDE ----------------

reg [4:0] xa = 5'd0;
reg io_read_n = 1'b1, io_write_n = 1'b1;
reg [7:0] xdin = 8'd0;
wire [7:0] xdout;
wire iorq = ~io_read_n | ~io_write_n;
wire xcs_n = ~iorq; // ports 300h-31Fh: the address is always ours here

wire cs1fx, cs3fx, ide_rd_n, ide_wr_n;
wire [2:0] ide_a;
wire [15:0] ide_to_disk, ide_from_disk;

XT2IDE xt2ide(
	.clock(clk), .reset(reset), .high_speed(1'b0),
	.chip_select_n(xcs_n), .io_read_n(io_read_n), .io_write_n(io_write_n),
	.address(xa), .data_bus_in(xdin), .data_bus_out(xdout),
	.ide_cs1fx(cs1fx), .ide_cs3fx(cs3fx), .ide_io_read_n(ide_rd_n), .ide_io_write_n(ide_wr_n),
	.ide_address(ide_a), .ide_data_bus_in(ide_from_disk), .ide_data_bus_out(ide_to_disk)
);

// an I/O cycle of the 8088 with wait states: the strobe is 8 clocks of 50 MHz (160 ns), the CPU
// takes the read data in the last clock of the strobe
task io_wr(input [4:0] port, input [7:0] d);
	begin
		@(negedge clk); xa <= port; xdin <= d;
		@(negedge clk); io_write_n <= 1'b0;
		repeat (8) @(negedge clk);
		io_write_n <= 1'b1;
		repeat (6) @(negedge clk);
	end
endtask
reg [7:0] rbyte;
task io_rd(input [4:0] port);
	begin
		@(negedge clk); xa <= port;
		@(negedge clk); io_read_n <= 1'b0;
		repeat (7) @(negedge clk);
		@(posedge clk); rbyte = xdout;
		@(negedge clk); io_read_n <= 1'b1;
		repeat (6) @(negedge clk);
	end
endtask
reg [15:0] rdata;
task rd_reg(input [2:0] r); begin io_rd({ 2'b00, r }); rdata = { 8'h00, rbyte }; end endtask
task rd_word; begin io_rd(5'd0); rdata[7:0] = rbyte; io_rd(5'd8); rdata[15:8] = rbyte; end endtask
task wr_reg(input [2:0] r, input [7:0] d); io_wr({ 2'b00, r }, d); endtask

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
	.clk(clk), .areset(reset), .hdd0_image(hdd0_image),
	.sys_cs_n({ cs3fx, cs1fx }), .sys_rd_n(ide_rd_n), .sys_wr_n(ide_wr_n), .sys_a(ide_a),
	.sys_dout(ide_to_disk), .sys_din(ide_from_disk), .sys_reset_n(~pc_reset),
	.fdd_mgmt_address(), .fdd_mgmt_fddn(), .fdd_mgmt_write(), .fdd_mgmt_writedata(),
	.fdd_mgmt_read(), .fdd_mgmt_readdata(16'h0000), .fdd_request(2'b00),
	.cf_cs_n(), .cf_rd_n(), .cf_wr_n(), .cf_a(), .cf_d(cf_d), .cf_reset_n(),
	.img_mounted(img_mounted), .img_size(img_size),
	.img_data_wr(img_data_wr), .img_data_addr(img_data_addr), .img_data(img_data),
	.img_result_wr(img_result_wr), .img_result(img_result), .img_sum(img_sum),
	.img_q_wr(img_q_wr), .img_q_di(img_q_di), .img_q_ack(img_q_ack)
);
// the CF card is not there: its data lines float high (pull-ups)
assign (weak1, weak0) cf_d = 16'hFFFF;

localparam DISK_SECTORS = 2000;
function [7:0] dbyte(input [7:0] slot, input [31:0] lba, input [8:0] i);
	dbyte = lba[7:0] ^ i[7:0] ^ 8'h5A ^ { 7'd0, i[8] } ^ { slot[2:0], 5'd0 };
endfunction
integer mcu_reads = 0;

reg [31:0] q_lba = 0;
reg [7:0] q_slot = 0, q_op = 0;
reg q_sec = 0;
always @(posedge clk) begin
	img_q_ack <= 1'b0;
	if (img_q_wr && !img_q_ack) begin
		img_q_ack <= 1'b1;
		case (img_q_di[23:16])
			8'h42: q_lba[img_q_di[9:8]*8 +: 8] = img_q_di[7:0];
			8'h43: begin q_slot = img_q_di[15:8]; q_op = img_q_di[7:0]; q_sec = 1; end
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
integer k;
reg [15:0] s;
initial begin : mcu_model
	forever begin
		@(posedge clk);
		if (q_sec && q_op == 8'd1) begin
			q_sec = 0;
			#20000;
			mcu_reads = mcu_reads + 1;
			s = 0;
			for (k = 0; k < 512; k = k + 1) begin
				b = dbyte(q_slot, q_lba, k);
				s = s + b;
				@(posedge clk); img_data_wr <= 1'b1; img_data_addr <= k; img_data <= b;
				@(posedge clk); img_data_wr <= 1'b0;
			end
			img_sum <= s;
			mcu_result(8'd1);
		end
	end
end

task mount(input [2:0] slot, input [63:0] size);
	begin
		@(posedge clk); img_size <= size; img_mounted <= 8'h01 << slot;
		@(posedge clk); img_mounted <= 8'h00;
	end
endtask

// ---------------- the BIOS ----------------

task wait_bsy;
	integer n;
	begin
		n = 0;
		rd_reg(3'd7);
		while (rdata[7] && n < 100000) begin rd_reg(3'd7); n = n + 1; end
		if (rdata[7]) begin $display("%t ERROR BSY stays", $time); errors = errors + 1; end
	end
endtask

integer id_heads = 0, id_spt = 0;
task identify(input [7:0] devhead);
	begin
		wr_reg(3'd6, devhead);
		wait_bsy; // the selected device may still examine its image
		wr_reg(3'd7, 8'hEC);
		wait_bsy;
		for (k = 0; k < 256; k = k + 1) begin
			rd_word;
			if (k == 3) id_heads = rdata;
			if (k == 6) id_spt = rdata;
		end
	end
endtask

task ataread(input [7:0] slot, input [31:0] lba, input chs, input [255:0] what);
	integer n, i;
	reg [15:0] w;
	integer bad;
	integer c, h, sec;
	reg [7:0] dev;
	begin
		dev = slot[0] ? 8'h10 : 8'h00;
		wait_bsy;
		if (chs) begin
			sec = lba % id_spt + 1;
			h = (lba / id_spt) % id_heads;
			c = lba / (id_spt * id_heads);
			wr_reg(3'd6, 8'hA0 | dev | h[3:0]);
			wr_reg(3'd2, 8'd1);
			wr_reg(3'd3, sec[7:0]);
			wr_reg(3'd4, c[7:0]);
			wr_reg(3'd5, c[15:8]);
		end
		else begin
			wr_reg(3'd6, 8'hE0 | dev | lba[27:24]);
			wr_reg(3'd2, 8'd1);
			wr_reg(3'd3, lba[7:0]);
			wr_reg(3'd4, lba[15:8]);
			wr_reg(3'd5, lba[23:16]);
		end
		wr_reg(3'd7, 8'h20);
		n = 0;
		rd_reg(3'd7);
		while ((rdata[7] || !(rdata[3] || rdata[0])) && n < 100000) begin rd_reg(3'd7); n = n + 1; end
		if (rdata[0] || !rdata[3]) begin
			rd_reg(3'd1);
			$display("%t ERROR %0s: lba %0d, error %02x", $time, what, lba, rdata[7:0]);
			errors = errors + 1;
		end
		else begin
			bad = 0;
			for (i = 0; i < 256; i = i + 1) begin
				rd_word;
				w = { dbyte(slot, lba, 2 * i + 1), dbyte(slot, lba, 2 * i) };
				if (rdata !== w) begin
					if (bad == 0) $display("%t %0s: word %0d %04x, expected %04x", $time, what, i, rdata, w);
					bad = bad + 1;
				end
			end
			check(what, bad, 0);
			rd_reg(3'd7);
			check({ what, " status after" }, rdata[7:0] & 8'h89, 8'h00); // no BSY, DRQ, ERR
		end
	end
endtask

integer r0;
initial begin
	repeat (10) @(posedge clk);
	reset <= 1'b0;
	repeat (100) @(posedge clk);
	pc_reset <= 1'b0;

	// HDD0 = Image
	repeat (1000) @(posedge clk);
	r0 = mcu_reads;
	mount(3'd0, DISK_SECTORS * 512);
	wait (mcu_reads != r0); // the geometry read
	repeat (100) @(posedge clk);
	wait_bsy;

	identify(8'hA0);
	$display("geometry: %0d heads, %0d sectors", id_heads, id_spt);
	check("identify heads", id_heads, 16);
	check("identify sectors", id_spt, 63);

	r0 = mcu_reads;
	ataread(0, 0, 0, "read lba 0");
	ataread(0, 63, 0, "read lba 63");
	check("mcu reads", mcu_reads - r0, 2);
	ataread(0, id_heads * id_spt + 2 * id_spt + 4, 1, "read chs");
	ataread(0, id_heads * id_spt + 2 * id_spt + 4, 0, "read the chs sector by lba");

	// the reset of the PC (OSD Reset): the task file and the commands work again
	pc_reset <= 1'b1;
	repeat (5000) @(posedge clk);
	pc_reset <= 1'b0;
	repeat (100) @(posedge clk);
	identify(8'hA0);
	r0 = mcu_reads;
	ataread(0, 0, 0, "read lba 0 after reset");
	check("mcu reads after reset", mcu_reads - r0, 1);

	// HDD0 = CF card, the HDD1 image is device 1
	hdd0_image <= 1'b0;
	r0 = mcu_reads;
	mount(3'd1, DISK_SECTORS * 512);
	wait (mcu_reads != r0);
	repeat (100) @(posedge clk);
	identify(8'hB0);
	check("identify dev 1 heads", id_heads, 16);
	ataread(1, 5, 0, "read dev 1 lba 5");
	// device 0 is the card now: hdf_ata must not answer, the data lines are the card's
	wr_reg(3'd6, 8'hE0);
	rd_reg(3'd7);
	check("dev 0 status from the card", rdata[7:0], 8'hFF);

	$display("tb_disks: %0d errors", errors);
	$finish;
end

initial begin
	#200000000;
	$display("ERROR timeout");
	$display("tb_disks: %0d errors", errors + 1);
	$finish;
end

endmodule
