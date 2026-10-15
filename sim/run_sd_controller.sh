#!/bin/bash
# run_sd_controller.sh - run sim/tb_sd_controller.vhd (the SPI SD card
# controller, Components/SDCARD/sd_controller.vhd, against a behavioural SPI SD
# card model) in several configurations and print a PASS/FAIL verdict for each.
# The late-insertion and no-card configurations simulate 100-150 ms and take
# about a minute of CPU each; the configurations run in parallel.
# Usage: sim/run_sd_controller.sh [workdir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

"$SCRIPT_DIR/check_sync.sh" > /dev/null

WORKDIR="${1:-/tmp/sim_sd_controller_build}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")
for f in sim/sim_compat_pkg.vhd sim/sd_controller_sim.vhd sim/tb_sd_controller.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_sd_controller

run() {   # index, name, generics...
    local idx="$1" name="$2"; shift 2
    (
        echo "---- $name ----" > "$WORKDIR/out.$idx"
        ghdl -r "${GHDL_FLAGS[@]}" tb_sd_controller -gDBG=false "$@" --ieee-asserts=disable 2>&1 \
            | sed -n 's/.*(report \(note\|warning\|error\|failure\)): //p' \
            | grep -E "PASS|FAIL|mismatch|timeout|should|NEVER|init done|probe" >> "$WORKDIR/out.$idx" || true
    ) > /dev/null &
}

run 1 "normal SDHC card"                                  
run 2 "slow card (response after 64 idle bits)"           -gNCR_BITS=64
run 3 "fast card (response after 1 idle bit)"             -gNCR_BITS=1
run 4 "card needs 200 ACMD41 polls"                       -gPOLLS=200
run 5 "SDSC v1 card (CMD8 illegal)"                       -gV1=true
run 6 "card inserted 100 ms after reset (init retries)"   -gINSERT_US=100000 -gPROBE_US=90000
run 7 "no card: stays in init, retries, diagnostics"      -gEXPECT_NOCARD=true -gINSERT_US=1000000000 -gPROBE_US=150000
wait
cat "$WORKDIR"/out.[0-9]
echo
grep -h "PASS: tb_sd_controller" "$WORKDIR"/out.[0-9] | wc -l | sed 's/$/ of 7 configurations PASS/'
