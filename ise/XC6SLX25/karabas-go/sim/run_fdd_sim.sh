#!/bin/bash
# Simulate the floppy disks of the core (sim/tb_fdd.v: floppy.v + pcxt_disks / pcxt_fdd + a model
# of the mcu) with iverilog. Usage: sim/run_fdd_sim.sh
set -e
cd "$(dirname "$0")"
mkdir -p build
M=../../../../modules/rtl
H=../../../../HW
iverilog -g2005 -o build/tb_fdd.vvp -s tb_fdd \
	tb_fdd.v $H/common/floppy.v $H/common/simple_fifo.v ../rtl/pcxt_fdd.v ../rtl/pcxt_disks.v \
	$M/mcu/img_sdc.v $M/mcu/hdf_ata.v
vvp -n build/tb_fdd.vvp "$@" | tee build/tb_fdd.log | grep -E "ERROR|errors|read|write|format"
grep -q "tb_fdd: 0 errors" build/tb_fdd.log
