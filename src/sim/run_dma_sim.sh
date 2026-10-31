#!/bin/bash
# Simulate the floppy DMA of the core (sim/tb_dma_fdd.v: a read, sim/tb_dma_fdd_wr.v: a write;
# KF8237 + Ready.v + the floppy glue + floppy.v) with iverilog. Usage: sim/run_dma_sim.sh
set -e
cd "$(dirname "$0")"
mkdir -p build
H=../rtl
iverilog -g2005 -o build/tb_dma_fdd.vvp -s tb_dma_fdd \
	tb_dma_fdd.v $H/chipset/KF8237/KF8237*.v $H/chipset/Ready.v \
	$H/common/floppy.v $H/common/simple_fifo.v
vvp -n build/tb_dma_fdd.vvp | tee build/tb_dma_fdd.log | grep -E "ERROR|errors|sectors"
grep -q "tb_dma_fdd: 0 errors" build/tb_dma_fdd.log
iverilog -g2005 -o build/tb_dma_fdd_wr.vvp -s tb_dma_fdd_wr \
	tb_dma_fdd_wr.v $H/chipset/KF8237/KF8237*.v $H/chipset/Ready.v \
	$H/common/floppy.v $H/common/simple_fifo.v
vvp -n build/tb_dma_fdd_wr.vvp | tee build/tb_dma_fdd_wr.log | grep -E "ERROR|errors|write:"
grep -q "tb_dma_fdd_wr: 0 errors" build/tb_dma_fdd_wr.log
