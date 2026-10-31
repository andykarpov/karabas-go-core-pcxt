`timescale 1ns / 1ps
`default_nettype none
/*
 com_usb.v
 karabas: a serial port (COM2, 2F8h, IRQ 3) on the USB serial port of the mcu: the registers of an
 8250 / 16450 without its shift registers. A byte written to THR goes to the mcu (tx_wr / tx_data
 to kg_mcu_uart: CMD_UART 00 d, the firmware sends it to its USB serial port); bytes of the mcu
 (rx_data, rx_idx: a new byte when the index changes) wait in a FIFO of 16 for RBR.
 - THR stays full (LSR THRE / TEMT 0) for the time of a 10-bit character at the speed of DLL / DLM
   (divisor x 86.8 us: divisor 1 is 115200 baud), so a program sees the speed it set and the link of
   the mcu is not flooded; LCR, the parity and the stop bits are only stored.
 - IIR: line status (overrun), received data, THR empty, none (01h); no FIFO (16450): FCR writes are
   ignored, IIR bits 7-6 are 0. MSR: CTS, DSR, DCD on; MCR loop: THR goes to the receive FIFO.
 - irq: IER x pending, gated by MCR OUT2 as on the PC.
*/
module com_usb #(
	parameter CHAR_CLKS = 13'd4340     // clocks of a character at divisor 1 (50 MHz: 86.8 us)
) (
	input wire clk,
	input wire reset,

	input wire [2:0] address,
	input wire write,                  // one-clock strobes
	input wire read,                   // at the start of a read: pops RBR, clears THRE / overrun
	input wire [7:0] writedata,
	output reg [7:0] readdata,         // combinational, valid during the read

	output wire irq,

	// kg_mcu_uart
	input wire [7:0] rx_data,
	input wire [7:0] rx_idx,
	output reg tx_wr = 1'b0,
	output reg [7:0] tx_data = 8'd0
);

reg [7:0] ier = 8'd0, lcr = 8'd0, mcr = 8'd0, scr = 8'd0, dll = 8'd12, dlm = 8'd0;
wire dlab = lcr[7];
wire loop = mcr[4];

// the receive FIFO
reg [7:0] fifo [0:15];
reg [3:0] wp = 4'd0, rp = 4'd0;
reg [4:0] n = 5'd0;
reg overrun = 1'b0;
reg [7:0] rx_idx_d = 8'd0;
reg first = 1'b1;
wire dr = (n != 5'd0);

// the transmitter
reg thr_busy = 1'b0;
reg [12:0] cc = 13'd0;
reg [15:0] dc = 16'd0;
reg thre_int = 1'b0;               // the THR empty interrupt, until IIR is read or THR written

wire wr_thr = write && address == 3'd0 && !dlab;
wire rd_rbr = read && address == 3'd0 && !dlab;
wire rd_iir = read && address == 3'd2;
wire rd_lsr = read && address == 3'd5;

// the interrupt pending, by priority
wire int_ls = ier[2] && overrun;
wire int_rd = ier[0] && dr;
wire int_th = ier[1] && thre_int;
wire [7:0] iir = int_ls ? 8'h06 : int_rd ? 8'h04 : int_th ? 8'h02 : 8'h01;
assign irq = mcr[3] && (int_ls || int_rd || int_th);

wire push_mcu = !first && (rx_idx != rx_idx_d) && !loop;
wire push_loop = wr_thr && loop;
wire push = push_mcu || push_loop;
wire [7:0] push_data = push_loop ? writedata : rx_data;

always @(posedge clk) begin
	tx_wr <= 1'b0;
	rx_idx_d <= rx_idx;
	first <= 1'b0;
	if (reset) begin
		ier <= 8'd0; lcr <= 8'd0; mcr <= 8'd0;
		wp <= 4'd0; rp <= 4'd0; n <= 5'd0;
		overrun <= 1'b0;
		thr_busy <= 1'b0;
		thre_int <= 1'b0;
	end else begin
		// the receive FIFO
		if (push && n != 5'd16) begin
			fifo[wp] <= push_data;
			wp <= wp + 1'd1;
		end
		if (push && n == 5'd16) overrun <= 1'b1;
		if (rd_rbr && dr) rp <= rp + 1'd1;
		n <= n + ((push && n != 5'd16) ? 5'd1 : 5'd0) - ((rd_rbr && dr) ? 5'd1 : 5'd0);
		if (rd_lsr) overrun <= 1'b0;

		// the registers
		if (write)
			case (address)
				3'd0: if (dlab) dll <= writedata;
				3'd1: if (dlab) dlm <= writedata; else begin
					// enabling the THR empty interrupt with THR empty raises it (8250)
					if (writedata[1] && !ier[1] && !thr_busy) thre_int <= 1'b1;
					ier <= {4'd0, writedata[3:0]};
				end
				3'd3: lcr <= writedata;
				3'd4: mcr <= {3'd0, writedata[4:0]};
				3'd7: scr <= writedata;
				default: ;
			endcase
		if (rd_iir && iir == 8'h02) thre_int <= 1'b0;

		// the transmitter: a character time per byte
		if (wr_thr) begin
			if (!loop) begin
				tx_wr <= 1'b1;
				tx_data <= writedata;
			end
			thr_busy <= 1'b1;
			thre_int <= 1'b0;
			cc <= CHAR_CLKS;
			dc <= ({dlm, dll} == 16'd0) ? 16'd1 : {dlm, dll};
		end else if (thr_busy) begin
			if (cc != 13'd0)
				cc <= cc - 1'd1;
			else if (dc != 16'd1) begin
				dc <= dc - 1'd1;
				cc <= CHAR_CLKS;
			end else begin
				thr_busy <= 1'b0;
				thre_int <= 1'b1;
			end
		end
	end
end

always @(*)
	case (address)
		3'd0: readdata = dlab ? dll : fifo[rp];
		3'd1: readdata = dlab ? dlm : ier;
		3'd2: readdata = iir;
		3'd3: readdata = lcr;
		3'd4: readdata = mcr;
		3'd5: readdata = {1'b0, !thr_busy, !thr_busy, 3'b000, overrun, dr};
		3'd6: readdata = loop ? {mcr[3], mcr[2], mcr[0], mcr[1], 4'h0} : 8'b1011_0000;
		default: readdata = scr;
	endcase

endmodule
