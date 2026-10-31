#!/bin/bash
# Simulate the floppy DMA of the core (sim/tb_dma_fdd.v: KF8237 + Ready.v + the floppy glue +
# floppy.v) with iverilog. Usage: sim/run_dma_sim.sh
set -e
cd "$(dirname "$0")"
mkdir -p build
H=../../../../HW
iverilog -g2005 -o build/tb_dma_fdd.vvp -s tb_dma_fdd \
	tb_dma_fdd.v $H/KFPC-XT/HDL/KF8237/HDL/KF8237*.v $H/KFPC-XT/HDL/Ready.v \
	$H/common/floppy.v $H/common/simple_fifo.v
vvp -n build/tb_dma_fdd.vvp | tee build/tb_dma_fdd.log | grep -E "ERROR|errors|sectors"
grep -q "tb_dma_fdd: 0 errors" build/tb_dma_fdd.log
