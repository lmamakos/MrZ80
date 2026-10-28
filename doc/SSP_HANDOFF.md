# SSP Hand-off — current state and how to proceed

Date: 2026-10-27 · Branch `r24-p1a` (unpushed; `main` = `origin/main` =
`b12e7aa` R23) · Last design round: **R31** · Phase: **P1a ("first light")**,
simulation lane green, hardware integration not started.

This document is for the next agent picking up the System Support Processor
(SSP) work. It holds working knowledge that is **not** in the design set:
current state, the ordered plan, hazards found the hard way, commands, and
environment facts. It does not restate the design. Read in this order:

1. This document, §1–§3 (state, plan, hazards).
2. `AGENTS.md` (project rules: never touch `sys/`, LF only, um80 not pasmo,
   **what not to commit**).
3. `doc/SSP_DESIGN.md` — authoritative spec. Key parts: §2 decisions
   D-01…D-37, §6 bridge register map, §13 requirements R-xx ↔ testbenches,
   §14 open questions, §15 phasing, §17 decision log (R1…R26).
4. `doc/t80_reg_debug_vector.md` (T80 `REG` vector), `doc/SSP_REGS.md`
   (generated register table), `doc/SSP_PANEL_UX.md` (panel UX, P2).

Earlier versions of this handoff (R13–R26 working notes, superseded
theories) are in git history; the design-relevant parts were logged in
`SSP_DESIGN.md` §17.

---

## 1. Where things stand

### 1.1 Done

| Area | State |
|---|---|
| P0 (core bake-off) | Closed R23: **FemtoRV32-gracilis** selected (D-37), `ADDR_WIDTH=30` (D-34). picorv32 kept vendored as fallback. Both in `Components/RISCV/` (provenance in `PROVENANCE.md`) |
| Firmware base | Mecrisp-Quintus 1.1.2a port in `ssp/fw/` (RAM dictionary, no flash, D-32). Kernel source referenced in place from `~/mecrisp-quintus` (GPLv3; compliance vehicle per H-3/R16). Build: `cd ssp/fw && make` → `ssp/fw/build/mecrisp-ssp.hex` (build dir is git-ignored) |
| Register map | `ssp/regs/ssp_regs.csv` is canonical (72 regs / 138 fields). `make -C sim regmap` regenerates `ssp/rtl/ssp_regs.vh`, `ssp/rtl/ssp_regs_pkg.vhd`, `ssp/fw/ssp-regs.fs`, `doc/SSP_REGS.md`; `regmap-check` fails on drift (R-45) |
| P1a RTL (written, sim-verified at RV side) | `ssp/rtl/ssp_top.v` (core + MROM/RV RAM + decoder + bridge + UART + console mux), `ssp_bridge.v` (P1a registers, park controller, D-30 micro-op sequencer for FW mem/IO kicks, WDG×2, `TICK_US`), `ssp_uart.v` (8N1, RX FIFO 8, escape recognizer, OQ-22 byte relay), `z80_bus_mux.vhd` (D-26 mux, not yet instantiated anywhere), **`ssp_tramp.vhd` (R28: Z80 reset vent + reset-vector `JP aaaa` injector for `G aaaa`; verified on the real T80, not yet instantiated in the CPM core)** |
| T80 changes (R25) | `T80.vhd`/`T80_Pack.vhd`/`T80s.vhd`: `would_boundary` export + FREEZE gate (BusAck only when next state is M1; prefix-gated). In `MicrocomputerZ80CPM.vhd` the gate is **tied off** (`n_BUSRQ <= '1'`; `FREEZE_req_n => '1'` is a dead port) — zero behaviour change. Regression benches passed at R25 (run.sh 115/0, cpuregs 8/8, ixmin 10/10, ixstack, run_forth) |
| Monitor FW (R30) | `ssp/fw/apps/monitor.fs`: `E` `D` `G aaaa` `G` `R` `F` `?` (D-39), dedicated command loop, `init` runs it. `make -C sim dict-p1a` builds the dictionary artifact (`ssp/fw/build/mecrisp-ssp-p1a-app.hex`), `make -C sim smoke-p1a` runs the operator session + OM-off/on + idle-watchdog checks. Kernel `serial_key` kicks `WDG_PARK` while waiting |
| GHDL integration benches (R31) | `make -C sim integ-park` (R-40: every park on an instruction boundary vs an unparked reference), `integ-mux` (R-42: mux + real T80 + engine model), `cycle-golden` + `engine-golden` (engine strobe waveform == real T80's, per T-state, committed `sim/ssp/golden_cycles.txt`). Fixed in `ssp_bridge.v`: strobes were held through T3, I/O read split IORQ/RD, **I/O write had no WR_n** |
| P1a Verilator lane | `make -C sim p1a` → real `ssp_top` + behavioural Z80 (`sim/ssp/z80_bfm.v`) + pin-level serial. **REPL green (R26)**: escape → park → console hand-over → Mecrisp evaluates input (`1 2 + . cr` → `3 ok.`; `q` → `q not found.`) |
| Hygiene | Build dirs and waveform dumps untracked and ignored; history purged (old→new hashes: `513a539`→`9ef7346`, `ba6cc92`→`d3a8b33`, `07a4ee9`→`12ad50b`) |

### 1.2 Not started / missing

- **RTL gap (owner decision):** WDG_PARK expiry only latches `park_dead_l`;
  D-13 says it also demotes the console and releases the FW hold
  (`SSP_DESIGN.md` R30 hazard 2). Not fixed.
- Synthesis: no SSP file is in `MrZ80.qsf`; the synthesis RAM wrapper lives
  only in `bakeoff/`; no factory-ROM init path for Quartus.
- Top-level integration (`MicrocomputerZ80CPM.vhd`, `MrZ80.sv`).
- Docs debt (R24/R25 log entries, OQ-22, D-25 amendment): **paid in R30**.

### 1.3 R26 fixes (this session, for context)

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

### 1.4 R28: `G aaaa` hardware (done; design in `SSP_DESIGN.md` §7.4 / §17 R28)

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

---

## 2. How to proceed — ordered plan

Each step lists the goal, the work, the files, and the exit check. Do them
in order; steps 2 and 3 can overlap. Commit at the end of each step with a
descriptive message (heredoc, see §6). Log design-level changes as a new
round (R27, …) in `SSP_DESIGN.md` §17.

### Step 0 — Housekeeping (small, do first)

- **DONE (R30):** R24/R25 log entries written, OQ-22 closed, D-25 amended.
- `r24-p1a` is pushed to `origin` (`lmamakos/MrZ80`, owner-approved R27).
  Note: the remote named `upstream` is MiSTer-devel/MultiComp_MiSTer, the
  project this was forked from — never push there.

### Step 1 — Monitor FW for P1a (Verilator lane) — **DONE (R30)**

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

### Step 2 — GHDL integration benches (real T80, VHDL side) — **DONE (R31)**

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

### Step 3 — Synthesis prerequisites — **DONE (R32; `MrZ80.qsf` entries added in R33)**

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
   after `.qsf` changes. Gracilis has file-scope `` `define``s (§7.1) —
   check for macro collisions.

**Exit:** `tools/build.sh synth` succeeds with the SSP instantiated (step 4)
or with a temporary stub top.

### Step 4 — Top-level integration — **DONE (R33); `make -C sim integ-core` is the R-42 SDRAM/BRAM/MMU bench**

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
     (`sim/check_sync.sh`; recipe and gotcha in §5).
2. **`MrZ80.sv`** (core shell):
   - Instantiate `ssp_top`. OSD status bits: design uses **bit 20 = monitor
     enable (`osd_ok`)** and **bit 22 = Serial Escape (`OM`)**; also a
     "Reset SSP" item for `rv_rst_n`. Bits 0, 9–19 are taken (§7.3).
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
     (shared truth, §5.3).
   - Tie `dl_*` (MROM download, P1b) inactive.
3. Capture chain: the 64-bit `SSP_CHAIN` export is allocated bits 292–355
   (of `CHAIN_BITS => 384`, ~line 803). Not needed for P1a; when added, update
   `SIGNAL-CAPTURES.md` in the same change.

**Exit:** with OSD monitor-enable off, the core behaves exactly as before
(CP/M boots and runs; GHDL regressions unchanged); full compile passes
timing.

### Step 5 — Hardware first light (P1a exit) — **DONE (R35): all items PASS on hardware 2026-10-27; P1a CLOSED**

`tools/build.sh` (full compile on `tycho`), then `make install` (scp to
host `mister`). P1a exit criteria (`SSP_DESIGN.md` §15): on hardware,
escape into the SSP, examine/deposit Z80 memory, resume — with OM off
proven bit-transparent. Record results as a design round.

### After P1a — P1b preview (owner priorities at first light, R35)

Owner requirements raised at first light — all already in P1b scope, now the
leading items: **(a)** physical 28-bit memory examine/deposit -> `MD`/`AR`/`DR`
shared regs + `ssp_mem_client` (parked physical client borrowing the SDRAM
client wiring — SDRAM pages only; the BRAM page is deferred by owner ruling
R35, physical ops there rejected `?`; `z80_bus_mux` unchanged — it stays the logical,
cycle-faithful Z80 path, R35 assessment); **(b)** Z80 I/O port commands ->
FW-only (`I`/`O`; the D-30 sequencer's IO_RD/IO_WR are already golden-verified);
**(c)** MMU inspection + logical->physical display -> FW `MAP` via engine I/O
reads of $B0..$BF (the permanent path — see R38); `PHY`/`LOG` mode verbs;
physical-vs-logical command letters = OQ-24. Also pending: `PR`/mailbox, step
assist, MROM/MPKG mount path, ODT skin. Bridge board design (OQ-09) runs in
parallel. **R38: the direct MMU frame-tap interface (and with it the
`MAP_CHANGED` IRQ producer) is shelved** — owner analysis: the MiSTer OSD is a
configuration surface (escape char, SD mount, ROM download: static, not
debug-hot), and the FPGA-video terminal is serial-like; MMU awareness is
human-scale and parked-CPU-only, and the `$B0..$BF` engine path covers every
such need. `MAP0..3` stay reserved in the regmap (reads 0) and the IRQ bit
defined but producerless, preserving ABI. If a live-running-system consumer
ever materialises (e.g. bank-state lamps on an OSD overlay), the tap is the
reactivation path.

**M1 DONE (R37):** `I`/`O`/`MAP`/`PHY`/`LOG` + colour stubs are in the monitor
(`monitor.fs`), covered by new Part E of `p1a_smoke.sh`; item (b) is fully
closed — with the owner ruling that port I/O is address-mode-independent, the
bridge now rejects only MEMORY kicks while `MD=physical` (`IS_IO` exempt).
Physical E/D (item (a)) still awaits `ssp_mem_client` (M3): FW refuses with
`PHYSICAL E/D PENDING M3`. `MAP` reads the $B0..$BF engine path — permanent per
R38 (direct frame taps shelved). Factory `forth_rom.mif` regenerated
with M1; owner rebuild (`tools/build.sh`) + `make install` to see the new
commands on hardware.

### Owner questions outstanding

| # | Question | Where it blocks |
|---|---|---|
| — | Answered R27: command set (D-39), commit factory ROM (D-38), console follows OSD port (D-40), push to `origin` (done) | — |
| new | Final command letters and the modify-session terminator (proposed: `E`, `D`, `G`, `.`) — confirm only if changing | Step 1 |
| OQ-10 | Exact "Reset System" scope | P1b |
| OQ-18 | Board-freeze UX values | P2 |

---

## 3. Hazards and lessons (read before debugging)

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

---

## 4. Command reference

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

---

## 5. Simulation infrastructure facts

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
  Step 4 edits the top level, so resync in the same change (consider
  generating the copy with `sed` in the runner — propose to the owner).
- `tb_inir_race` hitting the 20 ms cap with 0 mismatches is documented
  known-good partial behaviour (`sim/STATUS.md`).
- Behavioural stand-ins available: `behav_ram_rom.vhd`, `behav_display.vhd`,
  `sdram_cdc_fake.vhd`. `testbenchs/` (sic) holds timing dumps, not HDL.
- The p1a BFM is **not** cycle-exact T80: it accepts FREEZE only at its own
  instruction boundaries. The real gate is proven only by step 2.

---

## 6. Conventions (owner)

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
- Editing `SSP_DESIGN.md` (~1450 lines, very long table rows): use the edit
  tool with a short unique substring; for larger moves, a Python script with
  `assert s.count(old) == 1`. Verify no CR bytes: `grep -c $'\r' <file>` → 0.

---

## 7. Reference notes

### 7.1 FemtoRV32-gracilis (`module FemtoRV32`)

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

### 7.2 SSP memory map and FW console

ROM `0x0000_0000` (64K; writable only in dictionary window
`0x4400..0x10000`, D-35), RV RAM `0x1000_0000` (64K), bridge
`0x2000_0000` (4K, decode `mem_addr[31:12] == 20'h20000`, word index
`mem_addr[11:2]`). FW console (`ssp/fw/terminal.s`): TXDATA `+0x120`,
RXDATA `+0x124`, STAT `+0x128` (bit0 tx_ready, bit1 rx_avail, bit2
overrun), CTRL `+0x12C`.

### 7.3 Codebase anchors

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

## 8. Environment facts (verified 2026-10-26/27)

### 8.1 Local workstation (Debian forky/sid)

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

### 8.2 Network from the agent shell

- `git push`/`fetch` to `origin` (`git@github.com:lmamakos/MrZ80`, SSH)
  **works** (verified 2026-10-27, R27 push; earlier notes said SSH was not
  authorized — no longer true for this repo). `git clone https://...` of
  other repos still fails (credential prompt, no TTY).
- Works: `curl` to `raw.githubusercontent.com` (single files) and
  `api.github.com` (unauthenticated, ~60 req/h; use `-L`).
- `webfetch`/`websearch` tools work.

### 8.3 Remote Quartus (`tycho`)

- `tools/quartus_build.sh` runs Quartus 17.0 in Docker on `tycho` against
  `Projects/z80fp/MrZ80`, **the same tree as this workspace** (no sync step;
  owner-confirmed). The script's header comment naming
  `RomWBW_MrZ80_MiSTer` is stale. `ssh -t` may complain without a TTY; do
  not edit the script without the owner's agreement.
- Bake-off fits (R21, `bakeoff/`): gracilis 1,128 ALM / 540 reg / 64.13 MHz;
  memory 130 M10K blocks for 64K ROM + 64K RV RAM.

---

## 9. History pointer

Commit trail on `r24-p1a` (newest first): R28 `G aaaa` hardware (this
commit) · `54d6f42`/`f28289a` R27 owner rulings D-38…D-40 · `e7e23be` R26 TX-mux erratum + handoff rewrite · `8727a10` AGENTS.md what-not-to-commit ·
`4de3ae1` handoff purge record · `9391356`/`aed8f48` untrack VCD / obj dirs
· `12ad50b` R26 REPL green · `d3a8b33` rx_rnext wiring · `9ef7346` P1a lane
WIP · `e94018b` R25 · then `main`: `b12e7aa` R23 · `864903c` R22 ·
`da181a3` R21 · `c84da00` R20 · `ef9867d` R19 · … (full log:
`git log --oneline`). Design rationale for every round is in
`SSP_DESIGN.md` §17.
