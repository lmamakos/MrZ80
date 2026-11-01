#!/usr/bin/env python3
"""Run the shared disassembler test vectors in Mecrisp-Quintus (QEMU).

Feeds mecrisp-port.fs, ../z80dis.fth (UPPERCASE source, comments stripped as
the SSP dictionary build does) and driver.fth to the SSP firmware's REPL
under qemu-system-riscv32 with `compiletoflash` (so the `0 variable` rule is
tested too), preloads the test image at guest $80100000 and runs DZT.
Writes the result JSON to argv[1].  Needs: make -C ssp/fw qemu.
"""
import json, os, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../..'))
sys.path.insert(0, os.path.join(ROOT, 'tools')); sys.path.insert(0, HERE)
from qforth import QForth
import cases


def source(path):
    for l in open(path).read().split('\n'):
        if l.strip() and not l.lstrip().startswith('\\'):
            yield l.rstrip('\r')


def main(out):
    img = tempfile.NamedTemporaryFile(suffix='.bin', delete=False)
    img.write(cases.image()); img.close()
    q = QForth(loads=[(img.name, 0x80100000)])
    lines = ['compiletoflash']
    for p in ('mecrisp-port.fs', '../z80dis.fth', 'driver.fth'):
        lines += list(source(os.path.join(HERE, p)))
    for l in lines:
        text, ok = q.line(l)
        if not ok:
            sys.exit('harness_mecrisp: line failed: %s\n%s' % (l, text))
    sl = cases.slots()
    res = []
    for i in range(0, len(sl), 64):
        n = min(64, len(sl) - i)
        text, ok = q.line('%d %d DZT' % (cases.BASE + i * 8, n), timeout=120)
        if not ok:
            sys.exit('harness_mecrisp: chunk at slot %d failed:\n%s' % (i, text[-300:]))
        res.append(text)
    depth, _ = q.line('DEPTH .')
    q.close(); os.unlink(img.name)
    json.dump({'env': 'mecrisp', 'chunks': res, 'depth': depth}, open(out, 'w'))
    print('mecrisp: ran %d cases' % len(sl))


main(sys.argv[1])
