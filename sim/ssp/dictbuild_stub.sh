#!/usr/bin/env bash
# sim/ssp/dictbuild_stub.sh -- D-35 dictionary build at HARDWARE-true
# addresses on the Verilator stub SoC.  Authoritative lane of the pipeline
# rehearsed on qemu by dictbuild_qemu.sh (R18); the captured merged image is
# the OSD MROM artifact form (rom@0, dict window 0x4400..0x10000).
# Cores: TAG=picorv32 (default) | gracilis (MODEL + obj dir selected by
# the Makefile wrappers); artifacts carry the tag.
#
# Flow:
#   1. make -C ssp/fw ssp                     kernel hex (silicon map)
#   2. stub SoC session: compiletoflash + apps/demo.fs over the modelled
#      console (RX pacing structural: FIFO-room polling, §R19)
#   3. harness ROM dump ($writememh) -> hex -> bin = kernel+dict merged
#   4. kernel-byte integrity: bytes below the dict window identical to the
#      shipped kernel image (build session must not touch them)
#   5. cold boot of the artifact hex: app words resident from power-on
#      (reg-id reads the stub bridge ID 4D525A03 -- hardware-map proof)
# Artifacts land in ssp/fw/build/ (dict-stub.bin/.hex, mecrisp-ssp-stub-app.bin/.hex).

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
TAG=${TAG:-picorv32}
MODEL=${MODEL:-sim/ssp/obj_dir/ssp_stub}
FW=ssp/fw
BUILD=$FW/build
WORK=/tmp/opencode/dictbuild-stub-$TAG; mkdir -p "$WORK"
DICT_OFF=0x4400
DICT_LEN=$((0x10000 - 0x4400))

[ -x "$MODEL" ] || { echo "FAIL: model $MODEL missing (make -C sim stub${TAG:+-$TAG}?)"; exit 1; }
make -C "$FW" ssp >/dev/null || { echo "FAIL: fw build"; exit 1; }
KHEX=$BUILD/mecrisp-ssp.hex
KBIN=$BUILD/mecrisp-ssp.bin

# ---- session 1: build the dictionary ------------------------------------------
{ printf 'compiletoflash\r'; sed 's/$/\r/' "$FW/apps/demo.fs"; } \
  | timeout 180 "$MODEL" +ROM="$KHEX" +DUMP="$WORK/stub-rom.hex" +IDLE=3000000 \
  > "$WORK/console_build.log" 2> "$WORK/info_build.log"
rc=$?
[ $rc -eq 0 ] || { echo "FAIL: build session exit $rc"; tail -2 "$WORK/info_build.log"; cat "$WORK/console_build.log"; exit 1; }
grep -qi 'not found' "$WORK/console_build.log" && {
  echo "FAIL: build session had unknown words"; cat "$WORK/console_build.log"; exit 1; }
grep -q 'compiletoflash' "$WORK/console_build.log" || { echo "FAIL: compiletoflash missing"; exit 1; }

[ -f "$WORK/stub-rom.hex" ] || { echo "FAIL: no ROM dump"; exit 1; }
python3 tools/hex2bin.py "$WORK/stub-rom.hex" "$WORK/stub-rom.bin" 0x10000

# ---- dictionary usage + kernel integrity --------------------------------------
DICT_USED=$(python3 - "$WORK/stub-rom.bin" "$DICT_OFF" "$DICT_LEN" <<'PYEOF'
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

# kernel bytes below the window must be untouched (pad kernel.bin to window)
python3 - "$KBIN" "$WORK/stub-rom.bin" "$DICT_OFF" <<'PYEOF'
import sys
k = open(sys.argv[1], "rb").read()
r = open(sys.argv[2], "rb").read()
lim = int(sys.argv[3], 0)
k += b"\x00" * (lim - len(k)) if len(k) < lim else k
assert k[:lim] == r[:lim], "kernel bytes differ below dict window"
print("kernel integrity: ok (%d bytes identical)" % lim)
PYEOF

# ---- artifacts ---------------------------------------------------------------
cp "$WORK/stub-rom.bin" "$BUILD/mecrisp-ssp-$TAG-app.bin"
python3 tools/bin2hex.py "$BUILD/mecrisp-ssp-$TAG-app.bin" \
  "$BUILD/mecrisp-ssp-$TAG-app.hex" 0x10000 >/dev/null \
  || { echo "FAIL: bin2hex merged image"; exit 1; }
dd if="$WORK/stub-rom.bin" of="$BUILD/dict-$TAG.bin" bs=1 skip=$((DICT_OFF)) \
   count=$((DICT_LEN)) status=none
python3 tools/bin2hex.py "$BUILD/dict-$TAG.bin" "$BUILD/dict-$TAG.hex" \
  "$DICT_LEN" "$DICT_OFF" >/dev/null \
  || { echo "FAIL: bin2hex dict fragment"; exit 1; }
[ -s "$BUILD/dict-$TAG.hex" ] && [ -s "$BUILD/mecrisp-ssp-$TAG-app.hex" ] \
  || { echo "FAIL: artifact hex files missing/empty"; exit 1; }

# ---- cold-boot residency proof (artifact-as-shipped) ------------------------
printf 'cpu-hello\r42answer . cr\rreg-id hex. cr\r' \
  | timeout 120 "$MODEL" +ROM="$BUILD/mecrisp-ssp-$TAG-app.hex" +IDLE=2000000 \
  > "$WORK/console_cold.log" 2> "$WORK/info_cold.log"
rc=$?
[ $rc -eq 0 ] || { echo "FAIL: cold boot exit $rc"; tail -2 "$WORK/info_cold.log"; exit 1; }

rc=0
norm=$(tr '\r' '\n' < "$WORK/console_cold.log" | tr 'A-Z' 'a-z')
expect() { echo "$norm" | grep -Eq "$1" && echo "  ok: /$1/" \
           || { echo "  MISSING: /$1/"; rc=1; }; }
expect 'hello from the ssp application dictionary'
expect 'answer \. cr 42 *$'
expect 'reg-id hex\. cr'
expect '4d525a03'      # bridge ID via app word reg-id (stub decode == CSV)
grep -qi 'not found' "$WORK/console_cold.log" && { echo "  FAIL: unknown word at cold boot"; rc=1; }
echo "--- cold console ---"; cat "$WORK/console_cold.log"
[ $rc -eq 0 ] && echo "dictbuild_stub($TAG): PASS" || echo "dictbuild_stub($TAG): FAIL"
exit $rc
