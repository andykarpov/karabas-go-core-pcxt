#!/bin/bash
# Simulate the physical floppy drives with iverilog (a few minutes each):
# - tb_fdd_phys.v: rtl/fdd/pcxt_fdd_phys.v alone on two drive models (fdd_model.v);
# - tb_fdd_int.v: floppy.v + pcxt_disks (PHYS_FDD 1) + a drive model, through the FDC ports.
# Usage: sim/run_fdd_phys_sim.sh [tb_fdd_phys|tb_fdd_int] [+vcd]
set -e
cd "$(dirname "$0")"
mkdir -p build
F=../rtl/fdd
H=../rtl
M=../../modules/rtl
TBS="tb_fdd_phys tb_fdd_int"
case "$1" in tb_*) TBS=$1; shift;; esac
for tb in $TBS; do
	iverilog -g2005 -o build/$tb.vvp -s $tb $tb.v fdd_model.v $F/pcxt_fdd_phys.v $F/mfm_rx.v $F/mfm_tx.v \
		$H/common/floppy.v $H/common/simple_fifo.v $H/pcxt_fdd.v $H/pcxt_disks.v $M/mcu/img_sdc.v $M/mcu/hdf_ata.v
	vvp -n build/$tb.vvp "$@" | tee build/$tb.log | grep -E "ERROR|errors|geometry|op |read|write|format"
	grep -q "$tb: 0 errors" build/$tb.log
done
