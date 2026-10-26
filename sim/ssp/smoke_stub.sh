#!/usr/bin/env bash
# sim/ssp/smoke_stub.sh -- RV-side REPL smoke on the Verilator stub SoC.
# The picorv32 twin of smoke_qemu.sh: boots the hardware-map FW image
# (rom@0, dtcm@0x1000_0000, bridge@0x2000_0000) and drives the REPL over
# the modelled console UART.  The bridge ID read-back ($2000_0000 @ ->
# 4D525A03) is the proof the stub's register decode matches ssp_regs.csv.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
TAG=${TAG:-picorv32}
MODEL=${MODEL:-sim/ssp/obj_dir/ssp_stub}
HEX=ssp/fw/build/mecrisp-ssp.hex
WORK=/tmp/opencode/stub-smoke-$TAG; mkdir -p "$WORK"

[ -x "$MODEL" ] || { echo "FAIL: model missing -- run: make -C sim stub"; exit 1; }
[ -f "$HEX" ]  || { echo "FAIL: FW hex missing -- run: make -C ssp/fw ssp"; exit 1; }

printf '1 2 + . cr\r: sq dup * ; 5 sq . cr\r$20000000 @ hex. cr\r' \
  | timeout 120 "$MODEL" +ROM="$HEX" +IDLE=2000000 \
  > "$WORK/console.log" 2> "$WORK/info.log"
rc=$?

echo "--- console ---"; cat "$WORK/console.log"
[ $rc -eq 0 ] || { echo "FAIL: harness exit $rc"; tail -2 "$WORK/info.log"; exit 1; }

norm=$(tr '\r' '\n' < "$WORK/console.log" | tr 'A-Z' 'a-z')
fail=0
check() { # $1 = description, $2 = grep -E pattern applied to normalized console
  if echo "$norm" | grep -Eq "$2"; then echo "  ok: $1"; else
    echo "  MISSING: $1 (/$2/)"; fail=1; fi; }
# Console format: FW echoes the line, replies on the same line (". " emits
# leading space; `cr` emits LF), then " ok." on its own line.
check "banner"            'mecrisp-quintus .*ssp core'
check "arithmetic (3)"    '^1 2 \+ \. cr 3 *$'
check "word def + call (25)" '^: sq dup \* ; 5 sq \. cr 25 *$'
check "bridge ID read (4D525A03)" '^[$]20000000 @ hex\. cr 4d525a03 *$'
n_ok=$(echo "$norm" | grep -c '^ ok\.$')
[ "$n_ok" -eq 3 ] && echo "  ok: three ok prompts" \
  || { echo "  FAIL: expected 3 'ok.' prompts, got $n_ok"; fail=1; }
echo "$norm" | grep -qi 'not found' && { echo "  FAIL: unknown word"; fail=1; }
grep -E 'trap=1|bus_errs=[1-9]|rom_core_writes=[1-9]' "$WORK/info.log" \
  && { echo "  FAIL: stub diagnostics flagged"; fail=1; }

[ $fail -eq 0 ] && echo "smoke_stub($TAG): PASS" || echo "smoke_stub($TAG): FAIL"
exit $fail
