# SDRAM_REWORK_PLAN — SDRAM Memory Subsystem Rework Roadmap

Status: **DRAFT v0.1** — captures the rework planning discussion and owner
decisions of 2026-10-23 (decision round **R9** in the `SSP_DESIGN.md`
§17 log numbering). Tags as in the design doc (`[verified]`/`[decided]`/
`[proposed]`/`[open]`/`[deferred]`).

Companions: `REQUIREMENTS.md` items 1 & 4 (the requirements this plan
dispositions), `doc/SSP_DESIGN.md` (v1.0-draft) §9.2 (the monitor's memory
clients — the rework's primary driver), `HISTORY.md` +
`SDRAM-review-handoff.md` (reliability/performance narrative), `MrZ80.sdc`
(timing).

---

## 1. Why rework at all

The SDRAM path is **reliable** and **fast**; those battles are won:

- Sustained-access failures fixed (wait-release race, T80 INI/OTI bug,
  device-0 refresh) — `sdramexec`/`sdramret`/`backtoback`/`timertest` pass
  on hardware. `[verified]`
- REQUIREMENTS item 4 steps 1–4 landed (CEN clocking, combinational wait
  release, speculative T1 reads, posted writes): CamelFORTH `bench` SDRAM
  29465 ms vs BRAM 29271 ms (**+0.7%**, was +49%). The BRAM cache
  (item 4.2) lost its performance rationale and was shelved. `[verified]`

So this rework is **not** a fix and not a speed project. The driver is
**architecture**: the SSP design (`SSP_DESIGN.md`, renamed from ODT_MONITOR_DESIGN.md at R13) introduces *multiple memory
clients*, and today there is no arbiter — one CPU client FSM (inline in
`MicrocomputerZ80CPM.vhd`) plus an implicit second path (the HPS ioctl
loader streams via the same wiring while the CPU is held), multiplexed *by
convention* across two hierarchy levels. REQUIREMENTS item 1 anticipated
exactly this; the historical S_GAP CDC deadlock class was born in this kind
of implicit coupling.

## 2. Verified baseline (inputs to the plan)

- Controller `sdram_32r8w` (`Components/SDRAM/sdram2.sv`): CoCo3-derived,
  LOCAL MODs = full 128 MB decomposition (addr[26] = device chip, DQM byte
  lanes on the cpu port), refresh-over-request priority (`:300`), dual-device
  alternating refresh, post-access DLY recovery fix. Arbitration
  characterized: **refresh > cpu > vid**; vid port read-only, 16-bit words,
  A0=0. `BURST_LENGTH = 2` (`:110`). `[verified]`
- CPU client FSM (CPM core): `S_IDLE→S_REQ→S_DONE→S_GAP`; level-held req
  across `clk_sys`(50)→`clk_ram`, completion toggle back-synced; speculative
  read launch at T1 (`MRD_T1`), posted-write buffer. `[verified]`
- Clocks: `clk_sys` 50 MHz; `clk_ram` = 112 MHz primary tap, 100 MHz
  fallback via `SDRAM_CLK_100` — **the fallback is active in the current
  build** (`MrZ80.sv:502`), pending 112 MHz timing closure. Both configs are
  standing regression targets. `[verified]`
- Loader path (HPS ioctl, `MrZ80.sv`): byte-streaming write handshake with
  `DL_WR_COOLDOWN` spacing while the CPU is held at boot/mount; 8 MB `.DSK`
  mounts in a few seconds. Owner: adequate. `[decided, R9]`
- Physical map: SDRAM pages 0–8191 (128 MB), BRAM page 8192 @ `0x8000_0000`
  (separate mux, not the SDRAM controller); MMU is 28-bit physical
  (256 MB capable; >128 MB has no physical devices).

## 3. Client roster (as decided across SSP design rounds R3/R9)

| # | Client | Priority | Traffic shape | Status |
|---|---|---|---|---|
| 1 | **CPU** (MMU-translated, existing FSM) | highest | single bytes; T1-speculative reads; posted writes | live |
| 2 | **Loader** (ioctl BIN/DSK/MPKG/MROM) | boot-ish (CPU held) | byte stream, cooldown-spaced | live; streaming **deferred** (D-S3) |
| 3 | **`ssp_mem_client`** (SSP P1) | only while guest parked ∧ primary FSM idle | single physical bytes R/W (incl. BRAM mux) | planned |
| 4 | **`ssp_sd`** (SSP P2) | lowest | vid-port 16-bit background **reads** | planned (OQ-11 keeps writes deferred) |
| ~~5~~ | ~~Block-transfer engine~~ | — | — | **retired** (D-S2) |

Standing SSP constraints apply to all clients: **P-A** (park before master),
**P-D** (never disturb MMU/guest state — arbiter is physical-space by
construction), **G-2** (explicit muxes, frozen-output discipline), **G-4**
(transient guest-stall budget ≤ ~4 ms, watchdog-backed).

## 4. Decisions `[decided, R9, 2026-10-23]`

- **D-S1 — Staged A-then-B.** *Option A* (minimal additive: new clients
  borrow existing mux points inline, no new abstraction) ships with SSP
  P1/P2 — smallest diff, keeps R-21 bit-identical discipline trivially.
  *Option B* (formal arbiter extraction) is **approved as useful work** but
  runs as a dedicated refactor milestone **after P2 green**, off the monitor
  critical path. See §5/§6.
- **D-S2 — No block-transfer engine.** REQUIREMENTS item-1 reserved slot #3
  retired. The need (RAM-disk sector moves, RomWBW `HB_BNKCPY`-style bank
  copies) is addressed by the *initial implementation*: CPU-driven moves
  using the MMU **direct-access I/O port** with `INIR`/`OTIR` repeated block
  transfers — existing hardware, and ordinary CPU-class traffic, so no new
  arbiter client is required. Revisit only if profiling shows INIR/OTIR
  throughput inadequate; if so, a block client becomes the first native
  customer of milestone B's arbiter.
- **D-S3 — Loader streaming mode deferred.** Continuous-beat streaming
  (replacing `DL_WR_COOLDOWN` spacing) would cut 8 MB mount times
  substantially, but current performance "feels adequate" and improving it is
  low priority. If ever picked up, it rides the milestone-B arbiter.
- **D-S4 — No burst transfers.** Controller `BURST_LENGTH` stays 2; the
  client protocol is **single-beat** everywhere (req/gnt +
  rnw/addr[27:0]/din[7:0]/dout/ready). No measured demand from monitor
  dumps, uploads, or mounts justifies the added controller/client complexity
  and re-verification risk. (Monitor 64 KB bank dump ≈ tens of ms single-beat
  — fine for a human-scale console.)
- **D-S5 — Arbiter shape for milestone B (sketch, non-binding until B
  starts).** Placement: `Components/MEM/sd_arb.sv` + generalized
  `sd_cdc_client.sv` (today's FSM module-ized), CPU-side ports punched
  through the CPM boundary so the arbiter simulates standalone. Strict
  priority: CPU > loader > monitor-parked; vid port remains the controller's
  own clk_ram-native lowest class (no crossing change). Stall-budget and
  per-class beat counters (G-4 enforcement + debug visibility);
  `mon_park` grant additionally gated on BusAck ∧ primary-idle (P-A);
  loader grant gated on CPU-held.
- **D-S6 — Cache stays shelved (re-confirmed).** Item 4.2's BRAM cache
  remains off the roadmap (+0.7% penalty). For RomWBW the lever is the
  existing alternative: place hot banks (HBIOS/user/common/AUX ≈ 128 KB) in
  block RAM page 8192 and leave ROM/RAM-disk in SDRAM — HBIOS platform code
  must write the MMU page high-byte ports (+4..+7); no RTL arbiter/cache
  work.

## 5. Milestone A — additive borrowed wiring (rides SSP P1/P2)

What actually gets built now, unchanged from `SSP_DESIGN.md` §9.2:

1. `ssp_mem_client` taps the existing client-interface mux points in
   `MicrocomputerZ80CPM.vhd` (plus the BRAM mux), gated parked ∧
   primary-client-idle; native DQM via `addr[0]` (R-27).
2. `ssp_sd` instantiates the *existing CDC pattern* (level req + completion
   toggle) onto the controller's vid port, reads only; acceptance = R-26
   "benign as refresh collisions" assertion suite.
3. Loader untouched (cooldown stays; D-S3).
4. R-21 discipline: bit-identical existing traces with monitor clients idle;
   full sim + hardware regression on every step.

Acceptance = the SSP P1/P2 exit criteria (R-26, R-27) plus existing
regressions green at **both** `clk_ram` configs.

## 6. Milestone B — formal arbiter extraction (future, approved)

Trigger: SSP P2 green (three muxed clients now exist inline) or a measured
need that D-S2's INIR/OTIR path can't meet — whichever first. Then, as a
self-contained refactor:

- Extract `sd_arb.sv` + `sd_cdc_client.sv`; migrate CPU, loader, and
  `ssp_mem_client` onto the formal ports; vid path unchanged at controller.
- Add stall-budget counters + per-class debug counters (export through the
  SSP bridge debug registers for `SYS` lamp page / `ENG_LOG` visibility —
  free synergy).
- Gate: full regression (`sim/run.sh`, `run_perf.sh`, hardware
  `sdramexec/ret/backtoback/timertest`, bench within noise) + STA all
  corners, both clk_ram taps + new `tb_sdram_arb` (below).

## 7. Explicit non-goals

- BRAM cache (D-S6) — reopen only via the trace study REQUIREMENTS 4.2
  prescribes, and only if a *new* need (not speed) appears.
- Burst transfers (D-S4).
- Loader streaming (D-S3, deferred rather than rejected).
- `clk_ram`-side client FSM / clocking rework (REQUIREMENTS item 4.3) —
  remains an open idea; if pursued it lands inside milestone B's module,
  since B already relocates the FSM code.
- 256 MB physical — hardware limit (XSDS devices are 128 MB); MMU width
  already future-proof.
- vid-port writes — unchanged OQ-11 gate (after R-26 read proof).

## 8. Verification spine

- **Carried:** `sim/run.sh` + `sim/run_perf.sh`; hardware `sdramexec`,
  `sdramret`, `backtoback`, `timertest`, CamelFORTH `bench` (block RAM vs
  SDRAM); R-21 bit-identical discipline.
- **New at B:** `tb_sdram_arb` — strict-priority behaviour; CPU added-wait
  under max background load bounded at refresh-equivalence; no client
  starvation (liveness); timeout semantics per G-4; randomized multi-client
  overlap; deadlock-class checks (the historical S_GAP family gets explicit
  regression vectors).
- **Monitor clients (A):** `tb_mem_client` (R-27), `tb_ssp_sd` (R-26) —
  land in P1/P2 respectively.
- **STA:** any added mux into `cpuDataIn`/strobe nets must keep the T80
  `set_multicycle_path` (setup 5 / hold 4) argument valid — paths change
  length; re-verify all corners, both clk_ram taps; the known
  `SBCTextDisplayRGB` failure stays tracked separately.
- **Refresh guarantee:** per-device interval holds under worst-case client
  load at *both* 100 and 112 MHz taps (constants are conservative at 100 —
  re-check when/if 112 goes live).

## 9. Risks & standing constraints

- Milestone B touches the hottest verified path — hence its own milestone
  with full regression, never smuggled into a feature phase.
- CDC correctness is the historical failure class: keep the level-held-req +
  toggle-done pattern as the sanctioned idiom; any deviation needs written
  justification in the module header.
- `SDRAM_CLK_100` currently live: 112 MHz activation is itself a
  verification event (STA + soak + refresh constants) — track independently
  of this plan.
- `sys/` files untouchable; `sdram2.sv` edits only under the LOCAL MOD
  comment discipline and only if an accepted decision requires them
  (none do in A or B as scoped).

## 10. Future-work ledger (summary)

| Item | Disposition | Trigger / home |
|---|---|---|
| `ssp_mem_client`, `ssp_sd` (additive) | scheduled (SSP P1/P2) | `SSP_DESIGN.md` §9.2 |
| Formal `sd_arb` extraction (Milestone B) | **approved, unscheduled** | after SSP P2 green; confirm at P3 planning (SSP OQ-19) |
| Block-transfer engine | retired (INIR/OTIR suffices) | reopen only on measured inadequacy |
| Loader streaming mode | deferred (adequate today) | with/after milestone B |
| Burst transfers | rejected v1/v2 | reopen only on measured demand |
| BRAM cache | shelved (re-confirmed) | trace study + new non-speed need |
| RomWBW hot banks in BRAM page 8192 | roadmap (platform FW) | RomWBW port work; MMU +4..+7 writes in HBIOS |
| 112 MHz `clk_ram` activation | open (timing) | STA closure; standalone soak |
| vid-port writes | deferred | OQ-11 gate after R-26 |
| clk_ram-side client FSM (item 4.3) | open idea | milestone-B vessel if pursued |
