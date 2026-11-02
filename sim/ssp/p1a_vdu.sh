#!/usr/bin/env bash
# sim/ssp/p1a_vdu.sh -- R44 SSP console on the video terminal, on the p1a lane
# (real ssp_top + Z80 BFM + a model of the SSP terminal's byte port, see
# p1a_sim_top.v +VDU/+KEYS).  The real terminal is covered by
# `make -C sim terminal`.
#
# Part A  OSD "Enter SSP Monitor" with SSP Console = Video, Serial Escape (OM)
#         off: the Z80 is parked, the SSP screen shown, the banner and an E
#         listing go to the video terminal and nothing to the serial pin; keys
#         come from the keyboard; bytes typed on the serial port meanwhile still
#         reach the Z80; G gives the screen back.
# Part B  OSD entry with SSP Console = Serial, OM off: the monitor works on the
#         serial port, the video terminal gets nothing, and the operator's bytes
#         do NOT reach the Z80 (the monitor reads them).
# Part C  the serial escape (OM on) always routes the console to serial, even
#         with SSP Console = Video.
# Part D  OM on, video console: serial bytes still reach the Z80 through the
#         escape relay while the monitor is on the video terminal.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
MODEL=${MODEL:-sim/ssp/obj_p1a/ssp_p1a}
APP=ssp/fw/build/mecrisp-ssp-app.hex
WORK=/tmp/opencode/p1a-vdu; mkdir -p "$WORK"

[ -x "$MODEL" ] || { echo "FAIL: model missing -- run: make -C sim p1a"; exit 1; }
[ -f "$APP" ] || { echo "FAIL: $APP missing -- run: make -C sim dict-rtl"; exit 1; }

fail=0
ok()   { echo "  ok: $1"; }
miss() { echo "  FAIL: $1"; fail=1; }
hexkeys() { python3 -c "import sys; print('\n'.join('%02x' % ord(c) for c in sys.argv[1]))" "$1"; }
run() { # $1 = tag, rest = plusargs; stdin = serial operator input
  local tag=$1; shift
  : > "$WORK/$tag.vdu"
  timeout 900 "$MODEL" "$@" +ROM="$APP" +VDU="$WORK/$tag.vdu" +ECHO=0 \
      > "$WORK/$tag.out" 2> "$WORK/$tag.info"
  local rc=$?
  { [ $rc -eq 0 ] || [ $rc -eq 3 ]; } \
    || { echo "FAIL: harness exit $rc ($tag)"; tail -3 "$WORK/$tag.info"; exit 1; }
  python3 - "$WORK/$tag" <<'PYEOF'
import re, sys
w = sys.argv[1]
t = open(w + ".out", "rb").read().decode("latin-1")
ev = re.compile(r"\[p1a[^]]*\][^\r\n]*\n?")
open(w + ".events", "w").write("\n".join(m.group(0).rstrip("\n") for m in ev.finditer(t)) + "\n")
open(w + ".serial", "w").write(ev.sub("", t).replace("\r", "\n"))
open(w + ".video", "w").write(open(w + ".vdu", "rb").read().decode("latin-1").replace("\r", "\n"))
PYEOF
}
has()  { grep -aEq "$3" "$WORK/$TAG.$2" && ok "$1" || miss "$1 (/$3/ in $2)"; }
hasnt(){ grep -aEq "$3" "$WORK/$TAG.$2" && miss "$1 (/$3/ in $2)" || ok "$1"; }
guest_rx() { sed -nE 's/.* guest_rx=([0-9]+).*/\1/p' "$WORK/$TAG.info" | tail -1; }

# ---- Part A ----------------------------------------------------------------------
echo "--- Part A: OSD entry, video console, OM off"
TAG=A
hexkeys $'E 0 8\rG\r' > "$WORK/A.keys"
printf 'abc' | run A +OM=0 +OSDENTER_AT=1000000 +OSDVID=1 \
    +KEYS="$WORK/A.keys" +KEYS_AT=2000000 +KEYS_GAP=60000 +RXAT=1500000 \
    +MAXCYCLES=8000000 +IDLE=100000000
has   "OSD entry seen"                        events '\[p1a-vdu @[0-9]+\] OSD enter \(video=1\)'
has   "SSP screen shown"                      events 'show -> 1'
has   "banner on the video terminal"          video  'MrZ80 SSP MONITOR'
has   "E listing on the video terminal"       video  '^0000: C3 00 01 03 04 05 06 07 '
has   "keys echoed on the video terminal"     video  'E 0 8'
has   "G gives the screen back"               events 'show -> 0'
hasnt "nothing from the monitor on serial"    serial 'MRZ80|0000:'
n=$(guest_rx); [ "${n:-0}" -eq 3 ] && ok "serial bytes still reach the Z80 (guest_rx=$n)" \
    || miss "serial bytes reach the Z80 (guest_rx=${n:-?}, expected 3)"
hasnt "serial bytes not read by the monitor"  video  'abc'

# ---- Part B ----------------------------------------------------------------------
echo "--- Part B: OSD entry, serial console, OM off"
TAG=B
printf 'E 0 8\r' | run B +OM=0 +OSDENTER_AT=1000000 +OSDVID=0 +RXAT=2000000 \
    +MAXCYCLES=12000000 +IDLE=3000000
has   "banner on serial"                      serial 'MrZ80 SSP MONITOR'
has   "E listing on serial"                   serial '^0000: C3 00 01 03 04 05 06 07 '
hasnt "SSP screen never shown"                events 'show -> 1'
[ -s "$WORK/B.vdu" ] && miss "video terminal got bytes" || ok "video terminal got nothing"
n=$(guest_rx); [ "${n:-0}" -eq 0 ] && ok "operator bytes kept from the Z80 (guest_rx=0)" \
    || miss "operator bytes reached the Z80 (guest_rx=$n)"

# ---- Part C ----------------------------------------------------------------------
echo "--- Part C: serial escape with SSP Console = Video"
TAG=C
printf '\x1dE 0 8\r' | run C +OM=1 +OSDVID=1 +MAXCYCLES=12000000 +IDLE=3000000
has   "banner on serial"                      serial 'MrZ80 SSP MONITOR'
has   "E listing on serial"                   serial '^0000: C3 00 01 '
hasnt "SSP screen never shown"                events 'show -> 1'
[ -s "$WORK/C.vdu" ] && miss "video terminal got bytes" || ok "video terminal got nothing"

# ---- Part D ----------------------------------------------------------------------
echo "--- Part D: OM on, video console, serial bytes relayed to the Z80"
TAG=D
printf 'xyz' | run D +OM=1 +OSDENTER_AT=1000000 +OSDVID=1 \
    +KEYS="$WORK/A.keys" +KEYS_AT=2000000 +KEYS_GAP=60000 +RXAT=1500000 \
    +MAXCYCLES=8000000 +IDLE=100000000
has   "E listing on the video terminal"       video  '^0000: C3 00 01 03 04 05 06 07 '
n=$(guest_rx); [ "${n:-0}" -eq 3 ] && ok "serial bytes relayed to the Z80 (guest_rx=$n)" \
    || miss "serial bytes relayed to the Z80 (guest_rx=${n:-?}, expected 3)"
hasnt "serial bytes not read by the monitor"  video  'xyz'

[ $fail -eq 0 ] && echo "p1a_vdu: PASS" || echo "p1a_vdu: FAIL"
exit $fail
