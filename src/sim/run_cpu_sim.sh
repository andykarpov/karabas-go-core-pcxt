#!/bin/bash
# Simulate the flags of ADD / ADC / SUB / SBB on the MCL86 (sim/tb_cpu_flags.v, the program from
# sim/gen_cpu_flags.py) with iverilog. Usage: sim/run_cpu_sim.sh (the CPU of rtl/cpu),
# OLD=1 sim/run_cpu_sim.sh (the old one of rtl/cpu/mcl86_2022)
set -e
cd "$(dirname "$0")"
mkdir -p build
H=../rtl
python3 gen_cpu_flags.py
if [ -n "$OLD" ]; then
	cp $H/cpu/mcl86_2022/microcode.mem build/
	iverilog -g2005 -o build/tb_cpu_flags.vvp -s tb_cpu_flags tb_cpu_flags.v $H/cpu/mcl86_2022/*.v
else
	cp $H/cpu/mcl86_ucode.mem build/
	iverilog -g2005 -DMCL86_2026 -o build/tb_cpu_flags.vvp -s tb_cpu_flags tb_cpu_flags.v $H/cpu/*.v
fi
(cd build && vvp -n tb_cpu_flags.vvp) | tee build/tb_cpu_flags.log | grep -E "ERROR|errors|tests" | head -40
grep -q "tb_cpu_flags: 0 errors" build/tb_cpu_flags.log
