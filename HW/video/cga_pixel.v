// Graphics Gremlin
//
// Copyright (c) 2021 Eric Schlaepfer
// This work is licensed under the Creative Commons Attribution-ShareAlike 4.0
// International License. To view a copy of this license, visit
// http://creativecommons.org/licenses/by-sa/4.0/ or send a letter to Creative
// Commons, PO Box 1866, Mountain View, CA 94042, USA.
//
`default_nettype none

module cga_pixel(
	input		wire					clk,
	input		wire	[4:0]			clk_seq,
	input		wire					hres_mode,
	input		wire					grph_mode,
	input		wire					bw_mode,
	input		wire					mode_640,
	input		wire					tandy_16_mode,
	input		wire					thin_font,
	input		wire	[7:0]			vram_data,
	input		wire					vram_read_char,
	input		wire					vram_read_att,
	input		wire					disp_pipeline,
	input		wire					charrom_read,
	input		wire					display_enable,
	input		wire					cursor,
	input		wire	[4:0]			row_addr,
	input		wire					blink_enabled,
	input		wire					blink,
	input		wire					hsync,
	input		wire					vsync,
	input		wire					video_enabled,
	input		wire	[7:0]			cga_color_reg,
	input		wire	[3:0]			tandy_palette_color,
	input		wire	[3:0]			tandy_newcolor,
	input		wire					tandy_palette_set,
	input		wire	[4:0]			tandy_bordercol,
	output	wire	[3:0]			video
	);

    reg[7:0] attr_byte;
    reg[7:0] char_byte;
    reg[7:0] char_byte_old;
    reg[7:0] attr_byte_del;
    wire[7:0] charbits;
    reg[7:0] charbits1;
    reg[7:0] charbits2;
    reg[1:0] cursor_del;
    reg[1:0] display_enable_del;
    reg pix;
    reg pix_delay;
    reg[1:0] pix_bits;
    reg[1:0] pix_bits_old;
    reg[3:0] tandy_bits;
	 
    reg[3:0] tandy_palette[0:15];
	 
    wire pix_640;
    wire load_shifter;
    wire [2:0] charpix_sel;
    wire [3:0] video_out;
    assign video = (tandy_16_mode && hres_mode) ? tandy_palette[video_out] : video_out;

    // Character ROM
    reg[7:0] char_rom[0:4095];
	 
	 initial begin 
		 $readmemh("cga.hex", char_rom, 0, 4095);
		 
		 tandy_palette[0] = 4'h0;
		 tandy_palette[1] = 4'h1;
		 tandy_palette[2] = 4'h2;
		 tandy_palette[3] = 4'h3;
		 tandy_palette[4] = 4'h4;
		 tandy_palette[5] = 4'h5;
		 tandy_palette[6] = 4'h6;
		 tandy_palette[7] = 4'h7;
		 tandy_palette[8] = 4'h8;
		 tandy_palette[9] = 4'h9;
		 tandy_palette[10] = 4'ha;
		 tandy_palette[11] = 4'hb;
		 tandy_palette[12] = 4'hc;
		 tandy_palette[13] = 4'hd;
		 tandy_palette[14] = 4'he;
		 tandy_palette[15] = 4'hf;	 
	 end

    // Latch character and attribute data from VRAM
    // at appropriate times
    always @ (posedge clk)
    begin
	     if (tandy_palette_set)
		     tandy_palette[tandy_palette_color] = tandy_newcolor;
			  
        if (vram_read_char) begin
            char_byte <= vram_data;
            char_byte_old <= char_byte;
        end
        if (vram_read_att) begin
            attr_byte <= vram_data;
        end
    end

    // Fetch pixel data for graphics modes
    wire [2:0]muxin;
    assign muxin = hres_mode ? (clk_seq[3:1] + 3'd6) : (clk_seq[4:2] + 3'd7);
    always @ (*)
    begin
        if (video_enabled) begin
            // Hi-res vs low-res needs different adjustments
            // Normal CGA is low res only in graphics mode
            // Tandy uses "high res" mode for both 320x200x16
            // and 640x200x4 color modes
            case (muxin)
                3'd0: pix_bits <= char_byte[7:6];
                3'd1: pix_bits <= char_byte[5:4];
                3'd2: pix_bits <= char_byte[3:2];
                3'd3: pix_bits <= char_byte[1:0];
                3'd4: pix_bits <= attr_byte[7:6];
                3'd5: pix_bits <= attr_byte[5:4];
                3'd6: pix_bits <= attr_byte[3:2];
                3'd7: pix_bits <= attr_byte[1:0];
                default: pix_bits <= 2'b0;
            endcase
        end else begin
            pix_bits <= 2'b0;
        end
    end

    // Add a pipeline delay to the attribute byte data, cursor, and display
    // enable so they line up with the displayed character
    always @ (posedge clk)
    begin
        if (disp_pipeline) begin
            attr_byte_del <= video_enabled ? attr_byte : 8'd0;
            display_enable_del <= {display_enable_del[0], display_enable};
            cursor_del <= {cursor_del[0], cursor};
        end
    end

    // Look up character byte in our character ROM table
    wire[11:0] rom_addr;
    wire[11:0] rom_addr2;
    assign rom_addr = {1'b0,char_byte, row_addr[2:0]};
    assign rom_addr2 = {1'b1,char_byte, row_addr[2:0]};
//  char_rom[{~thin_font, 11'b0} | rom_addr];
    always @ (posedge clk)
    begin
        // Only load character bits at this point
        if (charrom_read) begin
            charbits1 <= char_rom[rom_addr];
        end
    end

    always @ (posedge clk)
    begin
        // Only load character bits at this point
        if (charrom_read) begin
            charbits2 <= char_rom[rom_addr2];
        end
    end

	 assign charbits = ((row_addr > 5'd7) && tandy_16_mode) ? 1'b0 : thin_font ? charbits1 : charbits2;
	 
    // This must be a mux. Using a shift register causes very weird
    // issues with the character ROM and Yosys turns it into a bunch
    // of flip-flops instead of a ROM.
	 	 
	 assign charpix_sel = hres_mode ? (clk_seq[3:1] + 3'd6) : (clk_seq[4:2] + 3'd7);  
	 
    always @ (*)
    begin
        if (video_enabled) begin
            // Hi-res vs low-res needs different adjustments
            case (charpix_sel)
                5'd0: pix <= charbits[7];
                5'd1: pix <= charbits[6];
                5'd2: pix <= charbits[5];
                5'd3: pix <= charbits[4];
                5'd4: pix <= charbits[3];
                5'd5: pix <= charbits[2];
                5'd6: pix <= charbits[1];
                5'd7: pix <= charbits[0];
                default: pix <= 0;
            endcase
        end else begin
            pix <= 0;
        end
    end

    // In 640x200 mode, alternate between the two bits from
    // the shift register outputs at specific times in the sequence
    wire[2:0] tmp_clk_seq;
    assign tmp_clk_seq = clk_seq + 3'd7;
    assign pix_640 = tmp_clk_seq[1] ? pix_bits[0] : pix_bits[1];

    // In Tandy 320x200x16 mode, concatenate two adjacent pixels
    wire temp;
    assign temp = clk_seq[1:0] == 2'b00;
    always @ (posedge clk)
    begin
        if (clk_seq[0]) begin
            if (clk_seq[1]) begin
                tandy_bits <= {pix_bits_old, pix_bits};
            end else begin
                pix_bits_old <= pix_bits;
            end
        end
    end

    // Add one clk cycle delay to match up pixel data with attribute byte
    // data.
    always @ (posedge clk)
    begin
        pix_delay <= pix;
    end

    // Applies video attributes, generates final video
    cga_attrib attrib (
        .clk(clk),
        .att_byte(attr_byte_del),
        .row_addr(row_addr),
        .cga_color_reg(cga_color_reg),
        .grph_mode(grph_mode),
        .bw_mode(bw_mode),
        .mode_640(mode_640),
        .tandy_16_mode(tandy_16_mode && hres_mode),
        .display_enable(display_enable_del[0]),
        .blink_enabled(blink_enabled),
        .blink(blink),
        .cursor(cursor_del[0]),
        .hsync(hsync),
        .vsync(vsync),
        .pix_in(pix_delay),
        .c0(pix_bits[0]),
        .c1(pix_bits[1]),
        .pix_640(pix_640),
        .pix_tandy(tandy_bits),
        .tandy_bordercol(tandy_bordercol),
        .pix_out(video_out)
    );

endmodule