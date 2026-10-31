`timescale 1ns / 1ns
// KF8237 + READY (Ready.v) + the floppy glue of Peripherals.v (a copy) + floppy.v: a read of 1
// sector by DMA channel 2 as the BIOS does it, with the refresh on channel 0; the sector comes into
// the fifo through mgmt (as pcxt_fdd). The bus goes to the DMA between CPU cycles only.
// The KF8237 before MiSTer fc23647 lost the TC in the wait states of Ready.v: the read never ended
// (on hardware: endless sector reads). Run: sim/run_dma_sim.sh, ends with "tb_dma_fdd: 0 errors".
module tb_dma_fdd;
reg clk = 0; always #10 clk = ~clk;
reg cpu_clock = 0; integer cdiv = 0;
always @(posedge clk) begin cdiv = cdiv + 1; if (cdiv == 5) begin cdiv = 0; cpu_clock <= ~cpu_clock; end end
reg prev_cpu_clock = 0; always @(posedge clk) prev_cpu_clock <= cpu_clock;
wire cpu_clock_negedge = prev_cpu_clock & ~cpu_clock;
reg reset = 1;
reg cs_n = 1, iow_n = 1; reg [3:0] a = 0; reg [7:0] d = 0;
wire [3:0] dreq; wire hrq; wire [3:0] dack_n; wire eop_n; wire [7:0] dout;
wire ior_o, iow_o, ior_io, iow_io, memr_n, memw_n, aen, adstb, hiaddr; wire [15:0] ao;
// the bus goes to the DMA between CPU cycles only
reg cpu_busy = 0;
reg hlda = 0; always @(posedge cpu_clock) hlda <= hrq & (hlda | ~cpu_busy);
reg drq0 = 0;
wire dma_ready;
READY u_ready(.clock(clk), .cpu_clock(cpu_clock), .reset(reset), .processor_ready(), .dma_ready(dma_ready),
	.dma_wait_n(1'b1), .io_channel_ready(1'b1), .io_read_n(io_read_n), .io_write_n(iow_io ? iow_n : iow_o),
	.memory_read_n(memr_n), .dma0_acknowledge_n(dack_n[0]), .address_enable_n(~hlda));
KF8237 u(.clock(clk), .cpu_clock(cpu_clock), .reset(reset), .chip_select_n(cs_n), .ready(dma_ready),
	.hold_acknowledge(hlda), .dma_request(dreq), .data_bus_in(d), .data_bus_out(dout),
	.io_read_n_in(1'b1), .io_read_n_out(ior_o), .io_read_n_io(ior_io),
	.io_write_n_in(iow_n), .io_write_n_out(iow_o), .io_write_n_io(iow_io),
	.end_of_process_n_in(1'b1), .end_of_process_n_out(eop_n), .address_in(a), .address_out(ao),
	.output_highst_address(hiaddr), .hold_request(hrq), .dma_acknowledge(dack_n),
	.address_enable(aen), .address_strobe(adstb), .memory_read_n(memr_n), .memory_write_n(memw_n));
wire io_read_n = ior_io ? 1'b1 : ior_o;   // the bus: the 8237 drives IOR during its cycles

// ---- the glue of Peripherals.v (FLOPPY) ----
wire fdd_dma_ack = ~dack_n[2];
wire terminal_count = ~eop_n;
reg prev_fdd_dma_ack = 0; always @(posedge clk) prev_fdd_dma_ack <= fdd_dma_ack;
wire fdd_dma_rw_ack = prev_fdd_dma_ack & ~fdd_dma_ack;
reg fdd_dma_tc = 0;
always @(posedge clk)
	if (fdd_dma_ack) begin if (~fdd_dma_tc) fdd_dma_tc <= terminal_count; end
	else fdd_dma_tc <= 1'b0;
wire fdd_dma_req_wire; reg fdd_dma_req_r = 0;
always @(posedge clk)
	if (fdd_dma_ack) fdd_dma_req_r <= 1'b0;
	else if (cpu_clock_negedge) fdd_dma_req_r <= fdd_dma_req_wire;
assign dreq = {1'b0, fdd_dma_req_r, 1'b0, drq0};
integer rt = 0;
always @(posedge clk) begin rt = rt + 1; if (rt == 750) begin rt = 0; drq0 <= 1; end if (!dack_n[0]) drq0 <= 0; end

reg [2:0] io_address = 0; reg io_read = 0, io_write = 0; reg [7:0] io_writedata = 0; wire [7:0] io_readdata;
wire irq; wire [7:0] dma_writedata;
reg [3:0] mgmt_address = 0; reg mgmt_write = 0; reg [15:0] mgmt_writedata = 0; reg mgmt_fddn = 0;
wire [15:0] mgmt_readdata; wire [1:0] request;
floppy fdc(.clk(clk), .rst_n(~reset),
	.dma_req(fdd_dma_req_wire), .dma_ack(fdd_dma_rw_ack), .dma_tc(fdd_dma_tc & fdd_dma_rw_ack),
	.dma_readdata(8'h00), .dma_writedata(dma_writedata), .irq(irq),
	.io_address(io_address), .io_read(io_read), .io_readdata(io_readdata), .io_write(io_write), .io_writedata(io_writedata),
	.fdd0_inserted(), .mgmt_address(mgmt_address), .mgmt_fddn(mgmt_fddn), .mgmt_write(mgmt_write),
	.mgmt_writedata(mgmt_writedata), .mgmt_read(1'b0), .mgmt_readdata(mgmt_readdata),
	.wp(2'b00), .clock_rate(28'd50000000), .request(request));

integer sectors = 0, bytes = 0, tcs = 0, bad_addr = 0;
reg [15:0] dma_start = 16'h7C00;
reg [15:0] last_ao = 0;
// the address of each byte (the 8237 outputs it during DACK): dma_start + n
always @(posedge clk) begin
	if (fdd_dma_ack) last_ao <= ao;
	if (fdd_dma_rw_ack) begin
		if (last_ao !== dma_start + bytes[15:0]) begin
			if (bad_addr < 4) $display("ERROR byte %0d at %h, expected %h", bytes, last_ao, dma_start + bytes[15:0]);
			bad_addr = bad_addr + 1;
		end
		bytes = bytes + 1;
	end
	if (fdd_dma_tc & fdd_dma_rw_ack) tcs = tcs + 1;
end
// pcxt_fdd: a sector into the fifo for each read request
initial begin : feeder
	integer k;
	forever begin
		@(posedge clk);
		if (request[0]) begin
			sectors = sectors + 1;
			repeat (100) @(posedge clk);
			for (k = 0; k < 512; k = k + 1) begin
				@(posedge clk); mgmt_address <= 15; mgmt_writedata <= k; mgmt_write <= 1;
				@(posedge clk); mgmt_write <= 0;
			end
			while (request[0]) @(posedge clk);
		end
	end
end

task wr8237(input [3:0] r, input [7:0] v);
	begin
		@(posedge cpu_clock); while (hlda || hrq) @(posedge cpu_clock);
		cpu_busy <= 1; a <= r; d <= v; cs_n <= 0;
		@(posedge cpu_clock); iow_n <= 0;
		@(posedge cpu_clock); @(posedge cpu_clock); iow_n <= 1;
		@(posedge cpu_clock); cs_n <= 1; cpu_busy <= 0;
	end
endtask
task fdc_wr(input [2:0] r, input [7:0] v);
	begin @(posedge clk); io_address <= r; io_writedata <= v; io_write <= 1; @(posedge clk); io_write <= 0; repeat (20) @(posedge clk); end
endtask
task mgmt(input [3:0] r, input [15:0] v);
	begin @(posedge clk); mgmt_address <= r; mgmt_writedata <= v; mgmt_write <= 1; @(posedge clk); mgmt_write <= 0; end
endtask

initial begin
	repeat (20) @(posedge clk); reset = 0;
	mgmt(1, 0); mgmt(2, 80); mgmt(3, 18); mgmt(4, 2880); mgmt(5, 2); mgmt(0, 1);
	wr8237(4'hD, 0); wr8237(4'h8, 0); wr8237(4'hB, 8'h58); wr8237(4'h1, 8'hFF); wr8237(4'h1, 8'hFF); wr8237(4'hA, 0);
	fdc_wr(2, 8'h1C);
	fdc_wr(5, 8'h03); fdc_wr(5, 8'hDF); fdc_wr(5, 8'h02);
	// the BIOS: DMA ch2 512 bytes, then read C0 H0 R1, EOT 18
	wr8237(4'hB, 8'h46); wr8237(4'hC, 0); wr8237(4'h5, 8'hFF); wr8237(4'h5, 8'h01);
	if ($test$plusargs("addr0")) dma_start = 16'h0000;
	wr8237(4'hC, 0); wr8237(4'h4, dma_start[7:0]); wr8237(4'h4, dma_start[15:8]); wr8237(4'hA, 8'h02);
	fdc_wr(5, 8'hE6); fdc_wr(5, 8'h00); fdc_wr(5, 0); fdc_wr(5, 0); fdc_wr(5, 1); fdc_wr(5, 2); fdc_wr(5, 18); fdc_wr(5, 8'h1B); fdc_wr(5, 8'hFF);
	repeat (100000) @(posedge clk);
	$display("wire %b dreq %b hrq %b hlda %b dack %b exec_ndma %b has_term %b irq_en %b fifo_empty %b mask %b", fdd_dma_req_wire, dreq, hrq, hlda, dack_n, fdc.execute_ndma, fdc.dma_has_terminated, fdc.dma_irq_enable, fdc.fifo_empty, u.u_Priority_Encoder.mask_register);
	repeat (400000) @(posedge clk);
	$display("sectors %0d, DMA bytes %0d, TC to floppy %0d, irq %b, fdc state %0d (expected 1 / 512 / 1 / 1)", sectors, bytes, tcs, irq, fdc.state);
	$display("start %h: %0d bytes at a wrong address", dma_start, bad_addr);
	$display("tb_dma_fdd: %0d errors", (sectors != 1) + (bytes != 512) + (tcs != 1) + (irq != 1'b1) + (fdc.state != 0) + (bad_addr != 0));
	$finish;
end
endmodule
