#!/bin/bash
# run_integ_park.sh - R-40: every SSP park lands on an instruction boundary,
# on the real T80s (sim/tb_integ_park.vhd + sim/tb_integ_park.asm).
# Exits non-zero on any failure.
#   T80_DIR=<dir>   use T80 sources from <dir> instead of Components/Z80
#                   (mutation testing: a copy with a broken freeze gate)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_integ_park_build}"
T80_DIR="${T80_DIR:-Components/Z80}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

tools/z80asm.sh -o "$WORKDIR/integ_park" sim/tb_integ_park.asm > "$WORKDIR/asm.log" 2>&1 \
    || { cat "$WORKDIR/asm.log"; exit 1; }
sym() { local h; h=$(awk -v n="$1" '$2 == n { print $1 }' "$WORKDIR/integ_park.sym"); [ -n "$h" ] && echo $((16#$h)); }
TRG_EI=$(sym TRGEI); TRG_BLK=$(sym TRGBLK); TRG_DDC=$(sym TRGDDC); END_PC=$(sym ENDHLT); INIT_PC=$(sym INITOK)
for v in "$TRG_EI" "$TRG_BLK" "$TRG_DDC" "$END_PC" "$INIT_PC"; do
    [ -n "$v" ] || { echo "FAIL: label missing from the symbol file"; exit 1; }
done

for f in "$T80_DIR/T80_Pack.vhd" "$T80_DIR/T80_ALU.vhd" "$T80_DIR/T80_Reg.vhd" \
         "$T80_DIR/T80_MCode.vhd" "$T80_DIR/T80.vhd" "$T80_DIR/T80s.vhd" \
         sim/tb_integ_park.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_integ_park
ghdl -r "${GHDL_FLAGS[@]}" tb_integ_park --assert-level=failure --ieee-asserts=disable \
    -gBIN="$WORKDIR/integ_park.bin" -gTRG_EI="$TRG_EI" -gTRG_BLK="$TRG_BLK" \
    -gTRG_DDC="$TRG_DDC" -gEND_PC="$END_PC" -gINIT_PC="$INIT_PC" --stop-time=2000ms
