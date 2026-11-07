#!/usr/bin/env python3
"""Emulator regression for the CamelFORTH Life game (blocks 50-55).

Usage:  forth/life/life_check.py       (run `make -C forth/blocks` first)

Loads the blocks into the stock kernel under tools/z80sim.py after the usual
startup set (editor, SEE, ...), then checks the game against a Python
reference Life on the same 64x64 torus: the packed board (16 cells per word)
and the Dazzler window bytes (nibble + quadrant layout).  The sim has no Dazzler: write-snoop and the screen are hardware.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
from z80sim import Z80Forth, build_kernel   # noqa: E402

ERR = re.compile(r'\S+\?\s*$|\n\S+\?( |$)', re.M)

f = Z80Forth(build_kernel(), blk=os.path.join(ROOT, 'forth/blocks/forth.blk'))
_settle = f.settle
f.settle = lambda: _settle(limit=60000)
fails = []


def send(c, strict=True):
    t, ok = f.send(c)
    err = (not ok) or (c not in t) or (
        strict and bool(ERR.search(t[t.index(c) + len(c):])))
    if err:
        print('FAIL on [%s]: %r' % (c, t[-160:]))
        fails.append(c)
    return not err


def number(expr):
    t, _ = f.send('DECIMAL ' + expr + ' .')
    return int(t.split()[-2])


# --- load: the editor/SEE set first, as on the real machine -------------
for c in ['0 LOAD', '1 LOAD', 'blocks', 'editor', 'screen', 'see', '25 LOAD']:
    assert send(c, strict=False), c
assert send('DECIMAL', strict=False)
before = number('HERE')
assert send('50 55 THRU', strict=False), 'load'
WIN = number('WIN')
top = number('HERE')
print('dictionary $%04X -> $%04X; WIN $%04X' % (before, top, WIN))
assert WIN % 512 == 0 and top < 0x7D00, 'memory layout'


def board():
    return number('CUR @')


def cells():
    base = board()
    raw = f.peek(base, 512)
    live = set()
    for i in range(256):
        w = raw[2 * i] | raw[2 * i + 1] << 8
        for b in range(16):
            if w >> b & 1:
                live.add((((i & 3) << 4) + b, i >> 2))
    return live


def window_ref(live):
    w = bytearray(2048)
    for (x, y) in live:
        off = (y >> 5) * 1024 + ((x >> 5) & 1) * 512 + (y & 31) * 16 + ((x & 31) >> 1)
        w[off] |= 0xA0 if x & 1 else 0x0A
    return bytes(w)


def step(c):
    n = {}
    for (x, y) in c:
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if dx or dy:
                    k = ((x + dx) & 63, (y + dy) & 63)
                    n[k] = n.get(k, 0) + 1
    return {k for k, v in n.items() if v == 3 or (v == 2 and k in c)}


def check(live, what):
    assert cells() == live, what + ': cells'
    assert f.peek(WIN, 2048) == window_ref(live), what + ': window bytes'


def ticks_of(line):
    f.inq.extend(line.encode() + b'\r')
    f.idle = 0
    n = 0
    while True:
        f.m.ticks_to_stop = 100000
        f.m.run()
        n += 1
        if not f.inq and f.idle > 300:
            return n * 100000


assert send('DZ-INIT')
check(set(), 'after DZ-INIT')
assert send('20 20 PLANTAT')
check({(20, 20)}, 'one cell')
assert send('1 RUN')
check(set(), 'lone cell dies')
print('PLANT/DIE OK')

# blinker, then a glider across the torus seam, compared every generation
assert send('DZ-INIT')
glider = {(61, 62), (62, 62), (63, 62), (61, 63), (62, 0)}
for (x, y) in sorted(glider):
    assert send('%d %d PLANTAT' % (x, y))
ref = set(glider)
check(ref, 'glider start')
for g in range(1, 13):
    assert send('1 RUN')
    ref = step(ref)
    check(ref, 'glider gen %d' % g)
print('GLIDER ACROSS TORUS SEAM OK (12 gens)')

# random soup: exact cell count, then 20 generations vs the reference
assert send('DZ-INIT') and send('4321 SEED') and send('1200 SPARK')
ref = cells()
assert len(ref) == 1200, 'SPARK count %d' % len(ref)
check(ref, 'soup start')
for g in range(1, 21):
    assert send('1 RUN')
    ref = step(ref)
    check(ref, 'soup gen %d' % g)
print('SOUP 1200 CELLS, 20 GENS MATCH REFERENCE')

# a dense soup and a full board (every cell born, then all die)
assert send('DZ-INIT') and send('77 SEED') and send('3000 SPARK')
ref = cells()
assert len(ref) == 3000
for g in range(1, 6):
    assert send('1 RUN')
    ref = step(ref)
    check(ref, 'dense gen %d' % g)
assert send('DZ-INIT') and send('5000 SPARK')
assert len(cells()) == 4096, 'SPARK caps at 4096'
check(cells(), 'full board')
assert send('1 RUN')
check(set(), 'full board dies')
print('DENSE SOUP / FULL BOARD OK')

# n RUN runs exactly n generations; seeds reproduce; 0 SPARK plants nothing
assert send('DZ-INIT') and send('4321 SEED') and send('1200 SPARK')
ref = cells()
assert send('5 RUN')
for _ in range(5):
    ref = step(ref)
check(ref, '5 RUN')
assert send('DZ-INIT') and send('9 SEED') and send('50 SPARK')
a = cells()
assert send('DZ-INIT') and send('9 SEED') and send('50 SPARK')
assert a == cells() and len(a) == 50, 'seed reproducibility'
assert send('DZ-INIT') and send('0 SPARK') and not cells()
print('RUN COUNT / SEED REPRODUCIBLE / 0 SPARK OK')

# speed (stock kernel; the hardware kernel with custom NEXT is faster)
assert send('DZ-INIT') and send('4321 SEED') and send('1200 SPARK')
t = [ticks_of('1 RUN') for _ in range(3)]
assert send('DZ-INIT') and send('4321 SEED') and send('1200 SPARK') and send('60 RUN')
late = ticks_of('1 RUN')
print('T-states per generation: soup gen 1-3 %s ..., after 60 gens %d'
      % ([x // 1000000 for x in t], late // 1000000), '(millions, incl. idle polls)')

# LIFE! runs until a key, then returns to the prompt
assert send('DZ-INIT')
n = len(f.out)
f.inq.extend(b'100 1234 LIFE!\r')
for _ in range(300):
    f.m.ticks_to_stop = 100000
    f.m.run()
f.inq.extend(b'x')
assert f.settle() >= 0 and bytes(f.out[n:]).rstrip().endswith(b'ok'), bytes(f.out[n:])[-40:]
print('LIFE! RUNS AND STOPS ON KEY OK')

assert number('DEPTH') == 0, 'data stack not clean'
print('DATA STACK CLEAN')

if fails:
    sys.exit('FAILED: ' + ' | '.join(fails))
print('ALL TESTS PASS')
