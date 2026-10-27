#!/bin/bash
# run_tramp.sh - ssp_tramp (guest reset vent + "G aaaa" reset-vector JP
# injector, D-02/D-39) against the real T80s: sim/tb_tramp.vhd.
# Exits non-zero on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_tramp_build}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 --workdir="$WORKDIR")

for f in Components/Z80/T80_Pack.vhd Components/Z80/T80_ALU.vhd \
         Components/Z80/T80_Reg.vhd Components/Z80/T80_MCode.vhd \
         Components/Z80/T80.vhd Components/Z80/T80s.vhd \
         ssp/rtl/ssp_tramp.vhd sim/tb_tramp.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_tramp
ghdl -r "${GHDL_FLAGS[@]}" tb_tramp --assert-level=failure --ieee-asserts=disable \
    --stop-time=20ms
