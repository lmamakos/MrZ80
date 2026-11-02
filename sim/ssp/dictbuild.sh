#!/usr/bin/env bash
# sim/ssp/dictbuild.sh -- D-35 dictionary build of the SSP MONITOR on the
# Verilator model (real ssp_top + Z80 BFM, sim/ssp/obj_p1a/ssp_p1a).  Derived
# from the P0 stub-lane script (retired R43).  The qemu rehearsal of the same
# flow is dictbuild_qemu.sh; tools/ssp_image.py is the everyday front end.
#
# Flow:
#   1. make -C ssp/fw ssp                    kernel hex (silicon map)
#   2. model session: operator escape (the console is the guest's until then,
#      R25), `compiletoflash`, the SSP_* constants monitor.fs uses (picked out
#      of the generated ssp-regs.fs by name), then ssp/fw/apps/monitor.fs.
#      Input is paced a line at a time (+LINEWAIT).
#   3. harness ROM dump ($writememh) -> hex -> bin = kernel+dict merged
#   4. kernel-byte integrity: bytes below the dict window identical to the
#      shipped kernel image
#   5. cold boot of the artifact: `init` runs the monitor, which stays silent
#      until the operator escapes, then banners; E proves it is alive and
#      reading the BFM's memory through the D-30 sequencer.
# Artifacts: ssp/fw/build/mecrisp-ssp-app.{bin,hex}, dict.{bin,hex}.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
MODEL=${MODEL:-sim/ssp/obj_p1a/ssp_p1a}
FW=ssp/fw
BUILD=$FW/build
WORK=/tmp/opencode/dictbuild-rtl; mkdir -p "$WORK"
ROM_LEN=0x20000                 # 128 KiB MROM (R43)
DICT_OFF=0x5000                 # = FlashDictionaryAnfang = ssp_top DICT_BASE
DICT_LEN=$((ROM_LEN - DICT_OFF))

[ -x "$MODEL" ] || { echo "FAIL: model $MODEL missing (make -C sim p1a)"; exit 1; }
make -C "$FW" ssp >/dev/null || { echo "FAIL: fw build"; exit 1; }
KHEX=$BUILD/mecrisp-ssp.hex
KBIN=$BUILD/mecrisp-ssp.bin

# ---- build input: constants monitor.fs uses + monitor.fs, comment-stripped --------
# monitor.fs may pull in shared source with a line `\ @include path/from/repo/root`
# (R41: forth/disasm/z80dis.fth, the Z-80 disassembler core shared with CamelFORTH).
# Every input byte costs 4.3k cycles of wire time, so drop blank lines, full-line
# comments and trailing "\ ..." comments (no string in monitor.fs contains a
# backslash) and the "( ... )" description the generator appends to constants.
python3 tools/ssp_appsrc.py "$FW/ssp-regs.fs" "$FW/apps/monitor.fs" "$WORK/build_input.fs" || exit 1

# ---- session 1: build the dictionary ------------------------------------------
{ printf '\x1d'; printf 'compiletoflash\r'; cat "$WORK/build_input.fs"; } \
  | timeout 1500 "$MODEL" +ROM="$KHEX" +OM=1 +DUMP="$WORK/rom.hex" +LINEWAIT=1 \
      +MAXCYCLES=2000000000 +IDLE=3000000 +ECHO=0 \
  > "$WORK/console_build.log" 2> "$WORK/info_build.log"
rc=$?
[ $rc -eq 0 ] || { echo "FAIL: build session exit $rc"; tail -3 "$WORK/info_build.log"; tail -20 "$WORK/console_build.log"; exit 1; }
grep -aiE 'not found|stack|unbalanced' "$WORK/console_build.log" | head -5 > "$WORK/errs.txt"
[ -s "$WORK/errs.txt" ] && { echo "FAIL: build session errors:"; cat "$WORK/errs.txt"; tail -12 "$WORK/console_build.log"; exit 1; }
grep -aq 'compiletoflash' "$WORK/console_build.log" || { echo "FAIL: compiletoflash missing"; exit 1; }
[ -f "$WORK/rom.hex" ] || { echo "FAIL: no ROM dump"; exit 1; }
python3 tools/hex2bin.py "$WORK/rom.hex" "$WORK/rom.bin" "$ROM_LEN"

# ---- dictionary usage + kernel integrity --------------------------------------
DICT_USED=$(python3 - "$WORK/rom.bin" "$DICT_OFF" "$DICT_LEN" <<'PYEOF'
import sys
d = open(sys.argv[1], "rb").read()
lo, n = int(sys.argv[2], 0), int(sys.argv[3], 0)
end = lo + n
while end >= lo + 4 and d[end-4:end] == b"\x00\x00\x00\x00":
    end -= 4
print(end - lo)
PYEOF
)
echo "dictionary window: ${DICT_LEN} B, used: ${DICT_USED} B"
[ "$DICT_USED" -gt 0 ] || { echo "FAIL: dictionary empty"; exit 1; }

python3 - "$KBIN" "$WORK/rom.bin" "$DICT_OFF" <<'PYEOF' || exit 1
import sys
k = open(sys.argv[1], "rb").read()
r = open(sys.argv[2], "rb").read()
lim = int(sys.argv[3], 0)
k += b"\x00" * (lim - len(k)) if len(k) < lim else b""
assert k[:lim] == r[:lim], "kernel bytes differ below dict window"
print("kernel integrity: ok (%d bytes identical)" % lim)
PYEOF

# ---- artifacts ---------------------------------------------------------------
cp "$WORK/rom.bin" "$BUILD/mecrisp-ssp-app.bin"
python3 tools/bin2hex.py "$BUILD/mecrisp-ssp-app.bin" \
  "$BUILD/mecrisp-ssp-app.hex" "$ROM_LEN" >/dev/null \
  || { echo "FAIL: bin2hex merged image"; exit 1; }
dd if="$WORK/rom.bin" of="$BUILD/dict.bin" bs=1 skip=$((DICT_OFF)) \
   count=$((DICT_LEN)) status=none
python3 tools/bin2hex.py "$BUILD/dict.bin" "$BUILD/dict.hex" \
  "$DICT_LEN" "$DICT_OFF" >/dev/null \
  || { echo "FAIL: bin2hex dict fragment"; exit 1; }
[ -s "$BUILD/dict.hex" ] && [ -s "$BUILD/mecrisp-ssp-app.hex" ] \
  || { echo "FAIL: artifact hex files missing/empty"; exit 1; }

# ---- cold-boot residency proof (artifact as shipped) -----------------------------
# Escape, then E: the BFM image starts C3 00 01 (JP $0100) at $0000.
{ printf '\x1d'; printf 'E 0 20\r'; } \
  | timeout 300 "$MODEL" +ROM="$BUILD/mecrisp-ssp-app.hex" +OM=1 +ECHO=0 \
      +IDLE=2000000 +MAXCYCLES=100000000 \
  > "$WORK/console_cold.log" 2> "$WORK/info_cold.log"
rc=$?
[ $rc -eq 0 ] || { echo "FAIL: cold boot exit $rc"; tail -2 "$WORK/info_cold.log"; exit 1; }

grep -av '^\[p1a\]' "$WORK/console_cold.log" | tr '\r' '\n' > "$WORK/cold_norm.log"
rc=0
expect() { grep -aEq "$1" "$WORK/cold_norm.log" && echo "  ok: /$1/" \
           || { echo "  MISSING: /$1/"; rc=1; }; }
expect '(MRZ80|MrZ80) SSP MONITOR'
expect '^0000: C3 00 01 '
expect '^0010: '
grep -aqi 'not found' "$WORK/cold_norm.log" && { echo "  FAIL: unknown word at cold boot"; rc=1; }
echo "--- cold console ---"; cat "$WORK/cold_norm.log"
[ $rc -eq 0 ] && echo "dictbuild: PASS" || echo "dictbuild: FAIL"
exit $rc
