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
    instance (the two halves of the seam are wired to each other);
  * R47 RESET SYSTEM: sys_rst_req sets the reset_from_mount stretch, which feeds
    reset_sys, which resets ssp_top;
  * R43 OSD ROM mount: the mnt_* ports are driven (not tied off), mnt_busy
    reaches ioctl_wait, and the SDRAM mux does not switch on a bare
    ioctl_download (an SSP mount leaves the Z-80 running on its SDRAM).
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

# R43 OSD ROM mount: the mnt_* ports carry the index-6 download (never a
# constant tie-off), its clear sweep holds the HPS off, and an SSP mount
# must leave the SDRAM with the running Z-80 (a bare ioctl_download select
# would hand it to the idle download FSM mid-run).
for p in ('mnt_active', 'mnt_wr', 'mnt_addr', 'mnt_data', 'mnt_busy'):
    n = sspt.get(p, '')
    if not n or re.match(r"^\d*'[bdh]|^\d+$|^\{", n):
        bad.append('ssp_top port %s is tied off (%r)' % (p, n))
w = re.search(r'assign\s+ioctl_wait\s*=\s*([^;]*);', sv)
if not w or sspt.get('mnt_busy', '#') not in w.group(1):
    bad.append('ioctl_wait does not include the ssp_top mnt_busy net')
for m in ('addr', 'din', 'we', 'rd'):
    a = re.search(r'assign\s+sdram_%s_mux\s*=\s*(\w+)\s*\?' % m, sv)
    if not a:
        bad.append('sdram_%s_mux assignment not found' % m)
    elif a.group(1) == 'ioctl_download':
        bad.append('sdram_%s_mux selects on bare ioctl_download (an SSP ROM mount '
                   'would take the SDRAM from the running Z-80)' % m)

# R47 RESET SYSTEM: ssp_top.sys_rst_req must be a real net (not tied off), and
# it must be a set-condition of the self-clearing reset_from_mount stretch
# (the latch is what keeps the core in reset for the whole count after a
# one-clock request), which must feed reset_sys, which must reset ssp_top.
n = sspt.get('sys_rst_req', '')
if not n or re.match(r"^\d*'[bdh]|^\d+$|^\{", n):
    bad.append('ssp_top port sys_rst_req is tied off (%r)' % n)
else:
    lat = re.search(r'always\s*@\(posedge\s+clk_sys\)\s*begin\s*if\s*\((.*?)\)\s*begin\s*'
                    r'reset_from_mount\s*<=\s*1', sv, re.S)
    if not lat or not re.search(r'\b%s\b' % re.escape(n), lat.group(1)):
        bad.append('sys_rst_req net %s is not a set-condition of reset_from_mount' % n)
rs = re.search(r'wire\s+reset_sys\s*=\s*([^;]*);', sv)
if not rs or 'reset_from_mount' not in rs.group(1):
    bad.append('reset_sys does not include reset_from_mount')
if sspt.get('rst_n', '') != '~reset_sys':
    bad.append('ssp_top rst_n is not ~reset_sys (RESET SYSTEM must reset the SSP too)')

if bad:
    print('check_seam: FAIL'); print('\n'.join('  ' + b for b in bad)); sys.exit(1)
print('check_seam: OK (%d CPM ssp_* ports, %d ssp_top ports connected)' % (len(cpm_ports), len(sspt)))
