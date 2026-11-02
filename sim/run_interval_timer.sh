#!/bin/bash
# run_interval_timer.sh - unit bench for Components/TIMER/IntervalTimer.vhd
# (sim/tb_interval_timer.vhd, GHDL). Exits non-zero on any failure.
# Usage: sim/run_interval_timer.sh [workdir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_interval_timer_build}"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

for f in Components/TIMER/IntervalTimer.vhd sim/tb_interval_timer.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_interval_timer
ghdl -r "${GHDL_FLAGS[@]}" tb_interval_timer --assert-level=error 2>&1 \
    | tee "$WORKDIR/run.log" | grep -E 'FAIL|PASS|checks' || true
grep -q 'PASS: tb_interval_timer' "$WORKDIR/run.log"
