//------------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2020, Ted Fried <@MicroCoreLabs>
// SPDX-FileCopyrightText: (c) 2026, Marcus Andrade <marcus@opengateware.org>
//------------------------------------------------------------------------------
//
// MCL86 - Intel 8086/8088 Microprocessor Compatible Gateware IP Core
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
// Execution Unit - Microcode-Based Instruction Processing Engine
//
// Description:
//   The EU owns the architectural register file (AX..DI, FLAGS), the ALU, and
//   the microcode sequencer. It never touches the bus: memory and I/O go to the
//   Bus Interface Unit over a request/done handshake, and instruction bytes
//   arrive through the BIU's prefetch queue. That split is what lets one EU
//   serve both the 8-bit 8088 and the 16-bit 8086 unchanged - it issues
//   width-tagged bus requests and never learns how wide the bus really is.
//
//   Execution is microcoded. Each 8086 instruction is a subroutine in a 4Kx32
//   ROM; the sequencer retires one microword per clock, decoding it into a
//   type / destination / two operand-select fields. Instruction dispatch is
//   itself a microcode jump - the opcode byte from the queue is concatenated
//   into the microcode address to vector into that instruction's handler.
//
//   The ALU is deliberately minimal (ADD, BYTESWAP, AND, OR, XOR, single-bit
//   SHR). There is no subtractor: microcode builds SUB from ADD by complementing
//   an operand and adding one (see 0x0A46). Wider shifts are microcode loops.
//
// Datapath:
//
//     eu_rom_address --> [ mcl86_ucode 4Kx32 ] --> decode --> operand muxes
//            ^                                                     |
//            |                                                     v
//            +------------- writeback / jump <----------------- [ ALU ]
//
// Sequencer lead - the one thing to know before editing this file:
//
//   The ROM read is registered while eu_rom_address keeps incrementing, so the
//   address counter runs TWO microwords ahead of the word being executed. Hence:
//
//   1. A taken jump has already admitted the next two words, so the sequencer
//      raises eu_stall_pipeline for one clock to squash them.
//   2. RTL that identifies an instruction by watching the microcode PC hit a
//      constant is watching an address the sequencer also GRAZES on its way past
//      a neighbouring routine. A marker must sit deep enough into its own arm
//      that no other path can overshoot into it. Not hypothetical: this is how a
//      marker meant for IDIV once fired for plain DIV (see the note below).
//
// FLAGS layout - eu_flags is not just the architectural FLAGS word. Microcode
//   reuses every bit the 8086 leaves RESERVED as private scratch:
//
//     bit  15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
//     8086  -   -   -   -  OF  DF  IF  TF  SF  ZF   -  AF   -  PF   -  CF
//     here RPZ REP LCK NMD  OF  DF  IF  TF  SF  ZF TFD  AF NMP  PF TMP  CF
//
//   Architectural flags sit where an 8086 programmer expects them; the reserved
//   bits carry the REP/REPNZ/LOCK prefix latches, NMI debounce and pending, the
//   TF debounce, and a temp. Consumers wanting a real FLAGS value must mask the
//   scratch bits off, as sim/sst does.
//
// Limitations:
//   - Ten flag alias wires (eu_flag_o/d/s/z/a/p, eu_prefix_rep/repnz,
//     eu_nmi_pending, eu_flag_temp) are driven but never read. They name the bit
//     layout for waveforms; microcode reads these bits through eu_flags. Not dead
//     code to be swept up.
//   - system_signals bits 15, 14 and 10 have no driver. Microcode must not select
//     them as an operand source.
//   - The microcode addresses this file watches are load-bearing: tools/uccheck.py
//     scrapes them out of this source text, comments included. Write addresses in
//     comments as 0xNNNN, never in the eu_rom_address == 'hNNNN form it matches.
//
// References:
//   - Intel 8086 Family User's Manual (Oct 1979) - FLAGS, STI/IF delay, TF
//   - MCL86 by Ted Fried (MicroCoreLabs) - original microcoded implementation
//   - docs/learnings.md - the IDIV marker and divide-FLAGS investigations
//   - tools/uccheck.py - microcode round-trip and marker-coupling tripwire
//
// Changelog:
// 1.0 - 10/8/15 - Initial revision
// 2.0 - 11/6/22 - Changed overflow flag calculation into rtl instead of microcode
// 3.0 - 9/29/25 - For DIV overflow AX and DX are restored to initial values
//------------------------------------------------------------------------------
//
// karabas: converted to Verilog-2005 with sv2v from MiSTer PCXT efce777 (rtl/8088/mcl86_eu_core.sv) for XST

`default_nettype none
module mcl86_eu_core (
	CORE_CLK_INT,
	RESET_INT,
	TEST_N_INT,
	FAKE286_FLAGS,
	EU_BIU_COMMAND,
	EU_BIU_DATAOUT,
	EU_REGISTER_R3,
	EU_PREFIX_LOCK,
	EU_FLAG_I,
	BIU_DONE,
	BIU_CLK_COUNTER_ZERO,
	BIU_NMI_CAUGHT,
	BIU_NMI_DEBOUNCE,
	BIU_INTR,
	PFQ_TOP_BYTE,
	PFQ_EMPTY,
	PFQ_ADDR_OUT,
	BIU_REGISTER_ES,
	BIU_REGISTER_SS,
	BIU_REGISTER_CS,
	BIU_REGISTER_DS,
	BIU_REGISTER_RM,
	BIU_REGISTER_REG,
	BIU_RETURN_DATA
);
	input wire CORE_CLK_INT;
	input wire RESET_INT;
	input wire TEST_N_INT;
	input wire FAKE286_FLAGS;
	output wire [15:0] EU_BIU_COMMAND;
	output wire [15:0] EU_BIU_DATAOUT;
	output wire [15:0] EU_REGISTER_R3;
	output wire EU_PREFIX_LOCK;
	output wire EU_FLAG_I;
	input wire BIU_DONE;
	input wire BIU_CLK_COUNTER_ZERO;
	input wire BIU_NMI_CAUGHT;
	output wire BIU_NMI_DEBOUNCE;
	input wire BIU_INTR;
	input wire [7:0] PFQ_TOP_BYTE;
	input wire PFQ_EMPTY;
	input wire [15:0] PFQ_ADDR_OUT;
	input wire [15:0] BIU_REGISTER_ES;
	input wire [15:0] BIU_REGISTER_SS;
	input wire [15:0] BIU_REGISTER_CS;
	input wire [15:0] BIU_REGISTER_DS;
	input wire [15:0] BIU_REGISTER_RM;
	input wire [15:0] BIU_REGISTER_REG;
	input wire [15:0] BIU_RETURN_DATA;
	reg [12:0] eu_rom_address;
	reg [51:0] eu_calling_address;
	reg eu_stall_pipeline;
	wire [31:0] eu_rom_data;
	wire [7:0] eu_rom_sel;
	wire new_instruction;
	wire [2:0] eu_opcode_type;
	wire [3:0] eu_opcode_dst_sel;
	wire [3:0] eu_opcode_op0_sel;
	wire [3:0] eu_opcode_op1_sel;
	wire [15:0] eu_opcode_immediate;
	wire eu_opcode_jump_call;
	wire [2:0] eu_opcode_jump_src;
	wire [3:0] eu_opcode_jump_cond;
	wire eu_jump_boolean;
	reg [15:0] eu_register_ax;
	reg [15:0] eu_register_bx;
	reg [15:0] eu_register_cx;
	reg [15:0] eu_register_dx;
	reg [15:0] eu_register_sp;
	reg [15:0] eu_register_bp;
	reg [15:0] eu_register_si;
	reg [15:0] eu_register_di;
	reg [15:0] eu_flags;
	reg [15:0] eu_register_r0;
	reg [15:0] eu_register_r1;
	reg [15:0] eu_register_r2;
	reg [15:0] eu_register_r3;
	wire eu_flag_c;
	wire eu_flag_temp;
	wire eu_flag_p;
	wire eu_nmi_pending;
	wire eu_flag_a;
	wire eu_tf_debounce;
	wire eu_flag_z;
	wire eu_flag_s;
	wire eu_flag_t;
	wire eu_flag_i;
	wire eu_flag_d;
	wire eu_flag_o;
	wire eu_prefix_lock;
	wire eu_prefix_rep;
	wire eu_prefix_repnz;
	wire [15:0] eu_operand0;
	wire [15:0] eu_operand1;
	wire [15:0] eu_alu2;
	wire [15:0] eu_alu3;
	wire [15:0] eu_alu4;
	wire [15:0] eu_alu5;
	wire [15:0] eu_alu6;
	wire [15:0] eu_alu7;
	wire [15:0] eu_alu_out;
	wire [15:0] eu_alu_logic;
	reg [15:0] eu_alu_last_result;
	wire [15:0] adder_out;
	wire [16:0] carry;
	wire eu_pushf_serialize;
	reg eu_add_carry;
	reg eu_add_carry8;
	reg eu_add_aux_carry;
	reg eu_add_overflow16;
	reg eu_add_overflow8;
	wire eu_parity;
	reg eu_overflow_override;
	reg eu_add_overflow8_fixed;
	reg eu_add_overflow16_fixed;
	wire [15:0] add_total;
	wire [15:0] adc_total;
	wire [15:0] sub_total;
	wire [15:0] sbb_total;
	reg idiv_opcode;
	reg [15:0] initial_ax;
	reg [15:0] initial_dx;
	reg [15:0] div_flag_src;
	reg biu_done_d1;
	reg biu_done_d2;
	reg biu_done_caught;
	wire eu_biu_req;
	reg eu_biu_req_d1;
	reg [15:0] eu_biu_command;
	reg [15:0] eu_biu_dataout;
	reg intr_enable_delayed;
	wire intr_asserted;
	reg eu_flag_t_d;
	reg eu_tr_latched;
	wire [15:0] system_signals;
	mcl86_ucode u_ucode_rom(
		.clk(CORE_CLK_INT),
		.addr(eu_rom_address[11:0]),
		.dout(eu_rom_data),
		.dout_sel(eu_rom_sel)
	);
	assign eu_opcode_type = eu_rom_data[30:28];
	assign eu_opcode_dst_sel = eu_rom_data[27:24];
	assign eu_opcode_op0_sel = eu_rom_data[23:20];
	assign eu_opcode_op1_sel = eu_rom_data[19:16];
	assign eu_opcode_immediate = eu_rom_data[15:0];
	assign eu_opcode_jump_call = eu_rom_data[24];
	assign eu_opcode_jump_src = eu_rom_data[22:20];
	assign eu_opcode_jump_cond = eu_rom_data[19:16];
	function automatic [15:0] mux4;
		input [1:0] sel;
		input [15:0] d0;
		input [15:0] d1;
		input [15:0] d2;
		input [15:0] d3;
		case (sel)
			2'd0: mux4 = d0;
			2'd1: mux4 = d1;
			2'd2: mux4 = d2;
			default: mux4 = d3;
		endcase
	endfunction
	assign eu_pushf_serialize = ((((eu_opcode_type == 3'h5) && (eu_opcode_dst_sel == 4'hf)) && (eu_opcode_op0_sel == 4'h8)) && (eu_opcode_op1_sel == 4'hf)) && (eu_opcode_immediate == 16'hf002);
	wire [15:0] eu_op0_grp0;
	wire [15:0] eu_op0_grp1;
	wire [15:0] eu_op0_grp2;
	wire [15:0] eu_op0_grp3;
	assign eu_op0_grp0 = mux4(eu_rom_sel[5:4], eu_register_ax, eu_register_bx, eu_register_cx, eu_register_dx);
	assign eu_op0_grp1 = mux4(eu_rom_sel[5:4], eu_register_sp, eu_register_bp, eu_register_si, eu_register_di);
	assign eu_op0_grp2 = mux4(eu_rom_sel[5:4], eu_flags, eu_register_r0, eu_register_r1, eu_register_r2);
	assign eu_op0_grp3 = mux4(eu_rom_sel[5:4], eu_register_r3, eu_biu_command, system_signals, 16'h0000);
	assign eu_operand0 = mux4(eu_rom_sel[7:6], eu_op0_grp0, eu_op0_grp1, eu_op0_grp2, eu_op0_grp3);
	wire [15:0] eu_op1_grp0;
	wire [15:0] eu_op1_grp1;
	wire [15:0] eu_op1_grp2;
	wire [15:0] eu_op1_grp3;
	assign eu_op1_grp0 = mux4(eu_rom_sel[1:0], BIU_REGISTER_ES, BIU_REGISTER_SS, BIU_REGISTER_CS, BIU_REGISTER_DS);
	assign eu_op1_grp1 = mux4(eu_rom_sel[1:0], {8'h00, PFQ_TOP_BYTE}, BIU_REGISTER_RM, BIU_REGISTER_REG, BIU_RETURN_DATA);
	assign eu_op1_grp2 = mux4(eu_rom_sel[1:0], PFQ_ADDR_OUT, eu_register_r0, eu_register_r1, eu_register_r2);
	assign eu_op1_grp3 = mux4(eu_rom_sel[1:0], eu_register_r3, eu_alu_last_result, system_signals, eu_opcode_immediate);
	assign eu_operand1 = mux4(eu_rom_sel[3:2], eu_op1_grp0, eu_op1_grp1, eu_op1_grp2, eu_op1_grp3);
	assign eu_jump_boolean = (((idiv_opcode == 'h1) && (eu_rom_address == 'he76)) && (eu_register_ax[15:7] != 'h0) ? 1'b1 : (((idiv_opcode == 'h1) && (eu_rom_address == 'hf02)) && ((eu_register_dx != 'h0) || (eu_register_ax[15] != 'h0)) ? 1'b1 : (eu_opcode_jump_cond == 4'h0 ? 1'b1 : ((eu_opcode_jump_cond == 4'h1) && (eu_alu_last_result != 16'h0000) ? 1'b1 : ((eu_opcode_jump_cond == 4'h2) && (eu_alu_last_result == 16'h0000) ? 1'b1 : 1'b0)))));
	assign system_signals[13] = eu_add_carry8;
	assign system_signals[12] = BIU_CLK_COUNTER_ZERO;
	assign system_signals[11] = eu_add_overflow16;
	assign system_signals[9] = eu_add_overflow8;
	assign system_signals[8] = eu_tr_latched;
	assign system_signals[7] = ~PFQ_EMPTY;
	assign system_signals[6] = biu_done_caught;
	assign system_signals[5] = TEST_N_INT;
	assign system_signals[4] = eu_add_aux_carry;
	assign system_signals[3] = BIU_NMI_CAUGHT;
	assign system_signals[2] = eu_parity;
	assign system_signals[1] = intr_asserted;
	assign system_signals[0] = eu_add_carry;
	assign eu_prefix_repnz = eu_flags[15];
	assign eu_prefix_rep = eu_flags[14];
	assign eu_prefix_lock = eu_flags[13];
	assign BIU_NMI_DEBOUNCE = eu_flags[12];
	assign eu_flag_o = eu_flags[11];
	assign eu_flag_d = eu_flags[10];
	assign eu_flag_i = eu_flags[9];
	assign eu_flag_t = eu_flags[8];
	assign eu_flag_s = eu_flags[7];
	assign eu_flag_z = eu_flags[6];
	assign eu_tf_debounce = eu_flags[5];
	assign eu_flag_a = eu_flags[4];
	assign eu_nmi_pending = eu_flags[3];
	assign eu_flag_p = eu_flags[2];
	assign eu_flag_temp = eu_flags[1];
	assign eu_flag_c = eu_flags[0];
	assign eu_alu2 = adder_out;
	assign eu_alu3 = {eu_operand0[7:0], eu_operand0[15:8]};
	assign eu_alu4 = eu_operand0 & eu_operand1;
	assign eu_alu5 = (FAKE286_FLAGS && eu_pushf_serialize ? {4'b0000, eu_flags[11:2], 1'b1, eu_flags[0]} : eu_operand0 | eu_operand1);
	assign eu_alu6 = eu_operand0 ^ eu_operand1;
	assign eu_alu7 = {1'b0, eu_operand0[15:1]};
	assign eu_alu_logic = (eu_opcode_type == 3'h3 ? eu_alu3 : (eu_opcode_type == 3'h4 ? eu_alu4 : (eu_opcode_type == 3'h5 ? eu_alu5 : (eu_opcode_type == 3'h6 ? eu_alu6 : eu_alu7))));
	assign eu_alu_out = (eu_opcode_type == 3'h2 ? eu_alu2 : eu_alu_logic);
	mcl86_adder u_adder(
		.a(eu_operand0),
		.b(eu_operand1),
		.sum(adder_out),
		.carry(carry)
	);
	assign eu_parity = ~(((((((eu_alu_last_result[0] ^ eu_alu_last_result[1]) ^ eu_alu_last_result[2]) ^ eu_alu_last_result[3]) ^ eu_alu_last_result[4]) ^ eu_alu_last_result[5]) ^ eu_alu_last_result[6]) ^ eu_alu_last_result[7]);
	assign eu_biu_req = eu_biu_command[9];
	assign intr_asserted = BIU_INTR & intr_enable_delayed;
	assign new_instruction = (eu_rom_address[12:8] == 5'h01) | (eu_biu_command[8:4] == 5'h18);
	assign add_total = eu_register_r0 + eu_register_r1;
	assign adc_total = (eu_register_r0 + eu_register_r1) + eu_flag_c;
	assign sub_total = eu_register_r0 - eu_register_r1;
	assign sbb_total = (eu_register_r0 - eu_register_r1) - eu_flag_c;
	always @(posedge CORE_CLK_INT) begin : proc_eu_microsequencer
		if (RESET_INT == 1'b1) begin
			biu_done_d1 <= 1'sb0;
			biu_done_d2 <= 1'sb0;
			eu_biu_req_d1 <= 1'sb0;
			biu_done_caught <= 1'sb0;
			eu_flag_t_d <= 1'sb0;
			eu_tr_latched <= 1'sb0;
			eu_add_carry <= 1'sb0;
			eu_add_carry8 <= 1'sb0;
			eu_add_aux_carry <= 1'sb0;
			eu_add_overflow16 <= 1'sb0;
			eu_add_overflow8 <= 1'sb0;
			eu_alu_last_result <= 1'sb0;
			div_flag_src <= 1'sb0;
			eu_register_ax <= 1'sb0;
			eu_register_bx <= 1'sb0;
			eu_register_cx <= 1'sb0;
			eu_register_dx <= 1'sb0;
			eu_register_sp <= 1'sb0;
			eu_register_bp <= 1'sb0;
			eu_register_si <= 1'sb0;
			eu_register_di <= 1'sb0;
			eu_flags <= 1'sb0;
			eu_register_r0 <= 1'sb0;
			eu_register_r1 <= 1'sb0;
			eu_register_r2 <= 1'sb0;
			eu_register_r3 <= 1'sb0;
			eu_biu_command <= 1'sb0;
			eu_biu_dataout <= 1'sb0;
			eu_stall_pipeline <= 1'sb0;
			eu_rom_address <= 13'h0020;
			eu_calling_address <= 1'sb0;
			intr_enable_delayed <= 1'sb0;
			idiv_opcode <= 1'sb0;
		end
		else begin
			if (eu_flag_i == 1'b0)
				intr_enable_delayed <= 1'b0;
			else if (new_instruction == 1'b1)
				intr_enable_delayed <= eu_flag_i;
			eu_flag_t_d <= eu_flag_t;
			if ((eu_flag_t_d == 1'b0) && (eu_flag_t == 1'b1))
				eu_tr_latched <= 1'b1;
			else if (eu_tf_debounce == 1'b1)
				eu_tr_latched <= 1'b0;
			biu_done_d1 <= BIU_DONE;
			biu_done_d2 <= biu_done_d1;
			eu_biu_req_d1 <= eu_biu_req;
			if ((biu_done_d2 == 1'b0) && (biu_done_d1 == 1'b1))
				biu_done_caught <= 1'b1;
			else if ((eu_biu_req_d1 == 1'b1) && (eu_biu_req == 1'b0))
				biu_done_caught <= 1'b0;
			if (eu_rom_address == 16'h09c9) begin
				eu_overflow_override <= 1'b1;
				if ((((eu_register_r0[7] == 1'b0) && (eu_register_r1[7] == 1'b0)) && (add_total[7] == 1'b1)) || (((eu_register_r0[7] == 1'b1) && (eu_register_r1[7] == 1'b1)) && (add_total[7] == 1'b0)))
					eu_add_overflow8_fixed <= 1'b1;
				else
					eu_add_overflow8_fixed <= 1'b0;
			end
			if (eu_rom_address == 16'h0a03) begin
				eu_overflow_override <= 1'b1;
				if ((((eu_register_r0[7] == 1'b0) && (eu_register_r1[7] == 1'b0)) && (adc_total[7] == 1'b1)) || (((eu_register_r0[7] == 1'b1) && (eu_register_r1[7] == 1'b1)) && (adc_total[7] == 1'b0)))
					eu_add_overflow8_fixed <= 1'b1;
				else
					eu_add_overflow8_fixed <= 1'b0;
			end
			if (eu_rom_address == 16'h0a46) begin
				eu_overflow_override <= 1'b1;
				if ((((eu_register_r0[7] == 1'b0) && (eu_register_r1[7] == 1'b1)) && (sub_total[7] == 1'b1)) || (((eu_register_r0[7] == 1'b1) && (eu_register_r1[7] == 1'b0)) && (sub_total[7] == 1'b0)))
					eu_add_overflow8_fixed <= 1'b1;
				else
					eu_add_overflow8_fixed <= 1'b0;
			end
			if (eu_rom_address == 16'h0aae) begin
				eu_overflow_override <= 1'b1;
				if ((((eu_register_r0[7] == 1'b0) && (eu_register_r1[7] == 1'b1)) && (sbb_total[7] == 1'b1)) || (((eu_register_r0[7] == 1'b1) && (eu_register_r1[7] == 1'b0)) && (sbb_total[7] == 1'b0)))
					eu_add_overflow8_fixed <= 1'b1;
				else
					eu_add_overflow8_fixed <= 1'b0;
			end
			if (eu_rom_address == 16'h09cc) begin
				eu_overflow_override <= 1'b1;
				if ((((eu_register_r0[15] == 1'b0) && (eu_register_r1[15] == 1'b0)) && (add_total[15] == 1'b1)) || (((eu_register_r0[15] == 1'b1) && (eu_register_r1[15] == 1'b1)) && (add_total[15] == 1'b0)))
					eu_add_overflow16_fixed <= 1'b1;
				else
					eu_add_overflow16_fixed <= 1'b0;
			end
			if (eu_rom_address == 16'h0a12) begin
				eu_overflow_override <= 1'b1;
				if ((((eu_register_r0[15] == 1'b0) && (eu_register_r1[15] == 1'b0)) && (adc_total[15] == 1'b1)) || (((eu_register_r0[15] == 1'b1) && (eu_register_r1[15] == 1'b1)) && (adc_total[15] == 1'b0)))
					eu_add_overflow16_fixed <= 1'b1;
				else
					eu_add_overflow16_fixed <= 1'b0;
			end
			if (eu_rom_address == 16'h0a52) begin
				eu_overflow_override <= 1'b1;
				if ((((eu_register_r0[15] == 1'b0) && (eu_register_r1[15] == 1'b1)) && (sub_total[15] == 1'b1)) || (((eu_register_r0[15] == 1'b1) && (eu_register_r1[15] == 1'b0)) && (sub_total[15] == 1'b0)))
					eu_add_overflow16_fixed <= 1'b1;
				else
					eu_add_overflow16_fixed <= 1'b0;
			end
			if (eu_rom_address == 16'h0aba) begin
				eu_overflow_override <= 1'b1;
				if ((((eu_register_r0[15] == 1'b0) && (eu_register_r1[15] == 1'b1)) && (sbb_total[15] == 1'b1)) || (((eu_register_r0[15] == 1'b1) && (eu_register_r1[15] == 1'b0)) && (sbb_total[15] == 1'b0)))
					eu_add_overflow16_fixed <= 1'b1;
				else
					eu_add_overflow16_fixed <= 1'b0;
			end
			if (eu_rom_address == 'h11) begin
				eu_overflow_override <= 1'b0;
				initial_ax <= eu_register_ax;
				initial_dx <= eu_register_dx;
				idiv_opcode <= 'h0;
			end
			if ((eu_rom_address == 'he56) || (eu_rom_address == 'hed0))
				idiv_opcode <= 'h1;
			if ((eu_stall_pipeline == 1'b0) && (eu_opcode_type == 3'h2)) begin
				eu_add_carry <= carry[16];
				eu_add_carry8 <= carry[8];
				eu_add_aux_carry <= carry[4];
				eu_add_overflow16 <= (eu_overflow_override == 1'b1 ? eu_add_overflow16_fixed : carry[16] ^ carry[15]);
				eu_add_overflow8 <= (eu_overflow_override == 1'b1 ? eu_add_overflow8_fixed : carry[8] ^ carry[7]);
			end
			if (((eu_stall_pipeline == 1'b0) && (eu_opcode_type != 3'h0)) && (eu_opcode_type != 3'h1)) begin
				eu_alu_last_result <= eu_alu_out[15:0];
				case (eu_opcode_dst_sel)
					4'h0: eu_register_ax <= eu_alu_out[15:0];
					4'h1: eu_register_bx <= eu_alu_out[15:0];
					4'h2: eu_register_cx <= eu_alu_out[15:0];
					4'h3: eu_register_dx <= eu_alu_out[15:0];
					4'h4: eu_register_sp <= eu_alu_out[15:0];
					4'h5: eu_register_bp <= eu_alu_out[15:0];
					4'h6: eu_register_si <= eu_alu_out[15:0];
					4'h7: eu_register_di <= eu_alu_out[15:0];
					4'h8: eu_flags <= eu_alu_out[15:0];
					4'h9: eu_register_r0 <= eu_alu_out[15:0];
					4'ha: eu_register_r1 <= eu_alu_out[15:0];
					4'hb: eu_register_r2 <= eu_alu_out[15:0];
					4'hc: eu_register_r3 <= eu_alu_out[15:0];
					4'hd: eu_biu_command <= eu_alu_out[15:0];
					4'hf: eu_biu_dataout <= eu_alu_out[15:0];
					default:
						;
				endcase
			end
			if (eu_rom_address == 'hf11) begin
				eu_register_ax <= initial_ax;
				eu_register_dx <= initial_dx;
			end
			if (((eu_rom_address == 'he6c) && (eu_stall_pipeline == 1'b1)) && (eu_register_r2[15:8] == 8'h00))
				div_flag_src <= eu_register_r2;
			if ((eu_rom_address == 'hef0) && (eu_register_r3[0] == 1'b0))
				div_flag_src <= eu_register_r2;
			if ((eu_rom_address == 'hf85) || (eu_rom_address == 'hf8d))
				eu_register_r0 <= div_flag_src;
			if (((eu_stall_pipeline == 1'b0) && (eu_opcode_type == 3'h1)) && (eu_jump_boolean == 1'b1)) begin
				eu_stall_pipeline <= 1'b1;
				if (eu_opcode_jump_call == 1'b1)
					eu_calling_address[51:0] <= {eu_calling_address[38:0], eu_rom_address[12:0]};
				case (eu_opcode_jump_src)
					3'h0: eu_rom_address <= eu_opcode_immediate[12:0];
					3'h1: eu_rom_address <= {5'b00001, PFQ_TOP_BYTE};
					3'h2: eu_rom_address <= {eu_opcode_immediate[4:0], PFQ_TOP_BYTE[7:6], PFQ_TOP_BYTE[2:0], 3'b000};
					3'h3: begin
						eu_rom_address <= eu_calling_address[12:0];
						eu_calling_address[38:0] <= eu_calling_address[51:13];
					end
					3'h4: eu_rom_address <= {eu_opcode_immediate[7:0], eu_biu_dataout[3:0], 1'b0};
					3'h5: eu_rom_address <= {eu_opcode_immediate[6:0], eu_biu_dataout[3:0], 2'b00};
					3'h6: eu_rom_address <= {eu_opcode_immediate[12:3], eu_biu_dataout[5:3]};
					default:
						;
				endcase
			end
			else begin
				eu_stall_pipeline <= 1'b0;
				eu_rom_address <= eu_rom_address + 1'b1;
			end
		end
	end
	assign EU_BIU_COMMAND = eu_biu_command;
	assign EU_BIU_DATAOUT = eu_biu_dataout;
	assign EU_REGISTER_R3 = eu_register_r3;
	assign EU_FLAG_I = intr_enable_delayed;
	assign EU_PREFIX_LOCK = eu_prefix_lock;
endmodule
`default_nettype wire
