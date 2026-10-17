#!/bin/bash
# run_frontpanel.sh - compile and run tb_frontpanel (FrontPanel_Subsystem
# profile feature) with GHDL. Standalone: needs no T80/MMU/etc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

WORKDIR="${1:-/tmp/sim_frontpanel_build}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

for f in Components/FRONTPANEL/FP_RAM_Store.vhd \
         Components/FRONTPANEL/Transparent_Capture_Chain.vhd \
         Components/FRONTPANEL/FrontPanel_Subsystem.vhd \
         sim/tb_frontpanel.vhd; do
    echo "-- analyzing $f"
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done

echo "-- elaborating tb_frontpanel"
ghdl -e "${GHDL_FLAGS[@]}" tb_frontpanel

echo "-- running tb_frontpanel"
ghdl -r "${GHDL_FLAGS[@]}" tb_frontpanel --stop-time=2000ms
