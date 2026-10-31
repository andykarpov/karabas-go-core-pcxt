`default_nettype none
`include "config.vh"

module PERIPHERALS (
	input		wire					clock,
	input		wire					cpu_clock,
	input		wire					peripheral_clock,
	output	wire					turbo,
	input		wire					reset,
	output	reg					interrupt_to_cpu,
	input		wire					interrupt_acknowledge_n,
	output	wire					dma_chip_select_n,
	output	wire					dma_page_chip_select_n,
	input		wire					splashscreen,
	input		wire					clk_vga_cga,
	output	wire					de_o,
	output	wire	[5:0]			VGA_R,
	output	wire	[5:0]			VGA_G,
	output	wire	[5:0]			VGA_B,
	output	wire					VGA_HSYNC,
	output	wire					VGA_VSYNC,
	output	wire					VGA_HBlank,
	output	wire					VGA_VBlank,
	// karabas: the CGA picture before the scandoubler (the HDMI frame buffer, rtl/fb/pcxt_fb.v)
	output	wire	[3:0]			CGA_VIDEO,
	output	wire					CGA_HSYNC,
	input		wire	[19:0]		address,
	input		wire	[7:0]			internal_data_bus,
	output	reg	[7:0] 		data_bus_out,
	output	reg					data_bus_out_from_chipset,
	input		wire	[7:0]			interrupt_request,
	input		wire					io_read_n,
	input		wire					io_write_n,
	input		wire					memory_read_n,
	input		wire					memory_write_n,
	input		wire					address_enable_n,
	output	wire	[2:0]			timer_counter_out,
	output	wire					speaker_out,
	output	wire	[7:0]			port_a_out,
	output	wire					port_a_io,
	input		wire	[7:0]			port_b_in,
	output	wire	[7:0]			port_b_out,
	output	wire					port_b_io,
	input		wire	[7:0]			port_c_in,
	output	wire	[7:0]			port_c_out,
	output	wire	[7:0]			port_c_io,
	input		wire	[7:0]			kb_scancode,
	input		wire					kb_scancode_upd,	
	input    wire 					serial_mouse_tx,
	output   wire 					serial_mouse_rts,
`ifdef GAME_PORT
	// karabas: two joysticks from the USB pads of the mcu (Sega MD2 bits), game_port.v
	input		wire	[12:0]		joy0,
	input		wire	[12:0]		joy1,
`endif
	input		wire					clk_en_opl2,
	output	wire	[15:0]		jtopl2_snd_e,
	input		wire					adlibhide,
//	input		wire					tandy_video,
	output	wire	[7:0]			tandy_snd_e,
	output	wire					tandy_snd_rdy,
	output	wire					tandy_16_gfx,
	input		wire					ioctl_download,
	input		wire	[7:0]			ioctl_index,
	input		wire					ioctl_wr,
	input		wire	[24:0]		ioctl_addr,
	input		wire	[7:0]			ioctl_data,
	input		wire					clk_uart,
	output	wire	[20:0]		SRAM_ADDR,
	inout		wire	[7:0]			SRAM_DATA,
	output	wire					SRAM_WE_n,
	input		wire					ems_enabled,
	input		wire	[1:0]			ems_address,
	output	wire					cga_vram_rdy,

	output   wire  [1:0]       ide_cs_n,
	output   wire              ide_rd_n,
	output   wire              ide_wr_n,
	output   wire  [2:0]       ide_a,
	// karabas: the IDE data bus split, so that the board can put the CF card and the image
	// disks (hdf_ata) on it without a tristate bus inside the FPGA
	output   wire  [15:0]      ide_dout,
	input    wire  [15:0]      ide_din,
	output   wire              ide_reset_n,

`ifdef FLOPPY
	// karabas: the floppy controller of MiSTer PCXT (floppy.v), its disks through the management
	// bus of floppy.v (MiSTer: the HPS), DMA channel 2, IRQ 6
	output   wire              fdd_dma_req,
	input    wire              fdd_dma_ack,
	input    wire              terminal_count,
	input    wire  [3:0]       fdd_mgmt_address,
	input    wire              fdd_mgmt_fddn,
	input    wire              fdd_mgmt_write,
	input    wire  [15:0]      fdd_mgmt_writedata,
	input    wire              fdd_mgmt_read,
	output   wire  [15:0]      fdd_mgmt_readdata,
	output   wire  [1:0]       fdd_request,
`endif
`ifdef RTC_MCU
	// karabas: the clock of the mcu (kg_mcu_rtc, MC146818 registers) at ports 2C0h (index) / 2C1h
	// (data), as the RTC of MiSTer PCXT (4806f99, fd00d43; GET_RTC.EXE sets the DOS time from it)
	output   wire  [7:0]       rtc_a,
	output   wire  [7:0]       rtc_di,
	input    wire  [7:0]       rtc_do,
	output   wire              rtc_cs,
	output   wire              rtc_wr_n,
`endif
`ifdef MIDI_MPU401
	// karabas: MIDI OUT of an MPU-401 in UART mode at ports 330h / 331h (mpu401_tx)
	output   wire              midi_tx,
`endif
	// karabas: the rom loader of the mcu (in the clock of the chipset)
	input    wire              rom_wr,
	input    wire  [14:0]      rom_addr,
	input    wire  [7:0]       rom_data,
	output   reg  [7:0]        xtctl = 8'h00,
	input		wire					btn_green_n_i,
	input		wire					btn_yellow_n_i
	);
	
`include "config.vh"

	wire [4:0] clkdiv;
	reg prev_cpu_clock;
	
	always @(posedge clock, posedge reset)
	begin
		if (reset) 
			prev_cpu_clock <= 1'b0;
		else
			prev_cpu_clock <= cpu_clock;
	end
	
	wire cpu_clock_posedge = ~prev_cpu_clock & cpu_clock;
	wire cpu_clock_negedge = prev_cpu_clock & ~cpu_clock;

	parameter ps2_over_time = 16'd1000;
	wire tandy_video;
	wire [7:0] SRAM_DATA_A_o;
	wire grph_mode;
	wire hres_mode;
	assign tandy_16_gfx = (tandy_video & grph_mode) & hres_mode;
	reg [7:0] chip_select_n;
	wire CGA_VRAM_ENABLE;
	wire turbo_mode;
   wire swap_video;

	assign cga_vram_rdy = ~(CGA_VRAM_ENABLE | CGA_VRAM_ENABLE_ff | CGA_VRAM_ENABLE_ff_2 | CGA_VRAM_ENABLE_ff_3);

	always @(*)
		if ((~address_enable_n & ~address[9]) & ~address[8])
			casez (address[7:5])
				3'b000: chip_select_n = 8'b11111110;
				3'b001: chip_select_n = 8'b11111101;
				3'b010: chip_select_n = 8'b11111011;
				3'b011: chip_select_n = 8'b11110111;
				3'b100: chip_select_n = 8'b11101111;
				3'b101: chip_select_n = 8'b11011111;
				3'b110: chip_select_n = 8'b10111111;
				3'b111: chip_select_n = 8'b01111111;
				default: chip_select_n = 8'b11111111;
			endcase
		else
			chip_select_n = 8'b11111111;
	wire iorq = ~io_read_n | ~io_write_n;
	assign dma_chip_select_n = iorq && chip_select_n[0];
	wire interrupt_chip_select_n = iorq && chip_select_n[1];
	wire timer_chip_select_n = iorq && chip_select_n[2];
	wire ppi_chip_select_n = iorq && chip_select_n[3];
	assign dma_page_chip_select_n = iorq && chip_select_n[4];
`ifdef GAME_PORT
	// without iorq, which ends with the strobe (the write is taken at its end)
	wire joystick_select = ~address_enable_n && (address[15:3] == (16'h0200 >> 3));
`endif
	wire uart_cs = ~address_enable_n && ({address[15:3], 3'd0} == 16'h03f8);
	wire opl_chip_select_n = ~((iorq && ~address_enable_n) && (address[15:1] == (16'h0388 >> 1)));
	wire cga_chip_select_n = ~((~iorq && ~address_enable_n) && (address[19:15] == 5'b10111));
	wire ide0_chip_select_n      = ~(iorq && ~address_enable_n && ({address[15:4], 4'd0} == 16'h0300));
	wire lpt_cs = (iorq && ~address_enable_n) && (address[15:0] == 16'h0378);
	wire xtide_select_n = ~((~iorq && ~address_enable_n) && (address[19:14] == 6'b111011));
	// karabas: a 16 KB BIOS at FC000-FFFFF (Sergey Kiselev's XT BIOS of MiSTer PCXT)
	wire bios_8kb_select_n = ~((~iorq && ~address_enable_n) && (address[19:14] == 6'b111111));
	wire tandy_chip_select_n = ~((iorq && ~address_enable_n) && (address[15:3] == (16'h00c0 >> 3)));
`ifdef FLOPPY
	wire floppy0_chip_select_n = ~(~address_enable_n && (({address[15:2], 2'd0} == 16'h03F0) || ({address[15:1], 1'd0} == 16'h03F4) || ({address[15:0]} == 16'h03F7)));
`endif
	// wire xtctl_chip_select = (iorq && ~address_enable_n && address[15:0] == 16'h8888);

`ifdef FLOPPY
	// karabas: the memory cycles of the floppy DMA reach the RAM too (MiSTer: RAM.sv decodes
	// the address alone; here the RAM needed the bus of the CPU)
	wire fdd_dma_mem = fdd_dma_ack && (~memory_read_n || ~memory_write_n);
	wire ram_select_n = ~((~iorq && ~address_enable_n) || fdd_dma_mem);
`else
	wire ram_select_n = ~(~iorq && ~address_enable_n);
`endif
	wire bios_select_n = ~(bios_8kb_select_n && (~iorq && ~address_enable_n) && (address[19:16] == 4'b1111));

	wire nmi_mask_register_n = ~(((tandy_video && iorq) && ~address_enable_n) && (address[15:3] == (16'h00a0 >> 3)));
	wire tandy_page_cs = (iorq && ~address_enable_n) && (address[15:0] == 16'h03df);

	wire    [3:0] ems_page_address  = (ems_address == 2'b00) ? 4'b1100 : (ems_address == 2'b01) ? 4'b1101 : 4'b1110;
	wire ems_oe = ((iorq && ~address_enable_n) && ems_enabled) && ({address[15:2], 2'd0} == 16'h0260);
	reg [0:3] ena_ems;
	wire ems_b1 = (~iorq && ena_ems[0]) && (address[19:14] == {ems_page_address, 2'b00});
	wire ems_b2 = (~iorq && ena_ems[1]) && (address[19:14] == {ems_page_address, 2'b01});
	wire ems_b3 = (~iorq && ena_ems[2]) && (address[19:14] == {ems_page_address, 2'b10});
	wire ems_b4 = (~iorq && ena_ems[3]) && (address[19:14] == {ems_page_address, 2'b11});
	reg [23:0] map_ems;
	reg [1:0] ems_access_address;
	reg ems_write_enable;
	reg [7:0] write_map_ems_data;
	reg write_map_ena_data;
	always @(posedge clock or posedge reset)
		if (reset) begin
			ems_access_address <= 2'b11;
			ems_write_enable <= 1'b0;
			write_map_ems_data <= 8'd0;
			write_map_ena_data <= 1'b0;
		end
		else begin
			ems_access_address <= address[1:0];
			ems_write_enable <= ems_oe && ~io_write_n;
			write_map_ems_data <= (internal_data_bus == 8'hff ? 8'hff : (internal_data_bus < 8'h80 ? internal_data_bus[6:0] : map_ems[(3 - address[1:0]) * 6+:6]));
			write_map_ena_data <= (internal_data_bus == 8'hff ? 1'b0 : (internal_data_bus < 8'h80 ? 1'b1 : ena_ems[address[1:0]]));
		end
	always @(posedge clock or posedge reset)
		if (reset) begin
			map_ems <= 24'h000000;
			ena_ems <= 4'b0000;
		end
		else if (ems_write_enable) begin
			map_ems[(3 - ems_access_address) * 6+:6] <= write_map_ems_data;
			ena_ems[ems_access_address] <= write_map_ena_data;
		end

	wire timer_interrupt;
	reg keybord_interrupt;
	wire uart_interrupt;
`ifdef FLOPPY
	wire fdd_interrupt;
`endif
	wire [7:0] interrupt_data_bus_out;
	wire interrupt_to_cpu_buf;
	KF8259 u_KF8259(
		.clock(clock),
		.reset(reset),
		.chip_select_n(interrupt_chip_select_n),
		.read_enable_n(io_read_n),
		.write_enable_n(io_write_n),
		.address(address[0]),
		.data_bus_in(internal_data_bus),
		.data_bus_out(interrupt_data_bus_out),
		.cascade_in(3'b000),
		.slave_program_n(1'b1),
		.interrupt_acknowledge_n(interrupt_acknowledge_n),
		.interrupt_to_cpu(interrupt_to_cpu_buf),
`ifdef FLOPPY
`ifdef MOUSE_COM1
		.interrupt_request({interrupt_request[7], fdd_interrupt, interrupt_request[5], uart_interrupt & ~uart_cs, interrupt_request[3:2], keybord_interrupt, timer_interrupt})
`else
		.interrupt_request({interrupt_request[7], fdd_interrupt, interrupt_request[5:4], interrupt_request[3:2], keybord_interrupt, timer_interrupt})
`endif
`else
`ifdef MOUSE_COM1
		.interrupt_request({interrupt_request[7:5], uart_interrupt & ~uart_cs, interrupt_request[3:2], keybord_interrupt, timer_interrupt})
`else
		.interrupt_request({interrupt_request[7:4], interrupt_request[3:2], keybord_interrupt, timer_interrupt})
`endif
`endif		
	);
	
	always @(posedge clock or posedge reset)
		if (reset) 
			interrupt_to_cpu <= 1'b0;
		else if (cpu_clock_negedge)
			interrupt_to_cpu <= interrupt_to_cpu_buf;
		else
			interrupt_to_cpu <= interrupt_to_cpu;
	
	reg prev_p_clock_1;
	reg prev_p_clock_2;
	always @(posedge clock or posedge reset)
		if (reset) begin
			prev_p_clock_1 <= 1'b0;
			prev_p_clock_2 <= 1'b0;
		end
		else begin
			prev_p_clock_1 <= peripheral_clock;
			prev_p_clock_2 <= prev_p_clock_1;
		end
	wire p_clock_posedge = prev_p_clock_1 & ~prev_p_clock_2;
	reg timer_clock;
	always @(posedge clock or posedge reset)
		if (reset)
			timer_clock <= 1'b0;
		else if (p_clock_posedge)
			timer_clock <= ~timer_clock;
		else
			timer_clock <= timer_clock;
	wire [7:0] timer_data_bus_out;
	wire tim2gatespk = port_b_out[0] & ~port_b_io;
	wire spkdata = port_b_out[1] & ~port_b_io;
	KF8253 u_KF8253(
		.clock(clock),
		.reset(reset),
		.chip_select_n(timer_chip_select_n),
		.read_enable_n(io_read_n),
		.write_enable_n(io_write_n),
		.address(address[1:0]),
		.data_bus_in(internal_data_bus),
		.data_bus_out(timer_data_bus_out),
		.counter_0_clock(timer_clock),
		.counter_0_gate(1'b1),
		.counter_0_out(timer_counter_out[0]),
		.counter_1_clock(timer_clock),
		.counter_1_gate(1'b1),
		.counter_1_out(timer_counter_out[1]),
		.counter_2_clock(timer_clock),
		.counter_2_gate(tim2gatespk),
		.counter_2_out(timer_counter_out[2])
	);
	assign timer_interrupt = timer_counter_out[0];
	assign speaker_out = timer_counter_out[2] & spkdata;
	wire [7:0] ppi_data_bus_out;
	reg [7:0] port_a_in;
	KF8255 u_KF8255(
		.clock(clock),
		.reset(reset),
		.chip_select_n(ppi_chip_select_n),
		.read_enable_n(io_read_n),
		.write_enable_n(io_write_n),
		.address(address[1:0]),
		.data_bus_in(internal_data_bus),
		.data_bus_out(ppi_data_bus_out),
		.port_a_in(port_a_in),
		.port_a_out(port_a_out),
		.port_a_io(port_a_io),
		.port_b_in(port_b_in),
		.port_b_out(port_b_out),
		.port_b_io(port_b_io),
		.port_c_in(port_c_in),
		.port_c_out(port_c_out),
		.port_c_io(port_c_io)
	);
	wire ps2_send_clock;
	wire keybord_irq;
	wire [7:0] keycode_buf;
	wire [7:0] keycode;
	wire [7:0] tandy_keycode;
	wire prev_ps2_reset;
	reg prev_ps2_reset_n;
	wire lock_recv_clock;
	wire clear_keycode = port_b_out[7];
	wire ps2_reset_n = (~tandy_video ? port_b_out[6] : 1'b1);
	always @(posedge clock or posedge reset)
		if (reset)
			prev_ps2_reset_n <= 1'b0;
		else
			prev_ps2_reset_n <= ps2_reset_n;

	KFPS2KB_direct u_KFPS2KB(
		.clock(clock),
		.reset(reset),
		.kb_scancode(kb_scancode),
		.kb_scancode_upd(kb_scancode_upd),
		.reset_keybord(~prev_ps2_reset_n & ps2_reset_n),
		.irq(keybord_irq),
		.keycode(keycode_buf),
		.clear_keycode(clear_keycode)
	);

	// MiSTer 7a9c8b1: 80h while the BIOS holds the keyboard in reset (port B bit 6), no slow keyboard
	// after a warm boot
	assign keycode = ps2_reset_n ? keycode_buf : 8'h80;

`ifdef SOUND_ADLIB
	// MiSTer 864d32c: Ctrl+Alt+Del resets the OPL for 100 us (no notes left playing after a warm boot)
	reg prev_keybord_irq;
	reg ctrl_down;
	reg alt_down;
	reg [15:0] opl_reset_cnt;
	wire opl_warm_reset = (opl_reset_cnt != 16'd0);
	always @(posedge clock or posedge reset)
		if (reset) begin
			prev_keybord_irq <= 1'b0;
			ctrl_down <= 1'b0;
			alt_down <= 1'b0;
			opl_reset_cnt <= 16'd0;
		end
		else begin
			prev_keybord_irq <= keybord_irq;
			if (opl_reset_cnt != 16'd0)
				opl_reset_cnt <= opl_reset_cnt - 16'd1;
			if (keybord_irq && ~prev_keybord_irq) begin
				case (keycode)
					8'h1D: ctrl_down <= 1'b1;
					8'h9D: ctrl_down <= 1'b0;
					8'h38: alt_down <= 1'b1;
					8'hB8: alt_down <= 1'b0;
					default: ;
				endcase
				if (keycode == 8'h53 && ctrl_down && alt_down)
					opl_reset_cnt <= 16'd5000;
			end
		end
`endif

	Tandy_Scancode_Converter u_Tandy_Scancode_Converter(
		.clock(clock),
		.reset(reset),
		.scancode(keycode),
		.keybord_irq(keybord_irq),
		.convert_data(tandy_keycode)
	);

	
`ifdef SOUND_ADLIB
	wire [7:0] jtopl2_dout;
	wire [7:0] opl32_data;
	assign opl32_data = (adlibhide ? 8'hff : jtopl2_dout);
	jtopl jtopl2_inst(
		.rst(reset | opl_warm_reset),
		.clk(clock),
		.cen(clk_en_opl2),
		.din(internal_data_bus),
		.dout(jtopl2_dout),
		.addr(address[0]),
		.cs_n(opl_chip_select_n),
		.wr_n(io_write_n),
		.irq_n(),
		.snd(jtopl2_snd_e),
		.sample()
	);
`endif
	
`ifdef SOUND_TANDY
	sn76489_top sn76489(
		.clock_i(clock),
		.clock_en_i(clk_en_opl2),
		.res_n_i(~reset),
		.ce_n_i(tandy_chip_select_n),
		.we_n_i(io_write_n),
		.ready_o(tandy_snd_rdy),
		.d_i(internal_data_bus),
		.aout_o(tandy_snd_e)
	);
`else
	assign tandy_snd_rdy = 1'b1;
`endif

	reg keybord_interrupt_ff;
	always @(posedge clock or posedge reset)
		if (reset) begin
			keybord_interrupt_ff <= 1'b0;
			keybord_interrupt <= 1'b0;
		end
		else begin
			keybord_interrupt_ff <= keybord_irq;
			keybord_interrupt <= keybord_interrupt_ff;
		end
	reg prev_io_read_n;
	reg prev_io_write_n;
	reg [7:0] write_to_uart;
	wire [7:0] uart_readdata_1;
	reg [7:0] uart_readdata;
	always @(posedge clock) begin
		prev_io_read_n <= io_read_n;
		prev_io_write_n <= io_write_n;
	end
`ifdef RTC_MCU
	// the index and a data write at the end of the write strobe (the select without iorq, which
	// ends with the strobe); bit 7 of the index is the NMI mask of an AT, not a register
	wire rtc_chip_select_n = ~(~address_enable_n && (address[15:1] == (16'h02C0 >> 1)));
	reg [7:0] rtc_index = 8'h00;
	reg [7:0] rtc_wdata = 8'h00;
	reg rtc_wr = 1'b0;
	always @(posedge clock) begin
		if (~io_write_n)
			rtc_wdata <= internal_data_bus;
		rtc_wr <= 1'b0;
		if (io_write_n & ~prev_io_write_n & ~rtc_chip_select_n) begin
			if (~address[0])
				rtc_index <= {1'b0, rtc_wdata[6:0]};
			else
				rtc_wr <= 1'b1;
		end
	end
	assign rtc_a = rtc_index;
	assign rtc_di = rtc_wdata;
	assign rtc_cs = rtc_wr;
	assign rtc_wr_n = ~rtc_wr;
	// the registers as the firmware keeps them (since firmware #97 without an EEPROM bank: A 26h,
	// B 02h, 24 hours, BCD)
	wire [7:0] rtc_readdata = rtc_do;
`endif
`ifdef MIDI_MPU401
	// a write at the end of its strobe, a read latched at its start (the read clears the
	// acknowledge, the CPU takes the byte later in the cycle)
	wire mpu401_chip_select_n = ~(~address_enable_n && (address[15:1] == (16'h0330 >> 1)));
	reg [7:0] mpu401_wdata = 8'h00;
	reg [7:0] mpu401_readdata = 8'h00;
	wire [7:0] mpu401_readdata_1;
	wire mpu401_read = ~io_read_n & prev_io_read_n & ~mpu401_chip_select_n;
	always @(posedge clock) begin
		if (~io_write_n)
			mpu401_wdata <= internal_data_bus;
		if (mpu401_read)
			mpu401_readdata <= mpu401_readdata_1;
	end
	mpu401_tx mpu401_inst(
		.clk(clock),
		.reset(reset),
		.address(address[0]),
		.write(io_write_n & ~prev_io_write_n & ~mpu401_chip_select_n),
		.writedata(mpu401_wdata),
		.read(mpu401_read),
		.readdata(mpu401_readdata_1),
		.midi_tx(midi_tx)
	);
`endif
	reg [7:0] keycode_ff;
	always @(posedge clock or posedge reset)
		if (reset) begin
			keycode_ff <= 8'h00;
			port_a_in <= 8'h00;
		end
		else begin
			keycode_ff  <= ~tandy_video ? keycode : tandy_keycode;
			port_a_in <= keycode_ff;
		end
	reg [7:0] lpt_data = 8'hff;
	reg [7:0] tandy_page_data = 8'h00;
	reg [7:0] nmi_mask_register_data = 8'hff;
	always @(posedge clock) begin
		
		if (~io_write_n)
			write_to_uart <= internal_data_bus;
		else
			write_to_uart <= write_to_uart;
		
		if (lpt_cs && ~io_write_n)
			lpt_data <= internal_data_bus;
//      if ((xtctl_chip_select) && (~io_write_n))
//         xtctl <= internal_data_bus;

		if (tandy_page_cs && ~io_write_n)		
			tandy_page_data <= internal_data_bus;
		if (~nmi_mask_register_n && ~io_write_n)
			nmi_mask_register_data <= internal_data_bus;
	end
	 
`ifdef MOUSE_COM1
	wire rts_n;	
	wire iorq_uart = (io_write_n & ~prev_io_write_n) || (~io_read_n & prev_io_read_n);
	wire uart_tx;
	uart uart1(
		.clk(clock),
		.br_clk(clk_uart),
		.reset(reset),
		.address(address[2:0]),
		.writedata(write_to_uart),
		.read(~io_read_n & prev_io_read_n),
		.write(io_write_n & ~prev_io_write_n),
		.readdata(uart_readdata_1),
		.cs(uart_cs & iorq_uart),
		.rx(uart_tx),
      .cts_n(0),
      .dcd_n(0),
      .dsr_n(0),
      .ri_n(1),
      .rts_n(rts_n),
		.irq(uart_interrupt)
	);

	assign uart_tx = serial_mouse_tx;
	assign serial_mouse_rts = ~rts_n;
`endif
	
	always @(posedge clock)
		if (~io_read_n)
			uart_readdata <= uart_readdata_1;
		else
			uart_readdata <= uart_readdata;
	
	reg [19:0] video_ram_address;
	reg [7:0] video_ram_data;
	reg video_memory_write_n;
	reg video_memory_read_n;
	reg cga_chip_select_n_1;
	reg [14:0] video_io_address;
	reg [7:0] video_io_data;
	reg video_io_write_n;
	reg video_io_read_n;
	reg video_address_enable_n;
	reg [14:0] cga_io_address_1;
	reg [14:0] cga_io_address_2;
	reg [7:0] cga_io_data_1;
	reg [7:0] cga_io_data_2;
	reg cga_io_write_n_1;
	reg cga_io_write_n_2;
	reg cga_io_write_n_3;
	reg cga_io_read_n_1;
	reg cga_io_read_n_2;
	reg cga_io_read_n_3;
	reg cga_address_enable_n_1;
	reg cga_address_enable_n_2;
	always @(posedge clock)
		if (~io_write_n | ~io_read_n) begin
			video_io_address <= address[14:0];
			video_io_data <= internal_data_bus;
		end
		else begin
			video_io_address <= video_io_address;
			video_io_data <= video_io_data;
		end
	always @(posedge clock) begin
		video_ram_address <= address[19:0];
		video_ram_data <= internal_data_bus;
		video_memory_write_n <= memory_write_n;
		video_memory_read_n <= memory_read_n;
		cga_chip_select_n_1 <= cga_chip_select_n;
		video_io_write_n <= io_write_n;
		video_io_read_n <= io_read_n;
		video_address_enable_n <= address_enable_n;
	end

	reg [7:0] cga_vram_cpu_dout;
	reg CGA_VRAM_ENABLE_ff;
	reg CGA_VRAM_ENABLE_ff_2;
	reg CGA_VRAM_ENABLE_ff_3;
	reg [19:0] cga_crtc_ff;
	reg [20:0] tandy_crtc_ff;
	always @(negedge clock) begin
		CGA_VRAM_ENABLE_ff <= CGA_VRAM_ENABLE;
		CGA_VRAM_ENABLE_ff_2 <= CGA_VRAM_ENABLE_ff;
		CGA_VRAM_ENABLE_ff_3 <= CGA_VRAM_ENABLE_ff_3;
		cga_crtc_ff <= cga_crtc;
		tandy_crtc_ff <= tandy_crtc;
	end

	always @(posedge clk_vga_cga) begin
		cga_io_address_1 <= video_io_address;
		cga_io_address_2 <= cga_io_address_1;
		cga_io_data_1 <= video_io_data;
		cga_io_data_2 <= cga_io_data_1;
		cga_io_write_n_1 <= video_io_write_n;
		cga_io_write_n_2 <= cga_io_write_n_1;
		cga_io_write_n_3 <= cga_io_write_n_2;
		cga_io_read_n_1 <= video_io_read_n;
		cga_io_read_n_2 <= cga_io_read_n_1;
		cga_io_read_n_3 <= cga_io_read_n_2;
		cga_address_enable_n_1 <= video_address_enable_n;
		cga_address_enable_n_2 <= cga_address_enable_n_1;		
		cga_vram_cpu_dout <= SRAM_DATA;

	end
	wire [3:0] video_cga;
	wire [18:0] CGA_VRAM_ADDR;
	wire [7:0] CGA_VRAM_DOUT;
	
	wire CGA_CRTC_OE;
	reg CGA_CRTC_OE_1;
	reg CGA_CRTC_OE_2;
	wire [7:0] CGA_CRTC_DOUT;
	reg [7:0] CGA_CRTC_DOUT_1;
	reg [7:0] CGA_CRTC_DOUT_2;
	localparam MDA_70HZ = 0;
	wire thin_font;
	assign thin_font = 1'b0;
	cga_vgaport vga_cga(
		.clk(clk_vga_cga),
		.video(video_cga),
		.red(VGA_R),
		.green(VGA_G),
		.blue(VGA_B)
	);
	wire isa_op_enable;
	wire scandoubler;
	wire hsync;
	wire dbl_hsync;
	wire [3:0] video;
	wire [3:0] dbl_video;
	assign VGA_HSYNC = scandoubler ? ~dbl_hsync : hsync;
	assign video_cga = scandoubler ? dbl_video : video;
	assign CGA_VIDEO = video;
	assign CGA_HSYNC = hsync;

	cga cga1(
		.clk(clk_vga_cga),

		.bus_a(cga_io_address_2),
		.bus_ior_l(cga_io_read_n_3),
		.bus_iow_l(cga_io_write_n_3),
		.bus_aen(cga_address_enable_n_2),
		.vram_din((splashscreen ? CGA_VRAM_DOUT : cga_vram_cpu_dout)),

		.bus_memr_l(1'd0),
		.bus_memw_l(1'd0),
		.bus_d(cga_io_data_2),
		.bus_out(CGA_CRTC_DOUT),
		.bus_dir(CGA_CRTC_OE),
		.vram_enable(CGA_VRAM_ENABLE),
		.vram_addr(CGA_VRAM_ADDR),
		.hsync(hsync),
		.dbl_hsync(dbl_hsync),
		.hblank(VGA_HBlank),
		.vsync(VGA_VSYNC),
		.vblank(VGA_VBlank),
		.de_o(de_o),
		.video(video),
		.dbl_video(dbl_video),
		.splashscreen(splashscreen),
		.thin_font(thin_font),
		.tandy_video(tandy_video),
		.grph_mode(grph_mode),
		.hres_mode(hres_mode),
		.isa_op_enable(isa_op_enable)
	);
	

	assign scandoubler = ~btn_green_n_i;
	assign turbo = ~btn_yellow_n_i;

	always @(posedge clock) begin
		CGA_CRTC_OE_1 <= CGA_CRTC_OE;
		CGA_CRTC_OE_2 <= CGA_CRTC_OE_1;
		CGA_CRTC_DOUT_1 <= CGA_CRTC_DOUT;
		CGA_CRTC_DOUT_2 <= CGA_CRTC_DOUT_1;
	end
	wire pcxt_loading = ioctl_download && (ioctl_index[5:0] == 0);
	wire tandy_loading = ioctl_download && (ioctl_index[5:0] == 1);
	wire xtide_loading = ioctl_download && (ioctl_index == 2);
	wire pcxt_loader = pcxt_loading && (ioctl_addr[24:16] == 9'b000000000);
	wire tandy_loader = tandy_loading && (ioctl_addr[24:16] == 9'b000000000);
	wire bios_loader = pcxt_loader || tandy_loader;
	reg bios_loaded = 1'b0;
	reg bios_loading = 1'b0;

	wire [20:0] SRAM_ADDR_A;
	reg [20:0] latch_address;	
	always @(*)
		if (ems_b1)
			latch_address = {1'b1, map_ems[18+:6], address[13:0]};
		else if (ems_b2)
			latch_address = {1'b1, map_ems[12+:6], address[13:0]};
		else if (ems_b3)
			latch_address = {1'b1, map_ems[6+:6], address[13:0]};
		else if (ems_b4)
			latch_address = {1'b1, map_ems[0+:6], address[13:0]};
		else
			latch_address = {1'b0, address};

	wire [20:0] tandy_processor = {1'b0, nmi_mask_register_data[3:1], tandy_page_data[5:4], (tandy_page_data[3] ? tandy_page_data[3] : latch_address[14]), latch_address[13:0]};
	wire [20:0] tandy_crtc = {1'b0, nmi_mask_register_data[3:1], tandy_page_data[2:1], (tandy_page_data[0] ? tandy_page_data[0] : CGA_VRAM_ADDR[14]), CGA_VRAM_ADDR[13:0]};
	wire [19:0] cga_crtc = {6'b10111, CGA_VRAM_ADDR[14:0]};

	defparam cga1.BLINK_MAX = 24'd4772727;
	wire [7:0] bios_cpu_dout;
	wire [7:0] xtide_cpu_dout;
	wire [7:0] ram_cpu_dout;
	wire SRAM_WE_n_A;

	ram ram(
		.clka(clock),
		.wea(~memory_write_n),
		.dina(internal_data_bus),
		.douta(ram_cpu_dout),

		.ena(~ram_select_n || ~cga_chip_select_n || ~bios_select_n),
		.addra(((tandy_16_gfx && ~cga_chip_select_n) && ~latch_address[20] ? tandy_processor : latch_address)),
		.SRAM_ADDR(SRAM_ADDR_A),
		.SRAM_WE_n(SRAM_WE_n_A),

		.SRAM_DATA_i(SRAM_DATA),
		.SRAM_DATA_o(SRAM_DATA_A_o)
	);

	assign SRAM_WE_n = (CGA_VRAM_ENABLE_ff ? 1'b1 : SRAM_WE_n_A);
	assign SRAM_ADDR = (CGA_VRAM_ENABLE_ff ? (tandy_16_gfx ? tandy_crtc_ff : cga_crtc_ff) : SRAM_ADDR_A);

	assign SRAM_DATA = (~SRAM_WE_n ? SRAM_DATA_A_o : 8'hzz);
	
	// karabas: the BIOS (16 KB, FC000-FFFFF) and the XTIDE BIOS (EC000-EFFFF) also written by the
	// rom loader of the mcu (the roms of core*.json; the PC is in reset meanwhile): rom address
	// 0000-3FFF the BIOS, 4000-7FFF the XTIDE BIOS. The .hex files stay as their first contents.
	wire rom_bios_we = rom_wr && ~rom_addr[14];
	wire rom_xtide_we = rom_wr && rom_addr[14];
	wire bios_cpu_we = 1'b0;

	bram #(.AW(14), .filename(`ROM_BIOS)) bios
	(
		.clka(clock),
		.ena(~bios_8kb_select_n || rom_bios_we),
		.douta(bios_cpu_dout),
		.wea(rom_bios_we || bios_cpu_we),
		.addra(rom_bios_we ? rom_addr[13:0] : address[13:0]),
		.dina(rom_bios_we ? rom_data : internal_data_bus),
		.istandy(tandy_video)
	);

	bram #(.AW(14), .filename(`XTIDE_BIOS)) xtide
	(
		.clka(clock),
		.ena(~xtide_select_n || rom_xtide_we),
		.wea(rom_xtide_we || bios_cpu_we),
		.addra(rom_xtide_we ? rom_addr[13:0] : address[13:0]),
		.dina(rom_xtide_we ? rom_data : internal_data_bus),
		.douta(xtide_cpu_dout)
	);

	`ifdef SPLASH_ENABLE
		bram #(.AW(12), .filename(`SPLASH_SCR)) splash			
			(
				.clka(clk_vga_cga),
				.wea(1'b0),
				.ena(splashscreen && CGA_VRAM_ENABLE),
				.addra(CGA_VRAM_ADDR[11:0]),
				.dina(8'h00),
				.douta(CGA_VRAM_DOUT)
			);
			
	`endif

    //
    // XT2IDE
    //
    wire   [7:0]   xt2ide0_data_bus_out;
    wire           ide0_cs1fx;
    wire           ide0_cs3fx;
    wire           ide0_io_read_n;
    wire           ide0_io_write_n;
    wire   [2:0]   ide0_address;
    wire   [15:0]  ide0_data_bus_in;
    wire   [15:0]  ide0_data_bus_out;

    XT2IDE xt2ide0 (
        .clock              (clock),
        .reset              (reset),

        .high_speed         (0),

        .chip_select_n      (ide0_chip_select_n),
        .io_read_n          (io_read_n),
        .io_write_n         (io_write_n),

        .address            (address[3:0]),
        .data_bus_in        (internal_data_bus),
        .data_bus_out       (xt2ide0_data_bus_out),

        .ide_cs1fx          (ide0_cs1fx),
        .ide_cs3fx          (ide0_cs3fx),
        .ide_io_read_n      (ide0_io_read_n),
        .ide_io_write_n     (ide0_io_write_n),

        .ide_address        (ide0_address),
        .ide_data_bus_in    (ide0_data_bus_in),
        .ide_data_bus_out   (ide0_data_bus_out)
    );
	 
	 // 
	 // XTIDE-CF
	 // 
	 
	
	assign ide_cs_n = {ide0_cs3fx, ide0_cs1fx};
	assign ide_rd_n = ide0_io_read_n;
	assign ide_wr_n = ide0_io_write_n;
	assign ide_a = ide0_address;
	assign ide_dout = ide0_data_bus_out;
	assign ide0_data_bus_in = ide_din;
	assign ide_reset_n = ~reset;

`ifdef FLOPPY
	//
	// karabas: the floppy controller (floppy.v of MiSTer PCXT, its glue of Peripherals.sv),
	// ports 3F0-3F7, DMA channel 2, IRQ 6, two drives
	//
	reg [7:0] write_to_fdd = 8'h00;
	reg [2:0] fdd_io_address = 3'd0;
	reg fdd_io_read = 1'b0, fdd_io_read_1 = 1'b0, fdd_io_write = 1'b0;
	wire [7:0] fdd_readdata_wire;
	wire [7:0] fdd_dma_readdata;
	reg [7:0] fdd_readdata = 8'h00;
	wire fdd_dma_req_wire;
	reg fdd_dma_req_r = 1'b0;
	reg prev_fdd_dma_ack = 1'b0;
	reg fdd_dma_tc = 1'b0;
	// the reset of system comes from a register on the falling edge of the clock: half a clock
	// was too short for its path through floppy.v (selected_drive, the drive arrays)
	reg fdd_rst_n = 1'b0;
	always @(posedge clock)
		fdd_rst_n <= ~reset;

	always @(posedge clock)
		if (~io_write_n)
			write_to_fdd <= internal_data_bus;

	// a read at the start of its strobe, a write at its end
	always @(posedge clock) begin
		fdd_io_address <= address[2:0];
		fdd_io_read <= ~io_read_n & prev_io_read_n & ~floppy0_chip_select_n;
		fdd_io_read_1 <= fdd_io_read;
		fdd_io_write <= io_write_n & ~prev_io_write_n & ~floppy0_chip_select_n;
	end

	// a DMA byte at the end of its DACK
	wire fdd_dma_read = fdd_dma_ack & ~io_read_n;
	always @(posedge clock)
		prev_fdd_dma_ack <= fdd_dma_ack;
	wire fdd_dma_rw_ack = prev_fdd_dma_ack & ~fdd_dma_ack;

	always @(posedge clock)
		if (fdd_dma_ack) begin
			if (~fdd_dma_tc)
				fdd_dma_tc <= terminal_count;
		end
		else
			fdd_dma_tc <= 1'b0;

	floppy u_floppy(
		.clk(clock),
		.rst_n(fdd_rst_n),

		.dma_req(fdd_dma_req_wire),
		.dma_ack(fdd_dma_rw_ack),
		.dma_tc(fdd_dma_tc & fdd_dma_rw_ack),
		.dma_readdata(write_to_fdd),
		.dma_writedata(fdd_dma_readdata),

		.irq(fdd_interrupt),

		.io_address(fdd_io_address),
		.io_read(fdd_io_read),
		.io_readdata(fdd_readdata_wire),
		.io_write(fdd_io_write),
		.io_writedata(write_to_fdd),

		.fdd0_inserted(),

		.mgmt_address(fdd_mgmt_address),
		.mgmt_fddn(fdd_mgmt_fddn),
		.mgmt_write(fdd_mgmt_write),
		.mgmt_writedata(fdd_mgmt_writedata),
		.mgmt_read(fdd_mgmt_read),
		.mgmt_readdata(fdd_mgmt_readdata),

		.wp(2'b00),
		.clock_rate(`FDD_CLOCK_RATE),
		.request(fdd_request)
	);

	// DRQ in step with the CPU clock, as MiSTer (cpu_ce_negedge there)
	always @(posedge clock)
		if (fdd_dma_ack)
			fdd_dma_req_r <= 1'b0;
		else if (cpu_clock_negedge)
			fdd_dma_req_r <= fdd_dma_req_wire;
	assign fdd_dma_req = fdd_dma_req_r;

	always @(posedge clock)
		if (fdd_io_read_1 && ~address_enable_n)
			fdd_readdata <= fdd_readdata_wire;
		else if (fdd_dma_read)
			fdd_readdata <= fdd_dma_readdata;
`endif
	 
`ifdef GAME_PORT
	wire [7:0] joy_data;
	game_port joysticks(
		.clk(clock),
		.reset(reset),
		.start(io_write_n & ~prev_io_write_n & joystick_select),
		.joy0(joy0),
		.joy1(joy1),
		.d_out(joy_data)
	);
`endif
	always @(posedge clock)
		if (~interrupt_acknowledge_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= interrupt_data_bus_out;
		end
		else if (~interrupt_chip_select_n && ~io_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= interrupt_data_bus_out;
		end
		else if (~timer_chip_select_n && ~io_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= timer_data_bus_out;
		end
		else if (~ppi_chip_select_n && ~io_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= ppi_data_bus_out;
		end

`ifdef SOUND_ADLIB
		else if (~opl_chip_select_n && ~io_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= opl32_data;
		end
`endif

		else if (CGA_CRTC_OE_2) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= CGA_CRTC_DOUT_2;
		end
		else if (~xtide_select_n && ~memory_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= xtide_cpu_dout;
		end
		else if (~bios_8kb_select_n && ~memory_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= bios_cpu_dout;
		end
		else if ((~ram_select_n || ~bios_select_n) && ~memory_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= ram_cpu_dout;
		end
		else if (ems_oe && ~io_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= (ena_ems[address[1:0]] ? map_ems[(3 - address[1:0]) * 6+:6] : 8'hff);
		end
		else if (~nmi_mask_register_n && ~io_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= nmi_mask_register_data;
		end

		else if (~cga_chip_select_n && ~memory_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= cga_vram_cpu_dout;
		end
		else if (lpt_cs && ~io_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= lpt_data;
		end
		/*
      else if ((xtctl_chip_select) && (~io_read_n))
      begin
          data_bus_out_from_chipset <= 1'b1;
          data_bus_out <= xtctl;
      end
		*/
		else if ((~ide0_chip_select_n) && (~io_read_n)) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= xt2ide0_data_bus_out;
		end
`ifdef MIDI_MPU401
		else if ((~mpu401_chip_select_n) && (~io_read_n)) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= mpu401_readdata;
		end
`endif
`ifdef RTC_MCU
		else if ((~rtc_chip_select_n) && (~io_read_n)) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= address[0] ? rtc_readdata : rtc_index;
		end
`endif
`ifdef FLOPPY
		else if ((~floppy0_chip_select_n || fdd_dma_read) && (~io_read_n)) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= fdd_readdata;
		end
`endif
`ifdef MOUSE_COM1
      else if ((uart_cs) && (~io_read_n))
      begin
          data_bus_out_from_chipset <= 1'b1;
          data_bus_out <= uart_readdata;
      end
`endif
`ifdef GAME_PORT
		else if (joystick_select && ~io_read_n) begin
			data_bus_out_from_chipset <= 1'b1;
			data_bus_out <= joy_data;
		end
`endif
		else begin
			data_bus_out_from_chipset <= 1'b0;
			data_bus_out <= 8'b00000000;
		end
endmodule
