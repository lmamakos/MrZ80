#!/bin/bash
# run_universal_chain.sh - unit bench for Components/FRONTPANEL/
# Universal_Capture_Chain.vhd (sim/tb_universal_chain.vhd, GHDL): the stretch
# mask must select the intended bits however the generic is declared.
# Exits non-zero on any failure.  Usage: sim/run_universal_chain.sh [workdir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_universal_chain_build}"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

for f in Components/FRONTPANEL/Universal_Capture_Chain.vhd sim/tb_universal_chain.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_universal_chain
ghdl -r "${GHDL_FLAGS[@]}" tb_universal_chain --assert-level=error 2>&1 \
    | tee "$WORKDIR/run.log" | grep -E 'FAIL|PASS|checks' || true
grep -q 'PASS: tb_universal_chain' "$WORKDIR/run.log"
