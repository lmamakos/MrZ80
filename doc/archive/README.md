# archive/ — superseded design documents

Documents here record the *history* of a design decision but are **not
normative** — their ideas have been incorporated (usually evolved, sometimes
corrected) into the active specs. Do not implement from an archived document;
start from the active spec listed below.

| Archived doc | Superseded by | Notes |
|---|---|---|
| `ODT_CHANGE.md` | `doc/SSP_DESIGN.md` (current v1.0-draft) + `doc/SSP_RISCV_REVIEW.md` | Owner's original RISC-V/VexRiscv + Mecrisp-Quintus pivot handoff, incl. the initial `z80_bus_monitor.v` register sketch. All ideas absorbed; several facts corrected by the review (28-bit not 27-bit physical; vid port read-only, refresh>cpu>vid — "inspect without stalling" impossible; T80 FREEZES rather than tri-states; memory budget grew 16K/16K → 64K+64K + packs; VexRiscv must be vendored as generated Verilog — no SpinalHDL/sbt on the build host). "ODT" is the pre-R13 subsystem name — now **SSP — System Support Processor**; this archived file keeps its historical name. |
