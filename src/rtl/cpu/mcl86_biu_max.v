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
// Intel 8088 CPU - Bus Interface Unit in Maximum Bus Mode
//
// Description:
//   The BIU is everything the EU is not: the external bus, the segment
//   registers, and the prefetch queue. The EU asks for a transfer by placing a
//   command code on EU_BIU_COMMAND and the address in R3; the BIU runs the bus
//   cycle and raises BIU_DONE. It also keeps the queue fed with code bytes
//   whenever the bus would otherwise be idle, which is the whole point of the
//   8088's split-unit design.
//
//   MAXIMUM mode: the CPU does not drive RD/WR/IO-M itself. It emits a 3-bit
//   status code on S2_S0_OUT at the top of each bus cycle and an external 8288
//   bus controller decodes that into the actual command strobes. mcl86_biu_min
//   is the same BIU with minimum-mode pin behaviour instead.
//
// Two clocks - the thing to understand before editing:
//   The state machine is clocked by CORE_CLK_INT, which is FAST and unrelated to
//   the 8088's real bus rate. CLK is the 8088 pin clock, and it is only ever an
//   INPUT to be edge-detected (clk_posedge / clk_negedge). Bus events are placed
//   by waiting for the right edge of CLK, so the FSM burns many core clocks per
//   real bus clock and the external bus still sees authentic 8088 timing. States
//   that must land on a bus edge re-enter themselves until that edge arrives.
//
// Bus cycle: an 8088 WORD, an odd-offset 8086 WORD, and any word outside SDRAM
//   run as two back-to-back byte cycles (byte_num 0 then 1, offset incremented
//   between). An even 8086 SDRAM word uses one private wide cycle. State 0x50
//   is the hop back to 0x01 for a split second byte.
//
// EU command codes (eu_biu_req_code, EU_BIU_COMMAND[8:4]):
//   0x08 IO byte read     0x0C mem byte read     0x16 interrupt acknowledge
//   0x0A IO byte write    0x0E mem byte write    0x18 halt
//   0x1A IO word read     0x10 mem word read     0x19 jump (flush + reload PFQ)
//   0x1C IO word write    0x11 mem word read, SS forced
//                         0x12 mem word read, segment 0 (interrupt vectors)
//                         0x13 mem word write
//                         0x14 mem word write, SS forced
//
// Status codes driven on S2_S0_OUT (s_bits) - the real 8088 max-mode encoding:
//   000 INTA        010 I/O write    100 code fetch    110 memory write
//   001 I/O read    011 halt         101 memory read   111 passive (idle)
//
// Prefetch queue: four bytes as an 8088, six as an 8086, selected by IS8086.
//   pfq_addr_in and pfq_addr_out are the full 16-bit fetch and instruction
//   pointers; pfq_addr_out doubles as IP and is handed back to the EU.
//
//   There are eight physical entries and the low three bits of the pointer
//   select one. Depth is enforced separately, by how many bytes the queue is
//   allowed to hold, so six works without six being a power of two - which the
//   original scheme could not do. It selected the entry with the low two bits
//   and told full from empty with bit 2 as a wrap bit, and that only works when
//   the depth is exactly the index modulus.
//
//   Full and empty come from the difference between the pointers instead. It is
//   always between zero and the depth - the read pointer only advances when the
//   queue is not empty and the write pointer only when it is not full, and a
//   jump sets both to the same value - so the low four bits of the subtraction
//   are the true count even across the 16-bit wrap. Two live bytes can never
//   share an entry either, since their pointers differ by less than eight.
//
// Turbo mode: clock_cycle_counter is loaded by microcode with the instruction's
//   nominal 8088 cycle count and counted down; the EU stalls until it reaches
//   zero (BIU_CLK_COUNTER_ZERO), which is what makes execution cycle-accurate.
//   Dividing/decrementing it faster runs the CPU "turbo"; wrappers can also tie
//   BIU_CLK_COUNTER_ZERO high to bypass cycle accuracy entirely.
//
// Reset: CS = 0xFFFF, IP = 0x0000, so the first fetch is from 0xFFFF0.
//
// Limitations:
//   - State 0x08 has no case arm and is reached only by the default increment.
//     That is intentional (a one-cycle delay slot), not a missing state.
//
// References:
//   - Intel 8088 datasheet - max-mode status encoding, bus cycle timing
//   - Intel 8086 Family User's Manual (Oct 1979)
//
// Changelog:
// 1.0 - 10/8/15 - Initial revision
//------------------------------------------------------------------------
//
// karabas: converted to Verilog-2005 with sv2v from MiSTer PCXT efce777 (rtl/8088/mcl86_biu_max.sv) for XST

`default_nettype none
module mcl86_biu_max (
	CORE_CLK_INT,
	RESET_INT,
	CLK,
	READY_IN,
	NMI,
	INTR,
	LOCK_n,
	AD_OE,
	AD_OUT,
	AD_IN,
	S6_3_MUX,
	S2_S0_OUT,
	EU_BIU_COMMAND,
	EU_BIU_DATAOUT,
	EU_REGISTER_R3,
	EU_PREFIX_LOCK,
	BIU_DONE,
	BIU_CLK_COUNTER_ZERO,
	BIU_SEGMENT,
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
	BIU_RETURN_DATA,
	clock_cycle_counter_division_ratio,
	clock_cycle_counter_decrement_value,
	shift_read_timing,
	IS8086,
	WORD_READ_REQUEST,
	WORD_WRITE_REQUEST,
	DATA_BUS_WORD_OUT,
	DATA_BUS_WORD,
	WORD_ACCESS_POSSIBLE
);
	input wire CORE_CLK_INT;
	input wire RESET_INT;
	input wire CLK;
	input wire READY_IN;
	input wire NMI;
	input wire INTR;
	output reg LOCK_n;
	output reg AD_OE;
	output reg [19:0] AD_OUT;
	input wire [7:0] AD_IN;
	output reg S6_3_MUX;
	output reg [2:0] S2_S0_OUT;
	input wire [15:0] EU_BIU_COMMAND;
	input wire [15:0] EU_BIU_DATAOUT;
	input wire [15:0] EU_REGISTER_R3;
	input wire EU_PREFIX_LOCK;
	output wire BIU_DONE;
	output wire BIU_CLK_COUNTER_ZERO;
	output wire [1:0] BIU_SEGMENT;
	output wire BIU_NMI_CAUGHT;
	input wire BIU_NMI_DEBOUNCE;
	output reg BIU_INTR;
	output wire [7:0] PFQ_TOP_BYTE;
	output wire PFQ_EMPTY;
	output wire [15:0] PFQ_ADDR_OUT;
	output wire [15:0] BIU_REGISTER_ES;
	output wire [15:0] BIU_REGISTER_SS;
	output wire [15:0] BIU_REGISTER_CS;
	output wire [15:0] BIU_REGISTER_DS;
	output wire [15:0] BIU_REGISTER_RM;
	output wire [15:0] BIU_REGISTER_REG;
	output wire [15:0] BIU_RETURN_DATA;
	input wire [7:0] clock_cycle_counter_division_ratio;
	input wire [7:0] clock_cycle_counter_decrement_value;
	input wire shift_read_timing;
	input wire IS8086;
	output wire WORD_READ_REQUEST;
	output wire WORD_WRITE_REQUEST;
	output wire [15:0] DATA_BUS_WORD_OUT;
	input wire [15:0] DATA_BUS_WORD;
	input wire WORD_ACCESS_POSSIBLE;
	reg [7:0] biu_state;
	reg [2:0] s_bits;
	reg [2:0] s2_s0_out_int;
	reg word_cycle;
	reg byte_num;
	reg biu_done_int;
	reg biu_lock_n_int;
	reg fetch_word;
	reg [15:0] latched_word_in;
	reg data_word_read;
	reg data_word_write;
	reg wide_data_cycle;
	reg clk_d1;
	reg clk_d2;
	wire clk_posedge;
	wire clk_negedge;
	reg clk_negedge_d1;
	wire eu_prefix_seg;
	wire [1:0] eu_biu_strobe;
	wire [1:0] eu_biu_segment;
	wire eu_biu_req;
	wire [4:0] eu_biu_req_code;
	wire [1:0] eu_qs_out;
	wire [1:0] eu_segment_override_value;
	wire [1:0] biu_segment;
	wire [15:0] biu_muxed_segment;
	reg eu_biu_req_d1;
	reg eu_biu_req_caught;
	reg [15:0] biu_register_cs;
	reg [15:0] biu_register_es;
	reg [15:0] biu_register_ss;
	reg [15:0] biu_register_ds;
	reg [15:0] biu_register_rm;
	reg [15:0] biu_register_reg;
	reg [15:0] biu_register_cs_d1;
	reg [15:0] biu_register_es_d1;
	reg [15:0] biu_register_ss_d1;
	reg [15:0] biu_register_ds_d1;
	reg [15:0] biu_register_rm_d1;
	reg [15:0] biu_register_reg_d1;
	reg [15:0] biu_register_cs_d2;
	reg [15:0] biu_register_es_d2;
	reg [15:0] biu_register_ss_d2;
	reg [15:0] biu_register_ds_d2;
	reg [15:0] biu_register_rm_d2;
	reg [15:0] biu_register_reg_d2;
	reg [19:0] addr_out_temp_base;
	reg [15:0] addr_out_temp_offset;
	reg [7:0] ad_in_int;
	reg [7:0] latched_data_in;
	reg [15:0] biu_return_data_int;
	reg [15:0] biu_return_data_int_d1;
	reg [15:0] biu_return_data_int_d2;
	reg [15:0] eu_register_r3_d;
	reg [7:0] pfq_entry [0:7];
	reg [15:0] pfq_addr_in;
	reg [15:0] pfq_addr_out;
	reg [15:0] pfq_addr_out_d1;
	wire [7:0] pfq_top_byte_int;
	reg [7:0] pfq_top_byte_int_d1;
	reg pfq_write;
	wire [3:0] pfq_depth;
	wire [3:0] pfq_used;
	wire pfq_full;
	wire pfq_empty;
	reg nmi_d1;
	reg nmi_d2;
	reg nmi_d3;
	reg nmi_caught;
	reg intr_d1;
	reg ready_d1;
	reg ready_d2;
	reg ready_d3;
	reg eu_prefix_lock_d1;
	reg eu_prefix_lock_d2;
	integer pfq_reset_i;
	reg [12:0] clock_cycle_counter;
	reg [7:0] clock_cycle_counter_div;
	assign BIU_DONE = biu_done_int;
	assign PFQ_EMPTY = pfq_empty;
	assign PFQ_ADDR_OUT = pfq_addr_out_d1;
	assign BIU_SEGMENT = biu_segment;
	assign BIU_REGISTER_ES = biu_register_es_d2;
	assign BIU_REGISTER_SS = biu_register_ss_d2;
	assign BIU_REGISTER_CS = biu_register_cs_d2;
	assign BIU_REGISTER_DS = biu_register_ds_d2;
	assign BIU_REGISTER_RM = biu_register_rm_d2;
	assign BIU_REGISTER_REG = biu_register_reg_d2;
	assign BIU_RETURN_DATA = biu_return_data_int_d2;
	assign BIU_NMI_CAUGHT = nmi_caught;
	assign eu_prefix_seg = EU_BIU_COMMAND[14];
	assign eu_biu_strobe[1:0] = EU_BIU_COMMAND[13:12];
	assign eu_biu_segment[1:0] = EU_BIU_COMMAND[11:10];
	assign eu_biu_req = EU_BIU_COMMAND[9];
	assign eu_biu_req_code = EU_BIU_COMMAND[8:4];
	assign eu_qs_out[1:0] = EU_BIU_COMMAND[3:2];
	assign eu_segment_override_value[1:0] = EU_BIU_COMMAND[1:0];
	assign biu_segment = (eu_prefix_seg == 1'b1 ? eu_segment_override_value : eu_biu_segment);
	assign biu_muxed_segment = (biu_segment == 2'b00 ? biu_register_es : (biu_segment == 2'b01 ? biu_register_ss : (biu_segment == 2'b10 ? biu_register_cs : biu_register_ds)));
	wire [15:0] pfq_addr_in_p1 = pfq_addr_in + 16'd1;
	assign pfq_top_byte_int = pfq_entry[pfq_addr_out[2:0]];
	assign PFQ_TOP_BYTE = pfq_top_byte_int_d1;
	assign pfq_depth = (IS8086 ? 4'd6 : 4'd4);
	assign pfq_used = pfq_addr_in[3:0] - pfq_addr_out[3:0];
	assign pfq_full = (pfq_used >= pfq_depth ? 1'b1 : 1'b0);
	assign pfq_empty = (pfq_used == 4'd0 ? 1'b1 : 1'b0);
	wire [19:0] next_fetch_addr = {biu_register_cs[15:0], 4'h0} + {4'h0, pfq_addr_in[15:0]};
	wire word_fetch_ok = (next_fetch_addr < 20'ha0000) | (next_fetch_addr >= 20'hf0000);
	assign WORD_READ_REQUEST = fetch_word | data_word_read;
	assign WORD_WRITE_REQUEST = data_word_write;
	assign DATA_BUS_WORD_OUT = EU_BIU_DATAOUT;
	assign BIU_CLK_COUNTER_ZERO = (clock_cycle_counter == 13'h0000 ? 1'b1 : 1'b0);
	assign clk_posedge = clk_d1 & ~clk_d2;
	assign clk_negedge = ~clk_d1 & clk_d2;
	always @(posedge CORE_CLK_INT) begin : biu_fsm
		if (RESET_INT == 1'b1) begin
			clk_d1 <= 'h0;
			clk_d2 <= 'h0;
			clk_negedge_d1 <= 'h0;
			nmi_d1 <= 'h0;
			nmi_d2 <= 'h0;
			nmi_d3 <= 'h0;
			nmi_caught <= 'h0;
			eu_register_r3_d <= 'h0;
			eu_biu_req_caught <= 'h0;
			biu_register_cs <= 16'hffff;
			biu_register_es <= 'h0;
			biu_register_ss <= 'h0;
			biu_register_ds <= 'h0;
			biu_register_rm <= 'h0;
			biu_register_reg <= 'h0;
			clock_cycle_counter <= 'h0;
			pfq_addr_out <= 'h0;
			for (pfq_reset_i = 0; pfq_reset_i < 8; pfq_reset_i = pfq_reset_i + 1)
				pfq_entry[pfq_reset_i] <= 'h0;
			biu_state <= 8'hd0;
			S2_S0_OUT <= 'b111;
			s2_s0_out_int <= 'b111;
			pfq_write <= 'h0;
			pfq_addr_in <= 'h0;
			biu_lock_n_int <= 1'b1;
			S6_3_MUX <= 'h0;
			AD_OE <= 'h0;
			biu_return_data_int <= 'h0;
			biu_done_int <= 'h0;
			ready_d1 <= 'h0;
			ready_d2 <= 'h0;
			ready_d3 <= 'h0;
			eu_biu_req_d1 <= 'h0;
			latched_data_in <= 'h0;
			addr_out_temp_base <= 'h0;
			addr_out_temp_offset <= 'h0;
			s_bits <= 3'b111;
			AD_OUT <= 'h0;
			word_cycle <= 1'b0;
			byte_num <= 1'b0;
			fetch_word <= 1'b0;
			latched_word_in <= 16'h0000;
			data_word_read <= 1'b0;
			data_word_write <= 1'b0;
			wide_data_cycle <= 1'b0;
			ad_in_int <= 'h0;
			BIU_INTR <= 'h0;
			eu_prefix_lock_d1 <= 'h0;
			eu_prefix_lock_d2 <= 'h0;
			LOCK_n <= 1'b1;
			intr_d1 <= 'h0;
		end
		else begin
			clk_d1 <= CLK;
			clk_d2 <= clk_d1;
			clk_negedge_d1 <= clk_negedge;
			ready_d1 <= READY_IN;
			ready_d2 <= ready_d1;
			ready_d3 <= ready_d2;
			nmi_d1 <= NMI;
			nmi_d2 <= nmi_d1;
			nmi_d3 <= nmi_d2;
			intr_d1 <= INTR;
			biu_register_es_d1 <= biu_register_es;
			biu_register_ss_d1 <= biu_register_ss;
			biu_register_cs_d1 <= biu_register_cs;
			biu_register_ds_d1 <= biu_register_ds;
			biu_register_rm_d1 <= biu_register_rm;
			biu_register_reg_d1 <= biu_register_reg;
			biu_register_es_d2 <= biu_register_es_d1;
			biu_register_ss_d2 <= biu_register_ss_d1;
			biu_register_cs_d2 <= biu_register_cs_d1;
			biu_register_ds_d2 <= biu_register_ds_d1;
			biu_register_rm_d2 <= biu_register_rm_d1;
			biu_register_reg_d2 <= biu_register_reg_d1;
			pfq_top_byte_int_d1 <= pfq_top_byte_int;
			pfq_addr_out_d1 <= pfq_addr_out;
			biu_return_data_int_d1 <= biu_return_data_int;
			biu_return_data_int_d2 <= biu_return_data_int_d1;
			if (((nmi_d3 == 1'b0) && (nmi_d2 == 1'b0)) && (nmi_d1 == 1'b1))
				nmi_caught <= 1'b1;
			else if (BIU_NMI_DEBOUNCE == 1'b1)
				nmi_caught <= 1'b0;
			if (clk_posedge)
				BIU_INTR <= intr_d1;
			eu_prefix_lock_d1 <= EU_PREFIX_LOCK;
			eu_prefix_lock_d2 <= eu_prefix_lock_d1;
			if (clk_negedge_d1)
				LOCK_n <= ~eu_prefix_lock_d2 && biu_lock_n_int;
			eu_register_r3_d <= EU_REGISTER_R3;
			ad_in_int <= AD_IN;
			S2_S0_OUT <= s2_s0_out_int;
			eu_biu_req_d1 <= eu_biu_req;
			if ((eu_biu_req_d1 == 1'b0) && (eu_biu_req == 1'b1))
				eu_biu_req_caught <= 1'b1;
			else if (biu_done_int == 1'b1)
				eu_biu_req_caught <= 1'b0;
			if (eu_biu_strobe == 2'b11)
				case (eu_biu_req_code[2:0])
					3'h0: biu_register_es <= EU_BIU_DATAOUT[15:0];
					3'h1: biu_register_ss <= EU_BIU_DATAOUT[15:0];
					3'h2: biu_register_cs <= EU_BIU_DATAOUT[15:0];
					3'h3: biu_register_ds <= EU_BIU_DATAOUT[15:0];
					3'h4: biu_register_rm <= EU_BIU_DATAOUT[15:0];
					3'h5: biu_register_reg <= EU_BIU_DATAOUT[15:0];
					default:
						;
				endcase
			if (eu_biu_strobe == 2'b10) begin
				clock_cycle_counter_div <= clock_cycle_counter_division_ratio;
				clock_cycle_counter <= EU_BIU_DATAOUT[12:0];
			end
			else if (8'h00 != clock_cycle_counter_div)
				clock_cycle_counter_div <= clock_cycle_counter_div - 1;
			else begin
				clock_cycle_counter_div <= clock_cycle_counter_division_ratio;
				if (clock_cycle_counter != 13'h0000) begin
					if (clock_cycle_counter > clock_cycle_counter_decrement_value)
						clock_cycle_counter <= clock_cycle_counter - clock_cycle_counter_decrement_value;
					else
						clock_cycle_counter <= 0;
				end
			end
			if ((eu_biu_req_caught == 1'b1) && (eu_biu_req_code == 5'h19))
				pfq_addr_out <= eu_register_r3_d;
			else if ((eu_biu_strobe == 2'b01) && (pfq_empty == 1'b0))
				pfq_addr_out <= pfq_addr_out + 1;
			if ((eu_biu_req_caught == 1'b1) && (eu_biu_req_code == 5'h19))
				pfq_addr_in <= eu_register_r3_d;
			else if (pfq_write == 1'b1)
				pfq_addr_in <= pfq_addr_in + (fetch_word ? 16'd2 : 16'd1);
			if (pfq_write == 1'b1) begin
				if (fetch_word) begin
					pfq_entry[pfq_addr_in[2:0]] <= latched_word_in[7:0];
					pfq_entry[pfq_addr_in_p1[2:0]] <= latched_word_in[15:8];
				end
				else
					pfq_entry[pfq_addr_in[2:0]] <= latched_data_in[7:0];
			end
			biu_state <= biu_state + 1'b1;
			case (biu_state)
				8'h00: begin
					pfq_write <= 1'b0;
					biu_lock_n_int <= 1'b1;
					S6_3_MUX <= 1'b0;
					byte_num <= 1'b0;
					word_cycle <= 1'b0;
					fetch_word <= 1'b0;
					data_word_read <= 1'b0;
					data_word_write <= 1'b0;
					wide_data_cycle <= 1'b0;
					if (eu_biu_req_caught == 1'b1)
						case (eu_biu_req_code)
							8'h16: begin
								addr_out_temp_base <= {4'h0, eu_register_r3_d[15:0]};
								addr_out_temp_offset <= 'h0;
								word_cycle <= 1'b1;
								s_bits <= 3'b000;
								biu_state <= 8'h01;
							end
							8'h08: begin
								addr_out_temp_base <= {4'h0, eu_register_r3_d[15:0]};
								addr_out_temp_offset <= 'h0;
								s_bits <= 3'b001;
								biu_state <= 8'h01;
							end
							8'h1a: begin
								addr_out_temp_base <= {4'h0, eu_register_r3_d[15:0]};
								addr_out_temp_offset <= 'h0;
								word_cycle <= 1'b1;
								s_bits <= 3'b001;
								biu_state <= 8'h01;
							end
							8'h0a: begin
								addr_out_temp_base <= {4'h0, eu_register_r3_d[15:0]};
								addr_out_temp_offset <= 'h0;
								s_bits <= 3'b010;
								biu_state <= 8'h01;
							end
							8'h1c: begin
								addr_out_temp_base <= {4'h0, eu_register_r3_d[15:0]};
								addr_out_temp_offset <= 'h0;
								word_cycle <= 1'b1;
								s_bits <= 3'b010;
								biu_state <= 8'h01;
							end
							8'h18: begin
								addr_out_temp_base <= {biu_register_cs[15:0], 4'h0};
								addr_out_temp_offset <= pfq_addr_out[15:0];
								s_bits <= 3'b011;
								biu_state <= 8'h01;
							end
							8'h0c: begin
								addr_out_temp_base <= {biu_muxed_segment[15:0], 4'h0};
								addr_out_temp_offset <= eu_register_r3_d[15:0];
								s_bits <= 3'b101;
								biu_state <= 8'h01;
							end
							8'h10: begin
								addr_out_temp_base <= {biu_muxed_segment[15:0], 4'h0};
								addr_out_temp_offset <= eu_register_r3_d[15:0];
								word_cycle <= 1'b1;
								data_word_read <= IS8086 & ~eu_register_r3_d[0];
								s_bits <= 3'b101;
								biu_state <= 8'h01;
							end
							8'h11: begin
								addr_out_temp_base <= {biu_register_ss[15:0], 4'h0};
								addr_out_temp_offset <= eu_register_r3_d[15:0];
								word_cycle <= 1'b1;
								data_word_read <= IS8086 & ~eu_register_r3_d[0];
								s_bits <= 3'b101;
								biu_state <= 8'h01;
							end
							8'h12: begin
								addr_out_temp_base <= {4'h0, eu_register_r3_d[15:0]};
								addr_out_temp_offset <= 'h0;
								word_cycle <= 1'b1;
								data_word_read <= IS8086 & ~eu_register_r3_d[0];
								s_bits <= 3'b101;
								biu_state <= 8'h01;
							end
							8'h0e: begin
								addr_out_temp_base <= {biu_muxed_segment[15:0], 4'h0};
								addr_out_temp_offset <= eu_register_r3_d[15:0];
								s_bits <= 3'b110;
								biu_state <= 8'h01;
							end
							8'h13: begin
								addr_out_temp_base <= {biu_muxed_segment[15:0], 4'h0};
								addr_out_temp_offset <= eu_register_r3_d[15:0];
								word_cycle <= 1'b1;
								data_word_write <= IS8086 & ~eu_register_r3_d[0];
								s_bits <= 3'b110;
								biu_state <= 8'h01;
							end
							8'h14: begin
								addr_out_temp_base <= {biu_register_ss[15:0], 4'h0};
								addr_out_temp_offset <= eu_register_r3_d[15:0];
								word_cycle <= 1'b1;
								data_word_write <= IS8086 & ~eu_register_r3_d[0];
								s_bits <= 3'b110;
								biu_state <= 8'h01;
							end
							8'h19: begin
								biu_done_int <= 1'b1;
								biu_state <= 8'h0b;
							end
							default:
								;
						endcase
					else if (pfq_full == 1'b0) begin
						addr_out_temp_base <= {biu_register_cs[15:0], 4'h0};
						addr_out_temp_offset <= pfq_addr_in[15:0];
						s_bits <= 3'b100;
						biu_state <= 8'h01;
						fetch_word <= ((IS8086 & ~pfq_addr_in[0]) & word_fetch_ok) & (pfq_used <= (pfq_depth - 4'd2));
					end
					else
						biu_state <= 8'h00;
				end
				8'h01: begin
					if (s_bits != 3'b000) begin
						AD_OE <= 1'b1;
						if ((s_bits == 3'b001) || (s_bits == 3'b010))
							AD_OUT[19:0] <= (addr_out_temp_base + addr_out_temp_offset) & 20'h0ffff;
						else
							AD_OUT[19:0] <= addr_out_temp_base + addr_out_temp_offset;
					end
					S6_3_MUX <= 1'b0;
					if (clk_posedge)
						s2_s0_out_int <= s_bits;
					else
						biu_state <= 8'h01;
				end
				8'h02:
					if (~clk_negedge)
						biu_state <= 8'h02;
				8'h03:
					if (clk_negedge) begin
						if ((s_bits == 3'b000) && (byte_num == 1'b0))
							biu_lock_n_int <= 1'b0;
						else
							biu_lock_n_int <= 1'b1;
						S6_3_MUX <= 1'b1;
						AD_OE <= s_bits[1];
						if ((word_cycle == 1'b1) && (byte_num == 1'b1))
							AD_OUT[7:0] <= EU_BIU_DATAOUT[15:8];
						else
							AD_OUT[7:0] <= EU_BIU_DATAOUT[7:0];
					end
					else
						biu_state <= 8'h03;
				8'h04:
					if (~clk_negedge)
						biu_state <= 8'h04;
				8'h05:
					if (READY_IN == 1'b0)
						biu_state <= 8'h04;
					else begin
						s2_s0_out_int <= 3'b111;
						wide_data_cycle <= (data_word_read | data_word_write) & WORD_ACCESS_POSSIBLE;
					end
				8'h06:
					if ((~shift_read_timing & clk_posedge) || (shift_read_timing & clk_negedge)) begin
						if (fetch_word || (wide_data_cycle && (s_bits == 3'b101)))
							latched_word_in <= DATA_BUS_WORD;
						else
							latched_data_in <= ad_in_int;
						if (s_bits == 3'b100)
							pfq_write <= 1'b1;
					end
					else
						biu_state <= 8'h06;
				8'h07: pfq_write <= 1'b0;
				8'h09:
					if (wide_data_cycle && (s_bits == 3'b101))
						biu_return_data_int[15:0] <= latched_word_in;
					else if ((s_bits != 3'b000) && ((word_cycle == 1'b1) && (byte_num == 1'b1)))
						biu_return_data_int[15:8] <= latched_data_in[7:0];
					else
						biu_return_data_int[15:0] <= {8'h00, latched_data_in[7:0]};
				8'h0a:
					if (shift_read_timing | clk_negedge) begin
						addr_out_temp_offset[15:0] <= addr_out_temp_offset[15:0] + 1;
						if (((word_cycle == 1'b1) && (byte_num == 1'b0)) && !wide_data_cycle) begin
							byte_num <= 1'b1;
							data_word_read <= 1'b0;
							data_word_write <= 1'b0;
							biu_state <= 8'h50;
						end
						else if (s_bits != 3'b100)
							biu_done_int <= 1'b1;
					end
					else
						biu_state <= 8'h0a;
				8'h0b: biu_done_int <= 1'b0;
				8'h0c: biu_state <= 8'h00;
				8'h50: biu_state <= 8'h01;
				default:
					;
			endcase
		end
	end
endmodule
`default_nettype wire
