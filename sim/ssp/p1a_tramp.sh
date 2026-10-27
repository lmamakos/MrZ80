#!/usr/bin/env bash
# sim/ssp/p1a_tramp.sh -- "G aaaa" hardware contract, firmware side (R27).
# Drives the register-level sequence from the Mecrisp REPL on the p1a lane
# (real ssp_top + Z80 BFM) and checks the guest's PC after each case.  The
# injector itself is verified against the REAL T80 in sim/tb_tramp.vhd
# (sim/run_tramp.sh); this script proves the bridge <-> FW <-> reset-vent /
# injection handshake: TRAMP_ADDR lane data, CTRL arm/vent/release, hardware
# auto-clear of CTRL.TRAMP_EN, and PC_LATCH at the next park.
#
# CTRL ($2000_0004) bits: 0 Z_RST_N(assert reset) 1 Z_BUSRQ_N(hold) 4 TRAMP_EN
#   5 ESC_BREAK_EN 8 CONSOLE_OWN.  Escape leaves CTRL = $122 (esc_break|hold|own).
#   Always write full values and keep bit 5, or the escape is disabled.
# BFM image: $0000 = JP $0100 (boot vector); self-loops at $0100/$0200/$0300.
#
# Input: byte $1d = escape, $0d = CR, $01 = harness pause (+PAUSE cycles;
# Mecrisp spends ~170k cycles per line, so wait before each escape).

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
MODEL=${MODEL:-sim/ssp/obj_p1a/ssp_p1a}
HEX=ssp/fw/build/mecrisp-ssp.hex
WORK=/tmp/opencode/p1a-tramp; mkdir -p "$WORK"

[ -x "$MODEL" ] || { echo "FAIL: model missing -- run: make -C sim p1a"; exit 1; }
[ -f "$HEX" ]  || { echo "FAIL: FW hex missing -- run: make -C ssp/fw ssp"; exit 1; }

PC='$20000014 @ hex. cr\r'
CTRL='$20000004 @ hex. cr\r'
{
  printf '\x1d'
  # A: G $0200 -- arm + vent (hold kept), then release reset, drop hold, console to guest
  printf '$200 $20000008 !\r$133 $20000004 !\r$30 $20000004 !\r\x01'
  printf '\x1d'; printf "$PC"; printf "$CTRL"
  # B: plain Reset CPU (no arm) -> real boot vector -> JP $0100 loop
  printf '$123 $20000004 !\r$20 $20000004 !\r\x01'
  printf '\x1d'; printf "$PC"
  # C: park-at-target -- release reset but keep hold: JP $0300 injected, guest parks at $0300
  printf '$300 $20000008 !\r$133 $20000004 !\r$132 $20000004 !\r'
  printf "$PC"; printf "$CTRL"
} | timeout 900 "$MODEL" +ROM="$HEX" +OM=1 +MAXCYCLES=400000000 +IDLE=3000000 \
      +ECHO=0 +RXGAP=30000 +PAUSE=600000 +DBG \
    > "$WORK/console.log" 2> "$WORK/info.log"
rc=$?

[ $rc -eq 0 ] || { echo "FAIL: harness exit $rc"; tail -2 "$WORK/info.log"; exit 1; }

# $display lines share stdout with raw console bytes (a stray byte can even
# precede an event on the same line).  Extract the events from the first '['
# of each tag, and rebuild the console from the pin deserialiser's own trace
# ("[tb-tx @n] byte hh"), which is immune to the interleaving.
grep -aoE '\[(p1a|tb-tx)[^]]*\].*' "$WORK/console.log" > "$WORK/events.log"
grep -aE '^\[tb-tx @[0-9]+\] byte' "$WORK/events.log" \
  | sed -E 's/.*byte ([0-9a-f]+) .*/\1/' \
  | python3 -c "
import sys
out = ''.join(chr(int(l, 16)) for l in sys.stdin.read().split())
print(out.replace('\r', '\n'))" | tr 'A-Z' 'a-z' > "$WORK/norm.log"

echo "--- console ---"; cat "$WORK/norm.log"
fail=0
check() { # $1 = description, $2 = grep -E pattern on the normalised console
  if grep -Eq "$2" "$WORK/norm.log"; then echo "  ok: $1"; else
    echo "  MISSING: $1 (/$2/)"; fail=1; fi; }
ev() {    # $1 = description, $2 = grep -E pattern on the event log
  if grep -aEq "$2" "$WORK/events.log"; then echo "  ok: $1"; else
    echo "  MISSING: $1 (/$2/)"; fail=1; fi; }

ev    "TRAMP_ADDR lane data: arm raised with target 0200" 'tramp_arm -> 1 target=0200'
ev    "TRAMP_ADDR lane data: arm raised with target 0300" 'tramp_arm -> 1 target=0300'
ev    "guest reset vented (z_reset_n low)"                'z_reset_n -> 0'
ev    "injector delivered the JP to 0200"                 'tramp_done \(guest pc=0200\)'
ev    "injector delivered the JP to 0300"                 'tramp_done \(guest pc=0300\)'
# auto-clear must follow tramp_done within a few clocks (a later FW write that
# happens to clear bit 4 must not satisfy this)
if python3 - "$WORK/events.log" <<'PY'
import re, sys
done, clr = [], []
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"p1a-go\s+@(\d+)\] (tramp_done|tramp_arm -> 0)", l)
    if m:
        (done if m.group(2) == "tramp_done" else clr).append(int(m.group(1)))
ok = len(done) > 0 and all(any(0 <= c - d <= 3 for c in clr) for d in done)
sys.exit(0 if ok else 1)
PY
then echo "  ok: hardware auto-clear of TRAMP_EN within 3 clk of tramp_done"
else echo "  MISSING: hardware auto-clear of TRAMP_EN right after tramp_done"; fail=1; fi
check "A: G 0200 -> guest PC at the next park is 0200"    '[$]20000014 @ hex\. cr 0*200 *$'
check "A: CTRL after done: TRAMP_EN cleared by hardware (122)" '^[$]20000004 @ hex\. cr 0*122 *$'
check "B: plain reset (no arm) -> real boot vector, PC 0100" '[$]20000014 @ hex\. cr 0*100 *$'
check "C: park-at-target -> parked at 0300 (hold kept)"   '[$]20000014 @ hex\. cr 0*300 *$'
n_done=$(grep -ac 'tramp_done' "$WORK/events.log")
[ "$n_done" -eq 2 ] && echo "  ok: exactly two injections (A and C; B had no arm)" \
  || { echo "  FAIL: expected 2 tramp_done pulses, got $n_done"; fail=1; }
grep -qi 'not found' "$WORK/norm.log" && { echo "  FAIL: unknown word in console"; fail=1; }
grep -E 'bus_errs=[1-9]|rom_illegal=[1-9]' "$WORK/info.log" \
  && { echo "  FAIL: harness diagnostics flagged"; fail=1; }

[ $fail -eq 0 ] && echo "p1a_tramp: PASS" || echo "p1a_tramp: FAIL"
exit $fail
