#!/usr/bin/env bash
# sim/ssp/p1a_smoke.sh -- P1a monitor smoke on the p1a lane (real ssp_top +
# Z80 BFM), booting the dictionary artifact built by dictbuild.sh
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
APP=ssp/fw/build/mecrisp-ssp-app.hex
WORK=/tmp/opencode/p1a-smoke; mkdir -p "$WORK"

[ -x "$MODEL" ] || { echo "FAIL: model missing -- run: make -C sim p1a"; exit 1; }
if [ ! -f "$APP" ] || [ ssp/fw/apps/monitor.fs -nt "$APP" ] || [ forth/disasm/z80dis.fth -nt "$APP" ] || [ ssp/fw/terminal.s -nt "$APP" ]; then
  echo "(building the monitor dictionary: sim/ssp/dictbuild.sh)"
  sim/ssp/dictbuild.sh > "$WORK/dictbuild.log" 2>&1 \
    || { echo "FAIL: dictionary build"; tail -15 "$WORK/dictbuild.log"; exit 1; }
fi

fail=0
# PARTS=F runs only Part F (default: all parts)
want() { [[ "${PARTS:-ABCDEFGH}" == *$1* ]]; }
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

if want A; then
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
check "banner after the escape (not at boot)"        '^MrZ80 SSP MONITOR'
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
n_ban=$(grep -ac '^MrZ80 SSP MONITOR' "$WORK/A.norm.log")
[ "$n_ban" -eq 4 ] && echo "  ok: banner on every escape (4)" || { echo "  FAIL: expected 4 banners, got $n_ban"; fail=1; }
# monitor lines carry both CR and LF (kernel built with `crlf`: the writeln macro
# emits LF then CR); a terminal that does not translate a bare LF must still work
read -r n_crlf n_lf < <(python3 -c "
import re, sys
b = bytes(int(m.group(1), 16) for m in re.finditer(r'^\[tb-tx @[0-9]+\] byte ([0-9a-f]+) ', open('$WORK/A.events.log').read(), re.M))
print(len(re.findall(rb'MrZ80 SSP MONITOR  \? = HELP(?:\r\n|\n\r)', b)), len(re.findall(rb'MrZ80 SSP MONITOR  \? = HELP(?!\r\n|\n\r)', b)))")
[ "$n_crlf" -eq 4 ] && [ "$n_lf" -eq 0 ] && echo "  ok: monitor lines carry CR and LF" || { echo "  FAIL: banner CR LF count $n_crlf (want 4), bare-LF $n_lf (want 0)"; fail=1; }
absent "no unknown words"                            'not found'
if grep -aq 'p1a-ERR' "$WORK/A.events.log"; then
  echo "  FAIL: BUSRQ released during an engine cycle"; fail=1
else echo "  ok: BUSRQ held through every engine cycle"; fi
grep -E 'bus_errs=[1-9]|rom_illegal=[1-9]' "$WORK/A.info.log" \
  && { echo "  FAIL: harness diagnostics flagged"; fail=1; }
fi

if want B; then
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
fi

if want C; then
# ======================= Part C: OM on -> escape byte consumed ====================
TAG=C
printf 'ab\x1d' | runmodel C +OM=1 +RXAT=200000
gi=$(grep -aoE 'guest_rx=[0-9]+' "$WORK/C.info.log" | tail -1)
echo "--- Part C: $gi"
[ "$gi" = "guest_rx=2" ] && echo "  ok: only the 2 bytes before the escape reached the guest; ESC_CHAR consumed" \
  || { echo "  FAIL: expected guest_rx=2, got '$gi'"; fail=1; }
check "monitor banner after the escape"              '^MrZ80 SSP MONITOR'
fi

if want D; then
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
fi

if want E; then
# ======================= Part E: I/O ports, MAP view, PHY/LOG mode (OM=1) ========
# M1 commands.  BFM oracles (z80_bfm.v): an I/O READ returns port^0x0F; the
# I/O WRITE capture holds the last (port,data).  MMU mapping ports read through
# the engine too, so the MAP pages are (B0+n)^0x0F low / (B4+n)^0x0F high ->
# pages 3BBF/3ABE/39BD/38BC, phys = page<<14.  PHY sets MD (D-22): E/D refuse
# physical E/D go to the M3 client (Part G); I/O + G are unaffected.
TAG=E
{
  printf '\x1d'
  printf '?\r'
  printf 'I 0080\r'
  printf 'O 00BB 5A\r'
  printf 'O BB G\r'                                 # bad data -> ?
  printf 'O FF\r'                                 # missing data -> ?
  printf 'MAP\r'
  printf 'PHY\r'
  printf 'E 100 4\r'                             # PHYSICAL read of 0000100 (M3 path)
  printf 'I 0081\r'                             # I/O works even in PHYSICAL (R37)
  printf 'O 00CC 3C\r'                          # ... reads and writes alike
  printf 'PPX\rLO\r'                            # near-miss verbs -> ? ?
  printf 'LOG\r'
  printf 'E 100 4\r'                            # logical E restored
  printf 'G\r'
} | runmodel E +OM=1 +LINEWAIT=2 +QUIET=150000
echo "--- Part E console ---"; cat "$WORK/E.norm.log"
check "help lists I/O/MAP/PHY"                   '^I AAAA       INPUT'
check "help lists MAP"                           '^MAP          MMU FRAMES'
check "I reads a port (BFM pattern addr^0x0F)"  '^I 0080 = 8F$'
check "O writes a port and echoes"               '^O 00BB = 5A$'
n_qE=$(grep -ac '^?$' "$WORK/E.norm.log")
[ "$n_qE" -eq 4 ] && echo "  ok: 4 '?' replies (O BB G, O FF, PPX, LO)" \
  || { echo "  FAIL: expected 4 '?' replies, got $n_qE"; fail=1; }
check "MAP F0 frame + physical base"             '^F0  page 3BBF  phys EEFC000$'
check "MAP F3 frame + physical base"             '^F3  page 38BC  phys E2F0000$'
check "PHY mode message"                         '^PHYSICAL \(SDRAM, 28-BIT\)$'
check "E in PHYSICAL mode reads through the physical client (mock pattern, 7-digit address)" '^0000100: A4 A5 A6 A7 '
check "port read works even in PHYSICAL mode"    '^I 0081 = 8E$'
check "port write works even in PHYSICAL mode"   '^O 00CC = 3C$'
check "LOG mode message"                         '^LOGICAL$'
check "logical E/D restored after LOG"          '^0100: C3 00 01 02'
io_wr_line=$(grep -aoE 'io_wr=[0-9]+\(cc,3c\)' "$WORK/E.info.log" | tail -1)
[ -n "$io_wr_line" ] && echo "  ok: BFM captured the physical-mode I/O write $io_wr_line" \
  || { echo "  FAIL: no io_wr(cc,3c) in the info line"; fail=1; }
if grep -aq 'p1a-ERR' "$WORK/E.events.log"; then
  echo "  FAIL: BUSRQ released during an engine cycle (Part E)"; fail=1
fi
fi


if want F; then
# ======================= Part F: single-step (S), R39 ==============================
# Hardware one-shot (spec 7.2c): release, observe the BusAck drop, re-assert, boundary
# re-grant.  The BFM models the T80 contract (request sampled on cpu_cen; a grant needs
# one more instruction after every release) and the harness events carry the oracles:
#   [p1a-step] kick / regrant fetches=N pc=P / int_hold -> b / timeout.
# Program: $5000: 4 x NOP, JP $5000 (a five-instruction loop; the escape lands anywhere
# in it, so the checks are on the RELATIVE PC progression).  HALT at $5010.
TAG=F
{
  printf '\x1d'
  printf 'D 5000\r00\r00\r00\r00\rC3\r00\r50\r.\r'
  printf 'D 5010\r76\r.\r'
  printf 'G 5000\r'
  printf '\x1d'
  printf 'S\r'                                      # one step
  printf 'S 4\r'                                    # a short trace
  printf 'S 7\r'                                    # wraps through the JP
  printf 'S 0\rS zz\rS 1 2\r'                       # argument errors -> ?
  printf 'R\r'
  printf 'S 3\r'
  printf '\r\r'                                     # bare CR repeats S 3 (twice)
  printf 'E 5000 1\r'                               # any other command forgets it
  printf '\r'                                       # ... so this does nothing
  printf 'G 5010\r'
  printf '\x1d'
  printf 'S 2\r'                                    # HALT: HALTED on every step
  printf 'R\r'
  printf 'F\r'
  printf '$120 SSP_CTRL !\r'                        # Z80 released, console still ours
  printf '$201 SSP_STEP_CTL !\r'                    # kick while running: rejected
  printf '$122 SSP_CTRL !\r'                        # parked again
  printf 'SSP_STEP_CTL @ hex.\r'                    # STEP_ERR set (bit 12) ...
  printf 'SSP_STEP_CTL @ hex.\r'                    # ... and read-clear
  printf '$401 SSP_STEP_CTL !\r'                    # reserved MODE (MCYCLE): rejected
  printf 'SSP_STEP_CTL @ hex.\r'
  printf '$200 SSP_STEP_CTL !\r'                    # N = 0: rejected
  printf 'SSP_STEP_CTL @ hex.\r'
  printf '$203 SSP_STEP_CTL !\r'                   # N = 3 in ONE kick (INT held across all 3)
  printf 'SSP_PC_LATCH @ hex.\r'
  printf '$20000010 @ hex.\r'                # re-park reason: 3 = step
} | runmodel F +OM=1 +LINEWAIT=2 +QUIET=150000
echo "--- Part F console ---"; cat "$WORK/F.norm.log"
# oracle 1: the console's step lines walk the loop one instruction at a time
python3 - "$WORK/F.norm.log" "$WORK/F.events.log" <<'PYEOF'
import re, sys
con = open(sys.argv[1], errors="replace").read()
ev = open(sys.argv[2], errors="replace").read()
head = con.split("G 5010")[0]
lines = re.findall(r"^([0-9A-F]{4}): ((?:[0-9A-F-]{2} ){4})AF=", head, re.M)
pcs = [int(l[0], 16) for l in lines]
loop = [0x5000, 0x5001, 0x5002, 0x5003, 0x5004]
bad = [(i, pcs[i - 1], pcs[i]) for i in range(1, len(pcs))
       if pcs[i] != loop[(loop.index(pcs[i - 1]) + 1) % 5]]
ok = len(pcs) == 21 and not bad and all(p in loop for p in pcs)
print("  %s: 21 step lines, each exactly one instruction on (%d lines, %d breaks)"
      % ("ok" if ok else "FAIL", len(pcs), len(bad)))
# oracle 2: harness events -- kick, int_hold up, regrant (>= 1 fetch), int_hold down
toks = []
for m in re.finditer(r"\[p1a-step @\d+\] (kick N=\d+ MODE=1|int_hold -> [01]|regrant fetches=(\d+) pc=([0-9a-f]{4})|timeout)", ev):
    t = m.group(1)
    toks.append(("kick" if t.startswith("kick") else
                 "regrant" if t.startswith("regrant") else
                 "ih1" if t.endswith("1") and t.startswith("int") else
                 "ih0" if t.startswith("int") else "timeout", m.group(2), m.group(3)))
seq = [t[0] for t in toks]
good = (seq == ["kick", "ih1", "regrant", "ih0"] * 23 +
        ["kick", "ih1", "regrant", "regrant", "regrant", "ih0"])
print("  %s: 23 single steps = kick, int_hold up, regrant, int_hold down; then one N=3 kick"
      " = int_hold up ONCE, 3 regrants, down once (%d kicks)"
      % ("ok" if good else "FAIL", seq.count("kick")))
fe = [int(t[1]) for t in toks if t[0] == "regrant"]
print("  %s: every regrant followed >= 1 fetch (no zero-instruction step)"
      % ("ok" if fe and min(fe) >= 1 else "FAIL"))
rp = [int(t[2], 16) for t in toks if t[0] == "regrant"][:21]
n3 = [t[0] for t in toks if t[0] == "kick"]
kn = re.findall(r"kick N=(\d+)", ev)
print("  %s: the last kick carried N=3" % ("ok" if kn and kn[-1] == "3" else "FAIL"))
if not (kn and kn[-1] == "3"): good = False
print("  %s: bridge-side parked PCs equal the displayed PCs"
      % ("ok" if rp == pcs else "FAIL"))
# oracle 3 (R41: was a hard-coded PC=5001, which depended on where the escape
# happened to land in the 5-instruction loop and moved with any FW timing change):
# the first R, issued right after S 7, shows the PC of the 12th (last) step line.
rpc = re.search(r"^PC=([0-9A-F]{4}) ", con, re.M)
okr = bool(rpc) and len(pcs) > 11 and int(rpc.group(1), 16) == pcs[11]
print("  %s: R after S 7 shows the PC of the last step line (R PC=%s, line %s)"
      % ("ok" if okr else "FAIL", rpc.group(1) if rpc else "?",
         "%04X" % pcs[11] if len(pcs) > 11 else "?"))
sys.exit(0 if (ok and good and fe and min(fe) >= 1 and rp == pcs and okr) else 1)
PYEOF
[ $? -eq 0 ] || fail=1
n_h=$(grep -ac '^HALTED' "$WORK/F.norm.log")
[ "$n_h" -eq 2 ] && echo "  ok: HALTED reported on both steps in HALT" || { echo "  FAIL: HALTED x$n_h (want 2)"; fail=1; }
check "S line ends with the next instruction (R42): NOP"      '^50[0-9A-F]{2}: 00 .*SP=FFFE +NOP *$'
check "S line ends with the next instruction (R42): JP nn"    '^5004: C3 00 50 57 .*SP=FFFE +JP 5000h *$'
check "HALT parks with PC = HALT + 1"                 '^PC=5011 '
n_qF=$(grep -ac '^?$' "$WORK/F.norm.log")
[ "$n_qF" -eq 3 ] && echo "  ok: S 0, S zz, S 1 2 each answered ?" || { echo "  FAIL: expected 3 '?', got $n_qF"; fail=1; }
n_e1=$(grep -aEc 'SSP_STEP_CTL @ hex\. 0*1201 +ok' "$WORK/F.norm.log")
[ "$n_e1" -eq 3 ] && echo "  ok: STEP_ERR (bit 12) set by a kick while running, MODE=MCYCLE and N=0" \
  || { echo "  FAIL: expected 3 STEP_ERR reads, got $n_e1"; fail=1; }
check "STEP_ERR is read-clear"                         'SSP_STEP_CTL @ hex\. 0*201 +ok'
check "HALT_REASON = 3 after a step re-park"           '[$]20000010 @ hex\. 0*3 +ok'
absent "no unknown words"                              'not found'
if grep -aq 'p1a-step.*timeout' "$WORK/F.events.log"; then
  echo "  FAIL: a step timed out in the normal session"; fail=1; else echo "  ok: no step timeout"; fi
if grep -aq 'p1a-ERR' "$WORK/F.events.log"; then echo "  FAIL: BUSRQ released during an engine cycle (Part F)"; fail=1; fi

# ---- F2: a keystroke ends a long trace (BREAK).  \x02 = harness eager key.
TAG=F2
{
  printf '\x1d'
  printf 'D 5000\r00\r00\r00\r00\rC3\r00\r50\r.\r'
  printf 'G 5000\r'
  printf '\x1d'
  printf 'S 40\r'
  printf '\x02x'                                   # a key in the middle of the trace
  printf 'R\r'
} | runmodel F2 +OM=1 +LINEWAIT=2 +QUIET=150000
echo "--- Part F2 console (tail) ---"; tail -12 "$WORK/F2.norm.log" | grep -v '^$'
check "BREAK ends the trace"                          '^BREAK'
nk=$(grep -ac 'p1a-step.*kick' "$WORK/F2.events.log")
[ "$nk" -ge 2 ] && [ "$nk" -lt 40 ] && echo "  ok: trace stopped early ($nk of 40 steps)" \
  || { echo "  FAIL: kicks=$nk (want 2..39)"; fail=1; }
check "monitor alive after BREAK: R works"            '^PC=50'

# ---- F4: sovereignty.  The OSD RV-reset hatch (rv_rst_n low) mid-step: the sequence is
# abandoned, the Z80 released, and int_hold must DROP with it -- a dead RV may never leave
# INT masked on a running Z80 (review B8).
TAG=F4
{
  printf '\x1d'
  printf 'D 5000\r00\r00\r00\r00\rC3\r00\r50\r.\r'
  printf 'G 5000\r'
  printf '\x1d'
  printf 'S\r'
  printf 'S\r'                                      # hangs in the re-park (BFM)
} | ALLOW_SILENT=1 runmodel F4 +OM=1 +LINEWAIT=2 +QUIET=150000 +STEPHANG=3 +STEPHANG_CLKS=3000000 +RVRST +RVRST_AT=4000000 +IDLE=6000000
python3 - "$WORK/F4.events.log" <<'PYEOF'
import re, sys
RVRST_AT = 4000000
ev = open(sys.argv[1], errors="replace").read()
ih = [(int(m.group(1)), m.group(2)) for m in
      re.finditer(r"\[p1a-step @(\d+)\] int_hold -> ([01])", ev)]
kicks = len(re.findall(r"p1a-step.*kick", ev))
dn = [t for t, v in ih if v == "0"]
ok_run = (kicks == 2 and 'timeout' not in ev)
ok_drop = bool(ih) and ih[-1][1] == "0" and RVRST_AT <= dn[-1] <= RVRST_AT + 2000
print("  %s: the second step was hung in the re-park (%d kicks, no timeout yet) when the RV reset hit"
      % ("ok" if ok_run else "FAIL", kicks))
print("  %s: int_hold fell with the abort (last fall @%s, RV reset @%d)"
      % ("ok" if ok_drop else "FAIL", dn[-1] if dn else "-", RVRST_AT))
sys.exit(0 if ok_run and ok_drop else 1)
PYEOF
[ $? -eq 0 ] || fail=1

# ---- F3: step timeout.  The BFM stops re-parking after the escape+steps (STEPHANG),
# for 2.2M clocks; the bridge's 1M-clock sim budget expires -> STEP ERR, the request stays
# asserted, and the late park lands afterwards with fresh state.  (R typed while hung does
# not say NOT PARKED: m-parked? polls BUSACK for ~200k iterations, longer than this hang,
# so it simply waits for the late park.)
TAG=F3
{
  printf '\x1d'
  printf 'D 5000\r00\r00\r00\r00\rC3\r00\r50\r.\r'
  printf 'G 5000\r'
  printf '\x1d'
  printf 'S\r'                                      # fine
  printf 'S\r'                                      # the BFM refuses to re-park
  printf 'R\r'                                      # typed while hung: waits, then shows
  printf '\x01'                                     # wait out the hang
  printf 'R\r'                                      # late park landed
  printf 'S\r'                                      # and stepping works again
} | runmodel F3 +OM=1 +LINEWAIT=2 +QUIET=150000 +STEPHANG=3 +STEPHANG_CLKS=2200000 +PAUSE=1200000
echo "--- Part F3 console (tail) ---"; tail -14 "$WORK/F3.norm.log" | grep -v '^$'
check "step timeout reported as STEP ERR"             '^STEP ERR'
n_pcF3=$(grep -ac '^PC=50' "$WORK/F3.norm.log")
[ "$n_pcF3" -eq 2 ] && echo "  ok: the request stayed asserted: R typed while hung and R after the pause both show registers (late park landed)" \
  || { echo "  FAIL: expected 2 R register lines, got $n_pcF3"; fail=1; }
absent "no NOT PARKED (the park was never given up)"    'NOT PARKED'
nt=$(grep -ac 'p1a-step.*timeout' "$WORK/F3.events.log")
[ "$nt" -eq 1 ] && echo "  ok: exactly one step timeout" || { echo "  FAIL: timeouts=$nt (want 1)"; fail=1; }
ns=$(grep -ac 'p1a-step.*regrant' "$WORK/F3.events.log")
[ "$ns" -eq 2 ] && echo "  ok: the first S and the post-recovery S re-parked (2 regrants)" \
  || { echo "  FAIL: regrants=$ns (want 2)"; fail=1; }
fi

if want G; then
# ======================= Part G: physical E / D (M3, R40) ==========================
# MD=1 routes memory kicks to the parked physical client (the lane's mock: sparse
# memory, unwritten byte = a^a>>8^a>>16^A5, page >= 8192 answered done+err).  SDRAM
# window only: E/D 08000000 and up are rejected ? by the monitor, a range that runs
# off the top of the window stops with RD ERR / WR ERR from the client's reject.
TAG=G
{
  printf '\x1d'
  printf 'PHY\r'
  printf 'E 100 4\r'                                 # pattern read
  printf 'D 1000\r11\r22\r.\r'                      # physical deposit
  printf 'E 1000 4\r'                               # 11 22 + pattern
  printf 'E\r'                                      # bare E continues (physical default)
  printf 'E 7FFFFF0 20\r'                           # runs off the top: RD ERR on row 2
  printf 'E 08000000\r'                             # the block-RAM page: ?
  printf 'E 0FFFFFFF\r'                             # ?
  printf 'E 10000000\r'                             # >= 2^28: ?
  printf 'D 08000000\r'                             # ?
  printf 'D 7FFFFFF\r5A\r77\r'                       # last byte ok, then off the end: WR ERR (ends the D)
  printf 'E 7FFFFFF 1\r'                            # the 5A is there
  printf 'LOG\r'
  printf 'E 1000 4\r'                               # logical: the BFM image, not 11 22
  printf 'PHY\r'
  printf 'E 1000 2\r'                               # physical state persisted
  printf 'I 0080\r'                                 # port I/O still fine
  printf 'S\r'                                      # step bytes are the Z80's LOGICAL ones
} | runmodel G +OM=1 +LINEWAIT=2 +QUIET=150000 +PHDELAY=${G_PHDELAY:-0}
echo "--- Part G console ---"; cat "$WORK/G.norm.log"
rowph() { python3 - "$@" <<'PYEOF'
import sys
addr, n = int(sys.argv[1], 16), int(sys.argv[2], 16)
over = {}
for kv in sys.argv[3:]:
    a, v = kv.split("="); over[int(a, 16)] = int(v, 16)
pat = lambda a: ((a & 255) ^ ((a >> 8) & 255) ^ ((a >> 16) & 255) ^ 0xA5)
b = [over.get(a, pat(a)) for a in range(addr, addr + n)]
asc = "".join(chr(x) if 32 <= x <= 126 else "." for x in b)
print("%07X: %s" % (addr, " ".join("%02X" % x for x in b)), end="")
print(" " * (3 * (16 - n)) + "  " + asc)
PYEOF
}
check "physical E: 4 pattern bytes at 0000100"          "^$(rx "$(rowph 100 4)") *\$"
check "physical D shows the pattern byte it replaces"   '^0001000: [0-9A-F]{2} 11 *$'
check "physical D: next address"                        '^0001001: [0-9A-F]{2} 22 *$'
check "physical E reads back the deposit (11 22)"       "^$(rx "$(rowph 1000 4 1000=11 1001=22)") *\$"
check "bare E continues at the next physical address"   "^$(rx "$(rowph 1004 10 1000=11 1001=22)") *\$"
check "E 7FFFFF0 20: first row (last 16 bytes of the window)" "^$(rx "$(rowph 7FFFFF0 10)") *\$"
n_rd=$(grep -ac '^8000000: RD ERR$' "$WORK/G.norm.log")
[ "$n_rd" -eq 1 ] && echo "  ok: reading past the window top stops with RD ERR (client reject)" \
  || { echo "  FAIL: expected 1 RD ERR, got $n_rd"; fail=1; }
n_qG=$(grep -ac '^?$' "$WORK/G.norm.log")
[ "$n_qG" -eq 4 ] && echo "  ok: 4 '?' (E 08000000, E 0FFFFFFF, E 10000000, D 08000000)" \
  || { echo "  FAIL: expected 4 '?', got $n_qG"; fail=1; }
check "D at the last window byte, then off the end"     '^7FFFFFF: [0-9A-F]{2} 5A *$'
check "...the next prompt reads -- (client reject)"     '^8000000: -- 77 *$'
n_wr=$(grep -ac '^WR ERR$' "$WORK/G.norm.log")
[ "$n_wr" -eq 1 ] && echo "  ok: writing past the window top: WR ERR" || { echo "  FAIL: expected 1 WR ERR, got $n_wr"; fail=1; }
check "the last window byte holds the 5A"               '^7FFFFFF: 5A *'
check "LOG: logical E shows the BFM image, not the physical bytes" '^1000: 10 11 12 13 '
check "physical state persists across LOG/PHY"          "^$(rx "$(rowph 1000 2 1000=11 1001=22)") *\$"
check "port I/O works in PHYSICAL"                      '^I 0080 = 8F$'
check "S in PHYSICAL mode shows the Z80's logical bytes (JP \$0100 at the park)" '^0100: C3 00 01 '
absent "no unknown words"                               'not found'
gl=$(grep -aoE 'ph=[0-9]+\([0-9a-f]+,[0-9a-f]+\) phe=[0-9]+' "$WORK/G.info.log" | tail -1)
echo "--- Part G: $gl"
case "$gl" in *phe=3) echo "  ok: exactly 3 client rejects (E row 2, D read, D write at 8000000)";;
  *) echo "  FAIL: expected phe=3, got '$gl'"; fail=1;; esac
if grep -aq 'p1a-ERR' "$WORK/G.events.log"; then echo "  FAIL: BUSRQ released during an engine cycle (Part G)"; fail=1; fi

# ---- G2: a stalled client (refresh-like, 20000 clk per op) still completes
TAG=G2
{
  printf '\x1d'
  printf 'PHY\r'
  printf 'D 2000\r33\r.\r'
  printf 'E 2000 2\r'
} | runmodel G2 +OM=1 +LINEWAIT=2 +QUIET=150000 +PHDELAY=20000
check "stalled physical D/E completes (the deposit reads back)" '^0002000: 33 '
absent "no ERR on a 20000-clk stall"                  'ERR'

# ---- G3: a client that never answers within the bridge watchdog (2^22 clk)
# -> ENGINE_ERR -> RD ERR / --; the monitor stays alive and LOG/E still work
TAG=G3
{
  printf '\x1d'
  printf 'PHY\r'
  printf 'E 2000 1\r'
  printf 'LOG\r'
  printf 'E 100 2\r'
} | runmodel G3 +OM=1 +LINEWAIT=2 +QUIET=150000 +PHDELAY=4400000 +IDLE=12000000
check "bridge watchdog: RD ERR when the client never answers" '^0002000: RD ERR$'
check "monitor alive after the watchdog: logical E works"      '^0100: C3 00 '
fi

if want H; then
# ======================= Part H: U, the shared Z-80 disassembler (R41) =============
# forth/disasm/z80dis.fth through the monitor port (dz@ -> gc@ -> D-30 engine).
# A program is deposited at $1000 (covers a plain opcode, operands, a relative
# jump's computed target, CB, DD, ED and FD pages and the three custom-CPU
# instruction forms), listed, listed again by a bare U (continues), and listed
# in PHYSICAL mode (28-bit address, bytes from the physical client's mock).
TAG=H
{
  printf '\x1d'
  printf '?\r'
  printf 'D 1000\r'
  for b in F3 3E 12 21 34 12 18 02 00 00 C3 00 10 CB 7E DD 36 05 99 \
           ED B0 FD CB 02 06 ED 92 ED C5 ED E1 76 .; do printf '%s\r' $b; done
  printf 'U 1000 e\r'                              # 14 instructions
  printf 'U\r'                                      # continues after the last one
  printf 'U zz\rU 1000 0\rU 1000 1 2\r'             # argument errors -> ?
  printf 'PHY\r'
  printf 'U 100 2\r'                                # physical: 7-digit address
  printf 'LOG\r'
  printf 'U 1000 1\r'                               # logical again
  printf 'G\r'
} | runmodel H +OM=1 +LINEWAIT=2 +QUIET=150000
echo "--- Part H console ---"; cat "$WORK/H.norm.log"
check "help lists U"                                  '^U \[AAAA \[N\]\]  UNASSEMBLE'
check "DI (one byte)"                                 '^1000: F3 +DI *$'
check "LD A, n"                                       '^1001: 3E 12 +LD A, 12h *$'
check "LD HL, nn (little-endian operand)"             '^1003: 21 34 12 +LD HL, 1234h *$'
check "JR shows the computed target address"          '^1006: 18 02 +JR 100Ah *$'
check "NOP"                                           '^1008: 00 +NOP *$'
check "JP nn"                                         '^100A: C3 00 10 +JP 1000h *$'
check "CB page: BIT 7, (HL)"                          '^100D: CB 7E +BIT 7, \(HL\) *$'
check "DD page: LD (IX+d), n (4 bytes, no marker)"    '^100F: DD 36 05 99 +LD \(IX\+05h\), 99h *$'
check "ED page: LDIR"                                 '^1013: ED B0 +LDIR *$'
check "FD CB d op: RLC (IY+d)"                        '^1015: FD CB 02 06 +RLC \(IY\+02h\) *$'
check "custom CPU instruction F_NEXT"                 '^1019: ED 92 +F_NEXT *$'
check "custom CPU instruction PUSHIX BC"              '^101B: ED C5 +PUSHIX BC *$'
check "custom CPU instruction POPIX HL"               '^101D: ED E1 +POPIX HL *$'
check "HALT, the 14th instruction"                    '^101F: 76 +HALT *$'
check "bare U continues after the last listed byte"   '^1020: '
n_qH=$(grep -ac '^?$' "$WORK/H.norm.log")
[ "$n_qH" -eq 3 ] && echo "  ok: 3 '?' replies (U zz, U 1000 0, U 1000 1 2)" \
  || { echo "  FAIL: expected 3 '?' replies, got $n_qH"; fail=1; }
check "PHYSICAL U: 7-digit address, bytes via the physical client" '^0000100: A4 +AND H *$'
check "second physical instruction"                   '^0000101: A5 +AND L *$'
check "LOG restores the logical view"                 '^1000: F3 +DI *$'
absent "no read error in a healthy listing"           'RD ERR'
if grep -aq 'p1a-ERR' "$WORK/H.events.log"; then
  echo "  FAIL: BUSRQ released during an engine cycle (Part H)"; fail=1
fi
fi

[ $fail -eq 0 ] && echo "p1a_smoke: PASS" || echo "p1a_smoke: FAIL"
exit $fail
