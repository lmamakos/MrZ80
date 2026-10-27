#!/bin/bash
# run_blockdev_prog.sh - run testing/blockdevtest.asm (assembled -D SIM) on the
# real top level against a behavioural HPS block-interface model, in several
# configurations (see sim/tb_blockdev_prog.vhd). Prints the program's console
# output ("| ..." lines) and a PASS/FAIL verdict per configuration.
# Usage: sim/run_blockdev_prog.sh [workdir] [-v]     (-v: show console output)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

"$SCRIPT_DIR/check_sync.sh" > /dev/null

WORKDIR="${1:-/tmp/sim_blockdev_prog_build}"
VERBOSE="${2:-}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

"$PROJECT_ROOT/tools/z80asm.sh" -D SIM -o "$WORKDIR/blockdevtest_sim" testing/blockdevtest.asm > /dev/null

GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

FILES=(
    sim/sim_compat_pkg.vhd
    Components/Z80/T80_Pack.vhd
    Components/Z80/T80_ALU.vhd
    Components/Z80/T80_Reg.vhd
    Components/Z80/T80_MCode.vhd
    Components/Z80/T80.vhd
    Components/Z80/T80s.vhd
    Components/MMU/MMU.vhd
    sim/behav_ram_rom.vhd
    sim/behav_display.vhd
    sim/bufferedUART_sim.vhd
    sim/sd_controller_sim.vhd
    Components/SDCARD/hps_blockdev.vhd
    Components/RTC/ds12887.vhd
    Components/FRONTPANEL/Transparent_Capture_Chain.vhd
    Components/FRONTPANEL/Universal_Capture_Chain.vhd
    Components/FRONTPANEL/FP_RAM_Store.vhd
    Components/FRONTPANEL/FrontPanel_Subsystem.vhd
    Components/TIMER/BenchTimer.vhd
    ssp/rtl/z80_bus_mux.vhd
    ssp/rtl/ssp_tramp.vhd
    sim/MicrocomputerZ80CPM_sim.vhd
    sim/sdram_cdc_fake.vhd
    sim/tb_blockdev_prog.vhd
)
for f in "${FILES[@]}"; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" -gBIN="$WORKDIR/blockdevtest_sim.bin" tb_blockdev_prog

run() {   # index, name, generics...   (runs in the background, output to a file)
    local idx="$1" name="$2"; shift 2
    (
        echo "---- $name ----"
        ghdl -r "${GHDL_FLAGS[@]}" tb_blockdev_prog -gBIN="$WORKDIR/blockdevtest_sim.bin" "$@" \
            --ieee-asserts=disable 2>&1 | sed -n 's/.*(report \(note\|warning\|error\|failure\)): //p' > "$WORKDIR/out.$idx.raw" || true
        echo "---- $name ----" > "$WORKDIR/out.$idx"
        if [[ -n "$VERBOSE" ]]; then cat "$WORKDIR/out.$idx.raw" >> "$WORKDIR/out.$idx"
        else grep -v '^| ' "$WORKDIR/out.$idx.raw" >> "$WORKDIR/out.$idx"; fi
    ) > /dev/null &
}

# The configurations are independent, so they run in parallel (each takes
# several minutes of CPU in GHDL).
run 1 "normal"                                        -gNBLK=16
run 2 "read-only image"                               -gNBLK=16 -gREADONLY=true
run 3 "image mounted late"                            -gNBLK=16 -gMOUNT_US=300
run 4 "FAULT: last-block writes dropped (must FAIL)"  -gNBLK=16 -gFAULT=1 -gEXPECT_FAIL=true
run 5 "FAULT: write address bit 0 stuck (must FAIL)"  -gNBLK=16 -gFAULT=2 -gEXPECT_FAIL=true
wait
cat "$WORKDIR"/out.[0-9]
grep -h "^PASS\|^FAIL" "$WORKDIR"/out.[0-9] | sort | uniq -c
