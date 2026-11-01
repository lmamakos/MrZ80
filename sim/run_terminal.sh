#!/bin/bash
# run_terminal.sh - R44: the video terminal (SBCTextDisplayRGB) and the SSP's
# own instance (ssp_vdu), plus the serial ACIA's master reset (bufferedUART),
# under GHDL, sim/tb_terminal.vhd.  The terminal source
# is compiled from a temporary copy whose STD_LOGIC_UNSIGNED use line is
# replaced by VHDL-2008 ieee.numeric_std_unsigned: the same unsigned
# semantics, including comparisons of vectors of different lengths (the
# terminal compares 7-bit key codes with 8-bit literals; the built-in array
# comparison GHDL would otherwise use is lexicographic).  sim/sim_compat_pkg.vhd
# does not cover those.  RAM/ROM come from sim/behav_terminal_ram.vhd.
# Exits non-zero on any failure.
#   TERM_VHD=<file>  use another terminal source (mutation testing)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_terminal_build}"
TERM_SRC="${TERM_VHD:-Components/TERMINAL/SBCTextDisplayRGB.vhd}"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

grep -q '^\s*use ieee.std_logic_unsigned.all;' "$TERM_SRC" \
    || { echo "run_terminal: $TERM_SRC has no STD_LOGIC_UNSIGNED line to redirect"; exit 1; }
sed 's/^\(\s*\)use ieee.std_logic_unsigned.all;/\1use ieee.numeric_std_unsigned.all;/' \
    "$TERM_SRC" > "$WORKDIR/SBCTextDisplayRGB_sim.vhd"

for f in sim/behav_terminal_ram.vhd sim/sim_compat_pkg.vhd sim/bufferedUART_sim.vhd \
         "$WORKDIR/SBCTextDisplayRGB_sim.vhd" ssp/rtl/ssp_vdu.vhd \
         sim/tb_terminal.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_terminal
ghdl -r "${GHDL_FLAGS[@]}" tb_terminal --assert-level=failure --ieee-asserts=disable \
    --stop-time=100ms
