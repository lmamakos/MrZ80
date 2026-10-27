#!/usr/bin/env bash
# sim/ssp/p1a_smoke.sh -- P1a monitor smoke on the p1a lane (real ssp_top +
# Z80 BFM), booting the dictionary artifact built by p1a_dictbuild.sh
# (kernel + monitor.fs, `init` runs the monitor).
#
# Part A (+OM=1): the operator session --
#   escape -> banner; ? ; E (hex+ASCII); D (replace one byte, bare CR leaves
#   the next unchanged, `.` ends); E again (both visible); argument errors;
#   D pokes `JP $5000` into guest memory; G 5000 (guest restarts there through
#   the reset vent + injector and RUNS the poked code); second escape -> R
#   shows PC=5000; plain G (continue, no injection); third escape; G 0300.
#   Interleaving-proof console: rebuilt from the pin deserialiser's own trace
#   ("[tb-tx @n] byte hh", +DBG), as p1a_tramp.sh does.
# Part B (+OM=0): R-43 transparency -- every byte incl. ESC_CHAR reaches the
#   guest ACIA, no park.  Part C (+OM=1): the escape byte is consumed, only the
#   bytes before it reach the guest.
#
# BFM image: $0000 JP $0100 (boot), pattern addr[7:0]^addr[15:8] elsewhere,
# self-loops at $0100/$0200/$0300/$4000.  Input byte $1d = escape, $01 =
# harness pause (+PAUSE cycles) so a late-running command cannot overwrite
# the escape's hold/own hand-over (see p1a_tramp.sh).

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
MODEL=${MODEL:-sim/ssp/obj_p1a/ssp_p1a}
APP=ssp/fw/build/mecrisp-ssp-p1a-app.hex
WORK=/tmp/opencode/p1a-smoke; mkdir -p "$WORK"

[ -x "$MODEL" ] || { echo "FAIL: model missing -- run: make -C sim p1a"; exit 1; }
if [ ! -f "$APP" ] || [ ssp/fw/apps/monitor.fs -nt "$APP" ] || [ ssp/fw/terminal.s -nt "$APP" ]; then
  echo "(building the monitor dictionary: sim/ssp/p1a_dictbuild.sh)"
  sim/ssp/p1a_dictbuild.sh > "$WORK/dictbuild.log" 2>&1 \
    || { echo "FAIL: dictionary build"; tail -15 "$WORK/dictbuild.log"; exit 1; }
fi

fail=0
runmodel() { # $1 = tag, rest = plusargs; stdin = operator input
  local tag=$1; shift
  # caller plusargs first: the harness takes the FIRST occurrence of a key
  timeout 900 "$MODEL" "$@" +ROM="$APP" +MAXCYCLES=400000000 +IDLE=3000000 +ECHO=0 \
      +PAUSE=600000 +DBG > "$WORK/$tag.console.log" 2> "$WORK/$tag.info.log"
  local rc=$?
  # exit 3 = "nothing ever transmitted": expected with OM off (the monitor is
  # silent on the pin until an escape), so only tolerated when asked
  { [ $rc -eq 0 ] || { [ $rc -eq 3 ] && [ "${ALLOW_SILENT:-0}" = 1 ]; }; } \
    || { echo "FAIL: harness exit $rc ($tag)"; tail -2 "$WORK/$tag.info.log"; exit 1; }
  grep -aoE '\[(p1a|tb-tx)[^]]*\].*' "$WORK/$tag.console.log" > "$WORK/$tag.events.log"
  grep -aE '^\[tb-tx @[0-9]+\] byte' "$WORK/$tag.events.log" \
    | sed -E 's/.*byte ([0-9a-f]+) .*/\1/' \
    | python3 -c "
import sys
out = ''.join(chr(int(l, 16)) for l in sys.stdin.read().split())
print(out.replace('\r', '\n'))" > "$WORK/$tag.norm.log"
}
check() { # $1 = description, $2 = grep -E pattern on the console of $TAG
  if grep -aEq "$2" "$WORK/$TAG.norm.log"; then echo "  ok: $1"; else
    echo "  MISSING: $1 (/$2/)"; fail=1; fi; }
ev() {    # $1 = description, $2 = grep -E pattern on the event log of $TAG
  if grep -aEq "$2" "$WORK/$TAG.events.log"; then echo "  ok: $1"; else
    echo "  MISSING: $1 (/$2/)"; fail=1; fi; }
absent() { # $1 = description, $2 = pattern that must NOT appear on the console
  if grep -aEq "$2" "$WORK/$TAG.norm.log"; then echo "  FAIL: $1 (/$2/)"; fail=1; else
    echo "  ok: $1"; fi; }

# ---- expected hex rows, computed (initial image + the session's own edits) ------
row() { python3 - "$@" <<'PYEOF'
import sys
addr, n = int(sys.argv[1], 16), int(sys.argv[2], 16)
over = {}
for kv in sys.argv[3:]:
    a, v = kv.split("=")
    over[int(a, 16)] = int(v, 16)
base = {}                                   # BFM initial image (z80_bfm.v)
for a in (0x0000, 0x0100, 0x0200, 0x0300, 0x4000):
    base[a], base[a + 1], base[a + 2] = 0xC3, a & 255, a >> 8
b = [over.get(a, base.get(a, (a & 255) ^ (a >> 8))) for a in range(addr, addr + n)]
asc = "".join(chr(x) if 32 <= x <= 126 else "." for x in b)
print("%04X: %s" % (addr, " ".join("%02X" % x for x in b)), end="")
print(" " * (3 * (16 - n)) + "  " + asc)
PYEOF
}
rx() { sed -E 's/[][*.+?^$(){}|\\]/\\&/g' <<<"$1"; }   # literal -> ERE

# ======================= Part A: operator session (OM=1) ========================
TAG=A
{
  printf '\x1d'                                     # escape: console -> monitor
  printf '?\r'
  printf 'E 100 10\r'                               # examine, 16 bytes
  printf 'D 1000\rAA\r\r55\r.\r'                    # D: set, skip, set, end
  printf 'E 1000 4\r'
  printf 'D 1010\r1FF\rzz\r77\r.\r'                 # bad values stay put; 77 sets
  printf 'E 1010 2\r'
  printf 'E zz\rG zz\rE 100 10 99\r'                # argument errors
  printf 'E 1004\r'                                 # E, no length -> default $80
  printf 'E\r'                                      # E, no args -> continue at 1084
  printf 'D 5000\rC3\r00\r50\r.\r'                  # poke JP $5000
  printf 'E 5000 3\r'
  printf 'G 5000\r'                             # guest restarts at 5000
  printf '\x1d'; printf 'R\r'                       # escape back; registers
  printf 'G\r'                                  # plain continue
  printf '\x1d'; printf 'R\r'
  printf 'G 300\r'
  printf '\x1d'; printf 'R\rF\r'                    # leave to Forth
  printf '$2000000C @ hex. cr\r'                    # STATUS (RV_ALIVE = bit 20)
} | runmodel A +OM=1 +LINEWAIT=2 +QUIET=150000

echo "--- Part A console ---"; cat "$WORK/A.norm.log"
check "banner after the escape (not at boot)"        '^MRZ80 SSP MONITOR'
check "help lists G"                                 '^G \[AAAA\]'
check "E: 16 bytes + ASCII"                          "^$(rx "$(row 100 10)") *\$"
check "D prompts with the current contents"          '^1000: 10 AA *$'
check "D: bare CR leaves the next byte, advances"    '^1001: 11 *$'
check "D: next address after the skip"               '^1002: 12 55 *$'
check "D: . ends the session"                        '^1003: 13 \. *$'
check "E sees the replaced byte and the unchanged one" "^$(rx "$(row 1000 4 1000=AA 1002=55)")\$"
check "D: value > FF rejected, stays on the byte"    '^1010: 00 1FF *$'
check "D: garbage rejected"                          '^1010: 00 zz *$'
check "D: valid value after errors"                  '^1010: 00 77 *$'
check "E shows the 77 written after two rejections"  "^$(rx "$(row 1010 2 1010=77)")\$"
n_q=$(grep -ac '^?$' "$WORK/A.norm.log")
[ "$n_q" -eq 5 ] && echo "  ok: five '?' (1FF, zz, E zz, G zz, extra token)" \
  || { echo "  FAIL: expected 5 '?' replies, got $n_q"; fail=1; }
check "E default length: first row"                  "^$(rx "$(row 1004 10 1010=77)")\$"
check "E default length: last row (8 rows, \$80 bytes)" "^$(rx "$(row 1074 10)")\$"
check "bare E continues after the last examine"      "^$(rx "$(row 1084 10)")\$"
check "poked JP \$5000 reads back"                   "^5000: C3 00 50 "
ev    "G aaaa: reset vented"                         'z_reset_n -> 0'
ev    "G aaaa: injector armed with target 5000"      'tramp_arm -> 1 target=5000'
ev    "G aaaa: injector delivered the JP to 5000"    'tramp_done \(guest pc=5000\)'
ev    "G aaaa: guest ran the poked code (PC 5000 after release)" 'p1a-go .*z_reset_n -> 1'
check "R: guest PC is 5000 (ran the code the operator poked in)" '^PC=5000 '
n_pc5=$(grep -ac '^PC=5000 ' "$WORK/A.norm.log")
[ "$n_pc5" -eq 2 ] && echo "  ok: plain G left PC alone (PC=5000 on the second R too)" \
  || { echo "  FAIL: expected two PC=5000 R lines (G aaaa, then plain G), got $n_pc5"; fail=1; }
check "G 300: R after the restart shows PC=0300"     '^PC=0300 '
check "F leaves to Forth"                            '^FORTH'
check "STATUS.RV_ALIVE (bit 20) set: the core is seen reading" '^[$]2000000[cC] @ hex\. cr 00[13579bdfBDF][0-9a-fA-F]{5} *$'
ev    "G aaaa writes CTRL = 133 (arm + vent while parked)"   'p1a-ctrl .*CTRL <= 133 '
ev    "G aaaa writes CTRL = 030 (release, hold dropped, console back)" 'p1a-ctrl .*CTRL <= 030 '
ev    "plain G writes CTRL = 020 (no TRAMP_EN left set)"      'p1a-ctrl .*CTRL <= 020 '
n_done=$(grep -ac 'tramp_done' "$WORK/A.events.log")
[ "$n_done" -eq 2 ] && echo "  ok: exactly two injections (G 5000, G 300; plain G has none)" \
  || { echo "  FAIL: expected 2 tramp_done, got $n_done"; fail=1; }
n_esc=$(grep -ac 'ESC matched' "$WORK/A.events.log")
[ "$n_esc" -eq 4 ] && echo "  ok: four escapes matched" || { echo "  FAIL: expected 4 escapes, got $n_esc"; fail=1; }
n_ban=$(grep -ac '^MRZ80 SSP MONITOR' "$WORK/A.norm.log")
[ "$n_ban" -eq 4 ] && echo "  ok: banner on every escape (4)" || { echo "  FAIL: expected 4 banners, got $n_ban"; fail=1; }
# monitor lines carry both CR and LF (kernel built with `crlf`: the writeln macro
# emits LF then CR); a terminal that does not translate a bare LF must still work
read -r n_crlf n_lf < <(python3 -c "
import re, sys
b = bytes(int(m.group(1), 16) for m in re.finditer(r'^\[tb-tx @[0-9]+\] byte ([0-9a-f]+) ', open('$WORK/A.events.log').read(), re.M))
print(len(re.findall(rb'MRZ80 SSP MONITOR  \? = HELP(?:\r\n|\n\r)', b)), len(re.findall(rb'MRZ80 SSP MONITOR  \? = HELP(?!\r\n|\n\r)', b)))")
[ "$n_crlf" -eq 4 ] && [ "$n_lf" -eq 0 ] && echo "  ok: monitor lines carry CR and LF" || { echo "  FAIL: banner CR LF count $n_crlf (want 4), bare-LF $n_lf (want 0)"; fail=1; }
absent "no unknown words"                            'not found'
if grep -aq 'p1a-ERR' "$WORK/A.events.log"; then
  echo "  FAIL: BUSRQ released during an engine cycle"; fail=1
else echo "  ok: BUSRQ held through every engine cycle"; fi
grep -E 'bus_errs=[1-9]|rom_illegal=[1-9]' "$WORK/A.info.log" \
  && { echo "  FAIL: harness diagnostics flagged"; fail=1; }

# ======================= Part B: OM off -> bit-transparent (R-43) ==================
TAG=B
printf 'ab\x1dcd\r' | ALLOW_SILENT=1 runmodel B +OM=0 +RXAT=200000
gi=$(grep -aoE 'guest_rx=[0-9]+' "$WORK/B.info.log" | tail -1)
fa=$(grep -aoE 'freeze_acc=[0-9]+' "$WORK/B.info.log" | tail -1)
echo "--- Part B: $gi $fa"
[ "$gi" = "guest_rx=6" ] && echo "  ok: all 6 bytes (incl. ESC_CHAR) reached the guest with OM off (R-43)" \
  || { echo "  FAIL: expected guest_rx=6, got '$gi'"; fail=1; }
[ "$fa" = "freeze_acc=0" ] && echo "  ok: no park with OM off" || { echo "  FAIL: guest was parked with OM off ($fa)"; fail=1; }
if grep -aq 'ESC matched' "$WORK/B.events.log"; then echo "  FAIL: escape matched with OM off"; fail=1; else echo "  ok: escape not matched with OM off"; fi

# ======================= Part C: OM on -> escape byte consumed ====================
TAG=C
printf 'ab\x1d' | runmodel C +OM=1 +RXAT=200000
gi=$(grep -aoE 'guest_rx=[0-9]+' "$WORK/C.info.log" | tail -1)
echo "--- Part C: $gi"
[ "$gi" = "guest_rx=2" ] && echo "  ok: only the 2 bytes before the escape reached the guest; ESC_CHAR consumed" \
  || { echo "  FAIL: expected guest_rx=2, got '$gi'"; fail=1; }
check "monitor banner after the escape"              '^MRZ80 SSP MONITOR'

# ======================= Part D: an idle operator must not lose the park ===========
# WDG_PARK (~0.4 s, D-13) flags (spec: demotes) a park the FW stops refreshing.  The kernel's
# key-wait loop kicks it (terminal.s serial_key, R30), so a human sitting at the
# prompt for far longer than that (here 0.8 s) still finds the guest parked.
TAG=D
printf '\x1d\x01R\r' | runmodel D +OM=1 +PAUSE=40000000 +MAXCYCLES=600000000
echo "--- Part D console ---"; cat "$WORK/D.norm.log"
check "idle for 0.8 s at the prompt: still parked, R works" '^PC=0100 '
absent "no NOT PARKED after the idle period"         'NOT PARKED'
if grep -aq 'WDG_PARK expired' "$WORK/D.events.log"; then
  echo "  FAIL: WDG_PARK expired while the FW sat at the prompt (kernel key-wait must kick it)"; fail=1
else echo "  ok: WDG_PARK never expired while idle at the prompt"; fi

[ $fail -eq 0 ] && echo "p1a_smoke: PASS" || echo "p1a_smoke: FAIL"
exit $fail
