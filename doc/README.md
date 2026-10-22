Just some handy reference information.  Good stuff at <http://www.z80.info/>.

"The Undocumented Z80 Documented" from http://www.z80.info/zip/z80-documented.pdf

`t80_reg_debug_vector.md` -- map of the T80 `REG` debug vector (where every
register lives in the 212-bit export) and how `T80_Reg.vhd` implements the
Z80 register set in this core.

`FORTH-GLOSSARY.md` -- CamelFORTH Z-80 word glossary (low-level CODE words and
high-level words), archived from the top-level README; sourced from
`forth/glosslo.txt` and `forth/glosshi.txt`.

`BASIC.md` -- legacy BASIC keyword reference and program examples (Z80/6502/6809),
archived from the top-level README. The 6502 and 6809 CPUs have been removed
from the core.

`ODT_MONITOR_DESIGN.md` -- draft design spec for the FPGA-resident ODT-style
debug monitor (serial console + classic front panel: halt/step/examine/
deposit, breakpoints, jump history).
