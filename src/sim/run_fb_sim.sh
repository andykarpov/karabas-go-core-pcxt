#!/bin/bash
# Simulate the HDMI frame buffer (sim/tb_fb.v: rtl/fb/pcxt_fb.v + fb_sdram.v and a model of the
# SDRAM) with iverilog. Usage: sim/run_fb_sim.sh
set -e
cd "$(dirname "$0")"
mkdir -p build
M=../../modules/rtl
X=/opt/Xilinx/14.7/ISE_DS/ISE/verilog/src
iverilog -g2005 -o build/tb_fb.vvp -s tb_fb -s glbl tb_fb.v ../rtl/fb/pcxt_fb.v ../rtl/fb/fb_sdram.v \
	$M/mem/kg_sdpram.v $M/ctl/kg_sync.v ../rtl/video/cga_vgaport.v $X/unisims/ODDR2.v $X/glbl.v
vvp -n build/tb_fb.vvp | tee build/tb_fb.log | grep -E "ERROR|errors|frame|checked" | head -40
grep -q "tb_fb: 0 errors" build/tb_fb.log
