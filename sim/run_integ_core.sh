#!/bin/bash
# run_integ_core.sh - R-42 (SDRAM/BRAM/MMU half): the SSP engine through the REAL
# MicrocomputerZ80CPM fabric (sim/tb_integ_core.vhd + sim/tb_integ_core.asm).
# Exits non-zero on any failure.
#   MUX=<file>   use another z80_bus_mux source (mutation testing)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

"$SCRIPT_DIR/check_sync.sh" > /dev/null

WORKDIR="${1:-/tmp/sim_integ_core_build}"
MUX="${MUX:-ssp/rtl/z80_bus_mux.vhd}"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

tools/z80asm.sh -o "$WORKDIR/integ_core" sim/tb_integ_core.asm > "$WORKDIR/asm.log" 2>&1 \
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
         Components/TIMER/BenchTimer.vhd \
         "$MUX" ssp/rtl/ssp_tramp.vhd \
         sim/MicrocomputerZ80CPM_sim.vhd sim/sdram_cdc_fake.vhd \
         sim/tb_integ_core.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" -gBIN="$WORKDIR/integ_core.bin" tb_integ_core
ghdl -r "${GHDL_FLAGS[@]}" tb_integ_core --assert-level=failure --ieee-asserts=disable \
    -gBIN="$WORKDIR/integ_core.bin" --stop-time=200ms
