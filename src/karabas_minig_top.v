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
-- FPGA PCXT core for Karabas-Go Mini rev.G
--
-- @author Andy Karpov <andy.karpov@gmail.com>
-- EU, 2026
------------------------------------------------------------------------------------------------------------------*/



module karabas_minig_top (
	//---------------------------
	input wire 				CLK_50MHZ,

	//---------------------------
	inout wire 				UART_RX,
	inout wire 				UART_TX,
	inout wire 				UART_CTS,

	//---------------------------
	output wire [20:0] 	MA,
	inout wire [15:0] 	MD,
	output wire [1:0] 	MWR_N,
	output wire [1:0] 	MRD_N,

	//---------------------------
	output wire [1:0] 	SDR_BA,
	output wire [12:0] 	SDR_A,
	output wire 			SDR_CLK,
	output wire [1:0] 	SDR_DQM,
	output wire 			SDR_WE_N,
	output wire 			SDR_CAS_N,
	output wire 			SDR_RAS_N,
	inout wire [15:0] 	SDR_DQ,

	//---------------------------
	output wire 			SD_CS_N,
	output wire 			SD_CLK,
	inout wire 				SD_DI,
	inout wire 				SD_DO,
	input wire 				SD_DET_N,

	//---------------------------
	input wire [7:0] 		VGA_R,
	input wire [7:0] 		VGA_G,
	input wire [7:0] 		VGA_B,
	input wire 				VGA_HS,
	input wire 				VGA_VS,

	output wire [3:0] 	TMDS_P,
	output wire [3:0] 	TMDS_N,

	//---------------------------
	output wire 			FT_SPI_CS_N,
	output wire 			FT_SPI_SCK,
	input wire 				FT_SPI_MISO,
	output wire 			FT_SPI_MOSI,
	input wire 				FT_INT_N,
	input wire 				FT_CLK,
	input wire 				FT_DE,
	output wire 			FT_CLK_OUT,

	//---------------------------
	output wire [2:0] 	WA,
	output wire [1:0] 	WCS_N,
	output wire 			WRD_N,
	output wire 			WWR_N,
	output wire 			WRESET_N,
	inout wire [15:0] 	WD,

	//---------------------------	
	output wire 			TAPE_OUT,
	input wire 				TAPE_IN,
	
   //---------------------------
	output wire          DAC_BCK,
	output wire          DAC_WS,
	output wire          DAC_DAT,

	//---------------------------
	output wire 			ADC_CLK,
	inout wire 				ADC_BCK,
	inout wire 				ADC_LRCK,
	input wire 				ADC_DOUT,
	
	//---------------------------
	output wire          ESP32_SPI_CS_N,
	input wire           ESP32_PCM_BCK,
	input wire           ESP32_PCM_RLCK,
	input wire           ESP32_PCM_DAT,

	//---------------------------
	input wire 				MCU_CS_N,
	input wire 				MCU_SCK,
	input wire 				MCU_MOSI,
	output wire 			MCU_MISO,
	inout wire [5:0] 		MCU_IO, // [0] burst cs_n, [1] burst ready

	//---------------------------
	output wire 			MIDI_TX,

	//---------------------------
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
assign TAPE_OUT = 1'b0;
assign FLASH_CS_N = 1'b1;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;
assign FLASH_SCK = 1'b1;
assign FLASH_DI = 1'b1;
assign ESP32_SPI_CS_N = 1'b1;
assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'b0;
assign ADC_LRCK = 1'b0;

// burst transfers from the mcu (karabas-go-firmware docs/burst_protocol.md)
wire mcu_burst_ready;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[1] = mcu_burst_ready;
assign MCU_IO[5:2] = 4'bzzzz;

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
wire fb_de, fb_on;
wire [15:0] audio_l, audio_r;

// Rev.G has MCU_SCK on a global clock pin: bursts at up to 32 MHz
karabas_pcxt #(.BURST_MAX_MHZ(32), .FB(1)) pcxt(
	.clk_100(clk_100),
	.clk_50(clk_50),
	.clk_vga(clk_28_571),
	.areset(areset),

	.fdd_in(4'b0000),
	.fdd_out(),

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
	.vga_de(fb_de),
	.fb_on(fb_on),
	.dvi_only(dvi_only),

	.sdr_clk(SDR_CLK),
	.sdr_a(SDR_A),
	.sdr_ba(SDR_BA),
	.sdr_dq(SDR_DQ),
	.sdr_dqm(SDR_DQM),
	.sdr_ras_n(SDR_RAS_N),
	.sdr_cas_n(SDR_CAS_N),
	.sdr_we_n(SDR_WE_N),

	.audio_l(audio_l),
	.audio_r(audio_r),

	.kb_reset(kb_reset),
	.midi_tx(MIDI_TX)
);

//---------- HDMI ------------

// the frame buffer (fb_on, OSD item 0): its fixed raster as it is; Direct: hdmi_frame fits the
// sync of the scandoubled picture into 720x480
wire [23:0] hdmi_rgb, frame_rgb;
wire hdmi_hs, hdmi_vs, frame_hs, frame_vs, frame_blank;
assign hdmi_rgb = fb_on ? rgb : frame_rgb;
assign hdmi_hs = fb_on ? hs : frame_hs;
assign hdmi_vs = fb_on ? vs : frame_vs;
wire hdmi_de = fb_on ? fb_de : ~frame_blank;
hdmi_frame hdmi_frame(
	.clk_rgb(clk_28_571),
	.clk_vga(clk_28_571),
	.reset(areset),
	.rgb({rgb[23:18], rgb[15:10], rgb[7:2]}),
	.hs(hs),
	.vs(vs),
	.hdmi_rgb(frame_rgb),
	.hdmi_hs(frame_hs),
	.hdmi_vs(frame_vs),
	.hdmi_blank(frame_blank),
	.width(),
	.height()
);

zhdmi_top zhdmi_top(
	.clk(clk_28_571),
	.reset(areset),

	.vga_rgb(hdmi_rgb),
	.vga_hs(hdmi_hs),
	.vga_vs(hdmi_vs),
	.vga_de(hdmi_de),

	.audio_en(~dvi_only),
	.audio_l(audio_l),
	.audio_r(audio_r),

	.tmds_p(TMDS_P),
	.tmds_n(TMDS_N)
);

//---------- DAC ------------

kg_pcm5102 #(.DIV_BITS(2)) pcm5102( // 1.79 MHz bck, 55.8 kHz, as pcm5102.v before
	.clk(clk_28_571),
	.reset(areset),
	.left(audio_l),
	.right(audio_r),
	.din(DAC_DAT),
	.bck(DAC_BCK),
	.lrck(DAC_WS)
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
