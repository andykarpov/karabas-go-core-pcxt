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
	parameter PHYS_FDD = 0,      // 1: the physical floppy drives (Karabas Go), see pcxt_fdd_phys
	// the MCU link: 1 = v1 (kg_mcu, img_sdc in pcxt_disks, kg_soft_switches, kg_osd_overlay); 2 = v2
	// (kg_mcu2: its mounter, the SW registers, COM2 on PORT 0, LPT on PORT 3, kg_l2_osd_overlay;
	// mcu_burst_ready carries MCU_INT, mcu_burst_cs_n is unused)
	parameter LINK = 1
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

// the OSD of link v2 (kg_mcu2 -> kg_l2_osd_overlay)
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;
// the switches: kg_soft_switches (LINK 1) or the SW registers of kg_mcu2
wire [63:0] softsw_regs;
// LINK 2: the mounter of kg_mcu2 to pcxt_disks
wire [7:0] l2_sdc_img_mounted, l2_sdc_rd, l2_sdc_wr, l2_sdc_byte_in_data, l2_sdc_byte_out_data;
wire [63:0] l2_sdc_img_size;
wire [31:0] l2_sdc_sector;
wire l2_sdc_busy, l2_sdc_done, l2_sdc_error, l2_sdc_byte_in_strobe;
wire [2:0] l2_sdc_slot;
wire [8:0] l2_sdc_byte_addr;

generate if (LINK == 1) begin : mcu_link1
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
end else begin : mcu_link2
	// the v2 events and streams as the signals of v1
	wire [7:0] l2_ps2_code, l2_ms_x, l2_ms_y, l2_ms_b, l2_ld_data;
	wire l2_ps2_kind, l2_ps2_wr, l2_ms_wr, l2_ld_active, l2_ld_wr;
	wire [1:0] l2_ld_kind;
	wire [31:0] l2_ld_addr, l2_port_out_data, l2_port_stat;
	wire [3:0] l2_port_out_wr, l2_port_stat_wr;
	wire [15:0] l2_joy_l, l2_joy_r;
	reg [7:0] xt_r = 8'd0, com2_rx_r = 8'd0, com2_idx_r = 8'd0;
	reg xt_t = 1'b0, ms_t = 1'b0;
	// LPT: busy from a byte until the status of the printer comes back (PSTAT of port 3, bit 7 BUSY)
	reg prn_wait = 1'b0, prn_st_busy = 1'b0;
	always @(posedge clk_50) begin
		if (l2_ps2_wr && l2_ps2_kind) begin xt_r <= l2_ps2_code; xt_t <= ~xt_t; end
		if (l2_ms_wr) ms_t <= ~ms_t;
		if (l2_port_out_wr[0]) begin com2_rx_r <= l2_port_out_data[7:0]; com2_idx_r <= com2_idx_r + 8'd1; end
		if (prn_wr) prn_wait <= 1'b1;
		else if (l2_port_stat_wr[3]) begin prn_wait <= 1'b0; prn_st_busy <= l2_port_stat[31]; end
	end
	assign xt_scancode = xt_r;
	assign xt_scancode_upd = xt_t;
	assign ms_x = l2_ms_x;
	assign ms_y = l2_ms_y;
	assign ms_b = l2_ms_b[2:0];
	assign ms_upd = ms_t;
	assign joy_l = l2_joy_l[12:0];
	assign joy_r = l2_joy_r[12:0];
	assign com2_rx_data = com2_rx_r;
	assign com2_rx_idx = com2_idx_r;
	assign prn_busy = prn_wait || prn_st_busy;
	// the ROMs of the core file (LD kind 0): BIOS, XTIDE BIOS
	assign romload_active = l2_ld_active && l2_ld_kind == 2'd0;
	assign romload_wr = l2_ld_wr && l2_ld_kind == 2'd0;
	assign romload_addr = l2_ld_addr;
	assign romload_data = l2_ld_data;
	assign softsw_command = 16'd0;
	assign osd_command = 16'd0;

	kg_mcu2 #(
		.SW_N(8),
		.SW_INIT({56'h00_00_00_00_00_01_00, FB_VGA ? 8'h02 : 8'h01}),
		.CS_FILTER(3),
		.ENABLE_OSD(1),
		.ENABLE_IMG(1),            // HDD0 / HDD1 (slots 0, 1), FDD A / B (2, 3)
		.IMG_OUT_LATENCY(3),
`ifdef RTC_MCU
		.ENABLE_RTC(1),
`endif
		.ENABLE_PORTS({
`ifdef LPT_USB
			1'b1,
`else
			1'b0,
`endif
			2'b00,
`ifdef COM2_USB
			1'b1
`else
			1'b0
`endif
		}),
		.ENABLE_AUX(1),            // the level meters of the dot matrix
		.ENABLE_FT(0),
		.ENABLE_SD2(0)
	) mcu2(
		.CLK(clk_50),
		.N_RESET(~areset),

		.MCU_SCK(mcu_sck),
		.MCU_MOSI(mcu_mosi),
		.MCU_MISO(mcu_miso),
		.MCU_SS(mcu_cs_n),
		.MCU_INT(mcu_burst_ready),
		.MCU_SPI_FT_SS(1'b1),
		.MCU_SPI_SD2_SS(1'b1),

		.SW(softsw_regs), .SW_WR(), .SW_INDEX(), .SW_VALUE(), .HW_ID(), .DVI_ONLY(mcu_dvi_only),
		.CORE_BUILD(), .FW_BUILD(), .BUSY(), .BTNS(), .RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),

		.KBD(), .KBD_WR(), .PS2_CODE(l2_ps2_code), .PS2_KIND(l2_ps2_kind), .PS2_WR(l2_ps2_wr),
		.MS_X(l2_ms_x), .MS_Y(l2_ms_y), .MS_Z(), .MS_B(l2_ms_b), .MS_WR(l2_ms_wr),
		.JOY_L(l2_joy_l), .JOY_R(l2_joy_r), .JOY_WR(),
		.PS2_CMD(16'd0), .PS2_CMD_WR(1'b0),

		.LD_KIND(l2_ld_kind), .LD_SLOT(), .LD_SIZE(), .LD_START(), .LD_ACTIVE(l2_ld_active), .LD_END(),
		.LD_ADDR(l2_ld_addr), .LD_DATA(l2_ld_data), .LD_WR(l2_ld_wr), .LD_READY(1'b1),

		.OSD_WR(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
		.OSD_FG(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha), .OSD_PX(osd_px), .OSD_PY(osd_py),
		.OSD_PW(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),

		.SDC_IMG_MOUNTED(l2_sdc_img_mounted), .SDC_IMG_SIZE(l2_sdc_img_size),
		.SDC_RD(l2_sdc_rd), .SDC_WR(l2_sdc_wr), .SDC_SECTOR(l2_sdc_sector),
		.SDC_BUSY(l2_sdc_busy), .SDC_DONE(l2_sdc_done), .SDC_ERROR(l2_sdc_error), .SDC_SLOT(l2_sdc_slot),
		.SDC_BYTE_IN_STROBE(l2_sdc_byte_in_strobe), .SDC_BYTE_ADDR(l2_sdc_byte_addr),
		.SDC_BYTE_IN_DATA(l2_sdc_byte_in_data), .SDC_BYTE_OUT_DATA(l2_sdc_byte_out_data),
		.IMG_WP(), .IMG_PHYS_WR(img_phys_wr), .IMG_PHYS(img_phys), .IMG_FLUSH(), .FDD_CHNG_WR(), .FDD_CHNG(),
		.FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0),
		.BK_MOUNT(1'b0), .BK_FLUSHED(1'b0), .BK_SLOT(3'd0), .BK_SIZE(32'd0), .BK_KIND(8'd0), .BK_RESULT(8'd0),
		.IMG_ACTIVE(),

		.PORT_OUT_DATA(l2_port_out_data), .PORT_OUT_WR(l2_port_out_wr), .PORT_OUT_READY(4'b1111),
		.PORT_IN_DATA({prn_data, 16'd0, com2_tx_data}), .PORT_IN_WR({prn_wr, 2'b00, com2_tx_wr}),
		.PORT_CFG(128'd0), .PORT_IN_FULL(), .PORT_STAT(l2_port_stat), .PORT_STAT_WR(l2_port_stat_wr),
		.RTC_A(rtc_a), .RTC_DI(rtc_di), .RTC_CS(rtc_cs), .RTC_WR_N(rtc_wr_n), .RTC_DO(rtc_do),
		.MATRIX_CMD(matrix_cmd), .MATRIX_CMD_WR(matrix_cmd_wr), .DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),

		.FT_SPI_ON(), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(), .FT_MISO(1'b1), .FT_CS_N(),
		.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
	);
end endgenerate

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

generate if (LINK == 1) begin : sw_link1
// register n = OSD item n of core*.json; the file items (3-6) have no value
kg_soft_switches #(
	.N(8),
	.INIT({56'h00_00_00_00_00_01_00, FB_VGA ? 8'h02 : 8'h01})
) u_softsw(
	.clk(clk_50),
	.command(softsw_command),
	.regs(softsw_regs),
	.upd()
);
end endgenerate

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

pcxt_disks #(.PHYS_FDD(PHYS_FDD), .LINK(LINK)) disks(
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
	.sdc_img_mounted_i(l2_sdc_img_mounted), .sdc_img_size_i(l2_sdc_img_size), .sdc_rd_o(l2_sdc_rd),
	.sdc_wr_o(l2_sdc_wr), .sdc_sector_o(l2_sdc_sector), .sdc_busy_i(l2_sdc_busy), .sdc_done_i(l2_sdc_done),
	.sdc_error_i(l2_sdc_error), .sdc_slot_i(l2_sdc_slot), .sdc_byte_in_strobe_i(l2_sdc_byte_in_strobe),
	.sdc_byte_addr_i(l2_sdc_byte_addr), .sdc_byte_in_data_i(l2_sdc_byte_in_data),
	.sdc_byte_out_data_o(l2_sdc_byte_out_data),
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
generate if (LINK == 1) begin : osd_link1
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
end else begin : osd_link2
	// the direct VGA path has no de: made here from its syncs (a line of 912 clocks, the picture
	// at 0..639, hsync low at 720..880; a frame of 524 lines, the picture at 0..399, vsync high at
	// 448..479): clocks from the falling hsync, lines from the rising vsync
	reg [9:0] dh = 10'd0, dv = 10'd0;
	reg hs_d = 1'b1, vs_d = 1'b0;
	always @(posedge clk_vga) begin
		hs_d <= hs;
		vs_d <= vs;
		dh <= (hs_d && !hs) ? 10'd0 : dh + 10'd1;
		if (vs && !vs_d) dv <= 10'd0;
		else if (hs_d && !hs) dv <= dv + 10'd1;
	end
	wire direct_de = dh >= 10'd192 && dh < 10'd832 && dv >= 10'd76 && dv < 10'd476;
	// the bitmap OSD of link v2: centred in de, 2 clocks of latency with its syncs and de
	kg_l2_osd_overlay osd(
		.wclk(clk_50),
		.osd_wr(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
		.osd_fg(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha), .osd_px(osd_px), .osd_py(osd_py),
		.osd_pw(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
		.icon_on(8'd0), .icon_act(8'd0),
		.clk(clk_vga),
		.rgb_i({ovl_rgb[17:12], 2'b00, ovl_rgb[11:6], 2'b00, ovl_rgb[5:0], 2'b00}),
		.hs_i(fb_sel ? fb_hs : hs), .vs_i(fb_sel ? fb_vs : vs), .de_i(fb_sel ? fb_de : direct_de),
		.rgb_o(vga_rgb), .hs_o(vga_hs), .vs_o(vga_vs), .de_o(vga_de)
	);
end endgenerate

endmodule
