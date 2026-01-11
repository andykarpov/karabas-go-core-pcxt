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
-- FPGA PCXT core for Karabas-Go Mini
--
-- @author Andy Karpov <andy.karpov@gmail.com>
-- EU, 2026
------------------------------------------------------------------------------------------------------------------*/

// Warning! HW_ID2 macros defined in the Synthesize - XST process properties!

module karabas_mini_top (
	//------------------ global clock --------
	input wire 				CLK_50MHZ,

	//------------------ esp8266 uart --------
	inout wire 				UART_RX,
	inout wire 				UART_TX,
	inout wire 				UART_CTS,
	inout wire 				ESP_RESET_N,
	inout wire 				ESP_BOOT_N,

	//------------------ sram ----------------
	output wire [20:0] 	MA,
	inout wire [15:0] 	MD,
	output wire [1:0] 	MWR_N,
	output wire [1:0] 	MRD_N,

	//------------------ sdram ---------------
	output wire [1:0] 	SDR_BA,
	output wire [12:0] 	SDR_A,
	output wire 			SDR_CLK,
	output wire [1:0] 	SDR_DQM,
	output wire 			SDR_WE_N,
	output wire 			SDR_CAS_N,
	output wire 			SDR_RAS_N,
	inout wire [15:0] 	SDR_DQ,

	//------------------ sd2 -----------------
	output wire 			SD_CS_N,
	output wire 			SD_CLK,
	inout wire 				SD_DI,
	inout wire 				SD_DO,
	input wire 				SD_DET_N,

	//------------------ ft812 rgb + sync ----
	input wire [7:0] 		VGA_R,
	input wire [7:0] 		VGA_G,
	input wire [7:0] 		VGA_B,
	input wire 				VGA_HS,
	input wire 				VGA_VS,

	//------------------ dvi / hdmi ----------
	output wire [3:0] 	TMDS_P,
	output wire [3:0] 	TMDS_N,

	//------------------ ft812 spi and ctl ---
	output wire 			FT_SPI_CS_N,
	output wire 			FT_SPI_SCK,
	input wire 				FT_SPI_MISO,
	output wire 			FT_SPI_MOSI,
	input wire 				FT_INT_N,
	input wire 				FT_CLK,
	input wire 				FT_AUDIO,
	input wire 				FT_DE,
	input wire 				FT_DISP,
	output wire 			FT_RESET,
	output wire 			FT_CLK_OUT,

	//------------------ cf card -------------
	output wire [2:0] 	WA,
	output wire [1:0] 	WCS_N,
	output wire 			WRD_N,
	output wire 			WWR_N,
	output wire 			WRESET_N,
	inout wire [15:0] 	WD,

	//------------------ analog in/out -------	
	output wire 			TAPE_OUT,
	input wire 				TAPE_IN,
	output wire 			AUDIO_L,
	output wire 			AUDIO_R,

	//------------------ adc -----------------
	output wire 			ADC_CLK,
	inout wire 				ADC_BCK,
	inout wire 				ADC_LRCK,
	input wire 				ADC_DOUT,

	//------------------ mcu spi -------------
	input wire 				MCU_CS_N,
	input wire 				MCU_SCK,
	input wire 				MCU_MOSI,
	output wire 			MCU_MISO,
	input wire [3:0] 		MCU_IO,

	//------------------ midi ----------------
	output wire 			MIDI_TX,
	output wire 			MIDI_CLK,
	output wire 			MIDI_RESET_N,

	//------------------ optional flash ------
	output wire 			FLASH_CS_N,
	input wire  			FLASH_DO,
	output wire 			FLASH_DI,
	output wire 			FLASH_SCK,
	output wire 			FLASH_WP_N,
	output wire 			FLASH_HOLD_N
);

// unused signals yet
assign ESP_RESET_N 	= 1'bZ;
assign ESP_BOOT_N 	= 1'bZ;
assign FT_SPI_CS_N = 1'b1;
assign FT_SPI_SCK = 1'b0;
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
assign TAPE_OUT = 1'b0;
assign FLASH_CS_N = 1'b1;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;
assign FLASH_SCK = 1'b1;
assign MIDI_RESET_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FT_RESET = 1'b1;
assign MIDI_TX = 1'b1;

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

wire clk_100;
wire clk_50;
wire clk_28_571;
wire locked;
wire areset;

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
wire vga_hs, vga_vs;
wire serial_mouse_tx, serial_mouse_rts;
wire [15:0] audio_l, audio_r;
wire ps2_clk, ps2_dat;
wire kb_swap_video, kb_turbo_mode;
wire [7:0] hid_kb_scancode;
wire hid_kb_scancode_upd;	

system sys_inst
(
	.clk_100(clk_100),
	.clk_chipset(clk_50),
	.clk_vga(clk_28_571),
	
	.VGA_R(r),
	.VGA_G(g),
	.VGA_B(b),
	.VGA_HSYNC(vga_hs),
	.VGA_VSYNC(vga_vs),
	
	.SRAM_ADDR(MA),
	.SRAM_DATA(MD[7:0]),
	.SRAM_WE_n(MWR_N[0]),
	
	.kb_scancode(hid_kb_scancode),
	.kb_scancode_upd(hid_kb_scancode_upd),
	
	.serial_mouse_tx(serial_mouse_tx),
	.serial_mouse_rts(serial_mouse_rts),
	
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
wire [7:0] ms_x, ms_y;
wire [2:0] ms_b;
wire ms_upd;
wire [12:0] joy_l, joy_r;
wire [15:0] softsw_command, osd_command;
wire mcu_busy;
wire [7:0] hwid;
wire dvi_only;
wire [10:0] hdmi_width, hdmi_height;

mcu mcu(
	.CLK(clk_50),
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
	
	.KB_SCANCODE(hid_kb_scancode),
	.KB_SCANCODE_UPD(hid_kb_scancode_upd),
	
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
	
	.HWID(hwid),
	.DVI_ONLY(dvi_only),
	
	.SOFTSW_COMMAND(softsw_command),	
	.OSD_COMMAND(osd_command),
	
	.DEBUG_ADDR("00000" & hdmi_width),
	.DEBUG_DATA("00000" & hdmi_height),
	
	.BUSY(mcu_busy)
);

//---------- Keyboard parser ------------

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

wire kb_reset;

soft_switches soft_switches(
	.CLK(clk_50),
	
	.SOFTSW_COMMAND(softsw_command),

	// todo: more modes (incl. soft buttons and mode switches)
	.SWAP_VIDEO(kb_swap_video),
	.TURBO_MODE(kb_turbo_mode),
	.RESET(kb_reset)
);

assign btn_reset_n = ~kb_reset & ~mcu_busy;

// ----

// midi clk 12mhz out
//ODDR2 u_midi_clk (.Q(MIDI_CLK), .C0(clk_12mhz), .C1(~clk_12mhz), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));
assign MIDI_CLK = 1'b0;

// ft clk 8mhz out
//ODDR2 u_ft_clk (.Q(FT_CLK_OUT), .C0(clk_8mhz), .C1(~clk_8mhz), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));
assign FT_CLK_OUT = 1'b0;

wire [15:0] audio_mix_l, audio_mix_r;

// hdmi frame converter
wire [23:0] hdmi_rgb;
wire hdmi_hs, hdmi_vs, hdmi_blank;
hdmi_frame hdmi_frame(
	.clk_rgb			(clk_28_571),
	.clk_vga			(clk_28_571),
	.reset			(areset),
	.rgb				({r,g,b}),
	.hs				(vga_hs),
	.vs				(vga_vs),
	.hdmi_rgb		(hdmi_rgb),
	.hdmi_hs			(hdmi_hs),
	.hdmi_vs			(hdmi_vs),
	.hdmi_blank		(hdmi_blank),
	.width			(hdmi_width),
	.height			(hdmi_height)
);

// hdmi
wire [7:0] hdmi_freq;
hdmi_top hdmi_top(
	.clk				(clk_28_571),
	.ds80				(1'b1),
	.reset			(areset || kb_reset),

	.vga_rgb			(hdmi_rgb),
	.vga_hs			(hdmi_hs),
	.vga_vs			(hdmi_vs),
	.vga_de			(~hdmi_blank),

	.audio_en		(~dvi_only),
	.audio_l			(audio_mix_l),
	.audio_r			(audio_mix_r),

	.tmds_p			(TMDS_P),
	.tmds_n			(TMDS_N),

	.freq				(hdmi_freq),
	.clk_pix			()
);

//------- Sigma-Delta DAC ---------
dac dac_l(
	.I_CLK			(clk_28_571),
	.I_RESET			(areset),
	.I_DATA			({2'b00, !audio_mix_l[15], audio_mix_l[14:4], 2'b00}),
	.O_DAC			(AUDIO_L)
);

dac dac_r(
	.I_CLK			(clk_28_571),
	.I_RESET			(areset),
	.I_DATA			({2'b00, !audio_mix_r[15], audio_mix_r[14:4], 2'b00}),
	.O_DAC			(AUDIO_R)
);

// ------- PCM1808 ADC ---------
/*wire signed [23:0] adc_l, adc_r;
wire adc_clk_int = clk_28_571;

i2s_transceiver adc(
	.reset_n			(~areset),
	.mclk				(adc_clk_int),
	.sclk				(ADC_BCK),
	.ws				(ADC_LRCK),
	.sd_tx			(),
	.sd_rx			(ADC_DOUT),
	.l_data_tx		(24'b0),
	.r_data_tx		(24'b0),
	.l_data_rx		(adc_l),
	.r_data_rx		(adc_r)
);

// ------- ADC_CLK output buf
ODDR2 oddr_adc2(.Q(ADC_CLK), .C0(adc_clk_int), .C1(~adc_clk_int), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));
*/
assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'b0;
assign ADC_LRCK = 1'b0;

// ------- audio mix
assign audio_mix_l = audio_l;
assign audio_mix_r = audio_r;

endmodule
