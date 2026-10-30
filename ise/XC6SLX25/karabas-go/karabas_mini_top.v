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
	inout wire [3:0] 		MCU_IO, // [0] burst cs_n, [1] burst ready

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
assign FLASH_DI = 1'b1;
assign MIDI_TX = 1'b1;
assign MIDI_CLK = 1'b0;
assign MIDI_RESET_N = 1'b1;
assign ESP_RESET_N = 1'bZ;
assign ESP_BOOT_N = 1'bZ;
assign FT_RESET = 1'b1;
assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'b0;
assign ADC_LRCK = 1'b0;

// burst transfers from the mcu (karabas-go-firmware docs/burst_protocol.md)
wire mcu_burst_ready;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[1] = mcu_burst_ready;
assign MCU_IO[3:2] = 2'bzz;

//---------- Clocks ------------

wire clk_100, clk_50, clk_28_571;
wire locked;
wire areset;

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

wire [23:0] rgb;
wire hs, vs, dvi_only, kb_reset;
wire [15:0] audio_l, audio_r;

// MCU_SCK is not on a global clock pin: bursts at the link clock
karabas_pcxt #(.BURST_MAX_MHZ(0)) pcxt(
	.clk_100(clk_100),
	.clk_50(clk_50),
	.clk_vga(clk_28_571),
	.areset(areset),

	.sram_a(MA),
	.sram_d(MD[7:0]),
	.sram_we_n(MWR_N[0]),

	.ide_cs_n(WCS_N),
	.ide_rd_n(WRD_N),
	.ide_wr_n(WWR_N),
	.ide_a(WA),
	.ide_d(WD),
	.ide_reset_n(WRESET_N),
	.sd_cs_n(SD_CS_N),
	.sd_di(SD_DI),
	.sd_clk(SD_CLK),
	.sd_do(SD_DO),

	.mcu_cs_n(MCU_CS_N),
	.mcu_sck(MCU_SCK),
	.mcu_mosi(MCU_MOSI),
	.mcu_miso(MCU_MISO),
	.mcu_burst_cs_n(MCU_IO[0]),
	.mcu_burst_ready(mcu_burst_ready),

	.vga_rgb(rgb),
	.vga_hs(hs),
	.vga_vs(vs),
	.dvi_only(dvi_only),

	.audio_l(audio_l),
	.audio_r(audio_r),

	.kb_reset(kb_reset)
);

//---------- HDMI ------------

// hdmi frame converter: fits the sync into 720x480
wire [23:0] hdmi_rgb;
wire hdmi_hs, hdmi_vs, hdmi_blank;
hdmi_frame hdmi_frame(
	.clk_rgb(clk_28_571),
	.clk_vga(clk_28_571),
	.reset(areset),
	.rgb({rgb[23:18], rgb[15:10], rgb[7:2]}),
	.hs(hs),
	.vs(vs),
	.hdmi_rgb(hdmi_rgb),
	.hdmi_hs(hdmi_hs),
	.hdmi_vs(hdmi_vs),
	.hdmi_blank(hdmi_blank),
	.width(),
	.height()
);

zhdmi_top zhdmi_top(
	.clk(clk_28_571),
	.reset(areset),

	.vga_rgb(hdmi_rgb),
	.vga_hs(hdmi_hs),
	.vga_vs(hdmi_vs),
	.vga_de(~hdmi_blank),

	.audio_en(~dvi_only),
	.audio_l(audio_l),
	.audio_r(audio_r),

	.tmds_p(TMDS_P),
	.tmds_n(TMDS_N)
);

//---------- DAC ------------

// sigma-delta outputs, a quarter of the full scale as before (offset binary)
kg_sigma_delta_dac #(.MSBI(15)) dac_l(
	.clk(clk_28_571),
	.reset(areset),
	.din({2'b00, ~audio_l[15], audio_l[14:4], 2'b00}),
	.dout(AUDIO_L)
);

kg_sigma_delta_dac #(.MSBI(15)) dac_r(
	.clk(clk_28_571),
	.reset(areset),
	.din({2'b00, ~audio_r[15], audio_r[14:4], 2'b00}),
	.dout(AUDIO_R)
);

//---------- FT812 clock ------------

// 8.33 MHz (clk_50 / 6): an FT812 without a clock is left in an undefined state and hums into
// the audio (its output goes to the ADC path)
reg [1:0] ft_div = 2'd0;
reg ft_clk = 1'b0;
always @(posedge clk_50) begin
	ft_div <= (ft_div == 2'd2) ? 2'd0 : ft_div + 1'd1;
	if (ft_div == 2'd2) ft_clk <= ~ft_clk;
end
assign FT_CLK_OUT = ft_clk;

endmodule
