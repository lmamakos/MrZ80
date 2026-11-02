#!/usr/bin/env bash
# sim/ssp/p1a_dlpath.sh -- R43 OSD ROM mount (R-29) on the p1a lane: real
# ssp_top + Z80 BFM, the harness streaming an image into the mnt_* port the
# way hps_io does (one byte per write, held off by mnt_busy = ioctl_wait).
#
# Part A  kernel-only ROM; mount the full 128 KiB monitor image (with a marker
#         in its last word).  The MROM must then equal the image byte for byte
#         (all four byte lanes, top address included), the monitor must boot
#         from it (escape -> banner, E reads guest memory), and the guest must
#         run straight through the mount (never reset).
# Part B  monitor ROM, guest parked by an escape; mount the SHORT kernel-only
#         image.  The park must be released during the mount (guest runs), the
#         MROM tail above the image must read zero (clear sweep), and after a
#         second escape the bare Mecrisp REPL answers (no monitor any more).
# Part C  SSP Monitor Off (+OSD_OK=0): a mount still lands byte for byte.
#
# Needs the monitor image from dictbuild.sh (built here if missing).

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
MODEL=${MODEL:-sim/ssp/obj_p1a/ssp_p1a}
BUILD=ssp/fw/build
APPBIN=$BUILD/mecrisp-ssp-app.bin
APPHEX=$BUILD/mecrisp-ssp-app.hex
KBIN=$BUILD/mecrisp-ssp.bin
KHEX=$BUILD/mecrisp-ssp.hex
WORK=/tmp/opencode/p1a-dlpath; mkdir -p "$WORK"
ROM_LEN=131072

[ -x "$MODEL" ] || { echo "FAIL: model missing -- run: make -C sim p1a"; exit 1; }
make -C ssp/fw ssp >/dev/null || { echo "FAIL: fw build"; exit 1; }
if [ ! -f "$APPBIN" ] || [ "$(stat -c %s "$APPBIN")" -ne $ROM_LEN ]; then
  echo "(building the monitor dictionary: sim/ssp/dictbuild.sh)"
  sim/ssp/dictbuild.sh > "$WORK/dictbuild.log" 2>&1 \
    || { echo "FAIL: dictionary build"; tail -15 "$WORK/dictbuild.log"; exit 1; }
fi

# ---- mount images: one hex byte per line -----------------------------------------
python3 - "$APPBIN" "$KBIN" "$WORK" <<'PYEOF' || exit 1
import sys
app, kern, w = sys.argv[1:4]
a = bytearray(open(app, "rb").read())
a[-4:] = b"\xde\xad\xbe\xef"                   # top word: proves 0x1FFFC..F land
open(w + "/imgA.bin", "wb").write(a)
k = open(kern, "rb").read()
open(w + "/imgB.bin", "wb").write(k)
for n, d in (("imgA", a), ("imgB", k)):
    open("%s/%s.bytes" % (w, n), "w").write("\n".join("%02x" % b for b in d) + "\n")
print("images: A %d bytes (monitor + marker), B %d bytes (kernel only)" % (len(a), len(k)))
PYEOF
LEN_B=$(stat -c %s "$WORK/imgB.bin")

fail=0
ok()   { echo "  ok: $1"; }
miss() { echo "  FAIL: $1"; fail=1; }
run() { # $1 = tag, rest = plusargs; stdin = operator input
  local tag=$1; shift
  timeout 900 "$MODEL" "$@" +MAXCYCLES=200000000 +IDLE=3000000 +ECHO=0 \
      +DUMP="$WORK/$tag.dump.hex" > "$WORK/$tag.out" 2> "$WORK/$tag.info"
  local rc=$?
  { [ $rc -eq 0 ] || { [ $rc -eq 3 ] && [ "${ALLOW_SILENT:-0}" = 1 ]; }; } \
    || { echo "FAIL: harness exit $rc ($tag)"; tail -3 "$WORK/$tag.info"; exit 1; }
  # $display lines can land in the middle of a console line: pick the events
  # out anywhere, and cut them out of the console text
  python3 - "$WORK/$tag" <<'PYEOF'
import re, sys
w = sys.argv[1]
t = open(w + ".out", "rb").read().decode("latin-1")
ev = re.compile(r"\[p1a[^]]*\][^\r\n]*\n?")
open(w + ".events", "w").write("\n".join(m.group(0).rstrip("\n") for m in ev.finditer(t)) + "\n")
open(w + ".console", "w").write(ev.sub("", t).replace("\r", "\n"))
PYEOF
  python3 tools/hex2bin.py "$WORK/$tag.dump.hex" "$WORK/$tag.dump.bin" $ROM_LEN >/dev/null
}
ev()      { grep -aEq "$2" "$WORK/$TAG.events"  && ok "$1" || miss "$1 (/$2/)"; }
con()     { grep -aEq "$2" "$WORK/$TAG.console" && ok "$1" || miss "$1 (/$2/)"; }
no_err()  { grep -aq 'p1a-ERR' "$WORK/$TAG.events" && miss "harness error: $(grep -a p1a-ERR "$WORK/$TAG.events" | head -1)" || ok "no harness errors"; }
fetches() { sed -nE 's/.*\[p1a-mnt @[0-9]+\] end .*fetches_during=([0-9]+).*/\1/p' "$WORK/$TAG.events"; }
romcmp()  { # $1 = description, $2 = expected-image bin (zero-padded to 128 KiB)
  python3 - "$WORK/$TAG.dump.bin" "$2" <<'PYEOF' && ok "$1" || miss "$1"
import sys
d = open(sys.argv[1], "rb").read()
e = open(sys.argv[2], "rb").read()
e += b"\x00" * (len(d) - len(e))
if d != e:
    i = next(i for i in range(len(d)) if d[i] != e[i])
    print("    first difference at 0x%05x: rom %02x, image %02x" % (i, d[i], e[i]))
    sys.exit(1)
PYEOF
}

# ---- Part A ----------------------------------------------------------------------
echo "--- Part A: kernel-only ROM, mount the 128 KiB monitor image"
TAG=A
{ printf '\x1d'; printf 'E 0 20\r'; } | run A +ROM="$KHEX" +OM=1 \
    +MNT="$WORK/imgA.bytes" +MNT_LEN=$ROM_LEN +MNT_AT=300000 +RXAT=3000000
ev  "download started"                      '\[p1a-mnt @[0-9]+\] start'
ev  "download ended, all bytes streamed"    "\[p1a-mnt @[0-9]+\] end bytes=$ROM_LEN "
ev  "guest not reset by the mount"          'end .* z_reset_n=1'
ev  "monitor released after the mount"      '\[p1a-mnt @[0-9]+\] restart'
python3 - "$WORK/A.events" <<'PYEOF' && ok "monitor reset lasts past the end of the stream" || miss "RV released too early after the stream"
import re, sys
t = open(sys.argv[1]).read()
e = int(re.search(r"p1a-mnt @(\d+)\] end", t).group(1))
r = int(re.search(r"p1a-mnt @(\d+)\] restart", t).group(1))
sys.exit(0 if r - e >= 200 else 1)
PYEOF
f=$(fetches); [ "${f:-0}" -gt 0 ] && ok "guest ran during the mount ($f fetches)" || miss "guest did not run during the mount"
romcmp "MROM == mounted image (all lanes, 0x00000..0x1FFFF)" "$WORK/imgA.bin"
con "monitor boots from the mounted image"  'MRZ80 SSP MONITOR'
con "E reads guest memory"                  '^0000: C3 00 01 '
no_err

# ---- Part B ----------------------------------------------------------------------
echo "--- Part B: monitor ROM, parked guest, mount the short kernel-only image"
TAG=B
{ printf '\x1d'; printf 'E 0 8\r'; printf '\x01'; printf '\x1d'; printf '1 2 + .\r'; } \
  | run B +ROM="$APPHEX" +OM=1 +MNT="$WORK/imgB.bytes" +MNT_LEN=$LEN_B \
      +MNT_AT=4000000 +PAUSE=5000000
con "monitor ran before the mount"          'MRZ80 SSP MONITOR'
ev  "guest parked when the download starts" '\[p1a-mnt @[0-9]+\] start .*parked=1'
ev  "park released by the mount"            'end .* busrq_n=1 '
ev  "bridge reset by the mount (console back to the guest)" 'restart .*console_own=0'
ev  "guest not reset by the mount"          'end .* z_reset_n=1'
f=$(fetches); [ "${f:-0}" -gt 0 ] && ok "guest ran during the mount ($f fetches)" || miss "guest did not run during the mount"
romcmp "MROM == short image + zero tail (clear sweep)" "$WORK/imgB.bin"
con "bare Mecrisp REPL after the mount"     '1 2 \+ \. 3 '
grep -aq 'MRZ80 SSP MONITOR' <(sed -n '/1 2 + ./,$p' "$WORK/B.console") \
  && miss "monitor still present after the mount" || ok "monitor gone after the mount"
no_err

# ---- Part C ----------------------------------------------------------------------
echo "--- Part C: SSP Monitor Off, the mount still lands"
TAG=C
: | ALLOW_SILENT=1 run C +ROM="$KHEX" +OSD_OK=0 +MNT="$WORK/imgA.bytes" \
      +MNT_LEN=$ROM_LEN +MNT_AT=300000
ev  "download ended"                        "\[p1a-mnt @[0-9]+\] end bytes=$ROM_LEN "
romcmp "MROM == mounted image" "$WORK/imgA.bin"
no_err

[ $fail -eq 0 ] && echo "p1a_dlpath: PASS" || echo "p1a_dlpath: FAIL"
exit $fail
