#!/bin/bash
# run_forth.sh - boot CamelFORTH kernels on a bare T80s core under GHDL and
# compare their console transcripts and per-line clock counts.
#
# Builds three BOOTABLE variants of forth/camel80.azm into a scratch dir:
#   stock   - no custom instructions (runs on any Z-80)
#   next    - -D CUSTNEXT            (custom NEXT, ED 92)
#   nextrsp - -D CUSTNEXT -D CUSTRSP (custom NEXT + PUSHIX/POPIX)
# runs each through sim/tb_forth.vhd, and diffs the transcripts after the
# boot banner (which legitimately differs between variants).
#
# Usage: sim/run_forth.sh [workdir]     (run from anywhere)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

WORKDIR="${1:-/tmp/sim_forth_build}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/k"

# --- assemble the kernel variants (sources copied so INCLUDEs resolve) ---
cp forth/*.azm "$WORKDIR/k/"
build() {   # name, defines...
    local name=$1; shift
    ( cd "$WORKDIR/k" &&
      "$PROJECT_ROOT/tools/um80.sh" camel80.azm -D BOOTABLE=1 "$@" -g \
          -o "$name.rel" -l "$name.prn" >/dev/null &&
      "$PROJECT_ROOT/tools/ul80.sh" -p 0 -x -o "$name.hex" "$name.rel" >/dev/null &&
      objcopy -I ihex -O binary "$name.hex" "$name.bin" )
}
build stock
build next    -D CUSTNEXT=1
build nextrsp -D CUSTNEXT=1 -D CUSTRSP=1

# --- compile the testbench ---
GHDL_FLAGS=(--std=08 --workdir="$WORKDIR")
for f in Components/Z80/T80_Pack.vhd Components/Z80/T80_ALU.vhd \
         Components/Z80/T80_Reg.vhd Components/Z80/T80_MCode.vhd \
         Components/Z80/T80.vhd Components/Z80/T80s.vhd sim/tb_forth.vhd; do
    ghdl -a "${GHDL_FLAGS[@]}" "$f"
done
ghdl -e "${GHDL_FLAGS[@]}" tb_forth

# --- run each variant ---
for v in stock next nextrsp; do
    echo "===== $v ($(stat -c%s "$WORKDIR/k/$v.bin") bytes) ====="
    ghdl -r "${GHDL_FLAGS[@]}" tb_forth --ieee-asserts=disable \
        -gBIN="$WORKDIR/k/$v.bin" -gLOG="$WORKDIR/$v.log" 2>&1 |
        sed -n 's/.*(report [a-z]*): //p' | tee "$WORKDIR/$v.out"
done

# --- compare transcripts, skipping the boot banner lines ---
status=0
for v in next nextrsp; do
    if diff <(grep -v "Hello world\|IX(RSP)" "$WORKDIR/stock.log") \
            <(grep -v "Hello world\|IX(RSP)" "$WORKDIR/$v.log") >/dev/null; then
        echo "transcript $v == stock: OK"
    else
        echo "transcript $v != stock: MISMATCH"
        diff <(grep -v "Hello world\|IX(RSP)" "$WORKDIR/stock.log") \
             <(grep -v "Hello world\|IX(RSP)" "$WORKDIR/$v.log") || true
        status=1
    fi
done

# --- per-line clock comparison table ---
echo
printf "%-6s %12s %12s %12s %9s %9s\n" line stock next nextrsp "next%" "nextrsp%"
paste <(grep -o '^line [0-9]*: [0-9]*' "$WORKDIR/stock.out") \
      <(grep -o '^line [0-9]*: [0-9]*' "$WORKDIR/next.out") \
      <(grep -o '^line [0-9]*: [0-9]*' "$WORKDIR/nextrsp.out") |
    awk '{ s=$3; n=$6; r=$9; sub(":","",$2);
           printf "%-6s %12d %12d %12d %8.1f%% %8.1f%%\n", $2, s, n, r,
                  100*(s-n)/s, 100*(s-r)/s }'
exit $status
