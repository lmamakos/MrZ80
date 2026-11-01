#!/usr/bin/env python3
"""check_ssp_map.py - the SSP memory map is written down in several places.

R43 (MROM 64 -> 128 KiB, dictionary window moved to 0x5000): the ROM size and
the first byte of the Mecrisp flash-dictionary window must agree between

  * the firmware   ssp/fw/mecrisp-quintus-ssp.s (.equ), ssp/fw/memmap-ssp,
                   the qemu variant (ssp/fw/Makefile QEMU_DEFS, memmap-qemu)
                   and the hex padding in ssp/fw/Makefile;
  * the RTL        ssp/rtl/ssp_top.v (decode width, MROM DEPTH, DICT_BASE),
                   MrZ80.sv (DICT_BASE override, mount address guard);
  * the tooling    sim/ssp/p1a_dictbuild.sh, sim/ssp/dictbuild_qemu.sh
                   (ROM_LEN / DICT_OFF), the bin2mif depth in sim/Makefile.

A mismatch is silent elsewhere: a dictionary built against one window and
write-protected against another, or an image padded to the wrong size.
"""
import os
import re
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bad = []


def rd(p):
    return open(os.path.join(root, p)).read()


def num(s):
    s = s.strip().replace('_', '')
    m = re.fullmatch(r"(\d+)'[hH]([0-9a-fA-F]+)", s)
    if m:
        return int(m.group(2), 16)
    m = re.fullmatch(r"(\d+)'[dD](\d+)", s)
    if m:
        return int(m.group(2))
    return int(s, 0)


def need(cond, msg):
    if not cond:
        bad.append(msg)


def find(src, pat, what, flags=0):
    m = re.search(pat, src, flags)
    if not m:
        sys.exit('check_ssp_map: cannot find %s' % what)
    return m


# ---- firmware (silicon map) --------------------------------------------------
asm = rd('ssp/fw/mecrisp-quintus-ssp.s')
eq = dict((k, num(v)) for k, v in
          re.findall(r'^\.equ\s+(\w+),\s*(0x[0-9A-Fa-f]+)', asm, re.M))
for k in ('RamAnfang', 'RamEnde', 'FlashAnfang', 'FlashEnde',
          'FlashDictionaryAnfang', 'FlashDictionaryEnde'):
    if k not in eq:
        sys.exit('check_ssp_map: .equ %s missing in mecrisp-quintus-ssp.s' % k)
ROM = eq['FlashEnde'] - eq['FlashAnfang']
DICT = eq['FlashDictionaryAnfang'] - eq['FlashAnfang']
RAM = eq['RamEnde'] - eq['RamAnfang']
need(eq['FlashAnfang'] == 0, 'FlashAnfang must be 0 (RV reset vector)')
need(eq['FlashDictionaryEnde'] == eq['FlashEnde'],
     'FlashDictionaryEnde %#x != FlashEnde %#x' % (eq['FlashDictionaryEnde'], eq['FlashEnde']))
need(ROM & (ROM - 1) == 0, 'ROM size %#x is not a power of two' % ROM)


def memmap(p):
    s = rd(p)
    r = find(s, r'rom\s*\([^)]*\)\s*:\s*ORIGIN\s*=\s*(0x[0-9A-Fa-f]+),\s*LENGTH\s*=\s*(0x[0-9A-Fa-f]+)', p + ' rom')
    a = find(s, r'ram\s*\([^)]*\)\s*:\s*ORIGIN\s*=\s*(0x[0-9A-Fa-f]+),\s*LENGTH\s*=\s*(0x[0-9A-Fa-f]+)', p + ' ram')
    return num(r.group(1)), num(r.group(2)), num(a.group(1)), num(a.group(2))


ro, rl, ao, al = memmap('ssp/fw/memmap-ssp')
need((ro, rl) == (eq['FlashAnfang'], ROM), 'memmap-ssp rom %#x+%#x != .equ map' % (ro, rl))
need((ao, al) == (eq['RamAnfang'], RAM), 'memmap-ssp ram %#x+%#x != .equ map' % (ao, al))

fwmk = rd('ssp/fw/Makefile')
m = find(fwmk, r'bin2hex\.py \$\(OBJROOT\)/mecrisp-ssp\.bin \$@ (0x[0-9A-Fa-f]+)', 'kernel hex padding')
need(num(m.group(1)) == ROM, 'ssp/fw/Makefile pads the kernel hex to %s, ROM is %#x' % (m.group(1), ROM))

# ---- firmware (qemu variant: same geometry, offset into DRAM) -----------------
qd = dict((k, num(v)) for k, v in re.findall(r'--defsym (\w+)=(0x[0-9A-Fa-f]+)', fwmk))
qbase = qd.get('FlashAnfang', -1)
need(qd.get('FlashEnde', 0) - qbase == ROM, 'qemu FlashEnde-FlashAnfang != ROM size')
need(qd.get('FlashDictionaryAnfang', 0) - qbase == DICT, 'qemu dictionary window offset != %#x' % DICT)
need(qd.get('FlashDictionaryEnde', 0) == qd.get('FlashEnde', -1), 'qemu FlashDictionaryEnde != FlashEnde')
need(qd.get('RamEnde', 0) - qd.get('RamAnfang', 0) == RAM, 'qemu RAM size != %#x' % RAM)
need(qd.get('RamAnfang', 0) >= qd.get('FlashEnde', 1 << 40), 'qemu RAM overlaps the ROM')
ro, rl, ao, al = memmap('ssp/fw/memmap-qemu')
need((ro, rl) == (qbase, ROM), 'memmap-qemu rom %#x+%#x != QEMU_DEFS' % (ro, rl))
need((ao, al) == (qd.get('RamAnfang'), RAM), 'memmap-qemu ram %#x+%#x != QEMU_DEFS' % (ao, al))

# ---- RTL ---------------------------------------------------------------------
top = re.sub(r'//[^\n]*', '', rd('ssp/rtl/ssp_top.v'))
m = find(top, r'parameter\s*\[16:0\]\s*DICT_BASE\s*=\s*([^,\s)]+)', 'ssp_top DICT_BASE')
need(num(m.group(1)) == DICT, 'ssp_top DICT_BASE %s != FlashDictionaryAnfang %#x' % (m.group(1), DICT))
m = find(top, r'is_rom\s*=\s*\(mem_addr\[31:(\d+)\]\s*==', 'ssp_top is_rom decode')
need(1 << int(m.group(1)) == ROM, 'ssp_top is_rom decodes %#x bytes, ROM is %#x' % (1 << int(m.group(1)), ROM))
m = find(top, r'is_rram\s*=\s*\(mem_addr\[31:(\d+)\]\s*==\s*\d+\'h([0-9A-Fa-f]+)\)', 'ssp_top is_rram decode')
need(1 << int(m.group(1)) == RAM, 'ssp_top is_rram decodes %#x bytes, RAM is %#x' % (1 << int(m.group(1)), RAM))
need(int(m.group(2), 16) << int(m.group(1)) == eq['RamAnfang'], 'ssp_top RAM base != RamAnfang')
m = find(top, r'ssp_sdp_ram\s*#\s*\(([^;]*?)\)\s*u_mrom', 'MROM instance parameters', re.S)
d = re.search(r'\.DEPTH\s*\((\d+)\)', m.group(1))
need(d is not None and int(d.group(1)) * 4 == ROM, 'u_mrom DEPTH*4 != ROM size %#x' % ROM)

sv = re.sub(r'//[^\n]*', '', rd('MrZ80.sv'))
m = find(sv, r'ssp_top\s*#\s*\((.*?)\)\s*ssp_top\s*\(', 'MrZ80.sv ssp_top parameters', re.S)
d = re.search(r'\.DICT_BASE\s*\(([^)]*)\)', m.group(1))
if d:
    need(num(d.group(1)) == DICT, 'MrZ80.sv DICT_BASE %s != %#x' % (d.group(1), DICT))
m = find(sv, r'ssp_mnt_in_rom\s*=\s*\(ioctl_addr\[26:(\d+)\]\s*==', 'MrZ80.sv mount address guard')
need(1 << int(m.group(1)) == ROM, 'MrZ80.sv mount guard admits %#x bytes, ROM is %#x' % (1 << int(m.group(1)), ROM))

# ---- tooling -----------------------------------------------------------------
for p in ('sim/ssp/p1a_dictbuild.sh', 'sim/ssp/dictbuild_qemu.sh'):
    s = rd(p)
    rlen = find(s, r'^ROM_LEN=(0x[0-9A-Fa-f]+)', p + ' ROM_LEN', re.M)
    doff = find(s, r'^DICT_OFF=(0x[0-9A-Fa-f]+)', p + ' DICT_OFF', re.M)
    need(num(rlen.group(1)) == ROM, '%s ROM_LEN %s != %#x' % (p, rlen.group(1), ROM))
    need(num(doff.group(1)) == DICT, '%s DICT_OFF %s != %#x' % (p, doff.group(1), DICT))
mk = rd('sim/Makefile')
for depth in re.findall(r'forth_rom\.mif (\d+)', mk):
    need(int(depth) * 4 == ROM, 'sim/Makefile bin2mif depth %s != ROM words %d' % (depth, ROM // 4))

if bad:
    print('check_ssp_map: FAIL')
    print('\n'.join('  ' + b for b in bad))
    sys.exit(1)
print('check_ssp_map: OK (MROM %d KiB, dictionary window %#x..%#x, RV RAM %d KiB)'
      % (ROM // 1024, DICT, ROM, RAM // 1024))
