#!/usr/bin/env python3
"""hex2bin.py -- $readmemh-style word hex -> flat binary.

Inverse of tools/bin2hex.py; also accepts Verilator $writememh output
(comments '//', '@XXXXXXXX' word-index directives, one 32-bit little-endian
word per line).  Used by the stub-SoC dictionary pipeline to turn the
rom[] dump into the merged OSD artifact binary.

usage: hex2bin.py IN.hex OUT.bin [PADTO]
  PADTO  byte count to zero-pad the output to (default: size of image)
"""
import re
import sys


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    src, dst = sys.argv[1], sys.argv[2]
    padto = int(sys.argv[3], 0) if len(sys.argv) > 3 else None

    data = bytearray()
    idx = 0  # word index
    for lineno, line in enumerate(open(src), 1):
        line = line.split("//", 1)[0].strip()
        if not line:
            continue
        if line.startswith("@"):
            idx = int(line[1:], 16)
            continue
        for tok in line.split():
            if not re.fullmatch(r"[0-9a-fA-F]+", tok):
                print("hex2bin: %s:%d: bad word %r" % (src, lineno, tok),
                      file=sys.stderr)
                sys.exit(1)
            need = idx * 4 + len(tok) // 2
            if need > len(data):
                data.extend(b"\x00" * (need - len(data)))
            data[idx * 4:idx * 4 + len(tok) // 2] = \
                bytes.fromhex(tok)[::-1]  # token is big-endian text of LE word
            idx += 1

    if padto:
        if len(data) > padto:
            print("hex2bin: image %d bytes exceeds PADTO %d" % (len(data), padto),
                  file=sys.stderr)
            sys.exit(1)
        data += b"\x00" * (padto - len(data))
    open(dst, "wb").write(bytes(data))
    print("hex2bin: %s -> %s (%d bytes)" % (src, dst, len(data)))


if __name__ == "__main__":
    main()
