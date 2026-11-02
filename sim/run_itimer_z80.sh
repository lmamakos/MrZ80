#!/bin/bash
# run_itimer_z80.sh - the IntervalTimer raising a Z80 interrupt through the real
# MicrocomputerZ80CPM fabric (sim/tb_itimer_z80.vhd + sim/tb_itimer_z80.asm).
# Exits non-zero on any failure.
# Usage: sim/run_itimer_z80.sh [workdir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

"$SCRIPT_DIR/check_sync.sh" > /dev/null

WORKDIR="${1:-/tmp/sim_itimer_z80_build}"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

tools/z80asm.sh -o "$WORKDIR/itimer_z80" sim/tb_itimer_z80.asm > "$WORKDIR/asm.log" 2>&1 \
    || { cat "$WORKDIR/asm.log"; exit 1; }

for f in sim/sim_compat_pkg.vhd \
         Components/Z80/T80_Pack.vhd Components/Z80/T80_ALU.vhd \
         Components/Z80/T80_Reg.vhd Components/Z80/T80_MCode.vhd \
         Components/Z80/T80.vhd Components/Z80/T80s.vhd \
         Components/MMU/MMU.vhd \
         sim/behav_ram_rom.vhd sim/behav_display.vhd \
         sim/bufferedUART_sim.vhd sim/sd_controller_sim.vhd \
         Components/SDCARD/hps_blockdev.vhd Components/RTC/ds12887.vhd \
         Components/FRONTPANEL/Transparent_Capture_Chain.vhd \
         Components/FRONTPANEL/Universal_Capture_Chain.vhd \
         Components/FRONTPANEL/FP_RAM_Store.vhd \
         Components/FRONTPANEL/FrontPanel_Subsystem.vhd \
         Components/TIMER/BenchTimer.vhd Components/TIMER/IntervalTimer.vhd \
         ssp/rtl/z80_bus_mux.vhd ssp/rtl/ssp_tramp.vhd ssp/rtl/ssp_mem_client.vhd \
         sim/MicrocomputerZ80CPM_sim.vhd sim/sdram_cdc_fake.vhd \
         sim/tb_itimer_z80.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" -gBIN="$WORKDIR/itimer_z80.bin" tb_itimer_z80
ghdl -r "${GHDL_FLAGS[@]}" tb_itimer_z80 -gBIN="$WORKDIR/itimer_z80.bin" \
    --assert-level=error --ieee-asserts=disable --stop-time=40ms 2>&1 \
    | tee "$WORKDIR/run.log" | grep -E 'PASS|FAIL|INT asserted|preload' || true
grep -q 'PASS: tb_itimer_z80' "$WORKDIR/run.log"
