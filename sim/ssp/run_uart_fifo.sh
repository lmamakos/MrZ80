#!/usr/bin/env bash
# sim/ssp/run_uart_fifo.sh -- ssp_uart RX FIFO unit bench (tb_uart_fifo.v) at
# depth 8 (the pre-R29 size, regression) and 128 (D-41 default).  iverilog.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
WORK=/tmp/opencode/uart-fifo; mkdir -p "$WORK"
fail=0
for L in 3 7; do
  iverilog -g2012 -Wall -Ptb_uart_fifo.L=$L -o "$WORK/tb_$L.vvp" \
      sim/ssp/tb_uart_fifo.v ssp/rtl/ssp_uart.v 2> "$WORK/iverilog_$L.log" \
    || { echo "FAIL: iverilog compile (L=$L)"; cat "$WORK/iverilog_$L.log"; exit 1; }
  vvp "$WORK/tb_$L.vvp" > "$WORK/run_$L.log" 2>&1
  grep -E "FAIL|PASS" "$WORK/run_$L.log" | head -6
  grep -q "tb_uart_fifo: PASS" "$WORK/run_$L.log" || fail=1
done
[ $fail -eq 0 ] && echo "uart-fifo: PASS" || echo "uart-fifo: FAIL"
exit $fail
