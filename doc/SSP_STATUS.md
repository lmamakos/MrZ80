# SSP_STATUS — state, plans and hand-off for the System Support Processor

Updated: **2026-10-29 (round R39 committed locally)** · Branch `r24-p1b`, one
commit ahead of `33d6127` (= `main` = `origin/main`; not pushed) · Phase
**P1b**; M4 (single-step) done in simulation, **M3 is next**.

## 0. How to use the SSP documents

There are two SSP documents. Each has a different job and a different update
rule:

| Document | Answers | Update rule |
|---|---|---|
| `doc/SSP_DESIGN.md` | **What and why.** Architecture, decision table (D-xx, §2), register model (§6, with the generated `doc/SSP_REGS.md`), semantics (§7–§11), requirements ↔ benches (§13), open questions (§14), phasing (§15), and the round log (§17). | Edit spec sections only when a design decision changes, marking superseded text with `[Rn erratum: …]` (never rewrite history). Append one §17 entry per round recording decisions, rationale and results. Section numbers §1–§15 are cited from source files — keep them stable. |
| `doc/SSP_STATUS.md` (this file) | **Now, next, how.** Current state, the active milestone's plan and checklist, the next milestone's plan, backlog, owner questions, hazards, commands, conventions, environment. | Rewrite freely: it must always describe the present. Update §1–§5 at the end of every session (it is the hand-off). When a milestone completes, record its outcome as a §17 round in the design doc and shrink its plan here to a one-line entry in §1. |

Companions (stable references): `doc/SSP_REGS.md` (generated from
`ssp/regs/ssp_regs.csv`, never hand-edit), `doc/SSP_PANEL_UX.md` (panel UX,
P2), `doc/t80_reg_debug_vector.md` (T80 `REG` vector), `doc/SDRAM_REWORK_PLAN.md`
(SDRAM client roadmap), `doc/SSP_RISCV_REVIEW.md` (historical review).
Planning documents are not kept outside `doc/`.

**Reading order for a new session:** this file §1–§6, then `AGENTS.md`
(project rules), then the `SSP_DESIGN.md` sections the active milestone cites.

---

## 1. Current state

### 1.1 Milestones

| Phase / milestone | State |
|---|---|
| P0 core bake-off | Closed R23: FemtoRV32-gracilis (D-37), `ADDR_WIDTH=30` (D-34); picorv32 vendored as fallback |
| P1a "first light" | Closed R35: on hardware, escape → park → examine/deposit → resume; OM-off transparency proven |
| R36 | Terminology pass ("Z80" not "guest", "RV RAM" not "DTCM") |
| P1b M1 (R37) | Done: monitor `I`/`O`/`MAP`/`PHY`/`LOG` + colour stubs; port I/O independent of address mode; smoke Part E |
| P1b M2 | **Shelved R38**: direct MMU frame taps + `MAP_CHANGED` IRQ (regmap slots reserved, read 0) |
| P1b M4 single-step (R39) | Done in simulation (details: `SSP_DESIGN.md` §17 R39); needs the owner's hardware check (§2) |
| **P1b M3 physical memory client** | **Next** (§3); log entry R40, smoke Part G |

### 1.2 What is on hardware

The board was last flashed for P1a first light (R35). M1 (R37) and everything
after it need an owner rebuild: `tools/build.sh`, then `make install`. The
committed factory ROM (`ssp/fw/forth_rom.mif`) is current through R39.

### 1.3 Repository and build facts

- Register map: `ssp/regs/ssp_regs.csv` is canonical (72 regs / 140 fields
  at R39). `make -C sim regmap regmap-check` regenerates and drift-checks.
- RTL: `ssp/rtl/` (`ssp_top.v`, `ssp_bridge.v`, `ssp_uart.v`, `z80_bus_mux.vhd`,
  `ssp_tramp.vhd`, `ssp_sdp_ram.vhd`, generated `ssp_regs.vh`/`_pkg.vhd`),
  integrated in `MicrocomputerZ80CPM.vhd` and `MrZ80.sv`; T80 park gate in
  `Components/Z80/T80.vhd` (R25).
- Firmware: Mecrisp-Quintus port in `ssp/fw/`; monitor in
  `ssp/fw/apps/monitor.fs` (`E D G R I O MAP PHY LOG S F ?`).
- Verification: Verilator lanes in `sim/ssp/`, GHDL lanes in `sim/`
  (commands in §7).

### 1.4 Known gaps

- **WDG_PARK expiry** only latches `park_dead_l`; D-13 says it also demotes
  the console and releases the firmware hold. Awaiting an owner ruling (§5).
- Physical (28-bit) examine/deposit: the monitor refuses with
  `PHYSICAL E/D PENDING M3` until M3 lands.

### 1.5 Baseline: what exists and where

| Area | State |
|---|---|
| Cores | FemtoRV32-gracilis (selected) and picorv32 (fallback) in `Components/RISCV/`, provenance in `PROVENANCE.md` |
| Firmware base | Mecrisp-Quintus 1.1.2a port in `ssp/fw/` (RAM dictionary, no flash, D-32). Kernel source referenced in place from `~/mecrisp-quintus` (GPLv3; compliance per H-3/R16). Build: `cd ssp/fw && make` → `ssp/fw/build/mecrisp-ssp.hex` (build dir git-ignored). Dictionary build (D-35): `make -C sim dict-p1a` → `ssp/fw/build/mecrisp-ssp-p1a-app.hex`; factory image `make -C sim fw-rom` → committed `ssp/fw/forth_rom.mif` (D-38) |
| SSP RTL | `ssp_top.v` (core + MROM/RV RAM + decoder + bridge + UART + console mux), `ssp_bridge.v` (register file, park controller, D-30 sequencer for FW mem/IO kicks, WDG×2, `TICK_US`, R39 step sequencer), `ssp_uart.v` (8N1, 128-byte RX FIFO, escape recognizer, OQ-22 byte relay), `z80_bus_mux.vhd` and `ssp_tramp.vhd` (instantiated in the CPM core since R33) |
| T80 changes (R25) | `T80.vhd`/`T80_Pack.vhd`/`T80s.vhd`: `would_boundary` export + boundary park gate (BusAck only when the next state is M1; prefix-gated). Wired since R33: `n_BUSRQ <= ssp_busrq_n`; `FREEZE_req_n` is a dead port (R28 finding). With the SSP idle the core is unchanged (P-B) |
| GHDL integration benches | `integ-park` (R-40: every park on an instruction boundary vs an unparked reference), `integ-mux` (R-42: mux + real T80 + engine model), `integ-core` (R-42 against the real SDRAM/BRAM/MMU fabric), `cycle-golden` + `engine-golden` (engine strobes == real T80, per T-state; committed `sim/ssp/golden_cycles.txt`), `tramp` (`G aaaa` vs the real T80, 176 checks) |
| Verilator lanes | `p1a`: real `ssp_top` + behavioural Z80 (`sim/ssp/z80_bfm.v`, no FREEZE-gate model) + pin-level serial; `smoke-p1a` Parts A–F; `tramp-p1a`; `uart-fifo` |
| Hygiene | Build dirs and waveform dumps untracked and ignored. History was purged once (R26; old→new hashes `513a539`→`9ef7346`, `ba6cc92`→`d3a8b33`, `07a4ee9`→`12ad50b`) |

---

## 2. M4 single-step (R39): done, awaiting hardware

Spec `SSP_DESIGN.md` §7.2c; results, review findings and mutation outcomes in
§17 R39. Owner rulings: M4 before M3; INT masked for the whole step sequence;
on timeout keep the request asserted and report `STEP ERR`; `S` / `S n` /
bare-CR repeat, `T` reserved.

### 2.1 Owner action: hardware check

Rebuild (`tools/build.sh`, then `make install`) and try: escape, `D` a few
NOPs plus a `JP`, `G aaaa`, escape, then `S`, `S 10`, bare CR, a key during
`S 100`. Expect one line per step (`PC: b b b b AF BC DE HL SP`), `HALTED` on
a HALT, `STEP ERR` only if the Z80 never reaches a boundary. Not exercised in
simulation: real INT sources (none exist yet), real clock-tick masking.

### 2.2 Verification tooling added (reuse for later milestones)

| Tool | Use |
|---|---|
| `sim/tb_integ_park.vhd` `step_once`/`step_window` | bridge-exact step sequence on the real T80; `STEP_OBSERVE=false sim/run_integ_park.sh` is the no-observe mutant |
| `sim/tb_integ_core.vhd` INT-gate block | forces `n_INT` via external name, watches `n_INT_ssp` |
| `make -C sim seam-check` (`sim/check_seam.py`) | `MrZ80.sv` seam wiring; run after any top-level or port change |
| `PARTS=F sim/ssp/p1a_smoke.sh` | run selected smoke parts only (default `ABCDEF`; add `G` for M3) |
| `z80_bfm.v` T80-contract model | cen-sampled request, release ends boundary, `halt_n`, `+STEPHANG=<n> +STEPHANG_CLKS=<c>` |
| harness `0x02` eager key, `+BRKTX=<n>` | send a key mid-output |
| `[p1a-step]` events (`p1a_sim_top.v`) | kick / regrant (fetches, pc) / int_hold edges / timeout |
| `STEP_TIMEOUT_T` parameter | `ssp_bridge`/`ssp_top`; p1a lane uses 1M clocks |

### 2.3 Known limitations (documented, accepted)

- Z80 serial output from stepped instructions is dropped (the monitor owns
  the console TX).
- Stepping an `EI; HALT` wait loop shows `HALTED` indefinitely: the masked INT
  cannot wake it. `G` lets it run.
- Block instructions step once per iteration; step-over (`X`) needs P2
  breakpoints or the trampoline.
- MCYCLE/TSTATE modes are reserved (rejected `STEP_ERR`) until the
  `freeze_any` milestone.
- The step logic lives in the Verilog bridge, not the VHDL side D-33
  specifies (rationale `SSP_DESIGN.md` §7.2c); hence the two-half proof.
- `R` typed while a step is hung waits (up to ~200k polls) for the late park
  instead of saying NOT PARKED (monitor `m-parked?`).
- The monitor dictionary does not define every register constant; Forth test
  lines use raw addresses where needed (e.g. `$20000010` HALT_REASON).

---

## 3. Next — M3: parked physical memory client (`ssp_mem_client`)

Status: not started; plan written 2026-10-28, owner-approved design (`SSP_DESIGN.md` D-15-P, §9.2 with the R35 revision: SDRAM window only, BRAM page 8192 rejected `?`). Round number for its log entry: **R40**. M4 also edits `ssp_bridge.v`, so step 3 builds on the committed M4 bridge.

### 3.1 Goal

Give the SSP monitor **physical (28-bit) examine/deposit** (D-15-P, §9.2 of
`doc/SSP_DESIGN.md`), per owner ruling R35-rev: **SDRAM physical window only**
(pages 0..8191 = phys 0x0000_0000..0x07FF_FFFF). Physical ops to page 8192
(BRAM at 0x0800_0000) are **rejected `?`**; BRAM stays logically reachable only.
`MD`/`AR`/`DR` regs and the modal `PHY`/`LOG` verbs already exist (R37); R37's
MD-physical *reject* branch becomes a *route* to the new client.

**Architecture invariant (R35-rev/R38 + owner sign-off 2026-10-28): `z80_bus_mux`
is NOT touched.** It has exactly two masters (T80, cycle-faithful engine).
Physical traffic bypasses the mux AND the MMU, landing at the SDRAM client
interface downstream. Exclusivity is inherited: all SSP ops are parked-only and
the bridge serializes to one outstanding op, so client vs engine vs primary-CPU
SDRAM traffic cannot co-occur. `tb_integ_mux` + `cycle-golden` re-run UNMODIFIED
are the standing proof that Z80 cycle timing is unaffected.

### 3.2 Memory map facts

- phys = page << 14; page 14 bits. SDRAM = pages 0..8191 (128 MiB => addr[27]=0;
  CPM entity `sdram_addr` is 27 bits = phys[26:0]).
- BRAM page 8192 => phys bit 27 set (`0x0800_0000`) — window check rejects it.
- CPM SDRAM client ports (`MicrocomputerZ80CPM.vhd` ~L86-91):
  `sdram_addr(26:0)`, `sdram_din(7:0)`, `sdram_we`, `sdram_rd` out;
  `sdram_dout(7:0)`, `sdram_ready` in. Byte lane via addr[0] handled at the
  controller layer (`MrZ80.sv`: `sdram2.sv` sdram_32r8w @ clk_ram ~112 MHz,
  `sdram_*_mux` signals, `sdram_ready_mux` = 1-clk clk_sys completion pulse).
  Byte-write fidelity is inherited from the proven primary path; no new DQM logic.
- Primary client FSM lives inside CPM: `sdram_state_t = (S_IDLE, S_REQ, S_HOLD,
  S_DONE, S_WPOST, S_GAP)` (signals `sdram_addr_r`, `sdram_din_r`,
  `sdram_we_reg`, `sdram_rd_reg`, `sdram_wait_n`, speculative reads).
  Client protocol to mirror: hold request level stable until ready pulse; GAP
  between transactions; ready is stall-tolerant (refresh).

### 3.3 Step 1 — unit RTL + GHDL bench (first session; self-contained)

New `ssp/rtl/ssp_mem_client.vhd` (VHDL per D-33 language seam). Entity sketch:

    clk, rst_n                          -- clk_sys domain
    -- bridge seam (via ssp_top pins, plain signals)
    ph_req   : in  std_logic;          -- level or pulse; decide+document (recommend level, held until done/err, self-timed out by bridge)
    ph_we    : in  std_logic;
    ph_addr  : in  std_logic_vector(27 downto 0);
    ph_wdata : in  std_logic_vector(7 downto 0);
    ph_done  : out std_logic;         -- 1-clk pulse
    ph_err   : out std_logic;         -- 1-clk pulse with done on reject/timeout-assist
    ph_rdata : out std_logic_vector(7 downto 0);
    -- park + primary-idle gates (from CPM fabric)
    parked   : in  std_logic;         -- busrq asserted AND busack confirmed
    prim_idle: in  std_logic;         -- sdram_state = S_IDLE
    -- borrowed SDRAM client wiring
    c_addr   : out std_logic_vector(26 downto 0);
    c_din    : out std_logic_vector(7 downto 0);
    c_we     : out std_logic;
    c_rd     : out std_logic;
    c_dout   : in  std_logic_vector(7 downto 0);
    c_ready  : in  std_logic;
    borrow   : out std_logic;        -- select for the CPM-layer port muxes

Mini-FSM: IDLE -> (admit: ph_req ∧ parked ∧ prim_idle ∧ idle) -> check
`ph_addr(27)='1'` (page >= 8192) => ERR pulse, zero bus activity; else
REQ (drive addr/din/we|rd via borrow mux) -> HOLD (wait c_ready, stall-ok) ->
DONE (capture dout on read; pulse ph_done) -> GAP (1-2 clks) -> IDLE.
Abort on rst_n. `ph_req` released only when bridge sees done/err (bridge owns
timeout; client may add a generous counter as defense-in-depth).

New `sim/tb_mem_client.vhd` + `sim/run_mem_client.sh` + Makefile target
`mem-client` (pattern-match `run_integ_*.sh`). Bench drives the seam + a mock
SDRAM controller (random-ready backpressure, addr/data pattern oracle) and the
parked/prim_idle gates. R-27 **minus BRAM legs** check list:
1. parked read/write byte fidelity, randomized addrs (SDRAM window incl. odd
   byte addresses) vs oracle -> ph_rdata / controller-captured data exact.
2. **zero bus activity while Z80 runs**: parked='0' blocks every attempt;
   c_we/c_rd/c_addr quiescent. (Hard assertion, the R-27 headline.)
3. admission reject: prim_idle='0' -> ph_err, no wire activity.
4. page-8192 (and addr[27]=1 generally) reject -> ph_err, zero activity.
5. refresh-stall tolerance: ready stretched N cycles mid-transaction -> completes.
6. back-to-back ops: GAP honored; no merged/glued transactions; AR semantics stay
   (each op gets its own req).
7. abort-on-reset mid-HOLD: port released, no ph_done after reset, re-admit ok.
8. mutual-exclusion assertions: never (primary we/rd asserted) AND (client
   we/rd asserted); borrow only toggles when both sides idle.
9. err/done pulse widths = 1 clk_sys; ph_rdata valid only with done.
Mutation-test the bench (e.g. kill the parked gate -> check 2 dies; kill window
check -> check 4 dies) — same discipline as R-37 Part E.

### 3.4 Step 2 — fabric integration (CPM layer borrow)

- `MicrocomputerZ80CPM.vhd`: new entity seam ports **with defaults**
  (`ph_req/we <= '0'`, addr/data zero, `ph_done/err/rdata` outs) so every
  existing instantiation/wrapper compiles untouched; instantiate
  `ssp_mem_client`; drive `parked`/`prim_idle` from existing nets (busack/busrq
  + `sdram_state`); the ONLY other change: 2:1 borrow select on the four output
  drivers (sdram_addr/din/we/rd = borrow ? client : primary FSM regs) and
  steering of dout/ready back to the client. Select cannot toggle mid-transaction
  by construction (assert it).
- `sim/MicrocomputerZ80CPM_sim.vhd`: sync after the entity change
  (`sim/check_sync.sh` must pass).
- `MrZ80.sv`: wire `ssp_top` <-> CPM seam pins (same place Z80 nets connect).
- Re-run ALL existing GHDL lanes unmodified-in-intent: sync, tramp, integ-park,
  integ-mux, integ-core, cycle-golden -> all green BEFORE touching the bridge.

### 3.5 Step 3 — bridge physical branch (Verilator side)

- `ssp/rtl/ssp_bridge.v`: R37 branch `if (!park_act || (md_phys && !kick_isio))
  eng_err` -> route: `MD=1 ∧ !IS_IO` kick emits ph_req/ph_we/ph_addr(AR[27:0])/
  ph_wdata; SEQ_BUSY held until ph_done; ph_err or stall-timeout -> ENGINE_ERR;
  read result -> MEM_DATA; new `ENG_STAT.LAST_OP` codes (propose 4'd8=PH_RD,
  4'd9=PH_WR — confirm no CSV collision, document in CSV field text). I/O
  exemption unchanged.
- `ssp/rtl/ssp_top.v`: pass-through seam pins.
- CSV (`ssp/regs/ssp_regs.csv`): MD description "rejects MEMORY kicks" ->
  "routes MEMORY kicks to parked physical client (M3)"; MEM_CTL/ENG_STAT text +
  `make -C sim regmap` + regmap-check.
- `sim/ssp/p1a_sim_top.v` + `tb_p1a_main.cpp`: mock client (instant-response
  default, `+PHDELAY=n` stretch, oracle pattern on physical addr e.g.
  addr^addr[15:8]-ish — define and reuse, page-8192 -> err; surface counters on
  the `[p1a] done:` line: `ph=N(aa,dd)` like io_wr).
- New **Part G** in `sim/ssp/p1a_smoke.sh` (Part F is M4's): `PHY` then physical `E aaaaaaaa N` /
  `D` vs mock oracle, page-8192 `E 08000000` -> `?`, stall case via +PHDELAY,
  error reporting; I/O + MAP still work in PHYSICAL (already true since R37).

### 3.6 Step 4 — FW + ROM

- `ssp/fw/apps/monitor.fs`: retire `PHYSICAL E/D PENDING M3` refusal
  (`m-phystest`); with MD=1, `E`/`D` parse up to 8 hex digits (drop the `$FFFF`
  mask mode-conditionally; AR keeps 28 bits), examine lines print 8-digit phys
  (word `m-h7` exists), row wrap at 2^28 not 2^16, page-8192 pre-check -> `?`
  (defensive; RTL also rejects). Update `PHY` msg text + help string. `MAP` can
  cross-check one physical read per frame (optional flourish — keep cheap).
- OQ-24 (explicit PE/PD verbs) stays OPEN — modal surface only; owner letter
  lands at the ODT pass, no RTL impact either way.
- Regenerate factory ROM: `make -C sim fw-rom` (recommit `ssp/fw/forth_rom.mif`
  — recommit-on-FW-change rule).

### 3.7 Step 5 — regression, docs, commit

Full sweep: regmap-check, lint-ssp, p1a, dict-p1a, smoke-p1a (A-G), tramp-p1a,
uart-fifo, GHDL sync + tramp + integ-park + integ-mux + integ-core +
cycle-golden + mem-client. Docs: `SSP_DESIGN.md` §9.2 rewritten to what actually landed
(P1 minus BRAM leg), §17 entry **R40**, this file (§1 milestone table; §4 backlog). Open owner items to keep visible: OQ-24 letters, WDG_PARK
expiry semantics, OQ-10/OQ-18.

### 3.8 Key references

- `doc/SSP_DESIGN.md`: D-15/D-15-P (decision table), §9.1 (parked-only ops),
  §9.2 (physical path, R35-rev tag), R-27 (acceptance), R37/R38 log entries.
- `doc/SSP_STATUS.md` §4 (backlog context for M3).
- R37 precedents to reuse: m-wait ENG_STAT error check in `monitor.fs`;
  Part E structure in `p1a_smoke.sh`; dbg counters pattern in `p1a_sim_top.v`
  (widen 8-bit signals explicitly for Verilator -Wall: `{24'd0, sig}`).

---

## 4. Backlog after M3 (P1b remainder)

Owner priorities from P1a first light (R35), with status:

- **(a)** Physical 28-bit examine/deposit → M3 (§3).
- **(b)** Z80 I/O port commands → **done** (M1, R37).
- **(c)** MMU inspection → **done**: `MAP` reads the `$B0..$BF` engine path,
  permanent per R38 (direct frame taps and `MAP_CHANGED` shelved; regmap
  slots reserved). Reactivation path if a live-running consumer ever appears:
  the tap.
- Remaining P1b scope (`SSP_DESIGN.md` §15): `PR`/mailbox, MROM/MPKG mount
  path (monitor-only reset), reset stretcher, T80s MC/TS/ALT export
  completion (needed for MCYCLE/TSTATE stepping via `freeze_any`), ODT skin,
  real ANSI SGR colours (the `col-*` stubs in `monitor.fs`).
- Bridge board design (OQ-09) runs in parallel.
- P2 and later: see `SSP_DESIGN.md` §15 (panel engine, breakpoints and
  step-over, `ssp_sd` background reads, …).

---

## 5. Owner questions outstanding

| # | Question | Blocks |
|---|---|---|
| — | WDG_PARK expiry semantics: should expiry also demote the console and release the firmware hold (D-13), or only latch `park_dead_l` as now? | P1b (watchdog completion) |
| OQ-24 | Physical-access command surface: modal `PHY`/`LOG` (current default) vs explicit physical verbs | M3 FW surface (no RTL impact) |
| OQ-10 | Exact "Reset System" scope | P1b |
| OQ-18 | Board-freeze UX values | P2 |

Settled this period: M4-before-M3, INT masked while stepping, step timeout
policy, `S` letter semantics (R39); MMU tap shelving (R38); port I/O
address-mode independence (R37). Full open-question list: `SSP_DESIGN.md` §14.

---

## 6. Hazards and lessons (read before debugging)

- **Mecrisp-Quintus has no autocorrect** or any input-rewriting feature.
  Confirmed by grep of the kernel source. If console output looks
  "rewritten", suspect harness echo (`+ECHO`) interleaving with the kernel
  echo.
- **Probe the CPU-visible node.** The R26 RXDATA bug hid behind a probe of an
  internal register that "should" have matched. For bridge reads, check
  `u_dut.mem_rdata` in the cycle after `rd_fire` (the `POPD` probe now does).
- **Launch-edge capture:** `ssp_bridge` captures `q_reg` into `q_hold` on
  the launch edge. Anything that updates on the same edge (pops, read-clears)
  must feed `q_reg` combinationally.
- **Verilog `$display` goes to stdout**, interleaved with console bytes;
  harness messages go to stderr. Separate them when reading output.
- **Bridge register lanes (R28):** byte lane *n* of a multi-byte register
  takes `mem_wdata[8n+7:8n]` (`w1/w2/w3`), never `w`. A test that writes
  such a register with `sw` and reads it back is the only thing that catches
  this; `p1a_tramp.sh` covers TRAMP_ADDR and CTRL.
- **Mecrisp line latency:** ~170k cycles per input line (each token is a full
  dictionary search). Input is buffered by the 128-byte RX FIFO (R29/D-41: ~11 ms of line-rate
  input, ~3 lines), so a script of a few lines needs no `+RXGAP` pacing; for
  longer scripts pace with `+RXGAP=<cycles>`. Put an in-band pause (byte `0x01`, `+PAUSE=<cycles>`, default 400000)
  before an escape that follows a command, or the late-executing line
  overwrites the escape's hardware hand-over (hold/own).
- **`+DBG` is noisy:** the `p1a-mt3` probe in `p1a_sim_top.v` prints on
  every cycle while the monitor TX sits at the end of a byte (thousands of
  lines). Redirect to a file and grep; consider tightening that probe.
- **Edits can silently not land** (seen in earlier sessions with batched
  parallel edits). Grep-verify each edit before rebuilding.
- **RX FIFO is 128 bytes (R29, D-41; was 8).** A sender that outruns the
  polled FW for more than ~11 ms still overflows (`STAT.RX_OVERRUN`, byte
  dropped, no RTS/CTS). The p1a harness waits for TX quiet before the rest of
  the input; `+RXGAP=<cycles>` paces bytes. The depth is `ssp_uart.FIFO_LOG2`
  (7); the array must keep its MLAB `ramstyle` hint (async head read) --
  re-measure with `bakeoff/uartfifo128` if the FIFO logic changes. Unit bench:
  `make -C sim uart-fifo`.
- **Long scripts into Mecrisp need `+LINEWAIT=1`** (waits for each line's
  `ok.`), the monitor `+LINEWAIT=2 +QUIET=<cycles>` (TX quiet). Without them
  a slow line lets the sender run ahead and overflow the RX FIFO, which shows
  up as characters silently missing mid-line. The harness takes the **first**
  occurrence of a plusarg, so put overrides before defaults.
- **A `variable` in `compiletoflash` needs an initial value** (`0 variable x`);
  without it Mecrisp reports `Stack underflow` and the rest of the build
  derails.
- **Before `console_own` drops, drain the UART** (`m-drain` in `monitor.fs`):
  the last characters are otherwise cut off.
- **Monitor silent until escape** (R25): with `+OM=1`, nothing from the FW
  appears on the pin before the escape byte; that is correct.
- **um80 ignores `.PHASE`/`.DEPHASE`** (see `AGENTS.md`).
- **Do not commit intermediates** (`AGENTS.md` "What not to commit"). Stage
  files by name. `ssp/fw/build/` is ignored; the p1a lane reads
  `ssp/fw/build/mecrisp-ssp.hex`, so build the FW first on a fresh clone.
- The REVERTED SDRAM fix noted at the `S_DONE` state must not be retried
  (`SDRAM-review-handoff.md`).
- **Forth definition order:** Mecrisp needs every word defined before it is
  used. `dict-p1a` reports a forward reference as `not found` (R39 review B6).
- **Both simulation halves stub the seam:** a wiring or polarity bug at the
  `ssp_top` ↔ CPM boundary (R39 B1/B2) is invisible to the Verilator *and*
  GHDL lanes. Check top-level connectivity explicitly.

---

## 7. Commands and simulation facts

### 7.1 Command reference

```sh
# Firmware
cd ssp/fw && make                 # -> build/mecrisp-ssp.hex (silicon/stub map)
make -C ssp/fw qemu run-qemu      # qemu smoke variant

# Register map (after editing ssp/regs/ssp_regs.csv)
make -C sim regmap regmap-check

# Verilator lanes (run from repo root)
make -C sim lint-ssp              # ssp_top + bridge + uart + gracilis lint
make -C sim smoke-gracilis dict-gracilis    # P0 stub lane (gracilis)
make -C sim smoke-stub dict-stub            # P0 stub lane (picorv32)
make -C sim smoke-qemu dict-qemu
make -C sim bench-gracilis        # cycle benchmarks (R22)
make -C sim p1a                   # P1a lane -> sim/ssp/obj_p1a/ssp_p1a
make -C sim p1a-vcd               # traced twin, +VCD -> sim/ssp/p1a.vcd
make -C sim tramp                 # G aaaa: ssp_tramp vs the REAL T80 (GHDL, 176 checks)
make -C sim tramp-p1a             # G aaaa: FW-side handshake on the p1a lane
make -C sim uart-fifo             # ssp_uart RX FIFO unit bench, depths 8 and 128 (iverilog)
make -C sim dict-p1a smoke-p1a    # monitor dictionary build (~45 s) + operator-session smoke (~60 s)
make -C sim integ-park integ-mux cycle-golden   # GHDL, real T80 (seconds each)
make -C sim engine-golden         # real bridge engine vs the golden T80 waveforms

# P1a interactive run (escape = ^] = 0x1d)
printf '\x1d1 2 + . cr\r' | ./sim/ssp/obj_p1a/ssp_p1a \
  +ROM=ssp/fw/build/mecrisp-ssp.hex +OM=1 +MAXCYCLES=12000000 \
  +IDLE=2000000 +ECHO=0
# expected tail: "1 2 + . cr 3" / " ok."

# GHDL lanes (from repo root)
sim/check_sync.sh
sim/run.sh; sim/run_cpuregs.sh; sim/run_ixmin.sh; sim/run_ixstack.sh
sim/run_forth.sh; sim/run_frontpanel.sh

# Quartus (remote, tycho)
tools/build.sh synth              # analysis & synthesis
tools/build.sh                    # full compile -> output_files/MrZ80.rbf
make install                      # scp rbf to host 'mister'
```

**p1a plusargs.** Harness (`tb_p1a_main.cpp`): `+MAXCYCLES=` `+IDLE=`
(stop after this many cycles of TX silence once input is exhausted)
`+RXAT=` (send the first input byte at this cycle; default 400000)
`+ECHO=0/1` `+PAUSE=` (length of an in-band `0x01` input pause) `+VCD` (traced build only); env `TXTRACE=1` stamps each TX
byte. RTL (`p1a_sim_top.v`): `+ROM=` `+DUMP=` `+OSD_OK=0/1` `+OM=0/1`
`+WAIT` (engine wait-state injection) `+RVRST` `+RVRST_AT=` `+NOGUEST`
`+RXGAP=` `+DBG` (event traces on stdout: RX bytes, escape, ownership,
FIFO push/pop, TXDATA writes). Exit codes: 0 ok, 3 nothing transmitted,
1 bus/ROM-illegal errors.

### 7.2 Simulation infrastructure facts

- **Two flows by language (D-33):** RV side in Verilog under Verilator
  (`sim/ssp/`), Z80 side in VHDL under GHDL (`sim/run_*.sh`,
  `sim/tb_*.vhd`). The seam is the `ssp_top` port list. Quartus mixes
  languages freely; this only affects simulation.
- **Why `*_sim.vhd` copies exist:** GHDL rejects user re-implementations of
  `STD_LOGIC_ARITH`/`STD_LOGIC_UNSIGNED`. `sim/sim_compat_pkg.vhd` supplies
  the operators; `MicrocomputerZ80CPM_sim.vhd`, `bufferedUART_sim.vhd`,
  `sd_controller_sim.vhd` are copies with only the `use` lines redirected;
  `sim/check_sync.sh` enforces sync. **Resync gotcha:** the real top level
  has no `use ieee.numeric_std.all`, so the redirect must be the pair — line
  18 → `use ieee.numeric_std.all;`, line 19 → `use work.sim_compat_pkg.all;`.
  Any edit to the top level must resync in the same change (consider
  generating the copy with `sed` in the runner — propose to the owner).
- `tb_inir_race` hitting the 20 ms cap with 0 mismatches is documented
  known-good partial behaviour (`sim/STATUS.md`).
- Behavioural stand-ins available: `behav_ram_rom.vhd`, `behav_display.vhd`,
  `sdram_cdc_fake.vhd`. `testbenchs/` (sic) holds timing dumps, not HDL.
- The p1a BFM is **not** cycle-exact T80: it accepts FREEZE only at its own
  instruction boundaries. The real gate is proven only by the GHDL
  integration benches (`integ-park`, `integ-mux`, `integ-core`).

---

## 8. Conventions (owner)

- **Rounds:** each owner session is a round `Rn` in `SSP_DESIGN.md` §17;
  decisions get `D-nn` rows in §2 (with rejected alternatives); open
  questions are `OQ-nn` in §14 with a lean. Status tags
  `[verified]/[decided]/[proposed]/[open]/[deferred]`. Version stays
  v1.0-draft; the round number is the real version.
- **Never rewrite design history.** Mark wrong earlier statements with an
  inline `[Rn erratum: …]`; superseded text stays.
- The owner usually accepts a recommendation set with targeted
  modifications — implement the modification exactly and log the declined
  alternative. For real choices use the question tool, recommended option
  first, labelled "(Recommended)".
- **Commits:** at the end of each step/round, descriptive message via
  heredoc (`git commit -F - <<'MSG'`; zsh breaks on `"` inside `-m`). Stage
  files explicitly.
- Naming is canonical since R13: `ssp_*` modules, `ssp/rtl`, `ssp/fw`,
  `SSP_CTRL`/`SSP_CHAIN`, FW word `PAGE n`. "ODT" only for Intel heritage.
- Editing `SSP_DESIGN.md` (~2400 lines, very long table rows): use the edit
  tool with a short unique substring; for larger moves, a Python script with
  `assert s.count(old) == 1`. Verify no CR bytes: `grep -c $'\r' <file>` → 0.
- **Documents:** two SSP documents with the update rules in §0. Plans live in
  this file, not in separate plan files.
- Update `HARDWARE.md` incrementally with each landed surface, and keep the
  `REQUIREMENTS.md` item 1 note current (carried from the retired
  `SSP_DESIGN.md` §16 checklist).

---

## 9. Reference notes

### 9.1 FemtoRV32-gracilis (`module FemtoRV32`)

- Instantiate with `ADDR_WIDTH=30` (default 24 aliases the memory map) — D-34.
- `reset` is active-low; `RESET_ADDR` defaults to 0.
- Bus: `mem_rstrb` one-cycle read strobe, data expected next cycle unless
  `mem_rbusy` (tied 0 here — launch+1 native, D-36); writes via non-zero
  `mem_wmask`, stall with `mem_wbusy`.
- No trap/halt output: `STATUS.RV_TRAP` reads 0 (reserved); liveness is
  `STATUS.RV_ALIVE` (R25).
- File-scope `` `define NRV_* `` macros are global within a Quartus
  compilation — harmless unless a name collides.
- Register file is `registerFile[31:0]` (hierarchical probes:
  `u_dut.core.registerFile[n]`, `u_dut.core.PC_new`, `u_dut.core.state`).
  Mecrisp uses `s1` (x9) as data-stack pointer and `s0` (x8) as TOS.

### 9.2 SSP memory map and FW console

ROM `0x0000_0000` (64K; writable only in dictionary window
`0x4400..0x10000`, D-35), RV RAM `0x1000_0000` (64K), bridge
`0x2000_0000` (4K, decode `mem_addr[31:12] == 20'h20000`, word index
`mem_addr[11:2]`). FW console (`ssp/fw/terminal.s`): TXDATA `+0x120`,
RXDATA `+0x124`, STAT `+0x128` (bit0 tx_ready, bit1 rx_avail, bit2
overrun), CTRL `+0x12C`.

### 9.3 Codebase anchors

- `MrZ80.sv`: `module emu`; OSD config string ~line 380–400; status bits in
  use: 0 (reset), 9–11 (baud O9B), 12 (serial port select), 13 (boot-load
  target), 14 (flow control), 15 (reset after mount), 16–19 (panel
  profile). Serial routing ~lines 698–749. `MicrocomputerZ80CPM` instance
  ~line 987.
- `MicrocomputerZ80CPM.vhd`: T80s instance `cpu1` ~line 384; FREEZE tie-off
  ~407; `n_BUSRQ <= '1'` ~416; `cpu_wait_n` ~475; capture chain
  `CHAIN_BITS => 384` ~803 (292 bits used; BUSRQ/M1/HALT/BUSAK lamps at
  256–259 already exist); SDRAM speculative-read commentary ~980–1090.
- `SIGNAL-CAPTURES.md` is the authoritative capture-chain map; update it in
  the same change as any chain edit.
- LED profile tooling: `Components/FRONTPANEL/tools/` (YAML → `.fpp`).
- History docs worth knowing: `HISTORY.md`, `SDRAM-review-handoff.md`,
  `sim/STATUS.md`.

---

## 10. Environment facts (verified 2026-10-26/27)

### 10.1 Local workstation (Debian forky/sid)

| Tool | Version | Notes |
|---|---|---|
| `riscv64-unknown-elf-gcc`/binutils | 15.3.0 / 2.47 | flags `-march=rv32imc_zicsr_zifencei -mabi=ilp32`; ship your own linker script (default picolibc script breaks `-nostdlib` links) |
| `verilator` | 5.048 | |
| `ghdl` | 6.0.0 | |
| `iverilog` | 13.0 | version flag `-V` |
| `yosys` | 0.66 | |
| `gtkwave` | 3.3.127 | needs a display |
| `qemu-system-riscv32` | 11.1.2 | `-M virt -cpu rv32 -bios none -kernel <elf>` |
| `gdb-multiarch` | — | qemu `-s -S`, `target remote :1234` |
| um80/ul80 | — | only via `tools/z80tool.sh`, `um80.sh`, `ul80.sh`, `z80asm.sh` |
| `pasmo` | present | **forbidden** for Z80 code |
| `docker`, Questa | missing | Docker only on `tycho`; GHDL replaces Questa |
| `git-filter-repo` | missing | `git filter-branch` used for the R26 purge |

### 10.2 Network from the agent shell

- `git push`/`fetch` to `origin` (`git@github.com:lmamakos/MrZ80`, SSH)
  **works** (verified 2026-10-27, R27 push; earlier notes said SSH was not
  authorized — no longer true for this repo). `git clone https://...` of
  other repos still fails (credential prompt, no TTY).
- Works: `curl` to `raw.githubusercontent.com` (single files) and
  `api.github.com` (unauthenticated, ~60 req/h; use `-L`).
- `webfetch`/`websearch` tools work.

### 10.3 Remote Quartus (`tycho`)

- `tools/quartus_build.sh` runs Quartus 17.0 in Docker on `tycho` against
  `Projects/z80fp/MrZ80`, **the same tree as this workspace** (no sync step;
  owner-confirmed). The script's header comment naming
  `RomWBW_MrZ80_MiSTer` is stale. `ssh -t` may complain without a TTY; do
  not edit the script without the owner's agreement.
- Bake-off fits (R21, `bakeoff/`): gracilis 1,128 ALM / 540 reg / 64.13 MHz;
  memory 130 M10K blocks for 64K ROM + 64K RV RAM.

---

## Appendix A. Completed P1a execution notes (R26–R35, kept for recipes)

The ordered P1a plan and the per-step working notes, preserved because
source comments and later work still rely on their recipes (for example the
`CTRL` register sequence for `G aaaa` in step 1, item 2). Design rationale
for each round is in `SSP_DESIGN.md` §17. Commit history: `git log --oneline`.

### A.1 R26 fixes

1. **RXDATA one-pop lag** (`ssp_bridge.v`): the CPU received the byte from
   the previous read, so Enter was seen one key late. RXDATA now reads the
   combinational FIFO head; empty read returns 0.
2. **Console TX mux** (`ssp_top.v`): final form
   `snac_txd = (console_own & CONN_ROUTE.out_snac) ? mon_txd : z80_txd`.
   An interim R26 edit dropped the Z80 path; that was wrong, because
   `MrZ80.sv` routes the Z80's `serial_tx` to the SNAC TX. **The monitor is
   silent on the pin until the operator escapes** — by design (R25).
3. **Harness** (`tb_p1a_main.cpp`): models an operator in two steps (first
   byte — the escape — at `+RXAT`, remaining bytes once the monitor's output
   has been quiet for 100k cycles); `+ECHO=0` fixed.

### A.2 R28: `G aaaa` hardware (design in `SSP_DESIGN.md` §7.4 / §17 R28)

- **`ssp/rtl/ssp_tramp.vhd`**: Z80-CPU-only reset vent (release stretched
  to >= 8 `cpu_cen`) + reset-vector injector (`C3 lo hi` on the first three
  reads at `$0000..$0002`, primed only if `TRAMP_EN` is set *during* reset),
  `done` pulse -> bridge hardware-clears `CTRL.TRAMP_EN`.
- **Bridge/top:** ports `tramp_arm`, `tramp_target`, `tramp_done`.
- **Tests:** `make -C sim tramp` (GHDL, real T80s, 176 checks, mutation-tested)
  and `make -C sim tramp-p1a` (firmware-side handshake from the Mecrisp REPL:
  `G $0200`, plain reset -> `$0100`, park-at-target `$0300`).
- **Bug found and fixed:** the bridge used lane-0 write data for *every* byte
  lane, so any 32-bit store to a multi-byte register was wrong (TRAMP_ADDR,
  CTRL bits 9:8, MEM_ADDR, AR, BPn, ...). All 20 lane lines now use `w1/w2/w3`.
  **Any new multi-byte register must follow that pattern.**
- **Finding:** `FREEZE_req_n` is unused in `T80.vhd`; the park request is
  `BUSRQ_n` (gated inside the T80 by `freeze_ok`). See step 4.
- BFM: now resets like a T80 (PC=0, BusAck dropped), executes a real `JP`,
  and grants a freeze with PC = next instruction.

### A.3 Ordered P1a plan (all steps done)

Each step lists the goal, the work, the files, and the exit check. Do them
in order; steps 2 and 3 can overlap. Commit at the end of each step with a
descriptive message (heredoc, see §8). Log design-level changes as a new
round (R27, …) in `SSP_DESIGN.md` §17.

#### Step 0 — Housekeeping (small, do first)

- **DONE (R30):** R24/R25 log entries written, OQ-22 closed, D-25 amended.
- `r24-p1a` is pushed to `origin` (`lmamakos/MrZ80`, owner-approved R27).
  Note: the remote named `upstream` is MiSTer-devel/MultiComp_MiSTer, the
  project this was forked from — never push there.

#### Step 1 — Monitor FW for P1a (Verilator lane) — **DONE (R30)**

*(Kept below for reference. Deviations: `F` instead of `X` for "to Forth"
because `X` is the hardware escape in ODT; `R` was implemented; the monitor
is a dedicated loop, not Forth words; R-46/R-23 are exercised by every smoke
run. Command letters are still the owner-open proposals.)*

**Goal:** the P1a FW command set running on the p1a lane, plus automated
smoke and dictionary-build scripts.

**Work:**

1. **Command set — decided R27 (D-39).** The owner redefined the P1a
   commands around what an operator needs; the old `E D G H R X` list and the
   v0.1 table (not in the repo) no longer apply. A primitive framework,
   expected to grow considerably:

   | Command | Behaviour |
   |---|---|
   | `E aaaa [n]` | Examine memory: hex + ASCII dump from `aaaa` (default length, e.g. 16 or 128 bytes — pick and document) |
   | `D aaaa` | Modify memory interactively: print `aaaa: xx ` with the current contents; a hex value replaces it, a **bare carriage return leaves it unchanged**; then advance to the next address; `.` ends the session |
   | `G aaaa` | Go: start the Z80 at `aaaa` (trampoline after reset vent, D-02 — see item 2) |
   | `G` | Continue: resume the parked CPU and hand the console back to the Z80 |

   Letters and the `.` terminator are proposals the owner left open; confirm
   if you change them. Escape already parks the Z80, so no separate halt
   command is needed. `R` (registers from `SNAP_REG0..6`, per
   `t80_reg_debug_vector.md`; prefix `*MID-INSN*` if
   `STATUS.AT_BOUNDARY`=0) is a natural early addition, not required.
   Mecrisp is a Forth: either define these as words that parse their
   arguments (`E 1000` with `hex` base; e.g. via `token`/`parse-name`), or
   write a small dedicated command loop entered on escape. The design's ODT
   protocol (§10.1: `.` prompt, uppercase responses) suggests the latter;
   choose and record it.
2. **`G aaaa` — hardware is DONE (R28); the monitor word remains.** Use the
   register-level recipe proven by `sim/ssp/p1a_tramp.sh` (all writes are
   32-bit stores of full values; keep bit 5 `ESC_BREAK_EN` or the escape is
   disabled; do NOT read-modify-write `CTRL` after the injection completes —
   hardware clears bit 4 and a stale RMW would re-arm):

   ```
   \ G aaaa  (Z80 parked, console owned: CTRL = $122)
   aaaa  SSP_TRAMP_ADDR !            \ target
   $133  SSP_CTRL !                  \ arm + vent: TRAMP_EN|hold|own|esc|Z_RST_N
   $030  SSP_CTRL !                  \ release reset, drop hold, return console
   \ plain G (no address):  $020 SSP_CTRL !   (never injects)
   \ "set PC, stay parked": $132 SSP_CTRL !   (reset released, hold+own kept;
   \    Z80 executes the injected JP and parks AT aaaa; console stays)
   ```
   After the `$030` write the monitor is muted (Z80 owns the console), so
   print any "going to aaaa" text *before* it. The T80 does not grant the
   park until an instruction boundary; the 8-`cpu_cen` vent is enforced in
   hardware, so no FW delay is needed between the two `CTRL` writes (the
   p1a lane has ~100k cycles between them anyway). OQ-05 (a breakpoint inside
   the `$0000..$0002` window) is a P2 concern: no BP logic exists yet.
3. **Print on escape, not at boot.** A banner printed while the Z80 owns
   the console is lost. Have the monitor wait for `STATUS.FW_CONSOLE_OK`
   (bit 13) and print its banner/prompt when it gains the console. The
   kernel banner comes from `welcome` in `ssp/fw/mecrisp-quintus-ssp.s`;
   the app layer decides when to talk.
4. Write `ssp/fw/apps/monitor.fs` using the generated `ssp/fw/ssp-regs.fs`
   constants. Memory/IO access goes through the D-30 sequencer:
   `MEM_ADDR`/`MEM_DATA`, kick via `MEM_CTL` (bit0 kick, bit1 read, bit2 IO,
   bit3 use shared regs), poll `STATUS.SEQ_BUSY`, read `ENG_STAT` (read
   clears; `ENGINE_ERR` set if kicked while not parked, in physical mode, or
   while busy). Park/resume via `SSP_CTRL` (see the CSV for field names).
5. **Make the BFM memory writable.** Today `sim/ssp/z80_bfm.v` answers
   engine memory reads with a fixed pattern (`addr ^ 0x5A`, ~line 195) and
   does **not** store memory writes (only I/O writes are captured). Back
   engine reads/writes with a real 64K array (it can start from the same
   pattern) so a modify/examine round trip is testable.
6. Write `sim/ssp/p1a_dictbuild.sh` and `sim/ssp/p1a_smoke.sh`, cloned from
   `sim/ssp/dictbuild_stub.sh` and `sim/ssp/smoke_stub.sh` (D-35
   `compiletoflash` capture via `+DUMP=`; artifacts in their own name space —
   do not overwrite the P0 goldens). The smoke should script: escape, `E`
   dump (check pattern), `D` session (replace one byte, leave the next
   unchanged with a bare CR, end with `.`), `E` again (verify both), `G`
   (Z80 resumes, console returns), second escape, `G aaaa` (Z80 restarts
   at `aaaa`).
7. Add an **OM-off transparency** case (`+OM=0`): every byte, including
   `ESC_CHAR`, must reach the Z80 (BFM `guest_rx_count`), no park (R-43).

**Exit:** `make -C sim smoke-p1a dict-p1a` PASS; R-43, R-46 (polled FW, IRQ
tied off) and R-23 demonstrated on the p1a lane; `lint-ssp`,
`smoke-gracilis`, `dict-gracilis` still PASS.

#### Step 2 — GHDL integration benches (real T80, VHDL side) — **DONE (R31)**

*(Kept below for reference.)* Delivered: `tb_integ_park` (R-40),
`tb_integ_mux` + the golden-waveform pair `tb_cycle_golden` / `p1a_engine_golden.sh`
(R-42), which found and fixed three engine bugs (see `SSP_DESIGN.md` R31).
**Still open for step 4:** R-42's "SDRAM/BRAM/MMU" half -- re-run `tb_integ_mux`'s
engine cycles against the real fabric once the mux is in the CPM core.

**Goal:** prove the Z80-side RTL with the real T80, MMU and SDRAM client
FSM — the BFM in step 1 does **not** model the T80 FREEZE gate.
`sim/tb_tramp.vhd` (R28) is a working template: real `T80s` in the production
configuration, `cpu_cen` 1-of-5, a protected-type memory and read-cycle log, a
wait-state generator, and park/BusAck helpers.

GHDL cannot read Verilog (D-33), so these benches drive the bridge-side
signals (`BUSRQ_n` park request, engine master inputs) from a small VHDL stimulus
model instead of `ssp_top`. Follow the existing runner pattern
(`sim/run_*.sh`, `ghdl --std=08 -fsynopsys --workdir=/tmp/<name>`; payloads
assembled with `tools/z80asm.sh`).

1. **`sim/tb_integ_park.vhd` + `sim/run_integ_park.sh` (R-40):** assert
   `BUSRQ_n` at random points across a directed instruction mix — DD/FD/
   CB/ED prefixes, DDCB-indexed bit ops, LDIR/OTIR, HALT, EI + interrupt
   shadow, IM2 acknowledge. Check every park lands with `would_boundary`
   true and the snapshot PC equals the next instruction. Start from the
   `sim/run_cpuregs.sh` file set (T80 only).
2. **`sim/tb_integ_mux.vhd` (R-42):** instantiate `ssp/rtl/z80_bus_mux.vhd`
   in front of the MMU/SDRAM client path; engine reads/writes to SDRAM,
   BRAM and I/O must produce the same `MRD_T1`/strobe/wait waveforms as T80
   cycles (golden compare); the select never flips without BusAck. Read the
   comment block above the SDRAM client FSM in `MicrocomputerZ80CPM.vhd`
   (~lines 980–1090, `sdram_spec_go <= cpu_mrd_t1 and phys_in_sdram` at
   ~1093) before writing it.
3. Leave BP self-loop injection (R-41/OQ-23) for P2.

**Exit:** both benches PASS; the R25 regression set still passes
(`sim/check_sync.sh`, `run.sh` 115 iterations / 0 mismatches,
`run_cpuregs.sh` 8/8, `run_ixmin.sh` 10/10, `run_ixstack.sh`,
`run_forth.sh`).

#### Step 3 — Synthesis prerequisites — **DONE (R32; `MrZ80.qsf` entries added in R33)**

1. **RAM wrapper:** create `ssp/rtl/ssp_sdp_ram.vhd` from
   `bakeoff/ssp_sdp_ram.vhd` (16K×32 altsyncram `DUAL_PORT`, explicit IP —
   D-36; Quartus 17 inference failed). Add an `init_file` generic for the
   MROM instance; the bake-off wrapper has none. `sim/ssp/ssp_sdp_ram.v`
   stays the Verilator twin.
2. **Factory ROM image — decided R27 (D-38): commit it.**
   `tools/bin2hex.py` emits `$readmemh` words for Verilator; Quartus needs
   `.mif` or Intel HEX. Add a converter (or a mode of `bin2hex.py`) and a
   Makefile target in `ssp/fw` that produces the committed image (e.g.
   `ssp/fw/forth_rom.mif`, outside the ignored `build/` dir). It must include
   the monitor dictionary (the D-35 merged kernel + app image, as produced by
   the dictionary-build script), not just the bare kernel. Recommit it
   whenever the FW changes, and say so in the commit message. GPLv3 is not
   an issue (owner): the source is always available.
3. **`MrZ80.qsf`:** add `VERILOG_FILE` entries for `ssp_top.v`,
   `ssp_bridge.v`, `ssp_uart.v`, `Components/RISCV/femtorv32_gracilis.v`;
   `VHDL_FILE` for `ssp_sdp_ram.vhd`, `z80_bus_mux.vhd`, `ssp_tramp.vhd`,
   `ssp_regs_pkg.vhd`; a `SEARCH_PATH` for `ssp/rtl` (for
   `` `include "ssp_regs.vh" ``). Per `AGENTS.md`, run Analysis & Synthesis
   after `.qsf` changes. Gracilis has file-scope `` `define``s (§9.1) —
   check for macro collisions.

**Exit:** `tools/build.sh synth` succeeds with the SSP instantiated (step 4)
or with a temporary stub top.

#### Step 4 — Top-level integration — **DONE (R33); `make -C sim integ-core` is the R-42 SDRAM/BRAM/MMU bench**

**Rules:** `sys/` is untouchable. Keep the T80 strictly vanilla when the SSP
is disabled (P-B: monitor-disabled must be indistinguishable from
monitor-absent).

1. **`MicrocomputerZ80CPM.vhd`** (CPM core, VHDL):
   - Insert `z80_bus_mux` at the T80 output boundary (address, data out,
     MREQ/IORQ/RD/WR, `mrd_t1`, `M1_n`); export the engine-master ports and
     T80 status (`busak_n`, `m1_n`, `halt_n`, `would_boundary`, MC/TS/ALT,
     `REG`) through new entity ports.
   - Park request: drive `n_BUSRQ` (~line 416, currently `'1'`) from the
     bridge's `z_busrq_n`. **`FREEZE_req_n` (~line 407) is a dead port in the
     T80 — leave it `'1'`.** `cpu_wait_n` is at ~475.
   - Instantiate `ssp_tramp` (R28): `sys_rst_n` = `reset_n_internal`,
     `z_reset_n` = bridge, `t80_rst_n` -> the T80's `reset_n` (replacing
     `reset_n => reset_n_internal`, ~line 387), `cen` = **ungated** `cpu_cen`,
     `arm`/`target`/`done` to the bridge, `addr`/`mreq_n`/`rd_n` = the Z80
     nets *after* `z80_bus_mux`, `din_in` = today's `cpuDataIn` mux output
     (~line 965) and `din_out` -> the T80 `di`. Decide whether the capture
     chain's bus-data view (`fpStaticDataBus`) should see the raw or the
     injected byte (injected is more truthful). With the SSP idle the module
     is transparent: `t80_rst_n = reset_n_internal` and `din_out = din_in`
     (confirm with the golden regressions).
   - Update `sim/MicrocomputerZ80CPM_sim.vhd` in the same change
     (`sim/check_sync.sh`; recipe and gotcha in §7.2).
2. **`MrZ80.sv`** (core shell):
   - Instantiate `ssp_top`. OSD status bits: design uses **bit 20 = monitor
     enable (`osd_ok`)** and **bit 22 = Serial Escape (`OM`)**; also a
     "Reset SSP" item for `rv_rst_n`. Bits 0, 9–19 are taken (§9.3).
   - **Console port — decided R27 (D-40): the SSP console follows the OSD
     port selection.** Recommended wiring: put `ssp_top` *after* the
     existing select mux — `snac_rxd` ← `serial_rx` (already the selected
     port, ~line 704), and feed `snac_txd` back into the existing TX select
     logic in place of the Z80's `serial_tx` (~lines 736–749), with
     `z80_rxd`/`z80_txd` going to the Z80 ACIA. Then either port
     works with no extra muxing. RTS/CTS flow control stays Z80-only
     (the SSP UART has none, R4). If this proves difficult, the owner
     allows deferring it, together with an OSD video + keyboard console
     (D-19, P3); SNAC-only is then the fallback.
   - `baud_increment` must be the same O9B divider the Z80 UART uses
     (shared truth, `SSP_DESIGN.md` §5.3).
   - Tie `dl_*` (MROM download, P1b) inactive.
3. Capture chain: the 64-bit `SSP_CHAIN` export is allocated bits 292–355
   (of `CHAIN_BITS => 384`, ~line 803). Not needed for P1a; when added, update
   `SIGNAL-CAPTURES.md` in the same change.

**Exit:** with OSD monitor-enable off, the core behaves exactly as before
(CP/M boots and runs; GHDL regressions unchanged); full compile passes
timing.

#### Step 5 — Hardware first light (P1a exit) — **DONE (R35): all items PASS on hardware 2026-10-27; P1a CLOSED**

`tools/build.sh` (full compile on `tycho`), then `make install` (scp to
host `mister`). P1a exit criteria (`SSP_DESIGN.md` §15): on hardware,
escape into the SSP, examine/deposit Z80 memory, resume — with OM off
proven bit-transparent. Record results as a design round.

