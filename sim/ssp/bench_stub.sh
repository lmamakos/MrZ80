#!/usr/bin/env bash
# sim/ssp/bench_stub.sh -- cycle-level performance benchmark for the OQ-20
# bake-off cores on the Verilator stub SoCs (R22).
#
# Measures PRODUCTION-SHAPE execution: resident words in resident loops.
# Dictionary token lookups (interactive/compile-time only; ~10^5 cyc) sit
# outside the timed brackets and cancel; RECURSE is not exercised (rare in
# production Forth -- R22 owner note).
#
# Method: control-byte EMIT markers bracket each timed loop; TXTRACE=1
# timestamps every TX byte (tb_stub_main counts 2 ticks/clock -> all numbers
# reported in CORE CYCLES).  Each loop runs at N1=200000 and N2=100000
# (EQUAL digit counts -> identical line parse cost), so per-iteration core
# cost = (bracket@N1 - bracket@N2) / 100000 with all FW overhead cancelled.
# Markers are control bytes, never 0x0A/0x0D (FW whitespace); decimal EMIT
# args in echoed text are printable digits -- no collisions with echo/"ok.".
#
# Loop ladder (L2..L7 = L1 + body; deltas give the op-level table):
#   L1  0 DO LOOP                 bare DO..LOOP control
#   L2  0 DO N2 LOOP            + near-no-op non-inline subroutine call
#   L3  0 DO I + LOOP           + index fetch + accumulate
#   L4  0 DO I + U1 LOOP        + unit call DUP DUP 7 + + DROP (stack ops+add)
#   L5  0 DO I + U2 LOOP        unit with 7 * instead of 7 +  -> MUL cost
#   L6  0 DO N2 N2 N2 LOOP      3 calls -> marginal call cost x3
#   L7  0 DO I V ! V @ + LOOP   VARIABLE store + retrieve per iteration
#                               (real data RAM traffic; FABWAIT discriminant)
# `variable` ships in Mecrisp compiler-flash.s (excluded by D-32): provided
# via CREATE.  L3/L4/L5/L7 all reduce to sum(0..N-1): golden -1474936480
# (mod 2^32, signed) at N=200000, checked on each `.` verify run.
#
# Lanes: TAG/MODEL per core.  EXTRA="+FABWAIT" on picorv32 models the D-36
# explicit-IP fabric (launch+1 every access incl. fetch); gracilis stub is
# natively launch+1 (rstrb), so picorv32-fab vs gracilis is the
# silicon-predictive pairing.
# +IDLE must exceed the longest silent workload stretch (loops emit no TX).

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
TAG=${TAG:-picorv32}
MODEL=${MODEL:-sim/ssp/obj_dir/ssp_stub}
EXTRA=${EXTRA:-}
HEX=ssp/fw/build/mecrisp-ssp.hex
WORK=/tmp/opencode/stub-bench-$TAG; mkdir -p "$WORK"

[ -x "$MODEL" ] || { echo "FAIL: model missing -- run: make -C sim stub"; exit 1; }
[ -f "$HEX" ]  || { echo "FAIL: FW hex missing -- run: make -C ssp/fw ssp"; exit 1; }

printf ': VARIABLE create 0 , ;\rVARIABLE V\r: N2 ;\r: U1 DUP DUP 7 + + DROP ;\r: U2 DUP DUP 7 * + DROP ;\r: L1 0 SWAP 0 DO LOOP ;\r: L2 0 SWAP 0 DO N2 LOOP ;\r: L3 0 SWAP 0 DO I + LOOP ;\r: L4 0 SWAP 0 DO I + U1 LOOP ;\r: L5 0 SWAP 0 DO I + U2 LOOP ;\r: L6 0 SWAP 0 DO N2 N2 N2 LOOP ;\r: L7 0 SWAP 0 DO I V ! V @ + LOOP ;\r1 EMIT 200000 L1 2 EMIT\r3 EMIT 100000 L1 4 EMIT\r5 EMIT 200000 L2 6 EMIT\r7 EMIT 100000 L2 8 EMIT\r9 EMIT 200000 L3 11 EMIT\r12 EMIT 100000 L3 14 EMIT\r15 EMIT 200000 L4 16 EMIT\r17 EMIT 100000 L4 18 EMIT\r19 EMIT 200000 L5 20 EMIT\r21 EMIT 100000 L5 22 EMIT\r23 EMIT 200000 L6 24 EMIT\r25 EMIT 100000 L6 26 EMIT\r27 EMIT 200000 L7 28 EMIT\r29 EMIT 100000 L7 30 EMIT\r200000 L2 . CR\r200000 L3 . CR\r200000 L4 . CR\r200000 L5 . CR\r200000 L7 . CR\r' \
  | TXTRACE=1 timeout 900 "$MODEL" +ROM="$HEX" +IDLE=100000000 +MAXCYCLES=1000000000 $EXTRA \
  > "$WORK/console.log" 2> "$WORK/info.log"
rc=$?
[ $rc -eq 0 ] || { echo "FAIL: harness exit $rc"; tail -2 "$WORK/info.log"; exit 1; }

fail=0
n_ok=$(grep -o 'ok\.' "$WORK/console.log" | wc -l)
[ "$n_ok" -eq 31 ] || { echo "  MISSING: 31 ok prompts (got $n_ok)"; fail=1; }
n_sum=$(grep -c -- '-1474936480' "$WORK/console.log")
[ "$n_sum" -eq 4 ] || { echo "  MISSING: sum golden -1474936480 x4 (got $n_sum)"; fail=1; }
[ $fail -eq 0 ] || { echo "bench_stub($TAG): FAIL"; tail -5 "$WORK/console.log"; exit 1; }

python3 - "$TAG" "$WORK" <<'PY'
import re, sys
tag, work = sys.argv[1], sys.argv[2]
log = open(f'{work}/info.log').read()
tx  = [(int(m.group(2)), int(m.group(1), 16))
       for m in re.finditer(r'TX c=([0-9a-f]{2}) cyc=(\d+)', log)]
cyc = {}
for c, b in tx:
    cyc.setdefault(b, c)                      # first occurrence per marker byte
need = list(range(1, 9)) + [9, 11, 12, 14, 15, 16, 17, 18, 19, 20,
                             21, 22, 23, 24, 25, 26, 27, 28, 29, 30]
missing = [f'{m:02x}' for m in need if m not in cyc]
if missing:
    print(f'FAIL: markers missing from TX trace: {missing}'); sys.exit(1)

# ticks -> core cycles (tb_stub_main: g_cycle += 2 per clock)
def d(a, b): return (cyc[b] - cyc[a]) // 2

N1, N2, DN = 200_000, 100_000, 100_000
pairs = {'L1': (1, 2, 3, 4), 'L2': (5, 6, 7, 8), 'L3': (9, 11, 12, 14),
         'L4': (15, 16, 17, 18), 'L5': (19, 20, 21, 22),
         'L6': (23, 24, 25, 26), 'L7': (27, 28, 29, 30)}
cpi = {k: (d(a, b) - d(c, e)) / DN for k, (a, b, c, e) in pairs.items()}
cost = {'bare loop':      cpi['L1'],
        'call (per call)': cpi['L2'] - cpi['L1'],
        'call x3 check':  (cpi['L6'] - cpi['L1']) / 3,
        'I + add':         cpi['L3'] - cpi['L1'],
        'unit(DUP/DROP+add)': cpi['L4'] - cpi['L3'],
        'mul vs add':      cpi['L5'] - cpi['L4'],
        'var st+ld':       cpi['L7'] - cpi['L3']}
boot  = tx[0][0] // 2
total = int(re.search(r'cycles=(\d+)', log).group(1)) // 2

print(f'bench_stub({tag}): PASS')
print(f'  boot -> first TX : {boot:>12,} cyc')
for k in ('bare loop', 'call (per call)', 'call x3 check', 'I + add',
          'unit(DUP/DROP+add)', 'mul vs add', 'var st+ld'):
    print(f'  {k:19s}: {cost[k]:8.2f} cyc/iter')
print('  loop cyc/iter    : ' + '  '.join(f'{k}={v:.1f}' for k, v in cpi.items()))
print(f'  total run        : {total:>12,} cyc')

with open(f'{work}/bench-{tag}.tsv', 'w') as f:
    f.write('bench\tcyc_per_iter\n')
    f.write(f'boot_first_tx\t{boot}\n')
    for k, v in cost.items(): f.write(f'{k}\t{v:.3f}\n')
    for k, v in cpi.items():  f.write(f'{k}_cpi\t{v:.3f}\n')
    f.write(f'total_run\t{total}\n')
PY
