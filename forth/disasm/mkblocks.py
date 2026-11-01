#!/usr/bin/env python3
"""Pack the shared Z-80 disassembler into CamelFORTH blocks.

    mkblocks.py <port.fth> <core.fth> <outdir> [first-block-number]

The port file is the template: its "\\ @core" line is replaced by the core.
Text before the first "\\ ====" marker is dropped (file headers).  Each
marker starts one block, written as <n>-disasm.fth with a "( n title )"
first line.  Blocks are 16 lines x 64 columns, so this lints the result for
things a block load cannot digest: over-long lines, more than 16 lines, a
parsing word dangling at end of line, unterminated ." strings or ( comments.
Files are only rewritten when their content changes (keeps make quiet).
Exit status 1 on any lint failure.
"""
import glob, os, re, sys

PARSERS = {"POSTPONE", "'", "[']", "CHAR", "[CHAR]", "VARIABLE", "CONSTANT",
           "CREATE", ":", "DEFER", "IS", "VALUE", "TO", "(", "\\", '."', 'S"',
           'ABORT"'}

def lint(name, no, line):
    errs = []
    if len(line) > 64:
        errs.append("%d columns (max 64)" % len(line))
    if "\t" in line:
        errs.append("tab character")
    code = re.sub(r"(^|\s)\\(\s.*)?$", "", line)      # drop trailing \ comment
    toks = code.split()
    if toks and toks[-1].upper() in PARSERS:
        errs.append("line ends with parsing word %s" % toks[-1])
    for m in re.finditer(r'(^|\s)\."(\s|$)', code):
        if code.find('"', m.end(0) - 1 + 0) < 0 or code.count('"') % 2:
            errs.append('unterminated ." string'); break
    stripped = re.sub(r'\."[^"]*"', "", code)
    stripped = re.sub(r'(^|\s)\([^)]*\)', " ", stripped)
    if re.search(r'(^|\s)\((\s|$)', stripped):
        errs.append("unterminated ( comment")
    return ["%s:%d: %s" % (name, no, e) for e in errs]

def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    port, core, outdir = sys.argv[1:4]
    first = int(sys.argv[4]) if len(sys.argv) > 4 else 30
    core_lines = open(core).read().split("\n")
    for i, l in enumerate(core_lines):                # drop the core's header
        if l.startswith("\\ ===="):
            core_lines = core_lines[i:]
            break
    lines = []
    for l in open(port).read().split("\n"):
        if l.strip() == "\\ @core":
            lines.extend(core_lines)
        else:
            lines.append(l)
    sections, cur = [], None
    for l in lines:
        m = re.match(r"\\ ==== (.*\S)\s*$", l)
        if m:
            cur = [m.group(1), []]; sections.append(cur)
        elif cur is not None:
            cur[1].append(l)
    bad = []
    for sec in sections:                              # trim blank edges only
        while sec[1] and not sec[1][-1].strip(): sec[1].pop()
        while sec[1] and not sec[1][0].strip(): sec[1].pop(0)
    last = first + len(sections) - 1
    if last > 49:
        sys.exit("mkblocks: %d sections do not fit blocks %d..49"
                 % (len(sections), first))
    want = {}
    for i, (title, body) in enumerate(sections):
        n = first + i
        if "(" in title or ")" in title:
            bad.append("section title has a parenthesis (ends the block's "
                       "title comment early): %s" % title)
        text = ["( %d %s )" % (n, title)] + body
        name = "%d-disasm.fth" % n
        if len(text) > 16:
            bad.append("%s: %d lines (max 16): %s" % (name, len(text), title))
        for k, l in enumerate(text, 1):
            bad.extend(lint(name, k, l))
        want[name] = "\n".join(text) + "\n"
    if bad:
        print("\n".join(bad), file=sys.stderr); sys.exit(1)
    os.makedirs(outdir, exist_ok=True)
    for old in glob.glob(os.path.join(outdir, "[34][0-9]-disasm.fth")):
        if os.path.basename(old) not in want:
            os.remove(old)
    for name, text in want.items():
        path = os.path.join(outdir, name)
        if not os.path.exists(path) or open(path).read() != text:
            open(path, "w", newline="\n").write(text)

main()
