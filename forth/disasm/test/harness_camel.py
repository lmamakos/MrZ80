#!/usr/bin/env python3
"""Run the shared disassembler test vectors in CamelFORTH (Z-80 emulator).

Boots the stock bootable kernel with forth/blocks/forth.blk as the RAM disk,
loads the generated disassembler blocks exactly as a user does
(0 LOAD  1 LOAD  blocks  30 49 THRU), then runs driver.fth's DZT over the
test image.  Writes the decoded result to the JSON file given as argv[1].
Needs: pip install --user z80;  make -C forth/blocks   (builds forth.blk).
"""
import json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../..'))
sys.path.insert(0, os.path.join(ROOT, 'tools')); sys.path.insert(0, HERE)
from z80sim import Z80Forth, build_kernel
import cases


def main(out):
    blk = os.path.join(ROOT, 'forth/blocks/forth.blk')
    if not os.path.exists(blk):
        sys.exit('harness_camel: %s missing -- run make -C forth/blocks' % blk)
    f = Z80Forth(build_kernel(), blk=blk)
    for cmd in ('0 LOAD', '1 LOAD', 'blocks', '30 49 THRU'):
        text, ok = f.send(cmd)
        if not ok or '?' in text.split('\n')[-2:][0] + text.split('\n')[-1]:
            sys.exit('harness_camel: %r failed:\n%s' % (cmd, text[-300:]))
    for l in open(os.path.join(HERE, 'driver.fth')).read().split('\n'):
        if l.strip() and not l.lstrip().startswith('\\'):
            text, ok = f.send(l)
            if not ok or '?' in text:
                sys.exit('harness_camel: driver line failed: %s\n%s' % (l, text))
    sl = cases.slots()
    f.poke(cases.BASE, cases.image())
    res = []
    for i in range(0, len(sl), 64):
        n = min(64, len(sl) - i)
        text, ok = f.send('%d %d DZT' % (cases.BASE + i * 8, n))
        if not ok:
            sys.exit('harness_camel: hang in chunk at slot %d' % i)
        res.append(text)
    depth, _ = f.send('DEPTH .')
    json.dump({'env': 'camel', 'chunks': res, 'depth': depth}, open(out, 'w'))
    print('camel: ran %d cases' % len(sl))


main(sys.argv[1])
