#!/usr/bin/env python3
"""ssp_appsrc.py -- turn the SSP monitor source into the lines that are typed
into a Mecrisp REPL to build the dictionary.

Shared by sim/ssp/dictbuild.sh (silicon-true build on the p1a model) and
tools/ssp_image.py (qemu compile check), so both see the same input.

  1. `\\ @include <repo-relative file>` lines are expanded in place
  2. the SSP_* constants the source uses are picked out of ssp/fw/ssp-regs.fs
     by name and emitted first (an unknown SSP_* name is an error)
  3. blank lines, full-line comments and trailing `\\ ...` comments are
     dropped (every input byte costs 4.3k cycles of UART time in the model;
     no string in monitor.fs contains a backslash)

usage: ssp_appsrc.py REGS.fs APP.fs OUT.fs     OUT gets CR-separated lines
       ssp_appsrc.py REGS.fs APP.fs -          one line per output line (stdout)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def build_lines(regs, app):
    src = []
    for l in open(app).read().splitlines():
        m = re.match(r"\\ @include\s+(\S+)\s*$", l)
        src.extend(open(os.path.join(ROOT, m.group(1))).read().splitlines() if m else [l])
    used = set(re.findall(r"\bSSP_[A-Z0-9_]+\b", "\n".join(
        l for l in src if not l.lstrip().startswith("\\"))))
    consts = {}
    for l in open(regs):
        m = re.match(r"(\$[0-9A-F]+ constant (SSP_[A-Z0-9_]+))", l)
        if m:
            consts[m.group(2)] = m.group(1)
    missing = sorted(used - set(consts))
    if missing:
        sys.exit("%s uses constants missing from ssp-regs.fs: %s" % (app, " ".join(missing)))
    lines = [consts[n] for n in sorted(used, key=lambda n: list(consts).index(n))]
    nconst = len(lines)
    for l in src:
        l = re.sub(r"\s+\\ .*$", "", l.rstrip())
        if not l.strip() or l.lstrip().startswith("\\"):
            continue
        lines.append(l)
    return lines, nconst


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    regs, app, out = sys.argv[1:4]
    lines, nconst = build_lines(regs, app)
    if out == "-":
        print("\n".join(lines))
        return
    open(out, "w").write("\r".join(lines) + "\r")
    print("build input: %d constants + monitor, %d lines, %d bytes" %
          (nconst, len(lines), len("\r".join(lines)) + 1))


if __name__ == "__main__":
    main()
