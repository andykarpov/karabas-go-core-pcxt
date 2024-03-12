#!/bin/sh

ghdl -a serial_mouse_convertor.vhd 
ghdl -a serial_mouse_testbench.vhd 
ghdl -r serial_mouse_testbench --stop-time=100ms --wave=serial_mouse.ghw
