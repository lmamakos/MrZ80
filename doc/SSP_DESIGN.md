# SSP_DESIGN — System Support Processor for MrZ80
*An embedded RISC-V (Forth-powered) support processor and its Z80-facing
debug/console/assist interfaces.*

Status: **v1.0-draft** — **renamed from `ODT_MONITOR_DESIGN.md` at round
R13** (2026-10-26): the subsystem outgrew the Intel-derived "ODT" label
(debug console is now one feature among many). All prior content, decision
lineage v0.1–v0.9 and logs R1–R12 are preserved below and carry the old
name where historically accurate.
Architecture from v0.2 (support-CPU: RV32IMC +
Mecrisp-Quintus FORTH + cycle-accurate `ssp_bridge`) as amended by the
**design decision session of 2026-10-22** (full round-by-round log in §17),
plus follow-up refinement **R7**: 32-switch bank with dual personality
(panel input + Z80 sense ports $FC–$FF) and encoder accumulate-and-commit
menu counter exposed at $FB (§11.2/§11.6).
**v0.5** = panel-UX deep-dive outcome (round **R8**, 2026-10-23; full spec
in `SSP_PANEL_UX.md`): operator-sovereignty-with-PANEL_LOCK (G-8), per-page
lamp remapping with pinned chrome (G-9/D-23), S28–S30 = BP-ARM / FREEZE /
START-AT-A, encoder hold-cursor + rapid-double-press-zero, `*`-prefixed
panel-op commentary, colour conventions, WDG-dead forces CLASSIC page +
clears lock.
**v0.6** = SDRAM rework decisions (round **R9**, 2026-10-23; full record
`SDRAM_REWORK_PLAN.md`): staged **A-then-B** arbiter approach (additive
borrowed wiring for P1/P2 now; formal `sd_arb` extraction approved as a
later refactor milestone), **no block-transfer engine** (`INIR`/`OTIR` via
the MMU direct-access port suffices), **no burst transfers**, loader
streaming **deferred**; new OQ-19 (milestone-B scheduling).
**v0.7** = MMU map switch (round **R10**, 2026-10-23): 9th SPDT lever —
MMU-EXAM reads entry `S1:S0` from the `MAP` taps and displays the page on
the address lamps at their physical A27..A14 positions (frame number echoed
in L1:L0, rest of the low lamps dark); MMU-DEPOSIT stores `S27..S14` as
the entry's page (implicit valid, parked port-master macro) — **D-24**,
UX spec §4A.
**v0.8** = FemtoRV32 promoted to evaluated alternative (round **R11**,
2026-10-26, §5.8/OQ-20): owner-requested investigation of Bruno Levy's
FemtoRV core family (Mecrisp-co-author lineage, pure Verilog, no build
system required; RV32IMC variants address future footprint concerns).
**v0.9** = **P0 refocus** (round **R12**, 2026-10-26): P0 executes on
**FemtoRV32-gracilis**; **VexRiscv work shelved** — incl. the vexgen
container (§5.7 retained as written guidance for the shelved path) —
reopen only on measured drivers (OQ-21). Cross-development via packaged
riscv64-unknown-elf GNU toolchain (RV32IMC via `-march/-mabi`, §5.8).
Headline changes from v0.2: downloadable monitor ROM (no refit to update FW)
+ FORTH program pack via OSD; RV32IMC facilities settled; MMU direct-access
path **retracted** (Z80-owned state) and replaced by a parked physical
client that borrows the wiring; two-tier watchdog with a strict few-ms
Z80-stall budget; formal invariant P-D (state-neutral observation);
address-first front-panel switch map (28 address bits + SPDT function
switches) with the classic operations **executed in hardware**, the monitor
firmware a peer on the same shared functional registers; `$D0–$D3` Z80
mailbox; lamps-not-graphics philosophy with monitor state exported into the
capture chain on profile 7; firmware-policy console routing (serial → HDMI
mirror → later exclusive HDMI+keyboard console).
**R14** (2026-10-26, post-rename): PicoRV32 elevated from fallback to
**co-candidate** on external research (riscv-formal pedigree, ecosystem
depth, simpler bus — with its RV32C/timer/atomics asymmetries corrected in
§5.8); **P0 becomes a two-core bake-off** (D-09/OQ-20). Bake-off concluded
**R23: owner selected FemtoRV32-gracilis (D-37).**
**R15** (2026-10-26, design review): **instruction-boundary parking**
(the T80 grants BUSRQ at *any* M-cycle `T_Res` — D-25), a single
**`z80_bus_mux`** that also synthesizes `MRD_T1`/`M1_n` and senses
`cpu_wait_n` (D-26), **R14 IRQ claim corrected** — gracilis uses standard
CSRs, picorv32 custom instructions — so **v1 FW is polled** over sticky
status (D-27), two-level **simulation strategy** (D-28), **single-source
register map** (D-29), panel engine as a **micro-op sequencer** (D-30),
**serial escape = one specific character, gated by OSD switch `OM`**
(D-14 rev), **RAM-only Forth, no flash emulation** (D-32), profile-7
hardware interlock (D-31), **P1 split into P1a "first light" / P1b**.
**R16** (2026-10-26, P0 kickoff): toolchain installed + smoke-tested; GHDL
sim resynced to a green baseline; **language seam decided** — Z80-side
logic in VHDL, RV-side in Verilog (D-33); **gracilis `ADDR_WIDTH=30`**
(D-34); **Mecrisp-Quintus 1.1.2a source in-tree at `~/mecrisp-quintus`**
(GPL-3.0+ compliance path closed, H-3); capture-chain facts corrected
(292/384 used).

Tags: `[verified]` (re-confirmed against source; anchors are hints — grep the
name) · `[decided]` (locked, see §2) · `[proposed]` (review target) ·
`[open]` (§14) · `[deferred]` · `[new v0.3]` (from the decision session).

Companion documents: `doc/t80_reg_debug_vector.md` (normative register map),
`SSP_PANEL_UX.md` (panel UX spec — R8 outcome, referenced by §11),
`SDRAM_REWORK_PLAN.md` (memory-subsystem rework roadmap — R9 outcome,
referenced by §9.2), `SSP_RISCV_REVIEW.md` (v0.1→v0.2 rationale + fact
corrections), `archive/ODT_CHANGE.md`
(pivot handoff, historical — superseded by this doc), `REQUIREMENTS.md` item 1
(this design is its
detailed spec — traceability note added there), `HARDWARE.md` (I/O map; must
be updated when this lands).

### Naming (R13, 2026-10-26) `[decided]`

**SSP — System Support Processor**: the RISC-V support CPU *and* its
Z80-facing peripheral interfaces (bridge, console UART, panel engine,
watchdogs, memory clients, mount path) as one subsystem. Chosen over the
inherited "ODT" label, which described only the debug-console heritage;
industry pattern precedents: service/support processors, BMCs.

Rename map applied through the doc set (code hasn't existed yet, so this is
the canonical vocabulary from day one):

| Was | Now |
|---|---|
| ODT (subsystem brand) | **SSP** |
| `ODT_MONITOR_DESIGN.md` / `ODT_PANEL_UX.md` / `ODT_RISCV_REVIEW.md` | `SSP_DESIGN.md` / `SSP_PANEL_UX.md` / `SSP_RISCV_REVIEW.md` |
| `mon_top` / `mon_uart` / `mon_mem_client` / `mon_sd` | `ssp_top` / `ssp_uart` / `ssp_mem_client` / `ssp_sd` |
| `dbg_bridge` | `ssp_bridge` |
| `mon_active` / `mon_irq` / `mon subsystem` | `ssp_active` / `ssp_irq` / `ssp subsystem` |
| `MON_CTRL` / `MON_CHAIN` | `SSP_CTRL` / `SSP_CHAIN` |
| `monitor/rtl/`, `monitor/fw/` | `ssp/rtl/`, `ssp/fw/` |
| FW page word `MON n` | `PAGE n` (clearer: it selects lamp/state pages) |

**Carve-outs — "ODT" survives *only* as Intel heritage:** the phrase
"ODT-style" for the classic-console idiom (§1), the FW compatibility-skin
word `ODT` (§5.5/§10.1 — the command set *emulates* Intel's ODT monitor,
alongside its `H T G X K…` mnemonics), and `archive/ODT_CHANGE.md` (whose
name is itself historical). Nothing else bears the old label.

---

## 1. Purpose and Scope

A self-contained, FPGA-resident debug monitor ("the monitor") for the MrZ80
core in the spirit of literal-disk / IMSAI **ODT** and PDP-8/IMSAI 8H-era
front-panel consoles, implemented as a **RISC-V support CPU running FORTH**
beside the Z80, plus a thin cycle-accurate bridge, plus a **hardware
classic-console engine** that keeps the panel functional with no firmware at
all. Three operator surfaces, one state model:

1. **Serial console** — ODT-style hex command line on the monitor's own
   UART, SNAC path, monitor owns the link in monitor mode (§7).
2. **Classic front panel** — 32 address/mode toggle switches + SPDT
   momentary function switches + rotary encoder + WS2812 lamp array. The
   basic functions (Reset, Run/Stop, Step, Examine/Deposit, Port R/W, Load
   Address) are **executed by a hardware panel engine** through the same
   bridge primitives the firmware uses (§11). `[new v0.4]` The toggle bank is
   *dual-personality* — also readable by Z80 programs as IMSAI-style sense
   switches ($FC–$FF), and the encoder is an accumulate-and-commit menu
   selector ($FB preview). The monitor firmware shadows and can extend the
   panel but is not required for panel operation `[decided]`.
3. `[new v0.3]` **HDMI console (later phases)** — P2 mirrors monitor text
   onto the SBC terminal; a later phase adds an exclusive HDMI + PS2-keyboard
   monitor console, selected by OSD or by a serial command. Monitor I/O
   routing is firmware policy over hardware muxes; serial stays the
   fail-safe default surface (P-B).

Machine capabilities (unchanged core list): stop/go/step at instruction,
machine-cycle and T-state granularity; logical (Z80/MMU) *and* physical
(28-bit) examine/deposit; mastered I/O; read-only register snapshot (write-
back P3); 4 breakpoints; 16-entry jump ring; MMU map view; `[new v0.3]`
unassembler, search, I/O traps, HBIOS page-table decode and scripted
sequences as first-class FW features; `[new v0.3]` Z80→monitor mailbox
$D0–$D3 as the seed of HBIOS cooperation.

### Non-goals for v1
- Z80 register writes / resume-at-modified-registers (D-02; `[deferred]` P3).
- Monitor bus mastering while the Z80 runs (P-A). Background *physical
  reads* via the SDRAM vid port are the sole sanctioned concurrent access.
- HPS/network remote console (`[deferred]` P3+); graphical video frame
  buffer for monitor output (§14 OQ-15, later alternative to ANSI terminal).

---

## 2. Decision Log

| # | Decision | Notes / alternatives rejected |
|---|---|---|
| D-01 | `[decided]` Serial console SNAC mux: `monitor_owned = OSD OK(bit20) ∧ FW CTRL.console_own`; Z80 forced to Console Port while owned; untouched passthrough otherwise; hardware `OK`/S32-off forces release (P-B). Ratified in session R4. | bit-bang shared UART; passive-snoop-only |
| D-02 | `[decided]` Registers read-only in v1; `G aaaa`/START = trampoline (§7.4) after reset-vent; context loss accepted (session R2); write-back `[deferred]` P3. | invasive T80 write datapath (rejected) |
| D-03 | `[decided, revised v0.7]` Front panel = **32 address/mode toggle switches (S31..S0)** + **SPDT momentary function switches** (9 two-way = 18 lines incl. MMU EXAM/DEPOSIT added R10, §11.2) + quadrature encoder w/push + escape/disable toggle, SNAC bridge board (74HC165 frame). Toggle bank has **dual personality**: panel-engine input *and* Z80 sense switches ($FC–$FF, D-05). Function **execution is hardware** (panel engine, D-18). Electrical/board freeze at bridge-board design (OQ-09). | 64-switch bank (v0.1, retired by R5/R7 layout); FW-only panel (v0.2 — superseded by session R5/R6); matrix keyboard |
| D-04 | `[decided, session R5]` **$D0–$D3 Z80→monitor mailbox allocated**: Z80 writes mirror to bridge `MBX0..3` + raise monitor IRQ; Z80 reads return the mirror (never stalls). 0xD4–0xDF, 0xE0–0xEF reserved. | reserved-for-later |
| D-05 | `[decided, revised v0.4 (R7)]` Z80 **sense-switch ports** at the top of the port space, IMSAI-style: **$FF = S31..S24** (mode byte, incl. bit7=S31 PHYS), **$FE = S23..S16**, **$FD = S15..S8**, **$FC = S7..S0** (also the DEP data byte), **$FB = encoder menu counter** (§11.6). Reads return debounced state from hardware — zero FW dependency (P-B). **$FF write still drives `fpLatch`** LED latch (`MicrocomputerZ80CPM.vhd:~570`); $FF *read* repurposed from `fpLatchDataOut` (no Z80 reader exists — §3). $F8–$FA reserved. | 8-byte $F8–$FF window for a 64-switch bank (v0.1/D-05-original); FW-served sense reads |
| D-06 | `[decided]` Jump-history ring P2: T80 `CTEV*` side-band + 16-entry HW ring + FW `J` + lamps. | SW-only trace (can't keep up, §4.3) |
| D-07 | `[decided]` Panel START runs at the live switch-set address. | two-phase LOAD-then-RUN |
| D-08 | `[decided]` MC/TS port-out on `T80s` + bundled **`Alternate` export** (session R3; closes OQ-01) in the same P1 mod; `CEN` already ported. T-state/Mcycle step via bridge `STEP_CTL`. | BUSRQ-only stepping |
| D-09 | `[decided, session R1; revised R11/R12/R14; RESOLVED R23 → D-37: gracilis]` Support core: **P0 = two-core bake-off (R14): PicoRV32 (`COMPRESSED_ISA`) ⟷ FemtoRV32 `gracilis`** — both pure-Verilog vendored files, zero generation toolchain, same `ssp_top` wrapper; decision at P0 exit on the §5.8 criteria (trust/verification weighted first for a debug host). Common ground that neutralizes most deltas: RV32C available on both (parameter vs native); no standard `mtime` on either ⇒ bridge MMIO 1 MHz tick is common design; atomics absent on both (Mecrisp doesn't need them). **IRQ models differ** (R15 correction: gracilis = standard `mtvec/mepc/mcause/mstatus/mret`; picorv32 = custom `getq/setq/retirq/maskirq/waitirq/timer`) — neutralized by polled v1 FW (D-27). Both have first-party Mecrisp lineage (Mecrisp-Quintus's first target was PicoSoC/picorv32; gracilis ships in the distribution). **VexRiscv shelved** (R12; reopen = OQ-21 measured drivers). Baseline if both P0 entries somehow fail: plain PicoRV32 without C (already an entry member). | v0.1 "femtoRV primary" premise; VexRiscv-first sequencing (superseded R12); gracilis sole-primary focus (superseded R14 — external research + riscv-formal pedigree elevate PicoRV32 to co-candidate) |
| D-10 | `[decided, session R1]` **64 KiB ROM / 64 KiB RAM** (parameterized; final gate = P0 `fit.rpt`). **"ROM" is downloadable**: M10K block read-only to the RV, write port fed by the OSD download path; factory contents from committed init hex; downloaded contents persist across core resets within a session (full FPGA reconfig restores factory). **R15: stays RV-read-only — no flash emulation** (D-32). | 16K/16K; refit-required ROM; RV-writable upper-ROM "flash" for `compiletoflash` (offered R15, declined) |
| D-11 | `[decided; R15 wording]` Bridge MMIO base `0x2000_0000`, 4 KiB, word-aligned **SSP local bus** — core-neutral valid/ready (picorv32 `mem_valid/mem_ready` native; gracilis `mem_rstrb`/`mem_wmask` + `rbusy/wbusy` via thin shim); slave may stall (late ready). | 32-byte region; VexRiscv "SimpleBus" naming (retired with shelving) |
| D-12 | `[decided]` Formal invariants **P-A..P-D** (§2.5) + named guidance notes G-1..G-7 (session R2/R6: A–C formal per owner; P-D promoted R6). | notes-only |
| D-13 | `[decided, revised v0.3]` **Two-tier watchdog** (session R2): **WDG_RUN** (`[new]` transient holds — WAIT asserts, trap stalls, sequencer busy — auto-release Z80, default **~4 ms**, parameterized) and **WDG_PARK** (~1–2 s, governs *FW-originated* parks only: expiry demotes a dead FW console — `console_own←0`, dead-flag lamp — but **never releases a hardware-held park**: classic STOP/BP park semantics stay human-paced and panel-recoverable). §6.9. | single 1.3 s auto-release (v0.2) |
| D-14 | `[decided, session R4; revised R15]` **Serial escape = one specific character, recognized in hardware, only when OSD switch `OM` ("Serial Escape", status bit 22, default **Off**) is On.** Recognizer watches the SNAC RX stream; on match while the Z80 runs ⇒ park at instruction boundary (D-25, reason=escape), console handed to the SSP; the escape byte is **consumed**, never delivered to the Z80 (mechanism OQ-22). Character = `ESC_CHAR` register, hardware reset default **`0x1D` (`^]`)** — chosen because CP/M software (WordStar `^E` etc.) uses the low control codes. Effective enable = `OM ∧ CTRL.esc_break_en ∧ ssp_active` (FW may disable, never override the OSD). With `OM` Off the serial link is **fully transparent** — no byte value has special meaning; monitor entry is then via panel STOP/BP, or SSP FW when it already owns the link. Distinct from the panel **ESCAPE toggle** (frame bit 32 = monitor *disable*, G-8). | any-RX-byte break (R4 — rejected R15: line noise/answerback/type-ahead halt the Z80; no transparent mode); BREAK-condition detect; FW-poll escape |
| D-15 | `[decided, revised v0.3]` Physical memory: **(P) parked client** `ssp_mem_client` borrows the *wiring* — drives the existing SDRAM client interface (`sdram_addr/din/we/rd` + native DQM) and BRAM mux only while Z80 parked *and* primary client FSM idle; MMU registers untouched (P-D). **(B) background** vid-port client (P2): **reads only** — natively read-only, verified lowest priority (cpu > vid, refresh > both); vid-*write* mod deferred, revisit gated on sim showing vid traffic benign to the primary path like refresh collisions (session R3). | ~~MMU direct-access ports $B8–$BC~~ **retracted**: auto-increment pointer is Z80-owned state (session R3) |
| D-16 | `[decided, revised v0.3; R15]` OSD allocations: `OK`=bit 20 (`OL`=21 reserved); **`OM`=bit 22 "Serial Escape" Off/On (D-14, R15)**; download index **6 = `MROM` monitor ROM image**, index **7 = `MPKG` FORTH program pack**. MROM mount completion pulses **monitor-subsystem reset only** (RV+bridge+WDG re-arm; Z80 untouched, session R2). `OF` Reset-after-Mount semantics unchanged (Z80). | Z80-wide reset on mount |
| D-17 | `[decided, revised v0.3]` Lamp display philosophy (session R5): LEDs are a **flexibly-mapped signalling lamp array**, *not* a low-res graphics surface; no assumed correspondence with terminal text. Convention: monitor exports state words into the capture chain (§11.4); **profile 7 = monitor profile**; map_ram maps lamps to any chain bits (existing capture bits and/or monitor-exported bits); OSD profile-override engages profile 7 while monitor display active. Direct color/fb painting remains available for FW extensions. | dedicated monitor framebuffer; "text mirror" lamp pages |
| D-18 | `[decided, new v0.3]` **Hardware panel engine** (`fp_engine`): classic panel operations execute in FPGA logic through the shared bridge primitives (sequencer, step assist, reset stretcher, bus muxes), maintaining live **AR/DR/MD/PR** functional registers that FW reads/writes too. Panel works with FW absent/hung (P-B strengthened). FW and panel are **peers on one engine**; the sequencer busy-handshake is the arbiter; panel wins simultaneous kicks; panel ops event FW (IRQ + last-op log). | FW panel server as sole executor (v0.2) |
| D-19 | `[proposed, new v0.3]` Console routing is FW policy over HW muxes: `CONN_ROUTE` selects monitor output sink(s) {SNAC UART, HDMI terminal mirror} and input source {SNAC RX, PS2 kbd (P3)}; hardware default = serial on reset/WDG-death (P-B). | fixed serial-only routing (kept as fail-safe default semantics) |
| D-20 | `[decided, session R1; revised R15]` Core facilities: **RV32IMC** (no A — single hart, state read via bridge regs); time base = **bridge MMIO 1 MHz counter `TICK_US`** (neither candidate has `mtime`; `rdcycle` usable for fine timing); events read from bridge `IRQ_PENDING` **by polling in v1** (D-27) — the IRQ line exists in RTL but v1 FW does not depend on it; no PLIC, no core-specific trap code. | IMAC; mcause/vectored; "1 MHz machine timer" CSR (does not exist on either core) |
| D-25 | `[decided, new R15]` **Instruction-boundary parking.** The T80 grants BUSRQ at *any* M-cycle `T_Res` (`T80.vhd:~1033-1042`), so a raw BUSRQ can freeze mid-instruction (PC/temporaries half-advanced). The D-08 `T80s` mod additionally exports **`insn_end`** (last M-cycle of the instruction ∧ `T_Res`); the bridge passes park requests (FW hold, panel STOP, STEP INSN, escape, BP) to `BUSRQ_n` only aligned to `insn_end`. Rules: **prefixes are not boundaries** (no park between DD/FD/CB/ED and the opcode they modify); HALT state parks anywhere (PC = HALT+1); INT/NMI acknowledge completes before park; EI's one-instruction shadow honoured; block instructions park per iteration (PC re-points at the instruction). M-cycle/T-state step modes deliberately park off-boundary. `STATUS.at_boundary` tags every park; register snapshots are architectural only when set (`R` warns otherwise). **Breakpoints**: stop-*before*-execute via **self-loop injection** — on BP M1 match, the trampoline data mux feeds `18 FE` (`JR $`) in place of the opcode/displacement fetches, then park at its `insn_end` ⇒ PC = BP address, flags/regs untouched, only R +1 (already-accepted drift). Evaluation in sim (OQ-23). **[R25 amendment, documented R30]: the grant gate lives INSIDE the T80, not in the bridge.** The bridge no longer aligns requests to `insn_end`; it only asserts a level request on `BUSRQ_n`. The T80 (local ports `FREEZE_req_n`/`FREEZE_any`/`would_boundary` -- of these, `FREEZE_req_n` proved a dead port, R28 erratum: the request is `BUSRQ_n`) grants `BusAck` only at the branch whose next state is an M1, prefix-gated, with the XY-pair and mode-1 return cycles excluded by the FSM's own priority; `STATUS.AT_BOUNDARY` latches `would_boundary` at the grant. | raw BUSRQ park (v0.1–v1.0: unsafe); stop-after-BP-instruction (reports wrong PC) |
| D-26 | `[decided, new R15]` **Single `z80_bus_mux`** at the T80 output boundary, one select, flips only with `BusAck` confirmed (P-A): address, data-out, `MREQ/IORQ/RD/WR`, **`MRD_T1`** (the SDRAM speculative-read trigger, `MicrocomputerZ80CPM.vhd:~1090`), **`M1_n`** (capture chain `:~764`), plus engine-side **sensing of `cpu_wait_n`** (MMU + SDRAM waits — the parked T80 no longer consumes them). The engine emits **cycle-faithful Z80 bus cycles** on `cpu_cen` (T1–T3 + Tw, `MRD_T1` timing as T80s), so every peripheral and the SDRAM client FSM see "a Z80"; Z80-path tests are reused for engine cycles. | per-signal ad-hoc muxes; engine-native (non-Z80) strobe timing |
| D-27 | `[decided, new R15]` **Polled v1 firmware.** Every bridge event is a **sticky status bit** (W1C), so FW is correct by polling its main loop; the IRQ line is an optional later optimization. Makes the two P0 cores FW-interchangeable despite their different IRQ models, and keeps interrupt races out of the debugger. | IRQ-driven dispatch as baseline (v0.3 §5.5) |
| D-28 | `[decided, new R15; R16 amendment]` **Two-level simulation**: (1) **SSP-only, Verilator** — core + ROM/RV RAM + UART + bridge + engine against a behavioural Z80-bus model (BFM); fast enough for the Mecrisp REPL (10⁷–10⁸ cycles); (2) **integration, GHDL** *(R16: GHDL is installed and the established flow with a green baseline — Questa dropped)* — real T80/MMU/SDRAM client FSM (VHDL) for D-25/D-26, wait handling, R-21 pass-through. Integration benches follow the existing `sim/run_*.sh` + `sim/tb_*.vhd` pattern (`run_ssp_*.sh`); Verilator work in `sim/ssp/`; shared Makefile; the §13 TB names become runnable targets. Set up in P0. | single-simulator flow (Verilator can't read VHDL; mixed-language Icarus too slow for Mecrisp); Questa (unneeded — GHDL covers VHDL) |
| D-29 | `[decided, new R15]` **Single-source register map**: `ssp/regs/ssp_regs.csv` (offset, name, access, fields, reset, doc) → generator `tools/ssp_regmap.py` emits `ssp_regs.vh` (RTL), `ssp-regs.fs` (Forth constants), and the §6 Markdown table; TBs include the `.vh`. Hand-editing generated outputs forbidden. | hand-maintained parallel copies |
| D-30 | `[decided, new R15]` **Panel engine = micro-op sequencer.** Primitives `LOAD_AR, LOAD_PR, MEM_RD, MEM_WR, IO_RD, IO_WR, INC_AR, STEP, RESET_VENT, INJECT, TAP_RD, PAGE_SET`; each panel op (EXAM-NEXT, DEP-NEXT, START-AT-A, MMU-DEPOSIT two-OUT, …) is a short sequence in a small table; FW `MEM_CTL` kicks enter the **same queue**. Arbitration is **per macro** (atomic — no FW cycle between MMU-DEPOSIT's two OUTs); panel wins simultaneity. | hand-coded per-op FSM states |
| D-31 | `[decided, new R15]` **Profile-7 hardware interlock**: Z80 `$A0–$A7` writes targeting LED profile 7 are dropped in hardware; profile 7 is SSP-owned (supersedes §11.5's by-convention rule). | convention-only (v0.3) |
| D-32 | `[decided, new R15]` **RAM-only Forth — no flash emulation.** Mecrisp-Quintus runs `compiletoram` only: kernel executes from the OSD-loaded MROM image (RV-read-only, D-10); all compiled words live in RV RAM; flash-write primitives are **plain stores** (rev R18: writable in sim where the MROM window's backing store accepts writes, inert on silicon; see D-35); operator persistence = OSD MROM image + MPKG source packs re-`EVAL`'d at boot (D-21); OQ-13 stays deferred. | RV-writable upper-ROM `compiletoflash` region (offered R15, declined: unnecessary at this stage) |
| D-33 | `[decided, new R16]` **Language seam (H-4).** Simulation has no mixed-language path (GHDL reads VHDL only; Verilator reads Verilog only; no `ghdl-yosys-plugin` packaged). Rule: **Z80-side SSP logic = VHDL** — `z80_bus_mux`, boundary-park logic, escape recognizer, `fp_capture`, `fp_engine`, `ssp_mem_client`, and the bridge **client side** (the ssp_bridge port that crosses the seam) live at the CPM-core boundary in VHDL, testable in GHDL against the real T80/MMU/SDRAM FSM. **RV-side = Verilog** — vendored cores, MROM/RV RAM, decoder, `ssp_uart`, register file. The seam is a plain signal bundle across the `ssp_top`/CPM boundary (register strobes + data + event bits), crossed in **Verilog at `ssp_top`** by instantiating the VHDL units by entity (Quartus handles the mix; simulation stubs the far side at each level). | mixed-language sim hosts; all-VHDL (costs the vendored Verilog cores' zero-touch import); all-Verilog (costs the proven GHDL T80/SDRAM benches) |
| D-34 | `[decided, new R16]` **gracilis `ADDR_WIDTH = 30`** in all our instances (default 24 would alias the §5.2 map: RV RAM `0x1000_0000`/bridge `0x2000_0000` fold toward 0). §5.2 map unchanged. Parameterized at instantiation; verified in the P0 stub-SoC decode test. | compacting the map into 24 bits (FemtoSoC style — rejected: the 30/32-bit map is core-neutral and already documented) |
| D-35 | `[decided, new R18]` **Application-dictionary build = Mecrisp `compiletoflash` into a contiguous MROM window** (owner ruling). Dictionary window `FlashDictionaryAnfang..FlashDictionaryEnde` = `0x4400..0x10000` on the silicon map (~47 KiB above the 15.8 KiB kernel; ulx3s-style margin), same geometry on the qemu map offset to DRAM. Dictionary builds run **only in sim**: qemu for pipeline rehearsal (`sim/ssp/dictbuild_qemu.sh`, DONE R18 — app dict built via serial-fed `compiletoflash`, captured by QMP `pmemsave`, merged with kernel, cold-boot residency proven); authoritative captures on the `sim/ssp` Verilator stub SoC (hardware-true addresses; firmware-paced feed). Shipped OSD `MROM` artifact = kernel + dict merged hex (idx6, D-21). No boot-time restore logic: the existing `catchflashpointers` walk consumes the contiguous dictionary natively. Consequences: shipped factory image = build-pipeline output (release-hex rule); cold boot re-inits RAM variables from embedded init data (code persists, live state does not); dictionary must be compiled against the exact kernel hex shipped. | RV RAM-snapshot + restore pack (rejected R18: needs new boot restore path + pointer-capture manifest; the contiguous flash-dict machinery already exists and is proven by R18) |
 | D-37 | `[decided, new R23]` **SSP core = FemtoRV32-gracilis** (owner ruling "gracilis it is!" closing OQ-20 at P0 exit). Evidence: R21 fit (1,128 ALM/540 reg, −24 % vs picorv32, both ≥28 % timing margin at 50 MHz) · R19/R20 FW neutrality (identical hex boots, byte-identical dict artifacts) · R22 cycle-level benchmarks (gracilis wins every op — loops, calls, stack ops, memory, MUL 3-vs-41 cyc — while already paying the D-36 launch+1 latency that costs picorv32 +30 %; §5.8.2). Lineage: co-designed with Mecrisp's author; ships in the official distribution. Consequences: `ssp_top` instantiates `femtorv32_gracilis` (`ADDR_WIDTH=30`, D-34; ties `mem_rbusy=0`, §5.8.1 launch+1 native); gracilis has **no external trap pin** — FW-liveness/backstop rides the bridge watchdog (`STATUS.rv_trap` remains picorv32-only semantics, R20 footnote; WDG design stands, D-13); picorv32 stays vendored as documented fallback (R14 baseline clause; swap = `crt0.S` + wrapper shim only, D-27); riscv-formal optional run no longer on any critical path — residual pedigree risk logged: FemtoRV verification rests on shipped-deployment + learn-fpga suite + our benches (goldens). | PicoRV32 (`COMPRESSED_ISA`) — loses area, timing-equal, loses every perf op at equal fabric; kept as documented fallback |
 | D-36 | `[decided, new R21]` **SSP block memories = explicit altsyncram IP instances, never inference-dependent** (owner ruling after the R21 inference saga: gracilis failed Quartus 17 M10K inference 5 ways on its combinational address bus — `Error 276003`; picorv32 inferred only with 2× pass-through duplication). House pattern: hand-written MegaWizard-style wrappers à la `Components/INTERNALRAM/InternalRam64K.vhd` / `Components/TERMINAL/DisplayRam1K.vhd`; P0 bake-off proved the wrapper (`bakeoff/ssp_sdp_ram.vhd`, DUAL_PORT 16K×32, port-A byteenable, `ADDRESS_REG_B=CLOCK0`, `OUTDATA_REG_B=UNREGISTERED` — exact usage per §5.8.1). Consequence: launch+1 read latency is the fabric truth (native for gracilis `rstrb`; picorv32 bridge adds one wait state). | inference + `ramstyle` attributes (rejected: tool-version-fragile, silently core-specific — proven this round) |
| D-38 | `[decided, new R27]` **Factory ROM image is committed** (owner ruling). The monitor's factory MROM init image (D-10) is a deliberate deliverable in the repo, in a Quartus-loadable format (`.mif` or Intel HEX) produced from the `ssp/fw` build by a documented recipe, and recommitted whenever the FW changes. GPLv3 (H-3): no issue — the corresponding source is always available (`ssp/fw/` in-tree plus the referenced Mecrisp-Quintus release). | generate the image inside the Quartus build (extra toolchain dependency on `tycho`) |
| D-39 | `[decided, new R27]` **P1a monitor command set redefined** (owner ruling; supersedes the P1a `E D G H R X` list and the v0.1 table, which is not in the repo). Initial primitive framework, expected to grow considerably: **examine memory** (`E aaaa [n]`, hex + ASCII dump); **modify memory** (`D aaaa`: prompt with address and current contents, a hex value replaces it, a bare carriage return leaves it unchanged, then advance to the next address; `.` ends); **go** (`G aaaa`: start the Z80 at `aaaa` via the D-02 trampoline after reset vent); **continue** (`G` with no address: resume the parked CPU and return the console to the Z80). Command letters and the modify-session terminator are `[proposed]` — owner left naming open. `R` (registers) is a natural early addition but not required for P1a. Consequence: the trampoline (`TRAMP_ADDR`, `CTRL.TRAMP_EN`) moves from P1b to P1a. | carry v0.1 table verbatim (unavailable); separate `H`/`X` commands (escape already parks; bare `G` resumes) |
| D-40 | `[decided, new R27]` **SSP console follows the OSD serial-port selection** (owner preference). When OSD selects the HPS console port, that port should also serve as the SSP console. Lean implementation: insert `ssp_top` *after* the existing `serial_port_select` mux in `MrZ80.sv` (on the selected `serial_rx`/`serial_tx` pair), so the SSP sees whichever port is selected. If integration proves difficult, defer to a later phase together with the OSD video + keyboard console (D-19, P3). | SNAC-only SSP console (escape unavailable on the HPS console port) |
| D-41 | `[decided, new R29]` **SSP UART RX FIFO = 128 bytes** (owner request: headroom for automation driving the serial port at maximum rate; supersedes the 8-byte `[proposed]` depth of §5.3). Parameter `ssp_uart.FIFO_LOG2` (default 7). 128 bytes ≈ 11 ms of 115200-baud input ≈ three Mecrisp lines (~3.4 ms each, every token is a full dictionary search); beyond that a sender must still pace (no RTS/CTS, R4) -- overrun semantics unchanged (byte dropped, sticky `rx_overrun`, cleared by `CTRL.RX_CLR`). The head is read asynchronously (bridge captures it on the pop edge, R26), so the array must map to **MLAB**: `(* ramstyle = "MLAB, no_rw_check" *)` -- measured on Quartus 17.0, whole UART 128 ALMs (depth 8) -> 157 ALMs (depth 128), 1024 MLAB bits, 0 M10K; without the hint Quartus builds M10K + address-register logic. | 8 bytes (kept as the unit-bench regression depth); 64 (too little for ~1 Mecrisp line of backlog at line rate plus slack); RTS/CTS flow control (rejected R4) |
| D-21 | `[decided, session R1]` **Code is data lifecycle**: monitor boots before/independent of Z80 image; ROM image (index 6) and FORTH pack (index 7: text source staged in RV RAM, auto-`EVAL`'d at boot, magic+length trailer; position-independent, survives kernel rebuilds) both OSD-loadable; serial upload path (P2) reuses the same "eval a buffer" primitive. No NVRAM machinery in v1. | refit-per-change; battery-backed dict (deferred OQ-13) |
| D-22 | `[decided, session R5]` Addressing is **modal** on both surfaces: logical (MMU-translated, 16-bit) ⟷ physical (28-bit). FW keeps a live MMU shadow from the `mmu_frame` HW tap (state-neutral) and can translate/report either view; serial mode command (`PHY`/`LOG`); panel physical mode = **S31 = '1'** (§11.2). | single addressing mode |
| D-23 | `[decided, new v0.5 (R8)]` Panel UX package (full spec `SSP_PANEL_UX.md`): sovereignty-with-`PANEL_LOCK` (G-8) · S28=**BP ARM** (LOAD-ADDR also sets BP at encoder-cursor slot), S29=**FREEZE**, S30=**START-AT-A** (hardware trampoline start, firmware-free — closes D-07 panel gap) · per-page lamp remap with pinned chrome + page-ID lamps (G-9; cold default = identity ⇒ CLASSIC) · encoder: hold-cursor after commit, rapid double-press zeroes (no commit) · hybrid `*` commentary · colour conventions · WDG-dead ⇒ page forced to CLASSIC, lock cleared. | static-map/paged-content (rejected R8 in favour of per-page layout); unconditional RUN; zero-after-commit; queue-only or silent commentary |
| D-24 | `[decided, new v0.7 (R10)]` **MMU map switch** — 9th SPDT (center-off momentary; two electrical lines): UP = **MMU-EXAM**: entry `n=S1:S0` read from the `MAP0..3` taps (no port cycle — P-D-safe); sustained display override until next display-changing op: page → lamps at the physical **A27..A14** positions, `n` → L1:L0, other low lamps dark; re-query on each UP edge and live on `S1:S0` change while active `[board-adjustable]`. DOWN = **MMU-DEPOSIT**: page `S27..S14` → entry `n` via parked port-master macro (`OUT $B0+n` low, `OUT $B4+n` high; valid set implicitly, bit encoding per `MMU.vhd` verified at landing); no panel-side validity check — an invalid mapping misbehaves exactly as a Z80-set invalid value (owner R10). Engine-only capable both directions (tap + mastering); FW mirrors events for `*` commentary; FW map shadow self-corrects via tap. | valid-dot lamp — rejected: unnecessary (op is for a stopped CPU; static lights); FW-dependent display; latching toggle part |

### 2.5 Principles

**Formal invariants** — every RTL change must state which invariants it
touches; violations block merge.

- **P-A — Park before master.** No Z80-bus mux flip (address/strobe/data
  injection) unless `BusAck` confirmed asserted. Sole exception: vid-port
  SDRAM reads (§9.2-B), which never touch the Z80 bus.
- **P-B — Z80 independence.** Z80-visible behaviour (reset/hold defaults,
  $F8–$FF sense, $FF latch, console passthrough, and `[new v0.3]` the entire
  classic panel engine) is correct and recoverable with the support CPU held
  in reset or hung. OSD `OK`-off / S32 escape force all monitor controls
  inactive in hardware.
- **P-C — MMIO is policy, never timing.** Any function whose correctness
  depends on a Z80 cycle boundary lives in the bridge: BP match, step
  assist, reset stretch, escape break, trampoline one-shot, wait/trap
  releases. §4.3 gives the arithmetic.
- **P-D — State-neutral observation** `[promoted, session R6]`. Monitoring
  never mutates Z80-owned hardware state: observe via side taps
  (`REG`, `mmu_frame`, bus mirrors), dedicated mirror/export registers, or
  the monitor's own arbitrated client. Concretely: no gratuitous Z80
  register/port side effects (the MMU direct-access pointer auto-increment
  incident, D-15), and shared machinery (SDRAM controller, LED engine) is
  entered only through explicitly arbitrated ports whose worst case the
  primary path already tolerates (refresh-class collisions, verified in sim).

**Guidance notes** (named, binding-by-review, lighter than invariants):

- **G-1 Two tiers of stop.** Soft pause (`WAIT_n`, invisible, mid-cycle bus
  state *not* inspectable) vs hard park (`BUSRQ` + snapshot, self-consistent).
  Inspection is legal only at park.
- **G-2 Frozen-output discipline.** Bus outputs freeze unless proven
  tri-stated (the T80 core never releases its drivers, §3). Mastering is
  always an explicit mux with select; wire-OR is forbidden.
- **G-3 One execution engine.** Functional memory/IO/step/reset operations
  have exactly one hardware door (the bridge engine); serial console, panel
  engine, and any future surface are peers on it. `MD` (mode: logical/
  physical) and `AR`/`DR`/`PR` are shared functional registers, not
  per-surface copies.
- **G-4 Z80 stall budget.** Transient monitor holds ≤ **~4 ms**
  (WDG_RUN-enforced). FW parks are laxed-but-timed (WDG_PARK); hardware-
  held parks (STOP/BP) are human-paced by design. A long monitor-side
  *computation* (big dump) is fine as long as it does not hold the Z80.
- **G-5 State has one authoritative home.** Live functional state lives in
  the bridge (`AR/DR/MD/PR`, BP slots, engine status); interpretive state
  (labels, disassembly, scripts, jump-ring narration, config) lives in the
  Forth dictionary; FW mirrors bridge state, hardware never copies FW state.
- **G-6 Lamps, not graphics.** No lamp↔terminal correspondence; lamp meaning
  is *profile mapping*, monitor-exported bits, and operator documentation.
- **G-7 Iterate without refitting.** Anything expected to change (ROM image,
  dictionary packs) is runtime-loadable (D-21); refit is for RTL, not FW.
- **G-8 Operator sovereignty (with lock).** Escape/OSD-off are absolute and
  never lockable. Panel RUN/START may be blocked only by FW-held
  `PANEL_LOCK`, which auto-clears on WDG_PARK expiry (dead FW), escape,
  OK-off, and MROM mount. STOP/EXAM/DEP/PORT/STEP/RESET are never gated.
  FW must treat park as best-effort — STATUS is truth; never assume a hold
  persists (R8).
- **G-9 Page = content + layout.** A state page owns both the 64-bit export
  *content* and the profile-7 lamp *map*; chrome rows (modifier arms,
  status strip, page-ID) never move. Cold default = identity map ⇒ classic
  layout with zero FW (R8).

---

## 3. Verified Platform Facts (design inputs)

v0.2 table re-confirmed in full; deltas from this session marked. Line
numbers are hints — grep the name.

| Fact | Anchor |
|---|---|
| `busrq_n => '1'` tie-off; `M1_n`/`RFSH_n`/`HALT_n`/`BUSAK_n` unconnected at CPU map | `MicrocomputerZ80CPM.vhd:~352/361` |
| `clk_sys` = 50 MHz; `clk_ram` = **100 MHz fallback currently live** (`SDRAM_CLK_100`, `MrZ80.sv:~502`; 112 MHz tap remains a regression target — R15 correction); `cpu_cen` 1-of-5 → T80 at 10 MHz | `MrZ80.sv:~238, 505-535`; `MicrocomputerZ80CPM.vhd:~322-326, 1168-1173` |
| `ClkEn <= CEN and not BusAck` (all progression CEN-gated); `BusReq_s` sampled each CEN edge; park at `T_Res`; while parked CEN pulses do nothing | `T80.vhd:~344, ~968, ~1033-1044` |
| `CEN` already a `T80s` port; `MRD_T1` already exported; `MCycle`/`TState` still internal (P1 mod per D-08, now also exporting `Alternate`) | `T80s.vhd:~67-99, 128-135` |
| **T80 outputs FREEZE (not tri-state) during hold** — mastering = explicit muxes (G-2) | grep `'Z'` in `Components/Z80`: 0 hits; `cpuAddress` `:147/366`; `cpuDataIn` mux `:~875-883` |
| Halted Z80 refetches `76h` → R drifts; PC = next-to-execute after park; 212-bit `REG` (no `Alternate` — exported by D-08 mod from P1); `Jump`-covers-RET (no distinct `Ret`) | `t80_reg_debug_vector.md` §1; `T80_MCode.vhd:~110-127, 1905` |
| MMU 4×16 KB frames, `physical_page_bits => 14` (28-bit/256 MB); SDRAM pages 0–8191, BRAM page 8192 @ `0x8000000`; **MMU direct-access pointer ($B8–$BB) auto-increments ⇒ Z80-owned state — monitor must not touch (P-D, D-15 retraction `[new v0.3]`)** | `MMU.vhd:~162, ~293-337`; `HARDWARE.md:~180`; `REQUIREMENTS.md:~37-41` |
| No boot ROM / `n_RomActive` (removed); CPU held in reset until HPS BIN load — trampoline sequencing only interacts with the reset *hold* | `REQUIREMENTS.md:~598-601`; `MicrocomputerZ80CPM.vhd:~98, 143, 337-343, 385` |
| I/O windows in use: $70-71, $80-83, $88-97, $A0-A7, $B0-BF, $C0-CF, $FF ⇒ $D0-D3 (now mailbox, D-04), rest of $D0–$DF/$E0–$EF/$F0–$FE free. **$FF read path currently returns `fpLatchDataOut`** (`cpuDataIn` mux `:~879`) — repurposed to the sense top byte per D-05/R7 (read-safe: no existing Z80 reader, verified); `$FF` **write** latch behavior preserved | decode `MicrocomputerZ80CPM.vhd:~841-850` |
| SDRAM `sdram_32r8w`: refresh > **cpu** > **vid**; vid port read-only (no DQM), 16-bit granularity (`A0` lane on cpu path); ack/ready mirrors cpu port; existing clk_sys↔clk_ram client-FSM pattern to copy | `sdram2.sv:~300-359, 67-76, 321-334`; `MrZ80.sv:~261-326`; vid tied off `MrZ80.sv:~354-356` |
| Capture chain **output-only**, `CHAIN_BITS => 384`, **292 bits in use** — map per `SIGNAL-CAPTURES.md` (authoritative; update it in the same change as any chain edit); the 64-bit SSP export fits at **292–355**, 28 spare (R15/H-5, R16). No switch-input HDL yet (OQ-09) | `MicrocomputerZ80CPM.vhd:~800`; `SIGNAL-CAPTURES.md`; `Hardware/README.md:~28` |
| `FP_RAM_Store`: 8 profiles × (color 48b / map 8b) + global fb bit; Port A = single R/W owner (today Z80 `$A0–$A7`), Port B = refresh controller; `pri_ram` profile-file shadow precedent; OSD profile override `fp_osd_profile` | `FP_RAM_Store.vhd:~45-80`; `MrZ80.sv:~981-985` |
| SNAC io0/io1 = RX/TX (existing mux `status[12]`), io2/io3 RTS/CTS, io6 = WS2812, **io4/io5 free both directions** (SW[1] I2S caveat); open-drain mechanics | `MrZ80.sv:~212-221, 698-750`; `sys/sys_top.v:1634-1640` |
| CONF_STR bits in use 0, 9–11, 12, 13, **14 (`OE` flow — bit14 not free)**, 15, 16–19; download idx 1/2/5 used, 3/4 reserved ⇒ **6/7 allocate for MROM/MPKG (D-21)**; `OK`=bit20 valid | `MrZ80.sv:~382-408` |
| Baud divider table exists (`O9B`, 115200…2400) — monitor UART takes the same select (session R4) | `MrZ80.sv:~763-764` |
| 5 `clk_sys` per T-state; Mecrisp word ≈ 200 ns > one T-state ⇒ §4.3 split arithmetic | derived |
| `[new R15]` **BUSRQ is granted at the `T_Res` of *any* M-cycle**, not only at instruction end ⇒ raw parks can land mid-instruction (D-25) | `T80.vhd:~1033-1042` |
| `[new R15]` SDRAM speculative read is triggered by the T80's **`MRD_T1`** output; `n_M1` feeds the capture chain; MMU wait and SDRAM wait combine into `cpu_wait_n` ⇒ the engine must synthesize/sense these (D-26) | `MicrocomputerZ80CPM.vhd:~472, ~764, ~1090` |
| `[new R15]` **Core IRQ models differ**: gracilis = standard `mtvec/mepc/mcause/mstatus` + `mret`, 64-bit `rdcycle`; picorv32 = custom `getq/setq/retirq/maskirq/waitirq/timer` (+ optional countdown-timer IRQ), `rdcycle` with `ENABLE_COUNTERS` | `femtorv32_gracilis.v:~292-316`; `picorv32.v:~652-757` |
| `[new R15]` Bus interfaces: picorv32 `mem_valid/mem_ready/mem_wstrb` (+ look-ahead `mem_la_*`); gracilis `mem_rstrb`, `mem_wmask`, `mem_rbusy/mem_wbusy`, single `interrupt_request` | `picorv32.v:~93-107`; `femtorv32_gracilis.v:~26-38` |
| `[new R15]` OSD status bits in use: 0, 9–19; allocated 20 (`OK`), reserved 21 (`OL`) ⇒ **22 (`OM`) = Serial Escape** | `MrZ80.sv` `CONF_STR` |

---

## 4. System Architecture

### 4.1 Block diagram (v0.3)

```
 clk_sys 50 MHz (single domain; only the vid-port window crosses to clk_ram)

 SNAC io0/io1 ◄──► console mux ◄─┬─ Z80 ACIA path ($82/$83)          [default]
   HDMI kbd (P3) ────────────────┴─ CONN_ROUTE (D-19) ─► ssp_uart ◄┐
 SNAC io4/io5 ◄──► fp_capture ─► fp_engine (hardware classic console)│[new v0.3]
 USER_OUT[6] ◄──── WS2812 PHY ◄── refresh ctrl ◄── FP_RAM_Store ◄─┐│
                                                                   ▼│
 ┌──────────────────┐ SSP local bus ┌────────────────────────────────────────┐
 │ RV32IMC — P0 pick│──valid/ready─►│ ssp_bridge @ 0x2000_0000 (4 KiB)      │
 │ picorv32|gracilis│◄──ssp_irq────│ CTRL·STATUS·STEP·BP·TRAP·MD·AR·DR·PR   │
 │  ROM 64K (OSD-   │  (optional,  │ µop sequencer (one door: FW ⇄ panel)   │
 │   downloadable)  │   D-27)      │ SNAP/LIVE REG · MAP0..3 (mmu tap)      │
 │  RAM 64K (all    │              │ SSP-CHAIN export(64b)·MBX·CONN_ROUTE   │
 │   Forth, D-32)   │              │ TICK_US · ESC_CHAR (OM-gated, D-14)    │
 └──────────────────┘              │ WDG_RUN(4ms)+WDG_PARK(1-2s)·IRQ·ID     │
                                 └──┬──────────────────────────────┬──────────┘
                                  │ busreq (insn_end-aligned,     │ A·D·strobes·MRD_T1·M1
                                  │ D-25)/wait/rst/tramp/escape   │ + cpu_wait_n sense
                                  ▼                              ▼
                                  │      z80_bus_mux (D-26) — one select, BusAck-gated
                    T80s (CEN · MC/TS/ALT/insn_end export · REG[211:0] · CTEV* P2)
                                  │
        memory system: MMU (untouched by monitor, tapped only) · BRAM mux ·
        SDRAM client FSM ── ssp_mem_client (parked physical, borrows wiring) ──┐
        sdram2 vid port ◄── ssp_sd (P2 background READS only) ─────────────────┴─ clk_ram CDC
```

### 4.2 Module list

| Module | Responsibility |
|---|---|
| `Components/RISCV/picorv32.v` + `femtorv32_gracilis.v` (+`utils.v`) + `.qip` | **P0 bake-off entries (D-09/R14)**: vendored single-file RV32IMC cores (picorv32 with `COMPRESSED_ISA`), pinned upstream revs + provenance notes (URL/commit/license check); no generation toolchain |
| `Components/RISCV/VexRiscv.v` + `.qip` | *Shelved (R12)* — vendored core path if reopened (OQ-21); provenance manifest + `gen/GenMrZ80.scala` + containerized regen (`tools/vexgen.sh`, §5.7) all specced, nothing scheduled |
| `ssp/rtl/ssp_top.v` | Subsystem wrapper: core + ROM + RAM + decoder + `ssp_uart` + `ssp_bridge`; sideband bundle to CPM; `ssp_irq` out; Z80 controls out; `SSP_CHAIN[63:0]` export |
| `ssp/rtl/ssp_bridge.v` | §6 register file; shared functional registers (MD/AR/DR/PR); MEM-SEQ engine + arbiter; STEP assist; BP/trap; WDG×2; IRQ; ID |
| `ssp/rtl/ssp_uart.v` | 8N1 UART, divider select from `O9B` table index (session R4, §5.3); RX FIFO (128 bytes, D-41/R29; was 8 `[proposed]`); **escape-character recognizer** on the SNAC RX stream (`ESC_CHAR`, OSD `OM`-gated, D-14 rev R15) → boundary park + console hand-over; sticky `rx`/`esc` status bits |
| `ssp/rtl/ssp_tramp.vhd` | `[new R28]` `G aaaa` support at the CPM boundary (VHDL, D-33): Z80-CPU-only reset vent (>= 8 `cpu_cen` stretch) + reset-vector `JP aaaa` injector (data-input override on the first three reads at $0000..$0002; primed only when armed during reset; `done` pulse hardware-clears `CTRL.TRAMP_EN`). Verified against the real T80 (`sim/tb_tramp.vhd`) |
| `ssp/rtl/z80_bus_mux.vhd` | `[new R15]` D-26 single mux at the T80 output boundary (A, D-out, strobes, `MRD_T1`, `M1_n`; `cpu_wait_n` sense back to the sequencer); select BusAck-gated (P-A); lives at the CPM-core boundary (VHDL, beside the T80) |
| `ssp/regs/ssp_regs.csv` + `tools/ssp_regmap.py` | `[new R15]` D-29 single-source register map → `ssp_regs.vh`, `ssp-regs.fs`, §6 Markdown table |
| `sim/` | `[new R15; R16 pattern]` D-28: `sim/ssp/` (Verilator: cores + bridge + BFM, Mecrisp REPL); integration = new `sim/run_ssp_*.sh` + `sim/tb_ssp_*.vhd` in the existing GHDL flow (T80 + MMU + SDRAM client FSM + VHDL-side units per D-33); Makefile targets = §13 TB names |
| `ssp/rtl/fp_capture.vhd` | `[R16: VHDL — D-33]` 68-bit shift-in, debounce (4-sample ~2 ms), quadrature/press decode, menu-counter (+commit latch), frame-error detect; single source of truth feeding `fp_engine`, bridge mirror regs, **and** the Z80 sense-port mux ($FC–$FF/$FB, §11.6) |
| `ssp/rtl/fp_engine.vhd` | `[R16: VHDL — D-33]` **Hardware classic-console executor** (D-18, §11.3): SPDT command decode → **macro index into the shared micro-op sequencer** (D-30, R15); AR/DR/MD/PR state, auto-increment, lamp-state outputs; event+log to FW |
| `ssp/rtl/ssp_mem_client.vhd` | `[R16: VHDL — D-33]` Parked physical SDRAM/BRAM client (D-15-P): drives existing client interface + BRAM mux while Z80-parked ∧ primary client idle; native DQM byte lanes |
| `ssp/rtl/ssp_sd.v` | (P2) vid-port background READ client; clk_ram CDC per existing pattern |
| `ssp/fw/*` | Mecrisp-Quintus build: `crt0.S`, linker, kernel glue, ODT app sources → `forth_rom.hex` (factory ROM init image) + pack files |

Integration: `ssp_top` instantiates at `MrZ80.sv`; `fp_capture`+`fp_engine`
+`ssp_mem_client` live at the CPM-core boundary (signals available:
`cpuAddress`, strobes, `cpuDataIn` mux point, `reset_n_internal`,
`cpu_cen`, BRAM mux, SDRAM request signals); chain export appended at the
capture-chain input; `FP_RAM_Store` Port-A ownership mux (§11.5).

### 4.3 Split arithmetic (why this and not more FW) `[decided]`
50 MHz vs 10 MHz Z80 ⇒ 5 `clk_sys`/T-state; a Mecrisp word ≈ 10 instr ≈
200 ns > one T-state; SSP-local-bus round-trip ≈ RV-side stall. Human-speed
events (switches, keys, bytes, ms-scale budgets) → FW with vast margin.
Cycle-boundary functions → bridge (P-C). Panel *operation sequencing* is
human-speed — but D-18 places it in HW anyway (owner preference: FW stays
simple and independent; classic console survives FW death), and it costs a
small FSM precisely because every cycle-level primitive it needs already
exists in the bridge for the FW's benefit. No duplicated datapath —
two controllers, one engine (G-3).

---

## 5. Support-CPU Subsystem

### 5.1 Core configuration (D-09, D-20)
RV32IMC · no caches/MMU · Harvard I/D ports onto MROM + RV RAM (no wait states) · machine mode ·
time base = bridge **`TICK_US`** MMIO counter (+ `rdcycle`; D-20 rev R15) ·
external IRQ input wired (level from `|IRQ_PENDING`) but **unused by v1 FW**
(polled, D-27) · SSP-local-bus master (valid/ready, stall-tolerant slave
contract, D-11) · reset = `locked ∧ core_reset ∧ !ssp_subsystem_reset`
(monitor up **before** any Z80 image). No JTAG (UART *is* the debugger).
Core = **FemtoRV32-gracilis** (D-37, R23 owner ruling; §5.6/§5.8).
gracilis instances set `ADDR_WIDTH=30` (D-34). RV-side RTL is Verilog,
Z80-side VHDL (D-33).

### 5.2 Memory map
| Range | Content |
|---|---|
| `0x0000_0000–0x0000_FFFF` | "ROM" — 64 KiB M10K, **RV read-only**; download write-port (ioctl route, only while monitor held in reset during mount); factory init from committed `ssp/fw/forth_rom.hex`; downloaded image persists across core resets, full FPGA reconfig restores factory (D-10) |
| `0x1000_0000–0x1000_FFFF` | RV RAM 64 KiB byte-enable: Mecrisp RAM variables + stacks + **the entire compiled dictionary** (RAM-only, D-32) + **pack staging** (§5.4) |
| `0x2000_0000–0x2000_0FFF` | `ssp_bridge` (§6) |
| else | decoder error → `resp.error`; FW trap word prints |

### 5.3 Console UART
8N1; divider = existing `O9B` table select (single baud truth for the SNAC
connector, session R4; 115200 = ÷27 from 50 MHz ⇒ +0.47 %). No RTS/CTS for
the monitor (G/decision R4): TX blocks on ready, RX FIFO drains by polling
(D-27). **Escape (D-14, rev R15):** a hardware recognizer compares each SNAC
RX byte with `ESC_CHAR` (reset default `0x1D` = `^]`) only while OSD `OM`
("Serial Escape") is On; a match while the Z80 runs parks it at the next
instruction boundary (reason=escape), hands the console to the SSP and
consumes the byte. With `OM` Off the link is bit-transparent to whoever
owns it.
**FW-visible registers `[new R17]`:** `UART_TXDATA` 0x120 (WO),
`UART_RXDATA` 0x124 (RC pop), `UART_STAT` 0x128 (`tx_ready`, `rx_avail`,
sticky `rx_overrun`), `UART_CTRL` 0x12C (`en`, self-clearing `rx_clr`/
`tx_clr`) — canonical rows in `ssp/regs/ssp_regs.csv`.

### 5.4 Downloadable ROM, dictionary window & packs (D-21; D-35 rev R18)
- `MROM` (index 6): RV32 image = **kernel + application dictionary merged**
  (`forth_rom.hex` factory-committed; `.bin` mountable at runtime). Mount
  streams over ioctl into the ROM-RAM; **on mount-complete: monitor-
  subsystem reset pulse only** — RV boots new image; Z80 untouched (D-16).
  Image self-ID header `[rev R18: relocated]` — ROM+0 is the reset jump
  vector, so the header lives at the **pack-window tail** `0xFFF0..0xFFFF`
  (`'MRZM'`, version, CRC); dictionary builds must stop 16 B short of
  `FlashDictionaryEnde`. FW `V` reports it.
- **Dictionary window `[new R18, D-35]`** `0x4400..0x10000`: contiguous
  above the kernel. Build pipeline (§5.4.1) compiles application Forth there
  via `compiletoflash` *in sim*; `catchflashpointers` picks the dictionary up
  natively at every subsequent cold boot -- no restore mechanism, no pointer
  manifest. Empty window (kernel-only image) is a valid artifact and already
  boot-proven (R17).
- `MPKG` (index 7): **FORTH source pack** staged to a reserved RV RAM region
  (top-of-RAM staging, default 8 KiB, final size at P0), trailer
  `{magic 'FPAK', len, name[8]}`; FW boot scan auto-`EVAL`s packs present
  (position-independent text; robust across kernel rebuilds). Same primitive
  backs serial paste/XModem upload (P2). **Operator-visible packs stay
  source-only** `[rev R18]` — binary dictionary content is strictly the
  build system's product (MROM image), keeping operator packs human-editable
  and machine dicts reproducible.
- Dictionary (RAM) contents lost on monitor reset; recovery = re-mount packs
  or serial re-upload; "workstation" persistence ideas → OQ-13 (deferred).
  `[R18]` cold boot re-initialises RAM variables from each definition's
  embedded init data (flash-dict walk semantics): application *code* persists
  in MROM, live variable *state* does not.

#### 5.4.1 Dictionary build pipeline (D-35)

1. `make -C ssp/fw qemu` (or the silicon-map build for stub runs).
2. REPL session (qemu now; stub SoC authoritative): send `compiletoflash`,
   then application `.fs` sources — firmware-paced byte feed, no FIFO
   overruns by construction.
3. Capture window: qemu via QMP `pmemsave` (this QEMU's schema:
   `{filename, val=phys-addr, size}`); stub SoC via harness dump of the
   `rom[]` array. Fragment artifacts: `build/dict-qemu.{bin,hex}`.
4. Merge `kernel.bin + dict.bin` at `0x4400` -> OSD-loadable hex.
5. Reproducibility rule (CI, sibling of R-45): same kernel hex + same
   `.fs` + pinned `$MECRISP` commit => byte-identical merged image.
Lanes implemented: `make -C sim dict-qemu` -> **PASS R18** (rehearsal);
`make -C sim dict-stub` / `dict-gracilis` -> **PASS R19/R20**
(authoritative, hardware-true: harness `$writememh` dump of `rom[]` ->
`build/mecrisp-ssp-<core>-app.{bin,hex}` = OSD MROM-loadable form; kernel
bytes below `0x4400` verified identical to the shipped kernel image; cold
boot of the artifact hex runs the app words, incl. `reg-id hex. ->
4D525A03` through the stub's bridge decode; demo dict 196 B). Determinism
double-run identical SHA-1s on every lane §17 R19-R20 -- and the two
hardware-map cores produce **byte-identical dict + merged artifacts**
(dict `dd250da5…`, merged `c43b230a…`): dictionary content is
core-neutral as predicted (same ISA + same map); the qemu-lane image differs
only because its map is DRAM-based.)

### 5.5 Firmware structure (Mecrisp-Quintus)

**Reference distribution `[R16, H-3 closed; R17 build model]:** Mecrisp-Quintus
**1.1.2a** lives as **its own repository** at `~/mecrisp-quintus`
(GPL-3.0-or-later — the compliance vehicle for the shipped `forth_rom.hex`).
**R17: reference, don't vendor** — the FW build consumes the common core *in
place* through `$MECRISP` (`…/mecrisp-quintus-source`; verified by
`make -C ssp/fw check-tools`); only our target files live in `ssp/fw/`.
Directly reusable
material: `mecrisp-quintus-source/` (full core as `.s` sections +
`common/` tools incl. RV32IMC disassembler/assembler), the per-target
pattern `mecrisp-quintus-<t>.s` + `memmap` + `Makefile` + `terminal.s`
(→ our `ssp/fw/` skeleton mirrors `ulx3s-pipeline-compressed/`, the closest
ancestor: ROM@0 + RV32IMC + compressed dictionary), `common-verilog/`
(FemtoRV
variants incl. `femtorv32_gracilis.v` — whitespace-only diff vs our
vendored learn-fpga copy — plus `uart.v`, `MappedSPIFlash.v`, `celement.v`
= serial-CPU element for lamp-style arrays; MappedSPIFlash is **not** used,
D-32/R17), `release/quintusemu-*` host
emulators for running `.bin` images without hardware, and
`linux-rv32imc/` native runtimes. FW glue: `interrupt-femtorv.s` shows
the gracilis IRQ idiom (unused in v1, D-27). Our builds use
`riscv64-unknown-elf-*` with the §5.8 march flags (the release Makefiles
cite older `riscv64-linux-gnu` invocations — adapt, don't copy verbatim;
`ld` additionally needs `-m elf32lriscv` for the ELF32 objects).
**Built and REPL-verified in sim at R17** — see §5.5.1.

#### 5.5.1 P0 FW bring-up results (R17)

`ssp/fw/` builds `mecrisp-ssp.{elf,bin,hex}` (RV32IMC, `.option norelax`
+ `rvc`, `erasedflashcontainszero` — our ROM images are zero-filled, HW M
(no `softwaremultiply`), RAM dictionary at RV RAM, `FlashDictionary*` = 1 KiB
zeroed pad reserved at ROM top for future MPKG packs (D-21); kernel
≈ 15.9 KiB of the 64 KiB MROM). `terminal.s` drives the bridge UART
(0x120–0x12C) with a `-DQEMU_NS16550` variant for qemu virt; `flash.s`
stubs `flash!`/`hflash!`/`flushflash` (accept-and-discard; no flash device
exists). Smoke: `make -C sim smoke-qemu` drives the REPL on
`qemu-system-riscv32` and asserts `1 2 + . → 3`, `: sq dup * ; 5 sq → 25`,
`hex FF . → FF` — **PASS**.
Lessons banked: (1) terminal hooks are **tail-dispatched**, so the driver
must manage the stack itself — `emit`/`qemit`/`key`/`qkey` end with
`drop`/`pushdatos` (the `drop` in `emit` is what restores the string pointer
`type` had duplicated; missing it faults exactly one character into the
banner); (2) instantaneous pipe bursts overrun the ns16550 RX FIFO — sim
harnesses must pace input (real SNAC traffic is baud-paced); (3) `FOR`/`NEXT`
are absent from the Mecrisp core by design — loop words arrive later as
packs/EVAL'd tools (D-21), not the kernel; (4) `CONSTANT` is **postfix**
(`value CONSTANT name`) -- the first `.fs` emitter draft wrote it prefix;
fixed in `tools/ssp_regmap.py`, and the regenerated `ssp-regs.fs` live-load
verified on the qemu REPL (constants define and read back; `hex.` prints
zero-padded 8 digits; generated lines stay under the 200-char TIB).

**Stub-SoC bench lessons `[R19]`** (picorv32 twin `sim/ssp/`,
`make -C sim smoke-stub` PASS): (5) picorv32 `mem_la_*` are **look-ahead**
outputs -- asserted *before* `mem_valid`, so gating them with `mem_valid`
never fires; discriminate read vs write data-phase with `mem_instr` +
`mem_wstrb` (load = `!mem_instr && wstrb==0`); (6) the console harness must
**gate input release until firmware is alive** (first TX byte + grace) --
FW `uart_init` writes CTRL `rx_clr`, which otherwise flushes keystrokes the
harness pushed during boot (real operators type after the prompt; structural
FIFO-room RX pacing was already proven); (7) **Mecrisp echoes received
characters itself** (`key` echoes) -- console logs are "echo + reply on one
line" (`"."` emits *leading* space, `cr` emits LF `\n`); harness-local
echo is therefore OFF by default.

`crt0.S` trap vector → Forth dispatcher; stack-register convention verified
against the chosen port during P0 (was OQ-09b — P0 checklist item, carried).
Glue primitives: `serial-key?`, `serial-key`, `serial-emit`, `milliseconds`
(reads `TICK_US`). **Memory model (D-32, R15):** RAM-only — `compiletoram`
throughout; kernel executes from the MROM image, every compiled word lives in
RV RAM; Mecrisp's flash-write primitives are stubbed to an error; no flash
emulation. **Event handling (D-27, R15): polled** — the main loop reads the
sticky `IRQ_PENDING` bits and dispatches: bp/esc→halt line + REPL;
trap→log/release; fp_done→panel-op mirror update (comments,
disassemble-last); mbx→mailbox service; wdg→console-dead report; W1C after
handling. Loop body: parked→REPL `.`; running→background (pump panel mirror,
service traps, kick both WDGs, `CONN_ROUTE` service). The core's IRQ
mechanism is unused in v1, so the same FW source runs on either P0 core
(only `crt0.S` differs).
`F`⇄`ODT` raw-Forth / ODT-skin switch (session posture: ODT syntax is a
skin over a scriptable core).

### 5.6 Toolchain & core candidates
P0 is a **two-core bake-off** (R14, D-09): **PicoRV32** (`picorv32.v`,
`COMPRESSED_ISA` ⇒ RV32IMC; ISC; formally checked with riscv-formal; long
Quartus/Cyclone-V track record incl. picosoc flows) vs
**FemtoRV32-gracilis** (RV32IMC+IRQ native; ships inside the
Mecrisp-Quintus distribution). Both entries are vendored single-file
Verilog — no generation step for either; FW built with the packaged
`riscv64-unknown-elf` GNU chain (**§5.8** toolchain note). **P0 = full tycho
Quartus 17.0 synthesis spike** for `5CSEBA6U23I7`, per core, incl.
Mecrisp hello-world
on the UART + `fit.rpt` headroom capture; selection on the §5.8 criteria,
recorded in the P0 exit note.
Optional tie-breaker: riscv-formal against picorv32 in a throwaway
yosysHQ/eqy container — the §5.7 one-shot pattern applied to
*verification* rather than generation, off the critical path.
Zero-new-environment
note: post-R12/R14 the *entire* toolchain surface is distro
packages; the §5.7 container path belongs only to the shelved VexRiscv
route (OQ-21).

### 5.7 Containerized generation of the VexRiscv configuration ("vexgen")

> **SHELVED (R12, 2026-10-26).** VexRiscv work is deferred — P0 is the
> picorv32 ⟷ gracilis bake-off (R14, §5.8/D-09). Bus/timer wording below
> ("SimpleBus", mtime) is VexRiscv-specific and does not apply to the P0
> cores. This section is retained as
> ready-to-execute guidance should the shelved path reopen (OQ-21);
> nothing here is installed or scheduled.

No Scala/sbt toolchain is ever installed on the dev box or on `tycho`;
the CPU .v is produced in a throwaway container exactly like Quartus is
(quartus_build.sh pattern: SSH → `docker run --rm` bind-mount → outputs
land back in the repo), then **vendored + committed** (D-09). Day-to-day
builds never see the toolchain; the container is re-run only when the CPU
config is deliberately reconfigured (G-7 hygiene for RTL).

**Generator (`Components/RISCV/gen/GenMrZ80.scala`, vendored).** Anchored on
upstream **Murax** (`vexriscv.demo.Murax`) — VexRiscv's own smallest
SoC generator, whose CPU plugin set is precisely our §5.1 spec:
RV32**IMC** (`FetchPlugin` compressed + `ExecPlugin`/`MulPlugin`/
`DivPlugin`, full barrel shifter), machine-mode-only
(`CsrPluginConfig.smallest`-class: mtime/mtimecmp soft timer, MSIP-style
soft IRQ + one external IRQ input wired from `|IRQ_PENDING`), **no MMU, no
I$/D$**, simple uncached IBus/DBus. Murax's APB peripherals (uart/gpio/
prescaler) are dropped — UART lives in our bridge (§5.3); the generator
emits the bare *CPU* plus its IBus/DBus + IRQ/timer pins, which our
`rv_top` wires to MROM/RV RAM/SimpleBus shim and `ssp_bridge`.

**Container (`tools/vexgen/Dockerfile`, built once on tycho).**
`FROM eclipse-temurin:17-jdk` + `git` + the **mill** launcher single
binary (upstream VexRiscv README documents mill as the sbt alternative:
`curl -L -o mill …/0.11.6-assembly`; no sbt, no scala install, JDK 17
satisfies current SpinalHDL). Tag `localhost/mrz80-vexgen:1`. First run
pulls ~500 MB of Maven deps into coursier/ivy; persist them in a named
volume (`mrz80-rvcache` → `/root/.cache/coursier:/root/.ivy2`) so later
runs are near-offline.
Optional same-image add-on: prebuilt **riscv64-unknown-elf binutils**
(riscv-collab tarball, unpack-anywhere) so Mecrisp `crt0.S`/kernel
assembly builds in the same container — no host installs for FW either.

**Wrapper (`tools/vexgen.sh`).** Mirrors `tools/quartus_build.sh`: find
project root; rsync `Components/RISCV/gen/` →
`tycho:Projects/z80fp/MrZ80-gen/`; `ssh tycho docker run --rm -v …:…
-v mrz80-rvcache:… localhost/mrz80-vexgen:1 ./mill
"VexRiscv.runMain mrz80.GenMrZ80"`;
rsync outputs back. (Unlike the Quartus wrapper's implicit remote-copy
assumption, vexgen makes both sync directions explicit in the script.)

**Pinned inputs + provenance manifest (all committed).**
`Components/RISCV/VEXRISCV_MANIFEST`: upstream URL + pinned VexRiscv commit
(`VEXRISCV_REF`), SpinalHDL/JDK/mill versions (also echoed in the
generated file header), exact mill command line, sha256 of the emitted
Verilog, and the P0 fit figures. Outputs: `Components/RISCV/VexRiscv.v`
(+ any companion `.v` the generator emits; `.qip` per AGENTS mechanism 3),
marked `.gitattributes: linguist-generated=true`.

**Reproducibility gate (P0 exit):** regenerate twice at the same pin —
body diff must be empty (ignore generator date/header lines). Any
unexplained diff blocks vendoring.

**Pin candidates `[proposed, verify at spike]`:** VexRiscv master as of
2026-Q4, or — for extra provenance — the exact rev LiteX pins per variant
in `litex/soc/cores/cpu/vexriscv` (LiteX ships *our* config-adjacent
pre-gens, confirming field-tested pins; we generate ours fresh at that
pin). Pre-generated VexRiscv files elsewhere (m-labs/VexRiscv-verilog
2019 snapshot; LiteX variant cores) are **not** adopted directly: fixed
wrong plugin sets (no RV32C, or MMU+caches); they are config references
only.

### 5.8 FemtoRV32 — evaluated alternative core (R11, owner-initiated 2026-10-26) → **SELECTED: D-37, R23**

Owner directive: investigate **FemtoRV** as the debugger CPU. Strong fit
signals: it is pure Verilog (no generation/build system anywhere), it is
the softcore family **co-developed with Matthias Koch** — Mecrisp's author —
and ships inside the official Mecrisp-Quintus distribution, so the
firmware alignment we already rely on is first-party.

**Source of record:** <https://github.com/BrunoLevy/learn-fpga/tree/master/FemtoRV/RTL/PROCESSOR>
("FemtoRV processor collection"); background reading:
<https://deepwiki.com/BrunoLevy/learn-fpga/3-femtorv32-processor-design>.

Variant table (from the repo README, 2026-10):

| File | ISA | Notes (repo description, condensed) |
|---|---|---|
| `femtorv32_quark.v` | RV32I | Smallest; bit-serial shifter (tiny-FPGA target) |
| `femtorv32_quark_bicycle.v` | RV32I | Quark + barrel shifter; best CPI of the family |
| `femtorv32_tachyon.v` | RV32I | Exec split in two stages for higher fmax, worse CPI |
| `femtorv32_electron.v` | RV32IM | Barrel shifter + mul/div |
| `femtorv32_intermissum.v` | RV32IM + IRQ | Full interrupt support + CSR registers |
| **`femtorv32_gracilis.v`** | **RV32IMC + IRQ** | Compressed instructions — "saves both RAM usage and memory fetch cycles"; repo-recommended general-purpose part → **primary eval target** |
| `femtorv32_individua.v` | RV32IMAC + IRQ | + atomics ("useful for tricky interrupt handlers") |
| `femtorv32_petitbateau.v` | RV32IMFC + IRQ | Floating point (not needed; listed for completeness) |

**Why it earns an evaluation slot:**
- `gracilis` = RV32IMC + IRQ matches our §5.1 ISA requirement *exactly*,
  including the compressed encoding the owner flags for **future memory
  footprint concerns** (RVC ≈ 25–30 % smaller code images; Mecrisp
  kernels are 18–30 KiB against our 64 KiB MROM budget).
- Its IRQ model is PicoRV32-derived *custom-CSR* — deliberately simple,
  which is precisely the "IRQ via pending-register dispatch" model R1
  chose; no CLINT/PLIC machinery to bolt on. **[R15 erratum: wrong —
  gracilis implements the *standard* `mtvec/mepc/mcause/mstatus` CSRs +
  `mret`; it is picorv32 that uses custom instructions. See §3 and D-27.]**
- Footprint: family-scale ≈ a few hundred ALUTs — comfortably below any
  VexRiscv config; frees budget (LUTs *and* M10K) vs D-09's incumbent.
- Compressed variant addresses footprint *without* the LiteX-style caches
  we rejected; higher performance than PicoRV32 at similar size per the
  family README positioning. `[verify]`

**Deltas to verify at spike (vs §5.1):** (1) **machine soft-timer** —
confirm CSR mtime/mtimecmp presence; if absent, the tick moves to an MMIO
counter in `ssp_bridge` (our `milliseconds` glue reads it — trivial FW
change, negligible budget); (2) interrupt *latency & nesting* semantics vs
R-13-era dispatch assumptions; (3) repo license compatibility for vendoring
(learn-fpga is openly published; verify exact terms at checkout);
(4) external-reset-vector & stall-tolerant slave contract on its simple
buses; (5) Quartus 17.0 fmax/area on `5CSEBA6U23I7` (Verilog-2001, so
expected uneventful).

**Disposition (superseded by R12, then R14 — see D-09):** gracilis is the **P0
primary core**, not merely a candidate; VexRiscv shelved (reopen = OQ-21
measured drivers); PicoRV32 remains the baseline fallback. *(R14: now a
two-core bake-off; both cores vendored 2026-10-26 in `Components/RISCV/`.)*

**R14 addendum — PicoRV32 elevated to co-candidate (external research,
owner-forwarded 2026-10-26).** The forwarded recommendation: PicoRV32 for
formal verification pedigree, simple valid/ready memory interface, documented
custom-IRQ mechanism, deep docs/examples (PicoSoC), ISC license; "slow is
fine for a support processor"; FemtoRV framed as tiny-iCE40-oriented, less
documented/formally verified, FemtoSoC-wrapper-oriented, no atomics.
Assessment against *our* specifics:
- *Endorsed:* riscv-formal pedigree is the strongest argument, and the one
  that matters most for a **debug host** — the core we trust to inspect
  everything else must itself be beyond doubt; picorv32 is riscv-formal's
  reference target (optional eqy-container run at P0, off critical path).
  Memory-interface simplicity genuinely suits the `ssp_top` decoder;
  ecosystem depth (PicoSoC, decades of field use incl. Quartus/Cyclone V)
  is real; speed non-issue matches our §4.3-class arithmetic.
- *Corrected for context:* RV32C exists on picorv32 (`COMPRESSED_ISA`
  parameter) ⇒ gracilis's footprint/coding-density advantage **neutralized**;
  **neither** core implements standard `mtime` ⇒ the bridge-MMIO 1 MHz tick
  (R12 verify item) is *common* design work, not a gracilis penalty; the
  atomics critique cuts both ways — picorv32 lacks the A extension too, and
  Mecrisp doesn't need it; gracilis is not "unverified" — it *ships in the
  official Mecrisp-Quintus distribution* running the exact Forth we will
  run, and the family's custom-IRQ encodings are **PicoRV32-lineage**, so
  FW IRQ glue is near-portable across the finalists (the FW bet survives
  either pick). **[R15 erratum: the IRQ-portability claim is false — the
  two IRQ models are unrelated (gracilis standard CSRs/`mret`; picorv32
  `getq/setq/retirq/maskirq/waitirq/timer`). Portability is restored by
  design instead: v1 FW is polled (D-27), so only `crt0.S` differs. Also:
  Mecrisp-Quintus's *first* target was PicoSoC (picorv32), so both cores
  have first-party Mecrisp lineage.]**
- *External "design considerations" already in our architecture*
  (corroboration, not new work): private program/data RAM = D-10 MROM/RV RAM
  (unreachable from the Z80 bus); Z80 halt/reset control = `CTRL`
  `z_busreq/z_wait/z_rst` + `cen_gate` — stronger than the generic
  WAIT-advice, and carrying our *verified* T80 nuance (FREEZE, never
  tri-state ⇒ explicit muxes, P-D/G-2); explicit CDC = level-req +
  toggle-done idiom (§9.2/SDRAM plan); HPS-vs-SSP job split = D-19 console
  routing + P3 HPS-path eval (HPS = storage/config/archive host; SSP =
  runtime observation + panel + fast reaction — deliberately no Linux
  duplication on the board).

**P0 bake-off criteria `[decided R23 — owner selected gracilis, D-37]`:**

| Criterion | How measured | Weight |
|---|---|---|
| Trust / pedigree | riscv-formal pass on picorv32 (eqy container, optional-but-recommended); field history (picorv32 broad & long, incl. Mecrisp-Quintus's original PicoSoC target; gracilis = shipped-Mecrisp targets) | **highest** — debug host must be beyond doubt |
| ISA parity | RV32IMC both ways (`COMPRESSED_ISA` vs native) | parity |
| Bus-fit to `ssp_top` | wrapper LOC + `fit.rpt` timing on the local-bus↔ROM/RV RAM/decoder shim, per core (picorv32 valid/ready native; gracilis rstrb/wmask/busy shim) | high |
| Timer | no `mtime` on either ⇒ bridge `TICK_US` shared design (§6) | parity |
| Quartus 17.0 on `5CSEBA6U23I7` | `fit.rpt` ×2 area/fmax | medium (both expected easy) |
| Mecrisp bring-up effort in sim | `crt0.S` + glue LOC and time-to-REPL in Verilator (D-28), per core | medium |
| Docs / community | picorv32 deeper; learn-fpga tutorials adequate, lighter | medium |
| License | ISC (picorv32) vs BSD-3-Clause (learn-fpga) — **checked, both fine** (`Components/RISCV/PROVENANCE.md`) | closed |

*R15: the "IRQ glue — parity" row is removed (the claim was false, and the
question is moot under polled v1 FW, D-27).*

**Working lean `[proposed]`:** if the riscv-formal run executes, **picorv32
+ `COMPRESSED_ISA`** takes it on trust + ecosystem at zero ISA/footprint
cost; gracilis overturns only if its bus-fit or Mecrisp bring-up is
*measurably* cheaper at P0. With polled FW (D-27) the FW differs only in
`crt0.S`, so the decision stays reversible long after P0. (R15 strengthened
this lean: picorv32 also has first-party Mecrisp lineage.)

**Cross-development toolchain `[decided R12]`:** packaged **GNU
`riscv64-unknown-elf-*`** toolchain (distro package, e.g. Debian/Ubuntu
`gcc-riscv64-unknown-elf`; riscv-collab prebuilt tarball as the
no-package fallback). *An RV64 toolchain emitting RV32IMC is correct and is
standard FPGA practice* — the ISA is chosen per-invocation, not at
compiler-build time:
`riscv64-unknown-elf-gcc -march=rv32imc_zicsr_zifencei -mabi=ilp32`
(LiteX/picorv32/FemtoRV SoCs are all built this way). Notes:
(a) binutils ≥ 2.38 moved CSR/fence-i ops into `Zicsr`/`Zifencei` — the
march suffix is *required* or `csrr/csrw` glue (gracilis standard-CSR
code, `rdcycle`) won't assemble;
(b) multilib (`-print-multi-lib`) supplies rv32 runtime libs, but the
freestanding Mecrisp kernel needs essentially none (mul/div are
instructions) — a multilib-less chain still builds it;
(c) bare-metal `unknown-elf` triplet, never `riscv64-linux-gnu`;
(d) one toolchain covers both candidate cores — the PicoRV32 fallback adds
zero further tooling.

**Measured bake-off — Quartus 17.0 Lite, `5CSEBA6U23I7` `[R21, fit.rpt ×2].**
Both cores wrapped in an **identical** fabric (MROM+RV RAM as explicit
`ssp_sdp_ram` altsyncram IP, §5.8.1; console UART + decoder-error shim +
RV RAM guard), one 50 MHz clock, throwaway projects `bakeoff/` (README has the
run recipe + inference findings):

| Metric (fit) | picorv32 | gracilis | Δ | 50 MHz target |
|---|---|---|---|---|
| ALMs / 41,910 | 1,482 (4 %) | **1,128 (3 %)** | −354 (−24 %) | pass both |
| registers | 1,251 | **540** | −711 | — |
| block memory bits | 1,050,624 | 1,050,624 | 0 (identical IP) | — |
| RAM blocks / 553 | 130 | 130 | 0 | — |
| Fmax @ slow-1100mV-85C | **72.06 MHz** | 64.13 MHz | −11 % | pass both |
| Fmax @ slow-1100mV-0C  | 71.42 MHz  | 63.67 MHz | −11 % | pass both |

Read: **both entrants clear the 50 MHz budget with ≥ 28 % margin**, so speed
is *not* a discriminator (owner: "slow is fine for a support processor").
gracilis is ~24 % smaller and carries ~700 fewer registers; picorv32 buys its
extra ~350 ALMs with higher fmax headroom and the riscv-formal pedigree
(§5.8 weight "highest"). **Neither core is disqualified on area or timing** —
OQ-20 is not decided by these numbers alone; it comes down to trust/pedigree +
bus-fit, which are the higher-weighted criteria. **[RESOLVED R23 — owner
picked gracilis (D-37), with §5.8.2 performance evidence decisive.]** Time-to-REPL in Verilator
(sim-lane evidence, R19/R20): both boot the identical FW hex and pass the same
benches; the FW image is core-neutral (§5.4.1) so the FW bet survives either
pick.

### 5.8.1 Memory-fabric implementation note (R21, owner ruling)

The bake-off (and the production `ssp_top`) **instantiates block RAM explicitly
rather than relying on Quartus inference.** For picorv32 inference happened to
work, but its "pass-through duplication" inflated the reported usage 2×
(258 blocks / 2.1 Mbit → honest 130 / 1.05 Mbit); for gracilis inference
failed outright (`Error 276003`, rom/dtcm as ~1M raw registers) because FemtoRV
drives a **combinational** address bus and Quartus 17 wants a registered read
address to absorb into M10K. A staged probe (`bakeoff/ramprobe.v`, v1–v4 — full
findings in `bakeoff/README.md`) isolated the discriminator. Rather than
continue reverse-engineering the tool's acceptance rules, the fabric now uses a
hand-written MegaWizard-style `altsyncram` wrapper `bakeoff/ssp_sdp_ram.vhd`
(DUAL_PORT 16K×32, port-A byteenable, `ADDRESS_REG_B=CLOCK0`,
`OUTDATA_REG_B=UNREGISTERED`), matching the wrappers already shipping here —
`Components/INTERNALRAM/InternalRam64K.vhd` (SINGLE_PORT 64K×8, the general
memory system) and `Components/TERMINAL/DisplayRam1K.vhd` (BIDIR_DUAL_PORT
1K×8). **Decided as D-36: SSP block memories are explicit altsyncram IP
instances.**

Consequence (honest, both entrants): the IP's registered read address makes
**launch+1 read latency** the fabric truth — which is natively FemtoRV's
`rstrb` protocol (no `mem_rbusy` needed for RAM reads) and costs picorv32's
zero-latency valid/ready bus one wait-state per access. FW/boot sees the same
single-cycle-latency memories either way; `sim/ssp/` twins keep behavioral
memories (gracilis lane protocol-identical; picorv32 lane FW is
handshake-driven so a wait state is invisible to FW).

### 5.8.2 Cycle-level performance benchmarks (R22, `sim/ssp` Verilator lanes)

Owner-directed follow-up to the fit numbers: identical Mecrisp FW image run on
both stub SoCs, timed at the console with EMIT-marker brackets and
TXTRACE cycle stamps (`sim/ssp/bench_stub.sh`; lanes
`make -C sim bench-stub` / `bench-stub-fab` / `bench-gracilis`).
Method (R22 refinements banked in the script header):

* production-shape workloads only — resident words in resident loops;
  interactive dictionary token lookup (~10^5 cyc, see §5.8.3) sits outside
  the brackets; no `RECURSE` (rare in production Forth, owner note);
* each loop timed at N=200000 and N=100000 (equal digit counts) — the
  difference divided by 100000 cancels every fixed FW cost (parse, echo,
  `ok.`), leaving pure per-iteration core execution (results are exact
  integers — the cancellation is clean);
* `+FABWAIT` knob added to the picorv32 stub models the D-36 explicit-IP
  fabric (launch+1 on every access incl. instruction fetch). The bare
  picorv32 stub is zero-wait and therefore *flattering*; the gracilis stub
  has launch+1 natively (`rstrb`), so **picorv32-fab vs gracilis is the
  silicon-predictive pairing**.

Measured, core cycles/iteration (all goldens passed: L3/L4/L5/L7 all reduce
to Σ(0..N-1) mod 2^32):

| op (isolated by ladder delta) | picorv32 zero-wait | picorv32 +FABWAIT (silicon) | gracilis (native launch+1) |
|---|---|---|---|
| bare `DO…LOOP` control | 10 | 13 | **8** |
| near-no-op subroutine call | 7 | 9 | **4** |
| marginal call (×3 check) | 8.3 | 10.3 | **5.3** |
| `I` fetch + accumulate | 22 | 27 | **16** |
| stack-op unit call (`DUP DUP 7 + + DROP`) | 45 | 56 | **34** |
| MUL replaces ADD in unit | 41 | 42 | **3** |
| `VARIABLE` store + retrieve | 111 | 140 | **82** |
| boot → banner | 252,422 | 322,305 | **195,756** |

Read: **gracilis wins every op against both picorv32 configurations** —
~1.25–1.75× on loop/call/stack/memory ops while already paying the fabric
latency picorv32 doesn't in the bare stub; at equal-fabric conditions
picorv32-fab vs gracilis the gap is 1.6–2.3×. The standouts: FemtoRV's
hardware multiplier (+3 cyc vs picorv32's +41 — consistent with the
Mecrisp-co-designed datapath; picorv32's +41 deserves a config follow-up
but is directionally irrelevant: even zero-wait picorv32 loses 13.7×) and
native launch+1 costing gracilis ~0 while costing picorv32 +30 % per loop.
Combined with R21 (gracilis −24 % ALM/−711 regs at 50 MHz-equivalent
timing margin), **the performance axis of OQ-20 now favors gracilis
decisively**; the residual discriminator is trust/pedigree (§5.8 weights) —
owner ruled R23 in favor of gracilis: **D-37**.
Caveats: Verilator functional sim (cycle-exact RTL, no gate delays);
`+FABWAIT` models D-36 IP read latency only (no future peripheral skew);
fmax-adjusted absolute throughput is a wash at the 50 MHz budget — both
cores run the same FW comfortably.

### 5.8.3 FW observations from benchmarking (R22, informational)

* Interactive token lookup costs ~10^5 core cycles per word reference on the
  current kernel (O(dictionary) search, grows with dictionary size) —
  dominates REPL round-trips (~0.3 ms/op at 50 MHz: acceptable for a
  support console). Excluded from core scoring (owner: production code
  does not re-lookup).
* Kernel quirk banked: `RECURSE` definitions whose IF-condition uses a
  constant-folded comparison (`DUP 1 <= IF`, `DUP 2 < IF`, `DUP 0= IF`)
  produce wrong results (`(n-1)!` or 0) in this kernel — investigate
  constant-fold/RECURSE interaction at FW level before shipping any
  recursive FW word; non-recursive FW unaffected (all R17–R20 suites pass).
* `variable` is not in the kernel (it lives in Mecrisp `compiler-flash.s`,
  excluded by D-32) — provide via `CREATE` (proven pattern in bench).

---

## 6. Debug Bridge (`ssp_bridge`) — MMIO map (v0.3)

Base `0x2000_0000`, word offsets, 4 KiB. `[shared]` = also driven/updated by
`fp_engine` (G-3: single door, dual controllers).
**R15 (D-29):** this table becomes a *generated* artefact of
`ssp/regs/ssp_regs.csv` once RTL starts; until then it is the seed for that
CSV. All event bits are **sticky W1C** so polled FW is correct (D-27).
**R16:** the CSV now exists — `ssp/regs/ssp_regs.csv` is **canonical**;
generated outputs are `ssp/rtl/ssp_regs.vh`, `ssp/rtl/ssp_regs_pkg.vhd`
(VHDL side, D-33) and `ssp/fw/ssp-regs.fs`; check with
`make -C sim regmap-check`. One map addition (H-8): `STATUS` gains
**`rv_trap`** — picorv32's `trap` output (core halted on
illegal/misaligned access) as a "SSP FW crashed" chrome/WDG indicator.

| Off | Reg | Acc | Description |
|---|---|---|---|
| 0x00 | `ID` | R | `0x4D52_5A03` rev-stamped |
| 0x04 | `CTRL` | RW | bit0 `z_rst_n` · bit1 `z_busreq_n`(FW hold) · bit2 `z_wait_n` · bit3 `cen_gate` · bit4 `tramp_en` · bit5 `esc_break_en` (reset 1; effective only with OSD `OM` On — FW can disable, never override the OSD, D-14) · bit8 `console_own` · bit9 `panel_lock` (G-8: gates panel RUN/START only; auto-clears on WDG_PARK expiry/escape/OK-off/MROM mount); **forced inactive when `!ssp_active`**; park sources = FW hold ∨ engine stop-latch (D-13) |
| 0x08 | `TRAMP_ADDR` | RW | `G aaaa`/START target |
| 0x0C | `STATUS` | R | `BusAck, HALT_n, M1_n, MC, TS, ALT (new P1), cpu_running, ssp_active, s32, fw_console_ok, eng_stop_latch, seq_busy, wdg_dead`, **`at_boundary`** (R15/D-25: park landed on an instruction boundary ⇒ snapshot architectural), **`osd_esc_en`** (live OSD `OM`), **`rv_trap`** (R16/H-8: picorv32 halted on illegal/misaligned access — "SSP FW crashed") |
| 0x10 | `HALT_REASON` | R/clr | §10.4 codes (+`wdg`) |
| 0x14 | `PC_LATCH` | R | match/park PC |
| 0x18–0x30 | `SNAP_REG0..6` | R | `REG` frozen at park/match instant (R-snapshot discipline) |
| 0x34–0x4C | `LIVE_REG0..6` | R | combinational `REG` (meaningful parked) |
| 0x50 | `STEP_CTL` | RW | `{mode: off·INSN·MCYCLE·TSTATE×n, n}` (P-C) |
| 0x54–0x60 | `BP0..BP3` | RW | `{en, addr}` |
| 0x64 | `BP_SKIP` | RW | suppress-next-match mask (`C`) |
| 0x68–0x70 | `TRAP_CTL/ADDR/DATA` | RW | I/O trap `{en, wait_stall, rnw}` / port / `{mask, val}` |
| 0x74 | `MEM_CTL` | RW | **shared engine kick**: `{start, rnw, is_io}`; busy/done/timeout readback — arbitrated: panel-op-in-progress blocks FW kick, else panel wins simultaneous kick (engine priority). R15/D-30: a FW kick enqueues a one-step macro on the same micro-op sequencer the panel uses; arbitration per macro |
| 0x78 | `MEM_ADDR` | RW | `[shared]` op address: source = `AR` (mem) or `PR` (port) when kick bit `use_shared` set; explicit-value kicks allowed for FW scripted ops |
| 0x7C | `MEM_DATA` | RW | read = captured byte (latched at strobe **release**, `rd_done` discipline) · write = data-out (staged; source `DR` when `use_shared`) |
| 0x80 | `MD` | RW/clr | `[shared]` addressing mode: 0=logical(16b), 1=physical(28b) — tracks panel S31, FW `PHY`/`LOG` write |
| 0x84 | `AR` | RW | `[shared]` 28-bit address register (logical ops use 16 low bits) |
| 0x88 | `DR` | RW | `[shared]` data register (panel deploys low 8 of switch data field; FW full byte) |
| 0x8C | `PR` | RW | `[shared]` I/O port register (8b) |
| 0x90 | `ENG_STAT` | R/clr | panel engine state: `{last_op[3:0], auto_inc_active, engine_err}` + last-op completion |
| 0x94 | `ENG_LOG_ADDR` / 0x98 `ENG_LOG_DATA` | R/clr | last panel operation address/data (FW mirror, IRQ `fp` source) |
| 0xA0–0xAC | `SD_ADDR/SD_WDATA/SD_RDATA/SD_CTL` | RW/R | vid-port background window (P2; reads only — `SD_CTL.err` on write attempts until D-15-B revisit) |
| 0xB0 | `WDG_RUN_KICK` · 0xB4 `WDG_PARK_KICK` · 0xB8 `WDG_STAT` | WO/WO/R | two-tier watchdog (§6.9); `WDG_STAT {run_expiredL, park_deadL, park_timer}` |
| 0xC0 | `IRQ_EN` / 0xC4 `IRQ_PENDING` (W1C) | RW | `bp0..3, trap, rx, esc, mbx, fp_done, map_changed?, sd_done, wdg_park` — **sticky event register, polled by v1 FW** (D-27); `IRQ_EN` only gates the optional IRQ line |
| 0xC8 | `CONN_ROUTE` | RW | `{out_snac=1 default, out_hdmi(P2), in_snac=1 default, in_kbd(P3)}` — FW policy, HW fail-safe defaults on reset/`wdg_park` (D-19) |
| 0xD0–0xDC | `MBX0..3` | RW | Z80 mirror ($D0–$D3); Z80 write → IRQ `fp_done`-class new bit `mbx` |
| 0xE0–0xEC | `MAP0..MAP3` | R | **MMU frame tap**: `{valid, page[13:0]}` ×4 — FW translation shadow, state-neutral (P-D) |
| 0xF0 | `SSP_CTRL` | RW | `[shared]` chain-export control: `{enable, page}` — selects which 64-bit state block feeds `SSP_CHAIN[63:0]` (§11.4); panel engine writes `page` on encoder commit (D-23); WDG_PARK expiry forces `page←0` |
| 0xF4 | `LED_ADDR` | RW | profile-7 map/colour/fb write address (forwarded to `FP_RAM_Store` Port-A via ownership mux, §11.5) |
| 0xF8 | `LED_DATA0..2` | RW | map entry (≤10b) / colour (R,G,B) / fb bit per write-type select — FW rewrites profile-7 **map per page** (G-9); cold default = identity map ⇒ CLASSIC layout free |
| 0x100 | `FP_SW` | R | debounced toggle bank `{S31..S0}` — same source driving Z80 ports $FC–$FF (single source of truth, §11.6) |
| 0x104 | `FP_FN` | R | live debounced SPDT function-line levels (18 lines incl. MMU-EXAM/DEPOSIT at bits 17:16, R10, §11.2) — FW snoop of panel activity |
| 0x108 | `FP_ENC_CNT` | R | menu-selection counter — same source as Z80 port $FB (§11.6) |
| 0x10C | `FP_ENC_STAT` | R/W1C | `{committed[7:0](15:8), page_id[2:0], dbl_zero_evt, commit_evt, press_evt}` — press commits page (cursor **held**, D-23); rapid double-press zeroes cursor w/o commit; FW may subscribe instead of polling |
| 0x110 | `ESC_CHAR` | RW | `[new R15]` serial escape character (reset `0x1D` = `^]`); recognizer active only with OSD `OM` On ∧ `CTRL.esc_break_en` (D-14) |
| 0x114 | `TICK_US` | R | `[new R15]` free-running 32-bit 1 MHz counter (D-20; `milliseconds` glue) |
| 0x120 | `UART_TXDATA` | WO | `[new R17]` TX holding (SNAC); honored while `UART_STAT.tx_ready` (§5.3) |
| 0x124 | `UART_RXDATA` | RC | `[new R17]` RX FIFO pop; clears `rx_avail` when empty |
| 0x128 | `UART_STAT` | R | `[new R17]` `tx_ready, rx_avail, rx_overrun` (sticky; `CTRL.rx_clr`) |
| 0x12C | `UART_CTRL` | RW | `[new R17]` `en` (reset 1), self-clearing `rx_clr`/`tx_clr` |
| 0xFF0 | `DEC_ERR_COUNT` | R | unimplemented-offset counter |

`SSP_CHAIN[63:0]` is a structural output of `ssp_bridge` (not MMIO-readable
necessity — FW can read its own writes): `{PC, AR, DR, PR, STATUS,
HALT_REASON, MD/eng flags, spare}` selected by `SSP_CTRL.page`.

### 6.9 Two-tier watchdog (D-13)
`WDG_RUN` counts while any **transient** hold is asserted (`z_wait_n=0`
by FW/trap-stall, `seq_busy`, engine in-cycle): expiry → release the
transient hold, force `wait/stall` inactive, `err` on the operation,
`run_expiredL=1`, IRQ. Default 2²² clk ≈ **4 ms**.
`WDG_PARK` counts only while the sole park reason is **FW hold**
(`CTRL.bit1` set, `eng_stop_latch`=0): expiry → `console_own←0`,
**`panel_lock←0`**, **`SSP_CTRL.page←0`** (D-23: lamps fall back to
CLASSIC), `z_busreq_n←1` (release **and** demote: FW presumed dead),
`park_deadL=1`, lamp flag, IRQ; re-arm on next FW write after re-kick. Default 2²⁶ ≈ 1.3 s.
Hardware parks (`eng_stop_latch`, e.g. STOP/BP) do **not** arm WDG_PARK:
classic semantics, released by panel RUN or escape (P-B).

---

## 7. Z80 CPU Control Semantics (v0.1 §5 carried; actor = FW or panel engine)

7.1 HALT: park request (FW `CTRL`, panel STOP, escape) → **released to
`BUSRQ_n` only at `insn_end`** (D-25, R15) → park at that instruction's last
`T_Res`; architectural state (`STATUS.at_boundary`=1); exact resume; R
frozen by snapshot discipline. *(Pre-R15 text said "park at M-cycle
`T_Res`" — true of the T80 but unsafe: any M-cycle qualifies.)*
7.2 S/T/X steps: `STEP_CTL` one-shot semantics (v0.1 §5.2 table) — panel
Step pair drives the same register. STEP INSN = release, re-park at the
next `insn_end` (prefix bytes do not count, D-25). MCYCLE/TSTATE steps park
off-boundary by design ⇒ `at_boundary`=0 and `R` prints a "mid-instruction"
warning.
7.2b `[new R15]` **Boundary rules (D-25):** prefixes DD/FD/CB/ED are part
of their instruction (no park between prefix and opcode); HALT state parks
anywhere (PC = HALT+1, matching Z80 behaviour); an INT/NMI acknowledge
sequence completes before park; EI's one-instruction interrupt shadow is
preserved across a step; LDIR-class instructions park per iteration (PC
re-points at the instruction). `insn_end` is produced inside `T80s` by the
D-08 port-out mod, which therefore exports MC/TS/ALT **and `insn_end`**.
7.3 RESET: panel *Reset CPU* / serial `A` → HW-stretched ≥8-`cpu_cen` vent
on `reset_n_internal`; monitor state persists; auto-repark after (examine
context). Panel *Reset System* = `hard_reset_req` path (OSD-equivalent core
wide reset incl. profile-clear; **excludes** FPGA config; exact scope OQ-10).
7.4 Trampoline (`G aaaa`, panel START): arm `TRAMP_ADDR`+`tramp_en`,
reset-vent, inject `C3 lo hi` at the first three fetches from $0000 (mux
select over `cpuDataIn`), auto-disarm; plain `G` = resume (never injects).
BP suppression during injection $0000–$0002 (OQ-05 lean carried: matches
suppressed while injecting).
**[R28 implemented -- `ssp/rtl/ssp_tramp.vhd`, tests `sim/tb_tramp.vhd` (real
T80) + `sim/ssp/p1a_tramp.sh`]** Reset vent: `t80_rst_n = sys_rst_n AND
vent_q`, only the T80 is reset (peripherals/MMU stay on the system reset),
release stretched to >= 8 `cpu_cen` after `CTRL.Z_RST_N` drops. Injector:
primed only if `CTRL.TRAMP_EN` is set *while* the T80 is in reset (a stale arm
can never intercept a normal read of $0000); after release the first three
read cycles at $0000/$0001/$0002 get `C3`/lo/hi via a combinational override
of the CPU data input, then `tramp_done` pulses and the bridge hardware-clears
`TRAMP_EN`. Wait states, refresh cycles and a reset re-asserted mid-window are
handled (the sequence restarts). **FW order for `G aaaa` (full-register
writes, bit 5 kept or the escape is disabled):** `TRAMP_ADDR <- aaaa`;
`CTRL <- {TRAMP_EN, hold, own, esc_break, Z_RST_N}` (arm + vent while parked);
then `CTRL <- {TRAMP_EN, esc_break}` -- reset released, park request dropped
and console returned in ONE write. **Ordering rule:** the park request must
drop no later than the reset release. The T80 does not grant BUSRQ until an
instruction boundary, and its first instruction after reset is the injected
3-cycle JP, so a request still pending at release parks the Z80 *at the
target* (PC = aaaa, nothing executed): a free "set PC and stay parked" mode
(release reset but keep hold/own). Plain `G` (no address) = drop hold/own
only, never injects. Park request = `BUSRQ_n` (see R28 finding).

---

## 8. Breakpoints & Jump History (carried)
§6 regs; semantics exactly v0.1 §6 (latched match PC reported, adjacent
first-match, `C`=skip-once) — halt reasons visible to FW **and** lamps.
**R15 (D-25): stop-*before*-execute by self-loop injection.** BUSRQ cannot
un-fetch an opcode, so on a BP match at the M1 of the target address the
trampoline data mux (§7.4) substitutes `18 FE` (`JR $`) for the opcode and
displacement fetches; the CPU executes a jump to itself and parks at its
`insn_end` ⇒ PC = BP address, flags/registers untouched, R +1 (accepted
drift). Resume (`G`/RUN) suppresses the match once (`BP_SKIP` semantics) so
the real instruction executes. Edge cases to settle in sim (OQ-23): BP on a
prefix byte, BP inside the trampoline window (OQ-05), interrupt accepted at
the injected `JR`'s boundary (pushes PC = BP address — correct).
Jump ring P2 per D-06/OQ-06 (explicit `Ret` in MCode; lean carried).

---

## 9. Memory & I/O Access Model (v0.3 final)

### 9.1 Logical — shared sequencer, Z80 reuse
One engine (§6 `MEM_CTL`) executes mem and I/O cycles **while parked**,
driving the Z80's own nets through the single **`z80_bus_mux`** (D-26,
R15) → MMU translate, BRAM/SDRAM route, SDRAM wait handshake, peripheral
decodes all reused. The engine produces **cycle-faithful Z80 cycles** on
`cpu_cen` — T1–T3 plus wait states, **`MRD_T1` asserted in T1 of memory
reads** exactly as `T80s` does (the SDRAM client FSM starts its speculative
read from it), `M1_n` held inactive (engine cycles are never opcode
fetches) — and it **samples `cpu_wait_n` itself**, since the parked T80 no
longer does. FW `E/D/F/I/O` and the
panel EXAM/DEP/Port-R/W are identical transactions modulo source (G-3).
`MD`=logical. State-neutrality (P-D): engine op cycles *may* touch Z80
I/O (that is the point of port mastering) but never use the MMU
direct-access ports; frame state is read via the `MAP0..3` tap only.
AR auto-increment: engine policy for panel walks (`EXAM+`, `DEP+`); FW
commands update `AR` explicitly (both surfaces leave `AR` coherent, R-15).

### 9.2 Physical (28-bit)
- **P1 — parked client (D-15-P):** `ssp_mem_client` drives the SDRAM client
  interface (`sdram_addr/din/we/rd` + DQM via `addr[0]`) and the BRAM mux,
  gated on: parked ∧ primary-client-idle ∧ no contention. Full R/W reach
  incl. BRAM page 8192. MMU bypassed (physical, by definition) and untouched
  (P-D). `MD`=physical makes `AR` 28-bit for both surfaces.
  **[R35 revision: the BRAM-mux leg is deferred (owner ruling); P1 lands the SDRAM
  physical window only — physical ops to page 8192 rejected `?` by FW; BRAM remains
  reachable logically. BRAM leg joins the later client work.]**
- **P2 — background window (D-15-B):** `ssp_sd` client on the vid port,
  **reads only**; verified arbitration priority (refresh>cpu>vid) keeps the
  Z80 whole; acceptance = sim assertion suite showing vid traffic behaves
  like refresh-collision latency and never breaks primary-path accesses
  (session R3 criterion, R-26). Writes deferred with revisit gate (OQ-11).
- **Milestone note (R9):** P1/P2 clients land *additively* at the existing
  mux points (**Option A**); extraction of a formal arbiter (`sd_arb`) is
  approved future work (**Option B**, after P2 green, off the critical
  path), and single-beat/no-burst protocol plus retirement of any
  block-transfer client (`INIR`/`OTIR` suffices) are owner-set constraints
  — full roadmap `SDRAM_REWORK_PLAN.md` (D-S1…D-S6).

### 9.3 MMU shadow & map view
`MAP0..3` tap → FW shadow {valid, page} ×4 ⇒ logical↔physical translation
available in FW without any port cycles (D-22); `P` command + lamp page
source; map-change IRQ optional (glitch-free sample at parked). MMU *writes*
from monitor FW: `[deferred]` P3 (arbitration at tap, Z80 priority);
**panel-originated** MMU deposit is sanctioned in P2 via D-24 (parked
port-master macro — deliberate operator action, not observation; P-D
unaffected).

---

## 10. Monitor Software (Mecrisp-Quintus dictionary)

10.1 **ODT skin protocol** carried verbatim from v0.1 §10 (prompt `.`,
repeat-last, `$`/`.`/`;`, `?ER nn` atomicity, uppercase responses). `X`
escape (HW; R15: the escape is the `ESC_CHAR` byte, default `^]`, honoured
only while OSD `OM` is On) + `F`/`ODT` skin switch.

10.2 **Command table** (as v0.2 §10.2 with these amendments):
- `PHY` / `LOG` — addressing mode select (`MD`) `[new v0.3]`
- `E/D/I/O` default via `AR/PR` shared registers; explicit-arg forms allowed
- `MB rd[,n]` / `MB wr,dd` — mailbox peek/poke `$D0..$D3` `[new v0.3]`
- `PAGE n` — select lamp state block (`SSP_CTRL.page`) `[new v0.3; renamed
  from `MON n` at R13]`
- `SW[.]` — dump 32-switch bank (bridge mirror); `ENC` — menu counter + last
  committed selection `[new v0.4]`
- `U` unassembler P1 (carried pull-forward); `S?` search P2; `TR` trap P2;
  `H` HBIOS page-table decode P2; `ME/MD` now native via `PHY`+`E/D` (and
  retain `ME p:aaaa` shorthand); `SD` background-block dump P2.
- `ESC [hh]` — show / set the serial escape character (`ESC_CHAR`); also
  reports the OSD `OM` state, since the recognizer is inert while `OM` is
  Off `[new R15]`
`R` format carried (now `Alternate` known from P1 ⇒ prime banks labelled
correctly, `'AF=`… line conditional on bank). **R15:** if
`STATUS.at_boundary`=0 (after an M-cycle/T-state step) `R` prefixes
`*MID-INSN*` — register values are then not architectural (D-25).

10.3 Halt reasons / error codes carried verbatim (+ reason 9=`wdg-park-dead`,
+ error `0B` bridge timeout, `0C` SD-write-unimplemented-until-revisit).

10.4 FW ⇄ panel relationship: FW mirrors engine ops (`ENG_*` + IRQ) for
richer narration (e.g., auto-disassemble panel EXAM target at next REPL);
panel needs nothing from FW (P-B/G-7). Config (baud follow, escape enable,
BP table init, lamp page) is FW-owned, engine-executed.

---

## 11. Front Panel

### 11.1 Hardware inventory (D-03, R7)
**32 address/mode toggle switches S31..S0** (S27..S0 address, low 8 doubling
as DEP data; S31 PHYS mode; S30..S28 reserved) — dual personality: consulted
by the panel engine on command actuation *and* readable by Z80 programs as
sense switches ($FC–$FF, §11.6); **9 SPDT momentary function switches**
(center-off; each lever position = one function, 18 lines — R10 adds
MMU-EXAM/DEPOSIT); **quadrature
encoder with push** (accumulate-and-commit menu selector, §11.3/§11.6);
escape/disable toggle; 256-lamp WS2812 array; SNAC bridge board (74HC165 ×N,
io4 clk-out, io5 data-in; `Hardware/README.md`, OQ-09). Frame: 68 bits
(§11.2); debounced in `fp_capture`, which is the single source of truth for
engine, bridge mirrors, and Z80 ports alike.

### 11.2 Switch & frame map `[decided conceptually, sessions R5/R6/R7; electrical freeze at board design]`

```
frame[31:0]   TOGGLES S0..S31 (Z80-visible sense, §11.6)
  S27..S0   A[27:0]   address (logical mode: A15:0 used) / data byte = S7..S0
  S31       PHYS      1 = physical 28-bit addressing (MD)   0 = logical
  S30..S28  reserved  (future function keys at board freeze)
frame[32]     ESCAPE  monitor disabled (HW force-release, P-B)
frame[35:33]  encA | encB | encPRESS
frame[51:36]  SPDT function lines:
  F1+/F1-   EXAMINE / EXAMINE-NEXT        (lever up / down)
  F2+/F2-   DEPOSIT / DEPOSIT-NEXT
  F3+/F3-   PORT READ / PORT READ-NEXT
  F4+/F4-   PORT WRITE / PORT WRITE-NEXT
  F5+/F5-   LOAD ADDRESS: up = load A-reg (28b phys / 16b logical),
                          down = load P-reg (low 8 switches)
  F6+/F6-   RESET CPU / RESET SYSTEM
  F7+/F7-   RUN / STOP                    (when stopped)
  F8+/F8-   STEP INSTRUCTION / STEP CYCLE (when stopped)
  F9+/F9-   MMU EXAMINE / MMU DEPOSIT   (R10, D-24; see §11.3/UX §4A)
frame[67:54]  spare (future: banked data entry, page-step, extra functions)
encoder       signed ±1/detent menu counter; PRESS commits (§11.3);
              first application: lamp-profile/state-page select (OQ-12: menu
              semantics list remains open; AR-nudge retired from encoder role)
```
Toggle bank values are latched by the panel engine **at command actuation**
(EXAMINE, LOAD ADDRESS, …) and are simultaneously live for Z80 reads —
there is no staleness question since both consult the same debounced source.

### 11.3 Panel engine behaviour (`fp_engine`, hardware)
Load Address: latch switchfield→`AR` (per `MD`) or→`PR`. EXAM: mem[`AR`]→`DR`
(display); EXAM-NEXT: `AR`++ then EXAM (walk). DEP: `DR ← switches[7:0]`;
mem[`AR`]←`DR`; DEP-NEXT: `AR`++ then DEP. Port pairs: same over `PR`/`DR`.
RUN/STOP: release / latch-stop (stop-latch = park source, §6.9). STEP pair:
`STEP_CTL` INSN/MCYCLE one-shots. RESET pair: §7.3 CPU vent / system-reset.
All ops kick the shared engine; `seq_busy` serializes vs FW; panel wins
simultaneity; completion pulses `IRQ.fp_done` + `ENG_LOG`.
**Implementation (D-30, R15):** each operation above is a *macro* — a short
row sequence in the micro-op table (`LOAD_AR, LOAD_PR, MEM_RD, MEM_WR,
IO_RD, IO_WR, INC_AR, STEP, RESET_VENT, INJECT, TAP_RD, PAGE_SET`); e.g.
EXAM-NEXT = `INC_AR, MEM_RD`; START-AT-A = `LOAD tramp, INJECT arm,
RESET_VENT, release`; MMU-DEPOSIT = `IO_WR $B0+n, IO_WR $B4+n`. Macros are
atomic with respect to FW kicks. Errors
(e.g. engine-kick while not parked when required) latch `engine_err`, lamp
flag. Auto-increment policy lives here (human-speed; still hardware).
**Encoder (D-23/R8):** rotation accrues a signed cursor (page menu 0..7,
wrap); PRESS commits — sets `SSP_CTRL.page` immediately (hardware content
swap + chrome page-ID), latches `FP_ENC_STAT.committed`, pulses
`commit_evt`; the cursor is then **held** (persistent index). A second press
within `T_w` (default ≈500 ms `[proposed]`) **zeroes the cursor** without
committing (`dbl_zero_evt`). FW optionally rewrites the profile-7 lamp map
on `commit_evt` for per-page layout (§11.4/G-9); with FW absent, commits
still switch content under the last map — degraded, never stuck.
**Modifiers (D-23):** S28 **BP-ARM** — while on, LOAD-ADDRESS(up) also
installs BP at `A[15:0]`, slot = committed cursor[1:0] (panel-settable
breakpoints — v0.1 §9.5 exclusion retired; panel BP *clear* gesture open,
UX-spec §4/§11). S29 **FREEZE** — latches `SSP_CHAIN` export (chrome still
updates). S30 **START-AT-A** — while armed, RUN(up) executes hardware START:
`TRAMP_ADDR←A[15:0]`, `tramp_en`, stretched reset-vent, park release
(firmware-free, P-B; MD is display context only). Arm state → chrome lamps
M0–M2. **PANEL_LOCK gate (G-8):** while `CTRL.bit9` is set, RUN(up) and
START-AT-A are rejected (HALT-lamp flash, `lock_rejected` event/log);
STOP/EXAM/DEP/PORT/STEP/RESET/FREEZE/LOAD never gated; lock auto-clears on
WDG_PARK expiry, escape, OK-off, MROM mount.
**MMU map switch (D-24/R10):** UP edge = MMU-EXAM: `n ← S1:S0`;
`{valid, page}` read from the `MAP` tap n — no bus cycle, Z80 untouched
(P-D exemplar). Display override *sustains* until the next display-changing
op (any panel op, encoder page commit, FW auto-page): lamps at the
physical **A27..A14** positions ← page[13:0]; L1:L0 ← `n` (which frame is
shown); L12..L2 dark; no valid lamp (op targets a stopped CPU — taps are
static; R10). Re-query on each UP edge; `S1:S0` change while the override
is active re-queries live `[board-adjustable]`. DOWN edge = MMU-DEPOSIT:
page ← `S27..S14` written to entry `n` as a two-out macro through the
existing port-master path (`OUT $B0+n` low byte, `OUT $B4+n` high byte;
valid set implicitly — bit encoding per `MMU.vhd`, verify at landing),
Z80 transiently parked (G-4 budget); no value checking (invalid mapping
behaves Z80-invalid). Both ops FW-free; events mirrored (`FP_FN[17:16]`)
+ `ENG_LOG` so FW prints `*` commentary, and the FW map shadow self-corrects
from the tap.

### 11.4 Lamps — pages own content *and* layout (D-17/D-23, G-6/G-9)

`SSP_CHAIN[63:0]` (bridge output, selected state block)
is appended to the 384-bit capture chain after the existing 24 live bus
bits. **Page = content + layout:** on any page change (FW command
auto-paging, encoder commit, WDG fallback), the **profile-7 `map_ram` is
rewritten** (FW via `LED_ADDR/LED_DATA`; cold default = shipped *identity*
map, which is exactly the CLASSIC layout — zero FW needed for page 0), and
`SSP_CTRL.page` swaps the 64-bit export content. Chrome is invariant across
pages: modifier-arm lamps (S28–S30 arms + MD), status strip (RUN green /
HALT red / MON / CONSOLE_OWN / PANEL_LOCK amber / FW-alive cyan blink /
WDG violet), and 3-bit **page-ID** lamps — per `SSP_PANEL_UX.md` §2/§3
(zones A/M/B/T/D, colour table, page definitions 0–7: CLASSIC, CORE-A/B/C,
MMU, BP, MSG, SYS). FW-dead ⇒ content forced to page 0, map frozen, chrome
intact. Live bus bits remain mappable for authentic bus lamps. No text
rendering (G-6); page/layout/colour tables land in `HARDWARE.md`.

### 11.5 Port-A ownership mux (LED store)
`FP_RAM_Store` Port A select: {FP master controller (Z80 `$A0–$A7` path),
monitor FW route (via `ssp_top` → `LED_ADDR/DATA` bridge regs)}. Z80-Z80
writes win (rare, atomic); monitor writes proceed otherwise. **R15 (D-31):
Z80 writes addressed to profile 7 are dropped in hardware** — profile 7
is SSP-owned by interlock, no longer by convention. Z80 profiles 0–6 are
unaffected.

### 11.6 Z80-visible sense & encoder ports (D-05, R7) `[decided]`

IMSAI-spirit placement at the top of the port space; served entirely by
hardware from `fp_capture`'s debounced state (P-B — correct with the RV in
reset; identical source as the panel engine sees, so no skew between surfaces):

| Port | R | W |
|---|---|---|
| $FF | {S31..S24} — S31 = PHYS mode (bit 7), S30..S28 reserved, S27..S24 = A[27:24] | drives `fpLatch` (existing LED-latch behavior, preserved verbatim) |
| $FE | {S23..S16} = A[23:16] | ignored |
| $FD | {S15..S8} = A[15:8] | ignored |
| $FC | {S7..S0} = A[7:0] / DEP data byte | ignored |
| $FB | encoder menu counter (signed 8-bit, pre-commit preview; same value as bridge `FP_ENC_CNT`) | ignored |
| $F8–$FA | reserved, read 0x00 | ignored |

Decode: 8-port window `addr[7:3] = 11111` (`n_fpSenseCS`), byte select by
`addr[2:0]`; $FF keeps its existing write-side decode for `fpLatch`
(n_fpLatchCS gated to writes; read result fed from sense instead of
`fpLatchDataOut` — safe, §3 fact). Z80 use: panel-state polling from
CP/M/CamelFORTH/HBIOS (switch-driven apps, mailbox pairing via $D0–$D3),
and self-test of the bridge transport. FW reads the same state via bridge
mirrors (§6: `FP_SW/FP_FN/FP_ENC_CNT/FP_ENC_STAT`) rather than port cycles
(state-neutral default); parked `IN` on these ports returns the same values
and is harmless if FW chooses it.

---

## 12. Resource / Timing / Integration

| Item | Estimate |
|---|---|
| VexRiscv IMC + TCM *(shelved R12 — reference figures only)* | ~4–7k ALUT; 16 M10K (64K+64K), shrink knobs = ROM/RAM generics |
| FemtoRV32 gracilis (P0 entrant, §5.8) | ~0.3–0.6k ALUT expected (family scale) — same M10K budget (TCM is ours, not the core's); measure at P0 |
| PicoRV32 + `COMPRESSED_ISA` + MUL/DIV (P0 entrant, §5.8) | ~1.5–2.5k ALUT expected (`[verify]` at P0 `fit.rpt`); same M10K budget |
| `ssp_bridge` + uart + capture + engine | ~3–4k ALUT (engine ≈ +0.5–1k over v0.2 estimate), ~2 M10K |
| `ssp_mem_client` / `ssp_sd` | ~1–1.5k ALUT total |
| Idle/disabled | `OK`-off ⇒ all monitor outputs static-inactive, muxes Z80-side; RV quiescent (`WFI` between ticks; panel ops still serviced by engine — engine runs even when `OK`-off? **No**: `OK`-off disables monitor bus mastering incl. engine (bare-core equivalence, R-19); panel lamps/sense remain (Z80-visible per D-05) |
| Clock domains | all new logic clk_sys; vid client = only new CDC (existing pattern); SNAC/UART async `set_false_path`; chain/encoder false paths as v0.2 |

Integration edit list (delta to v0.2 §12): `MicrocomputerZ80CPM.vhd` gains
**`z80_bus_mux` (D-26, R15) covering A/D/strobes plus `cpu_mrd_t1` (feeds
`sdram_spec_go`) and `n_M1` (capture chain), with `cpu_wait_n` routed to the
engine**, `ssp_mem_client` (BRAM mux + SDRAM-request arbiter point),
profile-7 write interlock (D-31), `$D0–$D3` decode
+ mirror, **`$FB–$FF` sense/encoder decode (`n_fpSenseCS`; $FF read source
swap, write-side `fpLatch` untouched)**, engine mux participation,
`SSP_CHAIN` append at chain input, Port-A ownership mux (§11.5). `MrZ80.sv` gains `MPKG`/`MROM` ioctl routing
(idx 6/7), `CONN_ROUTE` HDMI tap points (P2), monitor-subsystem-reset pulse
on MROM mount-complete, CONF_STR `OK`/`OL` + **`OM` Serial Escape
(bit 22, R15)** + two file entries + profile
override extended value (profile 7 "monitor", OQ-12 detail). `T80s.vhd`
MC/TS + **ALT** + **`insn_end`** (R15/D-25) port-out (P1a), `T80.vhd`
CTEV*/`Ret` (P2). `HARDWARE.md`: mailbox, halt/error codes, switch map,
lamp conventions, console ownership, baud policy, **serial escape
(`OM`/`ESC_CHAR`)**. `REQUIREMENTS.md` item 1: traceability note (done at
this revision). `ssp/rtl`, `ssp/fw` outputs, `Components/RISCV` added to
`.qsf` (R15: `monitor/rtl` rename residue fixed).

---

## 13. Requirements ↔ Verification (v0.3 set)

R-01…R-22 semantics carried (drivers = MMIO tasks / synthetic frames),
with:
- R-08 reworded: mastered cycles incl. frozen-output mux assertions +
  FW⇄panel simultaneity (panel-wins) + FW scripted-kick path.
- R-15 rewritten: **shared-register coherence** — `E 1234` (FW) then panel
  EXAM-NEXT ⇒ AR 1235, and converse (panel LOAD-AR then FW `E` uses it).
- R-19 extended: `OK`-off disables engine bus ops too; $FB–$FF sense/encoder
  ports still live (Z80-visible per D-05).
- R-16 rewritten (R7): Z80 sense ports — $FC..$FF = toggle bank (top byte
  incl. PHYS bit at $FF), $FB = encoder menu counter; $FF write still drives
  `fpLatch`; all correct **with RV held in reset**; byte-order exact per
  §11.6 table.
New:
| Req | Statement | TB |
|---|---|---|
| R-23 | RV boots factory ROM init image; `V` header check | `tb_ssp_smoke` |
| R-24 | WDG_RUN (≤4 ms transient auto-release) / WDG_PARK (FW-hold-only release + console demote) / engine-park unaffected | `tb_bridge_wdg` |
| R-25 | console mux default passthrough with RV in reset (P-B); `CONN_ROUTE` switch-over; fail-safe on `wdg_park` | `tb_ssp_mux` |
| R-26 | vid-port reads benign to primary path (refresh-class latency envelope, zero corruption; Z80 whole during background sweeps) — **P2 gate** (session R3 criterion) | `tb_ssp_sd` |
| R-27 | `ssp_mem_client`: parked R/W vs BRAM page + SDRAM incl. odd-byte DQM; zero access while Z80 runs | `tb_mem_client` |
| R-28 | **panel engine standalone with RV held in reset**: full LOAD-AR/EXAM/DEP/PORT/STEP/RUN/STOP/RESET ritual functional | `tb_fp_engine` |
| R-29 | MROM mount → monitor-only reset (Z80 unaffected) + new image boots; MPKG auto-eval; factory restore on full reconfig | `tb_dl_path` |
| R-30 | mailbox: Z80 write→IRQ+mirror; Z80 read never stalls; FW `MB` roundtrip | `tb_mbx` |
| R-31 | FW translation shadow == live MMU maps across Z80 remaps (`MAP0..3` tap) | `tb_map_shadow` |
| R-32 | Encoder (D-23): cursor previews at $FB; press commits page (page-ID + `committed` latch) and cursor is **held**; rapid double-press (≤`T_w`) zeroes cursor without commit | `tb_fp_engine` |
| R-33 | PANEL_LOCK: gates panel RUN/START only; STOP/EXAM/DEP/PORT/STEP/RESET unaffected; auto-clear on WDG_PARK expiry/escape/OK-off/MROM mount; rejected attempt flashes + logs | `tb_bridge_lock` |
| R-34 | Per-page lamp remap: page change ⇒ profile-7 map rewritten + content swapped; cold default identity == CLASSIC layout; WDG-dead forces page-0 content, chrome intact | `tb_fp_led` |
| R-35 | Modifiers: BP-ARM LOAD also sets BP (cursor-slot); FREEZE latches export, chrome live; START-AT-A = trampoline+reset-vent+release, firmware-free | `tb_fp_engine` |
| R-36 | FW auto-paging per UX §3 table + `*` commentary (immediate idle / queued busy) golden script | `tb_fw_panel` |
| R-37 | MMU-EXAM: correct tap field per entry `n=S1:S0`; page→A27..A14 lamp routing, `n`→L1:L0, rest dark; persist-until-next-op; re-query on UP edge + live on S1:S0 change; zero MMU write strobes (state-neutral) | `tb_fp_engine` |
| R-38 | MMU-DEPOSIT: two-out macro `$B0+n`/`$B4+n`, executed only with Z80 parked; valid set implicitly, no value checking; FW map shadow matches taps after deposit | `tb_fp_engine` + `tb_fw_panel` |
| R-39 | MMU ops full-function with FW held in reset (engine-only: tap exam + deposit) | `tb_fw_panel` |
| R-40 | `[R15]` **Boundary parking** (D-25): every STOP/escape/STEP-INSN park lands on `insn_end` (`at_boundary`=1) across a directed instruction mix incl. DD/FD/CB/ED prefixes, DDCB-indexed bit ops, LDIR/OTIR, HALT, EI+INT shadow, IM2 acknowledge; snapshot PC == next instruction | `tb_integ_park` (integration level) |
| R-41 | `[R15]` **BP self-loop injection** (D-25/OQ-23): stop-before-execute ⇒ PC = BP addr, AF/regs unchanged, R +1 only; resume executes the real instruction once | `tb_integ_bp` |
| R-42 | `[R15]` **Bus mux fidelity** (D-26): engine reads/writes to SDRAM, BRAM and I/O produce the same `MRD_T1`/strobe/wait waveforms as T80 cycles (golden compare); engine honours MMU + SDRAM waits; mux select never flips without `BusAck` | `tb_integ_mux` + `tb_cycle_golden` + `p1a_engine_golden.sh` **[done R31]** + `tb_integ_core` **[done R33]** |
| R-43 | `[R15]` **Serial escape** (D-14 rev): `OM` Off ⇒ every byte incl. `ESC_CHAR` reaches the Z80 bit-transparently, no park; `OM` On ⇒ `ESC_CHAR` parks at boundary, console handed over, byte not delivered to Z80; other bytes pass; `ESC_CHAR` reprogrammable; FW disable honoured | `tb_ssp_esc` |
| R-44 | `[R15]` Profile-7 interlock (D-31): Z80 writes to profile 7 dropped, profiles 0–6 unaffected; SSP writes land | `tb_fp_led` |
| R-45 | `[R15]` Register-map consistency (D-29): generated `.vh`/`.fs`/Markdown match the CSV; build fails on drift | `make regmap-check` |
| R-46 | `[R15]` Polled FW (D-27): full P1a command set operates with the core's IRQ input tied off | `tb_ssp_smoke` |
R-21 unchanged and doubly load-bearing.

---

## 14. Open Questions

Closed this session: OQ-01 (ALT export P1) · OQ-02 (S31 + 28-bit map) ·
OQ-03 (no boot-ROM mux; MROM-reset settled D-16) · OQ-04 (context-loss
accepted, P3 write-back) · OQ-07 (bit 14 taken → OK=20) · OQ-08 (new map
redesigned; board freeze later) · OQ-14 ($D0 allocated) · OQ-16 (IMC/timer/
dispatch) · baud/flow/HDMI-direction settled (D-22/R4) · **OQ-12 + OQ-16b
(panel-UX deep-dive R8 → D-23 + `SSP_PANEL_UX.md`; residual values →
OQ-18)**.

| # | Question | Lean / notes |
|---|---|---|
| OQ-05 | BP at $0000–$0002 vs trampoline injection | Carried lean: suppressed during injection window |
| OQ-06 | `Ret` classification source for CTEV | Carried lean: explicit `Ret` in MCode |
| OQ-09 | Bridge board un-built: electrical freeze incl. SPDT parts, encoder, spare banks; sim now with synthetic frames (R-13) + SPDT pair encoding assumptions | P2 dependency, not P1 — **R15: longest-lead item; start board design in parallel with P1a/P1b** so the UX second pass isn't blocked |
| OQ-10 | **Exact "Reset System" scope** — proposed: `hard_reset_req`-equivalent (Z80 + monitor + FP profile clear; not FPGA config). Confirm at board design. | needs owner confirmation |
| OQ-11 | vid-port **writes** revisit gate (D-15-B): after R-26 passes with reads; scope = `sdram2.sv` DQM mod; alternative = physical writes stay parked-only forever | revisit P3+ |
| OQ-18 | Board-freeze UX values (residual from R8): double-press window `T_w`; page-ID lamp encoding (binary vs one-hot); lock-reject flash pattern; **panel BP-clear gesture** (armed LOAD-down? serial-only v1?); debounce/heartbeat constants; LED physical zones vs switch geometry; S28–S30 silkscreen labels; spare bank (frame bits 54–67) future use; **MMU-switch (D-24) silkscreen labels + 9th-SPDT mounting; live-re-query-on-`S1:S0` policy; deposit valid-bit encoding check vs `MMU.vhd`** | board design time; `SSP_PANEL_UX.md` §11 checklist |
| OQ-19 | Milestone-B scheduling: formal `sd_arb` extraction approved (R9) but unscheduled — proposal: dedicated refactor milestone after P2 green, before P3 polish work; confirm at P3 planning | `SDRAM_REWORK_PLAN.md` §6/§10 |
| OQ-20 | **CLOSED — resolved R23 (owner ruling, D-37): FemtoRV32-gracilis selected.** Full record: ~~license check~~ closed — ISC/BSD-3; ~~`fit.rpt` ×2~~ done R21 §5.8; ~~time-to-REPL~~ done R19/R20; ~~cycle-level performance~~ done R22 §5.8.2 (gracilis wins every op); residual trust/pedigree weighted by owner toward Mecrisp-co-design lineage. picorv32 retained as documented fallback (D-37) | was: P0 critical path — now resolved; feeds P1 (`ssp_top` instantiates gracilis per D-34/D-37) |
| OQ-21 | **VexRiscv reopen conditions** (shelved R12): reopen the §5.7 container path only on (a) measured FW cycle-budget shortfall in P1/P2 (dump/disassemble/REPL responsiveness vs §4.3-class arithmetic), or (b) a new capability need not met by the family (`individua` covers atomics; nothing else on the horizon). Record measured numbers with any reopen request | dormant until drivers |
| OQ-13 | Dictionary persistence across monitor resets beyond re-mount (NVRAM region in SDRAM?) | deferred; packs re-mount deemed sufficient v1. R15: flash emulation explicitly **not** pursued (D-32) |
| OQ-22 | `[new R15]` **Escape-byte consumption mechanism** (D-14): when the Z80 owns the SNAC link and `OM` is On, the escape byte must not reach the Z80 ACIA, but recognition completes only at the stop bit. Options: (a) byte-level relay (deserialize → filter → re-serialize at the `O9B` rate; adds one character time of latency, only while `OM` On; RTS/CTS passed through), (b) let the byte through and accept the Z80 sees it, (c) inject into the ACIA receive path instead of the wire | **CLOSED `[R24/R25, documented R30]`: option (a), byte-level relay**, implemented in `ssp/rtl/ssp_uart.v` (deserialize -> ESC filter -> re-serialize, 2-deep queue + inter-byte stretch); raw-vs-relay Z80-RX mux switches at `ssp_top` (raw when `OM` Off = bit-transparent R-43, relay when On; mutually exclusive, no byte duplication). Cost: one character time of latency, only while `OM` is On |
| OQ-23 | `[new R15]` **BP self-loop injection** (D-25): confirm in integration sim — BP on a prefix byte (inject at the prefix M1; does T80 prefix state reset cleanly?), interaction with trampoline window (OQ-05), interrupt taken at the injected `JR`'s boundary, `BP_SKIP` resume path | P1a/P2 sim (R-41); fallback = stop-after with corrected PC report |
| OQ-24 | `[new R35]` **Physical-access command surface** (owner first-light requirements, D-15-P/D-22): canonical is modal (`PHY`/`LOG` set `MD`, then `E`/`D` act logical-or-physical per mode); also add explicit physical verbs (e.g. `PE`/`PD`, `I a`, `O a d`, `MAP`)? Letters to be confirmed with the P1b FW ODT-skin pass | owner letter ruling; R35 next-phase note |
| OQ-15 | Graphical frame buffer for monitor *video* output (vs 80×25 ANSI on SBC terminal), including exclusive HDMI+kbd console details (D-19 P3): font, pages, keymap | later-phase design note |
| OQ-16b | *(closed by R8 →* `SSP_PANEL_UX.md` v0.1*)* deep-dive held 2026-10-23: sovereignty/lock, pages, lamps, encoder, commentary, walkthroughs; second pass after first FP hardware experience | closed |
| OQ-17 | Doc naming: CamelFORTH (Z80) vs Mecrisp (monitor) glossaries in `doc/` — two files naming | lean: `MONITOR-FORTH-GLOSSARY.md` new beside existing |

---

## 15. Phasing (ratified session R6)

| Phase | Scope | Exit |
|---|---|---|
| **P0 — two-core bake-off (R14)** | Vendored `picorv32.v` (`COMPRESSED_ISA`) **and** `femtorv32_gracilis.v` (+`utils.v`); Quartus 17.0 synth on `5CSEBA6U23I7` for **both**; **Mecrisp REPL live in sim and on the stub SoC** (UART console, per core); toolchain package verified (`riscv64-unknown-elf`, `-print-multi-lib`, `-march=rv32imc_zicsr_zifencei -mabi=ilp32`); downloadable-ROM write path sim; `fit.rpt` headroom recorded ×2; crt0 convention verified; §5.8 verify items closed (bridge `TICK_US` timer — common to both; ~~IRQ glue smoke~~ moot under polled FW, D-27; ~~learn-fpga license~~ closed). **R15 additions:** **simulation infrastructure** (D-28: `sim/ssp` Verilator + GHDL integration benches `sim/run_ssp_*.sh`, Makefile) — Mecrisp REPL in Verilator per core; **register-map generator** (D-29: CSV → `.vh`/`.fs`/Markdown, `make regmap-check`); Mecrisp RAM-only build confirmed (D-32: `compiletoram`, flash primitives stubbed). Optional: riscv-formal on picorv32 (eqy container, off critical path). **VexRiscv/vexgen shelved** (§5.7; reopen = OQ-21) | clean synth ×2; headroom logged; REPL live on harness; **one core selected per §5.8 table — DONE R23: FemtoRV32-gracilis (D-37, OQ-20 closed)**; sim flows + regmap generator runnable; no day-to-day container dependency |
| **P1a — "first light"** `[new R15]` | Minimum vertical slice that exercises the riskiest RTL on real hardware: bridge `ID/CTRL/STATUS/TICK_US/ESC_CHAR/IRQ_PENDING/MEM_CTL/MEM_ADDR/MEM_DATA/SNAP_REG`, **`insn_end` export + boundary parking** (D-25), **`z80_bus_mux` + cycle-faithful engine (logical mem + I/O)** (D-26), micro-op sequencer core (D-30, FW kicks only), `ssp_uart` + **OSD `OM` escape recognizer** (D-14, OQ-22 resolved), SNAC console mux; FW (polled, D-27): `E D G H R X` + `ESC` **[R27: FW command set per D-39 (examine, modify-with-prompt, `G aaaa`, bare `G` continue); the trampoline moves here from P1b]** | R-40, R-42, R-43, R-45, R-46, R-23, R-25 + the R-01…R-09 subset covering halt/examine/deposit/go green; **on hardware**: escape into the SSP, examine/deposit Z80 memory, resume — with `OM` Off proven bit-transparent **[CLOSED R35: all exit items PASS on hardware, 2026-10-27]** |
| **P1b — console complete** | Remaining P1 scope: `MD/AR/DR/PR` shared regs, `MAP0..3`, `MBX`, WDG×2, STEP assist (INSN/MCYCLE/TSTATE), reset stretcher, trampoline / `G aaaa`, **`ssp_mem_client`** (physical P/W), MROM/MPKG mount path (monitor-only reset), T80s MC/TS/ALT export completion; FW: ODT skin + `S T K I O A W V ? U F ODT PHY LOG MB` | rest of R-01…R-09, R-12, R-19…R-22, R-24, R-27, R-29…R-31 green in sim; real-terminal bring-up (halt/dump/examine/step/G) incl. no-Z80-image boot; panel *not* yet wired. **Bridge board (OQ-09) designed in parallel with P1a/P1b** |
| **P2 — panel + assist** | `fp_capture`+`fp_engine` (+engine priority/log), new switch map live, Z80 sense/encoder port decode (§11.6, R-16/R-32), **D-23 UX package: BP-ARM/FREEZE/START-AT-A, PANEL_LOCK, per-page profile-7 lamp remap + chrome + page-ID (`SSP_PANEL_UX.md`), encoder hold/double-zero, `*` commentary**, **MMU map switch ops (D-24: tap-exam display + parked deposit macro, R-37…R-39)**, panel macros on the D-30 sequencer, profile-7 interlock (D-31, R-44), BP/`C` with **self-loop stop-before-execute** (D-25, R-41/OQ-23) (with panel BP-set), CTEV ring + `J`, traps, `S?/TR/H/P/SD`, `ssp_sd` READ (R-26 gate), MPKG auto-eval polish, HDMI mirror (`CONN_ROUTE`), serial XModem | R-10…R-18, R-26, R-28 green; **RESET/DEP/START ritual from switches alone, RV held in reset**; panel-op mirror visible in FW |
| **P3 — polish** | T80 register write-back (retires trampoline), step-over, conditional BPs, `Y`, MMU writes from monitor, exclusive HDMI+kbd console (D-19), vid-write revisit (OQ-11), HPS path eval, mailbox protocol hardening with HBIOS | D-02 retired; all prior green |

> **SDRAM arbiter milestone (R9):** P1/P2 use additive borrowed-wiring
> clients (Option A) exactly as scoped above; formal `sd_arb` extraction
> (Option B) is approved future work scheduled after P2 green, outside the
> monitor critical path; no bursts, no block-transfer engine, loader
> streaming deferred — `SDRAM_REWORK_PLAN.md`.

---

## 16. Resume Checklist

1. `doc/t80_reg_debug_vector.md` (register/snapshot semantics) then this doc.
2. §17 decision log = authoritative deltas from v0.2; `SSP_RISCV_REVIEW.md`
   §2 for the fact corrections (freeze-not-tri-state, bit-14, 28-bit,
   cpu>vid arbitration, MMU auto-increment hazard).
3. Owner confirmations outstanding: OQ-10 (Reset-System scope), OQ-18
   (board-freeze UX values incl. panel BP-clear gesture), OQ-11/13/15
   (deferrals acknowledged); panel-UX second pass after first hardware.
   R15 opened OQ-22 (escape-byte consumption, lean relay) and OQ-23 (BP
   self-loop injection edge cases) — both settled in sim, not by owner.
4. P0 spike first, absolutely — **two-core bake-off: PicoRV32
   (`COMPRESSED_ISA`) vs FemtoRV32-gracilis** (R14, §5.8 criteria table):
   vendored files + packaged `riscv64-unknown-elf` GNU toolchain
   (`-march=rv32imc_zicsr_zifencei -mabi=ilp32`); optional riscv-formal
   tie-breaker via one-shot eqy container. VexRiscv/vexgen shelved (§5.7,
   reopen conditions OQ-21). Cores vendored (`Components/RISCV/`,
   2026-10-26). **R15: P0 also delivers the two simulation flows (D-28) and
   the register-map generator (D-29)** — everything after depends on them.
5. RTL order (R15): `insn_end` export in `T80s` + boundary-park logic
   (D-25, integration sim) → `z80_bus_mux` + cycle-faithful engine (D-26)
   → bridge P1a regs + sequencer (D-30) against the BFM → UART + escape
   recognizer (D-14) → **P1a hardware first light** → P1b
   (`ssp_mem_client`, mount path, WDGs, trampoline) → `fp_engine` macros
   standalone (R-28) → FW. Mux hookup only after `tb_bridge_*` green with
   gates stubbed transparent (R-21 discipline).
6. Update `HARDWARE.md` incrementally with each landed surface; keep
   `REQUIREMENTS.md` item 1 note current.

---

## 17. Decision Session Log (2026-10-22 → 2026-10-26)

R1 **Foundation**: VexRiscv primary P0-gated (PicoRV fallback) · RV32IMC +
µs timer + pending-reg dispatch · 64K/64K · downloadable ROM (no refit) +
`MPKG` FORTH pack; factory init-from-hex; lifecycle = code-is-data.
R2 **Principles/safety**: P-A..P-C formal (owner: keep formal set small) ·
two-tier stall budget ("few ms to change memory; lax park timing") → D-13
redesign · D-02 accepted, write-back P3 · MROM mount resets monitor only.
R3 **Memory**: MMU direct-access path **retracted** (guest-owned
auto-increment) → `ssp_mem_client` borrows wiring (P-D exemplar) · vid port
reads-only in v2, writes revisit later, acceptance = benign-as-refresh
sim proof · `Alternate` exported with MC/TS in P1 (OQ-01 closed) · modal
logical/physical addressing both surfaces (owner).
R4 **Console**: D-01/D-14 ratified · monitor baud follows `O9B` · no monitor
RTS/CTS · HDMI: P2 mirror, later exclusive HDMI+kbd console by OSD/serial
choice; routing = FW policy over HW muxes (D-19).
R5 **Panel/guest surface**: $D0–$D3 allocated · new switch map
(28×address, S31=PHYS, low 8 = data; monitor tracks MMU via tap for
translation) · lamps = flexible lamp array, monitor state exported to chain,
profile-7 convention, no text correspondence; graphical video FB idea parked.
R6 **Wrap**: hybrid SPDT IMSAI-style panel switch set, **operations executed
in hardware** (owner preference; FW simple + independent) → D-18 panel
engine + shared functional registers (G-3) · "state-neutral observation"
promoted to formal **P-D** · phasing ratified · full doc update set.

R7 **Follow-up (owner note, same day)**: 32-toggle bank (S31..S0) confirmed
as **dual-personality** — panel-engine input consulted at command actuation,
*and* guest-readable **sense switches** placed IMSAI-style at top of port
space: $FF = {S31..S24} (PHYS bit at bit 7), $FE/$FD/$FC down to the low
data byte; $FF write keeps the `fpLatch` LED-latch behavior; $FF read
repurposed from `fpLatchDataOut` (read-safe — verified no guest readers).
Rotary encoder = **accumulate-and-commit** menu selector: rotation accrues a
signed value, effective only on knob press; pre-commit value readable by the
guest at **$FB** and by FW at `FP_ENC_CNT`; first commit application = lamp
profile/state-page. FW reads the same state via dedicated bridge mirrors
(`FP_SW/FP_FN/FP_ENC_CNT/FP_ENC_STAT`) — one debounced source serves panel
engine, guest ports, and FW with no skew (D-03/D-05 revised; §11.6 new;
R-16 rewritten, R-32 added; OQ-12 narrowed to menu semantics + commit-clear
policy).

R8 **Panel-UX deep-dive (2026-10-23; spec → `SSP_PANEL_UX.md` v0.1)**:
sovereignty ladder adopted **with FW-held PANEL_LOCK** (owner choice over
unconditional sovereignty) — escape/OK-off absolute, lock gates RUN/START
only, auto-clears on WDG-PARK/escape/mount → **G-8** · S28=BP-ARM (panel
breakpoints via LOAD-ADDR + encoder cursor slot), S29=FREEZE, S30=START-AT-A
(firmware-free hardware trampoline start — closes the D-07 panel gap left by
the R6 switch-set) · lamp architecture: **per-page remap** chosen over
static-map/paged-content → **G-9** (page owns content+layout; pinned chrome
zones; page-ID lamps; cold identity default ⇒ CLASSIC free; WDG-dead falls
back to page 0) · encoder: cursor **held** after commit, rapid double-press
zeroes without commit (owner variant) · hybrid immediate/queue `*`
commentary ratified · colour conventions · FW auto-paging table ·
failure-posture matrix + 5 acceptance walkthroughs → R-33…R-36; residual
ergonomics values → OQ-18 (board freeze).

R9 **SDRAM subsystem rework decisions (2026-10-23; record →
`SDRAM_REWORK_PLAN.md` v0.1)**: rework driver is *architecture* (multi-client
sharing), not reliability or speed (+0.7% penalty; cache stays shelved —
RomWBW lever is hot banks in BRAM page 8192) · staged **A-then-B** adopted:
additive borrowed-wiring clients for P1/P2 now, formal `sd_arb` extraction
as a dedicated post-P2 milestone (owner: "splitting out the arbiter seems
like a useful effort") → OQ-19 · **block-transfer engine retired** —
initial implementation uses MMU direct-access I/O port + `INIR`/`OTIR`
(ordinary CPU-class traffic; reopen only on measured inadequacy) ·
**loader streaming deferred** (8 MB mount feels adequate; low priority) ·
**no burst transfers** (no appetite/demand justifying complexity+risk;
single-beat protocol, `BURST_LENGTH`=2 stays) · facts logged: vid-write
(OQ-11) unchanged, `SDRAM_CLK_100` fallback currently live at
`MrZ80.sv:502` (both clk_ram taps are standing regression targets).

R10 **MMU map switch (2026-10-23; UX spec §4A v0.2)**: 9th SPDT,
center-off **momentary** (owner clarification: "two electrical switches",
same part family as F1–F8; frame bits 52/53, spare bank now 54–67) · UP =
MMU-EXAM: `MAP`-tap read of entry `n=S1:S0` (no port cycle), sustained
lamp display at the **physical A27..A14 placements**, frame number echoed in
L1:L0, remaining low lamps dark; re-query per throw + live on `S1:S0` move ·
DOWN = MMU-DEPOSIT: `S27..S14` → entry `n` page via parked two-port macro
(`$B0+n`/`$B4+n`), **implicit validity** — owner: no panel hand-holding,
bogus values fail exactly like guest-set ones · valid-dot display **rejected**
(op is inherently a stopped-CPU operation; lights static) · fully engine-only
capable both directions; FW `FP_FN[17:16]` events, `*` commentary, shadow
self-corrects via tap → **D-24**, R-37…R-39, P2 scope.

R11 **FemtoRV32 investigation note (2026-10-26, owner-initiated)**: open
the candidate field for the debugger CPU to a third core — **FemtoRV**
(Bruno Levy's *learn-fpga* processor collection;
`github.com/BrunoLevy/learn-fpga/.../RTL/PROCESSOR`, background at
`deepwiki.com/BrunoLevy/learn-fpga/3-femtorv32-processor-design`) ·
pure-Verilog family, **no build/generation system** (same zero-toolchain
class as PicoRV32) · first-party Mecrisp lineage: family co-developed with
Mecrisp's author and shipped inside the Mecrisp-Quintus distribution
(board designs hx1k/ulx3s/icebreaker-femtorv32/vega) · variant spread
recorded in new **§5.8** (quark → petitbateau); **gracilis**
(RV32IMC + IRQ) = our exact ISA requirement, compressed encoding
explicitly banked against *future memory-footprint concerns* (owner) ·
custom-CSR IRQ model matches R1's pending-register dispatch choice ·
timer/CSR, IRQ semantics, licensing and Quartus-17 fit flagged as
spike-verify items · added to P0-exit three-way pick as **OQ-20**
(side-spike cost ≈ nil); D-09 unchanged until P0 data.

R12 **P0 refocus onto gracilis; VexRiscv shelved (2026-10-26)**: owner
call — no significant performance driver justifies VexRiscv's complex dev
process now → P0 executes on **FemtoRV32-gracilis**; the §5.7 vexgen
container work is **shelved** (spec retained verbatim as ready-to-run
guidance, nothing installed/scheduled) → reopen only via **OQ-21**
*measured* drivers (FW cycle-budget shortfall in P1/P2, or a capability
need beyond what `individua`/family covers); PicoRV32 stays baseline
fallback · **toolchain decision**: packaged GNU
`riscv64-unknown-elf-*` (distro packages; riscv-collab tarball fallback) —
owner's research confirmed and recorded: an **RV64 toolchain emits RV32IMC
correctly** via `-march=rv32imc_zicsr_zifencei -mabi=ilp32` (standard
LiteX/FemtoRV practice); caveats noted: Zicsr/Zifencei suffix mandatory on
binutils ≥2.38 for CSR glue, multilib nice-to-have but freestanding Mecrisp
needs ~no libs, bare-metal triplet only · D-09 rewritten; P0 row re-scoped;
module table reflects shelved VexRiscv + vendored gracilis rows.

R13 **Rebrand: ODT → SSP (2026-10-26)**: owner call — "naming is hard",
and the Intel-derived **ODT** label no longer fits a subsystem that is
console + panel engine + watchdog + loader + memory service + debugger host
· adopted name: **SSP — System Support Processor** (accurate, general,
industry-pattern: service/support processors, BMCs); considered-and-filed
alternatives: SPAR (Support Processor for debug And Recovery — SP+AR pun),
SERF, FORTHLY, TERTIUS (Mecrisp naming-lineage play), PORTAGE, WARDEN,
PECKER, PIER · **full rename executed now** (cheap pre-RTL): doc files →
`SSP_DESIGN.md`/`SSP_PANEL_UX.md`/`SSP_RISCV_REVIEW.md`; planned
identifiers `mon_*`→`ssp_*`, `dbg_bridge`→`ssp_bridge`,
`MON_CTRL/MON_CHAIN`→`SSP_CTRL/SSP_CHAIN`, `monitor/`→`ssp/`, FW word
`MON n`→`PAGE n`; canonical rename map recorded in "Naming" section after
§0-header · **carve-outs**: "ODT-style" kept for the Intel heritage idiom,
FW compatibility-skin word `ODT` kept (it emulates Intel's monitor),
`archive/ODT_CHANGE.md` keeps its historical name · design doc version
lineage reset: **v1.0-draft** (was v0.1–v0.9 under the old name; logs
R1–R12 unchanged).

R14 **PicoRV32 elevated to co-candidate — P0 two-core bake-off
(2026-10-26, owner-forwarded external research)**: advice recommended
PicoRV32 over gracilis (riscv-formal pedigree, simple valid/ready memory
interface, documented custom IRQs, PicoSoC ecosystem, ISC; "slow is fine
for a support processor"; area irrelevant on Cyclone V) · assessed against
our specifics: pedigree argument *endorsed* (decisive weight for the debug
host; riscv-formal run feasible off-critical-path in a one-shot eqy
container); corrections recorded: picorv32 **has RV32C**
(`COMPRESSED_ISA`) ⇒ gracilis footprint edge neutralized; **no `mtime` on
either** ⇒ bridge-MMIO tick is common design; atomics missing on *both*;
gracilis not unverified (ships running Mecrisp-Quintus on official board
targets; PicoRV32-lineage custom-IRQ encodings ⇒ FW glue near-portable,
decision reversible late) · its "design considerations" (private RAM,
WAIT/reset control, explicit CDC, HPS/SSP split) confirmed already
architected (D-10, `CTRL` + verified T80-FREEZE nuance, level+toggle CDC,
D-19/P3) — external corroboration · **D-09 rewritten**: P0 = bake-off on
the §5.8 criteria table (trust weighted highest; working lean picorv32+C
if riscv-formal executes); OQ-20 restated; P0 row, module table, resume
checklist, §5.6 realigned; VexRiscv remains shelved (OQ-21).

R15 **Design review — front panel + serial debugger readiness
(2026-10-26)**: owner-requested review of spec/design/plan against the
code; owner accepted all recommendations, with directions on escape and
memory model.
· **Findings verified in source:** T80 grants BUSRQ at *any* M-cycle
`T_Res` (`T80.vhd:~1033-1042`) ⇒ raw parks can land mid-instruction; SDRAM
speculative read keyed off T80 `MRD_T1` (`MicrocomputerZ80CPM.vhd:~1090`),
`n_M1` in capture chain (`:~764`), waits merged in `cpu_wait_n` (`:~472`);
**R14 IRQ claim false** — gracilis standard CSRs/`mret`, picorv32 custom
`getq/setq/retirq/maskirq/waitirq/timer`; Mecrisp-Quintus's first target
was PicoSoC (picorv32) · **New decisions:** D-25 instruction-boundary
parking (`insn_end` export in the D-08 mod; prefix/HALT/INT/EI/LDIR rules;
`STATUS.at_boundary`; BP stop-before-execute by `JR $` self-loop
injection), D-26 single `z80_bus_mux` incl. `MRD_T1`/`M1_n` synthesis and
`cpu_wait_n` sensing with cycle-faithful engine cycles, D-27 polled v1 FW
over sticky W1C status (cores FW-interchangeable; only `crt0.S` differs),
D-28 two-level simulation (Verilator SSP-only + Questa-Intel/GHDL
integration, `sim/` Makefile, P0 deliverable), D-29 single-source register
map (CSV → `.vh`/`.fs`/Markdown), D-30 panel engine as micro-op sequencer
with per-macro arbitration, D-31 profile-7 hardware interlock, D-32
RAM-only Forth · **Revised:** D-14 — owner direction: **only a specific
escape character** enters the monitor, and recognition is **conditional on
an OSD switch** so transparent serial I/O remains possible ⇒ `OM` (status
bit 22) "Serial Escape" Off/On default Off, `ESC_CHAR` default `0x1D`
(`^]`), byte consumed (mechanism OQ-22, lean byte relay), effective enable
`OM ∧ esc_break_en ∧ ssp_active`; D-10/D-32 — owner direction: **no flash
emulation**; Forth is built RAM-only on the OSD-loaded image (offered
RV-writable upper-ROM `compiletoflash` region declined); D-09/D-11/D-16/
D-20 wording (IRQ correction, core-neutral SSP local bus, `OM`
allocation, `TICK_US` time base) · **Plan:** P1 split into **P1a "first
light"** (boundary park + bus mux + escape + `E D G H R X` on hardware) and
**P1b** (rest of console); P0 gains sim flows + regmap generator; bridge
board (OQ-09) to be designed in parallel with P1 · §6 gains `ESC_CHAR`
(0x110), `TICK_US` (0x114), `STATUS.at_boundary/osd_esc_en`, `esc`/`mbx`
event bits; §13 gains R-40…R-46; §14 gains OQ-22/OQ-23 · **Doc hygiene:**
§4.1 diagram core-neutral; "SimpleBus" retired (VexRiscv-only); §5.1 stale
fallback text; §5.6→5.7→5.8 order restored; `monitor/rtl` and `tb_mon_*`
rename residue; `ssp_uart` row mis-cited D-22; §3 `clk_ram` corrected to
100 MHz live; R11/R14 IRQ text kept with explicit errata markers (log
history preserved, not rewritten).

R16 **P0 kickoff — toolchain in, sim baseline green, seam + map decisions
(2026-10-26)**: owner "proceed as recommended" + pointer to new local
repo `~/mecrisp-quintus`.
· **Toolset installed** (approved): gcc-riscv64-unknown-elf 15.3.0
(binutils 2.47), verilator 5.048, iverilog 13.0, yosys 0.66, gtkwave
3.3.127. Smoke test passed: `-march=rv32imc_zicsr_zifencei
-mabi=ilp32 -nostdlib` → RVC ELF, `csrr mcycle` OK. Gotchas: distro
default ldscript = picolibc flash/ram (`-nostdlib` alone still uses it)
⇒ **P0 ships its own linker script** for the §5.2 map; `rv32imc` links
the `rv32imac` multilib (harmless, freestanding).
· **H-1 closed** (commit `8b9f192`): top-level sim copy resynced
(capture-chain + control-signal era); canonical redirect **pair** restored
(`numeric_std.all` + `sim_compat_pkg.all` — the real top has no
`numeric_std` of its own). Green baseline re-verified: `check_sync` ×3,
`tb_cpuregs` 8/8, `tb_frontpanel` PASS (292-bit chain simulates),
`tb_inir_race` known-good partial per `sim/STATUS.md`.
· **D-33 language seam**: Z80-side units VHDL (GHDL-testable against real
T80/MMU/SDRAM FSM), RV-side Verilog; seam crossed at `ssp_top`
(Quartus mixes; each sim level stubs the far side). Module table
suffixes updated.
· **D-34**: gracilis `ADDR_WIDTH=30` at instantiation (default 24 aliases
the §5.2 map); map unchanged.
· **H-3 closed**: Mecrisp-Quintus **1.1.2a** in-tree at
`~/mecrisp-quintus` (GPL-3.0+ = compliance vehicle for the factory hex).
Assets noted in §5.5: per-target `.s`+`memmap`+Makefile pattern (mirrors
into `ssp/fw/`), `common-verilog/` (gracilis copy = whitespace-only diff
vs vendored; `uart.v`, `MappedSPIFlash.v`, `celement.v`), `release/`
host emulators (`quintusemu-*`), `common/` RV32IMC disassembler/
assembler tools, `linux-rv32imc/` native runtime.
· **H-7**: D-28 amended — GHDL is the integration simulator (Questa
dropped); integration benches follow the `sim/run_*.sh` pattern.
· **H-8**: `STATUS.rv_trap` added (picorv32 `trap` ⇒ "FW crashed" bit).
· **H-5/H-6**: §3 chain fact corrected to 292/384 with `SIGNAL-CAPTURES.md`
as authority; SSP export allocated 292–355 (map entry lands with P2 chain
edit).
· **Next**: register-map generator (D-29) → stub SoC per core (`sim/ssp/`,
Verilator) → Mecrisp REPL bring-up using the in-tree distribution.

R17 **Minimal flash-free Mecrisp port built and REPL-verified in sim
(2026-10-26)**: owner "proceed to the next step" + two rulings — generate a
**very minimal Mecrisp configuration with no flash memory and no
MappedSPIFlash device** (hardware-side restatement/extension of D-32: nothing
SPI-flash lives anywhere in the SSP), and Mecrisp stays **its own repository,
referenced not vendored** (build consumes `$MECRISP` in place; only target
files in-tree).
· **Regmap**: UART block added to the canonical CSV — `UART_TXDATA` 0x120,
`UART_RXDATA` 0x124, `UART_STAT` 0x128 (tx_ready/rx_avail/sticky
rx_overrun), `UART_CTRL` 0x12C (en, self-clearing flushes); map now **72 regs
/ 137 fields**, regenerated + `regmap-check` green (§5.3, §6 updated).
· **`ssp/fw/`**: `mecrisp-quintus-ssp.s` (RV32IMC; `.option norelax` +
`rvc`; `compressed_isa`; **`erasedflashcontainszero`** — our ROM images are
zero-filled, not SPI-0xFF; HW M, no `softwaremultiply`; `FlashDictionary*`
= 1 KiB zeroed pad at ROM top `0xFF00`, reserved-empty per D-21 — the
EndOfCore link + boot scan terminate correctly against zero fill);
`terminal.s` (bridge UART + `-DQEMU_NS16550` twin); `flash.s` stub —
`flash!`/`hflash!`/`flushflash` accept-and-discard, `initflash` absent so
boot skips flash init entirely; `memmap-ssp` (rom@0 + DTCM@0x1000_0000) /
`memmap-qemu` (smoke map in DRAM); Makefile (`MECRISP` guard +
`check-tools`, `ld -m elf32lriscv`). Image: **15.9 KiB kernel**, entry 0x0,
zero-padded 64 KiB hex via new `tools/bin2hex.py` (word `$readmemh` form).
· **QEMU lane** (assets installed: qemu-system-riscv32 11.1.2,
gdb-multiarch): `make -C sim smoke-qemu` → **PASS** — `1 2 + . → 3`,
`: sq dup * ; 5 sq . cr → 25`, `hex FF . cr decimal → FF`.
· **Banked lessons**: (1) terminal hooks are tail-dispatched
(`jalr zero,x15`) — drivers own the data stack: `emit` ends with `drop`
(it is what restores the pointer `type` duplicated; missing it faults at
character #2 — this exact bug cost one bring-up cycle), `key`/`qkey`/`qemit`
with `pushdatos`; (2) unpaced pipe input overruns the ns16550 RX FIFO —
harnesses must pace bytes (real SNAC traffic is baud-paced); (3) `FOR`/`NEXT`
not in the Mecrisp core by design — such loop words arrive later as
packs/EVAL'd tools (D-21); (4) `CONSTANT` is postfix (`value CONSTANT
name`) -- first `.fs` emitter draft had it prefix; fixed + live-load verified
(see 5.5.1).
· **Next**: `sim/ssp/` stub SoC (picorv32 `COMPRESSED_ISA` + ROM(hex)/DTCM
+ UART/bridge decode per §5.2 — the hex is ready today), then gracilis
wrapper, then Quartus `fit.rpt` ×2 for the OQ-20 bake-off.

R18 **compiletoflash dictionary-build pipeline proven on qemu (2026-10-26)**:
owner endorsed building the application dictionary **contiguous with the
kernel** via Mecrisp `compiletoflash` as the build-pipeline shape (D-35).
· **FW**: `flash!`/`hflash!` now plain stores (writable in sim, inert on
silicon — D-32 rev); dictionary window enlarged `0xFF00`-pad →
**`0x4400..0x10000`** (both maps; kernel 0x3F68 leaves margin);
`apps/demo.fs` added as pipeline-rehearsal content.
· **New `sim/ssp/dictbuild_qemu.sh` (`make -C sim dict-qemu`)**: boots the
qemu FW, sends `compiletoflash`, feeds `demo.fs` over paced serial, captures
the window via QMP `pmemsave`, merges kernel+dict, and **cold-boots the
merged image**: `cpu-hello` prints, `42answer . → 42`, `reg-id hex. →
00000000`, zero unknown words — application dictionary resident from
power-on with **no restore logic** (the `catchflashpointers` walk consumes it
natively). Dict captured at 196 B; window ~47 KiB available.
· **QMP gotchas banked**: this qemu's `pmemsave` args are
`{filename, val=phys-addr, size}` (no `offset`; `val` is the address), and
replies interleave with async events — skip lines until `return`/`error`.
· **Release-hex rule** coined: shipped factory image = pipeline output
(dictionary links resolve at compile time against the exact kernel bytes).
· **§5.4 revised**: pack-window-tail header `0xFFF0` (`'MRZM'` id/CRC —
ROM+0 is the reset vector, the old "header at ROM+0" idea was infeasible);
operator MPKG stays source-only; binary dicts are build-system artifacts.
· **Regressions green**: `smoke-qemu` PASS (kernel-only image, empty window);
`regmap-check` PASS (map unchanged at 72/137).
· **Next**: stub SoC (`sim/ssp/`) absorbs this script shape with hardware-
true addresses (its merged hex = the real OSD artifact); then gracilis
wrapper + `fit.rpt` ×2 (OQ-20).

R19 **Verilator stub SoC live at hardware addresses; authoritative dict
pipeline passes (2026-10-26)**: `sim/ssp/` RV-side stub SoC lands (D-33
Verilog side; OQ-20 picorv32 lane of the bake-off).
· **`ssp_stub_top.v`**: picorv32 `COMPRESSED_ISA+MUL+DIV, IRQ off` +
64 KiB ROM (`$readmemh` +RAM; dict window writable = build harness, kernel
region write-counted) + 64 KiB byte-enable DTCM + `ssp_bridge` STUB subset
decode (`ID`=4D525A03 per CSV + UART 0x120-0x12C with 8-byte RX FIFO,
structural FIFO-room pacing, sticky-overrun plumbing) + decoder-error slave
(counted, first address logged). `+ROM=`/`+DUMP=` plusargs; harness dump via
`$writememh` — no DPI exports needed (DPI imports carry TX/RX/err logging).
· **`tb_ssp_stub.cpp`**: stdin/stdout console (DPI), non-blocking stdin,
raw-tty handling, first-TX input-release gate, idle/EOF exit + cycle budget,
exit codes (trap/no-output/diag-flagged), `TXTRACE=1` byte log.
· **`make -C sim stub|smoke-stub|dict-stub`**. smoke-stub PASS: REPL arith,
word def/call, and `$20000000 @ hex. -> 4D525A03` (bridge decode verified
against `ssp_regs.csv`). dict-stub PASS: hardware-address D-35 pipeline —
compiletoflash + demo.fs session, ROM dump -> merged artifact
`build/mecrisp-ssp-stub-app.{bin,hex}` (OSD MROM form), kernel-integrity
check [R20 erratum: dict fragment capture had a dd seek/skip bug -- fixed
R20; R19's dict-stub.bin was the full-64 KiB sparse file, fragment now
correct], cold-boot residency from
the artifact hex (`cpu-hello`/`42answer`/`reg-id` live; `reg-id` proves the
real-map bridge read). Demo dict 196 B — identical size to the qemu lane
(bytes differ: absolute refs are map-relative, as designed). Determinism
double-run: identical SHA-1s for dict + merged artifacts (CI rule now
demonstrated on both lanes).
· New tool `tools/hex2bin.py` ($readmemh/$writememh-word hex -> flat bin,
inverse of bin2hex). Verilator gotchas banked: lint warnings are fatal by
default (picorv32 self-suppresses; keep our files clean); DPI spelling is
"DPI-C"; runtime-string $readmemh/$writememh + $value$plusargs all work —
the ROM in/dump path needs no public-signal access. Lessons (5)-(7) in 5.5.1
(mem_la look-ahead gating; input-release gate; FW self-echo console format).
· **Next**: gracilis twin stub (`FemtoRV32` ADDR_WIDTH=30, rstrb/rbusy/
wmask/wbusy fabric timing) + throwaway Quartus synth tops -> `fit.rpt` x2
(OQ-20 evidence; owner confirm for tycho synth per handoff 2.3).

R20 **gracilis twin stub live; bake-off sim-lane complete both cores
(2026-10-26)**: `sim/ssp/ssp_stub_gracilis.v` (FemtoRV32, D-34
`ADDR_WIDTH=30`) boots the identical FW hex and passes the same benches as
the picorv32 lane.
· **Protocol shim learned** (FemtoRV vs picorv32, handoff 4.1 confirmed):
reads announced by one-cycle `mem_rstrb` with data expected next cycle ->
registered `mem_rdata`, `mem_rbusy` tied 0 (registered-output M10K model);
writes by non-zero `mem_wmask`, `mem_wbusy` tied 0; NO valid/instr
qualifier exists -- fetch vs data discriminated by address (fetch always
< 0x10000, so UART/DTCM pops/writes are unambiguous); reset active-low;
NO trap output (top ties `trap`=0; WDG/idle-exit covers rv-hang for the
bake-off, real design keeps `STATUS.rv_trap` from picorv32 only -- worth a
footnote at bake-off writeup). Vendored gracilis verified to contain HW M
(mul/div ALU) + unconditional RVC decompressor -> RV32IMC confirmed.
· **Harness dedup**: `tb_ssp_stub.cpp` -> `tb_stub_main.cpp`, core selected
via `-DSTUB_INC=… -DSTUB_CLASS=…` + stringize include (nested-quote
versions get stripped through verilator->make->shell; token stringize is the
robust form). Makefile: `stub-gracilis`, `smoke-gracilis`, `dict-gracilis`;
scripts take `TAG`/`MODEL` env; artifacts now core-tagged
(`mecrisp-ssp-<core>-app.*`, `dict-<core>.*`).
· **Bench results**: smoke-gracilis PASS (arith, word def/call, ID read-back
4D525A03); dict-gracilis PASS (compiletoflash window writes land; kernel
integrity; cold-boot residency from artifact hex incl. reg-id). Cross-core
byte-identity of dict + merged artifacts (see 5.4.1) — the shipped MROM
image is core-neutral at the same map, strengthening D-35. Determinism
double-run identical SHA-1s both cores.
· **Fixed**: R19 dict-fragment `dd seek=` produced a sparse 64 KiB file
(bin2hex PADTO error was silent -- script lacks `set -e`; now explicit rc
checks on every artifact step). Fragment capture uses `skip=`.
· **Remaining OQ-20 evidence**: Quartus `fit.rpt` x2 on `5CSEBA6U23I7`
(ALUT/M10K/fmax table) -- needs tycho synth (owner confirm per handoff 2.3).

R21 **OQ-20 fit evidence complete both cores; memory fabric -> explicit RAM IP
(2026-10-26)**: throwaway bake-off projects `bakeoff/` (README = recipe +
findings; device settings mirrored from `MrZ80.qsf`, shared `bakeoff.sdc`
50 MHz, separate output dirs, gitignored products) fit on tycho
(Quartus 17.0 Lite, `5CSEBA6U23I7`; owner-confirmed same-files mount, no sync
-- handoff §2.3 updated).
· **Results table now in 5.8**: both entrants pass 50 MHz with >=28 % margin
(picorv32 72.06/71.42 MHz, 1,482 ALM, 1,251 reg; gracilis 64.13/63.67 MHz,
1,128 ALM, 540 reg; memory identical by construction: 130 M10K blocks,
1,050,624 bits). gracilis -24 % ALM / -711 regs; picorv32 +11 % fmax.
Neither disqualified -- OQ-20 remains for the P0-exit decision on the
weighted criteria (trust/pedigree highest; FW bet core-neutral per 5.4.1).
· **Owner ruling (implemented): explicit RAM IP, no inference reliance.**
Gracilis failed synthesis 5 ways (Error 276003, rom/dtcm as ~1M raw registers;
variants: async mux, rstrb-gated capture, captured-address mux, canonical
q-pipeline + per-bit byteenable, rstrb-gated-q) while the identical fabric
around picorv32 inferred first try (picorv32's registered `mem_addr` gets
absorbed -- `ADDRESS_REG_B=CLOCK0`). Staged probe `bakeoff/ramprobe.v` v1-v4
(v1 lesson: arrays declared 16K but indexed [13:2] -- silently pruned to 4K,
"wins" vacated; v2: standalone true-16K templates infer fine; v3/v4: femto-
driven fabric never reaches the RAM classifier). Rather than keep auditing
tool acceptance rules -> new wrapper `bakeoff/ssp_sdp_ram.vhd` (hand-written
MegaWizard-style altsyncram, DUAL_PORT 16Kx32 -- 17.0 Lite has no
SIMPLE_DUAL_PORT keyword; port-A byteenable, ADDRESS_REG_B=CLOCK0,
OUTDATA_REG_B=UNREGISTERED), house pattern per Components/INTERNALRAM/
InternalRam64K.vhd (general 64Kx8 RAM) & Components/TERMINAL/DisplayRam1K.vhd.
Both tops now instantiate it; picorv32 numbers cleaned of inference
duplication (258 blk/2.1 Mbit -> 130 blk/1.05 Mbit). **Recorded as D-36.**
· **Latency truth**: registered-address IP => launch+1 reads; native match for
FemtoRV rstrb (rbusy never needed for RAM), one wait-state FSM added to
picorv32 top (its sim lane unaffected -- handshake-driven FW).
· Sim parity: `sim/ssp/ssp_stub_gracilis.v` canonical q-pipeline + per-bit
byteenable rewrite; smoke-gracilis + dict-gracilis re-PASS; cross-core dict/
merged byte-identity holds (dd250da5.../c43b230a...).
· **Next**: ~~owner review of OQ-20 evidence + D-36 ruling~~ (done -- D-36
taken R21; OQ-20 decided R23: gracilis selected, D-37); P1a prep
(TICK_US/milliseconds, ssp_bridge RTL vs CSV, trap/WDG semantics §5.8
footnote per D-37: gracilis has no trap pin -- WDG carries the backstop).

R22 **OQ-20 cycle-level performance evidence complete -- gracilis wins every
op (2026-10-26)**: new bench lane `sim/ssp/bench_stub.sh` + make targets
bench-stub / bench-stub-fab / bench-gracilis (owner spec: real work --
no-op subroutine calls, DUP/DROP arithmetic units, MUL unit, VARIABLE
store/retrieve loops; NO empty loops, no RECURSE -- owner note that it is
rare in production; dictionary-lookup cost excluded from scoring, see 5.8.3).
Timed via EMIT control-byte markers + TXTRACE stamps; per-iteration cost by
equal-digit N differencing (200k vs 100k) cancels all fixed FW overhead
(results exact integers); goldens = sum(0..N-1) mod 2^32 on four accumulate
loops, verified all lanes. New +FABWAIT knob on the picorv32 stub models the
D-36 launch+1 IP fabric (bare stub was flattering picorv32; gracilis stub is
natively launch+1) => picorv32-fab vs gracilis = silicon-predictive pairing.
Results (cyc/iter, 5.8.2): bare loop 10/13/8, call 7/9/4, I+add 22/27/16,
stack-op unit 45/56/34, MUL-vs-ADD +41/+42/+3, var st+ld 111/140/82
(picorv32-zero / picorv32-fab / gracilis). Gracilis wins every op at equal
fabric latency (1.6-2.3x vs fab), incl. boot-to-banner 196k vs 322k cycles.
With R21 area (gracilis -24 % ALM) + R19/R20 FW neutrality + R22 perf, the
only residual OQ-20 discriminator is trust/pedigree. Follow-ups banked:
picorv32 +41 MUL path worth a config check (does not change direction);
kernel RECURSE x constant-fold miscompilation (5.8.3) must be understood
before any recursive FW word ships; `variable` provided via CREATE (D-32
trim). Harness lessons: +IDLE/+MAXCYCLES must exceed longest silent workload
stretch (loops emit no TX -- three truncation rounds diagnosed); harness
"cycles" are 2 ticks/clock (numbers halved). Artifacts:
/tmp/opencode/stub-bench-<lane>/bench-*.tsv (regenerable).

R23 **OQ-20 CLOSED -- owner selects FemtoRV32-gracilis (D-37) (2026-10-26)**:
"gracilis it is!" Decision recorded as D-37 with full rationale (area R21,
FW neutrality R19/R20, cycle-level performance R22 -- wins every op;
Mecrisp-co-design lineage). Consequences wired through the docs: 5.8 status
SELECTED; criteria block marked decided; D-09 marked resolved; module/P0
rows updated; ssp_top instantiation = femtorv32_gracilis, ADDR_WIDTH=30
(D-34), launch+1 native (D-36, rbusy tied 0 at wrapper). picorv32 stays
vendored as documented fallback (swap = crt0 + bus shim only, D-27).
Residual-risk note (pedigree axis): FemtoRV assurance = shipped Mecrisp
deployment + learn-fpga suite + our golden benches; optional riscv-formal
style sweep of gracilis is now a P1 comfort item, not a gate. P1 first
tasks unchanged in order: ssp_bridge RTL vs CSV, TICK_US/milliseconds,
panel-engine micro-op table (D-30), FW RECURSE-fold quirk fix (5.8.3) as
an FW hygiene item.

R24 **First-cut P1a RTL + external review (2026-10-26/27) [entry written
retrospectively in R30; the review text itself was not committed]**: first
version of the P1a vertical slice -- `ssp_bridge.v` (register file bound to
the CSV, D-30 memory sequencer, park controller), `ssp_uart.v` (SSP console
UART + escape recognizer; OQ-22 option (a) byte relay chosen, see OQ-22),
`ssp_top.v` (core + MROM/DTCM + decoder + bridge + UART + console mux),
`z80_bus_mux.vhd` (D-26), Verilator p1a lane. It went to an independent
review whose findings (H-series: T80 grant gating, boot sovereignty, engine
cycle fidelity, RXDATA/UART sampling, bus-mux latch) were all resolved in R25.

R25 **Review resolutions: T80 freeze gate, boot sovereignty, engine
fidelity (2026-10-27, commit e94018b) [entry written retrospectively in
R30 from the commit message]**:
(1) **D-25 reworked** -- grant gate inside the T80 (see the D-25 amendment).
(2) **Boot sovereignty (owner ruling)**: `CONSOLE_OWN` resets 0 -- the guest
owns the SNAC at power, so SSP FW death never blocks a guest boot; OSD
`rv_rst_n` host-reset hatch; `rv_ctrl_ok` releases CTRL/park/console when
the RV is in reset or hung; `WDG_RUN` (~1.3 ms) and `WDG_PARK` (~0.4 s)
implemented (D-13), `halt_reason`=9 `wdg_park`; `STATUS` gains `RV_ALIVE`
and a 3-bit `MC`.
(3) **Engine cycles T80s-literal** (production mode=1/t2write=1/iowait=0):
MREQ/RD T2..T3, I/O RD single-T at T3, WR from T2, data captured end of T2
(DI_Reg discipline); `BUSRQ` is held until the engine cycle completes so a
released park never truncates an engine access.
(4) **Console**: RXDATA launch+1 fix (superseded by the R26 correction);
UART RX sampled at bit centres (start 7, D0..D7 23..135, stop 151); relay
2-deep queue + inter-byte stretch; raw-vs-relay mux mutually exclusive;
escape hand-over wins a same-cycle CTRL write.
(5) `z80_bus_mux`: registered select (latch removed), all strobes idle-gated
while parked-and-idle (G-2).
(6) Regmap: RTL binds the CSV via RIDX/BIT/HI macros and sized reset
constants; CSV `CTRL` reset 0x20 (`esc_break_en`, D-14); `WDG_STAT` fields.
(7) Bench/infra: T80s benches and the CPM pair tie FREEZE inactive; sim
Makefile gains lint-ssp/p1a/dict-p1a/smoke-p1a.
Gates: Verilator lint -Wall clean; z80_bus_mux GHDL-synth latch-free;
run.sh 115 iterations / 0 mismatches (baseline); cpuregs 8/8, ixmin 10/10,
ixstack all-pass.

R26 **P1a console lane: REPL green (2026-10-27)**: three defects found in the p1a
Verilator lane (real ssp_top + Z80 BFM), owner-approved fixes:
(1) **RXDATA one-pop lag (RTL, ssp_bridge)** -- R25/H5 registered the FIFO
head into a hold reg on the pop edge and fed the hold to q_reg, while q_hold
captures q_reg on that SAME edge => q_hold latched the OLD hold; every KEY
returned the previous pop's byte (CR seen one key late => accept never
ended). Fix: q_reg(RXDATA) = combinational FIFO head (rx_rnext), 0 when
empty (CSV text updated, regen). [R25 erratum: the H5 "launch+1 hold"
shape was itself the one-byte skew.]
(2) **Monitor TX muted until first ESC (RTL, ssp_top)** -- snac_txd was
gated by console_own (resets 0 per R25), so the FW banner never reached the
pin. Per D-19 the monitor output sink is CONN_ROUTE.out_snac (reset 1, HW
fail-safe); snac_txd = out_snac ? mon_txd : idle. Guest TX never drives the
SNAC pin (silicon: SNAC wired to the SSP, guest ACIA TX internal);
console_own continues to govern RX routing only. [R25 erratum: header
"snac_txd = console_own ? monitor : guest" superseded.] **[R26 erratum
(same day, owner-approved): item (2) was wrong. MrZ80.sv routes the
guest's serial_tx to the SNAC TX (USER_OUT[1]), so gating TX by out_snac
alone would drop all guest console output once integrated. The muted
banner was the intended R25 behaviour (guest owns the console until ESC),
not a defect. Final mux: snac_txd = (console_own & out_snac) ? mon_txd :
guest_txd -- R25 ownership rule plus the D-19 sink gate. The p1a harness
now models the operator in two steps (escape at +RXAT, rest after the
monitor goes quiet). Consequence for FW: a banner printed before ESC is
lost; the monitor FW should print on escape, not at boot (handoff 2, step 1).]**
(3) **Harness (tb_p1a_main.cpp)** -- RX release fired mid-banner
(first_tx + grace, and the +RXAT fallback) and overflowed the depth-8 RX
FIFO before the kernel listened; now released when TX goes quiet, +RXAT
only when the FW never transmits. +ECHO=0 parsed as enable -- fixed.
Probe lesson: POPD now prints CPU-visible mem_rdata at launch+1 (the
old probe printed the hold reg, which looked correct and hid defect 1).
Diagnosis note: the "kernel polls offset 0x80 / stale FW hex" theory from
the handoff was wrong -- fresh runs show all kernel reads at 0x124/0x128.
Verified: `\x1d1 2 + . cr\r` -> banner, echo, `3`, `ok.`; `\x1dq\r` ->
`q not found.`; lint-ssp OK; smoke-gracilis, dict-gracilis, smoke-stub
PASS.

R27 **Owner rulings on the R26 handoff questions (2026-10-27)**:
(1) Factory ROM image is committed to the repo; no GPLv3 issue since the
source is always available -> D-38. (2) The SSP console should follow the
OSD serial-port selection, so the HPS console port also works as the SSP
console; deferrable to a later phase with the OSD video/keyboard console
if difficult -> D-40 (lean: place ssp_top after the existing port-select
mux, which likely makes it easy). (3) P1a commands redefined around the
operator's needs rather than the missing v0.1 table: examine memory,
modify memory by prompting with the current contents (bare CR leaves it
unchanged), go to an address, continue the CPU (bare `G`) -> D-39; the
trampoline therefore moves into P1a. Framework expected to grow. (4) Work
to date committed and pushed to origin (lmamakos/MrZ80), branch r24-p1a.

R28 **`G aaaa` hardware: reset vent + reset-vector trampoline (2026-10-27)**
(D-39 consequence; the trampoline moved from P1b into P1a). New
`ssp/rtl/ssp_tramp.vhd` (VHDL, Z80 side, D-33), bridge exports
`tramp_arm`/`tramp_target` and auto-clears `CTRL.TRAMP_EN` on `tramp_done`;
`ssp_top` carries the three ports; design in 7.4 above. Verification:
`sim/tb_tramp.vhd` -- real T80s, production configuration (Mode 1, T2Write 1,
IOWait 0, `cpu_cen` 1-of-5), 176 checks over: idle transparency, park -> G,
park-at-target, plain reset without arm, arm without reset never intercepts,
wait states, reset re-asserted at three points in the window, targets
$0000/$FFFF/$C3C3, vent minimum/maximum width; mutation-tested (injection
removed, never-disarm, prime-without-reset, vent stretch removed/lengthened,
early done, no index restart: all caught; two guard mutants are equivalent
and documented). `sim/ssp/p1a_tramp.sh` -- the same handshake driven from the
Mecrisp REPL at register level on the p1a lane (G $0200, plain reset, park at
$0300). Findings: (1) **bridge multi-byte-register write bug (pre-existing,
R25-R27 era)**: `w = mem_wdata[7:0]` was used for EVERY byte lane, so a 32-bit
store loaded the low byte into all lanes (`TRAMP_ADDR <- $0200` gave $0000;
`CTRL <- $133` spuriously set `PANEL_LOCK`, bit 9). Fixed: per-lane
`w1/w2/w3` on all 20 `mem_wmask[1..3]` registers (CTRL, TRAMP_ADDR, BP0-3,
TRAP_DATA, MEM_ADDR, AR, SD_ADDR, IRQ_EN, LED_DATA0/1); nothing had written a
multi-byte register from FW before. (2) **`FREEZE_req_n` is a dead port in
`T80.vhd`** (declared, never read); the park request is the ordinary
**`BUSRQ_n`**, gated by `freeze_ok`. Integration must drive `n_BUSRQ` from the
bridge's `z_busrq_n`; the earlier note naming `FREEZE_req_n` was wrong.
(3) T80 reset is asynchronous and clears `BusAck`; BFM now models reset,
real `JP`, and a freeze grant with no further instruction cycle (PC at park =
next instruction). (4) Mecrisp spends ~170k cycles per input line (each token
is a full dictionary search): scripts need `+RXGAP` pacing and the new
in-band pause marker (`0x01`, `+PAUSE`) before an escape, else a late-executing
line overwrites the escape hand-over.

R29 **SSP UART RX FIFO 8 -> 128 bytes (2026-10-27, owner request; D-41)**.
`ssp_uart` gains `parameter FIFO_LOG2 = 7`; pointers one bit wider than the
index (full = MSB differs, empty = equal), the array carries the MLAB
`ramstyle` hint, and the unused second read port (`rx_rdata <= fifo[rp]`) now
reuses the `rx_rnext` port (one RAM copy instead of two). New unit bench
`sim/ssp/tb_uart_fifo.v` (iverilog, `make -C sim uart-fifo`, depths 8 and
128): real 8N1 frames back to back at 115200 -- fill to exactly DEPTH, overrun
(first DEPTH intact, extras dropped, sticky flag, `rx_clr`), exactly-full from
four shifted read-pointer phases, 3*DEPTH bytes streamed through a half-full
FIFO across pointer wraparound, flush, console_own gating; mutation-tested
(never-full, no overrun flag, narrow index, no flush, head off by one, and
"full one early" -- the last survived until the shifted-phase case was added).
Quartus synthesis (`bakeoff/uartfifo8`, `uartfifo128`): see D-41. Effect on
the p1a lane: the register-level `G aaaa` script that overran the 8-byte FIFO
without `+RXGAP` pacing now runs unpaced, ~100 characters at line rate. The
P0 stub SoCs keep their own 8-byte FIFO model (different lane, unchanged).

R30 **P1a monitor FW (2026-10-27; D-39 implemented)**. `ssp/fw/apps/monitor.fs`:
**dedicated ODT-style command loop** (prompt `.`, uppercase hex, SSP_DESIGN
10.1), not Forth words that parse their own arguments; chosen because the
loop owns the console only while `STATUS.FW_CONSOLE_OK` is set and must wait
for the escape, banner on gaining it (R26), and survive the guest taking it
back. Commands (letters are the D-39 proposals, unchanged): `E [aaaa [n]]`
(default 128 bytes, 16 per row, hex + ASCII; no address = continue after the
last E/D), `D [aaaa]` (prompt `aaaa: xx `, hex replaces, bare CR leaves the
byte and advances, `.` ends; a value > FF or garbage prints `?` and stays on
the byte), `G aaaa` (register-level recipe of R28: `TRAMP_ADDR`, `CTRL=$133`,
`$030`), `G` (`CTRL=$020`, never injects), `R` (registers from `SNAP_REG0..6`;
`*MID-INSN*` if `AT_BOUNDARY`=0, `*EXX*` if `ALT`), `F` (leave to the Forth
REPL; `mon` re-enters), `? / H`. Malformed or extra arguments are errors --
`G zz` must never mean plain `G`. E/D/G/R require the guest parked
(`NOT PARKED` otherwise). `init` runs `mon`, so a cold boot of the dictionary
artifact is the monitor. Memory goes through the D-30 sequencer in the
guest's logical space.
Hazards found and fixed on the way:
(1) **Console hand-over truncation**: `G` drops `console_own` at once and
the UART has a 1-deep TX holding register plus the shifter, so the monitor
prints "GO" then waits ~200 us (`TICK_US`) before the `CTRL` write, else the
last characters are cut off on the guest's line.
(2) **WDG_PARK vs a human**: a park held with no `WDG_PARK_KICK` for ~0.4 s
sets `park_dead_l`/`STATUS.WDG_DEAD`; a person at the prompt is slower than
that, so the kernel's `serial_key` wait loop (`ssp/fw/terminal.s`) now writes
`WDG_PARK_KICK` while it polls. **RTL gap found, not fixed (owner decision
needed):** D-13/section 6.9 say expiry demotes the console and releases the
FW hold (`z_busreq_n`<-1, `console_own`<-0); `ssp_bridge.v` only latches
`park_dead_l` and reports it (`halt_reason`=9 fires only on `!rv_ctrl_ok`).
(3) **Mecrisp specifics**: in `compiletoflash` mode `variable` takes an
initial value (`0 variable x`); a `constant` split over two lines is fine.
Infrastructure: BFM memory is now a writable 64K image shared by guest fetches
and engine reads/writes (initial pattern `addr[7:0]^addr[15:8]`; engine writes
gated by `rst_n` -- uninitialised strobes scribbled `pmem[0]` before reset);
p1a harness: `+LINEWAIT=1|2` line-at-a-time input pacing (1 = wait for the
Mecrisp `ok.` prompt, 2 = TX quiet, for the monitor), `+QUIET`, `+LINETO`,
exit no longer fires while input was just sent, final line reports
`guest_rx=` and `freeze_acc=`; `sim/ssp/p1a_dictbuild.sh` (monitor into the
dictionary, kernel-integrity + cold-boot proof; ~45 s) and
`sim/ssp/p1a_smoke.sh`: A the full operator session (banner on every escape,
E/D semantics incl. error paths, `JP $5000` poked then `G 5000` and the guest
verified running it, plain G, `G 300`, F), B OM-off bit transparency (R-43),
C escape consumed with OM on, D idle at the prompt 0.8 s without WDG_PARK
expiry. Mutation-tested: deposit not advancing, `G aaaa` not arming, plain G
leaving TRAMP_EN set, BFM writes dropped, kernel not kicking the watchdog --
each caught.

R31 **GHDL integration benches on the real T80 (R-40, R-42); three engine bugs
found and fixed (2026-10-27)**.
(1) `sim/tb_integ_park.vhd` (R-40, `make -C sim integ-park`): production-config
T80s runs a directed mix (DD/FD, CB, DDCB/FDCB, ED incl. the custom PUSHIX/POPIX,
LDIR/LDDR/CPIR/CPDR/INIR/OTIR, DJNZ, CALL/RET, RST, EX (SP), EXX, I/O, EI shadow,
IM2 interrupts, HALT) under random BUSRQ requests and holds, with and without wait
states. The oracle is an unparked reference run: REG at every instruction start,
found by a bus-level prefix state machine independent of the T80's own `freeze_ok`.
A grant after n starts must show REG == reference[n+1] and `would_boundary`=1, REG
and bus idle for the hold; final REG and memory hash equal the reference. At an
interrupt-acknowledge boundary the reference start has already cleared IFF1/IFF2
(the T80 takes the interrupt on the same T_Res edge) while a park there is before the
acknowledge, so only those boundaries are compared without the IFF bits (and the
bench checks IFF is still 11). HALT parks anywhere, PC = HALT+1; an INT raised while
parked is acknowledged only after the release. ~2400 grants, 9036 checks, 4 s.
Mutation-tested on `freeze_ok` (listed in the bench header): catches vanilla
any-T_Res grants, a missing prefix gate, DJNZ without the zero test, "always" and an
extra MCycle=1 boundary; survivors are redundant with the Prefix gate in the
production configuration (NextIs_XY_Fetch, MCycle/="111", the Mode-1 "110"
exclusion) or merely coarser (No_BTR) -- recorded, not defects. Pitfall: the T80
register file is not reset, so the program defines every register (INITOK) and the
bench compares from there.
(2) **R-42 waveform golden compare.** The bridge is Verilog and GHDL cannot read it
(D-33), so `sim/tb_cycle_golden.vhd` captures the REAL T80's four data-cycle shapes
(memory/I-O, read/write; with and without one wait state), one vector per T-state
(MREQ IORQ RD WR M1 MRD_T1, sampled at each cpu_cen edge), into the committed
`sim/ssp/golden_cycles.txt` (`run_cycle_golden.sh` flags drift, `--update` rewrites
it), and `sim/ssp/p1a_engine_golden.sh` replays the same eight cases through the
real bridge engine on the p1a lane (`+ENGLOG`, `+WAIT`) and compares line for line.
It found: memory strobes held through T3 (T80: T2 only), I/O read with IORQ alone in
T2 and RD alone in T3, and **the I/O write never asserted WR_n** (the IO_WR primitive
was a no-op). `ssp_bridge.v` fixed: all four cycle types assert MREQ/IORQ with RD/WR in
T2 and release at the T2 exit (the wait-sensed edge), T3 is bus-hold only. (The R25
claim "T80s-literal" was not.) The BFM `+WAIT` now injects the same stimulus as the
golden (one wait state in T2 of every engine data cycle) and the p1a lane flags any
BUSRQ release during an engine cycle (`[p1a-ERR]`).
(3) `sim/tb_integ_mux.vhd` (`make -C sim integ-mux`): `z80_bus_mux` + real T80s + an
engine model (the bridge FSM transcribed; its pin waveform is checked against the
golden file, so bridge == golden == T80) + a fabric model that sees only the mux
outputs. Per clock: running = T80 nets, parked/idle = strobes and MRD_T1 idle, engine
cycle = engine nets, select never without BusAck (hierarchical `sel_eng`), select back
on the T80 once the engine is done; plus a directed protocol-violation test (engine
claims the bus before BusAck). At the end the T80 program (120-step running sum with
memory writes/reads and OUTs) is exact, memory-write and OUT cycle counts are exact
(no lost/doubled/glitched strobe at any select change) and every engine access lands.
Four phases: boundary parking and FREEZE_any (off-boundary grants, the P1b step-mode
shape), each with and without wait states. 250k checks. Mutation-tested (listed in
the bench header); the strobe idle-gate in the mux survives because a T80 grant
always finds the strobes already released -- kept as defence in depth.
(4) Not done: R-42's "reads/writes to SDRAM, BRAM and I/O ... engine honours MMU +
SDRAM waits" against the real MMU/SDRAM client FSM needs the mux instantiated in the
CPM core (step 4); the bench shape and the golden file are ready for it.

R32 **Synthesis prerequisites (2026-10-27; handoff Step 3).** (1) `ssp/rtl/ssp_sdp_ram.vhd`
is the bake-off altsyncram wrapper (D-36) plus a `INIT_FILE` generic; `ssp_top` takes
`parameter MROM_INIT` (default `ssp/fw/forth_rom.mif`, resolved by Quartus relative to
the project directory) and passes it to `u_mrom`. `sim/ssp/ssp_sdp_ram.v` accepts and
ignores it. (2) Factory ROM (D-38): `tools/bin2mif.py` turns the merged kernel +
monitor dictionary image (`ssp/fw/build/mecrisp-ssp-p1a-app.bin`) into the committed
`ssp/fw/forth_rom.mif` (16K x 32, identical-word runs as address ranges, so a recommit
is a small diff; `--check` verifies the MIF against a binary). `make -C sim fw-rom`
rebuilds the dictionary and regenerates the MIF; `fw-rom-check` is the drift check.
**Recommit the MIF whenever the FW changes.** (3) A synthesis probe of the real SSP file
set (`bakeoff/ssp_top.qpf`, top = `ssp_top`, Quartus 17.0 docker, ~25 s, 0 errors):
~1820 ALMs, 1346 registers, 3 DSP, 1,050,624 block-memory bits (two 16K x 32 M10K
arrays plus the MLAB FIFO); the MIF is found and used. The probe **found a real bug**:
the `RV_ALIVE`/`rv_stalled` probe sat inside `synthesis translate_off` and referenced
`core.state`, so on hardware `STATUS.RV_ALIVE` was stuck low (it worked in sim only).
It is now derived from the bus protocol, identically in sim and synthesis:
`rv_stalled = 0` (the `mem_*busy` inputs are tied 0) and `rv_alive` = a read strobe in
the last 65535 clocks. `p1a_smoke.sh` now checks `STATUS.RV_ALIVE` (mutation-tested:
`rv_alive = 1'b0` makes the smoke FAIL). (4) The `MrZ80.qsf` file entries are added with
the instantiation in step 4 (before then the files would be pruned as unused).

R33 **Top-level integration (2026-10-27; handoff Step 4).** (1) `MicrocomputerZ80CPM.vhd`:
the T80's pins now go through `z80_bus_mux` (the old net names `n_MREQ/n_IORQ/n_RD/n_WR/
n_M1`, `cpuAddress`, `cpuDataOut`, `cpu_mrd_t1` are the mux OUTPUTS, so the whole fabric is
unchanged); `n_BUSRQ` is driven by the new `ssp_busrq_n` port; `ssp_tramp` sits between the
`cpuDataIn` mux and the T80's DI and owns the T80 reset (`t80_rst_n`).  `FREEZE_req_n`
stays `'1'` (dead port); `FREEZE_any` takes `ssp_freeze_any`.  The capture chain's
bus-data view (`fpStaticDataBus`) uses the injected byte (`t80_din`), the more truthful
choice.  New entity ports (all inputs default idle so the core and every GHDL bench work
unchanged): `ssp_busrq_n, ssp_z_reset_n, ssp_tramp_arm/target, ssp_freeze_any, ssp_eng_*`;
outputs `ssp_tramp_done, ssp_cpu_cen` (ungated), `ssp_cpu_din, ssp_cpu_wait_n,
ssp_busack_n, ssp_halt_n, ssp_m1_n` (raw T80), `ssp_mc/ts/alt, ssp_would_boundary,
ssp_t80_reg`.  `ssp_top` stays in `MrZ80.sv` (Verilog; GHDL cannot read it, D-33).
`sim/MicrocomputerZ80CPM_sim.vhd` resynced (`check_sync.sh` OK); `run.sh`,
`run_blockdev_prog.sh`, `run_perf.sh` analyse the two new VHDL files (the latter two also
gained the `Universal_Capture_Chain.vhd` entry they had been missing, a pre-existing break).
(2) `MrZ80.sv`: `ssp_top` is instantiated AFTER the OSD serial-port mux (D-40): `snac_rxd` =
`serial_rx` (the selected port), `snac_txd` = `serial_tx` (selected port's TX: monitor, or
the guest's TX passed through), `guest_rxd/guest_txd` = the guest ACIA (`guest_rx`,
`guest_tx`); either port works with no further muxing.  OSD: `OK` SSP Monitor Off/On
(status[20] = `osd_ok`), `OM` SSP Serial Escape Off/On (status[22]), `TN` Reset SSP
(status[23], trigger, stretched to ~1.3 ms for `rv_rst_n`); bit 21 spare.  `baud_increment`
is the O9B value the guest UART gets.  `rst_n` = `~reset` (the guest reset: the SSP is held
in reset with the guest until a boot image is loaded and restarts on OSD Reset -- a P1a
simplification, a monitor-only reset domain is P1b).  `esc_disable`, `panel_stop` and
`dl_*` are tied inactive.  `z_wait_n` / `z_cen_gate` (CTRL.Z_WAIT_N / CEN_GATE) are
NOT wired in P1a: nothing in the P1a monitor uses them, and an engine cycle would stall on
a forced wait.  (3) `MrZ80.qsf` carries the SSP file set + `SEARCH_PATH ssp/rtl`.  Full
compile (`tools/build.sh`, 7m40s on tycho): 0 errors, all clocks meet timing (worst setup
slack +0.852 ns on the HDMI PLL clock, clk_sys domain +2.0 ns, hold >= +0.248 ns), 13,145
ALMs (31 %), 2.20 Mbit block memory (39 %), 37 DSP.  (4) R-42 second half,
`sim/tb_integ_core.vhd` (`make -C sim integ-core`): the engine model through the REAL
CPM fabric (mux, T80s, MMU, block RAM, SDRAM client FSM, clk_sys<->clk_ram CDC model) while
a guest program runs (`tb_integ_core.asm`).  The engine writes/reads block RAM and SDRAM
(incl. the MRD_T1 speculative read and the stall), reads MMU mapping registers by I/O,
and writes block RAM through the MMU direct-access pointer/data port (a promoted I/O
cycle), reading it back as memory; the guest's SDRAM + block-RAM read-back mismatch count
is 0 and its sum/memory image intact after 369 parks / 899 engine ops (99,292 checks),
with the per-clock mux checks as in `tb_integ_mux` run against the real DUT.
Mutation-tested (see the bench header).  Bench lesson: the MMU reset map puts frame 0 on
the block RAM page and frames 1..3 on SDRAM pages 1..3 (not block RAM everywhere).
Remaining: Step 5, hardware first light (`make install`, then escape, `E`/`D`, `G`, OM-off
transparency on the board).

R34 **Console line ends (2026-10-27; first-light finding).** On hardware the monitor (and
the Forth REPL) ended lines with a bare LF: the Mecrisp-Quintus `cr` word and kernel
messages come from the `writeln` macro (`common/forth-core.s`), which appends CR only when
the build defines `crlf`, and `ssp/fw/mecrisp-quintus-ssp.s` did not.  Fix (owner's
diagnosis): `.equ crlf, 1` in the target file, as the thejas32 port does; no custom words
in the monitor.  Note the macro emits LF then CR (`"\n\r"`), not CR LF; both characters are
present, which is what a terminal needs.  Kernel and factory ROM changed: `ssp/fw/forth_rom.mif`
regenerated (`make -C sim fw-rom`).  `p1a_smoke.sh` checks that every banner carries both
characters.  Re-verified: smoke-p1a, tramp-p1a, smoke/dict stub (picorv32, gracilis), smoke/dict qemu.

R35 **Hardware first light — P1a EXIT (2026-10-27).** Owner built, deployed and tested the
R34 image on the board.  ALL P1a exit items PASS on hardware: escape (`^]`, OSD `OM` On)
into the monitor; examine/deposit guest memory (`E`/`D`); register snapshot (`R`);
`G aaaa` (trampoline) and bare `G` (continue); `?` help; RomWBW/CP/M boots and runs
normally; console line ends CR+LF (R34 fix confirmed).  P1a is CLOSED.

**Next-phase requirements raised at first light (owner, 2026-10-27) and capability check.**
(1) *Physical (28-bit) memory examine/deposit*; (2) *Z80 I/O port access from the monitor*;
(3) *easy MMU-register inspection and logical→physical translation display in the monitor*;
(4) distinct command surface for physical ops.  Assessment against the current RTL:
- **I/O: no hardware gap.** The D-30 sequencer already implements IO_RD/IO_WR
  (`MEM_CTL.IS_IO`), golden-verified (R-42) and exercised by `tb_integ_core`; the mux
  carries IORQ.  Needs monitor FW commands only (`I a`, `O a d`).
- **Physical: no change to `z80_bus_mux` — and it is deliberately NOT the vehicle.**
  The mux arbitrates *Z80 cycle semantics* at the T80 boundary; those are inherently
  logical (MMU-translated) addresses, and its engine is address-shaped 16-bit on purpose.
  Physical access bypasses the MMU downstream, at the point where the fabric already
  sees physical addresses: this is exactly the already-decided **`ssp_mem_client`**
  (D-15-P, P1b, §9): parked client borrowing the *wiring* — drive the existing SDRAM
  client interface (`sdram_addr/din/we/rd`) and the BRAM mux (same seam the `dl_bram_*`
  download port already uses) while the guest is parked AND the primary client FSM is
  idle.  The rejected alternative (driving physical through the mux by widening
  `eng_addr` to 28 bits and bypassing the MMU there) would split translation semantics
  across two places and make the mux's R-42 golden story two-mode; the client approach
  keeps the mux single-purpose.  The retracted MMU-direct-port trick ($B8–$BC, guest-
  owned pointer — D-15) is confirmed bad practice from the R33 bench: 5 port cycles per
  access, perturbs guest pointer state.  Mode is the designed `MD` reg (0x80:
  logical/physical), FW `PHY`/`LOG` (D-22); `G` stays logical-only (CPU state is
  logical) — matches the owner's note.
- **MMU regs/translation: two designed paths.** (a) today, usable already: the engine
  I/O-reads $B0..$BF (state-neutral; proven by `tb_integ_core`), so FW can dump frames
  and the pointer without any HW change — enough for a `MAP` command in P1b-first;
  (b) the dedicated `MAP0..3` frame taps (0xE0–0xEC, `{valid,page}×4`, P-D neutral,
  §9.3): needs MMU.vhd to export `mmu_frame` as tap outputs (our file, allowed; not
  `sys/`), wired CPM entity → ssp seam → bridge.  Logical→physical *display* is FW math
  (4 frames × 16 KiB) from either source: annotate `E`/`D` rows with the physical
  address while in `PHY`-shadow mode.
- **Command surface:** canonical design is modal (`PHY`/`LOG` switch + same `E`/`D`,
  D-22); whether to ALSO add explicit physical verbs (e.g. `PE`/`PD`) is an open FW
  letter choice (owner, P1b FW scope) — see OQ-24.

**Revision same day (owner ruling):** **block-RAM access by physical address is
deferred** — a late hardware-debug aid, not needed for the first physical-capability
slice. `ssp_mem_client` P1 scope narrows to the SDRAM physical window (pages 0..8191);
a physical op targeting the BRAM page (0x0800_0000..0x0800_FFFF) is rejected by FW with
`?`. BRAM stays fully reachable through *logical* addresses today (engine cycles + MMU
frames), so nothing that works today is lost; the BRAM-mux leg of the client (and its
`tb_mem_client` checks) moves to a later phase with the vid/P2 client work.

R36 **Terminology + ground rules (2026-10-28; owner rulings).** (1) The Z80 is no longer
called the "guest" — it is the platform's primary processor: "the Z80" / "the Z80 system".
Renamed throughout the production RTL (`ssp/rtl/*`, `MicrocomputerZ80CPM.vhd`, `MrZ80.sv`;
`ssp_top` ports `guest_rxd/guest_txd` -> `z80_rxd/z80_txd`), FW (`terminal.s`, `monitor.fs`),
the canonical `ssp_regs.csv` (+ regenerated `.vh/.vhd/.fs/md`), and the living spec/handoff
text. Exception: §17 history entries, `SSP_RISCV_REVIEW.md` (archive), and the simulation
scripts keep their legacy wording; `sim/MicrocomputerZ80CPM_sim.vhd` follows the real file
because `check_sync.sh` keeps that pair identical. (2) **DTCM renamed to RV RAM**
(identifiers `*dtcm*` -> `*rram*`). Origin of the term: imported during the R12–R16 core
review from the FemtoRV32 literature (Harvard core, `I/imem`/`D/dmem` ports -> ITCM/DTCM
labels; F-09 in `SSP_RISCV_REVIEW.md` first proposed "TCM" sizes). The name was always
slightly wrong here: our `0x1000_0000` window is ordinary bus-decoded byte-enable M10K
behind the SSP local bus, not ARM-style tightly-coupled memory. §5.1/§5.2 reworded
accordingly. (3) **Ground rules (owner):** commit only code believed to work (trivial
changes exempt); never `git push` — pushing is the owner's manual step. Regression re-run
after the rename: regmap-check, lint-ssp, p1a + tramp-p1a + uart-fifo + dict-p1a +
smoke-p1a, stub/dict/smoke lanes (picorv32, gracilis, qemu), GHDL sync + tramp +
integ-park + integ-mux + integ-core + cycle-golden — all PASS.
