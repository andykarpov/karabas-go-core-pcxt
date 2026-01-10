`default_nettype none

module hdmi_frame(

	input wire clk_rgb, // 7 / 12 MHz
	input wire clk_vga, // 28 / 24 MHz
	input wire reset, 

	input wire [3:0] vmode, // ds80, screen, mode80

	// input video
	input wire [8:0] rgb,
	input wire rgb_active,
	input wire frame_lock,

	// output video
	output wire [23:0] hdmi_rgb,
	output wire hdmi_hs,
	output wire hdmi_vs,
	output wire hdmi_blank,
	output wire hdmi_frame_reset
);

// vmode
// 1000: profi    768x312 50Hz (512+48+48 x 240+16+16) ~ 608x272 => 600x576 => 600x576p 50 Hz (vga frame 768x624) -- border l/r 44, t/b 32
// 1001: profi    768x264 60Hz (512+48+48 x 240+00+00) ~ 608x240 => 600x480 => 600x480p 60 Hz (vga frame 768x528) -- border l/r 44, t/b 0
// 0000: pentagon 448x320 50Hz (256+64+64 x 192+48+64) ~ 384x288 => 360x288 => 720x576p 50 Hz (vga frame 896x640) -- border l/r 104, t/b 96/128
// 0001: pentagon 448x264 60Hz (256+64+64 x 192+xx+xx) ~ 384x240 => 360x240 => 720x480p 60 Hz (vga frame 896x528) -- border l/r 104, t/b 88/88
// 0010: 48       448x312 50Hz (256+64+64 x 192+xx+xx) ~ 384x288 => 360x288 => 720x576p 50 Hz (vga frame 896x624) -- border l/r 104, t/b ? 
// 0011: 48       448x256 60Hz (256+64+64 x 192+xx+xx) ~ 384x240 => 360x240 => 720x480p 60 Hz (vga frame 896x512) -- border l/r 104, t/b ?
// 0100: +3       448x312 50Hz (256+64+64 x 192+xx+xx) ~ 384x288 => 360x288 => 720x576p 50 Hz (vga frame 896x624) -- border l/r 104, t/b ? 
// 0101: +3       448x256 60Hz (256+64+64 x 192+xx+xx) ~ 384x240 => 360x240 => 720x480p 60 Hz (vga frame 896x512) -- border l/r 104, t/b ?
// 0110: 128      448x312 50Hz (256+64+64 x 192+xx+xx) ~ 384x288 => 360x288 => 720x576p 50 Hz (vga frame 896x624) -- border l/r 104, t/b ? 
// 0111: 128      448x256 60Hz (256+64+64 x 192+xx+xx) ~ 384x240 => 360x240 => 720x480p 60 Hz (vga frame 896x512) -- border l/r 104, t/b ?

wire ds80, mode60;
wire [1:0] screen;
assign {ds80, screen, mode60} = vmode;

// vmode parameters
reg [99:0] vmode_params;
always @(*) begin
	casex(vmode)
		// pengagon 50 (720x576 visible)
		// 720 732 796 896  576 581 586 640 -HSync -VSync
		4'b0xx0: vmode_params <= {10'd24, 10'd743, 10'd755, 10'd819, 10'd895,  // h disp start, end, sync start, end, line end 
										 10'd16, 10'd591, 10'd596, 10'd601, 10'd639}; // v disp start, end, sync start, end, frame end
		// pentagon 60 (720x480 visible)
		// 720 736 798 896  480 489 495 528 -HSync -VSync		
		4'b0xx1: vmode_params <= {10'd24, 10'd743, 10'd759, 10'd821, 10'd895, 
										 10'd24, 10'd503, 10'd512, 10'd518, 10'd527};
		// profi 50 (600x576 visible)
		// 600 616 672 768  576 579 589 624 -Hsync +Vsync
		4'b1xx0: vmode_params <= {10'd4,  10'd603, 10'd619, 10'd675, 10'd767,
										 10'd16,  10'd591, 10'd594, 10'd604, 10'd623};
		// profi 60 (600x480 visible)
		// 600 616 672 768  480 483 490 528 -Hsync +Vsync
		4'b1xx1: vmode_params <= {10'd4,  10'd603, 10'd619, 10'd675, 10'd767,
										 10'd32, 10'd511, 10'd514, 10'd521, 10'd527};
		// todo: spec vmodes!
	endcase
end

// clk_hdmi
wire clk_hdmi = clk_vga;

// frame reset on vmode change
reg frame_reset;
reg prev_vmode;
always @(posedge clk_hdmi) begin
	frame_reset <= 1'b0;
	if (prev_vmode != vmode)
		frame_reset <= 1'b1;
	prev_vmode <= vmode;
end
assign hdmi_frame_reset = frame_reset;

// vmode params extracted
wire [9:0] h_start, h_end, hs_start, hs_end, h_frame_end, v_start, v_end, vs_start, vs_end, v_frame_end;
assign {h_start, h_end, hs_start, hs_end, h_frame_end, v_start, v_end, vs_start, vs_end, v_frame_end} = vmode_params;

// sync cross clock domains
reg [1:0] frame_lock_r;
always @(posedge clk_hdmi)
	frame_lock_r <= {frame_lock_r[0], frame_lock};

wire frame_sync = (frame_lock_r == 2'b10); // falling edge
wire h_last = (hcnt == h_frame_end);
wire v_last = (vcnt == v_frame_end);

// counters
reg [9:0] hcnt, vcnt;
always @(posedge clk_hdmi) begin
	if (frame_sync) begin // reset counters on frame sync
		hcnt <= 0;
		vcnt <= 0;
	end
	else begin
		if (h_last) begin
			hcnt <= 0;
			if (v_last)
				vcnt <= 0;
			else
				vcnt <= vcnt + 1;
		end
		else
			hcnt <= hcnt + 1;
	end
end

// hdmi blank
wire h_blank = (hcnt < h_start) || (hcnt > h_end);
wire v_blank = (vcnt < v_start) || (vcnt > v_end);
assign hdmi_blank = h_blank || v_blank;

// hdmi sync
assign hdmi_hs = ~((hcnt >= hs_start) && (hcnt <= hs_end)); // neg
assign hdmi_vs = (ds80) ? ((vcnt >= vs_start) && (vcnt <= vs_end)) : ~((vcnt >= vs_start) && (vcnt <= vs_end)); // ds80 pos / pent neg

// scanline write
reg [10:0] waddr;
reg line = 1'b0;
reg prev_rgb_active;
always @(posedge clk_rgb) begin
	prev_rgb_active <= rgb_active;
	if (~rgb_active && prev_rgb_active) begin // input line blank start
		waddr <= {vcnt[1], 10'b0};
	end
	else if (rgb_active)
		waddr <= waddr + 1;
end

// scanline read
reg [10:0] raddr;
always @(posedge clk_hdmi) begin
	raddr <= ds80 ? {vcnt[1], hcnt[9:0]} : {vcnt[1], 1'b0, hcnt[9:1]}; //ds80 - single, pent - double pixel
end

// 2-port scanline ram (2 rows, 1024 px each)
wire [9:0] rgb_raw;
dpram2 #(.addr_width_g(11), .data_width_g(9)) hdmi_buffer(
	.clk_a_i(clk_rgb),
	.we_i(rgb_active),
	.addr_a_i(waddr),
	.data_a_i(rgb),
	.clk_b_i(clk_hdmi),
	.addr_b_i(raddr),
	.data_b_o(rgb_raw)
);

// output
assign hdmi_rgb = 
				{rgb_raw[8:6], 5'b0,  
				 rgb_raw[5:3], 5'b0,  
				 rgb_raw[2:0], 5'b0};  
	
endmodule
