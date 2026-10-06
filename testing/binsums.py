#!/usr/bin/env python3
"""binsums.py - host-side companion to testing/sdramsum.asm.

Prints the per-256-byte-block 16-bit additive checksums of a flat .BIN in
exactly the format sdramsum.bin prints for SDRAM page 0, plus the same
first-64-byte hex dump, so the two outputs can be compared by eye or diff.

Blocks wholly beyond the end of the image print '----'; the last, partial
block is computed over the image bytes only and flagged with '*' (the
SDRAM copy will differ there, since it also sums whatever followed the
image in SDRAM).

Usage: testing/binsums.py image.bin
"""
import sys

NBLK = 64
PERLINE = 8


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    data = open(sys.argv[1], "rb").read()
    out = []
    for k in range(NBLK):
        if k % PERLINE == 0:
            out.append("\n%02X:" % k)
        blk = data[k * 256:(k + 1) * 256]
        if not blk:
            out.append(" ----")
        else:
            mark = "*" if len(blk) < 256 else ""
            out.append(" %04X%s" % (sum(blk) & 0xFFFF, mark))
    print("".join(out).lstrip("\n"))
    print("first 64 bytes:")
    for off in range(0, 64, 16):
        row = data[off:off + 16]
        print("%04X: %s" % (off, " ".join("%02X" % b for b in row)))
    print("(image length %d = 0x%X bytes)" % (len(data), len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
