#!/usr/bin/env python3
"""ssp_image.py -- build an SSP monitor ROM image that the OSD can mount.

Builds the Mecrisp kernel + the monitor dictionary (ssp/fw/apps/monitor.fs)
into the 128 KiB MROM image the OSD "SSP Monitor ROM" item loads (.MRZ).

  tools/ssp_image.py                 check + build -> ssp/fw/build/mrz80-ssp.mrz
  tools/ssp_image.py --check         only the quick qemu compile check (~5 s)
  tools/ssp_image.py -o /tmp/t.mrz   write the image somewhere else
  tools/ssp_image.py --install       also scp it to the MiSTer (see --dest)

Two stages:

  1. Compile check (qemu, seconds).  The qemu variant of the firmware (the
     same Mecrisp kernel, ns16550 console, `make -C ssp/fw qemu`) gets
     `compiletoflash` and the monitor source through tools/qforth.py.  Any
     line that does not end in `ok.` (unknown word, stack error, ...) stops
     the run before the slow stage.  It cannot catch what depends on the SSP
     registers or timing, and its dictionary is NOT usable on the board: it
     is linked at the qemu addresses (0x8000_5000, DRAM at 0x8002_0000), the
     board's are 0x5000 and 0x1000_0000, and absolute links and variable
     addresses are baked into the dictionary.

  2. Image build (Verilator p1a model, ~3-4 minutes).  The same
     sim/ssp/dictbuild.sh `make -C sim dict-rtl` runs: the monitor is
     typed into the real ssp_top RTL at hardware addresses, the ROM is
     dumped and merged with the kernel, and the result is booted once to
     prove the words are resident.  That image is what is copied to -o.

Exit status: 0 image built and verified; 1 failure; 3 image built but the
final cold-boot check failed (the image is still written, marked unverified,
useful when you have changed the banner or the E command).
"""
import argparse
import os
import re
import shlex
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))

FW = os.path.join(ROOT, 'ssp/fw')
APP = os.path.join(FW, 'apps/monitor.fs')
REGS = os.path.join(FW, 'ssp-regs.fs')
BUILT = os.path.join(FW, 'build/mecrisp-ssp-app.bin')    # dictbuild.sh output
DEFAULT_OUT = os.path.join(FW, 'build/mrz80-ssp.mrz')
DEFAULT_DEST = 'mister:/media/fat/games/MrZ80/mrz80-ssp.mrz'  # as `make -C sim mrom-install`
ROM_LEN = 0x20000
LOG = '/tmp/opencode/ssp_image.log'


def say(msg):
    print(msg, flush=True)


def run_quiet(cmd, what, tail=25):
    """Run CMD, keeping its output; show the tail only on failure."""
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        say('FAIL: %s' % what)
        say('\n'.join(r.stdout.splitlines()[-tail:]))
        sys.exit(1)
    return r.stdout


def compile_check():
    from qforth import QForth
    from ssp_appsrc import build_lines
    t0 = time.time()
    say('[check] qemu compile check of %s' % os.path.relpath(APP, ROOT))
    lines, nconst = build_lines(REGS, APP)
    run_quiet(['make', '-C', FW, 'qemu'], 'qemu firmware build (make -C ssp/fw qemu)')
    q = QForth()
    bad = []
    try:
        for l in ['compiletoflash'] + lines:
            out, ok = q.line(l)
            if not ok or re.search(r'not found|stack (under|over)flow', out, re.I):
                bad.append((l, out.strip()))
    finally:
        q.close()
    if bad:
        say('FAIL: %d line(s) did not compile cleanly:' % len(bad))
        for l, out in bad[:10]:
            say('  line : %s' % (l if len(l) < 100 else l[:97] + '...'))
            say('  reply: %s' % out.replace('\n', ' | ')[-200:])
        sys.exit(1)
    say('[check] ok: %d lines compiled (%.0f s)' % (len(lines), time.time() - t0))


def build_image():
    t0 = time.time()
    say('[build] Verilator p1a model (make -C sim p1a)')
    run_quiet(['make', '-C', os.path.join(ROOT, 'sim'), 'p1a'], 'p1a model build')
    say('[build] dictionary build on the model, typically 3-4 minutes ...')
    start = time.time()
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, 'w') as log:
        rc = subprocess.run([os.path.join(ROOT, 'sim/ssp/dictbuild.sh')], cwd=ROOT,
                            stdout=log, stderr=subprocess.STDOUT).returncode
    text = open(LOG, errors='replace').read()
    fresh = os.path.exists(BUILT) and os.path.getmtime(BUILT) >= start
    for l in text.splitlines():
        if re.match(r'(build input|dictionary window|kernel integrity)', l):
            say('  ' + l)
    if rc == 0:
        say('[build] ok (%.0f s)' % (time.time() - t0))
        return True
    # the image is written before the cold-boot check; tell apart that failure
    if fresh and 'kernel integrity: ok' in text and 'MISSING:' in text:
        say('WARN: image built, but the cold-boot check failed:')
        for l in text.splitlines():
            if 'MISSING:' in l or 'FAIL' in l:
                say('  ' + l.strip())
        say('      (log: %s)' % LOG)
        return False
    say('FAIL: dictionary build (log: %s)' % LOG)
    say('\n'.join(text.splitlines()[-25:]))
    sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                 epilog='see the module docstring (head of this file) for details')
    ap.add_argument('-o', '--output', default=DEFAULT_OUT, metavar='FILE',
                    help='image file to write (default %s)' % os.path.relpath(DEFAULT_OUT, ROOT))
    ap.add_argument('--check', action='store_true', help='only the quick qemu compile check')
    ap.add_argument('--no-check', action='store_true', help='skip the qemu compile check')
    ap.add_argument('--install', action='store_true',
                    help='scp the image to the MiSTer after building')
    ap.add_argument('--dest', default=DEFAULT_DEST, metavar='HOST:PATH',
                    help='scp target for --install (default %s)' % DEFAULT_DEST)
    a = ap.parse_args()

    if not a.no_check:
        compile_check()
    if a.check:
        return 0

    verified = build_image()
    data = open(BUILT, 'rb').read()
    if len(data) != ROM_LEN:
        say('FAIL: %s is %d bytes, expected %d' % (BUILT, len(data), ROM_LEN))
        return 1
    out = os.path.abspath(a.output)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, 'wb').write(data)
    say('image: %s (%d bytes)%s' % (out, len(data), '' if verified else '  ** UNVERIFIED **'))

    if a.install:
        say('[install] scp -> %s' % a.dest)
        r = subprocess.run(['scp', out, a.dest])
        if r.returncode:
            say('FAIL: scp (%s)' % ' '.join(shlex.quote(x) for x in ['scp', out, a.dest]))
            return 1
    else:
        say('mount it from the OSD "SSP Monitor ROM" item, or: %s --install' % os.path.relpath(__file__, ROOT))
    return 0 if verified else 3


if __name__ == '__main__':
    sys.exit(main())
