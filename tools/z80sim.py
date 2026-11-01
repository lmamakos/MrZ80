#!/usr/bin/env python3
"""Run a bare-metal Z-80 program (the bootable CamelFORTH kernel) in the
`z80` Python emulator, with the MrZ80 console and RAM-disk ports modelled.

Needs the emulator package:   pip install --user z80
(It is a *stock* Z-80: kernels built with CUSTNEXT/CUSTRSP use the custom
ED opcodes and will NOT run here -- build the plain bootable kernel.  Use
sim/run_forth.sh (GHDL, real T80) when the custom instructions matter.)

Modelled hardware (see forth/io-multi.azm, HARDWARE.md):
  port 82h  console status: bit0 = RX byte ready, bit1 = TX ready (always)
  port 83h  console data
  B8h..BBh  MMU direct-access pointer, bytes 0..3, little-endian
  BCh       direct-access data port, pointer post-increments
The RAM disk (FORTH blocks) is the --blk file placed at physical --rd-base
(default 0x07800000, the address io-multi.azm uses), so the kernel's own
LOAD / BLOCK / read-file words work unchanged.  64 KB of flat RAM.

Command line:
  tools/z80sim.py [--bin FILE | --build] [--blk forth.blk] [-f FILE]... [-e LINE]...
    --build   assemble forth/camel80.azm (-D BOOTABLE=1) into a scratch dir
    -e LINE   send LINE (+CR) to the console       (repeatable)
    -f FILE   send each line of FILE               (repeatable)
              (-e and -f are sent in command-line order)
    --echo    print the whole transcript (default: only output after boot)
  e.g.  tools/z80sim.py --build --blk forth/blocks/forth.blk \\
            -e '0 LOAD' -e '1 LOAD' -e 'blocks' -e '30 49 THRU'

As a library (tools/ on sys.path):
  from z80sim import Z80Forth
  f = Z80Forth('forth/camel80.bin', blk='forth/blocks/forth.blk')
  out = f.send('1 2 + .')           # -> text the line produced
  f.poke(0x9000, b'\\xf3\\xc3'); f.peek(0x9000, 2)
"""
import argparse, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RD_BASE = 0x07800000


class Z80Forth:
    def __init__(self, binfile, blk=None, rd_base=RD_BASE, ram=None):
        try:
            import z80
        except ImportError:
            sys.exit("z80sim: the 'z80' package is missing: pip install --user z80")
        self.m = z80.Z80Machine()
        img = open(binfile, 'rb').read()
        self.m.set_memory_block(0, img)
        self.rd_base = rd_base
        self.blk = bytearray(open(blk, 'rb').read()) if blk else bytearray()
        self.ptr = [0, 0, 0, 0]
        self.inq = bytearray()
        self.out = bytearray()
        self.idle = 0
        self.m.set_input_callback(self._in)
        self.m.set_output_callback(self._out)
        self.settle()                       # boot banner + first prompt

    # ---- I/O model ---------------------------------------------------
    def _p(self):
        return self.ptr[0] | self.ptr[1] << 8 | self.ptr[2] << 16 | self.ptr[3] << 24

    def _setp(self, v):
        for i in range(4):
            self.ptr[i] = (v >> (8 * i)) & 255

    def _in(self, port):
        p = port & 0xFF
        if p == 0x82:
            if not self.inq:
                self.idle += 1
            return (1 if self.inq else 0) | 2
        if p == 0x83:
            return self.inq.pop(0) if self.inq else 0
        if p == 0xBC:
            a = self._p() - self.rd_base
            self._setp(self._p() + 1)
            return self.blk[a] if 0 <= a < len(self.blk) else 0xFF
        return 0xFF

    def _out(self, port, v):
        p = port & 0xFF
        if p == 0x83:
            self.out.append(v)
            self.idle = 0                   # TX also polls 82h: not "idle"
        elif 0xB8 <= p <= 0xBB:
            self.ptr[p - 0xB8] = v
        elif p == 0xBC:
            a = self._p() - self.rd_base
            self._setp(self._p() + 1)
            if 0 <= a < len(self.blk):
                self.blk[a] = v

    # ---- driving -----------------------------------------------------
    def settle(self, chunk=100000, limit=6000, quiet_polls=300):
        """Run until the kernel is waiting for input.  Returns the number
        of chunks used, or -1 if it never went idle (hung / crashed /
        still running a long word)."""
        self.idle = 0
        for i in range(limit):
            self.m.ticks_to_stop = chunk
            self.m.run()
            if not self.inq and self.idle > quiet_polls:
                return i
        return -1

    def send(self, line):
        """Type LINE + CR; return (text, settled_ok)."""
        n = len(self.out)
        self.inq.extend(line.encode() + b'\r')
        ok = self.settle() >= 0
        return bytes(self.out[n:]).decode('latin1').replace('\r', ''), ok

    def peek(self, addr, n=1):
        return bytes(self.m.memory[addr:addr + n])

    def poke(self, addr, data):
        self.m.set_memory_block(addr, bytes(data))


def build_kernel():
    d = tempfile.mkdtemp(prefix='z80sim-')
    for f in os.listdir(os.path.join(ROOT, 'forth')):
        if f.endswith('.azm'):
            with open(os.path.join(ROOT, 'forth', f), 'rb') as s, open(os.path.join(d, f), 'wb') as t:
                t.write(s.read())
    t = os.path.join(ROOT, 'tools')
    subprocess.run([f'{t}/um80.sh', 'camel80.azm', '-D', 'BOOTABLE=1', '-g', '-o', 'k.rel',
                    '-l', 'k.prn'], cwd=d, check=True, stdout=subprocess.DEVNULL)
    subprocess.run([f'{t}/ul80.sh', '-p', '0', '-x', '-o', 'k.hex', 'k.rel'], cwd=d,
                   check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['objcopy', '-I', 'ihex', '-O', 'binary', 'k.hex', 'k.bin'], cwd=d, check=True)
    return os.path.join(d, 'k.bin')


class Seq(argparse.Action):
    def __call__(self, parser, ns, values, option_string=None):
        getattr(ns, self.dest).append((option_string, values))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--bin', help='bootable kernel binary (ORG 0)')
    ap.add_argument('--build', action='store_true', help='assemble forth/camel80.azm first')
    ap.add_argument('--blk', help='FORTH block file (the RAM disk), e.g. forth/blocks/forth.blk')
    ap.add_argument('--rd-base', type=lambda s: int(s, 0), default=RD_BASE)
    ap.add_argument('-e', dest='todo', action=Seq, default=[], metavar='LINE')
    ap.add_argument('-f', dest='todo', action=Seq, default=[], metavar='FILE')
    ap.add_argument('--echo', action='store_true', help='include the boot banner')
    a = ap.parse_args()
    if not a.bin and not a.build:
        ap.error('give --bin FILE or --build')
    binfile = build_kernel() if a.build else a.bin
    f = Z80Forth(binfile, a.blk, a.rd_base)
    if a.echo:
        sys.stdout.write(bytes(f.out).decode('latin1').replace('\r', ''))
    todo = []
    for kind, v in a.todo:                   # command-line order is kept
        todo += [v] if kind == '-e' else open(v).read().split('\n')[:-1]
    rc = 0
    for l in todo:
        text, ok = f.send(l)
        sys.stdout.write(text)
        if not ok:
            print('\nz80sim: no prompt after %r (hung, crashed or still running)' % l,
                  file=sys.stderr)
            rc = 2
            break
    sys.stdout.write('\n')
    return rc


if __name__ == '__main__':
    sys.exit(main())
