# sim/ - GHDL testbench status (handoff notes)

## Purpose

This testbench was built to reproduce (or refute) the finding from
`testing/backtoback.asm` Phase A2/A3: the very first `INIR`-driven read of
the MMU direct-access port (0xBC), writing into a block-RAM destination,
deterministically captures the wrong byte (`exp=00 got=FF`), while an
otherwise-identical plain `IN r,(C)` (Phase A4) never does. See
`testing/backtoback.asm`'s header comments and `HISTORY.md` for the full
prior investigation (the `sdram_fsm` in `MicrocomputerZ80CPM.vhd`, the 2-FF
CDC synchroniser in `MultiComp.sv:260-320`, and a REVERTED, incorrect fix
attempt already tried there -- do not repeat that specific fix, see the
comment left at `MicrocomputerZ80CPM.vhd`'s `S_DONE` state).

No simulation infrastructure existed in this repo before this session --
everything under `sim/` is new.

## What's here and why

- `sim_compat_pkg.vhd` -- GHDL cannot use the real (proprietary,
  non-redistributable) `IEEE.STD_LOGIC_ARITH`/`STD_LOGIC_UNSIGNED`
  packages that `MicrocomputerZ80CPM.vhd`, `bufferedUART.vhd`, and
  `sd_controller.vhd` use (GHDL even has special built-in recognition of
  those package names and rejects user-reimplementations of them
  directly). This package reimplements the small set of operators those
  three files actually need (`+`, `-`, `<`, `=` between `std_logic_vector`
  and `integer`, unsigned semantics).
- `MicrocomputerZ80CPM_sim.vhd`, `bufferedUART_sim.vhd`,
  `sd_controller_sim.vhd` -- simulation-only copies of the real files with
  ONLY their Synopsys `use` line(s) redirected to `sim_compat_pkg`
  (+ `ieee.numeric_std` for the first one, which didn't already import
  it). **Never edit these by hand** -- regenerate via `cp` from the real
  file and reapply the redirect, then run `check_sync.sh`.
- `check_sync.sh` -- diffs each `*_sim.vhd` against its real counterpart
  and FAILS if anything beyond the expected redirected line(s) differs.
  Run after any edit to the real files or their copies. `run.sh` calls
  this automatically before compiling.
- `behav_ram_rom.vhd`, `behav_display.vhd` -- behavioral (non-megafunction)
  stand-ins for `InternalRam64K`, `Z80_CPM_BASIC_ROM`, and
  `SBCTextDisplayRGB`'s font/display-RAM chain, all of which are Quartus
  MegaWizard `altsyncram` wrappers needing the Altera `altera_mf`
  simulation library (present as source under Quartus's `eda/sim_lib/` on
  `tycho`, but no simulator that can use it -- `ghdl`/`vsim`/`iverilog` are
  all absent from that Docker image; only `ghdl` is available, locally).
- `sdram_cdc_fake.vhd` -- a **faithful, byte-for-byte VHDL translation**
  of `MultiComp.sv:260-320`'s actual 2-FF request/done CDC synchroniser
  (the mechanism under suspicion), driving a small behavioral model of the
  real `sdram_32r8w` controller's CPU-port handshake timing (~3 cycle ack,
  ~7 cycle ready for reads / ~3 for writes -- see the header comment for
  how those numbers were derived from `Components/SDRAM/sdram2.sv`). NOT
  sync-checked (it's a Verilog->VHDL translation, not a language-identical
  copy) -- re-verify by hand against `MultiComp.sv:260-320` if that file
  ever changes.
- `sim_inir_race.asm` -- Z-80 test payload. Sweeps a variable-length NOP
  preamble (D = 0..199) before each of 200 outer iterations' single
  8-byte `INIR` read from the direct-access port (reset to physical
  address 0 each iteration), verifying `buf[i] == i` (the fake SDRAM model
  returns `(byte address) mod 256` for any read). Records results
  (running mismatch count, first-failure delay/offset/expected/got,
  iteration count, done flag) to fixed addresses `0x0900-0x0908`.
  Build: `tools/z80asm.sh -o <dir>/sim_inir_race sim/sim_inir_race.asm`
  (done automatically by `run.sh`).
- `tb_inir_race.vhd` -- top-level testbench. Free-running `clk_sys`
  (~50 MHz) and `clk_ram` (~112 MHz), **not** phase-locked to each other
  (matching the real async relationship). Preloads the assembled `.bin`
  directly into block RAM via the `dl_bram_*` download port while the CPU
  is held in reset (mirrors the real "Boot Load Target = Block RAM" OSD
  path). Monitors results live via a VHDL-2008 *external name* probe on
  the DUT's internal block-RAM write bus (`bram_address`/`bram_data`/
  `bram_wren`) rather than needing a UART receiver.
- `run.sh` -- known-good compile order + elaborate + run. Usage:
  `sim/run.sh [workdir]` (run from anywhere; it `cd`s to the project root
  itself). Edit the `--stop-time=` value near the bottom to change run
  length (a full 200-iteration sweep needs on the order of 20-25 ms of
  simulated time; ~75 s of wall-clock time to run in `ghdl`'s mcode
  interpreter).

## Known simulation-only gotcha already fixed

`MicrocomputerZ80CPM.vhd`'s `cpuClkCount`/`sdClkCount` (the `clk`-divider
counters generating `cpuClock`/`sdClock`) have no VHDL initial value, so
they start as `'U'` in simulation (real FPGA registers always power up to
a determinate 0/1 -- this is a simulation-only gap, not real hardware
behaviour). Combined with `sim_compat_pkg`'s `to_integer`-based `"<"`
operator (which reads a metavalue as integer `0`, always `< 4`), the
counter never takes its `else` branch to reset to a defined value, gets
stuck at all-`U` forever, and `cpuClock` never toggles -- so the Z-80 core
never runs *at all*. Fixed in `tb_inir_race.vhd`'s `seed_counters` process:
force both counters to `"000000"` for the first few `clk_sys` edges (long
enough for the DUT's own clocked process to compute a determinate next
value from the forced starting point), then release. **If you see the
CPU's address stuck at `0x0000` forever, check this first.**

## RESOLVED: `INIR`'s destination address (`HL`) never incremented

This was a **real T80 core bug**, not a simulation artifact (see
`SDRAM-review-handoff.md` section 4). In `Components/Z80/T80_MCode.vhd`,
MCycle 3 of INI/IND/INIR/INDR and OUTI/OUTD/OTIR/OTDR used
`IncDec_16 = "0010"/"1010"`; `T80.vhd` only writes `ID16` back to the
register file when `IncDec_16(2) = '1'`, so HL+/-1 was computed but never
stored. Fixed by porting the upstream "0240mj1" change
(`"0110"/"1110"`). The hardware "only one mismatch at offset 0" result in
`testing/backtoback.asm` A2/A3 was this same bug plus stale block-RAM
contents from earlier runs.

After the fix, `sim/run.sh` (default `--stop-time=25ms`) reports 0
mismatches over the iterations completed (115 before the testbench's
20 ms `wait until sim_done for 20 ms` timeout; raise that and
`--stop-time` for the full 200-iteration sweep). The run also
includes the step-3a wait-release phase guard in `MicrocomputerZ80CPM.vhd`
(no deadlock in the direct-access SDRAM path). Note a zero-delay RTL
simulation cannot reproduce the derived-clock wait-line race itself; use
STA for that.

`run.sh` now assembles the payload with `tools/z80asm.sh` (um80/ul80)
instead of pasmo.
