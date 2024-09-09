module KFPS2KB_direct (
	input		wire					clock,
	input		wire					reset,
	input		wire [7:0]			kb_scancode,
	input		wire					kb_scancode_upd,
	input    wire              reset_keybord,
	output	reg					irq,
	output	reg	[7:0]			keycode,
	input		wire					clear_keycode
);
	reg prev_kb_scancode_upd = 1'b0;
	reg error_flag = 1'b0;

	always @(posedge clock or posedge reset)
		if (reset) begin
			irq <= 1'b0;
			keycode <= 8'h00;
			error_flag <= 1'b0;
		end
		else if (reset_keybord) begin
			irq <= 1'b1;
			keycode <= 8'haa;
		end
		else if (clear_keycode) begin
			irq <= 1'b0;
			keycode <= 8'h00;
			error_flag <= 1'b0;
		end
		else if (prev_kb_scancode_upd != kb_scancode_upd) begin
			prev_kb_scancode_upd <= kb_scancode_upd;
			/*if ((irq == 1'b1) || (error_flag == 1'b1)) begin
				irq <= 1'b0;
				keycode <= 8'hff;
				error_flag <= 1'b1;
			end
			else */if (kb_scancode == 8'h00) begin
				irq <= 1'b0;
				keycode <= 8'h00;
				error_flag <= 1'b0;
			end
			else if (kb_scancode == 8'hfa) begin
				irq <= 1'b0;
				keycode <= 8'h00;
				error_flag <= 1'b0;
			end
			else begin
				irq <= 1'b1;
				keycode <= kb_scancode;
				error_flag <= 1'b0;
			end
		end
		else begin
			irq <= irq | error_flag;
			keycode <= keycode;
			error_flag <= error_flag;
		end
endmodule
