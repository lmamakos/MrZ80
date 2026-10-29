#!/bin/bash
# run_mem_client.sh - M3 (R40): ssp_mem_client unit bench (sim/tb_mem_client.vhd).
# Exits non-zero on any failure.
#   CLIENT=<file>   use another ssp_mem_client source (mutation testing)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_mem_client_build}"
CLIENT="${CLIENT:-ssp/rtl/ssp_mem_client.vhd}"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

for f in "$CLIENT" sim/tb_mem_client.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_mem_client
ghdl -r "${GHDL_FLAGS[@]}" tb_mem_client --assert-level=failure --ieee-asserts=disable \
    --stop-time=500ms
