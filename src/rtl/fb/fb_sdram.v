`timescale 1ns / 1ps
`default_nettype none
/*
 fb_sdram.v
 The SDRAM of the HDMI frame buffer (pcxt_fb.v): lines of LINE_WORDS 16-bit words, one SDRAM row per
 line, written from the capture buffer and read into the output buffer. 16-bit SDRAM, 4 banks x 8192
 rows x 512 columns, bank 0 only; CAS latency 2, burst length 1; on clk (clk_50; SDR_CLK is clk at
 180 degrees from an ODDR2). After sdram_bg.v of the spec256 core.
 - init: 200 us, PRECHARGE ALL, 2 x AUTO REFRESH, LOAD MODE;
 - line write (wr_req): ACTIVE, LINE_WORDS WRITEs one per clock (the words of cb_addr a clock before:
   the capture buffer reads with a clock of latency), tWR, PRECHARGE ALL;
 - line read (rd_req): ACTIVE, LINE_WORDS READs one per clock, PRECHARGE ALL; the words go to the output
   buffer as lb_we / lb_addr / lb_data;
 - AUTO REFRESH every REFRESH_CLOCKS clocks (8192 rows in 64 ms: 7.8 us).
 A request waits while another runs (a few us each; a line of the PC lasts 64 us).
 Timing: SDR_CLK rises in the middle of a clk period, so the commands, the address and the write data
 (IOB flip-flops on the rising edge of clk) have half a period of setup and of hold at the SDRAM. The
 data of a READ on SDRAM edge n is valid from tAC (6 ns) after edge n+1 to tOH (3 ns) after edge n+2;
 the IOB flip-flop on the falling edge of clk takes it at edge n+2 (10 ns / 7 ns of margin at 50 MHz
 with 4 ns of pads and traces); RD_DELAY clocks after the READ it is in dq_neg.
*/
module fb_sdram #(
	parameter INIT_CLOCKS = 15'd10500,    // 210 us at 50 MHz
	parameter REFRESH_CLOCKS = 10'd380,   // 7.6 us
	parameter LINE_WORDS = 9'd180,
	parameter RD_DELAY = 3
) (
	input wire clk,
	input wire reset,

	// a line write: a pulse of wr_req starts it; the words from the capture buffer
	input wire wr_req,
	input wire [12:0] wr_row,
	input wire wr_buf,
	output wire [8:0] cb_addr,            // {buf, word}
	input wire [15:0] cb_data,            // a clock after cb_addr

	// a line read: a pulse of rd_req starts it; the words to the output buffer
	input wire rd_req,
	input wire [12:0] rd_row,
	input wire rd_buf,
	output reg lb_we = 1'b0,
	output reg [8:0] lb_addr = 9'd0,      // {buf, word}
	output reg [15:0] lb_data = 16'd0,

	output wire ready,                    // init done

	// SDRAM
	output wire [12:0] sdr_a,
	output wire [1:0] sdr_ba,
	inout wire [15:0] sdr_dq,
	output wire [1:0] sdr_dqm,
	output wire sdr_ras_n,
	output wire sdr_cas_n,
	output wire sdr_we_n
);

localparam [2:0] CMD_NOP = 3'b111, CMD_ACTIVE = 3'b011, CMD_READ = 3'b101, CMD_WRITE = 3'b100,
	CMD_PRECHARGE = 3'b010, CMD_REFRESH = 3'b001, CMD_MODE = 3'b000;

localparam [3:0] S_INIT = 0, S_INIT_PRE = 1, S_INIT_REF1 = 2, S_INIT_REF2 = 3, S_INIT_MODE = 4,
	S_IDLE = 5, S_WAIT = 6, S_WR_PRE = 7, S_WR_CMD = 8, S_WR_END = 9, S_RD_CMD = 10, S_RD_END = 11;

// the IOB flip-flops of the SDRAM pins
(* IOB = "TRUE" *) reg [12:0] a_r = 13'd0;
(* IOB = "TRUE" *) reg [1:0] dqm_r = 2'b11;
(* IOB = "TRUE" *) reg ras_r = 1'b1;
(* IOB = "TRUE" *) reg cas_r = 1'b1;
(* IOB = "TRUE" *) reg we_r = 1'b1;
(* IOB = "TRUE" *) reg [15:0] dq_out = 16'd0;
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [15:0] dq_oe_n = 16'hFFFF;  // a tristate flip-flop per pin
(* IOB = "TRUE" *) reg [15:0] dq_neg = 16'd0;        // sdr_dq on the falling edge of clk

assign sdr_a = a_r;
assign sdr_ba = 2'b00;
assign sdr_dqm = dqm_r;
assign sdr_ras_n = ras_r;
assign sdr_cas_n = cas_r;
assign sdr_we_n = we_r;
genvar i;
generate
	for (i = 0; i < 16; i = i + 1) begin : g_dq
		assign sdr_dq[i] = dq_oe_n[i] ? 1'bz : dq_out[i];
	end
endgenerate

always @(negedge clk)
	dq_neg <= sdr_dq;

reg [3:0] state = S_INIT;
reg [3:0] next_state = S_IDLE;
reg [14:0] cnt = 15'd0;
reg [9:0] ref_cnt = 10'd0;
reg ref_pending = 1'b0;
reg init_done = 1'b0;
assign ready = init_done;

reg wr_pend = 1'b0, rd_pend = 1'b0;
reg [12:0] w_row = 13'd0, r_row = 13'd0;
reg w_buf = 1'b0, r_buf = 1'b0;
reg [8:0] n = 9'd0;                   // the word of the next command (the capture buffer address)
reg [8:0] col_d = 9'd0;               // the word cb_data holds (the address of the last clock)
reg [RD_DELAY:0] rd_pipe = 0;         // a READ RD_DELAY clocks ago
reg [7:0] lb_word = 8'd0;

assign cb_addr = {w_buf, n[7:0]};

task cmd(input [2:0] c);
	begin
		ras_r <= c[2];
		cas_r <= c[1];
		we_r <= c[0];
	end
endtask

always @(posedge clk) begin
	if (wr_req) begin
		wr_pend <= 1'b1;
		w_row <= wr_row;
		w_buf <= wr_buf;
	end
	if (rd_req) begin
		rd_pend <= 1'b1;
		r_row <= rd_row;
		r_buf <= rd_buf;
	end

	if (ref_cnt == REFRESH_CLOCKS) begin
		ref_cnt <= 10'd0;
		ref_pending <= 1'b1;
	end else
		ref_cnt <= ref_cnt + 1'd1;

	// the data of the READs
	rd_pipe <= {rd_pipe[RD_DELAY-1:0], 1'b0};
	lb_we <= 1'b0;
	if (rd_pipe[RD_DELAY-1]) begin
		lb_we <= 1'b1;
		lb_data <= dq_neg;
		lb_addr <= {r_buf, lb_word};
		lb_word <= lb_word + 1'd1;
	end

	col_d <= n;
	cmd(CMD_NOP);
	dq_oe_n <= 16'hFFFF;
	dqm_r <= 2'b00;

	if (reset) begin
		state <= S_INIT;
		cnt <= 15'd0;
		init_done <= 1'b0;
		wr_pend <= 1'b0;
		rd_pend <= 1'b0;
		dqm_r <= 2'b11;
	end else case (state)
		S_INIT: begin
			dqm_r <= 2'b11;
			cnt <= cnt + 1'd1;
			if (cnt == INIT_CLOCKS) state <= S_INIT_PRE;
		end
		S_INIT_PRE: begin
			cmd(CMD_PRECHARGE);
			a_r[10] <= 1'b1;                  // all banks
			cnt <= 15'd3;
			next_state <= S_INIT_REF1;
			state <= S_WAIT;
		end
		S_INIT_REF1: begin
			cmd(CMD_REFRESH);
			cnt <= 15'd8;
			next_state <= S_INIT_REF2;
			state <= S_WAIT;
		end
		S_INIT_REF2: begin
			cmd(CMD_REFRESH);
			cnt <= 15'd8;
			next_state <= S_INIT_MODE;
			state <= S_WAIT;
		end
		S_INIT_MODE: begin
			cmd(CMD_MODE);
			a_r <= 13'b000_1_00_010_0_000;    // single location writes, CAS 2, sequential, burst 1
			cnt <= 15'd3;
			next_state <= S_IDLE;
			state <= S_WAIT;
		end

		S_WAIT: begin
			if (cnt == 15'd0) begin
				state <= next_state;
				if (next_state == S_IDLE) init_done <= 1'b1;
			end else
				cnt <= cnt - 1'd1;
		end

		S_IDLE: begin
			n <= 9'd0;
			if (ref_pending) begin
				ref_pending <= 1'b0;
				cmd(CMD_REFRESH);
				cnt <= 15'd4;                 // tRC 66 ns
				next_state <= S_IDLE;
				state <= S_WAIT;
			end else if (wr_pend) begin
				wr_pend <= 1'b0;
				cmd(CMD_ACTIVE);
				a_r <= w_row;
				state <= S_WR_PRE;            // tRCD: one clock between
			end else if (rd_pend) begin
				rd_pend <= 1'b0;
				cmd(CMD_ACTIVE);
				a_r <= r_row;
				lb_word <= 8'd0;
				cnt <= 15'd0;
				next_state <= S_RD_CMD;
				state <= S_WAIT;
			end
		end

		// the capture buffer takes word 0 now, its data comes with the first WRITE
		S_WR_PRE: begin
			n <= n + 1'd1;
			state <= S_WR_CMD;
		end

		// LINE_WORDS WRITEs of the row, one per clock: the word of col_d is in cb_data
		S_WR_CMD: begin
			cmd(CMD_WRITE);
			a_r <= {4'b0000, col_d};
			dq_out <= cb_data;
			dq_oe_n <= 16'h0000;
			n <= n + 1'd1;
			if (col_d == LINE_WORDS - 1'd1) begin
				cnt <= 15'd2;                 // tWR
				state <= S_WR_END;
			end
		end
		S_WR_END: begin
			if (cnt == 15'd0) begin
				cmd(CMD_PRECHARGE);
				a_r[10] <= 1'b1;
				cnt <= 15'd2;                 // tRP
				next_state <= S_IDLE;
				state <= S_WAIT;
			end else
				cnt <= cnt - 1'd1;
		end

		// LINE_WORDS READs of the row, one per clock
		S_RD_CMD: begin
			cmd(CMD_READ);
			a_r <= {4'b0000, n};
			rd_pipe[0] <= 1'b1;
			n <= n + 1'd1;
			if (n == LINE_WORDS - 1'd1) state <= S_RD_END;
		end

		// the last data, then PRECHARGE ALL and tRP
		S_RD_END: begin
			if (rd_pipe == 0) begin
				cmd(CMD_PRECHARGE);
				a_r[10] <= 1'b1;
				cnt <= 15'd2;
				next_state <= S_IDLE;
				state <= S_WAIT;
			end
		end

		default: state <= S_IDLE;
	endcase
end

endmodule
