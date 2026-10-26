# bakeoff/ — OQ-20 two-core bake-off synthesis projects (throwaway)

Purpose: apples-to-apples synthesis data for the P0 core selection decision
(`doc/SSP_DESIGN.md` §5.8 criteria, OQ-20): picorv32 vs gracilis (FemtoRV32)
on `5CSEBA6U23I7`, both wrapped in an **identical fabric** (ROM/DTCM arrays +
minimal UART/bridge register block + decoder-error counter), so the reported
ALUT/M10K/fmax deltas reflect the cores.

Synthesis-safe tops only: no DPI, no `$readmemh`, no plusargs — the functional
(sim) twins live in `sim/ssp/`. These tops exist to be measured, not booted.

Run (from repo root; tycho runs Quartus 17.0 in Docker on the same files):

    tools/quartus_build.sh --flow compile bakeoff/bakeoff_picorv32
    tools/quartus_build.sh --flow compile bakeoff/bakeoff_gracilis

Results (ALUTs, registers, M10K blocks, fmax vs the 50 MHz target) get
tabulated in `SSP_DESIGN.md` §5.8; `output_files/*.fit.summary` are the
compact evidence. Products (`db/`, `output_files/`) are gitignored.

Fairness notes:
* identical fabric sources per entrant (the two tops differ only in the core
  instantiation + bus-protocol shim, which is inherent to the entrants);
* one 50 MHz base clock declared in `bakeoff.sdc` (design sysclk) so fmax is
  reported; unplaced pins (no board I/O needed to fit);
* gracilis has no `trap` output — its top ties `trap=0` (footnote in §5.8;
  silicon `STATUS.rv_trap` exists only if picorv32 wins, else WDG covers).

## M10K inference lesson (R21) — see `ramprobe.v`

Gracilis initially failed synthesis with `Error (276003)` (rom/dtcm fell out
as ~1M raw registers); the identical fabric around picorv32 inferred first
try. Diagnostic progression (`ramprobe.v`, rewritten per round — verdicts
below are what each round actually established):

* v1 — six 1K..declared-16K arrays, per-array verdicts. Useful discriminators
  (RMW-masked writes fail pass 1; rstrb-gated `q` capture fails; always-`q` +
  explicit per-bit byteenable passes) **but the 16K arrays were indexed
  `[13:2]` and silently pruned to 4K depth — their "wins" did not prove
  anything about 16K**.
* v2 — TRUE 16K depth (index `[15:2]`), standalone arrays: both
  combinational-address and registered-address q-style + byteenable templates
  **inferred cleanly (1,048,576 bits, 15 registers)**. So the template per se
  is sound at full depth.
* v3/v4 — the full fabric driven by the real FemtoRV core: rom/dtcm never
  even reach the RAM classifier (no 276xxx messages; synthesis grinds on the
  raw-register netlist). v4 isolates the final hypothesis: a one-cycle
  **registered read address** (`r_addr` shim) in front of the arrays, matching
  what picorv32 effectively provides (its `mem_addr` register gets absorbed —
  see `output_picorv32/*.map.rpt`: `ADDRESS_REG_B=CLOCK0`).

## Resolution (R21, owner ruling): explicit RAM IP

Abandon inference-dependence for the bake-off fabric (v4 still grinding;
owner directive). Both tops now instantiate `ssp_sdp_ram.vhd` — a hand-written
MegaWizard-style `altsyncram` wrapper (`DUAL_PORT` 16K×32 — 17.0 Lite's
altsyncram has no `SIMPLE_DUAL_PORT` keyword; port-A-write/port-B-read wiring
*is* the simple-dual-port usage — port-A byteenable, `ADDRESS_REG_B=CLOCK0`,
`OUTDATA_REG_B=UNREGISTERED`) — exactly
the house pattern already shipping in this project:

| wrapper | shape | use |
|---|---|---|
| `Components/INTERNALRAM/InternalRam64K.vhd` | altsyncram SINGLE_PORT 64K×8, q unregistered | general (Z80) memory system |
| `Components/TERMINAL/DisplayRam1K.vhd` | altsyncram BIDIR_DUAL_PORT 1K×8 | terminal display RAM |
| `bakeoff/ssp_sdp_ram.vhd` (new) | altsyncram DUAL_PORT 16K×32, byteenable (SDP usage) | SSP MROM + DTCM |

Consequence, honest for both entrants and for the real design: the IP's
registered read address makes **launch+1 read latency** the fabric truth.
That is natively FemtoRV's `rstrb` protocol (no wait logic); picorv32's
zero-latency valid/ready bus gets a one-cycle wait-state FSM instead.
`sim/ssp/` functional twins keep their behavioral memories (protocol-identical
for gracilis; picorv32 sim lane was already handshake-driven, so a wait state
would be invisible to FW).

Design consequence for the real silicon (P1): with explicit IP, launch+1 read
latency *is* the fabric truth — matching FemtoRV natively (no `mem_rbusy`
assertion ever needed for RAM reads; the stall protocol stays reserved for
future slow slaves) and costing picorv32 one wait state per access. FW/boot
sees the same single-cycle-latency memories either way. Verdict + final
numbers in `SSP_DESIGN.md` §5.8 / §17 R21.
