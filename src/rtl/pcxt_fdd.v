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
*/

module pcxt_fdd (
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
	output reg [7:0] sdc_byte_out_data = 8'd0
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

reg [3:0] state = S_IDLE;
reg [1:0] mnt_pend = 2'b00;
reg [15:0] mnt_secs0 = 16'd0, mnt_secs1 = 16'd0;
reg drive = 1'b0;
reg [2:0] step = 3'd0;
reg [9:0] pos = 10'd0;
reg [1:0] wait_cnt = 2'd0;

// the write buffer: one sector
reg [7:0] wbuf [0:511];
reg wbuf_we = 1'b0;
reg [8:0] wbuf_wa = 9'd0;
reg [7:0] wbuf_wd = 8'd0;
always @(posedge clk) begin
	if (wbuf_we)
		wbuf[wbuf_wa] <= wbuf_wd;
	sdc_byte_out_data <= wbuf[sdc_byte_addr];
end

// sectors of an image: its size up to 32 MB, else as large
function [15:0] secs_of;
	input [63:0] size;
	secs_of = (size[63:25] != 39'd0) ? 16'hFFFF : size[24:9];
endfunction

wire [15:0] secs = mgmt_fddn ? mnt_secs1 : mnt_secs0;
wire [7:0] geo_cyl = (secs <= 16'd720) ? 8'd40 : 8'd80;
wire [7:0] geo_spt =
	(secs <= 16'd320) ? 8'd8 : (secs <= 16'd360) ? 8'd9 : (secs <= 16'd640) ? 8'd8 :
	(secs <= 16'd720) ? 8'd9 : (secs <= 16'd1440) ? 8'd9 : (secs <= 16'd2400) ? 8'd15 :
	(secs <= 16'd2880) ? 8'd18 : 8'd36;
wire [1:0] geo_heads = (secs <= 16'd360) ? 2'd1 : 2'd2;

always @(posedge clk) begin
	mgmt_write <= 1'b0;
	mgmt_read <= 1'b0;
	wbuf_we <= 1'b0;

	if (reset) begin
		state <= S_IDLE;
		sdc_rd <= 2'b00;
		sdc_wr <= 2'b00;
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

		S_MOUNT: begin
			mgmt_write <= 1'b1;
			step <= step + 3'd1;
			case (step)
				3'd0: begin mgmt_address <= 4'd1; mgmt_writedata <= 16'd0; end
				3'd1: begin mgmt_address <= 4'd2; mgmt_writedata <= {8'd0, geo_cyl}; end
				3'd2: begin mgmt_address <= 4'd3; mgmt_writedata <= {8'd0, geo_spt}; end
				3'd3: begin mgmt_address <= 4'd4; mgmt_writedata <= secs; end
				3'd4: begin mgmt_address <= 4'd5; mgmt_writedata <= {14'd0, geo_heads}; end
				default: begin
					mgmt_address <= 4'd0;
					mgmt_writedata <= {15'd0, secs != 16'd0};
					state <= S_IDLE;
				end
			endcase
		end

		S_REQ: begin
			drive <= mgmt_readdata[15];
			mgmt_fddn <= mgmt_readdata[15];
			sdc_sector <= {17'd0, mgmt_readdata[14:0]};
			pos <= 10'd0;
			mgmt_address <= 4'd15;
			state <= request[0] ? S_RD : S_DRAIN;
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
			else if (request[1] == 1'b0)
				state <= S_IDLE;
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
	end
	if (img_mounted[1]) begin
		mnt_pend[1] <= 1'b1;
		mnt_secs1 <= secs_of(img_size);
	end
end

endmodule
