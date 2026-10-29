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

The System Support Processor (SSP) is documented in two files with separate
jobs (update rules in `SSP_STATUS.md` §0):

`SSP_STATUS.md` -- **start here.** The living state/plan/hand-off document:
current state and milestones, the active milestone's plan and verification
checklist, the next milestone's plan, backlog, owner questions, hazards and
lessons, commands, conventions and environment facts; Appendix A keeps the
completed P1a execution notes. Rewritten every session. (Replaced
`SSP_HANDOFF.md` and the separate milestone plan files at R39.)

`SSP_DESIGN.md` -- the design spec (v1.0-draft; renamed from
`ODT_MONITOR_DESIGN.md` at R13): the FPGA-resident debug/console/assist
subsystem built on a FemtoRV32-gracilis RV32 core running Mecrisp-Quintus
Forth, the `ssp_bridge` register interface, boundary-aligned Z80 parking,
the single Z80 bus mux, the monitor, and the front-panel engine. Decision
table (§2), requirements ↔ benches (§13), open questions (§14), phasing
(§15), and the round-by-round decision log R1… (§17).

`SSP_REGS.md` -- SSP bridge register table, generated from
`ssp/regs/ssp_regs.csv` (do not hand-edit).

`SSP_PANEL_UX.md` -- front-panel user-experience spec (v0.2; deep-dive
2026-10-23 + MMU-switch addendum): lamp zones/chrome/colours, paged state
blocks with per-page remap, BP-ARM/FREEZE/START-AT-A modifiers, MMU
EXAM/DEPOSIT map switch (§4A), PANEL_LOCK sovereignty ladder,
encoder hold-cursor + double-press-zero, `*` commentary protocol,
acceptance walkthroughs, board-freeze checklist.

`SDRAM_REWORK_PLAN.md` -- SDRAM memory-subsystem rework roadmap (v0.1,
owner decisions of 2026-10-23): multi-client roster (CPU/loader/monitor
clients), staged A-then-B arbiter approach (additive borrowed wiring now,
formal `sd_arb` extraction later), block-transfer engine retired
(`INIR`/`OTIR` suffices), no bursts, loader streaming deferred, cache
shelving re-confirmed, verification spine and future-work ledger.

`SSP_RISCV_REVIEW.md` -- review of the v0.1 (hardwired-FSM) design against
the RISC-V/FORTH pivot; fact corrections and the disposition map used to
produce v0.2.

`archive/` -- superseded documents kept for provenance (see
`archive/README.md` for the disposition map): `ODT_CHANGE.md` was the
original pivot handoff (RISC-V/VexRiscv + Mecrisp-Quintus approach notes
and the initial `z80_bus_monitor.v` sketch), fully absorbed by
`SSP_DESIGN.md` and corrected by `SSP_RISCV_REVIEW.md`.
