//`default_nettype none

module hdmi_frame(

	input wire clk_rgb,
	input wire clk_vga,
	input wire reset, 

	// input video
	input wire [17:0] rgb,
	input wire hs,
	input wire vs,

	// output video
	output wire [23:0] hdmi_rgb,
	output wire hdmi_hs,
	output wire hdmi_vs,
	output wire hdmi_blank,
	
	// debug
	output wire [10:0] width,
	output wire [10:0] height
);

localparam [10:0] hoff = 160;
localparam [10:0] voff = 36;

// clk_hdmi
wire clk_hdmi = clk_vga;

// 720x480 desired vmode
// 720 736 798 896  480 489 495 525 -HSync -VSync

reg prev_hs, prev_vs;
reg [10:0] hcnt, vcnt;
reg [10:0] htotal, vtotal;
always @(posedge clk_rgb, posedge reset)
begin
	if (reset) begin
		hcnt <= 11'd0;
		vcnt <= 11'd0;
		prev_hs <= 1'b0;
		prev_vs <= 1'b0;
		htotal <= 11'd0;
		vtotal <= 11'd0;
	end else begin
		prev_hs <= hs;
		if (~hs && prev_hs) begin
			htotal <= hcnt;
			hcnt <= 0;
			prev_vs <= vs;
			if (~vs && prev_vs) begin
				vtotal <= vcnt;
				vcnt <= 0;
			end
			else
				vcnt <= vcnt + 1;
		end
		else
			hcnt <= hcnt + 1;	
	end
end
assign width = htotal;
assign height = vtotal;

// hdmi blank
wire h_blank = (hcnt < hoff) || (hcnt >= 720+hoff);
wire v_blank = (vcnt < voff) || (vcnt >= 480+voff);
assign hdmi_blank = h_blank || v_blank;
wire rgb_active = ~hdmi_blank;

// hdmi sync
assign hdmi_hs = ~((hcnt >= 0) && (hcnt <= 62)); // neg
assign hdmi_vs = ~((vcnt >= 0) && (vcnt <= 6)); // neg

// scanline write
/*reg [10:0] waddr;
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
	raddr <= {vcnt[1], hcnt[9:0]}; // {vcnt[1], 1'b0, hcnt[9:1]};
end

// 2-port scanline ram (2 rows, 1024 px each)
wire [17:0] rgb_raw;
dpram2 #(.addr_width_g(11), .data_width_g(18)) hdmi_buffer(
	.clk_a_i(clk_rgb),
	.we_i(rgb_active),
	.addr_a_i(waddr),
	.data_a_i(rgb),
	.clk_b_i(clk_hdmi),
	.addr_b_i(raddr),
	.data_b_o(rgb_raw)
);*/

// output
assign hdmi_rgb = {rgb[17:12], 2'b0,  
						 rgb[11:6], 2'b0,  
						 rgb[5:0], 2'b0}; 

//				{rgb_raw[17:12], 2'b0,  
//				 rgb_raw[11:6], 2'b0,  
//				 rgb_raw[5:0], 2'b0}; 

endmodule
