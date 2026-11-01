#!/usr/bin/env python3
"""Check a harness result (harness_camel.py / harness_mecrisp.py JSON).

Every disassembled line is assembled again with um80 (tools/um80.sh) and
the bytes compared with the original encoding; the number of bytes the
disassembler consumed must equal the real instruction length.  Cases an
assembler cannot reproduce are checked by explicit rules (listed in the
summary): ED mirror encodings, undocumented IXH/IXL/IYH/IYL, the DDCB
register-copy forms, ignored DD/FD prefixes, F_NEXT/PUSHIX/POPIX (custom).
Exit 0 only if every case passes and the stack was left balanced.
"""
import collections, json, os, re, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../..'))
sys.path.insert(0, HERE)
import cases
from parse import parse

BASE = cases.BASE
REG = "BCDEHL.A"
CUSTOM = {0x92: "F_NEXT"}
for rp, hi in (("BC", 0xC), ("DE", 0xD), ("HL", 0xE)):
    CUSTOM[hi << 4 | 5] = "PUSHIX " + rp
    CUSTOM[hi << 4 | 1] = "POPIX " + rp
SPECIAL = {0x70: "IN F, (C)", 0x71: "OUT (C), 0"}      # ED 70 / ED 71


def norm(t):      # M80 wants a leading digit on hex numbers
    return re.sub(r"\b([0-9][0-9A-F]*|[A-F][0-9A-F]*)h\b",
                  lambda m: ("0" + m.group(0)) if m.group(0)[0] in "ABCDEF" else m.group(0), t)


def assemble(items):
    """items: [(addr, text)] -> {addr: bytes} (length found via a sentinel)."""
    d = tempfile.mkdtemp(prefix='dzverify-')
    lines = ["\t.Z80", "\tASEG"]
    for a, t in items:
        lines += ["\tORG 0%04XH" % a, "\t" + t, "\tDB 0AAH,055H"]
    lines.append("\tEND")
    open(d + '/t.azm', 'w').write("\n".join(lines) + "\n")
    tl = ROOT + '/tools/'
    r = subprocess.run([tl + 'um80.sh', 't.azm', '-o', 't.rel', '-l', 't.prn'], cwd=d,
                       capture_output=True, text=True)
    errs = [l for l in (r.stdout + r.stderr).split('\n') if 'rror' in l]
    if errs:
        sys.exit("assembler rejected the disassembler output:\n" + "\n".join(errs[:10]))
    subprocess.run([tl + 'ul80.sh', '-p', '0', '-x', '-o', 't.hex', 't.rel'], cwd=d,
                   capture_output=True, check=True)
    mem = {}
    for l in open(d + '/t.hex'):
        l = l.strip()
        if l.startswith(':') and l[7:9] == '00':
            n, ad = int(l[1:3], 16), int(l[3:7], 16)
            for k in range(n): mem[ad + k] = int(l[9 + 2 * k:11 + 2 * k], 16)
    res = {}
    for a, _ in items:
        ln = 0
        while not (mem.get(a + ln) == 0xAA and mem.get(a + ln + 1) == 0x55) and ln < 7: ln += 1
        res[a] = bytes(mem.get(a + k, 0) for k in range(ln))
    return res


def main(path):
    data = json.load(open(path))
    out, lens = parse(data['chunks'])
    sl = cases.slots()
    bad, cat, ok = collections.OrderedDict(), collections.Counter(), 0
    if len(out) != len(sl):
        sys.exit("only %d of %d cases decoded (harness lost output?)" % (len(out), len(sl)))
    todo, halfs, cbreg = [], {}, {}
    for i, (n, b) in enumerate(sl):
        a = BASE + i * 8; t = out[a]
        if b[0] == 0xED and b[1] in CUSTOM:
            if t == CUSTOM[b[1]] and lens[a] == 2: cat['custom instruction'] += 1; ok += 1
            else: bad[n] = (t, CUSTOM[b[1]], b.hex(), lens[a])
            continue
        if "F_NEXT" in t or "PUSHIX" in t or "POPIX" in t:
            bad[n] = (t, 'not a custom opcode', b.hex(), lens[a]); continue
        if b[0] == 0xED and b[1] in SPECIAL:
            if t == SPECIAL[b[1]] and lens[a] == 2: ok += 1
            else: bad[n] = (t, SPECIAL[b[1]], b.hex(), lens[a])
            continue
        if t == "NOP" and b[0] != 0:                    # ED xx / prefix + NOP
            exp = 2 if b[0] == 0xED else (2 if b[0] in (0xDD, 0xFD) and b[1] == 0 else None)
            cat['NOP forms'] += 1
            if lens[a] == exp: ok += 1
            else: bad[n] = (t, 'NOP', b.hex(), lens[a])
            continue
        tt = norm(t)
        if " CB d " in n and (b[3] & 7) != 6:
            m = re.match(r"^(.*\(I[XY][+-]\w+\)),\s*([BCDEHLA])$", tt)
            if m: tt = m.group(1); cbreg[i] = m.group(2)
        h = re.search(r"\bI([XY])([HL])\b", tt)
        if h:
            tt = re.sub(r"\bI[XY]([HL])\b", r"\1", tt); halfs[i] = h.group(1)
        todo.append((i, a, tt))
    asm = assemble([(a, t) for _, a, t in todo])
    for i, a, t in todo:
        n, b = sl[i]; code = asm[a]; ln = len(code); consumed = lens[a]
        good = code == b[:ln] and consumed == ln
        if i in cbreg:
            good = (code == bytes(b[:3]) + bytes([(b[3] & ~7) | 6]) and consumed == 4
                    and cbreg[i] == REG[b[3] & 7])
            cat['DDCB/FDCB register copy'] += 1
        elif not good and b[0] in (0xDD, 0xFD) and b[1] in (0x10, 0x18, 0x20, 0x28, 0x30, 0x38) \
                and ln == 2 and consumed == 3:
            good = code[1] == (b[2] + 1) & 255 and code[:1] == b[1:2]
            cat['DD/FD before a relative jump'] += 1
        elif not good and b[0] in (0xDD, 0xFD) and code == b[1:1 + ln] and consumed == ln + 1:
            if i in halfs:
                good = b[0] == (0xDD if halfs[i] == "X" else 0xFD)
                cat['undocumented IXH/IXL/IYH/IYL'] += 1
            else:
                good = True; cat['ignored DD/FD prefix'] += 1
        elif not good and b[0] == 0xED:
            o = b[1]
            if o & 0xC7 == 0x44 and code == bytes([0xED, 0x44]) and consumed == 2:
                good = True; cat['ED mirror NEG'] += 1
            elif o & 0xC7 == 0x45 and consumed == 2 and \
                    code[:2] == bytes([0xED, 0x4D if (o >> 3) & 1 else 0x45]):
                good = True; cat['ED mirror RETN/RETI'] += 1
            elif o in (0x4E, 0x66, 0x6E, 0x76, 0x7E) and code[:1] == b'\xed' and \
                    code[1] in (0x46, 0x56, 0x5E) and consumed == 2:
                good = True; cat['ED mirror IM'] += 1
            elif o in (0x63, 0x6B) and code[0] in (0x22, 0x2A) and code[1:3] == b[2:4] \
                    and consumed == 4:
                good = True; cat['ED 63/6B long form'] += 1
        if good: ok += 1
        else: bad[n] = (out[a], code.hex(), b.hex(), consumed)
    m = re.search(r"DEPTH \. (-?\d+)", data.get('depth', ''))
    depth_ok = bool(m) and m.group(1) == '0'
    print("%s: %d cases, %d OK, %d bad; stack depth after: %s"
          % (data.get('env', '?'), len(sl), ok, len(bad), m.group(1) if m else '?'))
    print("  accepted by rule:", dict(cat))
    for n, v in list(bad.items())[:40]:
        print("  BAD", n.ljust(14), v)
    return 0 if not bad and depth_ok else 1


sys.exit(main(sys.argv[1]))
