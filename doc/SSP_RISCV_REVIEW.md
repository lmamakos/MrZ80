# SSP_RISCV_REVIEW — Impact of the RISC-V/FORTH pivot on SSP_DESIGN.md

Status: **DRAFT v0.1** (2026-10-22). Review of `SSP_DESIGN.md` v0.1
(hardwired mon_core/mon_cli architecture) against the new approach in
`archive/ODT_CHANGE.md`: a VexRiscv RV32IMC softcore running Mecrisp-Quintus FORTH
as the debug monitor, reaching over to the T80 through a thin MMIO bridge
(`z80_bus_monitor`).

Owner direction during this review: **the front panel stays**, but it no
longer needs the full function set v0.1 hardwired for it — its behavior is
serviced by the support CPU; only cycle-critical plumbing stays in hardware.

Tags: `[verified]` (re-confirmed against source this review, anchor given),
`[carried]` (v0.1 content survives unchanged), `[rehosted]` (same behavior,
implementation moves hardware→FORTH or FORTH→bridge), `[superseded]`,
`[new]`, `[risk]`, `[decision]` (needs owner call before v0.2).

Companion docs: `SSP_DESIGN.md` (review subject), `archive/ODT_CHANGE.md`
(pivot handoff), `doc/t80_reg_debug_vector.md` (still normative),
`REQUIREMENTS.md` item 1 (the examine/deposit-port requirement this
architecture satisfies), `HARDWARE.md` (must gain the monitor windows).

---

## 0. Verdict

The pivot is sound and recommended. Roughly **half of v0.1 survives intact**
— and, notably, the surviving half is the *hard-won* half: the T80 semantics
(§3/§5), the halt/step/BP behavioral spec (§6), the console protocol (§10),
and the verification matrix (§12) are all **behavioral** statements that do
not care who executes them. What dies is the *implementation* split: the
FSM/console/CLI RTL (mon_core, mon_cli, ssp_uart, most of mon_fp, the
mon_mem logical path) becomes FORTH code, where it is cheaper, more
debuggable, and easier to extend.

Three things must **not** become software, at any clock ratio (see §1.2 for
the arithmetic): deterministic breakpoint capture, instruction/cycle/T-state
step assist, and bus arbitration under a watchdog. v0.2 should therefore be
structured as: *behavior spec inherited from v0.1 verbatim; mechanism spec
rewritten as "RISC-V + thin cycle-accurate bridge".*

The `z80_bus_monitor.v` sketch in ODT_CHANGE.md is directionally right but
is **monitor-only (passive)** today — it cannot examine, deposit, halt-step,
or reset-pulse to any useful semantics. Findings F-01…F-12 (§3) list what
must be added before it is a debug bridge rather than a bus scope.

---

## 1. Why the trade is good

### 1.1 What FORTH buys that v0.1 priced out or deferred

| Capability | v0.1 cost (RTL) | v0.2 cost (FORTH) |
|---|---|---|
| `U` unassembler (`[deferred]` P3) | state machine + ROM ≈ mon_cli-class module | ~1 page of code — **pull into P1** |
| Memory search `S aaaa,bbbb,dd`, fills with stride, port walks | P2 FSM work | words |
| RomWBW/HBIOS page-table decode, HBIOS trap analysis (ODT_CHANGE Task 3) | not even scoped | words reading ROM/SDRAM |
| Command repeat, error atomicity, help text, paging | P12 protocol FSM + ROM | REPL idioms |
| Conditional breakpoints, step-over (P3) | comparators + sequencers | `until`-style loops over the step-assist register |
| Programmatic sequences ("run 10k insns, dump regs") | n/a | scripts in the dictionary |
| File upload (XModem-ish on the monitor UART) | P3 | RX FIFO + word |

Plus the maintenance argument: every behavior change becomes a `.hex` swap
(ideally runtime-loadable, §9 OQ-RV-03), not a Quartus compile.

### 1.2 Why cycle-critical functions stay in hardware `[verified]`

`clk_sys` = 50 MHz (`MrZ80.sv:238`), T80 at 10 MHz via one-in-five
`cpu_cen` (`MicrocomputerZ80CPM.vhd:322-326, 1168-1173`) gives 5 `clk_sys`
per T-state. A Mecrisp word invocation is ~10 RV cycles ≈ 200 ns > one
T-state (100 ns). Polling the live-status register cannot deterministically
observe or react inside a T-state or even guarantee catching a single M1
window; it *can* comfortably catch human-speed events (keys, bytes, buttons
at ms scale). Consequence:

- **Breakpoints**: keep the v0.1 `mon_bp` HW matcher (M1-window compare,
  `cpu_cen`-qualified) with auto-BUSRQ + PC/REG latch + IRQ. FORTH only
  formats and policies. (v0.1 §6 semantics carried verbatim, incl. latched
  match-PC reporting and adjacent-BP/`C` skip via a `BP_SKIP` register.)
- **Step assist**: one MMIO write `{mode, n}` = INSN / MCYCLE / TSTATE×n,
  hardware releases BUSRQ and re-asserts at the correct instant (next M1,
  MCycle change, N `cpu_cen` pulses). v0.1 §5.2 semantics carried verbatim
  (R-02/R-03/R-04 stay testable).
- **Reset vent**: fixed ≥8-`cpu_cen` HW stretcher (v0.1 §5.3), not FORTH
  bit-banging.
- **Trampoline** ($0000 `JP aaaa` overlay, v0.1 §5.4): HW mux, FW-set addr
  + one-shot enable.
- **Bus arbitration**: busreq/wait/reset muxes live in the bridge; the RV
  can die and a watchdog (§5, P3-invariant) must free the guest.

### 1.3 New headroom the pivot exposes `[new]`

- **`z80_wait_n` (in the sketch, unused by v0.1)**: pause the guest inside
  its current M-cycle while the monitor does slow work. Safe to *pause*
  with WAIT; bus *inspection* still requires parking via BUSRQ (bus state
  mid-cycle is not self-consistent). Document as a two-tier stop: soft
  pause (WAIT, invisible, resumable, R keeps refetch-drift if HALTed) vs
  hard park (BUSRQ, snapshot). `[proposed]`
- **Trap-and-stall guest I/O** `[new]`: comparator on `io_wr` {port,
  value, mask}; on match raise RV IRQ and optionally hold WAIT until
  serviced — the cheap hardware basis for the "HBIOS traps / I/O write
  breakpoints" idea in ODT_CHANGE Task 3, without patching the guest.

---

## 2. Newly verified platform facts (this review)

Adds to / corrects v0.1 §3. These must land in v0.2's facts table.

| Fact | Anchor |
|---|---|
| `clk_sys` = 50 MHz (PLL `refclk(CLK_50M)`, `outclk_0`); `clk_ram` = 112 MHz default, 100 MHz fallback tap | `MrZ80.sv:238, 505-535` |
| **OSD status bit 14 is TAKEN** — `OE,Flow Control`. Bits in use: 0 (R0), 9-11 (O9B), 12 (OC), 13 (OD), 14 (OE), 15 (OF), 16-19 (OGJ). → v0.1 **OQ-07 resolved: `OK`=20 is valid** | `MrZ80.sv:382-400, 701` |
| Z80 windows in use: $70-71 RTC, $80-83, $88-97, $A0-A7 FP, $B0-BF MMU, $C0-CF timer, $FF latch. **$D0-$DF, $E0-$EF, $F0-$FE are free** — v0.1 D-04 windows confirmed available | decode `MicrocomputerZ80CPM.vhd:841-850` |
| **T80 outputs do NOT tri-state during hold — they FREEZE** (no `'Z'` anywhere in `Components/Z80`; `ClkEn` gating stops the registered outputs mid-value). The v0.1 §8.2 claim "CPU tri-states its bus while `BusAck='1'`" is **wrong for this soft core**. Monitor mastering must use **explicit muxes with a select**, never wire-OR, on `A[15:0]`, strobes, and the `cpuDataIn` mux (`:875-883`) | grep `Components/Z80` (0 tri-states); `cpuAddress` drivers `MicrocomputerZ80CPM.vhd:147, 366` |
| `CEN` is already a `T80s` port (local mod, default `'1'`) and `MRD_T1` is already exported (speculative-read work landed); `MCycle`/`TState` remain **internal** — D-08's MC/TS port-out is still an open small mod | `T80s.vhd:67-99, 128-129, 133-135`; `MicrocomputerZ80CPM.vhd:898-955` |
| MMU physical space is **28-bit** (`physical_page_bits => 14`, BRAM page 8192 = `0x8000000`). ODT_CHANGE's `mmu_phys_addr_in[26:0]` is a stale 27-bit width | `REQUIREMENTS.md:37-41`; `MMU.vhd:162-163` |
| MMU already exposes a **direct-access pointer/data** port (+8..+12 / +12) — physical inspection primitive exists on the guest side; monitor-side physical view is for when the guest is *not* runnable | `HARDWARE.md:180` |
| **`n_RomActive` / built-in boot ROM are gone**; boot source is HPS-loaded BIN only, CPU held in reset until loaded. v0.1 §5.4/OQ-03 trampoline mux conflict is therefore *much smaller than feared*: no competing boot-ROM mux; overlay only needs to win the first fetches after a reset-vent while `tramp_en` | `REQUIREMENTS.md:598-601`; `MicrocomputerZ80CPM.vhd:98, 143, 337-343` |
| SDRAM controller (`sdram_32r8w`) has a **second, currently-tied-off port** (`vid`): 16-bit-granular (A0=0), shared 16-bit `dout`, ready/ack handshake; refresh has priority over pending requests; **cpu-vs-vid arbitration priority not yet characterized** → ODT_CHANGE's "128 MB without stalling the T80" is plausible but unverified | `sdram2.sv:67-76, 300`; tied off `MrZ80.sv:354-356` |
| SNAC: io0 RX (input, `USER_IN[0]`), io1 TX, io2 RTS, io3 CTS-en, **io4/5/6 outputs free in the map** (`USER_IN[4:6]` unused) — io6 currently assigned to WS2812, leaving **io4/io5 for the 2-wire switch frame**, matching v0.1 D-03; SW[1] I2S hijack caveat stands | `MrZ80.sv:212-221, 743-750`; `sys/sys_top.v:1634-1640` |
| Guest serial path: `serial_rx` muxed console/SNAC by `status[12]` into the core's ACIA path (`rxd1/txd1` at `:1008`); bufferedUART is the guest's $82/$83 | `MrZ80.sv:698-750, 1008-1012`; `MicrocomputerZ80CPM.vhd:842` |
| No switch-capture HDL exists yet (capture chains are LED *output* only, 384-bit); the 74HC165 bridge board is still planned hardware — v0.1 OQ-09 carries over unchanged | `MicrocomputerZ80CPM.vhd:650, 713`; `Hardware/README.md:28` |
| FP LED plumbing: `$A0-$A7` window → `FrontPanel_Subsystem`, `fpLatch` at $FF, WS2812 out `USER_OUT[6]`; RAM store with own init sequencer | `MicrocomputerZ80CPM.vhd:846, 570`; `MrZ80.sv:744`; `REQUIREMENTS.md` item 3 |
| `REG` 212-bit export at `T80s` unchanged; `Alternate` still not exported (OQ-01 carries) | `T80s.vhd:116`; `t80_reg_debug_vector.md` §1.3 |

---

## 3. Findings on `ODT_CHANGE.md` (the pivot sketch)

Severity: **B** = blocker for the architecture claim, **M** = must-fix
before useful, **m** = clean-up.

| # | Sev | Finding |
|---|---|---|
| F-01 | **B** | **No bus-mastering path.** The module drives only `z80_reset_n/busreq_n/wait_n`. Examine/deposit/IN/OUT require driving `A[15:0]`, `MREQ_n`, `IORQ_n`, `RD_n`, `WR_n` and (for deposits) data-out — plus injecting read data into `cpuDataIn`. Combined with §2's freeze-not-tri-state fact, this is an explicit mux with select at the wrapper, not a bus-share. Add a **cycle sequencer** (kick/busy/done, addr, dir, io/mem, data-in/out) to the bridge. |
| F-02 | M | `mmu_phys_addr_in[26:0]` is a stale width; MMU is 14-bit page / 28-bit physical. |
| F-03 | M | **Sampling model wrong.** All Z80 bus signals are `clk_sys`-synchronous (CEN-gated), so the 3-stage synchronizers are unnecessary latency, and edge-detects that free-run on `clk_sys` sample away from the `cpu_cen` boundaries where the signals are valid. Follow v0.1 §11 discipline: qualify with `cpu_cen`. Also, latching `z80_data_bus` at the MREQ/IORQ *assertion* edge captures **stale** data for reads — data is valid later in the cycle. Latch reads at read completion; REQUIREMENTS item 3 documents this exact class of bug (`wr_pulse`/`rd_done_pulse`) and its fix — reuse that pattern. |
| F-04 | M | CTRL bits act combinationally and reset values are sensible (all inactive-high), but: reset-vent needs the ≥8-`cpu_cen` HW stretcher; `wait_n` needs the pause-vs-park doc (v0.1 §5 vocabulary); no `cen_gate` (kills the X/TSTEP granularity) and no trampoline control. |
| F-05 | M | Register set too small: no REG snapshot window (212 bits ≈ 7 words + live copy), no MC/TS status, no halt-reason, no BP/trap, no FP frame/LED, no memory sequencer (§ F-01), no SDRAM window, no watchdog, no ID/version. `bus_addr[5:0]` (64 B) must widen — propose a 4 KiB region. |
| F-06 | M | No **IRQ output** to the VexRiscv. Poll-only works but forces busy-looping during long dumps/pauses. Add one external-interrupt line (sources: bp, trap, rx-byte, fp-edge, sd-done, wdg) + `IRQ_EN`/`IRQ_PENDING`. |
| F-07 | m | SimpleBus is fine for the bridge, but the decoder/ack must tolerate wait states for slow clients (SDRAM-window reads take tens of cycles); `ack` may not be combinationally guaranteed. |
| F-08 | M | "128 MB inspection without stalling the T80" is an **unverified promise**: the second SDRAM port is the `vid` port (16-bit granularity, A0=0 → byte writes need HW read-modify-write; refresh priority; cpu-vs-vid arbitration uncharacterized, §2). Until characterized, restrict monitor SDRAM access to parked/idle windows, or accept and measure guest slowdown under background reads. |
| F-09 | M | 16 KB ROM / 16 KB RAM is tight: Mecrisp-Quintus kernel ≈ 8-12 KB flash-resident leaves little dictionary for the RomWBW suite (page decode, tracing, disassembler, uploads). Propose **32 KiB ROM / 64 KiB RAM** (TCM, byte-enable, M10K) — but check M10K headroom in `output_files/MrZ80.fit.rpt` first `[risk]`. |
| F-10 | M | Toolchain reality: VexRiscv comes from SpinalHDL (Scala/sbt — **not available on `tycho`**). Vendor the generated Verilog + `VexRiscv.qip` (`set_global_assignment -name QIP_FILE`, AGENTS mechanism 3) + a regeneration script/commit stamp. Quartus 17.0 acceptance is a known-good community path but **must be de-risked by a P0 synthesis spike** before committing the architecture. No JTAG debug plugin (no usable JTAG path on MiSTer) — the UART *is* the debugger, which is fine given the whole point. |
| F-11 | M | **No watchdog.** An RV hang with `busreq_n=0` or `wait_n=0` bricks the guest. Bridge must auto-release all controls (busreq↑, wait↑, cen transparent) on expiry of a HW timer (~100-300 ms) unless a kick is refreshed, latch a `wdg_expired` reason, and require re-arm from RV reset. |
| F-12 | m | Sample lacks `cpu_cen` input entirely (needed for every timing claim above), clock/commit assumptions implicit (all `clk_sys` = good), and no tie-off of outputs during FPGA-image boot (RV should be held in reset only until its ROM image is valid, not until the *guest's* BIN loads — monitor must be alive *before* the guest to be useful). |

---

## 4. Disposition map: SSP_DESIGN.md section by section

| v0.1 § | Content | Disposition | v0.2 home |
|---|---|---|---|
| §1 | Purpose, two operator surfaces, capabilities | `[carried]` — panel scope reduced per owner direction; add non-goal "guest behavior must not depend on the RV being alive" | — |
| D-01 | SNAC serial mux ownership | `[carried]` mechanism rehosted: passthrough↔monitor-ownership mux driven by RV CTRL bit AND OSD `OK` (bit 20, now valid — OQ-07 closed); escape-on-RX-while-running stays a bridge feature (auto-busrq + reason=escape) | bridge + FW |
| D-02 | Registers read-only, trampoline for `G aaaa` | `[carried]` — a supervisory CPU changes nothing about the missing T80 write-back path; trampoline enable/addr become bridge registers (OQ-03 mostly closed by §2 fact: no boot-ROM mux) | bridge + FW |
| D-03 | 64 sw + encoder + S32 on SNAC io4/io5 | `[carried]` — bridge-side capture `[new]`, board unchanged (OQ-09 open) | bridge HW |
| D-04 | Guest windows $D0-DF / $E0-E7 / $F8-FF | `[shrunk]` **[decision]**: operator console moved to RV; guest window now only needs *sense switches* $F8-FE + $FF LED latch (v0.1 D-05, HW, zero RV dependency). $D0-$DF becomes either reserved or a tiny guest→monitor **mailbox** (write → RV IRQ) for HBIOS cooperation `[new]` | bridge HW |
| D-05 | $F8-FF frame reads, $FF write→LED latch | `[carried]` verbatim — HW only (guest-visible contract must survive RV reset/hang) | bridge HW |
| D-06 | Jump-history ring | `[carried]` — T80 `CTEV*` mod is orthogonal to the pivot; 16-entry ring stays HW, FORTH formats `J` | bridge HW + FW |
| D-07 | START uses live switch value | `[carried]` — now literally free (FORTH policy) | FW |
| D-08 | MC/TS export + CEN gating for step | `[carried]` — `CEN` port already exists `[verified]`; MC/TS port-out still the same one-line mod | T80s mod + bridge |
| §3 | Verified platform facts | `[carried]` — all still valid, **except** the §8.2 tri-state claim (corrected, §2) and "27/28-bit" ambiguity (28-bit). Merge in §2 of this review | — |
| §4 | Module list (mon_core/cli/uart/fp/bp/jr/mem) | `[superseded]` by §5 split below. mon_core+mon_cli→**Mecrisp REPL**; ssp_uart→RV MMIO UART; mon_fp→thin frame/LED bridge + FW policy; mon_bp+mon_jr→bridge HW (kept); mon_mem→cycle-sequencer + SD client (bridge HW) + FW driver | — |
| §5 | Stop/go/step/reset/G semantics | `[carried]` **as the normative behavior spec**; mechanism = CTRL/STEP_CTL/reset-stretcher/trampoline regs; add soft-pause via `wait_n` `[new]`; R-snapshot-at-freeze invariant unchanged | bridge + FW |
| §6 | 4×BP, latched match PC, `C`-skip | `[carried]` HW matcher + `BP_SKIP`; OQ-05 (BP at $0000 vs trampoline) carries | bridge HW + FW |
| §7 | `CTEV` ring | `[carried]` unchanged proposal (OQ-06 open) | T80 mod + bridge |
| §8 | Memory & I/O access | `[superseded]`, restructured: **logical** accesses = bridge cycle-sequencer while parked, reusing the *guest's own* memory path (MMU translate, BRAM/SDRAM route, I/O decode) — one sequencer serves both memory **and** port mastering (F-01); **physical** = `vid`-port client (F-08 caveats); MMU read-tap `[carried]`, MMU writes stay `[deferred]` | bridge |
| §9 | Front panel | `[rehosted, shrunk]` per owner: HW = 68-bit frame capture/debounce/quadrature + LED write path; **all behavior** (§9.2 map, §9.3 AR/DR model, §9.4 command table, LED pages) becomes FORTH, polled at human speed — the §9.4 table survives verbatim as the FORTH command-spec seed; AR auto-inc/enc-nudge semantics carried; R-15 (shared AR/DR with serial) becomes free — one dictionary, one state | FW + bridge |
| §10 | Serial command set + protocol | `[carried]` — the command table becomes the **FORTH glossary seed**; ODT protocol (`.` prompt, repeat-last, `?ER nn` atomicity) implemented exactly in FW; `U` **pull-forward P3→P1**; `[new]` candidates: `S a,b,dd` search, `T` trace-until, `H` HBIOS page decode, XModem upload | FW |
| §11 | Resource/timing budget | `[superseded]`: VexRiscv RV32IMC + 32K/64K TCM ≈ 5-8k ALUT + ~50 M10K; bridge (ctrl/bp/jr/fp/sequencer/SD client) ≈ 2-3k ALUT + a few M10K; domains: RV+bridge on `clk_sys` 50 MHz (no new CDC), SDRAM client crosses to `clk_ram` (existing pattern), console UART on `clk_sys`. Idle transparency rule carried: when monitor disabled, HW forces bridge outputs to defaults `[proposed]` | — |
| §12 | R-01…R-22 | `[carried]` — semantics unchanged; test surfaces re-targeted (§8 here), plus R-23…R-28 below | sim/ |
| §13 | OQ-01…OQ-10 | see §9: OQ-07 **closed**; OQ-03 mostly closed by §2 facts; rest carry | — |
| §14 | Phasing | `[superseded]` by §7 phasing here (adds P0 spike) | — |
| §15 | Resume checklist | `[superseded]`; rewrite in v0.2 | — |

---

## 5. Proposed v0.2 architecture

```
 clk_sys 50 MHz (all of the below, single domain)                        
                                                                          
  SNAC io0/io1 ◄──► console mux ◄─────► guest ACIA path ($82/$83)        
                       ▲ owner = OSD OK & rv_ctrl                          
  SNAC io4/io5 ◄──►► fp_bridge ─┐      (68-bit capture, debounce, quad)  ┌─► FP_RAM_Store / WS2812
                                │    ┌────────────────────────┐   led mux ──┘
  VexRiscv RV32IMC ── SimpleBus ►│  ssp_bridge (4 KiB)    │◄── cpu_cen, M1, MC/TS, BusAck,
   ITCM: forth_rom (32K)        │  ctrl/status/step-assist│    frozen A/DO, REG[211:0]
   DTCM: dict     (64K)         │  BP×4 + trap + jump ring│──► busreq_n, wait_n, rst_n(stretched),
   uart0 (SNAC muxed)           │  mem/io cycle sequencer │    A mux sel, RD/WR/MREQ/IO mux sel,
   timer, ext IRQ ◄─────────────│  FP frame + LED regs    │    cpuDataIn override
   watchdog kick                │  SDRAM vid-port client ───┼──► sdram2.sv vid port (clk_ram CDC)
                                └────────────────────────────┘    ($0000 trampoline overlay at wrapper)
                                   watchdog auto-release ──────────► all guest controls → defaults
```

Load-bearing invariants (v0.2 carries v0.1's "arbiter of record" §4 and adds):

1. **P-A** `[carried]` No Z80-bus mastering (address/strobe/data muxes)
   unless `BusAck` confirmed — except non-bus physical SDRAM reads via the
   vid client, which never touch the Z80 bus and are limited by the
   controller's arbiter (F-08 characterization required).
2. **P-B** `[new]` Guest-visible behavior (CPU reset/hold defaults, $F8-FF
   sense, $FF latch, guest passthrough when monitor disabled) is delivered
   by hardware and does **not** depend on the RV being alive; a watchdog
   forces the release state.
3. **P-C** `[new]` Cycle-accurate functions stay in the bridge (§1.2):
   BP match, step assist, reset stretcher, escape break, trampoline
   one-shot — MMIO is a *policy* interface, never a timing interface.

Sense-switch reads and the $FF latch stay exactly as v0.1 D-05. The optional
$D0 mailbox (guest write → RV IRQ, guest read → HW status) is the only new
guest-visible port proposed, and it is `[decision]` material.

---

## 6. Proposed MMIO map (base `0x2000_0000`, word accesses, 4 KiB region)

Replaces the sketch's 8-register block. All offsets word-aligned
(SimpleBus); `*` = default after RV and/or bridge reset noted in RTL.

| Off | Reg | Acc | Notes |
|---|---|---|---|
| 0x00 | `ID` | R | `0x4D52_5A00` 'MRZ' + minor rev; FW `V` command source |
| 0x04 | `CTRL` | RW | bit0 `z_rst_n`* · bit1 `z_busreq_n`* · bit2 `z_wait_n`* · bit3 `cen_gate`* · bit4 `tramp_en` (one-shot) |
| 0x08 | `TRAMP_ADDR` | RW | `G aaaa` / panel START target; HW emits `C3 aa aa` at $0000 while `tramp_en` and first fetches after reset-vent |
| 0x0C | `STATUS` | R | live `BusAck, Halt_n, M1_n, MC[2:0], TS[2:0], cpu_running, ssp_active, s32, alt` (OQ-01 sideband when added), `wdg_expired` |
| 0x10 | `HALT_REASON` | R/clr | v0.1 §10.2 codes + `wdg`; latched `{reason, bp_slot}` |
| 0x14 | `PC_LATCH` | R | match/park PC (v0.1 §6 "latched match, not PC+1") |
| 0x18–0x30 | `SNAP_REG0..6` | R | 212-bit `REG` frozen at park/match instant (`t80_reg_debug_vector.md` §1 layout, normative) |
| 0x34–0x4C | `LIVE_REG0..6` | R | combinational `REG` (valid whenever parked) |
| 0x50 | `STEP_CTL` | RW | `{mode[1:0]: 0 off, 1 INSN, 2 MCYCLE, 3 TSTATE×n; n[7:0]}` — auto release/re-assert (v0.1 §5.2) |
| 0x54–0x60 | `BP0..3` | RW | `{en, addr16}` |
| 0x64 | `BP_SKIP` | RW | suppress next match mask (implements `C`, v0.1 §6) |
| 0x68–0x70 | `TRAP_CTL/ADDR/DATA` | RW | `{en, wait_stall}` / port / `{val, mask}` — I/O-write trap + optional stall `[new]` |
| 0x74 | `MEM_CTL` | RW | `{start, rnw, is_io}` — parked cycle sequencer (F-01) |
| 0x78 | `MEM_ADDR` | RW | 16-bit Z80 address (mem *or* port per `is_io`) |
| 0x7C | `MEM_DATA` | R/W | read = last captured byte (latched at strobe end, F-03); write = driven data |
| 0x80 | `MEM_STAT` | R | `{busy, done, err_timeout}` |
| 0x84–0x94 | `FP_SW_LO/HI, FP_ENC, FP_PRESS, FP_STAT` | R | 68-bit frame (debounced), quadrature delta, press, frame-error |
| 0x98 | `LED_ADDR` / 0x9C `LED_DATA` | RW | framebuffer write path into the FP subsystem (exact mux tap `[decision]` OQ-RV-06) |
| 0xA0–0xAC | `SD_ADDR, SD_WDATA, SD_RDATA, SD_CTL/STAT` | RW/R | physical 128 MB window via vid-port client; HW RMW for byte writes; CDC per existing pattern (F-08) |
| 0xB0 | `WDG_KICK` / 0xB4 `WDG_STAT` | RW/R | ~100-300 ms expiry → P-B auto-release (F-11) |
| 0xB8 | `IRQ_EN` / 0xBC `IRQ_PENDING` | RW/R/W1C | sources: bp0-3, trap, rx_byte, fp_edge, sd_done, wdg (F-06) |
| 0xC0 | `ESC_CTL` | RW | escape-break policy: rx-while-running → auto busreq + reason (v0.1 §10) |

Guest-side Z80 ports unchanged from `HARDWARE.md` + D-05 ($F8-FF read
frame, $FF latch); $D0 mailbox optional. FORTH seed words against this map:
`z80-halt z80-run z80-reset z80-step ex@ ex! io@ io! regs snap. bp! bpc
mem! mem@ sd@ page. h bios.map` — the v0.1 §10.1 command table implemented
1:1 in the dictionary.

---

## 7. Revised phasing (supersedes v0.1 §14)

| Phase | Scope | Exit criteria |
|---|---|---|
| **P0 — tool de-risk** `[new]` | SpinalHDL generation pinned + vendored; VexRiscv (IMC, no caches, TCM) + Mecrisp hello-world synthesizes in **Quartus 17.0** for `5CSEBA6U23I7`; M10K/ALUT headroom read from `fit.rpt`; GHDL: RV-in-TB or ROM-model harness chosen | clean `analysis_and_synthesis` + sim boots Mecrisp banner on a tb-simulated UART |
| **P1 — monitor core** | bridge (ctrl/status/snap/step-assist/mem-sequencer/reset-stretcher/trampoline/console-mux/uart/WDG/IRQ) + FORTH: `z80-*`, `E/D/I/O/R/G/S/T/X/K/A/W/V/?`, ODT protocol, `U` (pull-forward) | v0.1 R-01…R-05, R-08*, R-09, R-12, R-19…R-22 green (R-08 via sequencer TB); classic "halt, dump regs, examine, single-step" from a real SNAC terminal |
| **P2 — panel + assist** | fp_bridge (frame/debounce/quad/LED), FORTH panel server (v0.1 §9.2-9.4 carried as spec), `mon_bp`+`BP_SKIP`+`C`, jump ring (`CTEV` mod), trap registers, physical SDRAM window, MMU map view, `B/P/J/F`, escape break | R-10…R-18 green; RESET/DEP/START ritual from switches only; background SD reads measured vs F-08 |
| **P3 — write-back + polish** | T80 register write-back (retires trampoline), step-over, conditional BPs, MMU writes, $D0 mailbox/HBIOS cooperation, runtime ROM-load path, HPS path eval | D-02 retired; everything above still green |

(*R-08 "no contention" gains extra teeth from the freeze-not-tri-state fact.)

## 8. Verification adjustments

- v0.1 §12 requirements carry **verbatim as behavioral specs**; the test
  driver moves from "drive mon_* FSMs" to "drive MMIO registers" — VHDL
  tasks emulating FORTH calls make every v0.1 TB reusable
  (`tb_ssp_bridge` replaces tb_mon_ctrl's register surface; tb_mon_mem/io
  now exercise the cycle sequencer incl. the mux-vs-frozen-output cases).
- New requirements: **R-23** RV boots from TCM ROM with `forth_rom.hex`
  (ROM-model init in GHDL smoke test); **R-24** watchdog auto-release +
  re-arm semantics; **R-25** console mux: guest↔SNAC passthrough when
  monitor off/dies; **R-26** SD vid-port client coexists with cpu port +
  refresh (priority characterization, F-08); **R-27** byte-write RMW via
  SD window; **R-28** guest-visible $F8-FF/$FF identical to v0.1 R-16
  **with RV held in reset** (P-B proof).
- Keep R-21 (idle bit-identical regression) — now doubly load-bearing:
  the RV must be provably quiescent-when-idle (no bus traffic, no mux
  flips).

## 9. Open questions — closed, carried, new

| # | Status | Item |
|---|---|---|
| OQ-07 | **closed** | bit 14 used (`OE` flow control); `OK`=20/`OL`=21 allocation valid (§2) |
| OQ-03 | mostly closed | boot-ROM mux removed (§2); trampoline = overlay-$0000-while-enabled; remaining: exact one-shot arm/disarm vs `bin_loaded` gating at `:337-343` |
| OQ-01, -02, -04, -05, -06, -08, -09, -10 | carried | unchanged v0.1 statements and leans |
| OQ-RV-01 | new | RV clock = `clk_sys` (50 MHz)? Comfortable Fmax even at I7 grade; keeps single-domain bridge. Alternative dedicated PLL tap buys headroom but adds CDC for zero current need. Lean: clk_sys |
| OQ-RV-02 | new | VexRiscv config + Mecrisp variant (RV32IMC, no MMU/cache, machine mode, timer+PLIC-lite). Pin the SpinalHDL commit; verify C-extension benefit vs simplicity for Mecrisp |
| OQ-RV-03 | new | Monitor ROM path: factory `forth_rom.hex` in bitstream + **runtime reload via HPS ioctl** (new `FC` image type) for iteration without refits — strongly recommended |
| OQ-RV-04 | new | Background physical reads while guest runs (P-A relaxation via vid client) or parked-only until F-08 arbitration measured? |
| OQ-RV-05 | new | $D0-$DF guest mailbox: allocate now or keep reserved until HBIOS cooperation design? |
| OQ-RV-06 | new | LED write tap: mux into `FP_RAM_Store` port A vs replicate a small fb in the bridge driving the capture-chain input |
| OQ-RV-07 | new | Monitor text on the HDMI terminal (reuse `SBCTextDisplayRGB`) or serial-only in v2? Serial-only keeps scope clean `[deferred proposed]` |
| OQ-RV-08 | new | Naming/doc hygiene: guest CamelFORTH vs monitor Mecrisp dictionary (separate glossaries in `doc/`); `REQUIREMENTS.md` item 1 wording → "support-CPU examine/deposit port" traceability |

## 10. Risk register `[risk]`

| Risk | Mitigation |
|---|---|
| Quartus 17.0 vs SpinalHDL-generated Verilog | P0 spike before any architecture commitment |
| M10K headroom (existing BRAM + LED RAM usage reported "tight" in REQUIREMENTS item 4.2 discussions) | read `fit.rpt` in P0; fall back to 32K/32K + dictionary slimming |
| RV lockup holding bus | watchdog (F-11), P-B invariant, R-24 |
| vid-port arbitration starves guest (inverted from ODT_CHANGE's claim) | P2 measurement; parked-only fallback (OQ-RV-04) |
| Byte-write via 16-bit SD port corrupts neighbor byte | HW RMW in client, R-27 |
| Frozen-output assumption (F-01/§2) causing silent double-drive if someone later wire-ORs | explicit mux selects + R-08 contention assertions in TB |
| SNAC io4/5 conflict with SW[1] I2S option | carried v0.1 caveat; disable monitor FP when SW1 set |
| Two consoles confusion (guest ACIA vs monitor UART on same SNAC pins) | explicit ownership bit + OSD label + `.` prompt contract |

## 11. Next steps

1. Owner calls on the `[decision]` items: D-04 shrink ($D0-$DF reserved vs
   mailbox), LED tap (OQ-RV-06), ROM/runtime-reload (OQ-RV-03).
2. P0 spike (F-10 de-risk, headroom numbers) — gates everything.
3. Rewrite `SSP_DESIGN.md` → **v0.2**: keep §1-§3 (corrected), §5,
   §6, §7, §10, §12 as behavior spec; replace §4, §8, §11, §14, §15 with
   this review's §5-§8; merge ODT_CHANGE.md's roadmap into the P0-P3 plan.
4. Update `REQUIREMENTS.md` item 1 (the arbiter/examine-port requirement)
   to reference design v0.2 (now `SSP_DESIGN.md`) as its satisfying architecture, and `HARDWARE.md`
   when the bridge lands.
