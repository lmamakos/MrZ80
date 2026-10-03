#!/bin/bash
# run_ixmin.sh - minimal per-instruction PUSHIX/POPIX test (sim/tb_ixmin.vhd).
# Exits non-zero on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_ixmin_build}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 --workdir="$WORKDIR")

for f in Components/Z80/T80_Pack.vhd Components/Z80/T80_ALU.vhd \
         Components/Z80/T80_Reg.vhd Components/Z80/T80_MCode.vhd \
         Components/Z80/T80.vhd Components/Z80/T80s.vhd sim/tb_ixmin.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_ixmin
ghdl -r "${GHDL_FLAGS[@]}" tb_ixmin --assert-level=failure --ieee-asserts=disable \
    --stop-time=10ms
