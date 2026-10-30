`timescale 1ns / 1ns
`default_nettype wire

/*
 karabas_pcxt.v

 The PC/XT of the three Karabas boards: system (HW/system.v) with the MCU link of
 karabas-go-modules (kg_mcu), the soft switches of the OSD items (core*.json), the OSD overlay
 and the USB mouse as a serial mouse on COM1. The board tops add the clocks, the video out
 (VGA or HDMI) and the audio DAC.

 Soft switch n = OSD item n of core*.json:
   0 Video mode (RGB / VGA)   1 Turbo   2 HDD0 (CF card / Image)
   3 HDD0 image (file slot 0, no value)   4 HDD1 image (file slot 1, no value)
   5 Reset (a pulse of the firmware: resets the whole PC, as after the splash screen)

 Disks (PHYSICAL_IDE): the XT-IDE of system (XT2IDE, ports 300h) talks to the CF card on the W*
 pins and to hdf_ata, the image disks of the file mounter (img_sdc, slots 0 and 1). HDD0 = CF
 card: the card is device 0, the HDD1 image device 1 (the card ignores the commands for device 1);
 the read data comes from the card while DEV = 0. HDD0 = Image: the card is off (no chip select),
 the images are devices 0 and 1.
*/

module karabas_pcxt #(
	parameter BURST_MAX_MHZ = 0 // see kg_mcu
) (
	input wire clk_100,
	input wire clk_50,          // chipset, MCU link
	input wire clk_vga,         // 28.571 MHz
	input wire areset,

	// sram
	output wire [20:0] sram_a,
	inout wire [7:0] sram_d,
	output wire sram_we_n,

	// cf card (PHYSICAL_IDE) or sd card
	output wire [1:0] ide_cs_n,
	output wire ide_rd_n,
	output wire ide_wr_n,
	output wire [2:0] ide_a,
	inout wire [15:0] ide_d,
	output wire ide_reset_n,
	output wire sd_cs_n,
	output wire sd_di,
	output wire sd_clk,
	input wire sd_do,

	// mcu
	input wire mcu_cs_n,
	input wire mcu_sck,
	input wire mcu_mosi,
	output wire mcu_miso,
	input wire mcu_burst_cs_n,
	output wire mcu_burst_ready,

	// video (clk_vga), the OSD over it
	output wire [23:0] vga_rgb,
	output wire vga_hs,
	output wire vga_vs,
	output wire dvi_only,       // in clk_vga

	// audio (two's complement, clk_50)
	output wire [15:0] audio_l,
	output wire [15:0] audio_r,

	output wire kb_reset
);

`include "config.vh"

//---------- PCXT ------------

wire [5:0] r, g, b;
wire hs, vs;
wire serial_mouse_tx, serial_mouse_rts;
wire kb_swap_video, kb_turbo_mode;
wire [7:0] xt_scancode;
wire xt_scancode_upd;
wire [15:0] aud_l, aud_r;
wire [1:0] sys_ide_cs_n;
wire sys_ide_rd_n, sys_ide_wr_n, sys_ide_reset_n;
wire [2:0] sys_ide_a;
wire [15:0] sys_ide_dout, sys_ide_din;

system sys_inst
(
	.clk_100(clk_100),
	.clk_chipset(clk_50),
	.clk_vga(clk_vga),

	.VGA_R(r),
	.VGA_G(g),
	.VGA_B(b),
	.VGA_HSYNC(hs),
	.VGA_VSYNC(vs),

	.SRAM_ADDR(sram_a),
	.SRAM_DATA(sram_d),
	.SRAM_WE_n(sram_we_n),

	.kb_scancode(xt_scancode),
	.kb_scancode_upd(xt_scancode_upd),

	.serial_mouse_tx(serial_mouse_tx),
	.serial_mouse_rts(serial_mouse_rts),

	.AUD_L(aud_l),
	.AUD_R(aud_r),

`ifdef PHYSICAL_IDE
	.ide_cs_n(sys_ide_cs_n),
	.ide_rd_n(sys_ide_rd_n),
	.ide_wr_n(sys_ide_wr_n),
	.ide_a(sys_ide_a),
	.ide_dout(sys_ide_dout),
	.ide_din(sys_ide_din),
	.ide_reset_n(sys_ide_reset_n),
`endif
	.btn_green_n_i(~kb_swap_video),
	.btn_yellow_n_i(~kb_turbo_mode),
	.reset_in(kb_reset | areset)
);

`ifdef PHYSICAL_IDE
	assign sd_cs_n = 1'b1;
	assign sd_di = 1'b1;
	assign sd_clk = 1'b0;
`else
	assign ide_cs_n = 2'b11;
	assign ide_rd_n = 1'b1;
	assign ide_wr_n = 1'b1;
	assign ide_a = 3'b000;
	assign ide_d = 16'hZZZZ;
	assign ide_reset_n = 1'b1;
`endif

//---------- MCU ------------

wire [7:0] ms_x, ms_y;
wire [2:0] ms_b;
wire ms_upd;
wire [15:0] softsw_command, osd_command;
wire mcu_dvi_only;

wire [7:0] img_mounted;
wire [63:0] img_size;
wire img_data_wr;
wire [8:0] img_data_addr;
wire [7:0] img_data;
wire img_result_wr;
wire [7:0] img_result;
wire [15:0] img_sum;
wire img_q_wr;
wire [23:0] img_q_di;
wire img_q_ack;

kg_mcu #(
	.BURST_MAX_MHZ(BURST_MAX_MHZ),
	.CS_FILTER(3),
	.ENABLE_RTC(0),
	.ENABLE_UART(0),
	.ENABLE_MATRIX(0),
	.ENABLE_DEBUG(0),
	.ENABLE_IMG(1),
	.ENABLE_FILE(0),
	.ENABLE_FT(0),
	.ENABLE_SD2(0),
	.ENABLE_ESP(0),
	.ENABLE_PS2_CMD(0),
	.ENABLE_FLASHBOOT(0)
) mcu(
	.CLK(clk_50),
	.N_RESET(~areset),

	.MCU_MOSI(mcu_mosi),
	.MCU_MISO(mcu_miso),
	.MCU_SCK(mcu_sck),
	.MCU_SS(mcu_cs_n),
	.MCU_SPI_FT_SS(1'b1),
	.MCU_SPI_SD2_SS(1'b1),
	.MCU_BURST_CS_N(mcu_burst_cs_n),
	.MCU_BURST_READY(mcu_burst_ready),

	.MS_X(ms_x),
	.MS_Y(ms_y),
	.MS_Z(),
	.MS_B(ms_b),
	.MS_UPD(ms_upd),

	.KB_STATUS(),
	.KB_DAT0(), .KB_DAT1(), .KB_DAT2(), .KB_DAT3(), .KB_DAT4(), .KB_DAT5(),
	.KB_SCANCODE(),
	.KB_SCANCODE_UPD(),
	.XT_SCANCODE(xt_scancode),
	.XT_SCANCODE_UPD(xt_scancode_upd),
	.PS2_COMMAND(16'h0),
	.PS2_COMMAND_WR(1'b0),

	.JOY_L(),
	.JOY_R(),
	.BTNS(),

	.RTC_A(8'h0),
	.RTC_DI(8'h0),
	.RTC_DO(),
	.RTC_CS(1'b0),
	.RTC_WR_N(1'b1),

	.UART_RX_DATA(),
	.UART_RX_IDX(),
	.UART_TX_DATA(8'h0),
	.UART_TX_WR(1'b0),
	.UART_TX_MODE(1'b0),
	.UART_DLM(8'h0),
	.UART_DLL(8'h0),
	.UART_DLM_WR(1'b0),
	.UART_DLL_WR(1'b0),

	.SOFTSW_COMMAND(softsw_command),
	.OSD_COMMAND(osd_command),

	.ROMLOADER_ACTIVE(),
	.ROMLOAD_ADDR(),
	.ROMLOAD_DATA(),
	.ROMLOAD_WR(),
	.IOCTL_ACTIVE(),

	.FILELOAD_RESET(),
	.FILELOAD_ACTIVE(),
	.FILELOAD_SIZE(),
	.FILELOAD_ADDR(),
	.FILELOAD_DATA(),
	.FILELOAD_WR(),

	.FT_SPI_ON(),
	.FT_VGA_ON(),
	.FT_RESET(),
	.FT_SCK(),
	.FT_MOSI(),
	.FT_MISO(1'b1),
	.FT_CS_N(),

	.SD2_SCK(),
	.SD2_MOSI(),
	.SD2_MISO(1'b1),
	.SD2_CS_N(),

	.MATRIX_CMD(24'h0),
	.MATRIX_CMD_WR(1'b0),
	.DEBUG_ADDR(16'h0),
	.DEBUG_DATA(16'h0),

	.HWID(),
	.DVI_ONLY(mcu_dvi_only),

	.IMG_MOUNTED(img_mounted),
	.IMG_SIZE(img_size),
	.IMG_DATA_WR(img_data_wr),
	.IMG_DATA_ADDR(img_data_addr),
	.IMG_DATA(img_data),
	.IMG_RESULT_WR(img_result_wr),
	.IMG_RESULT(img_result),
	.IMG_SUM(img_sum),
	.IMG_Q_WR(img_q_wr),
	.IMG_Q_DI(img_q_di),
	.IMG_Q_ACK(img_q_ack),
	.IMG_PHYS_WR(),
	.IMG_PHYS(),
	.IMG_FLUSH(),

	.ESP_UART_TX_DATA(),
	.ESP_UART_TX_WR(),
	.ESP_UART_RX_DATA(8'h0),
	.ESP_UART_RX_WR(1'b0),
	.ESP_UART_RX_ACK(),

	.FLASHBOOT_START(1'b0),
	.FLASHBOOT_COREID(5'd0),

	.BUSY()
);

kg_sync #(.W(1)) u_sync_dvi(
	.clk(clk_vga),
	.d(mcu_dvi_only),
	.q(dvi_only)
);

//---------- Serial mouse ------------

hid_parser hid_parser(
	.CLK(clk_50),
	.RESET(areset),

	.MS_X(ms_x),
	.MS_Y(ms_y),
	.MS_B(ms_b),
	.MS_UPD(ms_upd),

	.MOUSE_TX(serial_mouse_tx),
	.MOUSE_RTS(serial_mouse_rts)
);

//---------- Soft switches ------------

// register n = OSD item n of core*.json; the file items (3, 4) have no value
wire [47:0] softsw_regs;
kg_soft_switches #(
	.N(6),
	.INIT(48'h00_00_00_01_00_01)
) u_softsw(
	.clk(clk_50),
	.command(softsw_command),
	.regs(softsw_regs),
	.upd()
);

wire kb_hdd0_image;
assign kb_swap_video = softsw_regs[0*8];
assign kb_turbo_mode = softsw_regs[1*8];
assign kb_hdd0_image = softsw_regs[2*8];
assign kb_reset      = softsw_regs[5*8];

`ifdef PHYSICAL_IDE
//---------- Disks: CF card and images ------------

pcxt_disks disks(
	.clk(clk_50),
	.areset(areset),
	.hdd0_image(kb_hdd0_image),

	.sys_cs_n(sys_ide_cs_n),
	.sys_rd_n(sys_ide_rd_n),
	.sys_wr_n(sys_ide_wr_n),
	.sys_a(sys_ide_a),
	.sys_dout(sys_ide_dout),
	.sys_din(sys_ide_din),
	.sys_reset_n(sys_ide_reset_n),

	.cf_cs_n(ide_cs_n),
	.cf_rd_n(ide_rd_n),
	.cf_wr_n(ide_wr_n),
	.cf_a(ide_a),
	.cf_d(ide_d),
	.cf_reset_n(ide_reset_n),

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
	.img_q_ack(img_q_ack)
);
`else
assign img_q_wr = 1'b0;
assign img_q_di = 24'h0;
`endif


//---------- OSD ------------

// osd_command (clk_50) into clk_vga: a toggle handshake. The word holds after it changed, and the
// mcu sends a command per link frame (1.5 us at 16 MHz), so it is stable when clk_vga takes it.
reg [15:0] osd_word = 16'h0;
reg osd_tgl = 1'b0;
always @(posedge clk_50) begin
	if (osd_command != osd_word) begin
		osd_word <= osd_command;
		osd_tgl <= ~osd_tgl;
	end
end

wire osd_tgl_s;
kg_sync #(.W(1)) u_sync_osd(
	.clk(clk_vga),
	.d(osd_tgl),
	.q(osd_tgl_s)
);

reg osd_tgl_d = 1'b0;
reg [15:0] osd_cmd_vga = 16'h0;
always @(posedge clk_vga) begin
	osd_tgl_d <= osd_tgl_s;
	if (osd_tgl_s != osd_tgl_d)
		osd_cmd_vga <= osd_word;
end

kg_osd_overlay #(
	.H_OFFSET(120),
	.V_OFFSET(72)
) overlay(
	.clk(clk_vga),
	.rgb_i({r, 2'b00, g, 2'b00, b, 2'b00}),
	.rgb_o(vga_rgb),
	.hsync_i(hs),
	.vsync_i(vs),
	.osd_command(osd_cmd_vga)
);

assign vga_hs = hs;
assign vga_vs = vs;

endmodule
