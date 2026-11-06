#!/bin/bash
# run_dazzler.sh - smoke bench for Components/DAZZLER/dazzler.vhd
# (sim/tb_dazzler.vhd, GHDL): port registers, window snoop (in/out/wrap/
# disabled), normal-res cell map + RGBI decode, 2K quadrant placement and
# IN $0E status bits.  Exits non-zero on any failure.
# Usage: sim/run_dazzler.sh [workdir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_dazzler_build}"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

for f in Components/DAZZLER/dazzler.vhd sim/tb_dazzler.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_dazzler
ghdl -r "${GHDL_FLAGS[@]}" tb_dazzler --assert-level=error --stop-time=150ms 2>&1 \
    | tee "$WORKDIR/run.log" | grep -E 'FAIL|PASS|error' || true
grep -q 'PASS: tb_dazzler' "$WORKDIR/run.log"
