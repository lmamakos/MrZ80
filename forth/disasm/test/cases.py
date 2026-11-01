"""The disassembler test vectors, shared by every environment's harness.

Every instruction encoding the Z-80 has (documented, undocumented, ED/DD/FD
page oddities, DDCB/FDCB) in an 8-byte slot, laid out at BASE in the test
memory image.  Operand bytes are 34 12 (so nn = 1234h, d = 34h, n = 12h).
"""
BASE = 0x9000


def slots():
    s = []
    def add(name, bs): s.append((name, bytes(bs)))
    for op in range(256):
        if op in (0xCB, 0xDD, 0xED, 0xFD): continue
        add("%02X" % op, [op, 0x34, 0x12])
    for op in range(256): add("CB %02X" % op, [0xCB, op])
    for op in range(256): add("ED %02X" % op, [0xED, op, 0x34, 0x12])
    for p in (0xDD, 0xFD):
        for op in range(256):
            if op in (0xCB, 0xDD, 0xED, 0xFD): continue
            add("%02X %02X" % (p, op), [p, op, 0x34, 0x12])
        for op in range(256): add("%02X CB d %02X" % (p, op), [p, 0xCB, 0x05, op])
        add("%02X 7E neg" % p, [p, 0x7E, 0xFB])           # negative displacement
    add("DD DD 21", [0xDD, 0xDD, 0x21, 0x34, 0x12])      # repeated prefix
    add("DD FD 21", [0xDD, 0xFD, 0x21, 0x34, 0x12])      # last prefix wins
    return s


def image():
    return b"".join(b.ljust(8, b"\x00") for _, b in slots())
