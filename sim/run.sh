#!/bin/bash
# run.sh - compile and run the tb_inir_race testbench with GHDL.
#
# Must be run with the project root as the working directory (the
# testbench's preload process opens "sim/sim_inir_race.bin" as a relative
# path). See sim/sim_compat_pkg.vhd for why sim/*_sim.vhd copies exist,
# and sim/tb_inir_race.vhd for the overall testbench architecture.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

"$SCRIPT_DIR/check_sync.sh"

WORKDIR="${1:-/tmp/sim_inir_race_build}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# Re-assemble the test payload in case sim_inir_race.asm changed.
"$PROJECT_ROOT/tools/z80asm.sh" -o "$WORKDIR/sim_inir_race" sim/sim_inir_race.asm
cp "$WORKDIR/sim_inir_race.bin" sim/sim_inir_race.bin

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
    sim/tb_inir_race.vhd
)

for f in "${FILES[@]}"; do
    echo "-- analyzing $f"
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done

echo "-- elaborating tb_inir_race"
ghdl -e "${GHDL_FLAGS[@]}" tb_inir_race

echo "-- running tb_inir_race"
ghdl -r "${GHDL_FLAGS[@]}" tb_inir_race --stop-time=25ms
