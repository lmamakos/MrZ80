#!/usr/bin/env python3
"""check_seam.py - top-level connectivity of the SSP seam in MrZ80.sv.

Neither the Verilator p1a lane (ssp_top + behavioural Z80) nor the GHDL
integration benches (CPM core with its own SSP stimulus) instantiate MrZ80.sv,
so a port left off or a net mis-named there is invisible to both (R39: the
ssp_int_hold gate).  Static check:
  * every ssp_* port of the MicrocomputerZ80CPM entity is connected in the CPM
    instance (VHDL port defaults would otherwise hide an omitted one);
  * every port of module ssp_top is connected in the ssp_top instance;
  * every net on a CPM ssp_* port also appears on a port of the ssp_top
    instance (the two halves of the seam are wired to each other).
"""
import re, sys, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rd = lambda p: re.sub(r'//[^\n]*', '', open(os.path.join(root, p)).read())
sv = rd('MrZ80.sv')
vhd = re.sub(r'--[^\n]*', '', open(os.path.join(root, 'MicrocomputerZ80CPM.vhd')).read())
top = rd('ssp/rtl/ssp_top.v')
bad = []

def instance(src, mod, label):
    m = re.search(r'^\s*%s\s+(?:#\s*\(.*?\)\s*)?%s\s*\((.*?)\n\s*\);' % (mod, label),
                  src, re.S | re.M)
    if not m:
        sys.exit('check_seam: instance of %s not found in MrZ80.sv' % mod)
    return dict((p, n.strip()) for p, n in re.findall(r'\.(\w+)\s*\((.*?)\)\s*(?:,|$|\n)', m.group(1)))

cpm = instance(sv, 'MicrocomputerZ80CPM', 'MicrocomputerZ80CPM')
sspt = instance(sv, 'ssp_top', 'ssp_top')

ent = re.search(r'entity\s+MicrocomputerZ80CPM\s+is\s+port\s*\((.*?)\n\s*\);\s*end', vhd, re.S | re.I)
cpm_ports = re.findall(r'^\s*(ssp_\w+)\s*:', ent.group(1), re.M | re.I)
for p in cpm_ports:
    if p not in cpm or not cpm[p]:
        bad.append('CPM port %s not connected in MrZ80.sv' % p)

hdr = re.search(r'module\s+ssp_top\b.*?\);', top, re.S).group(0)
for p in re.findall(r'(?:input|output)\s+wire\s*(?:\[[^\]]*\])?\s*(\w+)', hdr):
    if p not in sspt or not sspt[p]:
        bad.append('ssp_top port %s not connected in MrZ80.sv' % p)

top_nets = set(sspt.values())
for p in cpm_ports:
    n = cpm.get(p, '')
    if n and n not in top_nets:
        bad.append('CPM %s (net %s) is not on any ssp_top port' % (p, n))

if bad:
    print('check_seam: FAIL'); print('\n'.join('  ' + b for b in bad)); sys.exit(1)
print('check_seam: OK (%d CPM ssp_* ports, %d ssp_top ports connected)' % (len(cpm_ports), len(sspt)))
