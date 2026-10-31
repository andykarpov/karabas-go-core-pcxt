`timescale 1ns / 1ns
`default_nettype wire

/*
 pcxt_fdd.v

 The disks of the floppy controller of system (floppy.v of MiSTer PCXT, FLOPPY of config.vh):
 drives A and B are slots 2 and 3 of the mcu file mounter (img_sdc). This does the work of the
 HPS of MiSTer on the management bus of floppy.v:
 - mount (sdc_img_mounted[n] with sdc_img_size): the geometry from the size (160K 40/8/1,
   180K 40/9/1, 320K 40/8/2, 360K 40/9/2, 720K 80/9/2, 1.2M 80/15/2, 1.44M 80/18/2, larger
   80/36/2, the next larger one for sizes between), written as registers 1 (write protect, 0),
   2 cylinders, 3 sectors per track, 4 sectors, 5 heads, then 0 (present; size 0: not present);
 - request[0] (a sector to read): register 0 holds {drive, sector}; the sector of the image goes
   from img_sdc into the fifo of floppy.v (register 15 writes), the fifo full ends the request;
 - request[1] (a sector to write or format): the 512 bytes of the fifo (register 15 reads: the
   data of the fifo, or the filler byte of a format) into the buffer here first, which ends the
   request in floppy.v, then the buffer goes to img_sdc as the write of the sector.
 One request at a time; after the fifo is full / empty the request line must go down before the
 next one is taken (floppy.v leaves its state a clock later).
 PHYS = 1 (Karabas Go): a drive whose slot the mcu maps to a physical drive (CMD_IMG_PHYS: slot 2 /
 3, drive 1 DS0 / 2 DS1; a mount of the slot ends it) goes to pcxt_fdd_phys (rtl/fdd): its
 geometry from the probe there (written as on a mount), its requests as ops on the buffer here
 (management register 6: format or write, and for a format the sectors per track and the data
 rate; 7, polled while idle: the motors and the selected drive of floppy.v; register 1 bit 1
 written on the mount: a physical drive, whose format sets the sectors per track):
 - read: the op fills the buffer, then the 512 bytes into the fifo;
 - write / format: 511 bytes out of the fifo into the buffer, the last one only read (the
   request stays until the op ends), the op, then the last byte taken;
 - an error of the op goes to register 6 (floppy.v ends the command with an error status);
 - while idle the diagnostics of pcxt_fdd_phys go to registers 8..14 (ports 3F0h / 3F1h / 3F3h).
*/

module pcxt_fdd #(
	parameter PHYS = 0
) (
	input wire clk,
	input wire reset,

	// floppy.v
	output reg [3:0] mgmt_address = 4'd0,
	output reg mgmt_fddn = 1'b0,
	output reg mgmt_write = 1'b0,
	output reg [15:0] mgmt_writedata = 16'd0,
	output reg mgmt_read = 1'b0,
	input wire [15:0] mgmt_readdata,
	input wire [1:0] request,

	// img_sdc, slots 2 (A) and 3 (B); busy / done / bytes only with the slot of one of them
	input wire [1:0] img_mounted,
	input wire [63:0] img_size,
	output reg [1:0] sdc_rd = 2'b00,
	output reg [1:0] sdc_wr = 2'b00,
	output reg [31:0] sdc_sector = 32'd0,
	input wire sdc_busy,
	input wire sdc_done,
	input wire sdc_byte_in_strobe,
	input wire [8:0] sdc_byte_addr,
	input wire [7:0] sdc_byte_in_data,
	output wire [7:0] sdc_byte_out_data,

	// PHYS: CMD_IMG_PHYS of kg_mcu, the floppy pins (see pcxt_fdd_phys)
	input wire img_phys_wr,
	input wire [15:0] img_phys,
	input wire [3:0] fdd_in,
	output wire [7:0] fdd_out
);

localparam S_IDLE = 4'd0;
localparam S_MOUNT = 4'd1;  // the geometry registers of a mounted drive
localparam S_REQ = 4'd2;    // register 0 on the bus: drive and sector
localparam S_RD = 4'd3;     // read: the request to img_sdc
localparam S_RDATA = 4'd4;  // read: the bytes into the fifo until sdc_done
localparam S_DRAIN = 4'd5;  // write: a fifo read
localparam S_DWAIT = 4'd6;  // write: the next byte of the fifo
localparam S_WR = 4'd7;     // write: the request to img_sdc, the buffer to it
localparam S_WWAIT = 4'd8;
localparam S_DROP = 4'd9;   // read: wait for the request line to go down
localparam S_WDROP = 4'd10; // write: the same, before the write (floppy.v goes on meanwhile: a
                            // request after the write is the next one)
localparam S_PKIND = 4'd11; // PHYS: the kind of the request
localparam S_PWAIT = 4'd12; // PHYS: the op
localparam S_PCOPY = 4'd13; // PHYS: read: the buffer into the fifo

reg [3:0] state = S_IDLE;
reg [1:0] mnt_pend = 2'b00;
reg [15:0] mnt_secs0 = 16'd0, mnt_secs1 = 16'd0;
reg drive = 1'b0;
reg [2:0] step = 3'd0;
reg [9:0] pos = 10'd0;
reg [1:0] wait_cnt = 2'd0;

// the physical drives
reg [1:0] map0 = 2'd0, map1 = 2'd0;  // A / B: 0 an image, 1 DS0, 2 DS1
reg [1:0] probe = 2'b00;
reg [2:0] dor = 3'd0;               // { selected drive, motors } of floppy.v
reg op_go = 1'b0;
reg [1:0] op_kind = 2'd0;
reg [5:0] op_spt = 6'd18;           // a format: its sectors per track and data rate (register 6)
reg [1:0] op_rate = 2'd0;
reg p_on = 1'b0;                    // an op owns the buffer
reg [2:0] dbg_sel = 3'd0;
wire [15:0] dbg_word;
wire op_done;
wire [1:0] op_err;
wire [1:0] geo_upd;
wire geo_present, geo_wp;
wire [7:0] geo_cyl, geo_spt;
wire [15:0] geo_secs;
wire [1:0] geo_heads;
wire ph_we;
wire [8:0] ph_a;
wire [7:0] ph_wd;
wire phys_n = PHYS && ((mgmt_fddn ? map1 : map0) != 2'd0);

// the sector buffer
reg [7:0] wbuf [0:511];
reg wbuf_we = 1'b0;
reg [8:0] wbuf_wa = 9'd0;
reg [7:0] wbuf_wd = 8'd0;
reg [7:0] wbuf_q = 8'd0;
wire [8:0] wbuf_ra = !p_on ? sdc_byte_addr : (state == S_PCOPY) ? pos[8:0] : ph_a;
always @(posedge clk) begin
	if (wbuf_we)
		wbuf[wbuf_wa] <= wbuf_wd;
	else if (p_on && ph_we)
		wbuf[ph_a] <= ph_wd;
	wbuf_q <= wbuf[wbuf_ra];
end
assign sdc_byte_out_data = wbuf_q;

generate if (PHYS) begin : g_phys
	pcxt_fdd_phys u_phys(
		.clk(clk),
		.reset(reset),
		.map0(map0),
		.map1(map1),
		.probe(probe),
		.dor_motor(dor[1:0]),
		.dor_drive(dor[2]),
		.op_go(op_go),
		.op_kind(op_kind),
		.op_n(drive),
		.op_lba(sdc_sector[15:0]),
		.op_spt(op_spt),
		.op_rate(op_rate),
		.op_done(op_done),
		.op_err(op_err),
		.geo_upd(geo_upd),
		.geo_n(mgmt_fddn),
		.geo_present(geo_present),
		.geo_wp(geo_wp),
		.geo_cyl(geo_cyl),
		.geo_spt(geo_spt),
		.geo_secs(geo_secs),
		.geo_heads(geo_heads),
		.buf_we(ph_we),
		.buf_a(ph_a),
		.buf_wd(ph_wd),
		.buf_q(wbuf_q),
		.fdd_in(fdd_in),
		.fdd_out(fdd_out),
		.dbg_sel(dbg_sel),
		.dbg_word(dbg_word)
	);
end else begin : g_no_phys
	assign dbg_word = 16'd0;
	assign op_done = 1'b0;
	assign op_err = 2'd0;
	assign geo_upd = 2'b00;
	assign geo_present = 1'b0;
	assign geo_wp = 1'b0;
	assign geo_cyl = 8'd0;
	assign geo_spt = 8'd0;
	assign geo_secs = 16'd0;
	assign geo_heads = 2'd0;
	assign ph_we = 1'b0;
	assign ph_a = 9'd0;
	assign ph_wd = 8'd0;
	assign fdd_out = 8'h00;
end endgenerate

// sectors of an image: its size up to 32 MB, else as large
function [15:0] secs_of;
	input [63:0] size;
	secs_of = (size[63:25] != 39'd0) ? 16'hFFFF : size[24:9];
endfunction

wire [15:0] secs = mgmt_fddn ? mnt_secs1 : mnt_secs0;
wire [7:0] img_cyl = (secs <= 16'd720) ? 8'd40 : 8'd80;
wire [7:0] img_spt =
	(secs <= 16'd320) ? 8'd8 : (secs <= 16'd360) ? 8'd9 : (secs <= 16'd640) ? 8'd8 :
	(secs <= 16'd720) ? 8'd9 : (secs <= 16'd1440) ? 8'd9 : (secs <= 16'd2400) ? 8'd15 :
	(secs <= 16'd2880) ? 8'd18 : 8'd36;
wire [1:0] img_heads = (secs <= 16'd360) ? 2'd1 : 2'd2;

always @(posedge clk) begin
	mgmt_write <= 1'b0;
	mgmt_read <= 1'b0;
	wbuf_we <= 1'b0;
	op_go <= 1'b0;
	probe <= 2'b00;

	if (reset) begin
		state <= S_IDLE;
		sdc_rd <= 2'b00;
		sdc_wr <= 2'b00;
		p_on <= 1'b0;
	end
	else case (state)
		S_IDLE:
			if (mnt_pend != 2'b00) begin
				mgmt_fddn <= ~mnt_pend[0];
				mnt_pend[~mnt_pend[0]] <= 1'b0; // a mount of it while S_MOUNT: pending again
				step <= 3'd0;
				state <= S_MOUNT;
			end
			else if (request != 2'b00) begin
				mgmt_address <= 4'd0;
				state <= S_REQ;
			end
			else if (PHYS) begin
				// the diagnostics of pcxt_fdd_phys into registers 8..14, then the motors / drive
				// of floppy.v (register 7) for the physical drives
				dbg_sel <= dbg_sel + 3'd1;
				if (dbg_sel == 3'd7)
					mgmt_address <= 4'd7;
				else begin
					mgmt_address <= 4'd8 + {1'b0, dbg_sel};
					mgmt_write <= 1'b1;
					mgmt_writedata <= dbg_word;
				end
				if (mgmt_address == 4'd7)
					dor <= mgmt_readdata[2:0];
			end

		S_MOUNT: begin
			mgmt_write <= 1'b1;
			step <= step + 3'd1;
			case (step)
				3'd0: begin mgmt_address <= 4'd1; mgmt_writedata <= {14'd0, phys_n, phys_n & geo_wp}; end
				3'd1: begin mgmt_address <= 4'd2; mgmt_writedata <= {8'd0, phys_n ? geo_cyl : img_cyl}; end
				3'd2: begin mgmt_address <= 4'd3; mgmt_writedata <= {8'd0, phys_n ? geo_spt : img_spt}; end
				3'd3: begin mgmt_address <= 4'd4; mgmt_writedata <= phys_n ? geo_secs : secs; end
				3'd4: begin mgmt_address <= 4'd5; mgmt_writedata <= {14'd0, phys_n ? geo_heads : img_heads}; end
				default: begin
					mgmt_address <= 4'd0;
					mgmt_writedata <= {15'd0, phys_n ? geo_present : secs != 16'd0};
					state <= S_IDLE;
				end
			endcase
		end

		S_REQ: begin
			drive <= mgmt_readdata[15];
			mgmt_fddn <= mgmt_readdata[15];
			sdc_sector <= {17'd0, mgmt_readdata[14:0]};
			pos <= 10'd0;
			if (PHYS && ((mgmt_readdata[15] ? map1 : map0) != 2'd0)) begin
				mgmt_address <= 4'd6;
				state <= S_PKIND;
			end
			else begin
				mgmt_address <= 4'd15;
				state <= request[0] ? S_RD : S_DRAIN;
			end
		end

		// PHYS: a read goes to the op, a write / format first through the fifo
		S_PKIND: begin
			op_kind <= request[0] ? 2'd1 : mgmt_readdata[0] ? 2'd3 : 2'd2;
			op_spt <= mgmt_readdata[13:8];
			op_rate <= mgmt_readdata[2:1];
			mgmt_address <= 4'd15;
			p_on <= 1'b1;
			if (request[0]) begin
				op_go <= 1'b1;
				state <= S_PWAIT;
			end
			else
				state <= S_DRAIN;
		end

		S_PWAIT:
			if (op_done) begin
				if (op_err != 2'd0) begin
					mgmt_address <= 4'd6;
					mgmt_write <= 1'b1;
					mgmt_writedata <= {14'd0, op_err};
					p_on <= 1'b0;
					state <= S_DROP;
				end
				else if (op_kind == 2'd1)
					state <= S_PCOPY;
				else begin
					mgmt_read <= 1'b1;  // the last byte
					p_on <= 1'b0;
					state <= S_DROP;
				end
			end

		// the buffer read one clock late: byte pos - 1 in wbuf_q
		S_PCOPY: begin
			if (pos != 10'd0) begin
				mgmt_write <= 1'b1;
				mgmt_writedata <= {8'd0, wbuf_q};
			end
			if (pos == 10'd512) begin
				p_on <= 1'b0;
				state <= S_DROP;
			end
			else
				pos <= pos + 10'd1;
		end

		S_RD: begin
			sdc_rd[drive] <= 1'b1;
			if (sdc_busy) begin
				sdc_rd <= 2'b00;
				state <= S_RDATA;
			end
		end

		S_RDATA: begin
			if (sdc_byte_in_strobe) begin
				mgmt_write <= 1'b1;
				mgmt_writedata <= {8'd0, sdc_byte_in_data};
			end
			if (sdc_done)
				state <= S_DROP;
		end

		// mgmt_readdata is the fifo a clock late (a register), mgmt_read a register too: the
		// next byte is there 3 clocks after a read, taken after 4. The request gone before the
		// end (a reset of the PC): no write
		S_DRAIN:
			if (pos == 10'd512)
				state <= S_WDROP;
			else if (request[1] == 1'b0) begin
				p_on <= 1'b0;
				state <= S_IDLE;
			end
			else if (p_on && pos == 10'd511) begin
				// PHYS: the last byte stays in the fifo until the op is done
				wbuf_we <= 1'b1;
				wbuf_wa <= 9'd511;
				wbuf_wd <= mgmt_readdata[7:0];
				op_go <= 1'b1;
				state <= S_PWAIT;
			end
			else begin
				mgmt_read <= 1'b1;
				wbuf_we <= 1'b1;
				wbuf_wa <= pos[8:0];
				wbuf_wd <= mgmt_readdata[7:0];
				pos <= pos + 10'd1;
				wait_cnt <= 2'd2;
				state <= S_DWAIT;
			end

		S_DWAIT:
			if (wait_cnt != 2'd0)
				wait_cnt <= wait_cnt - 2'd1;
			else
				state <= S_DRAIN;

		S_WR: begin
			sdc_wr[drive] <= 1'b1;
			if (sdc_busy) begin
				sdc_wr <= 2'b00;
				state <= S_WWAIT;
			end
		end

		S_WDROP:
			if (request[1] == 1'b0)
				state <= S_WR;

		S_WWAIT:
			if (sdc_done)
				state <= S_IDLE;

		S_DROP:
			if (request == 2'b00)
				state <= S_IDLE;

		default: state <= S_IDLE;
	endcase

	// after the case: a mount in the clock its pending flag is taken stays pending
	if (img_mounted[0]) begin
		mnt_pend[0] <= 1'b1;
		mnt_secs0 <= secs_of(img_size);
		map0 <= 2'd0;
	end
	if (img_mounted[1]) begin
		mnt_pend[1] <= 1'b1;
		mnt_secs1 <= secs_of(img_size);
		map1 <= 2'd0;
	end
	// PHYS: a slot on a physical drive, its probe; a new geometry of it
	if (PHYS && img_phys_wr && img_phys[15:9] == 7'd1 && img_phys[1:0] != 2'd0) begin
		if (img_phys[8]) map1 <= img_phys[1:0]; else map0 <= img_phys[1:0];
		if (img_phys[8]) probe[1] <= 1'b1; else probe[0] <= 1'b1;
	end
	if (geo_upd[0]) mnt_pend[0] <= 1'b1;
	if (geo_upd[1]) mnt_pend[1] <= 1'b1;
end

endmodule
