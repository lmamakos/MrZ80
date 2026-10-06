# Feature and Capability Requirements

This is the compact, actively-maintained requirements document. Detailed
historical debugging narrative (SDRAM bring-up soak tests, FSM deadlock
diagnosis, MMU widening steps, etc.) has been moved to `HISTORY.md` and is
not repeated here — consult it for *why* the current design looks the way
it does. This document describes *where things stand* and *what to do
next*.

See also:
- `IOPORTS.md` — the living I/O port map and memory-map reference. Keep it
  in sync with the code; don't duplicate its tables here.
- `HISTORY.md` — full narrative history through the 128 MB SDRAM bring-up,
  MMU widening to 256 MB, and the FORTH/front-panel work that followed.

## Background

The repository started as a port of Grant Searle's "MultiComp" project
(multiple 8-bit CPUs — Z-80, 6800, 6502, 6809 — on the MiSTer FPGA
platform). The goal of this project is to host the RomWBW Z-80/Z-180
software platform (CP/M 2.2, CP/M 3.0, and related 8-bit OSes) on MiSTer
hardware (Cyclone V + XSDS 128 MB SDRAM module). Getting there requires an
MMU, working paged/SDRAM memory, and eventually HBIOS changes to target
this board's peripherals.

Only the Z-80 CPU core is in scope going forward; the other CPU cores
inherited from the original MultiComp are legacy and candidates for removal
once the RomWBW port is under way (see "Legacy cleanup" below).

## Current architecture (summary)

- **MMU** (`Components/alancox/MMU.vhd`): 4 logical frames of 16 KB each,
  Z2-compatible mapping-register I/O window, plus a direct-access
  pointer/data port for physical memory access outside the 4 logical
  frames. Parameterized physical address width; currently instantiated
  with `physical_page_bits => 14` (28-bit / 256 MB physical space).
- **Physical memory map**: 128 MB SDRAM at the bottom of the physical
  space, with the 64 KB on-chip block RAM relocated to its own page
  (`block_ram_page`, physical `0x8000000`) just above it — no more
  shadowing between the two. Frame 0 resets to the block-RAM page (normal
  boot) or to SDRAM page 0 when a `.BIN` has been OSD-loaded
  (`bin_loaded`). See `IOPORTS.md` for the exact address layout and reset
  mapping.
- **SDRAM controller + client FSM** (`MicrocomputerZ80CPM.vhd`): a 4-state
  FSM (`S_IDLE → S_REQ → S_DONE → S_GAP`) drives the CoCo3-derived
  `sdram2.sv` controller across a clock-domain crossing (`clk_sys` 50 MHz
  ↔ `clk_ram` 100 MHz). `S_GAP` and the read/write-strobe-keyed exit (as
  opposed to raw `MREQ`) were both added to work around, respectively, a
  back-to-back-request CDC deadlock and the Z-80 M1 opcode-fetch/refresh
  hazard. The FSM never releases the CPU wait on the `cpuClock` rising
  edge (phase guard), and the controller refreshes both SDRAM devices
  correctly; sustained access and execution from SDRAM now work (see item 1
  status). Project timing constraints live in `MultiComp.sdc`.
- **Loadable boot ROM / RAM disk**: OSD-loaded `.BIN` (boots at physical/
  logical `0x0000`) and `.DSK` (8 MB RAM-disk images, default top-of-SDRAM)
  streamed in over the HPS `ioctl` download path.
- **CamelFORTH** (`forth/`): an interim Z-80 monitor/test harness (not part
  of RomWBW), booted via the `.BIN` loader in place of the legacy BASIC/CP/M
  ROM. Includes RAM-disk I/O primitives and MMU debug words built on top of
  the direct-access port. Presently uses the classic 7-instruction inline
  `NEXT` macro, **not** the custom `ED 27` opcode (see below).
- **Front-panel LED subsystem** (`Components/FRONTPANEL/`): WS2812/SK6812
  addressable-RGB blinkenlights display, driven by `FrontPanel_Subsystem.vhd`
  from one or more shift-register "capture chains" that snapshot CPU/bus
  signals. Currently wired into `MicrocomputerZ80CPM.vhd` and out to
  `USER_OUT[6]` on the MiSTer USER_IO connector.

## Active problems / requirements

### 1. Memory subsystem: sustained-access failures + new arbitrated/cached architecture

**Status (2026-10): the sustained-access failures are resolved.** They had
three causes, none of them the request/gap handshake itself: a same-edge
race on the wait line into the derived-clock T80, a T80 core bug (INI/OUTI
family never updated `HL`), and SDRAM device 0 never being refreshed while
it was in use. With those fixed, `sdramexec`, `sdramret` and CamelFORTH run
from SDRAM pass repeated runs. See `HISTORY.md` ("Session update — SDRAM
reliability fixes") and `SDRAM-review-handoff.md`. The arbiter/cache
architecture below is no longer needed for correctness; it remains a
performance/feature item (see item 4).

**Original symptom.** Individual memory probes (discrete byte read/write via the MMU
direct-access port, or through a mapped frame) succeed, but sustained
access patterns fail: instruction fetch out of SDRAM is unreliable, and
block-move access via the direct-access port using `INIR`-style repeated
I/O also fails. This points at the request/handshake path (the SDRAM
client FSM and its clock-domain crossing into the SDRAM controller), not
the SDRAM array itself.

**Requirement.** Design a new memory-access architecture rather than
continuing to patch the existing single-client FSM. Proposed shape:

- A single **arbiter/cache module** sits between clients and physical
  memory (SDRAM controller + block RAM), replacing the current scheme
  where the CPU/MMU path talks to the SDRAM FSM directly.
- **Multiple ports**, arbitrated with the CPU (via the MMU) at the highest
  priority:
  1. **CPU port** — the existing MMU-driven physical read/write stream.
  2. **Front-panel examine/deposit port** — a new capability, in the
     spirit of a classic front-panel switch register (e.g. Altair-style
     STOP/EXAMINE/DEPOSIT), allowing physical memory to be read or written
     independently of the running CPU. Needs a bus-request/hold mechanism
     (akin to a DMA/HALT request) rather than sharing the CPU's cycle
     timing.
  3. Reserved slot(s) for future clients (e.g. a block-transfer engine for
     RAM-disk I/O) — the arbiter should be sized for more than 2 ports
     from the start rather than hard-coded for exactly one.
- **BRAM cache layer**: a small write-through cache (direct-mapped or
  2-way set-associative, short lines — e.g. 16–32 bytes) sitting in front
  of the SDRAM controller. Goals:
  - Absorb repeated/sequential access (loops, hot code, re-read data) so
    the majority of traffic never touches the raw SDRAM request path.
  - Reduce — but not by itself eliminate — exposure to whatever remains
    fragile in the SDRAM handshake; a cold miss still goes through the
    real controller, so the arbiter's request/gap sequencing must still be
    correct on its own merits.
  - Direct-access and front-panel writes must invalidate/update the cache
    the same way CPU writes do, so no port can observe stale data through
    a different port.
- The existing `S_IDLE/S_REQ/S_DONE/S_GAP` handshake and the M1/refresh
  hazard workaround should be re-examined (ideally reasoned about formally
  or exercised in simulation) as part of this rework, rather than patched
  further ad hoc as new failure modes surface.

**Diagnostics to build alongside the redesign** — extend
`testing/sdramtest.asm` (currently direct-access + MMU-paged-sweep phases
only) with a third phase that stresses sustained/block access specifically:

- Generate a test pattern in block RAM (BRAM).
- Copy it to an SDRAM-resident page using `LDIR` (a sustained,
  back-to-back memory-access instruction — this is exactly the access
  pattern suspected of failing).
- Compare byte-by-byte to confirm the copy succeeded.
- Repeat the comparison using `CPIR` (a sustained *read-only* access
  pattern) to check whether block-compare fails the same way block-copy
  does.
- The test program is small enough to use **frame 2 (logical
  `0x8000-0xBFFF`) and frame 3 (logical `0xC000-0xFFFF`)** as the two
  movable windows, mapping block RAM and/or SDRAM pages into them in
  different combinations (BRAM→BRAM, BRAM→SDRAM, SDRAM→SDRAM, SDRAM→BRAM)
  so a pass/fail split across combinations localizes whether the fault is
  specific to SDRAM-as-source, SDRAM-as-destination, or independent of
  which side is SDRAM.
- Note: `sdramtest.asm`'s existing Phase 2 comments/OUT sequence assume
  13-bit MMU page numbers (`physical_page_bits = 13`); the MMU is now
  instantiated with 14 bits (256 MB) with block RAM relocated to
  `block_ram_page = 8192` — the test should be updated to match before
  being extended.

### 2. FORTH `NEXT` instruction (`ED 27`) does not work

The custom Z-80 opcode implementing CamelFORTH's direct-threaded `NEXT`
primitive (see `Components/Z80/T80_MCode.vhd`) analyzes and elaborates
cleanly under GHDL, but fails when exercised. It is not currently used by
the working FORTH build (`forth/camel80.azm` still emits the classic
7-instruction inline macro).

**Requirement.** Write a small, standalone Z-80 assembly test — independent
of CamelFORTH — that isolates the instruction:

- Set up `DE` (IP) pointing at a known 16-bit cell in memory and a known
  sentinel in `HL`.
- Execute `DB 0EDh,27h` and check, in isolation: `HL` equals the cell that
  was at `(IP)`, `DE` has advanced by exactly 2, and control transferred to
  the address that was read (i.e. `PC` after the jump equals that value).
- Cover both the block-RAM and SDRAM-resident cases once the memory-system
  work above is in place, and cover the case where the target cell straddles
  a page boundary.
- Report pass/fail per sub-check over the serial console (matching the
  style of `testing/sdramtest.asm` / `testing/sdramexec.asm`), so a failure
  localizes to a specific register or timing assumption rather than a bare
  "it fails".

Only once this passes standalone should the CamelFORTH `next` macro be
redefined to emit the opcode and the FORTH test suite re-run.

### 3. Front-panel LED subsystem outputs all zero bits

**Symptom.** Oscilloscope inspection of the WS2812 serial line shows
correct bit timing and the correct total bit count, but every bit is 0 —
no LED ever lights.

**Fixed in HDL, hardware re-verification pending:**

- **Capture-chain bit order.** The root-cause suspect was *not* the WS2812
  PHY shift direction inside `FrontPanel_Subsystem.vhd` (which already
  shifted each 24-bit color MSB-first, matching the WS2812 protocol), but
  the **capture-chain** components (`Transparent_Capture_Chain.vhd`,
  `Universal_Capture_Chain.vhd`) that feed it, which shifted their
  `combined_data` input out LSB-first — backwards from what a physical
  LED-strip layout wants. Both variants now shift `combined_data` out
  **MSB-first** (`chain_out <= shift_reg(TOTAL_WIDTH-1)`, with a matching
  left-shift), so an 8-bit source register's MSB reaches the first LED in
  the chain, matching left-to-right register-bit order under the default
  identity mapping (see `FP_RAM_Store.vhd`).
- **Colour path simplified.** The per-LED gradual fade between
  programmable ON/OFF colors (`alpha_ram` ramp, `MATH_INIT`/
  `MATH_CHANNEL`/`MATH_BRIGHT` in `FrontPanel_Subsystem.vhd`) has been
  removed. Each LED now shows its RAM-stored on/off color directly and
  instantly, selected by the existing mapping-table/framebuffer logic
  (unchanged, fully retained). Global-brightness (`+0`) and fade-rate
  (`+1`) registers remain stored/readable for compatibility but currently
  have no effect; reintroduce fade/brightness incrementally once basic
  LED output is confirmed on hardware.

Both changes analyze/elaborate cleanly under GHDL `--std=08`. **Still
needed:** re-test on real hardware to confirm LEDs actually light; if they
still don't, the fault is elsewhere (PHY output enable, USER_IO pin
routing/muxing, or the WS2812 power/data wiring itself).

**Fixed: Z-80 I/O decoder re-triggering on every `clk` edge.** `clk` runs
far faster than the (divided-down) Z-80 clock, so `io_cs`/`iorq_n`/`wr_n`/
`rd_n` stayed asserted for several `clk` edges per Z-80 bus cycle. The
decoder's write/read blocks were gated on the raw signal *levels*, so a
single `OUT`/`IN` instruction caused pointer auto-increment, colour-stream
byte collection, and register writes to fire several times instead of
once. Fixed by deriving one-clk-wide `wr_pulse` (rising edge of the
write-active condition — data is already valid then) and `rd_done_pulse`
(falling edge of the read-active condition — deferred until after the CPU
has sampled `dout`, avoiding a read-ahead hazard) and gating all the
side-effecting logic on those pulses instead of the levels. The read
*data* mux is unchanged/level-sensitive so `dout` stays valid for however
long the CPU holds `RD` low. Verified with a standalone GHDL testbench
that holds `wr_n`/`rd_n` low for 6 `clk` cycles (simulating the slow
Z-80 clock) and confirms `global_ptr` advances by exactly 1 per access.

**Fixed: `FP_RAM_Store` colour/map RAM read back as zero on hardware.**
Root cause confirmed via `output_files/MultiComp.fit.rpt`: the Master
Controller's only consumers of the colour/map RAM's read port
(`r_col_b`, `r_map_b`) had been temporarily replaced with hardcoded
literals for testing (now commented out, not deleted, for easy restore),
so Quartus's optimizer eliminated `color_ram` entirely (it never appeared
in the fitter's RAM table) and collapsed `map_ram` down to a single read
port. Restoring the real `r_col_b`/`r_map_b` usage brings both RAMs back
into the build — confirmed by a fresh build: `color_ram` now appears as a
64×48 M10K Simple Dual Port block.

**Fixed: RAM contents now re-initialize on every reset, not just once at
FPGA power-up.** `color_ram`/`map_ram`/`fb_ram` used to rely on either a
Quartus-only `ram_init_file` attribute (a no-op in a plain VHDL simulator
like GHDL) or a VHDL default value (applied once at elaboration, not on a
later reset pulse) — neither gives reproducible behaviour across
repeated Z-80 resets. `FP_RAM_Store.vhd` now has its own small init
sequencer: on `reset`, it steps through every address for `NUM_LEDS` clk
cycles, writing the default identity map / default on-off colour /
all-off framebuffer, and holds a new `init_done` output low until it's
finished. `FrontPanel_Subsystem`'s Master Controller (`IDLE` state) waits
for `init_done` before starting the first refresh, so the very first
refresh after any reset only ever sees fully-initialized RAM. The old
external `colors.mif`/`mapping.mif` files were removed entirely — a
Quartus 17.0 build had already shown that once a signal has both a VHDL
default and a `ram_init_file` attribute, Quartus prefers the VHDL default
and auto-derives its own internal `db/*.hdl.mif` from it, never actually
reading the external `.mif` files — so `FP_RAM_Store.vhd`'s
`DEFAULT_COLOR` constant and `init` sequencer are now the single source
of truth for reset defaults.

**Changed: colour interface is now R,G,B, not the LEDs' native G,R,B.**
The `+3` colour-stream port and `color_ram`'s storage format used to
match the WS2812/SK6812 wire protocol's native G,R,B byte order directly,
requiring software to think in GRB. Both are now plain R,G,B (matching
how every other colour API works); the GRB reorder the LEDs actually
need happens only in a new `SCALE_BRIGHT` pipeline state, immediately
before the PHY, so software never has to deal with the LEDs' GRB quirk.

**Re-implemented: global brightness (`+0`).** Removed during the initial
bring-up simplification along with the fade ramp; brightness is back as
part of the same new `SCALE_BRIGHT` state, using the standard 8-bit
"scale8" convention (`scaled = (channel * global_bright) / 256`, e.g.
FastLED's `scale8()`) applied independently to each of the selected
colour's three channels. `global_bright = 0xFF` is ~full brightness (off
by <1 count vs. true /255 due to the `/256` convention), `0x00` forces
the LED fully off. The fade-rate (`+1`) register remains stored/readable
but inert; gradual fade *between* on and off colours is still future
work.

**Fixed while implementing the above: two write-path correctness bugs.**
- The `+3`/`+5`/`+6` pointer auto-increment updated `global_ptr` in the
  *same* cycle as the write commit (`we_col`/`we_map`/`we_fb` asserting),
  but `FP_RAM_Store`'s actual RAM write only takes effect one
  cross-entity clk edge later (the usual registered-signal handoff
  latency between two separate synchronous entities). By the time the
  write actually committed, `global_ptr` (and hence `addr_a`) had
  already advanced to the next value, so every auto-incrementing write
  silently landed one slot ahead of the address that was intended. Fixed
  by deferring the pointer update by one extra cycle (a new
  `pending_incr` signal) so `FP_RAM_Store` still sees the original
  address at the moment its write actually commits. The read-side
  auto-increment (`rd_done_pulse`, deferred until after the CPU samples
  `dout`) was already immune to this class of bug by construction.
- `global_ptr` could be driven past `NUM_LEDS-1` (trivially, e.g. by
  streaming exactly `NUM_LEDS` accesses through `+5`/`+6` in a loop),
  which is an out-of-bounds index into `color_ram`/`map_ram`/`fb_ram` —
  undefined address-truncation behaviour in synthesis, and a hard
  simulation failure under GHDL. The auto-increment now wraps at
  `NUM_LEDS` back to 0 instead.

All of the above (RAM re-init on a *second* reset, the RGB-in/GRB-out
colour path, brightness scaling at full/half/zero, and a write landing
at the correct pre-increment address) was verified with a dedicated GHDL
testbench before being folded into the committed HDL.

**Fixed: shift-in capture chain landed each bit one LED late (and lost
the last bit entirely).** Reported on real hardware after extending the
chain to 64 bits (`fpChain` + `fpChainStaticTest` + `fpChainEnd`, the
latter two both fed by the port `0xFF` `fpLatch` register): writing a
value to `fpLatch` put its MSB one LED position later than expected at
the *head* of the chain (LED 1 instead of LED 0), and at the *tail* the
same value's LSB was missing entirely, with its MSB also one LED late.
Root cause: `FrontPanel_Subsystem`'s Master Controller moved directly
from `LATCH_ST` to `SHADOW_SHIFT` the same cycle `latch` was presented
to the capture chains, but a capture chain's parallel load only commits
to its `shift_reg` one `clk` edge later (`chain_out` is combinational
off `shift_reg`, but `shift_reg` itself is an ordinary registered
update) — the same cross-entity registered-signal handoff latency
already documented for `FETCH_MEM`/`WAIT_MEM` above, here applied to
`latch`/`chain_out` instead of RAM `addr`/`dout`. The same latency
applies separately to the *first* `shift_en`-driven shift (advancing
from bit 0 to bit 1). `SHADOW_SHIFT` started sampling `chain_in` one
cycle too early on both counts, so bit 0 was captured twice (once
against stale pre-load data, once as a duplicate of the true bit 0)
while the true final bit of the whole 64-bit chain was never sampled at
all. Fixed with a new `LATCH_WAIT` settle state between `LATCH_ST` and
`SHADOW_SHIFT` that also raises `shift_en` a full state ahead of
`SHADOW_SHIFT`'s own first iteration, so both the parallel load and the
first shift have already committed by the time real capturing begins.
The existing 64-cycle `SHADOW_SHIFT` loop bound needed no change.
Verified with a dedicated GHDL testbench instantiating the full 3-stage
chain topology (matching `MicrocomputerZ80CPM.vhd`'s wiring exactly) and
checking all 64 `shadow_reg` bit positions against four different bit
patterns, including back-to-back refresh cycles (steady-state, not just
post-reset) — all 256 checks (4 patterns × 64 bits) pass.

**Also fix while in this code:** `MultiComp.sv` currently declares
`user_fpLED_serial` from `USER_OUT[4]` (a stale comment/declaration left
over from before the LED output was moved to a different pin) and
separately drives it via `assign ... USER_OUT[6]` — a leftover duplicate/
conflicting driver from the pin-swap commit. Clean this up so there is a
single, correctly-commented signal path from `FrontPanel_Subsystem` to the
physical pin.

### 4. Future: SDRAM execution performance (CPU clock and/or SDRAM cache)

**Status.** SDRAM is now functionally reliable for sustained access and
code execution (wait-release phase guard, T80 INI/OUTI fix, refresh fix,
project SDC — see `HISTORY.md`, "Session update — SDRAM reliability
fixes"). It is, however, slow: a CamelFORTH benchmark takes 13.0 s from
block RAM vs 19.3 s from SDRAM (stock kernel), and 9.0 s vs 13.4 s with the
custom instructions — roughly 30% slower from SDRAM. Every SDRAM access
pays the `clk_sys` → `clk_ram` 2-FF request synchroniser, the controller
latency, the `clk_ram` → `clk_sys` completion synchroniser, the `S_DONE`
phase guard and the 3-cycle `S_GAP`, all rounded up to whole ~100 ns T80
T-states. Acceptable for now; revisit either or both of:

1. **Clock the T80 from `clk_sys` with a clock enable** instead of the
   fabric-derived `cpuClock` register (`SDRAM-review-handoff.md` step 3b):
   - expose `CEN` on `T80s` (currently tied `'1'`) and gate `T80s`' own
     strobe/`DI_Reg` process with it; generate a one-cycle `cpu_cen` pulse
     from `cpuClkCount`;
   - removes the derived clock and with it the whole class of same-edge
     races (the `cpuClkCount` wait-release guard, the hold relaxations and
     the residual peripheral-read hold violations in `MultiComp.sdc`); all
     CPU paths become single-domain and STA-checked, using
     `set_multicycle_path` (setup 5 / hold 4) where needed;
   - allows `WAIT_n` to be sampled on the exact enable cycle, so an SDRAM
     access no longer has to be rounded up to whole T-states plus a guard
     cycle, and the `S_GAP` dead time can be re-derived;
   - re-check the peripherals that use CPU strobes as clocks
     (`n_RomActive` on `n_ioWR`, `bufferedUART`, SD controller, front
     panel) and whether the MMU `cpu_wait` pulse is still needed.
2. **Investigate a cache in front of the SDRAM** (block RAM, small lines,
   direct-mapped or 2-way, write-through), so that hits — loops, hot FORTH
   inner-interpreter code, the return/parameter stacks — complete at
   block-RAM speed without crossing into `clk_ram`. This is the cache part
   of the arbiter/cache architecture in item 1: direct-access-port and any
   future front-panel/DMA writes must update or invalidate it. Measure the
   hit rate on the FORTH benchmark and on CP/M before committing to a
   line size/associativity.
3. Optionally reduce CDC latency on its own: run the SDRAM client FSM
   directly in `clk_ram` with a single request/acknowledge crossing, or
   pick `clk_ram` as an integer multiple of `clk_sys` so the crossing can
   be made synchronous (treat any `clk_ram` change as an SDRAM read-capture
   timing change — see `SDRAM-review-handoff.md` section 6.1).

Use the same FORTH benchmark (block RAM vs SDRAM, stock and custom-
instruction kernels) as the before/after measure, and regress with
`testing/sdramexec`, `sdramret`, `backtoback` and `sdramtest`.

## Next milestone: RomWBW port

Once the three items above are resolved (reliable sustained memory access,
a working `NEXT` instruction to accelerate the FORTH inner interpreter used
for interactive testing, and a basic working front-panel LED display for
hardware visibility into the system), resume the top-level goal: port
RomWBW to this platform.

### Legacy cleanup (do alongside/after the RomWBW port begins)

As RomWBW's HBIOS takes over boot and memory management, strip out
remaining Grant Searle MultiComp legacy elements that RomWBW does not need,
notably:

- The port-`0x38` boot-ROM-disable trigger (`n_RomActive`/`n_basRomCS` in
  `MicrocomputerZ80CPM.vhd`) — a Searle-convention mechanism for unmapping
  the boot ROM overlay that RomWBW's own boot sequence will supersede.
- Any remaining non-Z-80 CPU support (6800/6502/6809 cores and their mux
  logic) once it's confirmed nothing else in the build depends on them.
