# ODT_MONITOR_DESIGN — FPGA-Resident ODT-Style Debug Monitor for MrZ80

Status: **DRAFT v0.6** — v0.2 (support-CPU architecture: VexRiscv RV32IMC +
Mecrisp-Quintus FORTH + cycle-accurate `dbg_bridge`) as amended by the
**design decision session of 2026-10-22** (full round-by-round log in §17),
plus follow-up refinement **R7**: 32-switch bank with dual personality
(panel input + guest sense ports $FC–$FF) and encoder accumulate-and-commit
menu counter exposed at $FB (§11.2/§11.6).
**v0.5** = panel-UX deep-dive outcome (round **R8**, 2026-10-23; full spec
in `ODT_PANEL_UX.md`): operator-sovereignty-with-PANEL_LOCK (G-8), per-page
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
Headline changes from v0.2: downloadable monitor ROM (no refit to update FW)
+ FORTH program pack via OSD; RV32IMC facilities settled; MMU direct-access
path **retracted** (guest-owned state) and replaced by a parked physical
client that borrows the wiring; two-tier watchdog with a strict few-ms
guest-stall budget; formal invariant P-D (state-neutral observation);
address-first front-panel switch map (28 address bits + SPDT function
switches) with the classic operations **executed in hardware**, the monitor
firmware a peer on the same shared functional registers; `$D0–$D3` guest
mailbox; lamps-not-graphics philosophy with monitor state exported into the
capture chain on profile 7; firmware-policy console routing (serial → HDMI
mirror → later exclusive HDMI+keyboard console).

Tags: `[verified]` (re-confirmed against source; anchors are hints — grep the
name) · `[decided]` (locked, see §2) · `[proposed]` (review target) ·
`[open]` (§14) · `[deferred]` · `[new v0.3]` (from the decision session).

Companion documents: `doc/t80_reg_debug_vector.md` (normative register map),
`ODT_PANEL_UX.md` (panel UX spec — R8 outcome, referenced by §11),
`SDRAM_REWORK_PLAN.md` (memory-subsystem rework roadmap — R9 outcome,
referenced by §9.2), `ODT_RISCV_REVIEW.md` (v0.1→v0.2 rationale + fact
corrections), `ODT_CHANGE.md`
(pivot handoff, historical), `REQUIREMENTS.md` item 1 (this design is its
detailed spec — traceability note added there), `HARDWARE.md` (I/O map; must
be updated when this lands).

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
   *dual-personality* — also readable by guest programs as IMSAI-style sense
   switches ($FC–$FF), and the encoder is an accumulate-and-commit menu
   selector ($FB preview). The monitor firmware shadows and can extend the
   panel but is not required for panel operation `[decided]`.
3. `[new v0.3]` **HDMI console (later phases)** — P2 mirrors monitor text
   onto the SBC terminal; a later phase adds an exclusive HDMI + PS2-keyboard
   monitor console, selected by OSD or by a serial command. Monitor I/O
   routing is firmware policy over hardware muxes; serial stays the
   fail-safe default surface (P-B).

Machine capabilities (unchanged core list): stop/go/step at instruction,
machine-cycle and T-state granularity; logical (guest/MMU) *and* physical
(28-bit) examine/deposit; mastered I/O; read-only register snapshot (write-
back P3); 4 breakpoints; 16-entry jump ring; MMU map view; `[new v0.3]`
unassembler, search, I/O traps, HBIOS page-table decode and scripted
sequences as first-class FW features; `[new v0.3]` guest→monitor mailbox
$D0–$D3 as the seed of HBIOS cooperation.

### Non-goals for v1
- Z80 register writes / resume-at-modified-registers (D-02; `[deferred]` P3).
- Monitor bus mastering while the guest runs (P-A). Background *physical
  reads* via the SDRAM vid port are the sole sanctioned concurrent access.
- HPS/network remote console (`[deferred]` P3+); graphical video frame
  buffer for monitor output (§14 OQ-15, later alternative to ANSI terminal).

---

## 2. Decision Log

| # | Decision | Notes / alternatives rejected |
|---|---|---|
| D-01 | `[decided]` Serial console SNAC mux: `monitor_owned = OSD OK(bit20) ∧ FW CTRL.console_own`; guest forced to Console Port while owned; untouched passthrough otherwise; hardware `OK`/S32-off forces release (P-B). Ratified in session R4. | bit-bang shared UART; passive-snoop-only |
| D-02 | `[decided]` Registers read-only in v1; `G aaaa`/START = trampoline (§7.4) after reset-vent; context loss accepted (session R2); write-back `[deferred]` P3. | invasive T80 write datapath (rejected) |
| D-03 | `[decided, revised v0.4]` Front panel = **32 address/mode toggle switches (S31..S0)** + **SPDT momentary function switches** (8 two-way = 16 lines, §11.2) + quadrature encoder w/push + escape/disable toggle, SNAC bridge board (74HC165 frame). Toggle bank has **dual personality**: panel-engine input *and* guest sense switches ($FC–$FF, D-05). Function **execution is hardware** (panel engine, D-18). Electrical/board freeze at bridge-board design (OQ-09). | 64-switch bank (v0.1, retired by R5/R7 layout); FW-only panel (v0.2 — superseded by session R5/R6); matrix keyboard |
| D-04 | `[decided, session R5]` **$D0–$D3 guest→monitor mailbox allocated**: guest writes mirror to bridge `MBX0..3` + raise monitor IRQ; guest reads return the mirror (never stalls). 0xD4–0xDF, 0xE0–0xEF reserved. | reserved-for-later |
| D-05 | `[decided, revised v0.4 (R7)]` Guest **sense-switch ports** at the top of the port space, IMSAI-style: **$FF = S31..S24** (mode byte, incl. bit7=S31 PHYS), **$FE = S23..S16**, **$FD = S15..S8**, **$FC = S7..S0** (also the DEP data byte), **$FB = encoder menu counter** (§11.6). Reads return debounced state from hardware — zero FW dependency (P-B). **$FF write still drives `fpLatch`** LED latch (`MicrocomputerZ80CPM.vhd:~570`); $FF *read* repurposed from `fpLatchDataOut` (no guest reader exists — §3). $F8–$FA reserved. | 8-byte $F8–$FF window for a 64-switch bank (v0.1/D-05-original); FW-served sense reads |
| D-06 | `[decided]` Jump-history ring P2: T80 `CTEV*` side-band + 16-entry HW ring + FW `J` + lamps. | SW-only trace (can't keep up, §4.3) |
| D-07 | `[decided]` Panel START runs at the live switch-set address. | two-phase LOAD-then-RUN |
| D-08 | `[decided]` MC/TS port-out on `T80s` + bundled **`Alternate` export** (session R3; closes OQ-01) in the same P1 mod; `CEN` already ported. T-state/Mcycle step via bridge `STEP_CTL`. | BUSRQ-only stepping |
| D-09 | `[decided, session R1]` Support core = **VexRiscv** (SpinalHDL, vendored generated Verilog, pinned config + regen script; sbt not run on tycho), **P0 Quartus-17.0 synthesis gate**; documented fallback **PicoRV32** (architecture is core-agnostic; only `crt0.S` + cycle budgets change). | femtoRV primary; spike-both |
| D-10 | `[decided, session R1]` **64 KiB ROM / 64 KiB RAM** (parameterized; final gate = P0 `fit.rpt`). **"ROM" is downloadable**: M10K block read-only to the RV, write port fed by the OSD download path; factory contents from committed init hex; downloaded contents persist across core resets within a session (full FPGA reconfig restores factory). | 16K/16K; refit-required ROM |
| D-11 | `[decided]` Bridge MMIO base `0x2000_0000`, 4 KiB, word-aligned SimpleBus, slave may stall (late resp.valid). | 32-byte region |
| D-12 | `[decided]` Formal invariants **P-A..P-D** (§2.5) + named guidance notes G-1..G-7 (session R2/R6: A–C formal per owner; P-D promoted R6). | notes-only |
| D-13 | `[decided, revised v0.3]` **Two-tier watchdog** (session R2): **WDG_RUN** (`[new]` transient holds — WAIT asserts, trap stalls, sequencer busy — auto-release guest, default **~4 ms**, parameterized) and **WDG_PARK** (~1–2 s, governs *FW-originated* parks only: expiry demotes a dead FW console — `console_own←0`, dead-flag lamp — but **never releases a hardware-held park**: classic STOP/BP park semantics stay human-paced and panel-recoverable). §6.9. | single 1.3 s auto-release (v0.2) |
| D-14 | `[decided, session R4]` RX byte at monitor UART while guest runs = hardware escape-break (auto-BUSRQ, reason=escape). | FW-poll escape |
| D-15 | `[decided, revised v0.3]` Physical memory: **(P) parked client** `mon_mem_client` borrows the *wiring* — drives the existing SDRAM client interface (`sdram_addr/din/we/rd` + native DQM) and BRAM mux only while guest parked *and* primary client FSM idle; MMU registers untouched (P-D). **(B) background** vid-port client (P2): **reads only** — natively read-only, verified lowest priority (cpu > vid, refresh > both); vid-*write* mod deferred, revisit gated on sim showing vid traffic benign to the primary path like refresh collisions (session R3). | ~~MMU direct-access ports $B8–$BC~~ **retracted**: auto-increment pointer is guest-owned state (session R3) |
| D-16 | `[decided, revised v0.3]` OSD allocations: `OK`=bit 20 (`OL`=21 reserved); download index **6 = `MROM` monitor ROM image**, index **7 = `MPKG` FORTH program pack**. MROM mount completion pulses **monitor-subsystem reset only** (RV+bridge+WDG re-arm; guest untouched, session R2). `OF` Reset-after-Mount semantics unchanged (guest). | guest-wide reset on mount |
| D-17 | `[decided, revised v0.3]` Lamp display philosophy (session R5): LEDs are a **flexibly-mapped signalling lamp array**, *not* a low-res graphics surface; no assumed correspondence with terminal text. Convention: monitor exports state words into the capture chain (§11.4); **profile 7 = monitor profile**; map_ram maps lamps to any chain bits (existing capture bits and/or monitor-exported bits); OSD profile-override engages profile 7 while monitor display active. Direct color/fb painting remains available for FW extensions. | dedicated monitor framebuffer; "text mirror" lamp pages |
| D-18 | `[decided, new v0.3]` **Hardware panel engine** (`fp_engine`): classic panel operations execute in FPGA logic through the shared bridge primitives (sequencer, step assist, reset stretcher, bus muxes), maintaining live **AR/DR/MD/PR** functional registers that FW reads/writes too. Panel works with FW absent/hung (P-B strengthened). FW and panel are **peers on one engine**; the sequencer busy-handshake is the arbiter; panel wins simultaneous kicks; panel ops event FW (IRQ + last-op log). | FW panel server as sole executor (v0.2) |
| D-19 | `[proposed, new v0.3]` Console routing is FW policy over HW muxes: `CONN_ROUTE` selects monitor output sink(s) {SNAC UART, HDMI terminal mirror} and input source {SNAC RX, PS2 kbd (P3)}; hardware default = serial on reset/WDG-death (P-B). | fixed serial-only routing (kept as fail-safe default semantics) |
| D-20 | `[decided, session R1]` Core facilities: **RV32IMC** (no A — single hart, state read via bridge regs), **1 MHz machine timer**, external IRQ dispatched by reading bridge `IRQ_PENDING` (no PLIC, no `mcause`-specific code; portable to fallback core). | IMAC; mcause/vectored |
| D-21 | `[decided, session R1]` **Code is data lifecycle**: monitor boots before/independent of guest image; ROM image (index 6) and FORTH pack (index 7: text source staged in DTCM, auto-`EVAL`'d at boot, magic+length trailer; position-independent, survives kernel rebuilds) both OSD-loadable; serial upload path (P2) reuses the same "eval a buffer" primitive. No NVRAM machinery in v1. | refit-per-change; battery-backed dict (deferred OQ-13) |
| D-22 | `[decided, session R5]` Addressing is **modal** on both surfaces: logical (MMU-translated, 16-bit) ⟷ physical (28-bit). FW keeps a live MMU shadow from the `mmu_frame` HW tap (state-neutral) and can translate/report either view; serial mode command (`PHY`/`LOG`); panel physical mode = **S31 = '1'** (§11.2). | single addressing mode |
| D-23 | `[decided, new v0.5 (R8)]` Panel UX package (full spec `ODT_PANEL_UX.md`): sovereignty-with-`PANEL_LOCK` (G-8) · S28=**BP ARM** (LOAD-ADDR also sets BP at encoder-cursor slot), S29=**FREEZE**, S30=**START-AT-A** (hardware trampoline start, firmware-free — closes D-07 panel gap) · per-page lamp remap with pinned chrome + page-ID lamps (G-9; cold default = identity ⇒ CLASSIC) · encoder: hold-cursor after commit, rapid double-press zeroes (no commit) · hybrid `*` commentary · colour conventions · WDG-dead ⇒ page forced to CLASSIC, lock cleared. | static-map/paged-content (rejected R8 in favour of per-page layout); unconditional RUN; zero-after-commit; queue-only or silent commentary |

### 2.5 Principles

**Formal invariants** — every RTL change must state which invariants it
touches; violations block merge.

- **P-A — Park before master.** No Z80-bus mux flip (address/strobe/data
  injection) unless `BusAck` confirmed asserted. Sole exception: vid-port
  SDRAM reads (§9.2-B), which never touch the Z80 bus.
- **P-B — Guest independence.** Guest-visible behaviour (reset/hold defaults,
  $F8–$FF sense, $FF latch, console passthrough, and `[new v0.3]` the entire
  classic panel engine) is correct and recoverable with the support CPU held
  in reset or hung. OSD `OK`-off / S32 escape force all monitor controls
  inactive in hardware.
- **P-C — MMIO is policy, never timing.** Any function whose correctness
  depends on a Z80 cycle boundary lives in the bridge: BP match, step
  assist, reset stretch, escape break, trampoline one-shot, wait/trap
  releases. §4.3 gives the arithmetic.
- **P-D — State-neutral observation** `[promoted, session R6]`. Monitoring
  never mutates guest-owned hardware state: observe via side taps
  (`REG`, `mmu_frame`, bus mirrors), dedicated mirror/export registers, or
  the monitor's own arbitrated client. Concretely: no gratuitous guest
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
- **G-4 Guest stall budget.** Transient monitor holds ≤ **~4 ms**
  (WDG_RUN-enforced). FW parks are laxed-but-timed (WDG_PARK); hardware-
  held parks (STOP/BP) are human-paced by design. A long monitor-side
  *computation* (big dump) is fine as long as it does not hold the guest.
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
| `clk_sys` = 50 MHz; `clk_ram` = 112 MHz (100 fallback); `cpu_cen` 1-of-5 → T80 at 10 MHz | `MrZ80.sv:~238, 505-535`; `MicrocomputerZ80CPM.vhd:~322-326, 1168-1173` |
| `ClkEn <= CEN and not BusAck` (all progression CEN-gated); `BusReq_s` sampled each CEN edge; park at `T_Res`; while parked CEN pulses do nothing | `T80.vhd:~344, ~968, ~1033-1044` |
| `CEN` already a `T80s` port; `MRD_T1` already exported; `MCycle`/`TState` still internal (P1 mod per D-08, now also exporting `Alternate`) | `T80s.vhd:~67-99, 128-135` |
| **T80 outputs FREEZE (not tri-state) during hold** — mastering = explicit muxes (G-2) | grep `'Z'` in `Components/Z80`: 0 hits; `cpuAddress` `:147/366`; `cpuDataIn` mux `:~875-883` |
| Halted guest refetches `76h` → R drifts; PC = next-to-execute after park; 212-bit `REG` (no `Alternate` — exported by D-08 mod from P1); `Jump`-covers-RET (no distinct `Ret`) | `t80_reg_debug_vector.md` §1; `T80_MCode.vhd:~110-127, 1905` |
| MMU 4×16 KB frames, `physical_page_bits => 14` (28-bit/256 MB); SDRAM pages 0–8191, BRAM page 8192 @ `0x8000000`; **MMU direct-access pointer ($B8–$BB) auto-increments ⇒ guest-owned state — monitor must not touch (P-D, D-15 retraction `[new v0.3]`)** | `MMU.vhd:~162, ~293-337`; `HARDWARE.md:~180`; `REQUIREMENTS.md:~37-41` |
| No boot ROM / `n_RomActive` (removed); CPU held in reset until HPS BIN load — trampoline sequencing only interacts with the reset *hold* | `REQUIREMENTS.md:~598-601`; `MicrocomputerZ80CPM.vhd:~98, 143, 337-343, 385` |
| I/O windows in use: $70-71, $80-83, $88-97, $A0-A7, $B0-BF, $C0-CF, $FF ⇒ $D0-D3 (now mailbox, D-04), rest of $D0–$DF/$E0–$EF/$F0–$FE free. **$FF read path currently returns `fpLatchDataOut`** (`cpuDataIn` mux `:~879`) — repurposed to the sense top byte per D-05/R7 (read-safe: no existing guest reader, verified); `$FF` **write** latch behavior preserved | decode `MicrocomputerZ80CPM.vhd:~841-850` |
| SDRAM `sdram_32r8w`: refresh > **cpu** > **vid**; vid port read-only (no DQM), 16-bit granularity (`A0` lane on cpu path); ack/ready mirrors cpu port; existing clk_sys↔clk_ram client-FSM pattern to copy | `sdram2.sv:~300-359, 67-76, 321-334`; `MrZ80.sv:~261-326`; vid tied off `MrZ80.sv:~354-356` |
| Capture chain **output-only**, `CHAIN_BITS => 384`, head 24 bits = `cpuAddress & cpuDataIn` — ample headroom for the 64-bit monitor export (§11.4) `[new v0.3]`; no switch-input HDL yet (OQ-09) | `MicrocomputerZ80CPM.vhd:~650, 713`; `Hardware/README.md:~28` |
| `FP_RAM_Store`: 8 profiles × (color 48b / map 8b) + global fb bit; Port A = single R/W owner (today Z80 `$A0–$A7`), Port B = refresh controller; `pri_ram` profile-file shadow precedent; OSD profile override `fp_osd_profile` | `FP_RAM_Store.vhd:~45-80`; `MrZ80.sv:~981-985` |
| SNAC io0/io1 = RX/TX (existing mux `status[12]`), io2/io3 RTS/CTS, io6 = WS2812, **io4/io5 free both directions** (SW[1] I2S caveat); open-drain mechanics | `MrZ80.sv:~212-221, 698-750`; `sys/sys_top.v:1634-1640` |
| CONF_STR bits in use 0, 9–11, 12, 13, **14 (`OE` flow — bit14 not free)**, 15, 16–19; download idx 1/2/5 used, 3/4 reserved ⇒ **6/7 allocate for MROM/MPKG (D-21)**; `OK`=bit20 valid | `MrZ80.sv:~382-408` |
| Baud divider table exists (`O9B`, 115200…2400) — monitor UART takes the same select (session R4) | `MrZ80.sv:~763-764` |
| 5 `clk_sys` per T-state; Mecrisp word ≈ 200 ns > one T-state ⇒ §4.3 split arithmetic | derived |

---

## 4. System Architecture

### 4.1 Block diagram (v0.3)

```
 clk_sys 50 MHz (single domain; only the vid-port window crosses to clk_ram)

 SNAC io0/io1 ◄──► console mux ◄─┬─ guest ACIA path ($82/$83)          [default]
   HDMI kbd (P3) ────────────────┴─ CONN_ROUTE (D-19) ─► mon_uart ◄┐
 SNAC io4/io5 ◄──► fp_capture ─► fp_engine (hardware classic console)│[new v0.3]
 USER_OUT[6] ◄──── WS2812 PHY ◄── refresh ctrl ◄── FP_RAM_Store ◄─┐│
                                                                   ▼│
 ┌──────────────────┐   SimpleBus   ┌────────────────────────────────────────┐
 │ VexRiscv RV32IMC │──cmd/ack────►│ dbg_bridge @ 0x2000_0000 (4 KiB)      │
 │  ROM 64K (OSD-   │◄──mon_irq────│ CTRL·STATUS·STEP·BP·TRAP·MD·AR·DR·PR   │
 │   downloadable)  │              │ MEM-SEQ engine (one door: FW ⇄ panel)  │
 │  RAM 64K         │              │ SNAP/LIVE REG · MAP0..3 (mmu tap)      │
 │  µs machine timer│              │ MON-CHAIN export(64b)·MBX·CONN_ROUTE   │
 └──────────────────┘              │ WDG_RUN(4ms)+WDG_PARK(1-2s)·IRQ·ID     │
                                 └──┬──────────────────────────────┬──────────┘
                                  │ busreq/wait/stretched-rst/     │ A·RD/WR/MREQ/IORQ
                                  │ cen_gate·tramp·escape          │ mux sel + DI inject
                                  ▼                              ▼
                    T80s (CEN · MC/TS/ALT export · REG[211:0] · CTEV* P2)
                                  │
        memory system: MMU (untouched by monitor, tapped only) · BRAM mux ·
        SDRAM client FSM ── mon_mem_client (parked physical, borrows wiring) ──┐
        sdram2 vid port ◄── mon_sd (P2 background READS only) ─────────────────┴─ clk_ram CDC
```

### 4.2 Module list

| Module | Responsibility |
|---|---|
| `Components/RISCV/VexRiscv.v` + `.qip` | Vendored core (D-09); `gen/VexRiscvConfig.scala` + `regen.sh` + pinned generator hash committed |
| `monitor/rtl/mon_top.v` | Subsystem wrapper: core + ROM + RAM + decoder + `mon_uart` + `dbg_bridge`; sideband bundle to CPM; `mon_irq` out; guest controls out; `MON_CHAIN[63:0]` export |
| `monitor/rtl/dbg_bridge.v` | §6 register file; shared functional registers (MD/AR/DR/PR); MEM-SEQ engine + arbiter; STEP assist; BP/trap; WDG×2; IRQ; ID |
| `monitor/rtl/mon_uart.v` | 8N1 UART, divider select from `O9B` table index (D-22 session R4); RX FIFO (8) `[proposed]`; RX-byte → escape-break + IRQ |
| `monitor/rtl/fp_capture.v` | 68-bit shift-in, debounce (4-sample ~2 ms), quadrature/press decode, menu-counter (+commit latch), frame-error detect; single source of truth feeding `fp_engine`, bridge mirror regs, **and** the guest sense-port mux ($FC–$FF/$FB, §11.6) |
| `monitor/rtl/fp_engine.v` | **Hardware classic-console executor** (D-18, §11.3): SPDT command decode, AR/DR/MD/PR state, auto-increment, kicks MEM-SEQ/STEP/RESET primitives, lamp-state outputs; event+log to FW |
| `monitor/rtl/mon_mem_client.v` | Parked physical SDRAM/BRAM client (D-15-P): drives existing client interface + BRAM mux while guest-parked ∧ primary client idle; native DQM byte lanes |
| `monitor/rtl/mon_sd.v` | (P2) vid-port background READ client; clk_ram CDC per existing pattern |
| `monitor/fw/*` | Mecrisp-Quintus build: `crt0.S`, linker, kernel glue, ODT app sources → `forth_rom.hex` (factory ROM init image) + pack files |

Integration: `mon_top` instantiates at `MrZ80.sv`; `fp_capture`+`fp_engine`
+`mon_mem_client` live at the CPM-core boundary (signals available:
`cpuAddress`, strobes, `cpuDataIn` mux point, `reset_n_internal`,
`cpu_cen`, BRAM mux, SDRAM request signals); chain export appended at the
capture-chain input; `FP_RAM_Store` Port-A ownership mux (§11.5).

### 4.3 Split arithmetic (why this and not more FW) `[decided]`
50 MHz vs 10 MHz Z80 ⇒ 5 `clk_sys`/T-state; a Mecrisp word ≈ 10 instr ≈
200 ns > one T-state; SimpleBus round-trip ≈ RV-side stall. Human-speed
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
RV32IMC · no caches/MMU · ITCM/DTCM tightly-coupled · machine mode ·
1 MHz machine soft-timer · external IRQ input (level from `|IRQ_PENDING`) ·
SimpleBus master with stall-tolerant slave contract · reset = `locked ∧
core_reset ∧ !mon subsystem_reset` (monitor up **before** any guest image).
No JTAG plugin (UART *is* the debugger). Fallback: PicoRV32 (§5.6).

### 5.2 Memory map
| Range | Content |
|---|---|
| `0x0000_0000–0x0000_FFFF` | "ROM" — 64 KiB M10K, **RV read-only**; download write-port (ioctl route, only while monitor held in reset during mount); factory init from committed `monitor/fw/forth_rom.hex`; downloaded image persists across core resets, full FPGA reconfig restores factory (D-10) |
| `0x1000_0000–0x1000_FFFF` | DTCM RAM 64 KiB byte-enable: BSS + dictionary + **pack staging** (§5.5) |
| `0x2000_0000–0x2000_0FFF` | `dbg_bridge` (§6) |
| else | decoder error → `resp.error`; FW trap word prints |

### 5.3 Console UART
8N1; divider = existing `O9B` table select (single baud truth for the SNAC
connector, session R4; 115200 = ÷27 from 50 MHz ⇒ +0.47 %). No RTS/CTS for
the monitor (G/decision R4): TX blocks on ready, RX FIFO drains via IRQ or
poll. Escape-break on first RX byte while guest runs (D-14, HW).

### 5.4 Downloadable ROM & packs (D-21)
- `MROM` (index 6): RV32 image `monitor/fw` build output (`forth.bin`→
  `forth_rom.hex` factory-committed; `.bin` mountable at runtime). Mount
  streams over ioctl into the ROM-RAM; **on mount-complete: monitor-
  subsystem reset pulse only** — RV boots new image; guest untouched (D-16).
  Image self-ID via header at ROM+0 (`'MRZM'`, version, CRC); FW `V` reports.
- `MPKG` (index 7): **FORTH source pack** staged to a reserved DTCM region
  (top-of-RAM staging, default 8 KiB, final size at P0), trailer
  `{magic 'FPAK', len, name[8]}`; FW boot scan auto-`EVAL`s packs present
  (position-independent text; robust across kernel rebuilds). Same primitive
  backs serial paste/XModem upload (P2). Binary dictionary overlays possible,
  not v1.
- Dictionary (RAM) contents lost on monitor reset; recovery = re-mount packs
  or serial re-upload; "workstation" persistence ideas → OQ-13 (deferred).

### 5.5 Firmware structure (Mecrisp-Quintus)
`crt0.S` trap vector → Forth dispatcher; stack-register convention verified
against the chosen port during P0 (was OQ-09b — P0 checklist item, carried).
Glue primitives: `serial-key?`, `serial-key`, `serial-emit`, `milliseconds`.
IRQ dispatcher on `IRQ_PENDING`: bp→halt line + REPL; trap→log/release;
fpevent→panel-op mirror update (comments, disassemble-last); rx→escape;
wdg→console-dead report. Main loop: parked→REPL `.`; running→background
(pump panel mirror, service traps, kick both WDGs, `CONN_ROUTE` service).
`F`⇄`ODT` raw-Forth / ODT-skin switch (session posture: ODT syntax is a
skin over a scriptable core).

### 5.6 Toolchain & fallback
Vendored generation (pin + regen script committed); **P0 = full tycho
Quartus 17.0 synthesis spike** for `5CSEBA6U23I7` incl. Mecrisp hello-world
on the UART + `fit.rpt` headroom capture. If P0 fails on VexRiscv-specific
grounds → PicoRV32 drop-in (identical bridge/FW; `crt0.S` rewrite; ~1 IPC
acceptable). Fallback decision recorded in P0 exit note.

---

## 6. Debug Bridge (`dbg_bridge`) — MMIO map (v0.3)

Base `0x2000_0000`, word offsets, 4 KiB. `[shared]` = also driven/updated by
`fp_engine` (G-3: single door, dual controllers).

| Off | Reg | Acc | Description |
|---|---|---|---|
| 0x00 | `ID` | R | `0x4D52_5A03` rev-stamped |
| 0x04 | `CTRL` | RW | bit0 `z_rst_n` · bit1 `z_busreq_n`(FW hold) · bit2 `z_wait_n` · bit3 `cen_gate` · bit4 `tramp_en` · bit5 `esc_break_en` · bit8 `console_own` · bit9 `panel_lock` (G-8: gates panel RUN/START only; auto-clears on WDG_PARK expiry/escape/OK-off/MROM mount); **forced inactive when `!mon_active`**; park sources = FW hold ∨ engine stop-latch (D-13) |
| 0x08 | `TRAMP_ADDR` | RW | `G aaaa`/START target |
| 0x0C | `STATUS` | R | `BusAck, HALT_n, M1_n, MC, TS, ALT (new P1), cpu_running, mon_active, s32, fw_console_ok, eng_stop_latch, seq_busy, wdg_dead` |
| 0x10 | `HALT_REASON` | R/clr | §10.4 codes (+`wdg`) |
| 0x14 | `PC_LATCH` | R | match/park PC |
| 0x18–0x30 | `SNAP_REG0..6` | R | `REG` frozen at park/match instant (R-snapshot discipline) |
| 0x34–0x4C | `LIVE_REG0..6` | R | combinational `REG` (meaningful parked) |
| 0x50 | `STEP_CTL` | RW | `{mode: off·INSN·MCYCLE·TSTATE×n, n}` (P-C) |
| 0x54–0x60 | `BP0..BP3` | RW | `{en, addr}` |
| 0x64 | `BP_SKIP` | RW | suppress-next-match mask (`C`) |
| 0x68–0x70 | `TRAP_CTL/ADDR/DATA` | RW | I/O trap `{en, wait_stall, rnw}` / port / `{mask, val}` |
| 0x74 | `MEM_CTL` | RW | **shared engine kick**: `{start, rnw, is_io}`; busy/done/timeout readback — arbitrated: panel-op-in-progress blocks FW kick, else panel wins simultaneous kick (engine priority) |
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
| 0xC0 | `IRQ_EN` / 0xC4 `IRQ_PENDING` (W1C) | RW | `bp0..3, trap, rx, fp_done, map_changed?, sd_done, wdg_park` |
| 0xC8 | `CONN_ROUTE` | RW | `{out_snac=1 default, out_hdmi(P2), in_snac=1 default, in_kbd(P3)}` — FW policy, HW fail-safe defaults on reset/`wdg_park` (D-19) |
| 0xD0–0xDC | `MBX0..3` | RW | guest mirror ($D0–$D3); guest write → IRQ `fp_done`-class new bit `mbx` |
| 0xE0–0xEC | `MAP0..MAP3` | R | **MMU frame tap**: `{valid, page[13:0]}` ×4 — FW translation shadow, state-neutral (P-D) |
| 0xF0 | `MON_CTRL` | RW | `[shared]` chain-export control: `{enable, page}` — selects which 64-bit state block feeds `MON_CHAIN[63:0]` (§11.4); panel engine writes `page` on encoder commit (D-23); WDG_PARK expiry forces `page←0` |
| 0xF4 | `LED_ADDR` | RW | profile-7 map/colour/fb write address (forwarded to `FP_RAM_Store` Port-A via ownership mux, §11.5) |
| 0xF8 | `LED_DATA0..2` | RW | map entry (≤10b) / colour (R,G,B) / fb bit per write-type select — FW rewrites profile-7 **map per page** (G-9); cold default = identity map ⇒ CLASSIC layout free |
| 0x100 | `FP_SW` | R | debounced toggle bank `{S31..S0}` — same source driving guest ports $FC–$FF (single source of truth, §11.6) |
| 0x104 | `FP_FN` | R | live debounced SPDT function-line levels (16 lines, §11.2) — FW snoop of panel activity |
| 0x108 | `FP_ENC_CNT` | R | menu-selection counter — same source as guest port $FB (§11.6) |
| 0x10C | `FP_ENC_STAT` | R/W1C | `{committed[7:0](15:8), page_id[2:0], dbl_zero_evt, commit_evt, press_evt}` — press commits page (cursor **held**, D-23); rapid double-press zeroes cursor w/o commit; FW may subscribe instead of polling |
| 0xFF0 | `DEC_ERR_COUNT` | R | unimplemented-offset counter |

`MON_CHAIN[63:0]` is a structural output of `dbg_bridge` (not MMIO-readable
necessity — FW can read its own writes): `{PC, AR, DR, PR, STATUS,
HALT_REASON, MD/eng flags, spare}` selected by `MON_CTRL.page`.

### 6.9 Two-tier watchdog (D-13)
`WDG_RUN` counts while any **transient** hold is asserted (`z_wait_n=0`
by FW/trap-stall, `seq_busy`, engine in-cycle): expiry → release the
transient hold, force `wait/stall` inactive, `err` on the operation,
`run_expiredL=1`, IRQ. Default 2²² clk ≈ **4 ms**.
`WDG_PARK` counts only while the sole park reason is **FW hold**
(`CTRL.bit1` set, `eng_stop_latch`=0): expiry → `console_own←0`,
**`panel_lock←0`**, **`MON_CTRL.page←0`** (D-23: lamps fall back to
CLASSIC), `z_busreq_n←1` (release **and** demote: FW presumed dead),
`park_deadL=1`, lamp flag, IRQ; re-arm on next FW write after re-kick. Default 2²⁶ ≈ 1.3 s.
Hardware parks (`eng_stop_latch`, e.g. STOP/BP) do **not** arm WDG_PARK:
classic semantics, released by panel RUN or escape (P-B).

---

## 7. Z80 CPU Control Semantics (v0.1 §5 carried; actor = FW or panel engine)

7.1 HALT: assert busreq (FW `CTRL` or panel STOP) → park at M-cycle `T_Res`;
self-consistent state; exact resume; R frozen by snapshot discipline.
7.2 S/T/X steps: `STEP_CTL` one-shot semantics (v0.1 §5.2 table) — panel
Step pair drives the same register.
7.3 RESET: panel *Reset CPU* / serial `A` → HW-stretched ≥8-`cpu_cen` vent
on `reset_n_internal`; monitor state persists; auto-repark after (examine
context). Panel *Reset System* = `hard_reset_req` path (OSD-equivalent core
wide reset incl. profile-clear; **excludes** FPGA config; exact scope OQ-10).
7.4 Trampoline (`G aaaa`, panel START): arm `TRAMP_ADDR`+`tramp_en`,
reset-vent, inject `C3 lo hi` at the first three fetches from $0000 (mux
select over `cpuDataIn`), auto-disarm; plain `G` = resume (never injects).
BP suppression during injection $0000–$0002 (OQ-05 lean carried: matches
suppressed while injecting).

---

## 8. Breakpoints & Jump History (carried)
§6 regs; semantics exactly v0.1 §6 (latched match PC reported, adjacent
first-match, `C`=skip-once) — halt reasons visible to FW **and** lamps.
Jump ring P2 per D-06/OQ-06 (explicit `Ret` in MCode; lean carried).

---

## 9. Memory & I/O Access Model (v0.3 final)

### 9.1 Logical — shared sequencer, guest reuse
One engine (§6 `MEM_CTL`) executes mem and I/O cycles **while parked**,
driving the guest's own nets (G-2 muxes) → MMU translate, BRAM/SDRAM route,
SDRAM wait handshake, peripheral decodes all reused. FW `E/D/F/I/O` and the
panel EXAM/DEP/Port-R/W are identical transactions modulo source (G-3).
`MD`=logical. State-neutrality (P-D): engine op cycles *may* touch guest
I/O (that is the point of port mastering) but never use the MMU
direct-access ports; frame state is read via the `MAP0..3` tap only.
AR auto-increment: engine policy for panel walks (`EXAM+`, `DEP+`); FW
commands update `AR` explicitly (both surfaces leave `AR` coherent, R-15).

### 9.2 Physical (28-bit)
- **P1 — parked client (D-15-P):** `mon_mem_client` drives the SDRAM client
  interface (`sdram_addr/din/we/rd` + DQM via `addr[0]`) and the BRAM mux,
  gated on: parked ∧ primary-client-idle ∧ no contention. Full R/W reach
  incl. BRAM page 8192. MMU bypassed (physical, by definition) and untouched
  (P-D). `MD`=physical makes `AR` 28-bit for both surfaces.
- **P2 — background window (D-15-B):** `mon_sd` client on the vid port,
  **reads only**; verified arbitration priority (refresh>cpu>vid) keeps the
  guest whole; acceptance = sim assertion suite showing vid traffic behaves
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
from monitor: `[deferred]` P3 (arbitration at tap, guest priority).

---

## 10. Monitor Software (Mecrisp-Quintus dictionary)

10.1 **ODT skin protocol** carried verbatim from v0.1 §10 (prompt `.`,
repeat-last, `$`/`.`/`;`, `?ER nn` atomicity, uppercase responses). `X`
escape (HW) + `F`/`ODT` skin switch.

10.2 **Command table** (as v0.2 §10.2 with these amendments):
- `PHY` / `LOG` — addressing mode select (`MD`) `[new v0.3]`
- `E/D/I/O` default via `AR/PR` shared registers; explicit-arg forms allowed
- `MB rd[,n]` / `MB wr,dd` — mailbox peek/poke `$D0..$D3` `[new v0.3]`
- `MON n` — select lamp state block (`MON_CTRL.page`) `[new v0.3]`
- `SW[.]` — dump 32-switch bank (bridge mirror); `ENC` — menu counter + last
  committed selection `[new v0.4]`
- `U` unassembler P1 (carried pull-forward); `S?` search P2; `TR` trap P2;
  `H` HBIOS page-table decode P2; `ME/MD` now native via `PHY`+`E/D` (and
  retain `ME p:aaaa` shorthand); `SD` background-block dump P2.
`R` format carried (now `Alternate` known from P1 ⇒ prime banks labelled
correctly, `'AF=`… line conditional on bank).

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
by the panel engine on command actuation *and* readable by guest programs as
sense switches ($FC–$FF, §11.6); **8 SPDT momentary function switches**
(center-off; each lever position = one function, 16 lines); **quadrature
encoder with push** (accumulate-and-commit menu selector, §11.3/§11.6);
escape/disable toggle; 256-lamp WS2812 array; SNAC bridge board (74HC165 ×N,
io4 clk-out, io5 data-in; `Hardware/README.md`, OQ-09). Frame: 68 bits
(§11.2); debounced in `fp_capture`, which is the single source of truth for
engine, bridge mirrors, and guest ports alike.

### 11.2 Switch & frame map `[decided conceptually, sessions R5/R6/R7; electrical freeze at board design]`

```
frame[31:0]   TOGGLES S0..S31 (guest-visible sense, §11.6)
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
frame[67:52]  spare (future: banked data entry, page-step, extra functions)
encoder       signed ±1/detent menu counter; PRESS commits (§11.3);
              first application: lamp-profile/state-page select (OQ-12: menu
              semantics list remains open; AR-nudge retired from encoder role)
```
Toggle bank values are latched by the panel engine **at command actuation**
(EXAMINE, LOAD ADDRESS, …) and are simultaneously live for guest reads —
there is no staleness question since both consult the same debounced source.

### 11.3 Panel engine behaviour (`fp_engine`, hardware)
Load Address: latch switchfield→`AR` (per `MD`) or→`PR`. EXAM: mem[`AR`]→`DR`
(display); EXAM-NEXT: `AR`++ then EXAM (walk). DEP: `DR ← switches[7:0]`;
mem[`AR`]←`DR`; DEP-NEXT: `AR`++ then DEP. Port pairs: same over `PR`/`DR`.
RUN/STOP: release / latch-stop (stop-latch = park source, §6.9). STEP pair:
`STEP_CTL` INSN/MCYCLE one-shots. RESET pair: §7.3 CPU vent / system-reset.
All ops kick the shared engine; `seq_busy` serializes vs FW; panel wins
simultaneity; completion pulses `IRQ.fp_done` + `ENG_LOG`. Errors
(e.g. engine-kick while not parked when required) latch `engine_err`, lamp
flag. Auto-increment policy lives here (human-speed; still hardware).
**Encoder (D-23/R8):** rotation accrues a signed cursor (page menu 0..7,
wrap); PRESS commits — sets `MON_CTRL.page` immediately (hardware content
swap + chrome page-ID), latches `FP_ENC_STAT.committed`, pulses
`commit_evt`; the cursor is then **held** (persistent index). A second press
within `T_w` (default ≈500 ms `[proposed]`) **zeroes the cursor** without
committing (`dbl_zero_evt`). FW optionally rewrites the profile-7 lamp map
on `commit_evt` for per-page layout (§11.4/G-9); with FW absent, commits
still switch content under the last map — degraded, never stuck.
**Modifiers (D-23):** S28 **BP-ARM** — while on, LOAD-ADDRESS(up) also
installs BP at `A[15:0]`, slot = committed cursor[1:0] (panel-settable
breakpoints — v0.1 §9.5 exclusion retired; panel BP *clear* gesture open,
UX-spec §4/§11). S29 **FREEZE** — latches `MON_CHAIN` export (chrome still
updates). S30 **START-AT-A** — while armed, RUN(up) executes hardware START:
`TRAMP_ADDR←A[15:0]`, `tramp_en`, stretched reset-vent, park release
(firmware-free, P-B; MD is display context only). Arm state → chrome lamps
M0–M2. **PANEL_LOCK gate (G-8):** while `CTRL.bit9` is set, RUN(up) and
START-AT-A are rejected (HALT-lamp flash, `lock_rejected` event/log);
STOP/EXAM/DEP/PORT/STEP/RESET/FREEZE/LOAD never gated; lock auto-clears on
WDG_PARK expiry, escape, OK-off, MROM mount.

### 11.4 Lamps — pages own content *and* layout (D-17/D-23, G-6/G-9)

`MON_CHAIN[63:0]` (bridge output, selected state block)
is appended to the 384-bit capture chain after the existing 24 live bus
bits. **Page = content + layout:** on any page change (FW command
auto-paging, encoder commit, WDG fallback), the **profile-7 `map_ram` is
rewritten** (FW via `LED_ADDR/LED_DATA`; cold default = shipped *identity*
map, which is exactly the CLASSIC layout — zero FW needed for page 0), and
`MON_CTRL.page` swaps the 64-bit export content. Chrome is invariant across
pages: modifier-arm lamps (S28–S30 arms + MD), status strip (RUN green /
HALT red / MON / CONSOLE_OWN / PANEL_LOCK amber / FW-alive cyan blink /
WDG violet), and 3-bit **page-ID** lamps — per `ODT_PANEL_UX.md` §2/§3
(zones A/M/B/T/D, colour table, page definitions 0–7: CLASSIC, CORE-A/B/C,
MMU, BP, MSG, SYS). FW-dead ⇒ content forced to page 0, map frozen, chrome
intact. Live bus bits remain mappable for authentic bus lamps. No text
rendering (G-6); page/layout/colour tables land in `HARDWARE.md`.

### 11.5 Port-A ownership mux (LED store)
`FP_RAM_Store` Port A select: {FP master controller (Z80 `$A0–$A7` path),
monitor FW route (via `mon_top` → `LED_ADDR/DATA` bridge regs)}. Z80-guest
writes win (rare, atomic); monitor writes proceed otherwise; profile 7 in
practice avoids overlap entirely (guest profile usage convention ≠ 7 —
enforced by convention, not interlock, noted).

### 11.6 Guest-visible sense & encoder ports (D-05, R7) `[decided]`

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
`fpLatchDataOut` — safe, §3 fact). Guest use: panel-state polling from
CP/M/CamelFORTH/HBIOS (switch-driven apps, mailbox pairing via $D0–$D3),
and self-test of the bridge transport. FW reads the same state via bridge
mirrors (§6: `FP_SW/FP_FN/FP_ENC_CNT/FP_ENC_STAT`) rather than port cycles
(state-neutral default); parked `IN` on these ports returns the same values
and is harmless if FW chooses it.

---

## 12. Resource / Timing / Integration

| Item | Estimate |
|---|---|
| VexRiscv IMC + TCM | ~4–7k ALUT; 16 M10K (64K+64K) — headroom confirmed at P0 (`fit.rpt`), shrink knobs = ROM/RAM generics |
| `dbg_bridge` + uart + capture + engine | ~3–4k ALUT (engine ≈ +0.5–1k over v0.2 estimate), ~2 M10K |
| `mon_mem_client` / `mon_sd` | ~1–1.5k ALUT total |
| Idle/disabled | `OK`-off ⇒ all monitor outputs static-inactive, muxes guest-side; RV quiescent (`WFI` between ticks; panel ops still serviced by engine — engine runs even when `OK`-off? **No**: `OK`-off disables monitor bus mastering incl. engine (bare-core equivalence, R-19); panel lamps/sense remain (guest-visible per D-05) |
| Clock domains | all new logic clk_sys; vid client = only new CDC (existing pattern); SNAC/UART async `set_false_path`; chain/encoder false paths as v0.2 |

Integration edit list (delta to v0.2 §12): `MicrocomputerZ80CPM.vhd` gains
`mon_mem_client` (BRAM mux + SDRAM-request arbiter point), `$D0–$D3` decode
+ mirror, **`$FB–$FF` sense/encoder decode (`n_fpSenseCS`; $FF read source
swap, write-side `fpLatch` untouched)**, engine mux participation,
`MON_CHAIN` append at chain input, Port-A ownership mux (§11.5). `MrZ80.sv` gains `MPKG`/`MROM` ioctl routing
(idx 6/7), `CONN_ROUTE` HDMI tap points (P2), monitor-subsystem-reset pulse
on MROM mount-complete, CONF_STR `OK`/`OL` + two file entries + profile
override extended value (profile 7 "monitor", OQ-12 detail). `T80s.vhd`
MC/TS + **ALT** port-out (P1), `T80.vhd` CTEV*/`Ret` (P2). `HARDWARE.md`:
mailbox, halt/error codes, switch map, lamp conventions, console ownership,
baud policy. `REQUIREMENTS.md` item 1: traceability note (done at this
revision). `monitor/fw`, `monitor/rtl`, `Components/RISCV` added to `.qsf`.

---

## 13. Requirements ↔ Verification (v0.3 set)

R-01…R-22 semantics carried (drivers = MMIO tasks / synthetic frames),
with:
- R-08 reworded: mastered cycles incl. frozen-output mux assertions +
  FW⇄panel simultaneity (panel-wins) + FW scripted-kick path.
- R-15 rewritten: **shared-register coherence** — `E 1234` (FW) then panel
  EXAM-NEXT ⇒ AR 1235, and converse (panel LOAD-AR then FW `E` uses it).
- R-19 extended: `OK`-off disables engine bus ops too; $FB–$FF sense/encoder
  ports still live (guest-visible per D-05).
- R-16 rewritten (R7): guest sense ports — $FC..$FF = toggle bank (top byte
  incl. PHYS bit at $FF), $FB = encoder menu counter; $FF write still drives
  `fpLatch`; all correct **with RV held in reset**; byte-order exact per
  §11.6 table.
New:
| Req | Statement | TB |
|---|---|---|
| R-23 | RV boots factory ROM init image; `V` header check | `tb_mon_smoke` |
| R-24 | WDG_RUN (≤4 ms transient auto-release) / WDG_PARK (FW-hold-only release + console demote) / engine-park unaffected | `tb_bridge_wdg` |
| R-25 | console mux default passthrough with RV in reset (P-B); `CONN_ROUTE` switch-over; fail-safe on `wdg_park` | `tb_mon_mux` |
| R-26 | vid-port reads benign to primary path (refresh-class latency envelope, zero corruption; guest whole during background sweeps) — **P2 gate** (session R3 criterion) | `tb_mon_sd` |
| R-27 | `mon_mem_client`: parked R/W vs BRAM page + SDRAM incl. odd-byte DQM; zero access while guest runs | `tb_mem_client` |
| R-28 | **panel engine standalone with RV held in reset**: full LOAD-AR/EXAM/DEP/PORT/STEP/RUN/STOP/RESET ritual functional | `tb_fp_engine` |
| R-29 | MROM mount → monitor-only reset (guest unaffected) + new image boots; MPKG auto-eval; factory restore on full reconfig | `tb_dl_path` |
| R-30 | mailbox: guest write→IRQ+mirror; guest read never stalls; FW `MB` roundtrip | `tb_mbx` |
| R-31 | FW translation shadow == live MMU maps across guest remaps (`MAP0..3` tap) | `tb_map_shadow` |
| R-32 | Encoder (D-23): cursor previews at $FB; press commits page (page-ID + `committed` latch) and cursor is **held**; rapid double-press (≤`T_w`) zeroes cursor without commit | `tb_fp_engine` |
| R-33 | PANEL_LOCK: gates panel RUN/START only; STOP/EXAM/DEP/PORT/STEP/RESET unaffected; auto-clear on WDG_PARK expiry/escape/OK-off/MROM mount; rejected attempt flashes + logs | `tb_bridge_lock` |
| R-34 | Per-page lamp remap: page change ⇒ profile-7 map rewritten + content swapped; cold default identity == CLASSIC layout; WDG-dead forces page-0 content, chrome intact | `tb_fp_led` |
| R-35 | Modifiers: BP-ARM LOAD also sets BP (cursor-slot); FREEZE latches export, chrome live; START-AT-A = trampoline+reset-vent+release, firmware-free | `tb_fp_engine` |
| R-36 | FW auto-paging per UX §3 table + `*` commentary (immediate idle / queued busy) golden script | `tb_fw_panel` |
R-21 unchanged and doubly load-bearing.

---

## 14. Open Questions

Closed this session: OQ-01 (ALT export P1) · OQ-02 (S31 + 28-bit map) ·
OQ-03 (no boot-ROM mux; MROM-reset settled D-16) · OQ-04 (context-loss
accepted, P3 write-back) · OQ-07 (bit 14 taken → OK=20) · OQ-08 (new map
redesigned; board freeze later) · OQ-14 ($D0 allocated) · OQ-16 (IMC/timer/
dispatch) · baud/flow/HDMI-direction settled (D-22/R4) · **OQ-12 + OQ-16b
(panel-UX deep-dive R8 → D-23 + `ODT_PANEL_UX.md`; residual values →
OQ-18)**.

| # | Question | Lean / notes |
|---|---|---|
| OQ-05 | BP at $0000–$0002 vs trampoline injection | Carried lean: suppressed during injection window |
| OQ-06 | `Ret` classification source for CTEV | Carried lean: explicit `Ret` in MCode |
| OQ-09 | Bridge board un-built: electrical freeze incl. SPDT parts, encoder, spare banks; sim now with synthetic frames (R-13) + SPDT pair encoding assumptions | P2 dependency, not P1 |
| OQ-10 | **Exact "Reset System" scope** — proposed: `hard_reset_req`-equivalent (guest + monitor + FP profile clear; not FPGA config). Confirm at board design. | needs owner confirmation |
| OQ-11 | vid-port **writes** revisit gate (D-15-B): after R-26 passes with reads; scope = `sdram2.sv` DQM mod; alternative = physical writes stay parked-only forever | revisit P3+ |
| OQ-18 | Board-freeze UX values (residual from R8): double-press window `T_w`; page-ID lamp encoding (binary vs one-hot); lock-reject flash pattern; **panel BP-clear gesture** (armed LOAD-down? serial-only v1?); debounce/heartbeat constants; LED physical zones vs switch geometry; S28–S30 silkscreen labels; spare bank (frame bits 52–67) future use | board design time; `ODT_PANEL_UX.md` §11 checklist |
| OQ-19 | Milestone-B scheduling: formal `sd_arb` extraction approved (R9) but unscheduled — proposal: dedicated refactor milestone after P2 green, before P3 polish work; confirm at P3 planning | `SDRAM_REWORK_PLAN.md` §6/§10 |
| OQ-13 | Dictionary persistence across monitor resets beyond re-mount (NVRAM region in SDRAM?) | deferred; packs re-mount deemed sufficient v1 |
| OQ-15 | Graphical frame buffer for monitor *video* output (vs 80×25 ANSI on SBC terminal), including exclusive HDMI+kbd console details (D-19 P3): font, pages, keymap | later-phase design note |
| OQ-16b | *(closed by R8 →* `ODT_PANEL_UX.md` v0.1*)* deep-dive held 2026-10-23: sovereignty/lock, pages, lamps, encoder, commentary, walkthroughs; second pass after first FP hardware experience | closed |
| OQ-17 | Doc naming: CamelFORTH (guest) vs Mecrisp (monitor) glossaries in `doc/` — two files naming | lean: `MONITOR-FORTH-GLOSSARY.md` new beside existing |

---

## 15. Phasing (ratified session R6)

| Phase | Scope | Exit |
|---|---|---|
| **P0** | VexRiscv vendored+P0 synth (Quartus 17.0, `5CSEBA6U23I7`) + Mecrisp hello-world + downloadable-ROM write path sim + `fit.rpt` headroom recorded + crt0 convention verified + fallback decision | clean synth, headroom numbers logged, Go/fallback |
| **P1 — console core** | bridge (regs incl. MD/AR/DR/PR, MAP0..3, MBX, WDG×2, ID), mon_uart (O9B divider), escape-break, STEP assist, reset stretcher, trampoline, MEM-SEQ (logical) + **`mon_mem_client`** (physical P/W), SNAC mux + MROM/MPKG mount path (monitor-only reset), T80s MC/TS/ALT export, FW: ODT skin + `G S T X K E D I O R A W V ? U F ODT PHY LOG MB` | R-01…R-09, R-12, R-19…R-25, R-27, R-29…R-31 green in sim; real-terminal bring-up (halt/dump/examine/step/G) incl. no-guest-image boot; panel *not* yet wired |
| **P2 — panel + assist** | `fp_capture`+`fp_engine` (+engine priority/log), new switch map live, guest sense/encoder port decode (§11.6, R-16/R-32), **D-23 UX package: BP-ARM/FREEZE/START-AT-A, PANEL_LOCK, per-page profile-7 lamp remap + chrome + page-ID (`ODT_PANEL_UX.md`), encoder hold/double-zero, `*` commentary**, BP/`C` (with panel BP-set), CTEV ring + `J`, traps, `S?/TR/H/P/SD`, `mon_sd` READ (R-26 gate), MPKG auto-eval polish, HDMI mirror (`CONN_ROUTE`), serial XModem | R-10…R-18, R-26, R-28 green; **RESET/DEP/START ritual from switches alone, RV held in reset**; panel-op mirror visible in FW |
| **P3 — polish** | T80 register write-back (retires trampoline), step-over, conditional BPs, `Y`, MMU writes from monitor, exclusive HDMI+kbd console (D-19), vid-write revisit (OQ-11), HPS path eval, mailbox protocol hardening with HBIOS | D-02 retired; all prior green |

> **SDRAM arbiter milestone (R9):** P1/P2 use additive borrowed-wiring
> clients (Option A) exactly as scoped above; formal `sd_arb` extraction
> (Option B) is approved future work scheduled after P2 green, outside the
> monitor critical path; no bursts, no block-transfer engine, loader
> streaming deferred — `SDRAM_REWORK_PLAN.md`.

---

## 16. Resume Checklist

1. `doc/t80_reg_debug_vector.md` (register/snapshot semantics) then this doc.
2. §17 decision log = authoritative deltas from v0.2; `ODT_RISCV_REVIEW.md`
   §2 for the fact corrections (freeze-not-tri-state, bit-14, 28-bit,
   cpu>vid arbitration, MMU auto-increment hazard).
3. Owner confirmations outstanding: OQ-10 (Reset-System scope), OQ-18
   (board-freeze UX values incl. panel BP-clear gesture), OQ-11/13/15
   (deferrals acknowledged); panel-UX second pass after first hardware.
4. P0 spike first, absolutely (tool risk gate; §5.6).
5. RTL order: bridge with task-emulated master harness → `mon_mem_client` →
   mux hookup only after `tb_bridge_*` green with gates stubbed transparent
   (R-21 discipline) → `fp_engine` standalone (R-28) → FW.
6. Update `HARDWARE.md` incrementally with each landed surface; keep
   `REQUIREMENTS.md` item 1 note current.

---

## 17. Decision Session Log (2026-10-22)

R1 **Foundation**: VexRiscv primary P0-gated (PicoRV fallback) · RV32IMC +
µs timer + pending-reg dispatch · 64K/64K · downloadable ROM (no refit) +
`MPKG` FORTH pack; factory init-from-hex; lifecycle = code-is-data.
R2 **Principles/safety**: P-A..P-C formal (owner: keep formal set small) ·
two-tier stall budget ("few ms to change memory; lax park timing") → D-13
redesign · D-02 accepted, write-back P3 · MROM mount resets monitor only.
R3 **Memory**: MMU direct-access path **retracted** (guest-owned
auto-increment) → `mon_mem_client` borrows wiring (P-D exemplar) · vid port
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

R8 **Panel-UX deep-dive (2026-10-23; spec → `ODT_PANEL_UX.md` v0.1)**:
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
