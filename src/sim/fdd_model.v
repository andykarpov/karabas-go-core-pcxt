`timescale 1ns / 1ps

/*
 fdd_model.v

 A floppy drive on the pins of the FPGA (high = active, as on the Karabas Go), for tb_fdd_phys:
 - a disk image in memory (CYLS x HEADS x SPT x 512, byte i of a sector = c * 7 + h * 13 +
   r * 3 + i); the tracks as an IBM System 34 track (gap 4a, IAM, gap 1, the sectors 1..SPT with
   ID and data fields, gap 3, 4E up to TRK_BYTES) at CELL clocks of 20 ns per MFM cell, the
   rotation SPEED times slower, each cell with a random jitter of JIT;
 - index pulses, track 0, write protect (wprot), STEP / DIR on the selected drive: a step is
   taken at the end of a STEP pulse of STEP_MIN_NS or more, with DIR steady DIR_SETUP_NS before
   it (a shorter pulse is lost, as a real drive at the edge of its timing may lose it; short_steps
   counts them);
 - the write data while the write gate is on is decoded: an ID field (a format) gives the sector
   of the next data field, else the sector whose ID passed last; the data field goes into the
   image (crc_errs counts the data fields with a wrong CRC). A track written from its index
   (a format) counts its IDs in fmt_ids.
 - unfmt_c: this cylinder has no format (4E only); disk_in 0: no disk (no index, no data).
*/

module fdd_model #(
	parameter DS = 1,
	parameter integer CELL = 10,
	parameter integer SPT = 4,
	parameter integer HEADS = 2,
	parameter integer CYLS = 80,
	parameter integer GAP3 = 80,
	parameter integer TRK_BYTES = 3000,
	parameter real SPEED = 1.01,
	parameter real JIT = 0.05,
	parameter integer CYL0 = 5,
	parameter real STEP_MIN_NS = 3000.0,
	parameter real DIR_SETUP_NS = 3000.0
) (
	input wire [7:0] fdd_out,
	output wire [3:0] fdd_in
);

wire sel = DS ? fdd_out[1] : fdd_out[0];
wire motor = fdd_out[2];
wire dir = fdd_out[3];
wire step = fdd_out[4];
wire side = fdd_out[5];
wire wgate = fdd_out[6];
wire wdata = fdd_out[7];

reg disk_in = 1'b1;
reg wprot = 1'b0;
integer unfmt_c = 255;
integer crc_errs = 0;
integer data_writes = 0;
integer fmt_ids = 0;

integer cyl = CYL0;
integer short_steps = 0;
realtime dir_t = 0, step_t = 0;
reg step_dir_ok = 1'b0;
always @(dir) dir_t = $realtime;
always @(posedge step) begin
	step_t = $realtime;
	step_dir_ok = ($realtime - dir_t >= DIR_SETUP_NS);
end
always @(negedge step)
	if (sel) begin
		if (!step_dir_ok || $realtime - step_t < STEP_MIN_NS) begin
			if (short_steps < 3)
				$display("%t fdd_model DS%0d: a step lost (pulse %0.0f ns, dir set %0.0f ns before)",
					$realtime, DS, $realtime - step_t, step_t - dir_t);
			short_steps = short_steps + 1;
		end
		else if (dir) begin
			if (cyl < CYLS - 1) cyl = cyl + 1;
		end
		else if (cyl > 0)
			cyl = cyl - 1;
	end

reg idx = 1'b0, rd = 1'b0;
assign fdd_in = sel ? {rd, wprot, cyl == 0, idx & disk_in & motor} : 4'b0000;

reg [7:0] img [0:CYLS*HEADS*SPT*512-1];
integer i0, c0, h0, r0;
initial
	for (c0 = 0; c0 < CYLS; c0 = c0 + 1)
		for (h0 = 0; h0 < HEADS; h0 = h0 + 1)
			for (r0 = 1; r0 <= SPT; r0 = r0 + 1)
				for (i0 = 0; i0 < 512; i0 = i0 + 1)
					img[((c0 * HEADS + h0) * SPT + r0 - 1) * 512 + i0] = (c0 * 7 + h0 * 13 + r0 * 3 + i0) & 255;

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

// ---------------- the rotation ----------------

real cell_ns;
integer seed = 1 + DS;
reg lastbit = 1'b0;
reg [15:0] gcrc;
integer pos = 0;
integer gen_r = 0;                  // the sector of the last ID that passed

task cell_out;
	input b;
	real t, j;
	begin
		j = ($random(seed) % 1000) / 1000.0 * JIT;
		t = cell_ns * (1.0 + j);
		if (b && disk_in && motor && !wgate) begin
			rd = 1'b1;
			#(t * 0.3) rd = 1'b0;
			#(t * 0.7);
		end
		else
			#(t);
	end
endtask

task emit;
	input [7:0] b;
	input [1:0] k;
	reg [15:0] w;
	reg q;
	integer i;
	begin
		if (k == 2'd1) w = 16'h4489;
		else if (k == 2'd2) w = 16'h5224;
		else begin
			q = lastbit;
			for (i = 7; i >= 0; i = i - 1) begin
				w[2*i+1] = ~(q | b[i]);
				w[2*i] = b[i];
				q = b[i];
			end
		end
		lastbit = w[0];
		gcrc = crc16(gcrc, b);
		for (i = 15; i >= 0; i = i - 1)
			cell_out(w[i]);
		pos = pos + 1;
		if (pos == 3) idx = 1'b0;
	end
endtask

task emit_n;
	input [7:0] b;
	input integer n;
	integer i;
	begin
		for (i = 0; i < n; i = i + 1)
			emit(b, 2'd0);
	end
endtask

task sync3;
	begin
		gcrc = 16'hFFFF;
		emit(8'hA1, 2'd1);
		emit(8'hA1, 2'd1);
		emit(8'hA1, 2'd1);
	end
endtask

integer s, i, c, h;
reg [15:0] cc;
initial begin
	cell_ns = CELL * 20.0 * SPEED;
	#1000;
	forever begin
		idx = 1'b1;
		pos = 0;
		c = cyl;
		h = (HEADS == 2) ? side : 0;
		if (c == unfmt_c || (side && HEADS == 1))
			emit_n(8'h4E, 146);
		else begin
			emit_n(8'h4E, 80);
			emit_n(8'h00, 12);
			emit(8'hC2, 2'd2); emit(8'hC2, 2'd2); emit(8'hC2, 2'd2);
			emit(8'hFC, 2'd0);
			emit_n(8'h4E, 50);
		end
		for (s = 1; s <= SPT; s = s + 1) begin
			c = cyl;
			h = (HEADS == 2) ? side : 0;
			if (c == unfmt_c || (side && HEADS == 1))
				emit_n(8'h4E, 574 + GAP3);
			else begin
				emit_n(8'h00, 12);
				sync3;
				emit(8'hFE, 2'd0);
				emit(c, 2'd0); emit(h, 2'd0); emit(s, 2'd0); emit(8'h02, 2'd0);
				cc = gcrc;
				emit(cc[15:8], 2'd0); emit(cc[7:0], 2'd0);
				gen_r = s;
				emit_n(8'h4E, 22);
				emit_n(8'h00, 12);
				sync3;
				emit(8'hFB, 2'd0);
				for (i = 0; i < 512; i = i + 1)
					emit(img[((c * HEADS + h) * SPT + s - 1) * 512 + i], 2'd0);
				cc = gcrc;
				emit(cc[15:8], 2'd0); emit(cc[7:0], 2'd0);
				emit_n(8'h4E, GAP3);
			end
		end
		while (pos < TRK_BYTES)
			emit(8'h4E, 2'd0);
	end
end

// ---------------- the write data ----------------

realtime t_last;
reg [15:0] raw;
integer bitc, mk, mcnt, wr_r, ids, k, j, jj;
reg after_sync;
reg [15:0] wcrc;
reg [7:0] idb [0:3];
reg [7:0] dbuf [0:511];
reg fmt_session;

task wbyte;
	input [7:0] b;
	begin
		if (mk == 0) begin
			if (after_sync && b == 8'hFE) begin mk = 1; mcnt = 0; wcrc = crc16(16'hCDB4, b); end
			else if (after_sync && b == 8'hFB) begin mk = 2; mcnt = 0; wcrc = crc16(16'hCDB4, b); end
		end
		else begin
			wcrc = crc16(wcrc, b);
			if (mk == 1) begin
				if (mcnt < 4) idb[mcnt] = b;
				if (mcnt == 5) begin
					mk = 0;
					wr_r = idb[2];
					ids = ids + 1;
					if (wcrc != 16'h0000) crc_errs = crc_errs + 1;
				end
			end
			else begin
				if (mcnt < 512) dbuf[mcnt] = b;
				if (mcnt == 513) begin
					mk = 0;
					if (wcrc != 16'h0000)
						crc_errs = crc_errs + 1;
					else begin
						for (jj = 0; jj < 512; jj = jj + 1)
							img[((cyl * HEADS + ((HEADS == 2) ? side : 0)) * SPT + wr_r - 1) * 512 + jj] = dbuf[jj];
						data_writes = data_writes + 1;
					end
				end
			end
			mcnt = mcnt + 1;
		end
		after_sync = 1'b0;
	end
endtask

task wcell;
	input b;
	begin
		raw = {raw[14:0], b};
		if (raw == 16'h4489) begin
			bitc = 0;
			after_sync = 1'b1;
			mk = 0;
		end
		else begin
			bitc = bitc + 1;
			if (bitc == 16) begin
				bitc = 0;
				wbyte({raw[14], raw[12], raw[10], raw[8], raw[6], raw[4], raw[2], raw[0]});
			end
		end
	end
endtask

always @(posedge wgate) begin
	t_last = $realtime;
	raw = 16'd0;
	bitc = 0;
	mk = 0;
	after_sync = 1'b0;
	wr_r = gen_r;
	ids = 0;
	fmt_session = (pos < 8);
end

always @(negedge wgate)
	if (fmt_session)
		fmt_ids = ids;

always @(posedge wdata)
	if (wgate) begin
		k = $rtoi(($realtime - t_last) / (CELL * 20.0) + 0.5);
		t_last = $realtime;
		for (j = 1; j < k; j = j + 1)
			wcell(1'b0);
		wcell(1'b1);
	end

endmodule
