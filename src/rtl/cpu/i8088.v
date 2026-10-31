//------------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2020, Ted Fried <@MicroCoreLabs>
// SPDX-FileCopyrightText: (c) 2026, Marcus Andrade <marcus@opengateware.org>
//------------------------------------------------------------------------------
//
// Intel 8088 Microprocessor Core - Maximum Bus Mode Configuration
//
// Copyright (c) 2020, Ted Fried <@MicroCoreLabs>
// Copyright (c) 2026, Marcus Andrade <marcus@opengateware.org>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
//------------------------------------------------------------------------------
// Intel 8088 CPU - Maximum Bus Mode
//
// Description:
//   Top level for an 8088 in MAXIMUM mode: mcl86_eu_core (microcoded execution
//   unit) plus mcl86_biu_max (bus interface unit). 16-bit internal architecture
//   over an 8-bit external data bus, with a 20-bit multiplexed address/data bus
//   reaching 1 MB.
//
//   In maximum mode the CPU does not drive RD/WR/ALE itself. It emits a 3-bit
//   status code on s2_s0_out and an external 8288 bus controller turns that into
//   the actual command strobes. i8088_min is the same core wired for minimum
//   mode, where the CPU drives those pins directly; i8086 is the 16-bit sibling.
//
// Status encoding driven on s2_s0_out (what the 8288 decodes):
//
//   S2 S1 S0   Bus cycle              S2 S1 S0   Bus cycle
//    0  0  0   Interrupt acknowledge   1  0  0   Instruction (code) fetch
//    0  0  1   I/O read                1  0  1   Memory read
//    0  1  0   I/O write               1  1  0   Memory write
//    0  1  1   Halt                    1  1  1   Passive (no bus activity)
//
//   lock_n   - active low for the duration of an atomic (LOCK-prefixed) access
//              and across the INTA pair
//   s6_3_mux - selects what the upper address/status lines carry: 0 = address,
//              1 = status. It is a bus mux control, not a timing knob.
//
// Cycle accuracy and turbo:
//   Microcode loads the BIU's cycle counter with each instruction's nominal 8088
//   cycle count and the EU stalls until it expires, which is what makes timing
//   authentic. cycle_accrate = 0 forces the "counter expired" signal high, so the
//   EU never waits and the core runs as fast as CORE_CLK allows. The division
//   ratio and decrement value scale that counter for intermediate turbo speeds.
//
// Clocking: CORE_CLK is the fast internal clock that runs both units. CLK is the
//   8088 pin clock and is only edge-detected inside the BIU to place bus events
//   at real 8088 timing - it is not a second clock domain.
//
// Limitations:
//   - SEGMENT is declared [2:0] but the BIU only drives 2 bits, so SEGMENT[2] is
//     UNDRIVEN (Verilator reports WIDTHTRUNC at the BIU_SEGMENT connection).
//     Treat it as SEGMENT[1:0]: 00=ES 01=SS 10=CS 11=DS. Do not consume bit 2.
//   - TEST_N is tied low at the EU, so a WAIT instruction completes immediately
//     rather than waiting on a coprocessor.
//
// References:
//   - Intel 8088 datasheet - max-mode status encoding, bus cycle timing
//   - Intel 8288 Bus Controller datasheet
//   - Intel 8086 Family User's Manual (Oct 1979)
//------------------------------------------------------------------------------
//
// karabas: converted to Verilog-2005 with sv2v from MiSTer PCXT efce777 (rtl/8088/wrappers/i8088.sv) for XST

`default_nettype none
module i8088 (
	CORE_CLK,
	CLK,
	RESET,
	READY,
	INTR,
	NMI,
	ad_out,
	dout,
	din,
	lock_n,
	s6_3_mux,
	s2_s0_out,
	SEGMENT,
	biu_done,
	cycle_accrate,
	clock_cycle_counter_division_ratio,
	clock_cycle_counter_decrement_value,
	shift_read_timing,
	is8086,
	fake286_flags,
	word_read_request,
	word_write_request,
	data_bus_word_out,
	data_bus_word,
	word_access_possible
);
	input wire CORE_CLK;
	input wire CLK;
	input wire RESET;
	input wire READY;
	input wire INTR;
	input wire NMI;
	output wire [19:0] ad_out;
	output wire [7:0] dout;
	input wire [7:0] din;
	output wire lock_n;
	output wire s6_3_mux;
	output wire [2:0] s2_s0_out;
	output wire [2:0] SEGMENT;
	output wire biu_done;
	input wire cycle_accrate;
	input wire [7:0] clock_cycle_counter_division_ratio;
	input wire [7:0] clock_cycle_counter_decrement_value;
	input wire shift_read_timing;
	input wire is8086;
	input wire fake286_flags;
	output wire word_read_request;
	output wire word_write_request;
	output wire [15:0] data_bus_word_out;
	input wire [15:0] data_bus_word;
	input wire word_access_possible;
	wire [15:0] t_eu_biu_command;
	wire [15:0] t_eu_biu_dataout;
	wire [15:0] t_eu_register_r3;
	wire t_eu_prefix_lock;
	wire t_eu_flag_i;
	wire t_biu_done;
	wire t_biu_clk_counter_zero;
	wire t_biu_ad_oe;
	wire t_biu_nmi_caught;
	wire t_biu_nmi_debounce;
	wire t_biu_intr;
	wire t_pfq_empty;
	wire [7:0] t_pfq_top_byte;
	wire [15:0] t_pfq_addr_out;
	wire [15:0] t_biu_register_es;
	wire [15:0] t_biu_register_ss;
	wire [15:0] t_biu_register_cs;
	wire [15:0] t_biu_register_ds;
	wire [15:0] t_biu_register_rm;
	wire [15:0] t_biu_register_reg;
	wire [15:0] t_biu_return_data;
	mcl86_biu_max u_biu_core(
		.CORE_CLK_INT(CORE_CLK),
		.RESET_INT(RESET),
		.CLK(CLK),
		.READY_IN(READY),
		.NMI(NMI),
		.INTR(INTR),
		.AD_OE(t_biu_ad_oe),
		.AD_OUT(ad_out),
		.AD_IN(din),
		.LOCK_n(lock_n),
		.S6_3_MUX(s6_3_mux),
		.S2_S0_OUT(s2_s0_out),
		.EU_BIU_COMMAND(t_eu_biu_command),
		.EU_BIU_DATAOUT(t_eu_biu_dataout),
		.EU_REGISTER_R3(t_eu_register_r3),
		.EU_PREFIX_LOCK(t_eu_prefix_lock),
		.BIU_DONE(t_biu_done),
		.BIU_CLK_COUNTER_ZERO(t_biu_clk_counter_zero),
		.BIU_SEGMENT(SEGMENT),
		.BIU_NMI_CAUGHT(t_biu_nmi_caught),
		.BIU_NMI_DEBOUNCE(t_biu_nmi_debounce),
		.BIU_INTR(t_biu_intr),
		.PFQ_TOP_BYTE(t_pfq_top_byte),
		.PFQ_EMPTY(t_pfq_empty),
		.PFQ_ADDR_OUT(t_pfq_addr_out),
		.BIU_REGISTER_ES(t_biu_register_es),
		.BIU_REGISTER_SS(t_biu_register_ss),
		.BIU_REGISTER_CS(t_biu_register_cs),
		.BIU_REGISTER_DS(t_biu_register_ds),
		.BIU_REGISTER_RM(t_biu_register_rm),
		.BIU_REGISTER_REG(t_biu_register_reg),
		.BIU_RETURN_DATA(t_biu_return_data),
		.clock_cycle_counter_division_ratio(clock_cycle_counter_division_ratio),
		.clock_cycle_counter_decrement_value(clock_cycle_counter_decrement_value),
		.shift_read_timing(shift_read_timing),
		.IS8086(is8086),
		.WORD_READ_REQUEST(word_read_request),
		.WORD_WRITE_REQUEST(word_write_request),
		.DATA_BUS_WORD_OUT(data_bus_word_out),
		.DATA_BUS_WORD(data_bus_word),
		.WORD_ACCESS_POSSIBLE(word_access_possible)
	);
	mcl86_eu_core u_eu_core(
		.CORE_CLK_INT(CORE_CLK),
		.RESET_INT(RESET),
		.TEST_N_INT(1'b0),
		.FAKE286_FLAGS(fake286_flags),
		.EU_BIU_COMMAND(t_eu_biu_command),
		.EU_BIU_DATAOUT(t_eu_biu_dataout),
		.EU_REGISTER_R3(t_eu_register_r3),
		.EU_PREFIX_LOCK(t_eu_prefix_lock),
		.EU_FLAG_I(t_eu_flag_i),
		.BIU_DONE(t_biu_done),
		.BIU_CLK_COUNTER_ZERO((cycle_accrate ? t_biu_clk_counter_zero : 1'b1)),
		.BIU_NMI_CAUGHT(t_biu_nmi_caught),
		.BIU_NMI_DEBOUNCE(t_biu_nmi_debounce),
		.BIU_INTR(t_biu_intr),
		.PFQ_TOP_BYTE(t_pfq_top_byte),
		.PFQ_EMPTY(t_pfq_empty),
		.PFQ_ADDR_OUT(t_pfq_addr_out),
		.BIU_REGISTER_ES(t_biu_register_es),
		.BIU_REGISTER_SS(t_biu_register_ss),
		.BIU_REGISTER_CS(t_biu_register_cs),
		.BIU_REGISTER_DS(t_biu_register_ds),
		.BIU_REGISTER_RM(t_biu_register_rm),
		.BIU_REGISTER_REG(t_biu_register_reg),
		.BIU_RETURN_DATA(t_biu_return_data)
	);
	assign dout = ad_out[7:0];
	assign biu_done = t_biu_done;
endmodule
`default_nettype wire
