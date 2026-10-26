# SSP Hand-off — working knowledge not captured elsewhere

Date: 2026-10-26 · Baseline: R17 (this commit), prev `e6c83f9` (branch `main`, working tree
clean) · Author: design-session agent, rounds R13–R15.

**Scope.** This document holds *only* information that is not already in
the design set: environment facts, tool availability, integration hazards
found in the code, things verified by running them, and how this project's
design sessions are run. It does **not** restate the design. For that, read
in this order:

1. `doc/SSP_DESIGN.md` — authoritative spec (v1.0-draft, rounds R1–R15;
   §2 decisions D-01…D-32, §15 phasing, §16 resume checklist, §17 log).
2. `doc/SSP_PANEL_UX.md` — panel UX (v0.2).
3. `doc/SDRAM_REWORK_PLAN.md` — memory roadmap (D-S1…D-S6).
4. `doc/t80_reg_debug_vector.md` — T80 `REG` vector semantics.
5. `Components/RISCV/PROVENANCE.md` — vendored cores, pins, hashes.

Items marked **H-n** are new findings from preparing this hand-off. They
are *not yet* in `SSP_DESIGN.md`; §9 suggests recording them as round R16.

---

## 1. Where things stand

| Area | State |
|---|---|
| Design docs | Complete through R17 and committed. No RTL for the SSP exists yet |
| Cores | `picorv32.v` and `femtorv32_gracilis.v` (+`utils.v`) vendored verbatim in `Components/RISCV/`, **not** in `MrZ80.qsf` yet |
| Phase | **P0** (two-core bake-off). Done: vendoring, license check, **toolchain
install + smoke test**, **GHDL sim resync + green baseline**, **R16
decisions logged**, **D-29 regmap pipeline live** (CSV + generator +
`make -C sim regmap-check`), **R17: minimal flash-free Mecrisp port built
and REPL-verified on qemu** (`ssp/fw/` + `make -C sim smoke-qemu` PASS;
UART regs in CSV; `tools/bin2hex.py`). Not started: stub SoC per core
(`sim/ssp/`, Verilator — ready to consume `ssp/fw/build/mecrisp-ssp.hex`),
`fit.rpt` ×2 |
| Owner decisions pending | OQ-10 (Reset-System scope), OQ-18 (board-freeze UX values). OQ-22/OQ-23 are settled by simulation, not by the owner |

Commit trail for these sessions (newest first): **R17 flash-free Mecrisp port + qemu smoke (this commit)** · `e6c83f9` R16 decisions + regmap pipeline · `4783106` tools installed · `8b9f192` sim resync
(H-1 closed) · `2ed69c3` hand-off doc · `e41d5fc` R15 review ·
`77208cd` cores vendored · `5e8ae1a` R14 bake-off · `d964f59` R13 ODT→SSP
rename · `022bb95` R12 · `b86a21d` R11.

---

## 2. Environment facts (verified 2026-10-26)

### 2.1 Local workstation (Debian forky/sid)

**Toolset install DONE 2026-10-26** (owner-approved):
`sudo apt-get install gcc-riscv64-unknown-elf verilator iverilog gtkwave yosys`
— all succeeded. Verified state:

| Tool | Version | Notes |
|---|---|---|
| `ghdl` | 6.0.0 | existing VHDL sim flow (§3) |
| `riscv64-unknown-elf-gcc` | **15.3.0** (new) | binutils/`as`/`ld` 2.47 — ≥2.38, so the `_zicsr_zifencei` march suffix is required (already the convention, §5.8 toolchain note) |
| `verilator` | **5.048** (new) | D-28 Verilator level |
| `iverilog` | **13.0** (new) | quick Verilog unit sims; version flag is `-V` |
| `yosys` | **0.66** (new) | early core lint/synth sanity without Quartus |
| `gtkwave` | **3.3.127** (new) | needs a display; headless invocation fails, expected |
| `python3` 3.14, `make` 4.4, `curl` | installed | |
| `qemu-system-riscv32` | **11.1.2** (new, R17) | `-M virt -cpu rv32
  -bios none -kernel <elf>` runs the FW smoke variant (`make -C sim
  smoke-qemu`) |
| `gdb-multiarch` | installed (new, R17) | attach: qemu `-s -S`,
  `target remote :1234` (no riscv-specific gdb needed) |
| Questa/ModelSim (`vsim`) | missing | not needed — GHDL covers VHDL (§3) |
| `docker` | **missing locally** | Docker exists only on `tycho` (Quartus builds) |
| `pasmo` | present | **Forbidden** for Z80 code (AGENTS.md). Use `tools/z80asm.sh` / `um80.sh` / `ul80.sh` |

**Toolchain smoke test (passed):** assembling with the exact P0 flags
`-march=rv32imc_zicsr_zifencei -mabi=ilp32 -nostdlib` produced a 32-bit
RISC-V/RVC ELF with correct compressed encodings (`c.addi`, `jr`) and
`csrr t1,mcycle`. Lessons recorded:
- `riscv64-unknown-elf-ld` default script is a picolibc `flash`/`ram`
  memory map: **`-nostdlib` alone still picks it up and link fails** —
  P0 must ship its own linker script defining the MROM/DTCM regions
  (`SSP_DESIGN.md` §5.2). Smoke-test pattern: `MEMORY { ROM (rx) :
  ORIGIN = 0, LENGTH = 64K }`.
- `-print-multi-lib` has `rv32imac/ilp32` but no `rv32imc` entry; linking
  plain `-march=rv32imc…` resolves to the `rv32imac` multilib — standard,
  harmless for freestanding code (no libs used).

### 2.2 Network access from the agent shell

- `git clone https://github.com/...` **fails**: it prompts for credentials
  and there is no TTY. `git@github.com:` SSH is **not authorized**.
- **What works:** `curl` against `raw.githubusercontent.com` (individual
  files) and against `api.github.com` (unauthenticated; ~60 requests/hour).
  Recipe used for vendoring:
  - file: `curl -sS -o f.v https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`
  - pin a file's last commit: `curl -sSL "https://api.github.com/repos/<o>/<r>/commits?path=<path>&per_page=1"`
  - list a tree: `.../git/trees/<branch>?recursive=1`
  - **use `-L`**: `cliffordwolf/picorv32` redirects (301) to YosysHQ.
  - The API returns pretty-printed JSON. Grep with `'"sha": *"…"'` (note
    the space).
- Repo-name trap: FemtoRV lives at **`BrunoLevy/learn-fpga`**. Other
  owner/fork names that turned up return 404.
- `webfetch`/`websearch` tools work for reading pages.

### 2.3 Remote Quartus (`tycho`)

- `tools/quartus_build.sh` runs `ssh -t tycho "cd Projects/z80fp/MrZ80 &&
  docker run --rm -v .:/build ghcr.io/raetro/quartus:17.0 quartus_sh …"`.
  There is **no rsync step**, so the remote tree must already reflect local
  edits; the setup implies a shared/synced checkout. Confirm with the owner
  before the first P0 synth.
- The script header comment names `Projects/z80fp/RomWBW_MrZ80_MiSTer`, but
  the command uses `Projects/z80fp/MrZ80`. The comment is stale.
- `ssh -t` asks for a TTY. In a non-interactive agent shell this may warn or
  fail (untested this session). `ssh -tt` or dropping `-t` are the usual
  fixes. Don't edit the script without the owner's agreement.
- `Makefile` target `install` copies `output_files/MrZ80.rbf` to the MiSTer
  (`scp` to host `mister`).

---

## 3. Existing simulation infrastructure — D-28 must build on it

D-28 (R15) was written assuming no simulation infrastructure existed. **That
is wrong: there is a working GHDL flow in `sim/`** (introduced during the
SDRAM investigation; see `sim/STATUS.md`). Key facts:

- **Runner pattern:** `sim/run_*.sh` scripts, run from the project root,
  build into `/tmp/<name>` work dirs with
  `ghdl --std=08 [-fsynopsys] --workdir=…`. Test payloads are assembled
  with `tools/z80asm.sh` (um80).
- **Why `*_sim.vhd` copies exist:** GHDL rejects user re-implementations of
  the proprietary `STD_LOGIC_ARITH`/`STD_LOGIC_UNSIGNED`.
  `sim/sim_compat_pkg.vhd` provides the needed operators, and
  `MicrocomputerZ80CPM_sim.vhd`, `bufferedUART_sim.vhd` and
  `sd_controller_sim.vhd` are copies with only the `use` lines redirected.
  `sim/check_sync.sh` enforces this.
- **H-1 — top-level sim copy drift: RESOLVED 2026-10-26, commit
  `8b9f192`.** `sim/MicrocomputerZ80CPM_sim.vhd` had predated the
  capture-chain extension (bits 224–291) and the
  `n_INT/n_NMI/n_BUSRQ/n_M1/n_HALT/n_BUSAK` wiring, blocking every
  full-system bench. Resynced per the script's recipe. **Gotcha learned
  (worth remembering for every future resync):** the real top level has
  *no* `use ieee.numeric_std.all`, so the redirect must be the canonical
  **pair** — line 18 → `use ieee.numeric_std.all;`, line 19 →
  `use work.sim_compat_pkg.all;`. Replacing both lines with
  `sim_compat_pkg` alone loses `numeric_std` and dies on the `unsigned`
  subtype/conversion uses (`reset_counter` etc.); GHDL's numeric_std with
  `-fsynopsys` supplies those directly, no new shim declarations needed.
  SSP integration will edit the top level often, so consider replacing
  the manual copy with a `sed`-generated copy in the runners. Small
  tooling change; propose it to the owner.
- **Green baseline re-established 2026-10-26 (post-resync, verified
  runs):** `check_sync.sh` OK ×3 · `tb_cpuregs`: **all 8 cases
  PASSED** · `tb_frontpanel`: **PASS** (exercises the new 292-bit chain
  against `FrontPanel_Subsystem`) · `tb_inir_race`: runs; 115 iterations,
  0 mismatches, DONE-flag timeout at the 20 ms cap — documented
  known-good partial behaviour (`sim/STATUS.md`).
- **Harness for D-25 work:** `sim/run_cpuregs.sh` (T80-only:
  `T80*.vhd` + `tb_cpuregs.vhd`, no compat package needed) →
  This is the natural harness for the
  D-25 `insn_end` export and boundary-park work: same file set, add cases.
- Other testbenches available to reuse: `tb_frontpanel.vhd` (panel/chain),
  `tb_inir_race.vhd`, `tb_blockdev_prog.vhd`, `tb_hps_blockdev.vhd`,
  `tb_forth.vhd`. Behavioural stand-ins: `behav_ram_rom.vhd`,
  `behav_display.vhd`, `sdram_cdc_fake.vhd`.
- `testbenchs/` (sic) holds timing-analysis text dumps (`cc_*.txt`), not
  HDL testbenches.

**Implications for D-28 (recommend recording in R16):**
1. Integration simulator = **GHDL** (installed, proven here). Drop Questa
   from the plan unless a need appears.
2. Layout: keep the existing `sim/` flat files untouched. Put new work in
   `sim/ssp/` (Verilator: RV core + ROM/DTCM + bridge MMIO + Mecrisp REPL)
   and integration benches as `sim/run_ssp_*.sh` / `sim/tb_ssp_*.vhd`,
   following the existing runner pattern.
3. **H-4 — language split.** GHDL cannot read Verilog, Verilator cannot
   read VHDL, and `ghdl-yosys-plugin` isn't packaged. So write everything
   on the **Z80 side** of the boundary in **VHDL**: `z80_bus_mux`, the
   cycle-faithful engine/micro-op sequencer, boundary-park logic, the
   escape recognizer, `fp_capture`/`fp_engine`. GHDL integration tests
   then run against the real T80, MMU and SDRAM client FSM with no mixed
   language. Keep the **RV side** (core, ROM/DTCM, decoder) in Verilog.
   The bridge register file is the seam: either VHDL with the RV side driven
   by a small VHDL bus model in GHDL, or Verilog with the Z80 side mocked in
   Verilator. Decide before writing `ssp_bridge`. Quartus mixes languages
   freely, so this only affects simulation. This changes the `.v` suffixes
   in the design module table, which were only nominal.

---

## 4. Core integration notes (from reading the vendored sources)

### 4.1 FemtoRV32 gracilis (`module FemtoRV32`)

- **H-2 — `ADDR_WIDTH` defaults to 24.** PC and load/store addresses are
  `ADDR_WIDTH` bits wide (`femtorv32_gracilis.v:~42, 242-265`). With 24
  bits, the design memory map (DTCM `0x1000_0000`, bridge `0x2000_0000`,
  §5.2) aliases onto `0x0000_0000`. Either instantiate with
  **`ADDR_WIDTH=30`** (or 32) or compact the SSP memory map (e.g. ROM
  `0x00_0000`, DTCM `0x10_0000`, bridge `0x20_0000`). FemtoSoC itself puts
  I/O at bit 22 to stay inside 24 bits. Record the choice in §5.2.
- `reset` is **active-low** ("set to 0 to reset"). `RESET_ADDR` parameter
  defaults to 0.
- Bus: `mem_rstrb` is a one-cycle read strobe. Read data is expected on
  the next cycle unless `mem_rbusy` is held; writes are signalled by a
  non-zero `mem_wmask`, with stalls via `mem_wbusy`. A registered-output
  M10K fits the read timing.
- Single `interrupt_request` input (unused in v1, D-27). 64-bit `cycles`
  CSR (`rdcycle`/`rdcycleh`) is free-running.
- File-scope `` `define NRV_ARCH/NRV_ABI/NRV_OPTIMIZE/NRV_INTERRUPTS `` and
  `utils.v`'s `bench`/`verbose` macros are global within the compilation
  in Quartus. Harmless unless a name collides. The generic module name
  `FemtoRV32` is collision-free in this repo today.

### 4.2 PicoRV32 (`module picorv32`)

Parameters to set for the P0 entry (defaults in brackets):
`COMPRESSED_ISA=1` [0] · `ENABLE_MUL=1` and `ENABLE_DIV=1` [0] (or
`ENABLE_FAST_MUL` for DSP multipliers) · **`ENABLE_IRQ=0`** [0] (polled
FW, D-27; leaving it 0 also keeps the register file at 32 entries) ·
`ENABLE_COUNTERS=1` [1] (`rdcycle`) · `BARREL_SHIFTER=1` [0] (optional;
cheap on Cyclone V) · `PROGADDR_RESET=0` · `STACKADDR` (Mecrisp sets its
own stacks; leave the default or point at DTCM top) · keep
`CATCH_MISALIGN`/`CATCH_ILLINSN`.

- `resetn` is **active-low**. Native interface is `mem_valid/mem_ready/
  mem_wstrb/mem_instr`. The look-ahead `mem_la_*` outputs allow 0-wait BRAM
  if wanted.
- The `trap` output goes high when the core halts on an illegal or
  misaligned access. **Wire it into a bridge status bit**: it's a free
  "SSP firmware crashed" indicator for the WDG/lamp chrome.
- `picorv32.v` also defines `picorv32_axi`, `picorv32_wb`, the PCPI
  multipliers and `picorv32_regs`. Uninstantiated modules cost nothing.

### 4.3 Mecrisp-Quintus

- **H-3 — License: Mecrisp is GPLv3** (stated in learn-fpga's
  `FemtoRV/FIRMWARE/MECRISP_QUINTUS/README.md`). The plan commits a factory
  `ssp/fw/forth_rom.hex` and embeds it in the bitstream (D-10). Shipping
  that `.rbf` or hex means distributing a GPLv3 binary, so the
  corresponding source (Mecrisp, plus our port glue) must be offered. The
  repo's own license is Grant Searle's acknowledgement/free-of-charge terms
  (`README.md` §License). Raise this with the owner before committing any
  Mecrisp binary. The simplest compliance is vendoring the exact Mecrisp
  source used under `ssp/fw/` with its license.
- **Sources:** official releases on SourceForge (`mecrisp` project,
  Mecrisp-Quintus tarballs); GitHub mirror `hansfbaier/mecrisp-quintus`.
  Mecrisp-Quintus's first targets were **PicoSoC** (picorv32) and a
  Stellaris RV32IM emulation. learn-fpga only ships **pre-built IceStick
  binaries** (`mecrisp-quintus-hx1k*.bin`), which are tied to FemtoSoC's
  memory map and not usable as-is.
- To verify in P0: which port directories the current release ships
  (picosoc / femtorv), how the RAM-only (`compiletoram`) build is
  configured (D-32), and what flash words need stubbing.

---

## 5. Codebase facts relevant to landing SSP RTL

- **H-5 — capture chain has grown.** `SIGNAL-CAPTURES.md` is the
  *authoritative* chain map and must be updated in the same change as any
  chain edit (its maintenance note says so). The chain is now **292 bits
  used of `CHAIN_BITS => 384`** (`MicrocomputerZ80CPM.vhd:~800`): fpLatch
  0–7, bus 8–31, registers 32–223, MMU physical address 224–251, CPU
  control strobes 252–259 (incl. **BUSRQ 256, M1 257, HALT 258, BUSAK
  259**: panel lamps for SSP park state already exist), reserved 260–279,
  stretched strobes 280–283, fpLatch echo 284–291. **The 64-bit
  `SSP_CHAIN` fits at 292–355**, leaving 28 spare. LED map entries are
  10 bits wide above 256 chain bits, which matches `LED_DATA "≤10b"`.
  `SSP_DESIGN.md` §3/§11.4 still describe the old "24-bit head" chain
  (**H-6**, stale).
- **Hook points now exist as named signals** at `MicrocomputerZ80CPM.vhd`
  ~lines 150–160 (declarations) and ~406–412: `n_INT <= '1'; n_NMI <= '1';
  n_BUSRQ <= '1';`. The SSP drives `n_BUSRQ` here (via D-25 gating), and
  `m1_n/halt_n/busak_n` are already brought out of `T80s`. The `§3`
  anchor `busrq_n => '1'` (~352) is out of date.
- `cpu_mrd_t1` → `sdram_spec_go` (~1090) and `cpu_wait_n` (~472) are the
  D-26 points. The long comment block above the SDRAM client FSM
  (~980–1080) explains the speculative-read timing the engine must
  reproduce. Read it before writing the engine.
- LED profile tooling exists: `Components/FRONTPANEL/tools/` (YAML →
  `.fpp`, Makefile with MiSTer install). Use it to produce the profile-7
  identity/page maps instead of hand-writing tables.
- Root-level history docs worth knowing: `HISTORY.md`,
  `SDRAM-review-handoff.md` (T80 block-I/O HL bug, `cpuClock` hazard),
  `sim/STATUS.md`. The REVERTED SDRAM fix noted at the `S_DONE` state must
  not be retried.

---

## 6. How design sessions run (owner conventions)

- **Docs first, decisions logged.** Each owner session is a round
  `Rn` in `SSP_DESIGN.md` §17. Decisions get `D-nn` rows in §2 with a
  rejected-alternatives column. Open questions are `OQ-nn` in §14 with a
  "lean". Status tags are `[verified]/[decided]/[proposed]/[open]/[deferred]`.
  The version stays **v1.0-draft**; the round number is the real version.
- **Never rewrite history.** Wrong statements in earlier rounds get an
  inline **`[Rn erratum: …]`** marker (see the §5.8 R11/R14 IRQ text);
  superseded text stays, with a "superseded by" note.
- The owner usually accepts a recommendation set **with targeted
  modifications** (e.g. R15: escape must be a *specific* char *and*
  OSD-gated; no flash emulation). Implement the modification exactly and
  log the declined alternative.
- For real choices, the owner prefers the question tool, with the
  recommended option first and labelled "(Recommended)".
- Commit at the end of each round with a descriptive message. Pass
  multi-line messages via heredoc (`git commit -F - <<'MSG'`): zsh broke on
  an embedded `"` in a `-m` string.
- Hard rules (AGENTS.md): LF only; never touch `sys/`; um80/ul80 via the
  `tools/` wrappers, never pasmo; PLL IP is generated, don't hand-edit.
- Naming is canonical since R13: `ssp_*` modules, `ssp/rtl`, `ssp/fw`,
  `SSP_CTRL/SSP_CHAIN`, FW word `PAGE n`. "ODT" appears only for Intel
  heritage: "ODT-style", the FW skin word `ODT`, `archive/ODT_CHANGE.md`.

### Editing `SSP_DESIGN.md` efficiently

- It's ~1350 lines with very long single-line table rows. Use the edit tool
  with a short, unique substring of a row. For multi-block moves, a small
  Python script with `assert s.count(old)==1` before writing is safe: it
  aborts without touching the file.
- After any rename or terminology change, grep for leftovers
  (`SimpleBus`, `monitor/rtl`, `tb_mon_`, `gracilis RV32IMC`, …) and expect
  hits only in the naming map, the alternatives columns, the shelved §5.7,
  and the logs.
- Verify no CR bytes: `grep -c $'\r' <file>` → 0.

---

## 7. Suggested concrete next steps (P0)

1. ~~Owner approves the tool install (§2.1), then install.~~ **DONE
   2026-10-26** — approved, installed, smoke-tested (§2.1).
2. ~~Resync `sim/MicrocomputerZ80CPM_sim.vhd` (H-1), run
   `sim/check_sync.sh` and one full-system bench (e.g. `sim/run.sh`) to
   re-establish a green baseline.~~ **DONE** — commit `8b9f192`; all
   three benches verified (§3).
3. ~~Decide the language seam (H-4) and gracilis `ADDR_WIDTH`/memory map
   (H-2). Record both as R16 together with H-3/H-5/H-6.~~ **DONE — R16
   logged `e6c83f9`** (D-33 seam, D-34 `ADDR_WIDTH=30`, H-3 repo,
   H-5/H-6 fixes, H-7/H-8).
4. ~~`ssp/regs/ssp_regs.csv` seeded from §6 + `tools/ssp_regmap.py`
   (D-29)~~ **DONE `e6c83f9`** — CSV canonical (68 regs/129 fields);
   generator emits `.vh`/`.vhd`/`.fs`/Markdown; `make -C sim
   regmap-check` = R-45, green.
5. `sim/ssp/`: Verilator stub SoC per core (core + ROM/DTCM + UART MMIO +
   `TICK_US`). First milestone: a hand-written RV32 "hello" over the UART
   model. Second: Mecrisp REPL (needs H-3 cleared for vendoring sources).
6. Add `insn_end` cases to `tb_cpuregs` (or a sibling `tb_insn_end.vhd`)
   before modifying `T80s`. The existing passing bench is the regression
   guard.
7. Quartus: `.qip` per core and a throwaway synthesis top for each, then
   `tools/build.sh synth`. Record ALUT/M10K/fmax in §5.8/§12 to close the
   bake-off together with the sim evidence.

---

## 8. Things deliberately *not* done

- ~~No packages installed~~ **done 2026-10-26 with owner approval**
  (§2.1). Still no edits to `tools/`, `MrZ80.qsf`, RTL, or `sys/`.
  `sim/` edited only for the H-1 resync (`8b9f192`).
- ~~`sim/MicrocomputerZ80CPM_sim.vhd` drift~~ **fixed** (H-1 closed).
- Mecrisp sources not downloaded (license question H-3 first).
- riscv-formal (eqy container) not attempted. It's optional and off the
  critical path. (`yosys` is now installed locally, which is one of its
  prerequisites; `sby` is not.)

## 9. R16 entries -- disposition (logged 2026-10-26, commit `e6c83f9`)

| # | Finding | Disposition |
|---|---|---|
| H-1 | sim copy drift | **closed `8b9f192`** -- resynced; generated-copy idea still open (worth doing before SSP top-level edits begin) |
| H-2 | gracilis `ADDR_WIDTH=24` aliases the 5.2 map | **closed R16 -- D-34**: `ADDR_WIDTH=30` at instantiation; map unchanged |
| H-3 | Mecrisp-Quintus is GPLv3 | **closed R16**: owner supplied in-tree reference repo `~/mecrisp-quintus` (1.1.2a, GPL-3.0+) = compliance vehicle; assets listed in `SSP_DESIGN.md` 5.5 |
| H-4 | No mixed-language simulator | **closed R16 -- D-33**: Z80-side VHDL (GHDL), RV-side Verilog (Verilator), seam crossed at `ssp_top` |
| H-5 | Chain is 292/384 bits | **recorded R16**: SSP export allocated 292-355; `SIGNAL-CAPTURES.md` row lands with the P2 chain edit |
| H-6 | stale chain description/anchors | **fixed R16** (doc pass) |
| H-7 | D-28 named Questa | **closed R16**: D-28 amended -- GHDL for integration |
| H-8 | picorv32 `trap` output | **closed R16**: `STATUS.rv_trap` (bit 18) in CSV + 6 |

### New assets since the first version of this doc (all committed)

- `~/mecrisp-quintus` -- **external reference repo** (not inside the
  MrZ80 repo): Mecrisp-Quintus 1.1.2a full source. Key paths:
  `mecrisp-quintus-source/` (core `.s` sections + `common/` tools incl
  RV32IMC disassembler/assembler), `common-verilog/` (FemtoRV variants
  incl. gracilis -- whitespace-only diff vs our vendored copy -- `uart.v`,
  `MappedSPIFlash.v`, `celement.v`), `release/quintusemu-*` host
  emulators, `linux-rv32imc/` native runtime, per-target build pattern
  (`hx1k/mecrisp-quintus-hx1k.s` + `memmap` + `Makefile` +
  `terminal.s`). Release Makefiles use legacy `riscv64-linux-gnu` +
  `-march=rv32i` -- adapt to the 5.8 flags, don't copy verbatim.
- D-29 regmap pipeline: `ssp/regs/ssp_regs.csv` (canonical, 68 regs /
  129 fields) + `tools/ssp_regmap.py` + generated `ssp/rtl/ssp_regs.vh`
  (iverilog-validated), `ssp/rtl/ssp_regs_pkg.vhd` (ghdl-validated),
  `ssp/fw/ssp-regs.fs`, `doc/SSP_REGS.md`, and `sim/Makefile`
  (`make -C sim regmap-check` = R-45).
- Commit chain: `e6c83f9` R16 -- `4783106` tools installed --
  `8b9f192` sim resync -- `2ed69c3` this doc (first version).
