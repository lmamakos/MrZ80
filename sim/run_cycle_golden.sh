#!/bin/bash
# run_cycle_golden.sh - capture the real T80s' data-cycle waveforms
# (sim/tb_cycle_golden.vhd) and compare with the committed
# sim/ssp/golden_cycles.txt, the reference the p1a lane holds the SSP engine
# to (sim/ssp/p1a_engine_golden.sh, R-42).
#   sim/run_cycle_golden.sh            compare; non-zero on any difference
#   sim/run_cycle_golden.sh --update   rewrite the committed golden file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR=/tmp/sim_cycle_golden_build
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")
GOLDEN=sim/ssp/golden_cycles.txt

for f in Components/Z80/T80_Pack.vhd Components/Z80/T80_ALU.vhd \
         Components/Z80/T80_Reg.vhd Components/Z80/T80_MCode.vhd \
         Components/Z80/T80.vhd Components/Z80/T80s.vhd sim/tb_cycle_golden.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_cycle_golden
ghdl -r "${GHDL_FLAGS[@]}" tb_cycle_golden --ieee-asserts=disable \
    -gOUT_FILE="$WORKDIR/golden_cycles.txt" --stop-time=100us

if [ "${1:-}" = "--update" ]; then
    cp "$WORKDIR/golden_cycles.txt" "$GOLDEN"
    echo "updated $GOLDEN"; cat "$GOLDEN"; exit 0
fi
if diff -u "$GOLDEN" "$WORKDIR/golden_cycles.txt"; then
    echo "cycle_golden: PASS (T80 data-cycle waveforms match $GOLDEN)"
else
    echo "cycle_golden: FAIL (T80 timing changed? review, then --update)"; exit 1
fi
