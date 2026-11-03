# SDRAM / Wait-Line Investigation — Independent Review Hand-off

Date of review: 2026-10-03. Baseline: commit `2a797ff` (branch `louie`),
compiled database / `output_files/MultiComp.sta.rpt` dated 2026-10-03 03:09.

This document reviews `SDRAM-bug-handoff.md` (and the related sections of
`HISTORY.md`, `sim/STATUS.md`, `testing/backtoback.asm`) against the RTL and
against new static-timing evidence. **No RTL, test, or constraint files were
changed during this review.** All conclusions below are pending
implementation; the action plan in section 7 is the intended order of work.

---

## 1. Executive summary

1. The hardware results used by `SDRAM-bug-handoff.md` do not support its
   "shared request-level CDC" diagnosis:
   - The `0x44` run ("Run 1") was produced by an earlier `backtoback.asm`
     with several documented test-program bugs; its results are not usable
     evidence.
   - The later A2/A3 "exactly one mismatch at offset 0, got=FF" result
     ("Run 2") is fully explained by a **real T80 core bug: INI/IND/INIR/INDR
     and OUTI/OUTD/OTIR/OTDR never update HL** — plus stale block-RAM buffer
     contents from a previous run.
2. There **is** a real hazard on the wait line, but it is not the one the
   handoff describes. The T80 is clocked by a fabric-derived, unconstrained
   clock (`cpuClock`). When `sdram_wait_n` changes on the same `clk_sys` edge
   on which `cpuClock` rises, different T80 flip-flops can capture different
   values (old vs new) — an *inconsistent CPU state*, not a stale-data read.
   STA (with `cpuClock` defined as a generated clock) confirms hold
   violations of up to -4.1 ns (fast corner) on these paths while the slow
   corner meets hold, i.e. the outcome is genuinely indeterminate.
3. The four proposed fixes in `SDRAM-bug-handoff.md` should **not** be applied
   as written: Fix 1 is a functional no-op and fails synthesis (multiple
   drivers) and targets the wrong phase; Fix 3 deadlocks every direct-access
   cycle; Fix 2 addresses a non-problem; Fix 4 is not behaviour-neutral.
4. New, independent defects found:
   - **SDRAM refresh starvation** in `sdram2.sv`: under sustained CPU access to
     device 0, device 0 is never refreshed, and in any case each device is
     refreshed at only ~half the required rate.
   - Timing constraints are missing for the derived CPU clock and for the
     `clk_sys` <-> `clk_ram` CDC, which hides real violations among large
     spurious ones.

---

## 2. System facts relevant to this review

| Item | Value / location |
|---|---|
| `clk_sys` | PLL outclk_0, 50.000 MHz (`rtl/pll/pll_0002.v`) |
| `clk_ram` | PLL outclk_2, **96.667 MHz** (`SDRAM_CLK_100` define, `MultiComp.sv:491`). VCO 1450 MHz; clk_sys = /29, clk_ram = /15 |
| outclk_1 | 111.538 MHz, -4310 ps (unused) |
| CPU clock | `cpuClock`, a **register** in `MicrocomputerZ80CPM.vhd:794-808`, /5 of `clk`, high 3 / low 2 cycles. Promoted by the fitter to global `GCLK3` (fit report). No SDC clock → all paths into/out of the T80 are **unanalysed** |
| T80 wrapper | `Components/Z80/T80s.vhd`, `CEN <= '1'` (line 115). All strobes and `DI_Reg` registered on `CLK_n` rising edge |
| T80 version | Wallner **0242** (`T80_MCode.vhd` header) — predates/omits the "0240mj1" INI/OUTI HL fix |
| SDRAM client FSM | `MicrocomputerZ80CPM.vhd:664-784` (`S_IDLE→S_REQ→S_DONE→S_GAP`) |
| CDC adapter | `MultiComp.sv:260-320` (2-FF level sync + edge detect into `clk_ram`; toggle + 2-FF back to `clk_sys`) |
| SDRAM controller | `Components/SDRAM/sdram2.sv` (CoCo3 `sdram_32r8w`, local mods for dual device), CL=3, BL=2, auto-precharge |
| SDRAM I/O | `FAST_INPUT_REGISTER`/`FAST_OUTPUT_REGISTER` set in `MultiComp.qsf:159-162`; `SDRAM_CLK` via `altddio_out` with `datain_h=0, datain_l=1` (inverted clock) |

### Exact cpuClock phase (correction to the earlier handoff)

```vhdl
if cpuClkCount < 4 then cpuClkCount <= cpuClkCount + 1; else cpuClkCount <= 0; end if;
if cpuClkCount < 2 then cpuClock <= '0'; else cpuClock <= '1'; end if;
```

Both assignments use the *old* count. Therefore `cpuClock` rises on the
`clk` edge at which the old `cpuClkCount = 2` (count goes 2→3), and falls on
the edge at which old count = 0. Any process that tests
`cpuClkCount = "000010"` inside `rising_edge(clk)` is acting **on the
cpuClock rising edge itself**. `SDRAM-bug-handoff.md` states the rise is at
1→2; that is off by one, and its Fix 1 releases on exactly the hazardous
edge.

---

## 3. Re-assessment of the hardware evidence

### 3.1 Run 1 — the `0x44` result (recorded in HISTORY.md "Test result of testing/backtoback.asm")

Output contained only Phases 0, A, B, C, D (no A2–A4), so it predates even
the `testing/backtoback.asm~` backup (Aug 25, which already has `phase_a2`).
The current `backtoback.asm` contains "NOTE: this used to…" comments
documenting bugs fixed after that era:

- **Ramp generation bug** (`gld_loop` / `fl_loop`): `ld a,b / or c` used the
  ramp register A as the loop test, so after byte 0 the "ramp" became the OR
  of the remaining count bytes. Both the golden buffer and the SDRAM fill
  used this loop, so offset 1 contained **0xFF**. → Phase C's
  "sentinel found EARLY @0001" is the *correct* result for that data.
- **`golden_fetch` index byte-swap** (B/C loaded from low/high bytes the wrong
  way round) — wrong expected values for most indices.
- **`report_fail` exp/got mix-up** (stack bookkeeping), per its own comment.
- **Phase 0 never verifies** — `PHASE 0 OK` is printed unconditionally, so
  "Phase 0 passed ⇒ write path proven" is not a valid inference.
- No mismatch counter existed then, so "only offset 0 fails" was never
  established — only the first failure was printed.

A constant `0x44` at the same offset across three unrelated hardware paths
(direct-access IN after direct writes; LDIR read after direct writes; LDIR
read after LDIR writes) is far better explained by a shared *software*
comparison defect than by hardware. **Treat Run 1 as invalid.**

### 3.2 Run 2 — A2/A3 "exactly 1 mismatch @0000, got=FF"; A4 passes

Recorded in `testing/backtoback.asm` (Phase A3/A4 comments), `sim/STATUS.md`,
and the comment in `MicrocomputerZ80CPM.vhd` S_DONE.

Root cause: **T80 INIR does not increment HL** (see section 4). Every byte of
all four INIRs is written to `WORK_BASE[0]`; the last byte read (offset 1023)
is `0xFF`. `WORK_BASE[1..1023]` is untouched and still holds a ramp left by a
previous run's Phase B/D — block RAM is **not** cleared by reset or by a BIN
reload (the download only writes the 0x908-byte image). Verify then sees
exactly one mismatch at offset 0 with `got=FF`. A4 (`IN r,(C)` loop with
explicit stores) passes because it does not use INI.

This also explains the reverted "`phys_in_sdram = '0' or`" S_DONE experiment
producing 1021 mismatches: the result depends on whatever `WORK_BASE` held
from prior runs (which, with that broken FSM change, would have been
garbage), not on INIR's SDRAM reads.

Other Run 2 phases (A, B, C, D) were not recorded anywhere found; the A4
comment implies A passed. **There is currently no valid evidence of an SDRAM
data-path failure in `backtoback.asm`.** The remaining credible symptoms are
`sdramexec.asm`'s intermittent `0xC3→0xC4` and the earlier execute-from-SDRAM
hang.

### 3.3 GHDL testbench

`sim/STATUS.md`'s "OPEN BLOCKER: INIR's destination address (HL) never
increments" is **not a simulation artifact** — it is the core bug, faithfully
simulated. Note also that a zero-delay RTL simulation can never reproduce the
wait-line race of section 5; STA is the right tool for that.

---

## 4. T80 INI/OUTI HL bug (real, core-level)

Local code (`Components/Z80/T80_MCode.vhd`):

- INI/IND/INIR/INDR, MCycle 3 (lines ~1951-1956):
  `IncDec_16 <= "0010"` / `"1010"`
- OUTI/OUTD/OTIR/OTDR, MCycle 3 (lines ~1980-1985):
  `IncDec_16 <= "0010"` / `"1010"`; no HL inc/dec in MCycle 2.

`T80.vhd:811` (register write-enable) only writes `ID16` back when
`IncDec_16(2) = '1'`. With bit 2 clear, HL+1 is computed (RegAddrA points at
HL in TState 2) but never stored. This code is unchanged since the initial
commit `a8139f3` — not a regression from the custom-instruction work.

Reference: Sorgelig's MiSTer T80 v350 (e.g.
`MiSTer-devel/ZX-Spectrum_MISTer rtl/T80/T80_MCode.vhd`), whose header lists
"0240mj1 fix for HL inc/dec for INI, IND, INIR, INDR, OUTI, OUTD, OTIR,
OTDR", uses:

```vhdl
-- INI/IND MCycle 1 additionally: TStates <= "101"; SetWZ <= "11"; IncDec_16(3) <= IR(3);
-- INI/IND MCycle 3:
if IR(3) = '0' then IncDec_16 <= "0110"; else IncDec_16 <= "1110"; end if;
-- OUTI/OUTD MCycle 2: SetWZ <= "11"; IncDec_16(3) <= IR(3);
-- OUTI/OUTD MCycle 3:
if IR(3) = '0' then IncDec_16 <= "0110"; else IncDec_16 <= "1110"; end if;
```

Only the `IncDec_16` values are needed for correct HL behaviour; the
`SetWZ`/`TStates`/`IncDec_16(3)` extras belong to v350's MEMPTR/timing work
and depend on signals that may not exist in this 0242-based core. Port the
minimal change and verify.

Impact: any software using INIR/INDR/OTIR/OTDR or INI/OUTI with HL (RomWBW
disk/serial drivers use these heavily) is silently broken on this core.
ZEXDOC/ZEXALL do not exercise I/O block instructions, so a targeted test is
required.

---

## 5. The real wait-line hazard (derived clock)

### 5.1 Mechanism

- `cpuClock` is a register output driven onto a global clock. The T80's
  flip-flops are clocked a few ns after the corresponding `clk` edge.
- `sdram_wait_n` (and any other `clk`-domain signal feeding the T80) changes
  a little after the same `clk` edge and fans out through deep T80 logic
  (TState advance, `DI_Reg`/`IR` load, register-file write enables,
  `RD_n`/`MREQ_n` hold, PC, XY_State, …).
- If the FSM releases `sdram_wait_n` (S_DONE, `MicrocomputerZ80CPM.vhd:750`)
  on the `clk` edge where `cpuClock` rises, whether each T80 FF sees
  `Wait_n = 0` or `1` depends on its individual path delay vs. clock
  insertion delay. A mixture is possible: e.g. TState advances past T2 while
  `IR`/`DI_Reg` do not load (→ previous opcode/operand reused), or `RD_n`
  stays asserted while TState moves on. This is consistent with the
  intermittent `C3→C4` single mis-executed instruction in `sdramexec.asm`.
- The S_DONE release phase relative to `cpuClkCount` is effectively random
  (SDRAM latency varies with the 29:15 `clk_sys`:`clk_ram` beat and refresh
  collisions), so roughly 1 in 5 SDRAM accesses releases on the hazardous
  edge; only some of those resolve inconsistently → rare, intermittent
  failures.
- `sdramReadData` is **not** the problem: it changes one cycle before the
  release (S_REQ) and stays constant through S_DONE/S_GAP/S_IDLE until the
  next read completes. The earlier handoff's "FSM moved on to S_GAP and the
  CPU captured a stale value" is incorrect.
- Wait *assertion* is safe in practice: the FSM detects the strobe 1–2 `clk`
  edges after the T80 edge (FSM input setup slack +3.3 to +6.4 ns), far from
  the next T80 sampling edge 5 cycles later.
- The MMU's combinational `cpu_wait` pulse (`MMU.vhd:230`) occurs just after a
  T80 edge and ends at the next `clk` edge; it never overlaps a T80 sampling
  edge and is effectively unused in this system.

### 5.2 STA evidence (diagnostic session only — nothing committed)

`cpuClock` was declared in a TimeQuest session as:

```tcl
create_generated_clock -name cpuClk -source $clk_sys_pll_pin -edges {1 7 11} \
    [get_registers {emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM|cpuClock}]
```

(period 100 ns, rise 0, fall 60 — high 3 / low 2 `clk_sys` periods).

| Transfer | Result |
|---|---|
| clk_sys → cpuClk **hold** (all) | worst **-5.862 ns** (mostly static `bin_loaded` via ROM-select into `DI_Reg`/`IR` — irrelevant in practice) |
| `sdram_wait_n` → T80 **hold** | worst **-4.123 ns** (PC[0], XY_Ind, MREQ_n, XY_State, ISet, TState, regfile WE, TmpAddr, Halt_FF…) — fast corner |
| `sdram_wait_n` → T80, slow corner | same-edge data arrives ~1–4 ns *after* the clock → would capture old value. Fast corner captures new. ⇒ indeterminate on silicon |
| `sdramReadData` → `DI_Reg`/`IR` setup (one-cycle lead) | +15.7 to +18.9 ns — fine |
| clk_sys → cpuClk setup | +9.6 ns worst — fine |
| cpuClk → clk_sys **setup** | worst **-7.636 ns**: `IORQ_n` → block-RAM address regs; `DO` → BRAM datain -4.8; `IORQ_n` → BRAM we_reg -1.5; T80 `A[5]` → MMU `direct_access_pointer` **-0.139** (marginal; pointer post-increment path) |
| cpuClk → clk_sys setup into SDRAM FSM regs | **positive** (+3.3 state, +6.4 rd/we/wait_n) |
| cpuClk internal | setup +82.7, hold +0.29 — fine |

BRAM violations are largely benign (address is stable from T1 for memory
cycles; writes repeat every `clk` while `WR_n` is low), but they illustrate
that the CPU domain is not timing-clean. They disappear with the CEN
conversion (section 7, step 3b).

### 5.3 Existing-SDC STA (as compiled)

| Clock | Setup WNS / TNS | Cause |
|---|---|---|
| clk_ram (96.67) | **-11.144 / -384.6** | `mmu_frame`/`direct_access_pointer` → `ram_addr` in `MultiComp.sv` — unconstrained CDC, launch/latch relationship ~0.69 ns. Functionally safe (bus held stable for the transaction), but unconstrained |
| clk_sys (50) | **-8.921 / -276.2** | `ram_byte` → `sdramReadData` (CDC, rel. 0.712 ns) — functionally safe; plus genuine **-2.79 ns** in `SBCTextDisplayRGB` (falling-edge `startAddr`/`cursorVert` → attribute RAM address; `mod` divider, see HISTORY "Pre-existing setup-timing violation") |
| Unconstrained clocks | `cpuClock`, `T80s:cpu1|IORQ_n` (clocks `n_RomActive`), `serialClkCount[15]` (UART) |

The whole `*|pll|...` group is one clock group in `sys/sys_top.sdc`, so the
`clk_sys`↔`clk_ram` crossing is analysed as synchronous. Constraints must be
added in a **project-level SDC** (never in `sys/`).

---

## 6. Review of the fixes proposed in `SDRAM-bug-handoff.md`

| Fix | Verdict | Reason |
|---|---|---|
| **1** phase-aligned release | **Do not apply as written** | (a) `sdram_wait_n_phase` is never driven `'0'` anywhere → the AND term is constant `'1'` → no-op. (b) `sdram_phase_pending`/`sdram_wait_n_phase` are assigned in two processes → Quartus error 10028 (multiple constant drivers). (c) Releases at old `cpuClkCount = 2` = exactly the cpuClock rising edge (section 2). (d) Muxing in `phys_in_sdram` adds an address-bus → MMU → `WAIT_n` combinational path; unnecessary because `sdram_wait_n` is only ever low for SDRAM cycles. The *idea* (avoid releasing on the rising edge) is right; see section 7 step 3a for a correct one-liner. |
| **2** widen S_GAP | Not needed | Request level is low for all of S_DONE (≥ until the T80's next edge) **plus** S_GAP — ≥ 80 ns ≈ 8 `clk_ram` edges; the 2-FF sync needs ~3. A dropped request would hang (stuck in `S_REQ`), never return wrong data. Harmless but addresses nothing. |
| **3** register MMU `cpu_wait` | **Do not apply — deadlocks** | `cpu_wait_reg` is set on entry and cleared only when `map_io_to_direct = '0'`, which requires the CPU to finish the I/O cycle, which it cannot do while waited. Every `IN/OUT (0xBC)` would hang. The MMU pulse is functionally irrelevant here anyway. |
| **4** regenerate PLL to 100/112 MHz | Defer / don't treat as cleanup | Changes SDRAM read-capture timing (see 6.1). The "100 MHz" soak results were actually at 96.67 MHz. Only change with a margin analysis or measured need. |

### 6.1 SDRAM read-capture note (for Fix 4 / future frequency changes)

READ issued at FPGA edge R; SDRAM clock is inverted so the chip registers it
at R+0.5. With CL=3 the first word is valid roughly
`[R+2.5T + tAC, R+3.5T + tOH] + d` (tAC ≈ 5.4 ns, tOH ≈ 2.5 ns, `d` = board +
I/O round trip). `dq_reg` is sampled at R+4 (and `ram_byte` takes that value
one cycle later). At 96.67 MHz this needs roughly 2.7 ns < d < 10 ns; at
111.5 MHz roughly 2.0 < d < 8.1 ns — both sample late in word 1, near the
start of word 2 (column+1, i.e. the byte two addresses on). HISTORY already
records DQ bit errors at 112 MHz. Treat clock changes as SDRAM-timing
changes.

---

## 7. Other findings

### 7.1 SDRAM refresh starvation (`Components/SDRAM/sdram2.sv`)

- Each CPU access sets `chip <= sdram_cpu_addr[26]` (line ~300).
- Each refresh does `chip <= ~chip` then `AUTO_REFRESH` (lines ~266-276).
- If at least one access to device 0 (address < 64 MB) occurs between
  consecutive refreshes (~8 µs apart) — true for any SDRAM-resident code,
  LDIR/INIR loops, or CP/M running from SDRAM — `chip` is always 0 before
  each refresh, so **every refresh goes to device 1 and device 0 is never
  refreshed**.
- Rate: `STATE_IDLE` only diverts to refresh when
  `refresh_count > (cycles_per_refresh<<1)` = 780; `STATE_IDLE_1` then
  refreshes because count > 390. The upstream "opportunistic" refresh in
  `IDLE_1` after each access is unreachable because accesses end via
  `DLY1→DLY2→IDLE`. Net: one refresh per ~781 cycles ≈ 8.1 µs at 96.67 MHz,
  alternating → each device every ~16 µs vs the required 7.8 µs
  (8192 rows / 64 ms).
- Short tests and room-temperature retention hide this; long-running SDRAM
  execution (RomWBW/CP/M from SDRAM, warm enclosure) will eventually corrupt
  device-0 data.
- Fix: keep a dedicated `refresh_chip` toggle independent of `chip`, drive
  `chip <= refresh_chip` for refresh commands, and trigger a refresh every
  ≤ ~3.9 µs (each device then gets one per ≤ 7.8 µs). Recompute constants
  for the actual `clk_ram` frequency.

### 7.2 Smaller items

- `sdramReadData` is also loaded on **write** completions (S_REQ latches
  `sdram_dout` whenever `sdram_ready`), with junk sampled from DQ. Harmless
  but confusing in debugging — gate the latch to reads.
- Controller write "ready" is asserted at `STATE_RW1` before tWR/tRP
  (already documented; download path has a cooldown; CPU path relies on
  instruction pacing).
- `n_RomActive` is clocked by `rising_edge(n_ioWR)` (combinational OR of two
  T80 strobes) — glitch-clock; make it synchronous to `clk`.
- `bufferedUART` is clocked by `serialClkCount(15)` (ripple clock) —
  pre-existing, unconstrained.
- `ram_addr`/`ram_din`/`ram_rnw` in `MultiComp.sv` are captured
  unsynchronised from `clk_sys` buses; functionally OK because the buses are
  held for the whole transaction, but needs `set_max_delay`/`set_false_path`
  so STA stops reporting it.
- Direct-access pointer pointing at block RAM while the logical frame of the
  I/O address maps to SDRAM: a transient `phys_in_sdram` during the
  `IORQ_n → map_io_to_direct → address mux` settling could in principle start
  a spurious SDRAM cycle. Edge case; disappears with CEN conversion.

---

## 8. Action plan (agreed to be done later, in this order)

Keep each step in its own commit; regress after each.

### Step 0 — Fix the test methodology first
- In `testing/backtoback.asm`: before every phase that writes into
  `WORK_BASE`, poison it (e.g. fill with `0xA5`) so stale block-RAM contents
  cannot fake or mask results. Consider also poisoning the SDRAM region
  before Phase 0.
- Make Phase 0 verify (read back via direct access) or rename its message.
- Keep the mismatch counter; optionally print the first N mismatches.
- Add a block-RAM-only INIR/OTIR check: e.g. `ld hl,X / ld b,4 / ld c,0B0h /
  inir` (MMU frame-register reads, no SDRAM), then print HL (expect X+4).
  Same for OTIR (port `0xFF` latch) and INDR/OTDR.

### Step 1 — Re-baseline on the current core
- Rebuild current RTL (includes ED 92 / PUSHIX/POPIX changes).
- Run `sdramtest`, `backtoback` (fixed), `sdramexec` (many runs, e.g. ≥ 200
  `EXEC_RUNS` total) and record full results per phase with counts.
- Expected: INIR test fails (HL constant); A2/A3 fail broadly with a poisoned
  buffer; other phases likely pass; `sdramexec` intermittent.

### Step 2 — Fix T80 INI/IND/OUTI/OUTD HL handling
- `T80_MCode.vhd` MCycle 3 of both groups: `"0010"→"0110"`,
  `"1010"→"1110"` (section 4). Check OUTI timing matches upstream (whether
  HL update belongs in MCycle 2 or 3 with this core's `T80.vhd`).
- Verify in GHDL (`sim/run.sh`, `tb_inir_race`), then on hardware with the
  Step 0 test. Update `sim/STATUS.md` (blocker resolved).

### Step 3 — Remove the wait-line race (pick one)
- **3a (minimal, quick to test):** in `S_DONE` only release when not on the
  cpuClock rising edge:
  ```vhdl
  when S_DONE =>
      if cpuClkCount /= "000010" then   -- never change WAIT_n on the cpuClock rising edge
          sdram_wait_n <= '1';
      end if;
      if mmu_req_read = '0' and mmu_req_write = '0' then ...
  ```
  (Single driver; no new process; ≤ 1 extra `clk`; `sdram_wait_n` can only
  be low for SDRAM cycles, so non-SDRAM cycles are unaffected.) Note the
  existing exit condition still works: the CPU cannot drop RD/WR until it
  has seen `Wait_n = 1`.
- **Validation experiment (falsifiable):** temporarily invert the condition
  (release *only* when `cpuClkCount = "000010"`); `sdramexec` failure rate
  should rise sharply. If 3a eliminates failures over many runs and the
  inverted build worsens them, the hypothesis is confirmed.
- **3b (proper, recommended long-term):** clock the T80 from `clk` with a
  1-in-5 clock enable instead of the derived `cpuClock`:
  - Expose `CEN` as a port on `T80s` (currently `CEN <= '1'`, line 115) and
    gate `T80s`' own strobe/`DI_Reg` process with `if CEN = '1'`.
  - Generate `cpu_cen` as a one-cycle pulse from `cpuClkCount`.
  - All CPU paths become single-domain and STA-checked; add
    `set_multicycle_path` (setup 5 / hold 4) for paths into the T80 if
    needed for closure.
  - Re-check peripherals that use strobes as clocks (`n_RomActive`, UART,
    SD controller, front panel) still behave; strobes are still registered.
  - Revisit whether the MMU `cpu_wait` pulse is needed at all (with CEN the
    FSM wait is asserted ≥ 3 `clk` before the next enabled edge).

### Step 4 — Fix SDRAM refresh (section 7.1)
- Dedicated `refresh_chip` toggle; refresh interval so each device gets
  ≤ 7.8 µs; recompute for actual `clk_ram`. Mark as `LOCAL MOD`.
- Validate with a retention test: write a pattern to both devices, run a
  tight SDRAM-resident loop on device 0 for minutes, verify.

### Step 5 — Project-level timing constraints
- New `MultiComp.sdc` (or similar, not in `sys/`), added to `MultiComp.qsf`
  via `set_global_assignment -name SDC_FILE …`.
- If 3a was used: `create_generated_clock` for `cpuClock` (edges `{1 7 11}`,
  source = clk_sys PLL output pin) so its paths are analysed.
- `set_max_delay` / `set_false_path` for the `MultiComp.sv` CDC:
  `sdram_addr_mux/din/we/rd` → `ram_addr/ram_din/ram_rnw/req_sync[0]`, and
  `ram_byte/ram_done` → `sdramReadData/done_sync[0]`.
- Optionally a multicycle/false path or RTL fix for `SBCTextDisplayRGB`
  (`dispAddr ... mod CHARS_PER_SCREEN`, HISTORY "Known issues").
- Goal: a clean timing report where any remaining violation is real.

### Step 6 — Cleanups
- Gate `sdramReadData` latch to reads.
- Make `n_RomActive` synchronous.
- Fix/remove the incorrect proposals in `SDRAM-bug-handoff.md` and the
  speculative-fix section of `HISTORY.md` (or annotate them with a pointer to
  this document) so they are not applied by mistake.
- PLL: leave at current frequencies unless a measured need arises
  (section 6.1).

### Step 7 — Regression
After each step: `sdramtest.asm`, `backtoback.asm` (fixed),
`sdramexec.asm` (many runs), block-RAM INIR/OTIR test, CP/M boot from block
RAM and from SDRAM (BIN to SDRAM, frame 0 = SDRAM page 0 — the M1-refresh
worst case), CamelFORTH custom-instruction self-tests.

---

## 9. Reproducing the STA diagnostics

Scripts left in `tmp/` (untracked) — run on `tycho` with the same Docker
image the build uses (note: `tools/quartus_build.sh` only invokes
`quartus_sh`, so call `quartus_sta` directly):

```sh
ssh tycho "cd Projects/z80fp/MrZ80 && docker run --rm -v .:/build -w /build \
    ghcr.io/raetro/quartus:17.0 quartus_sta -t tmp/sta_cpuclk.tcl"
```

| Script | Produces |
|---|---|
| `tmp/sta_paths.tcl` | Existing-SDC worst paths per clock pair → `tmp/sta_*.txt` |
| `tmp/sta_cpuclk.tcl` | Adds `cpuClk` generated clock; clk_sys↔cpuClk setup/hold → `tmp/cc_*.txt` |
| `tmp/sta_waitn.tcl` | Per-endpoint arrival/required for `sdram_wait_n` and `sdramReadData` → `tmp/waitn_*.txt` |
| `tmp/sta_fsm.tcl` | cpuClk → selected clk_sys endpoints (FSM, MMU, BRAM) → `tmp/fsm_endpoints.txt` (script errors on a final empty pattern after writing results; harmless) |

Core of the generated-clock definition (session-only):

```tcl
project_open MultiComp -revision MultiComp
create_timing_netlist
read_sdc
set c0pin [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
create_generated_clock -name cpuClk -source $c0pin -edges {1 7 11} \
    [get_registers {emu:emu|MicrocomputerZ80CPM:MicrocomputerZ80CPM|cpuClock}]
update_timing_netlist
set c0 [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set cc [get_clocks cpuClk]
report_timing -hold -from_clock $c0 -to_clock $cc -from [get_registers {*sdram_wait_n*}] \
    -npaths 40 -detail summary -file tmp/cc_hold_waitn.txt
report_timing -setup -from_clock $cc -to_clock $c0 -npaths 20 -detail summary \
    -file tmp/cc_setup_cpu_to_sys.txt
```

Numbers in this document are from the 2026-10-03 03:09 compile; re-run after
any rebuild. Consider moving the useful scripts into `tools/` when the
project SDC is created.

---

## 10. Open questions to resolve when resuming

1. Were Phases A, B, C, D recorded for Run 2 (the A2–A4 build)? If they
   passed, there is no remaining evidence of an SDRAM data-path fault apart
   from `sdramexec`.
2. The code of the earlier reverted `cpu_wait_n_sync` attempt is not in git;
   if it can be recovered, confirm why it broke boot (likely it also delayed
   the MMU pulse / every cycle, or released on the rising edge).
3. Does `sdramexec`'s `C3→C4` rate change with step 3a / the inverted
   experiment? (Primary confirmation of section 5.)
4. After step 2, does any shipped software (CP/M BIOS, BASIC, FORTH I/O)
   depend on the *broken* INI/OUTI behaviour? (Unlikely; grep sources for
   `INIR/OTIR/INI/OUTI/INDR/OTDR`.)
5. Board round-trip delay `d` for the SDRAM module (section 6.1) — measure or
   sweep sample phase if read errors ever appear.
