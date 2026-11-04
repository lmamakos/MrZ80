#!/bin/bash
# run_psg.sh - unit bench for Components/PSG/MrZ80_PSG.sv and the vendored
# YM2149_PSG_system (sim/tb_psg.sv, Verilator). Exits non-zero on failure.
# Compiles the same file set and macros as MrZ80.qsf (BHG_jt49_exp_q17.sv in
# place of the vendored BHG_jt49_exp.sv; USE_STEREO and USE_DUAL_PSG).
# Usage: sim/run_psg.sh [workdir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

WORKDIR="${1:-/tmp/sim_psg_build}"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
Y=Components/YM2149

verilator --binary --timing -O2 -Wno-fatal -Wno-lint -Wno-style \
    +define+USE_STEREO=1 +define+USE_DUAL_PSG=1 \
    --Mdir "$WORKDIR" -I"$Y" --top-module tb_psg -o tb_psg \
    sim/tb_psg.sv Components/PSG/MrZ80_PSG.sv Components/PSG/BHG_jt49_exp_q17.sv \
    "$Y/YM2149_PSG_system.sv" "$Y/BHG_FP_clk_divider.v" "$Y/BHG_jt49.v" \
    "$Y/BHG_audio_filter_mixer.sv" \
    "$Y/jt49_hdl/jt49_cen.v" "$Y/jt49_hdl/jt49_div.v" \
    "$Y/jt49_hdl/jt49_noise.v" "$Y/jt49_hdl/jt49_eg.v" \
    > "$WORKDIR/build.log" 2>&1 || { tail -30 "$WORKDIR/build.log"; exit 1; }

"$WORKDIR/tb_psg" 2>&1 | tee "$WORKDIR/run.log"
grep -q 'PASS: tb_psg' "$WORKDIR/run.log"
