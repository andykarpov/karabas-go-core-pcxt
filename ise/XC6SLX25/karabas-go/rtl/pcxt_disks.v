`timescale 1ns / 1ns
`default_nettype wire

/*
 pcxt_disks.v

 The disks behind the XT-IDE of system (XT2IDE, the 16-bit side, PHYSICAL_IDE): the CF card on the
 W* pins and hdf_ata (karabas-go-modules), the image disks of the mcu file mounter through
 img_sdc, slots 0 (HDD0) and 1 (HDD1).
 - hdd0_image = 0: the card is device 0, the HDD1 image device 1 (the card ignores the commands
   for device 1); the read data comes from the card while DEV of the task file is 0.
 - hdd0_image = 1: the card gets no chip select, the images are devices 0 and 1.
 - hdf_ata does a register access at the end of its strobe, but the chip select of XT2IDE ends
   with the strobe (iorq of Peripherals.v is io_read_n | io_write_n): the strobes reach hdf_ata a
   clock later, with chip select, address and write data latched while they are low.
 Simulation: sim/run_disks_sim.sh (tb_disks.v).
*/

module pcxt_disks (
	input wire clk,             // the clock of the chipset (clk_50)
	input wire areset,
	input wire hdd0_image,

	// the IDE bus of system (XT2IDE)
	input wire [1:0] sys_cs_n,  // [0] CS1FX (command block), [1] CS3FX (control block)
	input wire sys_rd_n,
	input wire sys_wr_n,
	input wire [2:0] sys_a,
	input wire [15:0] sys_dout,
	output wire [15:0] sys_din,
	input wire sys_reset_n,

	// the CF card
	output wire [1:0] cf_cs_n,
	output wire cf_rd_n,
	output wire cf_wr_n,
	output wire [2:0] cf_a,
	inout wire [15:0] cf_d,
	output wire cf_reset_n,

	// the file mounter of kg_mcu
	input wire [7:0] img_mounted,
	input wire [63:0] img_size,
	input wire img_data_wr,
	input wire [8:0] img_data_addr,
	input wire [7:0] img_data,
	input wire img_result_wr,
	input wire [7:0] img_result,
	input wire [15:0] img_sum,
	output wire img_q_wr,
	output wire [23:0] img_q_di,
	input wire img_q_ack
);

// the CF card: the bus of XT2IDE as before, off with HDD0 = Image
assign cf_cs_n = hdd0_image ? 2'b11 : sys_cs_n;
assign cf_rd_n = sys_rd_n;
assign cf_wr_n = sys_wr_n;
assign cf_a = sys_a;
assign cf_d = ~sys_wr_n ? sys_dout : 16'hZZZZ;
assign cf_reset_n = sys_reset_n;

// hdf_ata does a register access at the end of its strobe, but the chip select of XT2IDE ends
// with the strobe (iorq of Peripherals is io_read_n | io_write_n): the strobes reach hdf_ata a
// clock later, with chip select, address and write data latched while they are low
reg [1:0] hd_cs_n = 2'b11;
reg [2:0] hd_a = 3'd0;
reg [15:0] hd_din = 16'h0;
reg hd_rd_n = 1'b1, hd_wr_n = 1'b1;
always @(posedge clk) begin
	hd_rd_n <= sys_rd_n;
	hd_wr_n <= sys_wr_n;
	if (~sys_rd_n | ~sys_wr_n) begin
		hd_cs_n <= sys_cs_n;
		hd_a <= sys_a;
		hd_din <= sys_dout;
	end
end

wire [7:0] sdc_img_mounted;
wire [63:0] sdc_img_size;
wire [1:0] hdf_rd, hdf_wr;
wire [31:0] hdf_sector;
wire sdc_busy, sdc_done, sdc_error;
wire [2:0] sdc_slot;
wire sdc_byte_in_strobe;
wire [8:0] sdc_byte_addr;
wire [7:0] sdc_byte_in_data;
wire [7:0] hdf_byte_out_data;

img_sdc #(
	.OUT_LATENCY(3),
	.TIMEOUT(24'd10000000), // 200 ms at 50 MHz
	.RETRIES(2'd3)
) u_img_sdc(
	.clk(clk),
	.reset(areset),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_data_wr(img_data_wr),
	.img_data_addr(img_data_addr),
	.img_data(img_data),
	.img_result_wr(img_result_wr),
	.img_result(img_result),
	.img_sum(img_sum),
	.img_q_wr(img_q_wr),
	.img_q_di(img_q_di),
	.img_q_ack(img_q_ack),

	.sdc_img_mounted(sdc_img_mounted),
	.sdc_img_size(sdc_img_size),
	.sdc_rd({6'b000000, hdf_rd}),
	.sdc_wr({6'b000000, hdf_wr}),
	.sdc_sector(hdf_sector),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_byte_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_byte_in_data),
	.sdc_byte_out_data(hdf_byte_out_data),
	.active()
);

wire [15:0] hdf_dout;
wire hdf_dev;
wire hdf_own = (sdc_slot < 3'd2);

hdf_ata #(
	.DEF_HEADS(5'd16),
	.DEF_SPT(8'd63),
	.SYNC_BUS(0)
) u_hdf_ata(
	.clk(clk),
	.reset(areset),
	.ata_reset(~sys_reset_n), // the reset of the PC
	.dev0_en(hdd0_image),
	.dev(hdf_dev),
	.dev1_here(),

	.a(hd_a),
	.cs_n(hd_cs_n),
	.rd_n(hd_rd_n),
	.wr_n(hd_wr_n),
	.din(hd_din),
	.dout(hdf_dout),

	.img_mounted(sdc_img_mounted[1:0]),
	.img_size(sdc_img_size),
	.sdc_rd(hdf_rd),
	.sdc_wr(hdf_wr),
	.sdc_sector(hdf_sector),
	.sdc_busy(sdc_busy & hdf_own),
	.sdc_done(sdc_done & hdf_own),
	.sdc_error(sdc_error),
	.sdc_byte_in_strobe(sdc_byte_in_strobe & hdf_own),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_byte_in_data),
	.sdc_byte_out_data(hdf_byte_out_data),
	.led()
);

// read data: the images, or the card while it is device 0
assign sys_din = (hdd0_image | hdf_dev) ? hdf_dout : cf_d;
endmodule
