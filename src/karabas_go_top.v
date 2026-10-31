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
	output wire MIDI_TX,
	output wire MIDI_CLK,
	output wire MIDI_RESET_N,

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
	output wire MCU_MISO,
	inout wire [1:0] MCU_SPI_IO // [0] burst ready (N9), [1] burst cs_n (M11)
   );

	/////////////////////////////////////////////////////////////////////////////////////////////////////////

assign ESP_RESET_N = 1'bZ;
assign ESP_BOOT_N = 1'bZ;

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

// the floppy connector: physical drives A / B (karabas_pcxt PHYS_FDD); high = active at the pins,
// FDC_SIDE_N is SIDE1 there (1: head 1)
wire [7:0] fdd_out;
assign {FDC_WDATA, FDC_WGATE, FDC_SIDE_N, FDC_STEP, FDC_DIR, FDC_MOTOR, FDC_DRIVE[1], FDC_DRIVE[0]} = fdd_out;

assign TAPE_OUT = 1'b0;
assign BEEPER = 1'b0;

// burst transfers from the mcu (karabas-go-firmware docs/burst_protocol.md):
// firmware IO0 (GPIO14) = MCU_SPI_IO[1] (M11), IO1 (GPIO2) = MCU_SPI_IO[0] (N9)
wire mcu_burst_ready;
assign MCU_SPI_IO[0] = mcu_burst_ready;
assign MCU_SPI_IO[1] = 1'bz;

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
wire hs, vs;
wire [15:0] audio_l, audio_r;

// MCU_SCK is not on a global clock pin: bursts at the link clock
karabas_pcxt #(.BURST_MAX_MHZ(0), .PHYS_FDD(1)) pcxt(
	.clk_100(clk_100),
	.clk_50(clk_50),
	.clk_vga(clk_28_571),
	.areset(areset),

	.fdd_in({FDC_RDATA, FDC_WPRT, FDC_TR00, FDC_INDEX}),
	.fdd_out(fdd_out),

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
	.mcu_burst_cs_n(MCU_SPI_IO[1]),
	.mcu_burst_ready(mcu_burst_ready),

	.vga_rgb(rgb),
	.vga_hs(hs),
	.vga_vs(vs),
	.dvi_only(),

	.audio_l(audio_l),
	.audio_r(audio_r),

	.kb_reset(),
	.midi_tx(MIDI_TX)
);

//---------- MIDI ------------

assign MIDI_RESET_N = 1'b1;
midi_clk midi_clk_inst(.clk_50(clk_50), .midi_clk(MIDI_CLK));

//---------- VGA ------------

assign VGA_R = rgb[23:16];
assign VGA_G = rgb[15:8];
assign VGA_B = rgb[7:0];
assign VGA_HS = hs;
assign VGA_VS = vs;

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

//---------- DAC ------------

kg_pcm5102 #(.DIV_BITS(2)) pcm5102( // 1.79 MHz bck, 55.8 kHz, as pcm5102.v before
	.clk(clk_28_571),
	.reset(areset),
	.left(audio_l),
	.right(audio_r),
	.din(DAC_DAT),
	.bck(DAC_BCK),
	.lrck(DAC_LRCK)
);
assign DAC_MUTE = 1'b1; // soft mute, 0 = mute, 1 = unmute

endmodule
