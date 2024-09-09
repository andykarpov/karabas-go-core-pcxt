///////////////////////////////////////////////////////////////////////////
/*
MIT License

Copyright (c) 2021 Antonio Sánchez (@TheSonders)
THE EXPERIMENT GROUP (@agnuca @Nabateo @subcriticalia)

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

 USB<->PS2
Convertidor de teclado USB a teclado PS2 con soporte de LEDs
Este módulo recibe y maneja directamente las líneas de transmisión USB.
Genera las señales PS/2 a 19200 baudios que simulan las teclas pulsadas/soltadas.
 
 USO DEL MÓDULO:
 -Señal de entrada de reloj 48MHz
 -Señales de entrada/Salida USB (D+ y D-)
 -Señales de salida PS/2 (CLK y DTA)
 -Señales de entrada del estado deseado para los 3 leds del teclado USB
    (Si no van a usarse estas entradas conectar a lógica 0)
 
 Antonio Sánchez (@TheSonders)
 Referencias:
 -Ben Eater Youtube Video:
     https://www.youtube.com/watch?v=wdgULBpRoXk
 -USB Specification Revision 2.0
 -https://usb.org/sites/default/files/hut1_22.pdf
 -https://crccalc.com/
 -https://www.perytech.com/USB-Enumeration.htm
 
 Modified by Andy Karpov to accept parsed usb reports as ps2 scancodes and transmit them as ps2
*/
///////////////////////////////////////////////////////////////////////////

//
`define LineAsInput     0
`define LineAsOutput    1

module usb_ps2_convertor
    (input wire clk,
	 input wire [7:0] kb_scancode,
	 input wire kb_scancode_upd,
    output reg PS2data=0,
    output reg PS2clock=1);
    
`define CLK_MULT        50000   //(CLK / 1000)
`define PS2_PRES        2499    //(CLK / 10000 baud / 2)-1
`define TYPEMATIC_DELAY 25000 // 25 // 25 000 000 (2 Hz) [23:0]
`define TYPEMATIC_CPS   5000  // 5  // 5 000 000 (10 Hz) [23:0]

////////////////////////////////////////////////////////////
//                    PS2 CONVERSION                      //
//////////////////////////////////////////////////////////// 
`define StopBit     1'b1
`define StartBit    1'b0
`define NextChar    PS2_signal[8:1]

reg PS2Busy=0;
reg [10:0]PS2_signal=0;
reg [6:0]PS2TX_STM=0;
reg [5:0]PS2_STM=0;
reg PS2_buffer_busy=0;
reg ParityBit=0;
reg [$clog2(`PS2_PRES)-1:0]PS2_Prescaler=0;

reg prev_kb_scancode_upd=0;
reg [7:0] prev_kb_scancode;

always @(posedge clk)begin
    if (StartTimer==1) StartTimer<=0;
	 
	 if (PS2Busy == 0) begin
		 if (prev_kb_scancode_upd != kb_scancode_upd) begin
			prev_kb_scancode_upd <= kb_scancode_upd;
			prev_kb_scancode <= kb_scancode;
			PS2Busy <= 1;
		 end
	 end
    
////////////////////////////////////////////////////////////
//                    PS2 CONVERSION                      //
////////////////////////////////////////////////////////////
    if (PS2_buffer_busy==0)begin
        if (PS2Busy==1) begin
				Add_PS2_Buffer(prev_kb_scancode);
			   PS2Busy<=0;
         end
    end
////////////////////////////////////////////////////////////
//                    PS2 TRANSMISION                     //
////////////////////////////////////////////////////////////  
    else begin
        if (PS2_Prescaler==0) begin
        PS2_Prescaler<=`PS2_PRES;
        case(PS2TX_STM) 
            0,24: begin
                if (`NextChar==0) begin
                    PS2_signal<={11'b0,PS2_signal[32:11]};
                    PS2TX_STM<=PS2TX_STM+24;
                end
                else begin
                    ParityBit<=1;
                    PS2TX_STM<=PS2TX_STM+1;
                    PS2data<=`StartBit;
                end
            end
            48: begin
                if (`NextChar==0) begin
                    PS2_buffer_busy<=0;
                    PS2TX_STM<=0;
                end
                else begin
                    ParityBit<=1;
                    PS2TX_STM<=PS2TX_STM+1;
                    PS2data<=`StartBit;
                end
            end
            18,42,66: begin
                PS2clock<=1;
                PS2data<=ParityBit;
                PS2TX_STM<=PS2TX_STM+1;
            end
            23,47: PS2TX_STM<=PS2TX_STM+1;
            71: begin
                PS2_buffer_busy<=0;
                PS2TX_STM<=0;
            end
            default: begin
                if (PS2TX_STM[0]==0) begin
                    PS2clock<=1;
                    PS2data<=PS2_signal[0];
                    PS2TX_STM<=PS2TX_STM+1;
                end
                else begin
                    PS2clock<=0;
                    PS2_signal<={1'b0,PS2_signal[32:1]};
                    ParityBit<=ParityBit^PS2data;
                    PS2TX_STM<=PS2TX_STM+1;
                end
            end
        endcase
        end
        else PS2_Prescaler<=PS2_Prescaler-1;
    end 
end

task Add_PS2_Buffer(input [7:0]sig);
    begin
    PS2_buffer_busy<=1;
    PS2_signal<=
        {`StopBit,`StopBit,sig[7:0],`StartBit};
    end
endtask


////////////////////////////////////////////////////////////
//                Temporizador auxiliar                   //
//////////////////////////////////////////////////////////// 
reg [19:0] TimerPreload=0;
reg StartTimer=0;
wire TimerEnd;
Timer Timer(
    .clk(clk),
    .TimerPreload(TimerPreload),
    .StartTimer(StartTimer),
    .TimerEnd(TimerEnd));
task SetTimer(input integer milliseconds);
    begin
        TimerPreload<=`CLK_MULT*milliseconds;
        StartTimer<=1;
    end
endtask
endmodule

module Timer (
    input wire clk,
    input wire [19:0]TimerPreload,
    input wire StartTimer,
    output wire TimerEnd);
    
    assign TimerEnd=(rTimerEnd & ~StartTimer);
    
    reg rTimerEnd=0;
    reg PrevStartTimer=0;
    reg [19:0]Counter=0;
    always @(posedge clk)begin
        PrevStartTimer<=StartTimer;
        if (StartTimer && !PrevStartTimer)begin
            Counter<=TimerPreload;
            rTimerEnd<=0;
        end
        else if (Counter==0) begin
            rTimerEnd<=1;
        end
        else Counter<=Counter-1;
    end    
endmodule 
