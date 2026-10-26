#!/usr/bin/env bash
# sim/ssp/dictbuild_qemu.sh -- D-35 build-pipeline rehearsal on qemu.
#
# Flow (the qemu lane of the dictionary build; the authoritative run later
# happens on the sim/ssp Verilator stub SoC with hardware-true addresses,
# same script shape):
#   1. build the FW qemu variant (dict window 0x8000_4400..0x8001_0000,
#      "rom" = writable DRAM)
#   2. boot REPL, send `compiletoflash`, feed apps/demo.fs (paced bytes)
#   3. capture the dictionary window with QMP pmemsave
#   4. merge kernel.bin + dict.bin -> mecrisp-ssp-qemu-app.bin
#   5. cold-boot the merged image and prove the app words are resident
#      from power-on -- no source re-EVAL, exactly how silicon will boot
#      the OSD MROM artifact.
#
# Exit 0 = dictionary built, captured, merged, and app words live at cold
# boot. Artifacts land in ssp/fw/build/.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FW=$ROOT/ssp/fw
BUILD=$FW/build
WORK=/tmp/opencode/dictbuild
DICT_OFF=0x4400                 # window offset within the 64 KiB image
DICT_LEN=$((0x10000 - 0x4400)) # 0xBC00
OBJCOPY=${CROSS:-riscv64-unknown-elf-}objcopy

mkdir -p "$WORK"
rm -f "$WORK"/*.bin "$WORK"/*.log "$WORK"/qmp
make -C "$FW" qemu >/dev/null || { echo "FAIL: fw build"; exit 1; }
"$OBJCOPY" -O binary --gap-fill 0x00 --pad-to 0x80010000 \
  "$BUILD/mecrisp-ssp-qemu.elf" "$WORK/kernel.bin" || { echo "FAIL: objcopy"; exit 1; }

send_line() {  # $1 = pty, rest paced like a 115200-ish terminal
  local pty=$1 line=$2 i
  for ((i = 0; i < ${#line}; i++)); do
    printf '%s' "${line:$i:1}" > "$pty"; sleep 0.02
  done
  printf '\r' > "$pty"; sleep 0.5
}

qmp_save() {  # $1 = filename to receive $2 bytes at guest addr $3
  python3 - "$WORK/qmp" "$1" "$2" "$3" <<'PYEOF'
import socket, sys, json
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(10)
def rx():
    buf = ""
    while True:
        try: buf += s.recv(65536).decode(errors="replace")
        except Exception: return None
        while "\n" in buf:
            ln, buf = buf.split("\n", 1)
            ln = ln.strip()
            if '"return"' in ln or '"error"' in ln:
                return json.loads(ln)
rx()  # greeting
s.sendall(b'{"execute":"qmp_capabilities"}\r\n'); rx()
cmd = {"execute": "pmemsave",
       "arguments": {"filename": sys.argv[2],
                    "val": int(sys.argv[4], 0),    # phys addr (this QEMU's
                    "size": int(sys.argv[3], 0)}}  # pmemsave: {val,size,file}
s.sendall((json.dumps(cmd) + "\r\n").encode()); print(rx())
PYEOF
}

# ---- session 1: build the dictionary ------------------------------------------
timeout 90 qemu-system-riscv32 -M virt -cpu rv32 -m 8 -bios none \
  -kernel "$BUILD/mecrisp-ssp-qemu.elf" -display none -no-reboot \
  -serial pty -qmp unix:"$WORK/qmp",server,nowait > "$WORK/pty.log" 2>&1 &
QPID=$!
PTY=""
for _ in $(seq 50); do
  PTY=$(grep -o '/dev/pts/[0-9]*' "$WORK/pty.log" | head -1)
  [ -n "$PTY" ] && break; sleep 0.2
done
[ -n "$PTY" ] || { echo "FAIL: no pty"; kill $QPID; exit 1; }
cat "$PTY" > "$WORK/console_build.bin" & CATPID=$!
sleep 0.5

send_line "$PTY" 'compiletoflash'
while IFS= read -r line; do
  case "$line" in ''|\\*) continue ;; esac   # skip blanks and \ comments
  send_line "$PTY" "$line"
done < "$FW/apps/demo.fs"
sleep 1

qmp_save "$WORK/dict.bin" "$DICT_LEN" "$((0x80000000 + DICT_OFF))" \
  || { echo "FAIL: pmemsave"; kill $CATPID $QPID; exit 1; }
kill $CATPID $QPID 2>/dev/null; wait 2>/dev/null

# ---- dictionary size (last non-zero byte, cell-rounded) ---------------------
DICT_USED=$(python3 - "$WORK/dict.bin" <<'PYEOF'
import sys
d = open(sys.argv[1], "rb").read()
n = len(d)
while n >= 4 and d[n-4:n] == b"\x00\x00\x00\x00":
    n -= 4
print(n)
PYEOF
)
echo "dictionary window: ${DICT_LEN} B, used: ${DICT_USED} B"
[ "$DICT_USED" -gt 0 ] || { echo "FAIL: dictionary empty"; exit 1; }
grep -qi 'not found' "$WORK/console_build.bin" && {
  echo "FAIL: build session had unknown words"; cat -v "$WORK/console_build.bin"; exit 1; }

# ---- merge + cold-boot proof --------------------------------------------------
cp "$WORK/kernel.bin" "$WORK/app.bin"
dd if="$WORK/dict.bin" of="$WORK/app.bin" bs=1 seek="$((DICT_OFF))" \
   conv=notrunc status=none
python3 "$ROOT/tools/bin2hex.py" "$WORK/app.bin" \
  "$BUILD/mecrisp-ssp-qemu-app.hex" 0x10000 0x80000000 >/dev/null
cp "$WORK/app.bin" "$BUILD/mecrisp-ssp-qemu-app.bin"
# dict fragment alone (the piece the stub-SoC flow will regenerate at true
# hardware offsets, and the reproducible-diff artifact for CI):
cp "$WORK/dict.bin" "$BUILD/dict-qemu.bin"
python3 "$ROOT/tools/bin2hex.py" "$WORK/dict.bin" \
  "$BUILD/dict-qemu.hex" "$DICT_LEN" "$DICT_OFF" >/dev/null

timeout 60 qemu-system-riscv32 -M virt -cpu rv32 -m 8 -bios none \
  -kernel "$BUILD/mecrisp-ssp-qemu-app.bin" -display none -no-reboot \
  -serial pty > "$WORK/pty2.log" 2>&1 &
QPID2=$!
PTY2=""
for _ in $(seq 50); do
  PTY2=$(grep -o '/dev/pts/[0-9]*' "$WORK/pty2.log" | head -1)
  [ -n "$PTY2" ] && break; sleep 0.2
done
[ -n "$PTY2" ] || { echo "FAIL: no pty (cold boot)"; kill $QPID2; exit 1; }
cat "$PTY2" > "$WORK/console_cold.bin" & CATPID2=$!
sleep 0.5
send_line "$PTY2" 'cpu-hello'
send_line "$PTY2" '42answer . cr'
send_line "$PTY2" 'reg-id hex. cr'
sleep 1
kill $CATPID2 $QPID2 2>/dev/null; wait 2>/dev/null

rc=0
expect() { grep -q "$1" "$WORK/console_cold.bin" && echo "  ok: /$1/" \
           || { echo "  MISSING: /$1/"; rc=1; }; }
expect 'Hello from the SSP application dictionary'
expect '42answer . cr 42 $'
expect 'reg-id hex. cr 00000000 $'   # qemu virt flash@0x2000_0000 reads 0
grep -qi 'not found' "$WORK/console_cold.bin" && { echo "  FAIL: unknown word at cold boot"; rc=1; }
echo "--- cold console ---"; cat -v "$WORK/console_cold.bin"
[ $rc -eq 0 ] && echo "dictbuild_qemu: PASS" || echo "dictbuild_qemu: FAIL"
exit $rc
