#!/bin/bash
# run_blockdev.sh - compile and run tb_hps_blockdev (Components/SDCARD/hps_blockdev.vhd)
# with GHDL. Standalone: needs no T80/MMU/etc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

WORKDIR="${1:-/tmp/sim_blockdev_build}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

GHDL_FLAGS=(--std=08 -fsynopsys --workdir="$WORKDIR")

for f in Components/SDCARD/hps_blockdev.vhd sim/tb_hps_blockdev.vhd; do
    echo "-- analyzing $f"
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done

echo "-- elaborating tb_hps_blockdev"
ghdl -e "${GHDL_FLAGS[@]}" tb_hps_blockdev

echo "-- running tb_hps_blockdev"
ghdl -r "${GHDL_FLAGS[@]}" tb_hps_blockdev --stop-time=200ms
