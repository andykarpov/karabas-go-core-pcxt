`timescale 1ns / 1ns
`default_nettype wire

/*
 pcxt_fdd_phys.v

 Physical floppy drives (Karabas Go: DS0 / DS1 of the floppy connector) behind floppy.v: the
 drive A or B of floppy.v is a physical drive when the mcu maps its slot to one (CMD_IMG_PHYS);
 pcxt_fdd hands its sector requests here in place of img_sdc.
 - probe (the mapping, or a disk seen again): spin up, recalibrate, listen to track 0 for a
   revolution at 500, 300 and 250 kbit/s for valid IDs (C 0, H 0, N 2): the highest R is the
   sectors per track (the PLL can lock on a wrong rate: the length of an ID field, 112 cells
   from its sync, gives the rate, and the listen starts again at it); then head 1 for a
   revolution: two heads if it has IDs. 300 kbit/s is a
   360K disk in a 1.2M drive: 40 cylinders, two steps each; else 80. No IDs at any rate (an
   unformatted disk): 1.44M, so it can be formatted. No index pulse: no disk. The geometry goes
   to floppy.v by pcxt_fdd (geo_upd, geo_*), with the write protect of the drive.
 - op: a sector of floppy.v (op_lba, the logical sector of the geometry here) as C / H / R: seek
   (recalibrate first), find the ID in up to two revolutions (a wrong cylinder: recalibrate and
   seek once more), then
   read: the data field into the buffer (512 bytes; a CRC error: up to three tries);
   write: 22 bytes of gap 2 after the ID, then 12 x 00, A1 A1 A1 FB, the buffer, the CRC, 4E;
   format: the whole track at the first sector of it (from the index: gap 4a, the index mark,
   gap 1, the sectors R = 1..spt, N = 2, the data of the buffer, gap 3 by the sectors per track,
   4E to the index); the other sectors of the track only end. A format with other sectors per
   track (op_spt, from floppy.v) than the drive has sets them, and the rate from them (f_rate).
   Without this floppy.v would hang the format: DOS says "Not ready".
   op_err: 0 done, 1 sector not found, 2 data CRC, 3 no index (no disk) / no track 0.
 - no disk: a selected drive with the motor running and no index for NOIDX_US is not present
   (floppy.v sees a disk change); an index pulse on such a drive starts a probe.
 - the drive is selected while an op / probe runs on it, else while floppy.v has it selected with
   its motor on (the motor line is shared by both drives).
 fdd_in / fdd_out are at the FPGA pins, high = active (the board has inverters to the connector):
 fdd_in = { rdata, wprt, tr00, index }, fdd_out = { wdata, wgate, side1, step, dir (1: in),
 motor, ds1, ds0 }.
*/

module pcxt_fdd_phys #(
	parameter CLK_MHZ   = 50,
	parameter STEP_US   = 4000,         // step rate
	parameter SETTLE_US = 16000,        // head settle after the last step
	parameter SPIN_US   = 500000,       // motor spin up
	parameter NOIDX_US  = 600000,       // no index pulse: no disk
	parameter OP_US     = 1500000,      // an op or a listen without index pulses
	parameter [6:0] CELL_500 = 7'd50,   // clocks per MFM cell_clks
	parameter [6:0] CELL_300 = 7'd83,
	parameter [6:0] CELL_250 = 7'd100
) (
	input wire clk,
	input wire reset,

	input wire [1:0] map0,              // drive A / B: 0 an image, 1 DS0, 2 DS1
	input wire [1:0] map1,
	input wire [1:0] probe,             // one clock: drive n was mapped to a physical drive
	input wire [1:0] dor_motor,         // the digital output register of floppy.v
	input wire dor_drive,

	input wire op_go,                   // one clock: op_kind 1 read, 2 write, 3 format
	input wire [1:0] op_kind,
	input wire op_n,
	input wire [15:0] op_lba,
	input wire [5:0] op_spt,            // format: the sectors per track and the rate (of floppy.v)
	input wire [1:0] op_rate,
	output reg op_done = 1'b0,
	output reg [1:0] op_err = 2'd0,

	output reg [1:0] geo_upd = 2'b00,   // one clock: the geometry of drive n changed
	input wire geo_n,
	output wire geo_present,
	output wire geo_wp,
	output wire [7:0] geo_cyl,
	output wire [7:0] geo_spt,
	output wire [15:0] geo_secs,
	output wire [1:0] geo_heads,

	output reg buf_we = 1'b0,           // the sector buffer of pcxt_fdd (read: one clock late)
	output wire [8:0] buf_a,
	output reg [7:0] buf_wd = 8'd0,
	input wire [7:0] buf_q,

	input wire [3:0] fdd_in,
	output wire [7:0] fdd_out,

	// diagnostics (floppy.v pages 0..6 at 3F0h / 3F1h, the page by a write of 3F3h)
	input wire [2:0] dbg_sel,
	output reg [15:0] dbg_word
);

// CRC-CCITT (x^16 + x^12 + x^5 + 1) of a byte, MSB first
function [15:0] crc16;
	input [15:0] cin;
	input [7:0] d;
	integer i;
	reg [15:0] x;
	begin
		x = cin;
		for (i = 7; i >= 0; i = i - 1)
			x = (x[15] ^ d[i]) ? {x[14:0], 1'b0} ^ 16'h1021 : {x[14:0], 1'b0};
		crc16 = x;
	end
endfunction

// ---------------- pins, timers ----------------

reg [3:0] in_s1 = 4'd0, in_s2 = 4'd0;
reg index_q = 1'b0;
always @(posedge clk) begin
	in_s1 <= fdd_in;
	in_s2 <= in_s1;
	index_q <= in_s2[0];
end
wire rdata_s = in_s2[3];
wire wprt_s = in_s2[2];
wire tr00_s = in_s2[1];
wire idx_edge = in_s2[0] & ~index_q;

// microseconds
reg [6:0] pre = 7'd0;
reg us = 1'b0;
always @(posedge clk) begin
	us <= 1'b0;
	if (pre == CLK_MHZ - 1) begin
		pre <= 7'd0;
		us <= 1'b1;
	end
	else
		pre <= pre + 7'd1;
end

reg [20:0] tmr = 21'd0;             // the time in a state (tmr_clr)
reg tmr_clr = 1'b0;
always @(posedge clk)
	if (tmr_clr)
		tmr <= 21'd0;
	else if (us && tmr != 21'h1FFFFF)
		tmr <= tmr + 21'd1;

// ---------------- the drives ----------------

reg active = 1'b0;                  // an op / probe owns the drives
reg n = 1'b0;                       // its drive of floppy.v
wire [1:0] map_n = n ? map1 : map0;
wire pd = map_n[1];                 // its physical drive: 0 DS0, 1 DS1

wire [1:0] map_d = dor_drive ? map1 : map0;
wire idle_sel = (map_d != 2'd0) && (dor_drive ? dor_motor[1] : dor_motor[0]);
wire sel_on = active | idle_sel;
wire sel_pd = active ? pd : map_d[1];
wire motor = active | (dor_motor[0] & (map0 != 2'd0)) | (dor_motor[1] & (map1 != 2'd0));

// the time the selected drive has run: since the motor and the selection
reg [19:0] spin_us = 20'd0;
reg [19:0] idx_us = 20'd0;
reg sel_q = 1'b0, pd_q = 1'b0;
wire sel_chg = (sel_on != sel_q) || (sel_pd != pd_q);
always @(posedge clk) begin
	sel_q <= sel_on;
	pd_q <= sel_pd;
	if (!motor || !sel_on || sel_chg)
		spin_us <= 20'd0;
	else if (us && spin_us != 20'hFFFFF)
		spin_us <= spin_us + 20'd1;
	if (!sel_on || sel_chg || idx_edge)
		idx_us <= 20'd0;
	else if (us && idx_us != 20'hFFFFF)
		idx_us <= idx_us + 20'd1;
end
wire spun = spin_us >= SPIN_US;

// the geometry of drive A / B
reg [1:0] present = 2'b00, nodisk = 2'b00, wp = 2'b00, heads2 = 2'b00, dstep = 2'b00;
reg [1:0] rate0 = 2'd0, rate1 = 2'd0;     // 0 500, 1 300, 2 250 kbit/s
reg [5:0] spt0 = 6'd18, spt1 = 6'd18;

wire [5:0] g_spt = geo_n ? spt1 : spt0;
wire g_ds = (geo_n ? dstep[1] : dstep[0]);
assign geo_present = (geo_n ? present[1] : present[0]);
assign geo_wp = (geo_n ? wp[1] : wp[0]);
assign geo_spt = {2'b00, g_spt};
assign geo_cyl = g_ds ? 8'd40 : 8'd80;
assign geo_heads = (geo_n ? heads2[1] : heads2[0]) ? 2'd2 : 2'd1;
wire [15:0] spt80 = {4'd0, g_spt, 6'd0} + {6'd0, g_spt, 4'd0};
assign geo_secs = (g_ds ? {1'b0, spt80[15:1]} : spt80) << (geo_n ? heads2[1] : heads2[0]);

wire [5:0] spt_n = n ? spt1 : spt0;
wire [1:0] rate_n = n ? rate1 : rate0;

// the track of DS0 / DS1
reg [6:0] trk0 = 7'd0, trk1 = 7'd0;
reg [1:0] trk_ok = 2'b00;
wire [6:0] trk = pd ? trk1 : trk0;

// ---------------- MFM ----------------

reg rx_en = 1'b0;
reg tx_en = 1'b0;
reg [1:0] rate = 2'd0;
wire [6:0] cell_clks = (rate == 2'd0) ? CELL_500 : (rate == 2'd1) ? CELL_300 : CELL_250;

wire rx_sync, rx_stb;
wire [7:0] rx_data;
mfm_rx u_rx(
	.clk(clk), .en(rx_en), .cell_clks(cell_clks), .rd(rdata_s),
	.sync(rx_sync), .stb(rx_stb), .data(rx_data)
);

reg [7:0] tx_data;
reg [1:0] tx_kind;
wire tx_ld, tx_pulse;
mfm_tx u_tx(
	.clk(clk), .en(tx_en), .cell_clks(cell_clks), .data(tx_data), .kind(tx_kind),
	.ld(tx_ld), .pulse(tx_pulse)
);

// the marks: after a sync, FE an ID (C H R N CRC), FB / F8 a data field (512 bytes, CRC)
reg [1:0] mk = 2'd0;                // 0 hunt, 1 ID, 2 data
reg after_sync = 1'b0;
reg [9:0] mcnt = 10'd0;
reg [15:0] crc = 16'hFFFF;
reg [7:0] idc = 8'd0, idh = 8'd0, idr = 8'd0, idn = 8'd0;
reg id_stb = 1'b0, dat_stb = 1'b0;  // one clock: a field ended, crc_ok its CRC
reg crc_ok = 1'b0;
wire [15:0] crc_n = crc16(crc, rx_data);
reg [14:0] id_clks = 15'd0;         // clocks from the last sync to the end of the field
reg [1:0] id_rate = 2'd0;           // the rate of the last ID by its length (112 cells)
localparam [14:0] TH_300 = (CELL_500 + CELL_300) * 56;
localparam [14:0] TH_250 = (CELL_300 + CELL_250) * 56;
reg rx_buf = 1'b0;                  // the data field goes into the buffer
// diagnostics: syncs, IDs with a good / bad CRC since the start of the last probe / op (dbg_clr),
// the last good ID and its length in clocks
reg dbg_clr = 1'b0;
reg [7:0] n_sync = 8'd0, n_ok = 8'd0, n_bad = 8'd0;
reg [7:0] g_c = 8'd0, g_h = 8'd0, g_r = 8'd0, g_n = 8'd0;
reg [14:0] g_clks = 15'd0, id_len = 15'd0;
reg [8:0] rx_a = 9'd0;

always @(posedge clk) begin
	id_stb <= 1'b0;
	dat_stb <= 1'b0;
	buf_we <= 1'b0;
	if (rx_sync)
		id_clks <= 15'd0;
	else if (id_clks != 15'h7FFF)
		id_clks <= id_clks + 15'd1;
	if (dbg_clr) begin
		n_sync <= 8'd0;
		n_ok <= 8'd0;
		n_bad <= 8'd0;
	end
	else begin
		if (rx_sync && n_sync != 8'hFF)
			n_sync <= n_sync + 8'd1;
		if (id_stb && crc_ok && n_ok != 8'hFF)
			n_ok <= n_ok + 8'd1;
		if (id_stb && !crc_ok && n_bad != 8'hFF)
			n_bad <= n_bad + 8'd1;
	end
	if (id_stb && crc_ok) begin
		g_c <= idc;
		g_h <= idh;
		g_r <= idr;
		g_n <= idn;
		g_clks <= id_len;
	end
	if (!rx_en) begin
		mk <= 2'd0;
		after_sync <= 1'b0;
	end
	else if (rx_sync) begin
		after_sync <= 1'b1;
		mk <= 2'd0;
	end
	else if (rx_stb) begin
		after_sync <= 1'b0;
		mcnt <= mcnt + 10'd1;
		crc <= crc_n;
		case (mk)
			2'd0:
				if (after_sync && rx_data == 8'hFE) begin
					mk <= 2'd1;
					mcnt <= 10'd0;
					crc <= crc16(16'hCDB4, rx_data);  // A1 A1 A1 before it
				end
				else if (after_sync && (rx_data == 8'hFB || rx_data == 8'hF8)) begin
					mk <= 2'd2;
					mcnt <= 10'd0;
					crc <= crc16(16'hCDB4, rx_data);
				end
			2'd1: begin
				case (mcnt[2:0])
					3'd0: idc <= rx_data;
					3'd1: idh <= rx_data;
					3'd2: idr <= rx_data;
					3'd3: idn <= rx_data;
					default: ;
				endcase
				if (mcnt == 10'd5) begin
					mk <= 2'd0;
					id_stb <= 1'b1;
					id_len <= id_clks;
					crc_ok <= (crc_n == 16'h0000);
					id_rate <= (id_clks < TH_300) ? 2'd0 : (id_clks < TH_250) ? 2'd1 : 2'd2;
				end
			end
			default: begin
				if (mcnt < 10'd512 && rx_buf) begin
					buf_we <= 1'b1;
					rx_a <= mcnt[8:0];
					buf_wd <= rx_data;
				end
				if (mcnt == 10'd513) begin
					mk <= 2'd0;
					dat_stb <= 1'b1;
					crc_ok <= (crc_n == 16'h0000);
				end
			end
		endcase
	end
end

// ---------------- the track writer ----------------

localparam W_G4A = 5'd0, W_Z0 = 5'd1, W_IAM = 5'd2, W_FC = 5'd3, W_G1 = 5'd4, W_SZ = 5'd5,
	W_SS = 5'd6, W_FE = 5'd7, W_ID = 5'd8, W_IC = 5'd9, W_G2 = 5'd10, W_DZ = 5'd11, W_DS = 5'd12,
	W_FB = 5'd13, W_DD = 5'd14, W_DC = 5'd15, W_G3 = 5'd16, W_FILL = 5'd17, W_END = 5'd18;

reg [4:0] ws = W_END;
reg [9:0] wcnt = 10'd0;
reg [15:0] wcrc = 16'hFFFF;
reg fmt = 1'b0;                     // a track (else a sector)
reg [7:0] c = 8'd0;                 // the target: cylinder, head, sector
reg h = 1'b0;
reg [5:0] r = 6'd1;
reg [5:0] wr = 6'd1;                // the sector the format writes

wire [7:0] gap3 = (spt_n == 6'd18) ? 8'd108 : (spt_n == 6'd15) ? 8'd84 : 8'd80;

always @(*) begin
	tx_kind = 2'd0;
	case (ws)
		W_Z0, W_SZ, W_DZ: tx_data = 8'h00;
		W_IAM: begin tx_data = 8'hC2; tx_kind = 2'd2; end
		W_SS, W_DS: begin tx_data = 8'hA1; tx_kind = 2'd1; end
		W_FC: tx_data = 8'hFC;
		W_FE: tx_data = 8'hFE;
		W_ID: tx_data = (wcnt[1:0] == 2'd0) ? c : (wcnt[1:0] == 2'd1) ? {7'd0, h} :
			(wcnt[1:0] == 2'd2) ? {2'b00, wr} : 8'h02;
		W_IC, W_DC: tx_data = wcnt[0] ? wcrc[7:0] : wcrc[15:8];
		W_FB: tx_data = 8'hFB;
		W_DD: tx_data = buf_q;
		default: tx_data = 8'h4E;
	endcase
end

// the bytes of a segment
wire [9:0] wlen =
	(ws == W_G4A) ? 10'd80 : (ws == W_G1) ? 10'd50 : (ws == W_G2) ? 10'd22 :
	(ws == W_Z0 || ws == W_SZ || ws == W_DZ) ? 10'd12 :
	(ws == W_IAM || ws == W_SS || ws == W_DS) ? 10'd3 : (ws == W_ID) ? 10'd4 :
	(ws == W_IC || ws == W_DC) ? 10'd2 : (ws == W_DD) ? 10'd512 :
	(ws == W_G3) ? (fmt ? {2'b00, gap3} : 10'd1) : 10'd1;

reg tx_start = 1'b0;                // one clock: the writer starts (fmt: at W_G4A, else W_DZ)
always @(posedge clk) begin
	if (tx_start) begin
		ws <= fmt ? W_G4A : W_DZ;
		wcnt <= 10'd0;
		wr <= 6'd1;
	end
	else if (tx_ld && ws != W_END) begin
		if (ws == W_FE || ws == W_FB)
			wcrc <= crc16(16'hCDB4, tx_data);
		else if (ws == W_ID || ws == W_DD)
			wcrc <= crc16(wcrc, tx_data);
		if (ws == W_FILL)
			;
		else if (wcnt == wlen - 10'd1) begin
			wcnt <= 10'd0;
			if (ws == W_G3)
				if (!fmt)
					ws <= W_END;
				else if (wr == spt_n)
					ws <= W_FILL;
				else begin
					wr <= wr + 6'd1;
					ws <= W_SZ;
				end
			else
				ws <= ws + 5'd1;
		end
		else
			wcnt <= wcnt + 10'd1;
	end
end

assign buf_a = tx_en ? wcnt[8:0] : rx_a;

// ---------------- the drive sequencer ----------------

localparam S_IDLE = 5'd0, S_SPIN = 5'd1, S_RECAL = 5'd2, S_SEEK = 5'd3, S_DIR = 5'd4,
	S_STEP = 5'd5, S_STEPW = 5'd6, S_SETTLE = 5'd7, S_CHS = 5'd8, S_FIND = 5'd9, S_DATA = 5'd10,
	S_GAP2 = 5'd11, S_WRITE = 5'd12, S_FIDX = 5'd13, S_FMT = 5'd14, S_DONE = 5'd15,
	S_PIDX = 5'd16, S_PNEXT = 5'd17, S_LISTEN = 5'd18, S_PEND = 5'd19, S_WEND = 5'd20;

reg [4:0] st = S_IDLE;
reg [4:0] st_ret = S_IDLE;          // after a step
reg probing = 1'b0;
reg [1:0] kind = 2'd0;
reg [15:0] lba = 16'd0;
reg [1:0] op_pend_k = 2'd0;
reg op_pend_n = 1'b0;
reg [15:0] op_pend_lba = 16'd0;
reg [5:0] op_pend_spt = 6'd18;
reg [1:0] op_pend_rate = 2'd0;
wire [1:0] f_rate = (op_pend_spt > 6'd10) ? 2'd0 : (op_pend_rate == 2'd1) ? 2'd1 : 2'd2;
reg [1:0] probe_pend = 2'b00;
reg [6:0] steps = 7'd0;
reg moved = 1'b0;
reg dir = 1'b0;
reg step = 1'b0;
reg side = 1'b0;
reg [1:0] idx_cnt = 2'd0;
reg [1:0] tries = 2'd0;
reg reseek = 1'b0;
reg [7:0] bytes = 8'd0;
reg [5:0] maxr = 6'd0;
reg p_head = 1'b0;                  // probe: listening to head 1
reg [1:0] p_rate = 2'd0;
reg fmt_ok = 1'b0;                  // the track of the last format op was written
reg fmt_n = 1'b0;
reg [7:0] fmt_c = 8'd0;
reg fmt_h = 1'b0;
reg fidx = 1'b0;                    // format: the index came before the end of the sectors
reg [6:0] spth = 7'd0;

wire [6:0] ptgt = (n ? dstep[1] : dstep[0]) ? {c[5:0], 1'b0} : c[6:0];
wire [6:0] rem = lba[6:0];          // the sector in the cylinder (S_CHS)
wire rem_h1 = (n ? heads2[1] : heads2[0]) && (rem >= {1'b0, spt_n});
wire [6:0] rem_r = rem_h1 ? rem - {1'b0, spt_n} : rem;

always @(posedge clk) begin
	op_done <= 1'b0;
	geo_upd <= 2'b00;
	tmr_clr <= 1'b0;
	tx_start <= 1'b0;
	dbg_clr <= 1'b0;

	if (op_go) begin
		op_pend_k <= op_kind;
		op_pend_n <= op_n;
		op_pend_lba <= op_lba;
		op_pend_spt <= op_spt;
		op_pend_rate <= op_rate;
	end
	if (probe[0]) probe_pend[0] <= 1'b1;
	if (probe[1]) probe_pend[1] <= 1'b1;

	if (reset) begin
		st <= S_IDLE;
		active <= 1'b0;
		rx_en <= 1'b0;
		tx_en <= 1'b0;
		step <= 1'b0;
		op_pend_k <= 2'd0;
		probe_pend <= 2'b00;
		trk_ok <= 2'b00;
		fmt_ok <= 1'b0;
	end
	else case (st)
		S_IDLE: begin
			active <= 1'b0;
			rx_en <= 1'b0;
			tx_en <= 1'b0;
			rx_buf <= 1'b0;
			side <= 1'b0;
			tmr_clr <= 1'b1;
			if (op_pend_k != 2'd0 && !op_go) begin
				kind <= op_pend_k;
				op_pend_k <= 2'd0;
				n <= op_pend_n;
				lba <= op_pend_lba;
				probing <= 1'b0;
				active <= 1'b1;
				dbg_clr <= 1'b1;
				tries <= 2'd0;
				reseek <= 1'b0;
				fmt <= (op_pend_k == 2'd3);
				// a format with other sectors per track gives the drive its geometry: more than 10
				// sectors 500 kbit/s, else 250, or 300 when floppy.v has it (360K in a 1.2M drive;
				// the rate of floppy.v is 250 after a reset, whether the BIOS sets it or not)
				if (op_pend_k == 2'd3 && op_pend_spt != (op_pend_n ? spt1 : spt0)) begin
					if (op_pend_n) begin spt1 <= op_pend_spt; rate1 <= f_rate; end
					else begin spt0 <= op_pend_spt; rate0 <= f_rate; end
					if (op_pend_n) dstep[1] <= (f_rate == 2'd1); else dstep[0] <= (f_rate == 2'd1);
				end
				st <= S_SPIN;
			end
			else if (probe_pend != 2'b00) begin
				n <= ~probe_pend[0];
				begin if (~probe_pend[0]) probe_pend[1] <= 1'b0; else probe_pend[0] <= 1'b0; end
				probing <= 1'b1;
				active <= 1'b1;
				dbg_clr <= 1'b1;
				fmt_ok <= 1'b0;
				st <= S_SPIN;
			end
			// the selected drive (floppy.v) running: a disk taken out / put in
			else if (idle_sel && spun) begin
				if (idx_edge && (dor_drive ? nodisk[1] : nodisk[0]))
					begin if (dor_drive) probe_pend[1] <= 1'b1; else probe_pend[0] <= 1'b1; end
				else if (idx_us >= NOIDX_US && (dor_drive ? present[1] : present[0])) begin
					begin if (dor_drive) present[1] <= 1'b0; else present[0] <= 1'b0; end
					begin if (dor_drive) nodisk[1] <= 1'b1; else nodisk[0] <= 1'b1; end
					begin if (dor_drive) geo_upd[1] <= 1'b1; else geo_upd[0] <= 1'b1; end
				end
			end
		end

		// the motor up; a probe looks for the index first
		S_SPIN: begin
			tmr_clr <= 1'b1;
			steps <= 7'd0;
			moved <= 1'b0;
			if (map_n == 2'd0) begin
				if (probing) st <= S_IDLE; else begin op_err <= 2'd3; st <= S_DONE; end
			end
			else if (spun) begin
				spth <= (n ? heads2[1] : heads2[0]) ? {spt_n, 1'b0} : {1'b0, spt_n};
				c <= 8'd0;
				st <= probing ? S_PIDX : S_CHS;
			end
		end

		// the logical sector as C / H / R
		S_CHS:
			if (lba >= {9'd0, spth}) begin
				lba <= lba - {9'd0, spth};
				c <= c + 8'd1;
			end
			else begin
				h <= rem_h1;
				side <= rem_h1;
				r <= rem_r[5:0] + 6'd1;
				rate <= rate_n;
				if (kind == 2'd3 && fmt_ok && fmt_n == n && fmt_c == c && fmt_h == rem_h1) begin
					op_err <= 2'd0;
					st <= S_DONE;
				end
				else begin
					if (kind != 2'd3)
						fmt_ok <= 1'b0;
					st <= (pd ? trk_ok[1] : trk_ok[0]) ? S_SEEK : S_RECAL;
				end
			end

		S_RECAL:
			if (tr00_s) begin
				if (pd) trk1 <= 7'd0; else trk0 <= 7'd0;
				begin if (pd) trk_ok[1] <= 1'b1; else trk_ok[0] <= 1'b1; end
				tmr_clr <= 1'b1;
				st <= probing ? S_SETTLE : S_SEEK;
			end
			else if (steps == 7'd90) begin
				if (probing) begin
					begin if (n) nodisk[1] <= 1'b1; else nodisk[0] <= 1'b1; end
					st <= S_PEND;
				end
				else begin
					op_err <= 2'd3;
					st <= S_DONE;
				end
			end
			else begin
				dir <= 1'b0;
				steps <= steps + 7'd1;
				st_ret <= S_RECAL;
				tmr_clr <= 1'b1;
				st <= S_DIR;
			end

		S_SEEK:
			if (trk == ptgt) begin
				tmr_clr <= 1'b1;
				st <= S_SETTLE;
			end
			else begin
				dir <= (ptgt > trk);
				if (pd) trk1 <= (ptgt > trk) ? trk1 + 7'd1 : trk1 - 7'd1;
				else trk0 <= (ptgt > trk) ? trk0 + 7'd1 : trk0 - 7'd1;
				st_ret <= S_SEEK;
				tmr_clr <= 1'b1;
				st <= S_DIR;
			end

		// DIR before STEP, a 2 us pulse, then the step rate
		S_DIR:
			if (tmr >= 21'd2) begin
				step <= 1'b1;
				moved <= 1'b1;
				tmr_clr <= 1'b1;
				st <= S_STEP;
			end
		S_STEP:
			if (tmr >= 21'd2) begin
				step <= 1'b0;
				st <= S_STEPW;
			end
		S_STEPW:
			if (tmr >= STEP_US) begin
				tmr_clr <= 1'b1;
				st <= st_ret;
			end

		S_SETTLE:
			if (!moved || tmr >= SETTLE_US) begin
				tmr_clr <= 1'b1;
				idx_cnt <= 2'd0;
				if (probing) begin
					p_head <= 1'b0;
					p_rate <= 2'd0;
					rate <= 2'd0;
					side <= 1'b0;
					st <= S_PNEXT;
				end
				else if (fmt) begin
					fidx <= 1'b0;
					st <= S_FIDX;
				end
				else begin
					rx_en <= 1'b1;
					st <= S_FIND;
				end
			end

		// the ID of the sector, two revolutions
		S_FIND: begin
			if (idx_edge)
				idx_cnt <= idx_cnt + 2'd1;
			if (tmr >= OP_US) begin
				op_err <= 2'd3;
				st <= S_DONE;
			end
			else if (idx_cnt == 2'd3 || (id_stb && crc_ok && idc != c)) begin
				// not on this track (or the track is wrong): recalibrate once
				if (!reseek) begin
					reseek <= 1'b1;
					begin if (pd) trk_ok[1] <= 1'b0; else trk_ok[0] <= 1'b0; end
					rx_en <= 1'b0;
					steps <= 7'd0;
					tmr_clr <= 1'b1;
					st <= S_RECAL;
				end
				else if (idx_cnt == 2'd3) begin
					op_err <= 2'd1;
					st <= S_DONE;
				end
			end
			else if (id_stb && crc_ok && idh[0] == h && idr == {2'b00, r} && idn == 8'h02) begin
				bytes <= 8'd0;
				rx_buf <= (kind == 2'd1);
				st <= (kind == 2'd1) ? S_DATA : S_GAP2;
			end
		end

		// read: the data field of the ID
		S_DATA:
			if (dat_stb) begin
				rx_buf <= 1'b0;
				idx_cnt <= 2'd0;
				if (crc_ok) begin
					op_err <= 2'd0;
					st <= S_DONE;
				end
				else if (tries == 2'd2) begin
					op_err <= 2'd2;
					st <= S_DONE;
				end
				else begin
					tries <= tries + 2'd1;
					st <= S_FIND;
				end
			end
			else if (rx_stb && mk == 2'd0) begin
				bytes <= bytes + 8'd1;
				if (bytes == 8'd60) begin
					rx_buf <= 1'b0;
					st <= S_FIND;
				end
			end

		// write: gap 2 after the ID, then the data field
		S_GAP2:
			if (rx_stb) begin
				bytes <= bytes + 8'd1;
				if (bytes == 8'd21) begin
					rx_en <= 1'b0;
					tx_en <= 1'b1;
					tx_start <= 1'b1;
					st <= S_WRITE;
				end
			end
		S_WRITE:
			if (tx_ld && ws == W_END) begin
				tx_en <= 1'b0;
				op_err <= 2'd0;
				st <= S_DONE;
			end

		// format: the track from the index to the index
		S_FIDX:
			if (tmr >= OP_US) begin
				op_err <= 2'd3;
				st <= S_DONE;
			end
			else if (idx_edge) begin
				tx_en <= 1'b1;
				tx_start <= 1'b1;
				st <= S_FMT;
			end
		S_FMT: begin
			if (idx_edge)
				fidx <= 1'b1;
			if (ws == W_FILL && (idx_edge || fidx)) begin
				tx_en <= 1'b0;
				fmt_ok <= 1'b1;
				fmt_n <= n;
				fmt_c <= c;
				fmt_h <= h;
				op_err <= 2'd0;
				st <= S_DONE;
			end
		end

		S_DONE: begin
			op_done <= 1'b1;
			active <= 1'b0;
			rx_en <= 1'b0;
			tx_en <= 1'b0;
			st <= S_WEND;
		end
		S_WEND:
			st <= S_IDLE;

		// probe: an index pulse (a disk), then recalibrate
		S_PIDX:
			if (idx_edge) begin
				begin if (n) nodisk[1] <= 1'b0; else nodisk[0] <= 1'b0; end
				steps <= 7'd0;
				st <= S_RECAL;
			end
			else if (tmr >= NOIDX_US) begin
				begin if (n) nodisk[1] <= 1'b1; else nodisk[0] <= 1'b1; end
				st <= S_PEND;
			end

		// probe: listen for a revolution (two index pulses) at a rate / head
		S_PNEXT: begin
			rx_en <= 1'b1;
			idx_cnt <= 2'd0;
			maxr <= 6'd0;
			tmr_clr <= 1'b1;
			st <= S_LISTEN;
		end
		S_LISTEN: begin
			if (idx_edge)
				idx_cnt <= idx_cnt + 2'd1;
			if (id_stb && crc_ok && !p_head && id_rate != p_rate) begin
				// the PLL locked on another rate: listen at the measured one
				rx_en <= 1'b0;
				p_rate <= id_rate;
				rate <= id_rate;
				st <= S_PNEXT;
			end
			else if (id_stb && crc_ok && idn == 8'h02 && idr[7:6] == 2'b00) begin
				if (!p_head && idc == 8'd0 && idh == 8'd0 && idr[5:0] > maxr)
					maxr <= idr[5:0];
				if (p_head && idh == 8'd1)
					maxr <= 6'd1;
			end
			if ((idx_cnt == 2'd2 || tmr >= OP_US) && st == S_LISTEN && !(id_stb && crc_ok && !p_head && id_rate != p_rate)) begin
				rx_en <= 1'b0;
				if (p_head) begin
					begin if (n) heads2[1] <= (maxr != 6'd0); else heads2[0] <= (maxr != 6'd0); end
					st <= S_PEND;
				end
				else if (maxr != 6'd0) begin
					if (n) begin spt1 <= maxr; rate1 <= p_rate; end
					else begin spt0 <= maxr; rate0 <= p_rate; end
					begin if (n) dstep[1] <= (p_rate == 2'd1); else dstep[0] <= (p_rate == 2'd1); end
					p_head <= 1'b1;
					side <= 1'b1;
					st <= S_PNEXT;
				end
				else if (p_rate == 2'd2) begin
					// no IDs: unformatted, a 1.44M disk
					if (n) begin spt1 <= 6'd18; rate1 <= 2'd0; end
					else begin spt0 <= 6'd18; rate0 <= 2'd0; end
					begin if (n) dstep[1] <= 1'b0; else dstep[0] <= 1'b0; end
					begin if (n) heads2[1] <= 1'b1; else heads2[0] <= 1'b1; end
					st <= S_PEND;
				end
				else begin
					p_rate <= p_rate + 2'd1;
					rate <= p_rate + 2'd1;
					st <= S_PNEXT;
				end
			end
		end

		S_PEND: begin
			begin if (n) present[1] <= ~nodisk[1]; else present[0] <= ~nodisk[0]; end
			begin if (n) wp[1] <= wprt_s; else wp[0] <= wprt_s; end
			begin if (n) geo_upd[1] <= 1'b1; else geo_upd[0] <= 1'b1; end
			active <= 1'b0;
			rx_en <= 1'b0;
			side <= 1'b0;
			st <= S_IDLE;
		end

		default: st <= S_IDLE;
	endcase
end

// the pages (dbg_word with dbg_sel in the same clock)
always @(*)
	case (dbg_sel)
		3'd0: dbg_word = {n_bad, n_ok};
		3'd1: dbg_word = {n_sync, op_err, 1'b0, st};
		3'd2: dbg_word = {g_h, g_c};
		3'd3: dbg_word = {g_n, g_r};
		3'd4: dbg_word = {nodisk[0], present[0], heads2[0], dstep[0], wp[0], 1'b0, rate0, 2'b00, spt0};
		3'd5: dbg_word = {nodisk[1], present[1], heads2[1], dstep[1], wp[1], 1'b0, rate1, 2'b00, spt1};
		default: dbg_word = {1'b0, g_clks};
	endcase

assign fdd_out = {
	tx_en & tx_pulse,                   // WDATA
	tx_en,                              // WGATE
	sel_on & (active ? side : 1'b0),    // SIDE1
	step,                               // STEP
	dir,                                // DIR
	motor,                              // MOTOR
	sel_on & sel_pd,                    // DS1
	sel_on & ~sel_pd                    // DS0
};

endmodule
