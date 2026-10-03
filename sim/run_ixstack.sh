#!/bin/bash
# run_ixstack.sh - compile and run the tb_ixstack testbench with GHDL.
#
# Self-checking test of the custom PUSHIX/POPIX instructions on a bare T80s
# core.  See sim/tb_ixstack.vhd and sim/tb_ixstack.asm.  Exits non-zero on
# any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

WORKDIR="${1:-/tmp/sim_ixstack_build}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

pasmo --bin sim/tb_ixstack.asm sim/tb_ixstack.bin

GHDL_FLAGS=(--std=08 --workdir="$WORKDIR")

FILES=(
    Components/Z80/T80_Pack.vhd
    Components/Z80/T80_ALU.vhd
    Components/Z80/T80_Reg.vhd
    Components/Z80/T80_MCode.vhd
    Components/Z80/T80.vhd
    Components/Z80/T80s.vhd
    sim/tb_ixstack.vhd
)

for f in "${FILES[@]}"; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_ixstack
RUN=(ghdl -r "${GHDL_FLAGS[@]}" tb_ixstack --assert-level=failure --ieee-asserts=disable-at-0)
echo "== no wait states =="
"${RUN[@]}"
for w in 2 3 5; do
    echo "== random wait states (WAITS=$w) =="
    "${RUN[@]}" -gWAITS=$w
done
