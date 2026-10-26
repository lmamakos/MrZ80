#!/bin/bash
# sim/ssp/smoke_qemu.sh -- Mecrisp SSP firmware REPL smoke test on
# qemu-system-riscv32 (RV side of D-28 level 1's little brother: the same
# FW image family, console via the ns16550 variant; needs no RTL).
#
# Input is paced byte-by-byte: qemu feeds a pipe/pty burst into the ns16550
# RX FIFO faster than any plausible UART link, and unpaced input overruns
# the FIFO (observed: head-of-line bytes lost at 44-byte lines). A real
# SNAC link is self-paced by baud.
#
# Exit 0 = all expected strings seen on the console.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ELF=$ROOT/ssp/fw/build/mecrisp-ssp-qemu.elf
WORK=/tmp/opencode/ssp-smoke
mkdir -p "$WORK"

[ -f "$ELF" ] || make -C "$ROOT/ssp/fw" qemu >/dev/null || { echo "FAIL: build"; exit 1; }
command -v timeout >/dev/null || { echo "FAIL: need timeout"; exit 1; }

rm -f "$WORK/pty.log" "$WORK/console.bin"
timeout 40 qemu-system-riscv32 -M virt -cpu rv32 -m 8 -bios none \
  -kernel "$ELF" -display none -no-reboot -serial pty \
  > "$WORK/pty.log" 2>&1 &
QPID=$!

P=""
for _ in $(seq 40); do
  P=$(grep -o '/dev/pts/[0-9]*' "$WORK/pty.log" 2>/dev/null | head -1)
  [ -n "$P" ] && break
  sleep 0.2
done
[ -n "$P" ] || { echo "FAIL: no pty from qemu"; kill $QPID 2>/dev/null; exit 1; }

cat "$P" > "$WORK/console.bin" &
CATPID=$!
sleep 0.5

send_line() {
  local line=$1 i
  for ((i = 0; i < ${#line}; i++)); do
    printf '%s' "${line:$i:1}" > "$P"
    sleep 0.03
  done
  printf '\r' > "$P"
  sleep 0.7
}

send_line '1 2 + . cr'
send_line ': sq dup * ; 5 sq . cr'
send_line 'hex FF . cr decimal'

sleep 1
kill $CATPID 2>/dev/null
kill $QPID 2>/dev/null
wait 2>/dev/null

rc=0
expect() {
  if grep -q "$1" "$WORK/console.bin"; then
    echo "  ok: seen /$1/"
  else
    echo "  MISSING: /$1/"
    rc=1
  fi
}
# Banner is informational: the reader can attach after qemu already printed
# it; correct REPL responses below already prove boot + dictionary scan ran.
if grep -q 'Mecrisp-Quintus' "$WORK/console.bin"; then
  echo "  ok: seen /Mecrisp-Quintus/"
else
  echo "  note: banner missed (reader attached late) -- not fatal"
fi
expect '1 2 + . cr 3 $'                 # arithmetic + number output
expect '5 sq . cr 25 $'                 # colon definition + HW multiply
expect 'hex FF . cr decimal FF $'      # hex mode + numeric radix words
echo "--- console ---"
cat -v "$WORK/console.bin"
[ $rc -eq 0 ] && echo "smoke_qemu: PASS" || echo "smoke_qemu: FAIL"
exit $rc
