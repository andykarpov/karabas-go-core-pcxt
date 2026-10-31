#!/bin/bash
# Simulate the flags of ADD / ADC / SUB / SBB on the MCL86 (sim/tb_cpu_flags.v, the program from
# sim/gen_cpu_flags.py) with iverilog. Usage: sim/run_cpu_sim.sh (the CPU of HW/8088/mcl86_2026),
# OLD=1 sim/run_cpu_sim.sh (the old one of HW/8088)
set -e
cd "$(dirname "$0")"
mkdir -p build
H=../../../../HW
python3 gen_cpu_flags.py
if [ -n "$OLD" ]; then
	cp $H/8088/microcode.mem build/
	iverilog -g2005 -o build/tb_cpu_flags.vvp -s tb_cpu_flags tb_cpu_flags.v $H/8088/*.v
else
	cp $H/8088/mcl86_2026/mcl86_ucode.mem build/
	iverilog -g2005 -DMCL86_2026 -o build/tb_cpu_flags.vvp -s tb_cpu_flags tb_cpu_flags.v $H/8088/mcl86_2026/*.v
fi
(cd build && vvp -n tb_cpu_flags.vvp) | tee build/tb_cpu_flags.log | grep -E "ERROR|errors|tests" | head -40
grep -q "tb_cpu_flags: 0 errors" build/tb_cpu_flags.log
