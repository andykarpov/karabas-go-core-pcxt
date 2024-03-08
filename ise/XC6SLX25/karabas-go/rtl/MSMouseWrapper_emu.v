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
	input wire [3:0] ms_z,
	input wire [2:0] ms_b,
	input wire rts,
	output reg rd=0
	);

localparam HUNDRED=(CLKFREQ/10_000);
localparam SERIALBAUDRATE=1_200;
localparam SERIALPERIOD=(CLKFREQ/SERIALBAUDRATE);
localparam MILLIS=(CLKFREQ/1000);

`define 	PAR_ODD	0
`define	PAR_EVEN	1

`define RTSRISE		(rtsbuf==4'b0011)
reg [3:0]rtsbuf=0;

always @(posedge clk)begin
	rtsbuf<={rtsbuf[2:0],rts};
end

`define MSMByte1			{2'b11,LBut,RBut,AccY[7:6],AccX[7:6]}
`define MSMByte2			{2'b10,AccX[5:0]}
`define MSMByte3			{2'b10,AccY[5:0]}

`define Serial_Reset		 0

`define TMR_END	(Timer==0)

wire [7:0]YC= ms_y;
wire [7:0]XC= ms_x;
wire LeftBt=ms_b[0];
wire RightBt=ms_b[1];

reg LBut=0;
reg RBut=0;
reg Prev_LBut=0;
reg Prev_RBut=0;
reg msbX=0;
reg msbY=0;
reg [1:0]ByteSync=0;
reg [7:0]AccX=0;
reg [7:0]AccY=0;

reg FUpdate=0;
reg PS2Detected=0;

reg [$clog2(MILLIS)-1:0]Timer=0;
reg SerialSendRequest=0;
reg [4:0]Serial_STM=0;
reg [29:0]SerialSendData=0;


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
