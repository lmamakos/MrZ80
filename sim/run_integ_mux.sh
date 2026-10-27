#!/bin/bash
# run_integ_mux.sh - R-42: z80_bus_mux with the real T80s and an engine model
# (sim/tb_integ_mux.vhd); the engine waveform is checked against
# sim/ssp/golden_cycles.txt.  Exits non-zero on any failure.
#   MUX=<file>   use another z80_bus_mux source (mutation testing)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_integ_mux_build}"
MUX="${MUX:-ssp/rtl/z80_bus_mux.vhd}"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

for f in Components/Z80/T80_Pack.vhd Components/Z80/T80_ALU.vhd \
         Components/Z80/T80_Reg.vhd Components/Z80/T80_MCode.vhd \
         Components/Z80/T80.vhd Components/Z80/T80s.vhd \
         "$MUX" sim/tb_integ_mux.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_integ_mux
ghdl -r "${GHDL_FLAGS[@]}" tb_integ_mux --assert-level=failure --ieee-asserts=disable \
    --stop-time=500ms
