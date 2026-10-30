#!/bin/bash
# Simulate the image disks of the core (sim/tb_disks.v: XT2IDE + pcxt_disks + a model of the mcu)
# with iverilog. Usage: sim/run_disks_sim.sh
set -e
cd "$(dirname "$0")"
mkdir -p build
M=../../../../modules/rtl
iverilog -g2005 -o build/tb_disks.vvp -s tb_disks \
	tb_disks.v ../../../../HW/KFPC-XT/HDL/XT2IDE.v ../rtl/pcxt_disks.v \
	$M/mcu/img_sdc.v $M/mcu/hdf_ata.v
vvp -n build/tb_disks.vvp | tee build/tb_disks.log | grep -E "ERROR|errors|geometry|word"
grep -q "tb_disks: 0 errors" build/tb_disks.log
