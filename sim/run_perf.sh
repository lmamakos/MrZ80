#!/bin/bash
# run_perf.sh - assemble sim/sdram_perf.asm, then compile and run the
# tb_sdram_perf testbench with GHDL: reports the wait T-states SDRAM
# accesses cost (histogram per cycle type) and the total run time in
# T-states, and checks the payload's checksum. See sim/tb_sdram_perf.vhd.
# Usage: sim/run_perf.sh [workdir] [generic overrides, e.g. -gCLK_RAM_KHZ=112000]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

"$SCRIPT_DIR/check_sync.sh" > /dev/null

WORKDIR="${1:-/tmp/sim_perf_build}"
shift || true
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

"$PROJECT_ROOT/tools/z80asm.sh" -o "$WORKDIR/sdram_perf" sim/sdram_perf.asm > /dev/null
cp "$WORKDIR/sdram_perf.bin" sim/sdram_perf.bin

GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

FILES=(
    sim/sim_compat_pkg.vhd
    Components/Z80/T80_Pack.vhd
    Components/Z80/T80_ALU.vhd
    Components/Z80/T80_Reg.vhd
    Components/Z80/T80_MCode.vhd
    Components/Z80/T80.vhd
    Components/Z80/T80s.vhd
    Components/alancox/MMU.vhd
    sim/behav_ram_rom.vhd
    sim/behav_display.vhd
    sim/bufferedUART_sim.vhd
    sim/sd_controller_sim.vhd
    Components/FRONTPANEL/Transparent_Capture_Chain.vhd
    Components/FRONTPANEL/FP_RAM_Store.vhd
    Components/FRONTPANEL/FrontPanel_Subsystem.vhd
    Components/TIMER/BenchTimer.vhd
    sim/MicrocomputerZ80CPM_sim.vhd
    sim/sdram_cdc_fake.vhd
    sim/tb_sdram_perf.vhd
)

for f in "${FILES[@]}"; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_sdram_perf
ghdl -r "${GHDL_FLAGS[@]}" tb_sdram_perf "$@" --ieee-asserts=disable --stop-time=25ms 2>&1 \
    | sed -n 's/.*(report \(note\|error\)): //p'
