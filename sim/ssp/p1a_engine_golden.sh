#!/usr/bin/env bash
# sim/ssp/p1a_engine_golden.sh -- R-42 golden compare, bridge side.
#
# The SSP engine (ssp_bridge.v, D-26) must drive the guest bus with the same
# MRD_T1 / strobe / wait waveforms as the real T80 in the production
# configuration.  sim/ssp/golden_cycles.txt holds the T80's data-cycle
# waveforms (captured by sim/tb_cycle_golden.vhd, GHDL, one vector per T-state:
# MREQ IORQ RD WR M1 MRD_T1).  This script replays the four cycle types
# through the REAL bridge engine on the p1a lane -- memory read, memory write,
# I/O read, I/O write, each kicked from the Mecrisp REPL through MEM_CTL --
# once without and once with one wait state in T2 (+WAIT), logs the engine's
# waveform (+ENGLOG, sim/ssp/p1a_sim_top.v) and compares line for line.
#
# MEM_CTL ($2000_0074): START=1 RNW=2 IS_IO=4.  MEM_ADDR $..78, MEM_DATA $..7C.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
MODEL=${MODEL:-sim/ssp/obj_p1a/ssp_p1a}
HEX=ssp/fw/build/mecrisp-ssp.hex
GOLDEN=sim/ssp/golden_cycles.txt
WORK=/tmp/opencode/p1a-engine-golden; mkdir -p "$WORK"

[ -x "$MODEL" ] || { echo "FAIL: model missing -- run: make -C sim p1a"; exit 1; }
[ -f "$HEX" ]  || { echo "FAIL: FW hex missing -- run: make -C ssp/fw ssp"; exit 1; }
[ -f "$GOLDEN" ] || { echo "FAIL: $GOLDEN missing -- run: sim/run_cycle_golden.sh --update"; exit 1; }

MADDR='$20000078'; MDATA='$2000007C'; MCTL='$20000074'
ops() {
  printf '\x1d'                                             # escape: park + console
  printf '$8000 %s !\r3 %s !\r' "$MADDR" "$MCTL"            # memory read  @8000
  printf '$55 %s !\r$8001 %s !\r1 %s !\r' "$MDATA" "$MADDR" "$MCTL"   # memory write @8001
  printf '$55 %s !\r7 %s !\r' "$MADDR" "$MCTL"              # I/O read     port 55
  printf '$69 %s !\r$6966 %s !\r5 %s !\r' "$MDATA" "$MADDR" "$MCTL"   # I/O write    6966
}

fail=0
for variant in plain w1; do
  extra=""; suffix=""
  [ "$variant" = w1 ] && { extra="+WAIT"; suffix="_w1"; }
  ops | timeout 300 "$MODEL" +ROM="$HEX" +OM=1 +ENGLOG $extra +ECHO=0 \
        +MAXCYCLES=100000000 +IDLE=2000000 +LINEWAIT=1 \
        > "$WORK/$variant.console.log" 2> "$WORK/$variant.info.log"
  rc=$?
  [ $rc -eq 0 ] || { echo "FAIL: harness exit $rc ($variant)"; tail -2 "$WORK/$variant.info.log"; exit 1; }
  grep -ao '\[p1a-eng\].*' "$WORK/$variant.console.log" | sed 's/^\[p1a-eng\] *//' > "$WORK/$variant.eng"
  n=$(wc -l < "$WORK/$variant.eng")
  [ "$n" -eq 4 ] || { echo "FAIL ($variant): expected 4 engine cycles, saw $n"; cat "$WORK/$variant.eng"; fail=1; continue; }
  i=0
  for kind in memrd memwr iord iowr; do
    i=$((i + 1))
    want=$(grep -E "^${kind}${suffix} " "$GOLDEN" | sed -E "s/^${kind}${suffix} +//")
    got=$(sed -n "${i}p" "$WORK/$variant.eng")
    if [ "$want" = "$got" ]; then
      echo "  ok: ${kind}${suffix}: $got"
    else
      echo "  MISMATCH ${kind}${suffix}:"
      echo "     T80 golden : $want"
      echo "     SSP engine : $got"
      fail=1
    fi
  done
done

[ $fail -eq 0 ] && echo "p1a_engine_golden: PASS" || echo "p1a_engine_golden: FAIL"
exit $fail
