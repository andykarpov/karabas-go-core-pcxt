`timescale 1ns / 1ns
`default_nettype wire

/*
 karabas_pcxt.v

 The PC/XT of the three Karabas boards: system (rtl/system.v) with the MCU link of
 karabas-go-modules (kg_mcu), the soft switches of the OSD items (core*.json), the OSD overlay
 and the USB mouse as a serial mouse on COM1. The board tops add the clocks, the video out
 (VGA or HDMI) and the audio DAC.

 Soft switch n = OSD item n of core*.json:
   0 Video mode (RGB / VGA)   1 Turbo   2 HDD0 (CF card / Image)
   3 HDD0 image (file slot 0, no value)   4 HDD1 image (file slot 1, no value)
   5 FDD A image (file slot 2, no value)  6 FDD B image (file slot 3, no value)
   7 Reset (a pulse of the firmware: resets the whole PC, as after the splash screen)

 Disks (PHYSICAL_IDE): the XT-IDE of system (XT2IDE, ports 300h) talks to the CF card on the W*
 pins and to hdf_ata, the image disks of the file mounter (img_sdc, slots 0 and 1). HDD0 = CF
 card: the card is device 0, the HDD1 image device 1 (the card ignores the commands for device 1);
 the read data comes from the card while DEV = 0. HDD0 = Image: the card is off (no chip select),
 the images are devices 0 and 1.

 Floppies (FLOPPY): the floppy controller of system (floppy.v of MiSTer, ports 3F0h, DMA 2,
 IRQ 6, two drives) gets drives A and B from slots 2 and 3 of the file mounter (pcxt_fdd in
 pcxt_disks, on the management bus of floppy.v). PHYS_FDD (Karabas Go): a slot can be a physical
 drive of the floppy connector (pcxt_fdd_phys).
*/

module karabas_pcxt #(
	parameter BURST_MAX_MHZ = 0, // see kg_mcu
	parameter FB = 0,            // 1: the frame buffer in the SDRAM (Mini, Mini G: HDMI; Go: VGA), see below
	parameter FB_VGA = 0,        // with FB, 1: item 0 is RGB / VGA / Frame buffer (Go: the VGA output)
	parameter PHYS_FDD = 0       // 1: the physical floppy drives (Karabas Go), see pcxt_fdd_phys
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

	// the floppy connector (PHYS_FDD), at the pins: { rdata, wprt, tr00, index }, { wdata, wgate,
	// side1, step, dir, motor, ds1, ds0 }, high = active (inverters on the board)
	input wire [3:0] fdd_in,
	output wire [7:0] fdd_out,

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
	output wire vga_de,         // FB: the active picture of the frame buffer raster
	output wire fb_on,          // FB: the frame buffer path is selected (clk_vga)
	output wire dvi_only,       // in clk_vga

	// SDRAM (FB; tie off when FB = 0)
	output wire sdr_clk,
	output wire [12:0] sdr_a,
	output wire [1:0] sdr_ba,
	inout wire [15:0] sdr_dq,
	output wire [1:0] sdr_dqm,
	output wire sdr_ras_n,
	output wire sdr_cas_n,
	output wire sdr_we_n,

	// audio (two's complement, clk_50)
	output wire [15:0] audio_l,
	output wire [15:0] audio_r,

	output wire kb_reset,

	output wire midi_tx         // MPU-401 at 330h
);

`include "config.vh"

//---------- PCXT ------------

wire [5:0] r, g, b;
wire hs, vs;
wire [3:0] cga_video;
wire cga_hsync;
wire serial_mouse_tx, serial_mouse_rts;
wire kb_swap_video, kb_turbo_mode;
wire [7:0] xt_scancode;
wire xt_scancode_upd;
wire [15:0] aud_l, aud_r;
wire [1:0] sys_ide_cs_n;
wire sys_ide_rd_n, sys_ide_wr_n, sys_ide_reset_n;
wire [2:0] sys_ide_a;
wire [15:0] sys_ide_dout, sys_ide_din;
wire [3:0] fdd_mgmt_address;
wire fdd_mgmt_fddn, fdd_mgmt_write, fdd_mgmt_read;
wire [15:0] fdd_mgmt_writedata, fdd_mgmt_readdata;
wire [1:0] fdd_request;
wire [7:0] rtc_a, rtc_di, rtc_do;
wire [12:0] joy_l, joy_r;
wire [7:0] com2_rx_data, com2_rx_idx, com2_tx_data;
wire com2_tx_wr;
wire [7:0] prn_data;
wire prn_wr, prn_busy;
wire rtc_cs, rtc_wr_n;
wire romload_active, romload_wr;
wire [31:0] romload_addr;
wire [7:0] romload_data;

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
	.CGA_VIDEO(cga_video),
	.CGA_HSYNC(cga_hsync),

	.SRAM_ADDR(sram_a),
	.SRAM_DATA(sram_d),
	.SRAM_WE_n(sram_we_n),

	.kb_scancode(xt_scancode),
	.kb_scancode_upd(xt_scancode_upd),

	.serial_mouse_tx(serial_mouse_tx),
	.serial_mouse_rts(serial_mouse_rts),

	.AUD_L(aud_l),
	.AUD_R(aud_r),

	.ide_cs_n(sys_ide_cs_n),
	.ide_rd_n(sys_ide_rd_n),
	.ide_wr_n(sys_ide_wr_n),
	.ide_a(sys_ide_a),
	.ide_dout(sys_ide_dout),
	.ide_din(sys_ide_din),
	.ide_reset_n(sys_ide_reset_n),
	.btn_green_n_i(~kb_swap_video),
	.btn_yellow_n_i(~kb_turbo_mode),
	// the PC waits in reset while the mcu loads the BIOS / XTIDE BIOS (roms of core*.json)
	.reset_in(kb_reset | areset | romload_active)
	,.rom_wr(romload_wr && romload_addr[31:15] == 17'd0)
	,.rom_addr(romload_addr[14:0])
	,.rom_data(romload_data)
`ifdef FLOPPY
	,.fdd_mgmt_address(fdd_mgmt_address)
	,.fdd_mgmt_fddn(fdd_mgmt_fddn)
	,.fdd_mgmt_write(fdd_mgmt_write)
	,.fdd_mgmt_writedata(fdd_mgmt_writedata)
	,.fdd_mgmt_read(fdd_mgmt_read)
	,.fdd_mgmt_readdata(fdd_mgmt_readdata)
	,.fdd_request(fdd_request)
`endif
`ifdef MIDI_MPU401
	,.midi_tx(midi_tx)
`endif
`ifdef GAME_PORT
	,.joy0(joy_l)
	,.joy1(joy_r)
`endif
`ifdef LPT_USB
	,.prn_data(prn_data)
	,.prn_wr(prn_wr)
	,.prn_busy(prn_busy)
`endif
`ifdef COM2_USB
	,.com2_rx_data(com2_rx_data)
	,.com2_rx_idx(com2_rx_idx)
	,.com2_tx_wr(com2_tx_wr)
	,.com2_tx_data(com2_tx_data)
`endif
`ifdef RTC_MCU
	,.rtc_a(rtc_a)
	,.rtc_di(rtc_di)
	,.rtc_do(rtc_do)
	,.rtc_cs(rtc_cs)
	,.rtc_wr_n(rtc_wr_n)
`endif
);
`ifndef FLOPPY
assign fdd_mgmt_readdata = 16'h0000;
assign fdd_request = 2'b00;
`endif
`ifndef MIDI_MPU401
assign midi_tx = 1'b1;
`endif
`ifndef LPT_USB
assign prn_data = 8'h00;
assign prn_wr = 1'b0;
`endif
`ifndef COM2_USB
assign com2_tx_wr = 1'b0;
assign com2_tx_data = 8'h00;
`endif
`ifndef RTC_MCU
assign rtc_a = 8'h00;
assign rtc_di = 8'h00;
assign rtc_cs = 1'b0;
assign rtc_wr_n = 1'b1;
`endif

	assign sd_cs_n = 1'b1;
	assign sd_di = 1'b1;
	assign sd_clk = 1'b0;

//---------- Audio ------------

// the mix of system is combinational: a register in clk_50 before it leaves for the DAC / HDMI
// (zhdmi_top takes it into the pixel clock when two samples there are the same)
reg [15:0] audio_l_r = 16'h0, audio_r_r = 16'h0;
always @(posedge clk_50) begin
	audio_l_r <= aud_l;
	audio_r_r <= aud_r;
end
assign audio_l = audio_l_r;
assign audio_r = audio_r_r;

// level meters of the mcu (dot matrix): 2^20 clocks at 50 MHz = 21 ms
wire [23:0] matrix_cmd;
wire matrix_cmd_wr;
audio_peaks #(.PERIOD_BITS(20)) audio_peaks(
	.clk(clk_50),
	.audio_l(audio_l_r),
	.audio_r(audio_r_r),
	.cmd_wr(matrix_cmd_wr),
	.cmd(matrix_cmd)
);

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
wire img_phys_wr;
wire [15:0] img_phys;

kg_mcu #(
	.BURST_MAX_MHZ(BURST_MAX_MHZ),
	.CS_FILTER(3),
`ifdef RTC_MCU
	.ENABLE_RTC(1),
`else
	.ENABLE_RTC(0),
`endif
`ifdef LPT_USB
	.ENABLE_PRINTER(1),
`endif
`ifdef COM2_USB
	.ENABLE_UART(1),
`else
	.ENABLE_UART(0),
`endif
	.ENABLE_MATRIX(1),
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

	.JOY_L(joy_l),
	.JOY_R(joy_r),
	.BTNS(),

	.RTC_A(rtc_a),
	.RTC_DI(rtc_di),
	.RTC_DO(rtc_do),
	.RTC_CS(rtc_cs),
	.RTC_WR_N(rtc_wr_n),

	.PRN_DATA(prn_data),
	.PRN_WR(prn_wr),
	.PRN_BUSY(prn_busy),
	.UART_RX_DATA(com2_rx_data),
	.UART_RX_IDX(com2_rx_idx),
	.UART_TX_DATA(com2_tx_data),
	.UART_TX_WR(com2_tx_wr),
	.UART_TX_MODE(1'b0),
	.UART_DLM(8'h0),
	.UART_DLL(8'h0),
	.UART_DLM_WR(1'b0),
	.UART_DLL_WR(1'b0),

	.SOFTSW_COMMAND(softsw_command),
	.OSD_COMMAND(osd_command),

	.ROMLOADER_ACTIVE(romload_active),
	.ROMLOAD_ADDR(romload_addr),
	.ROMLOAD_DATA(romload_data),
	.ROMLOAD_WR(romload_wr),
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

	.MATRIX_CMD(matrix_cmd),
	.MATRIX_CMD_WR(matrix_cmd_wr),
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
	.IMG_PHYS_WR(img_phys_wr),
	.IMG_PHYS(img_phys),
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

// register n = OSD item n of core*.json; the file items (3-6) have no value
wire [63:0] softsw_regs;
kg_soft_switches #(
	.N(8),
	.INIT({56'h00_00_00_00_00_01_00, FB_VGA ? 8'h02 : 8'h01})
) u_softsw(
	.clk(clk_50),
	.command(softsw_command),
	.regs(softsw_regs),
	.upd()
);

wire kb_hdd0_image;
// item 0: Video mode RGB / VGA (the scandoubler), or with FB the HDMI path Direct / Frame buffer
// (the direct path needs the scandoubled VGA picture, so the scandoubler stays on); with FB_VGA
// (Go) RGB / VGA / Frame buffer (the frame buffer takes the CGA picture before the scandoubler,
// the scandoubler stays on for it: no 15 kHz flash while the OSD switches)
wire [1:0] kb_item0 = softsw_regs[1:0];
wire kb_fb_sel = FB_VGA ? (kb_item0 == 2'd2) : kb_item0[0];
assign kb_swap_video = FB_VGA ? (kb_item0 != 2'd0) : FB ? 1'b1 : kb_item0[0];
assign kb_turbo_mode = softsw_regs[1*8];
assign kb_hdd0_image = softsw_regs[2*8];
assign kb_reset      = softsw_regs[7*8];

//---------- Disks: CF card and images ------------

pcxt_disks #(.PHYS_FDD(PHYS_FDD)) disks(
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

	.fdd_mgmt_address(fdd_mgmt_address),
	.fdd_mgmt_fddn(fdd_mgmt_fddn),
	.fdd_mgmt_write(fdd_mgmt_write),
	.fdd_mgmt_writedata(fdd_mgmt_writedata),
	.fdd_mgmt_read(fdd_mgmt_read),
	.fdd_mgmt_readdata(fdd_mgmt_readdata),
	.fdd_request(fdd_request),

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
	.img_q_ack(img_q_ack),
	.img_phys_wr(img_phys_wr),
	.img_phys(img_phys),
	.fdd_in(fdd_in),
	.fdd_out(fdd_out)
);


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

// the position, VGA mode (cga_scandoubler): a line of 912 clocks, the picture at 0..639, VGA_HSYNC
// low at 720..880; the overlay counts from the rising hsync (880), a step per 2 clocks: the 256
// pixels (512 clocks) of the OSD centred at 32 + 64 clocks. A frame of 524 lines, the picture at
// 0..399, vsync high at 448..479; the overlay counts from its rising edge, a step per 2 lines:
// the 416 lines of the OSD centred at 76 - 8, then two rows (2 x 16 lines) up: its bottom came
// close to the edge of the screen (Mini G, HDMI).
// With the frame buffer the overlay gets the syncs ovl_hs / ovl_vs of pcxt_fb, placed so that the
// same offsets centre the OSD on its 720 x 480 picture.
wire [17:0] fb_rgb;
wire fb_hs, fb_vs, fb_de, fb_ovl_hs, fb_ovl_vs;
reg fb_sel = 1'b0;

generate if (FB) begin : g_fb
	pcxt_fb fb(
		.clk_vga(clk_vga),
		.clk_50(clk_50),
		.reset(areset),
		.video(cga_video),
		.hs_i(cga_hsync),
		.vs_i(~vs),
		.rgb(fb_rgb),
		.hs(fb_hs),
		.vs(fb_vs),
		.de(fb_de),
		.ovl_hs(fb_ovl_hs),
		.ovl_vs(fb_ovl_vs),
		.sdr_clk(sdr_clk),
		.sdr_a(sdr_a),
		.sdr_ba(sdr_ba),
		.sdr_dq(sdr_dq),
		.sdr_dqm(sdr_dqm),
		.sdr_ras_n(sdr_ras_n),
		.sdr_cas_n(sdr_cas_n),
		.sdr_we_n(sdr_we_n)
	);
	// the switch into clk_vga (it changes from the OSD only)
	wire item0_v;
	kg_sync #(.W(1)) u_sync_item0(.clk(clk_vga), .d(kb_fb_sel), .q(item0_v));
	always @(posedge clk_vga) fb_sel <= item0_v;
end else begin : g_no_fb
	assign fb_rgb = 18'd0;
	assign {fb_hs, fb_vs, fb_de, fb_ovl_hs, fb_ovl_vs} = 5'b11000;
	assign sdr_clk = 1'b0;
	assign sdr_a = 13'd0;
	assign sdr_ba = 2'd0;
	assign sdr_dq = 16'bz;
	assign sdr_dqm = 2'b11;
	assign {sdr_ras_n, sdr_cas_n, sdr_we_n} = 3'b111;
end endgenerate

assign fb_on = fb_sel;

wire [17:0] ovl_rgb = fb_sel ? fb_rgb : {r, g, b};
kg_osd_overlay #(
	.H_OFFSET(48),
	.V_OFFSET(18)
) overlay(
	.clk(clk_vga),
	.rgb_i({ovl_rgb[17:12], 2'b00, ovl_rgb[11:6], 2'b00, ovl_rgb[5:0], 2'b00}),
	.rgb_o(vga_rgb),
	.hsync_i(fb_sel ? fb_ovl_hs : hs),
	.vsync_i(fb_sel ? fb_ovl_vs : vs),
	.osd_command(osd_cmd_vga)
);

assign vga_hs = fb_sel ? fb_hs : hs;
assign vga_vs = fb_sel ? fb_vs : vs;
assign vga_de = fb_de;

endmodule
