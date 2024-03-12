`timescale 1ns / 1ps
`default_nettype none
//////////////////////////////////////////////////////////////////////////////////
/*
MIT License

Copyright (c) 2022 Antonio S�nchez (@TheSonders)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

PS2MOUSE -> MSMOUSE Conversion
STREAM VERSION

References:
https://roborooter.com/post/serial-mice/
https://isdaman.com/alsos/hardware/mouse/ps2interface.htm
https://www.avrfreaks.net/sites/default/files/PS2%20Keyboard.pdf

*/
//////////////////////////////////////////////////////////////////////////////////
module MSMouseWrapper_emu
	#(parameter CLKFREQ=50_000_000)
	(input wire clk,
	
	input wire [7:0] ms_x,
	input wire [7:0] ms_y,
	input wire [2:0] ms_b,
	input wire ms_upd,
	
	input wire rts,
	output reg rd=0
	);

localparam HUNDRED=(CLKFREQ/10_000);
localparam SERIALBAUDRATE=1_200;
localparam SERIALPERIOD=(CLKFREQ/SERIALBAUDRATE);
localparam MILLIS=(CLKFREQ/1000);

`define RTSRISE		(rtsbuf==4'b0011)
`define RTSFALL		(rtsbuf==4'b0000)

reg [3:0]rtsbuf=0;

always @(posedge clk)begin
	rtsbuf<={rtsbuf[2:0],rts};
end

`define MSMByte1			{2'b11, LBut, RBut, AccY[7:6], AccX[7:6]}
`define MSMByte2			{2'b10, AccX[5:0]}
`define MSMByte3			{2'b10, AccY[5:0]}

`define Serial_Reset		 0

`define PS2Pr_M			30'h39AFFFFF

`define TMR_END	(Timer==0)

reg [7:0] prev_ms_x, prev_ms_y;
reg [2:0] prev_ms_b;
reg prev_ms_upd;
reg LBut=0;
reg RBut=0;
reg Prev_LBut=0;
reg Prev_RBut=0;
reg signed [7:0]AccX=0;
reg signed [7:0]AccY=0;
reg [$clog2(MILLIS)-1:0]Timer=0;
reg SerialSendRequest=0;
reg [4:0]Serial_STM=0;
reg [29:0]SerialSendData=0;

always @(posedge clk)begin

	if (SerialSendRequest==1)SerialSendRequest<=0;

///////////////////////////////////////////
/////////////Mouse Emulation///////////////
///////////////////////////////////////////

	// update accumulators from usb host data
	if (prev_ms_upd != ms_upd) begin
		prev_ms_upd <= ms_upd;
		LBut <= ms_b[0];
		RBut <= ms_b[1];
		AccX <= AccX + $signed(ms_x);
		AccY <= AccY - $signed(ms_y);
	end

	// mouse detection by RTS signal: send M character
	if (`RTSRISE) begin
		SendSerial(`PS2Pr_M);
		//Timer <= 0;
	end 
	// mouse packets if data changed
	else begin
		if (Timer!=0)Timer<=Timer-1;		
		if (SerialSendRequest==0 && Serial_STM==0) begin
			if (AccX!=0 || AccY!=0 || LBut!=Prev_LBut || RBut!=Prev_RBut) begin
				SendSerial({1'b1,`MSMByte3,2'b01,`MSMByte2,2'b01,`MSMByte1,1'b0});
				Prev_LBut<=LBut;
				Prev_RBut<=RBut;
				AccX<=0;
				AccY<=0;
			end
		end
	end

///////////////////////////////////////////
/////////////Serial Transmision////////////
///////////////////////////////////////////
	if (`RTSRISE)begin
		Serial_STM<=0;
	end
	else begin
	case (Serial_STM)
		`Serial_Reset:begin
			if (SerialSendRequest==1)begin
				Serial_STM<=Serial_STM+1;
				{SerialSendData,rd}<={1'b1,SerialSendData};
				SetTimer(SERIALPERIOD);
			end
			else begin
				rd<=1;
			end
		end
		default:begin
			if (`TMR_END)begin
				Serial_STM<=Serial_STM+1;
				{SerialSendData,rd}<={1'b1,SerialSendData};
				SetTimer(SERIALPERIOD);
			end
		end
	endcase
	end
end

task SendSerial (input [29:0] ByteToSend);
begin
	SerialSendRequest<=1;
	SerialSendData<=ByteToSend;
end
endtask

task SetTimer(input [31:0]TIME);
begin
	Timer<=TIME;
end
endtask

endmodule
