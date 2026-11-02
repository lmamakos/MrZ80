#!/usr/bin/env python3
"""Drive the Mecrisp-Quintus REPL of the SSP firmware under QEMU.

Quick way to test RISC-V Forth code (the SSP debugger/monitor dictionary)
without the Verilator lane.  The qemu image (`make -C ssp/fw qemu`) is the
SAME Mecrisp kernel and source files as the silicon image, but with an
ns16550 console and everything in DRAM.  What it does NOT have: the SSP
bridge registers (SSP_*), the Z-80, the 4.3k-cycles-per-byte UART timing
or the MROM/dictionary windows.  Anything touching SSP_* must be tested on
the Verilator p1a lane (make -C sim p1a dict-rtl smoke-p1a, AGENTS.md).

Input is paced one byte at a time, waiting for the kernel's echo: qemu
delivers a burst into the 16-byte ns16550 FIFO faster than Mecrisp drains
it, and unpaced input silently loses characters (sim/ssp/smoke_qemu.sh).

Command line (lines are sent in command-line order):
  tools/qforth.py [--build] [--elf FILE] [--load FILE@ADDR]... [--strip]
                  [-e LINE]... [-f FILE]... [--check]
    --build         run `make -C ssp/fw qemu` first
    --load F@ADDR   preload binary F into guest RAM at ADDR (hex ok).  The
                    guest has 8 MB at 0x80000000; Forth uses the first
                    192 KB, so 0x80100000 and up is free for test data
    -e LINE         send LINE
    -f FILE         send each line of FILE
    --strip         drop blank lines and full-line `\\` comments from -f
                    files (what sim/ssp/dictbuild.sh does)
    --check         exit 1 if any line ended without `ok.` (an error such
                    as `foo not found.` or `Stack underflow`)
  e.g.  tools/qforth.py --build -e ': sq dup * ;' -e '7 sq .'

As a library (tools/ on sys.path):
  from qforth import QForth
  q = QForth(loads=[('/tmp/img.bin', 0x80100000)])
  out, ok = q.line('$80100000 c@ .')
  q.close()
"""
import argparse, os, re, select, subprocess, sys, termios, time, pty

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ELF = os.path.join(ROOT, 'ssp/fw/build/mecrisp-ssp-qemu.elf')


class QForth:
    def __init__(self, elf=ELF, loads=(), boot_timeout=10):
        if not os.path.exists(elf):
            sys.exit('qforth: %s missing -- run: make -C ssp/fw qemu  (or --build)' % elf)
        cmd = ['qemu-system-riscv32', '-M', 'virt', '-cpu', 'rv32', '-m', '8', '-bios', 'none',
               '-kernel', elf, '-display', 'none', '-no-reboot', '-serial', 'pty']
        for path, addr in loads:
            cmd += ['-device', 'loader,file=%s,addr=0x%x,force-raw=on' % (path, addr)]
        self.p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        m = re.search(r'/dev/pts/\d+', self.p.stdout.readline())
        if not m:
            sys.exit('qforth: qemu did not report a pty')
        self.fd = os.open(m.group(0), os.O_RDWR | os.O_NOCTTY)
        a = termios.tcgetattr(self.fd)
        a[0] &= ~(termios.ICRNL | termios.INLCR | termios.IGNCR | termios.IXON)
        a[1] &= ~termios.OPOST
        a[3] &= ~(termios.ECHO | termios.ICANON | termios.ISIG)
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        self.banner = self._read_until_ok(boot_timeout)[0]

    def _read(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return b''
        try:
            return os.read(self.fd, 4096)
        except OSError:
            return b''

    def _read_until_ok(self, timeout, quiet=0.4):
        """Read until the line ends in `ok.`; an error leaves no `ok.`, so
        also stop once the kernel has been silent for `quiet` seconds."""
        buf, end, last = b'', time.time() + timeout, time.time()
        while time.time() < end:
            d = self._read(0.05)
            if d:
                buf += d
                last = time.time()
                if buf.rstrip().endswith(b'ok.'):
                    return buf.decode('latin1').replace('\r', ''), True
            elif buf and time.time() - last > quiet:
                break
        return buf.decode('latin1').replace('\r', ''), False

    def line(self, text, timeout=30):
        """Send TEXT + CR, paced by the kernel's echo.  Returns (output,
        ok) where ok means the line finished with `ok.`."""
        out = b''
        for ch in text.encode():
            os.write(self.fd, bytes([ch]))
            got, end = b'', time.time() + 2
            while not got and time.time() < end:
                got = self._read(0.01)
            out += got
        os.write(self.fd, b'\r')
        rest, ok = self._read_until_ok(timeout)
        return out.decode('latin1').replace('\r', '') + rest, ok

    def close(self):
        self.p.kill()
        os.close(self.fd)


class Seq(argparse.Action):
    def __call__(self, parser, ns, values, option_string=None):
        getattr(ns, self.dest).append((option_string, values))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--build', action='store_true')
    ap.add_argument('--elf', default=ELF)
    ap.add_argument('--load', action='append', default=[], metavar='FILE@ADDR')
    ap.add_argument('--strip', action='store_true')
    ap.add_argument('--check', action='store_true')
    ap.add_argument('-e', dest='todo', action=Seq, default=[], metavar='LINE')
    ap.add_argument('-f', dest='todo', action=Seq, default=[], metavar='FILE')
    a = ap.parse_args()
    if a.build:
        subprocess.run(['make', '-C', os.path.join(ROOT, 'ssp/fw'), 'qemu'], check=True,
                       stdout=subprocess.DEVNULL)
    loads = []
    for s in a.load:
        f, _, ad = s.rpartition('@')
        loads.append((f, int(ad, 0)))
    lines = []
    for kind, v in a.todo:
        if kind == '-e':
            lines.append(v)
        else:
            for l in open(v).read().split('\n'):
                if a.strip and (not l.strip() or l.lstrip().startswith('\\')):
                    continue
                lines.append(l.rstrip('\r'))
    q = QForth(a.elf, loads)
    bad = 0
    for l in lines:
        out, ok = q.line(l)
        sys.stdout.write(out if out.endswith('\n') else out + '\n')
        if not ok:
            bad += 1
            print('qforth: no `ok.` after: %s' % l, file=sys.stderr)
    q.close()
    return 1 if (a.check and bad) else 0


if __name__ == '__main__':
    sys.exit(main())
