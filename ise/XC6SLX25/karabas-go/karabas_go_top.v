`timescale 1ns / 1ns
`default_nettype wire

/*-------------------------------------------------------------------------------------------------------------------
-- 
-- 
-- #       #######                                                 #                                               
-- #                                                               #                                               
-- #                                                               #                                               
-- ############### ############### ############### ############### ############### ############### ############### 
-- #             #               # #                             # #             #               # #               
-- #             # ############### #               ############### #             # ############### ############### 
-- #             # #             # #               #             # #             # #             #               # 
-- #             # ############### #               ############### ############### ############### ############### 
--                                                                                                                 
--         ####### ####### ####### #######                                         ############### ############### 
--                                                                                 #               #             # 
--                                                                                 #   ########### #             # 
--                                                                                 #             # #             # 
-- https://github.com/andykarpov/karabas-go                                        ############### ############### 
--
-- FPGA PCXT core for Karabas-Go
--
-- @author Andy Karpov <andy.karpov@gmail.com>
-- Ukraine, 2024
------------------------------------------------------------------------------------------------------------------*/

	module karabas_go_top (

   //---------------------------
   input wire CLK_50MHZ,

	//---------------------------
	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,
	inout wire ESP_RESET_N,
	inout wire ESP_BOOT_N,
	
   //---------------------------
   output wire [20:0] MA,
   inout wire [15:0] MD,
   output wire [1:0] MWR_N,
   output wire [1:0] MRD_N,

   //---------------------------
	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

   //---------------------------
   output wire SD_CS_N,
   output wire SD_CLK,
   inout wire SD_DI,
   inout wire SD_DO,
	input wire SD_DET_N,

   //---------------------------
   output wire [7:0] VGA_R,
   output wire [7:0] VGA_G,
   output wire [7:0] VGA_B,
   output wire VGA_HS,
   output wire VGA_VS,
	output wire V_CLK,
	
	//---------------------------
	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	output wire FT_OE_N,

	//---------------------------
	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,
	
	//---------------------------
	input wire FDC_INDEX,
	output wire [1:0] FDC_DRIVE,
	output wire FDC_MOTOR,
	output wire FDC_DIR,
	output wire FDC_STEP,
	output wire FDC_WDATA,
	output wire FDC_WGATE,
	input wire FDC_TR00,
	input wire FDC_WPRT,
	input wire FDC_RDATA,
	output wire FDC_SIDE_N,

   //---------------------------	
	output wire TAPE_OUT,
	input wire TAPE_IN,
	output wire BEEPER,
	
	//---------------------------
	output wire DAC_LRCK,
   output wire DAC_DAT,
   output wire DAC_BCK,
   output wire DAC_MUTE,
	
	//---------------------------
	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO	
   );

	/////////////////////////////////////////////////////////////////////////////////////////////////////////

	assign ESP_RESET_N = 1'bZ;
	assign ESP_BOOT_N = 1'bZ;
	
	assign VGA_R[7:0] = {r[5:0], 2'b00};
	assign VGA_G[7:0] = {g[5:0], 2'b00};
	assign VGA_B[7:0] = {b[5:0], 2'b00};
	
	assign FT_SPI_CS_N = 1'b1;
	assign FT_SPI_SCK = 1'b0;
	assign FT_OE_N = 1'b1;
	assign FT_SPI_MOSI = 1'b0;
	
	assign MWR_N[1] = 1'b1;
	assign MRD_N = 2'b10;
	assign MD[15:8] = 8'bZZZZZZZZ;
	
	assign SDR_BA = 2'b00;
	assign SDR_A = 13'b0000000000000;
	assign SDR_CLK = 1'b0;
	assign SDR_DQM = 2'b00;
	assign SDR_WE_N = 1'b1;
	assign SDR_CAS_N = 1'b1;
	assign SDR_RAS_N = 1'b1;
	
`ifndef PHYSICAL_IDE
	assign WA = 3'b000;
	assign WCS_N = 2'b11;
	assign WRD_N = 1'b1;
	assign WWR_N = 1'b1;
	assign WRESET_N = 1'b1;
`else
	assign SD_CS_N = 1'b1;
	assign SD_CLK = 1'b0;
`endif
	

	assign FDC_DRIVE = 2'b00;
	assign FDC_MOTOR = 1'b0;
	assign FDC_DIR = 1'b0;
	assign FDC_STEP = 1'b0;
	assign FDC_WDATA = 1'b0;
	assign FDC_WGATE = 1'b0;
	assign FDC_SIDE_N = 1'b1;

	assign TAPE_OUT = 1'b0;
	assign BEEPER = 1'b0;	

	wire clk_100;
	wire clk_50;
	wire clk_28_571;
	wire locked;
	wire areset;
	
	wire [15:0] audio_l, audio_r;
	
	//---------- PLL ------------
	
	dcm dcm_system 
	(
		.CLK_IN1(CLK_50MHZ),
		.CLK_OUT1(clk_100),
		.CLK_OUT2(clk_50),
		.CLK_OUT3(clk_28_571),
		.LOCKED(locked)
   );
	
	assign areset = ~locked;
   
	//---------- PCXT ------------

	wire [5:0] r, g, b;
	
	system sys_inst
	(
		.clk_100(clk_100),
		.clk_chipset(clk_50),
		.clk_vga(clk_28_571),
		
		.VGA_R(r),
		.VGA_G(g),
		.VGA_B(b),
		.VGA_HSYNC(VGA_HS),
		.VGA_VSYNC(VGA_VS),
		
		.SRAM_ADDR(MA),
		.SRAM_DATA(MD[7:0]),
		.SRAM_WE_n(MWR_N[0]),
		
		.clkps2(ps2_clk),
		.dataps2(ps2_dat),
		
		.ms_x(cursor_x),
		.ms_y(cursor_y),
		.ms_z(cursor_z),
		.ms_b(cursor_b),
		
		.AUD_L(audio_l),
		.AUD_R(audio_r),

`ifdef PHYSICAL_IDE
		.ide_cs_n(WCS_N),
		.ide_rd_n(WRD_N),
		.ide_wr_n(WWR_N),
		.ide_a(WA),
		.ide_d(WD),
		.ide_reset_n(WRESET_N),		
`else
		.SD_nCS(SD_CS_N),
		.SD_DI(SD_DI),
		.SD_CK(SD_CLK),
		.SD_DO(SD_DO),
`endif
		.btn_green_n_i(~kb_swap_video),
		.btn_yellow_n_i(~kb_turbo_mode)
	);
	
	//---------- MCU ------------

	wire [7:0] hid_kb_status, hid_kb_dat0, hid_kb_dat1, hid_kb_dat2, hid_kb_dat3, hid_kb_dat4, hid_kb_dat5;
	wire [12:0] joy_l, joy_r;
	wire [15:0] softsw_command, osd_command;
	wire mcu_busy;

	mcu mcu(
		.CLK(clk_28_571),
		.N_RESET(~areset),
		
		.MCU_MOSI(MCU_MOSI),
		.MCU_MISO(MCU_MISO),
		.MCU_SCK(MCU_SCK),
		.MCU_SS(MCU_CS_N),
		
		.MS_X(ms_x),
		.MS_Y(ms_y),
		.MS_Z(ms_z),
		.MS_B(ms_b),
		.MS_UPD(ms_upd),
		
		.KB_STATUS(hid_kb_status),
		.KB_DAT0(hid_kb_dat0),
		.KB_DAT1(hid_kb_dat1),
		.KB_DAT2(hid_kb_dat2),
		.KB_DAT3(hid_kb_dat3),
		.KB_DAT4(hid_kb_dat4),
		.KB_DAT5(hid_kb_dat5),
		
		.JOY_L(joy_l),
		.JOY_R(joy_r),
		
		.RTC_A(8'b00000000),
		.RTC_DI(8'b00000000),
		.RTC_DO(),
		.RTC_CS(1'b0),
		.RTC_WR_N(1'b1),
		
		.UART_RX_DATA(),
		.UART_RX_IDX(),
		.UART_TX_DATA(8'b00000000),
		.UART_TX_WR(1'b0),
		
		.ROMLOADER_ACTIVE(),
		.ROMLOAD_ADDR(),
		.ROMLOAD_DATA(),
		.ROMLOAD_WR(),
		
		.SOFTSW_COMMAND(softsw_command),	
		.OSD_COMMAND(osd_command),
		
		.BUSY(mcu_busy)
	);

	//---------- Keyboard parser ------------

	//wire [9:0] keycode;
	//wire ps2_clk, ps2_dat;

	hid_parser hid_parser(
		.CLK(clk_28_571),
		.RESET(areset),

		.KB_STATUS(hid_kb_status),
		.KB_DAT0(hid_kb_dat0),
		.KB_DAT1(hid_kb_dat1),
		.KB_DAT2(hid_kb_dat2),
		.KB_DAT3(hid_kb_dat3),
		.KB_DAT4(hid_kb_dat4),
		.KB_DAT5(hid_kb_dat5),	

		.PS2_CLK(ps2_clk),
		.PS2_DAT(ps2_dat)
		
	);
	
	//---------- Soft switches ------------
	
	wire kb_reset; //, kb_swap_video, kb_turbo_mode;
	
	soft_switches soft_switches(
		.CLK(clk_28_571),
		
		.SOFTSW_COMMAND(softsw_command),

		// todo: more modes (incl. soft buttons and mode switches)
		.SWAP_VIDEO(kb_swap_video),
		.TURBO_MODE(kb_turbo_mode),
		.RESET(kb_reset)
	);
	
	assign btn_reset_n = ~kb_reset & ~mcu_busy;

	//---------- Mouse / cursor ------------

	cursor cursor(
		.CLK(clk_28_571),
		.RESET(areset),
		
		.MS_X(ms_x),
		.MS_Y(ms_y),
		.MS_Z(ms_z),
		.MS_B(ms_b),
		.MS_UPD(ms_upd),
		
		.OUT_X(cursor_x),
		.OUT_Y(cursor_y),
		.OUT_Z(cursor_z),
		.OUT_B(cursor_b)
	);
	
	//---------- DAC ------------

	PCM5102 PCM5102(
		.clk(clk_28_571),
		.reset(areset),
		.left(audio_l),
		.right(audio_r),
		.din(DAC_DAT),
		.bck(DAC_BCK),
		.lrck(DAC_LRCK)
	);
	assign DAC_MUTE = 1'b1; // soft mute, 0 = mute, 1 = unmute

	//---------- V_CLK -------------
	
	ODDR2 uODDR2(
		.Q(V_CLK),
		.C0(clk_28_571),
		.C1(~clk_28_571),
		.CE(1'b1),
		.D0(1'b1),
		.D1(1'b0),
		.R(1'b0),
		.S(1'b0)
	);
	
endmodule
