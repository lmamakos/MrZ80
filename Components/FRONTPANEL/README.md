# Front Panel Interface

> **Status:** Wired into the `MicrocomputerZ80CPM` core with a single
> 8-bit `Transparent_Capture_Chain` sourced from a R/W latch at I/O
> port 0x47, and the subsystem's 8-port control window occupies I/O
> ports 0xA0..0xA7. The WS2812 serial line emerges on `USER_OUT[6]` of
> the MiSTer USER_IO port. On initial hardware bring-up the output
> showed correct WS2812 bit timing/count but every bit was 0 (no LED
> lit). Two changes have since been made to isolate the cause:
>
> 1. **Capture-chain bit order fixed.** `Transparent_Capture_Chain` and
>    `Universal_Capture_Chain` previously shifted `combined_data` out
>    **LSB-first**; combined with `FrontPanel_Subsystem`'s left-shift
>    capture of the incoming serial stream, this bit-*reversed* an
>    8-bit source register relative to physical LED order. Both chain
> variants now shift **MSB-first**, so (with the default identity
> mapping -- see `FP_RAM_Store.vhd`) LED *i* mirrors bit *i* of an
> 8-bit source register directly — matching a natural left-to-right
> PCB layout — instead of the mirrored order.
> 2. **Colour path simplified for bring-up.** `FrontPanel_Subsystem`'s
>    per-LED fade ramp and on/off colour interpolation + brightness
>    scaling (the `alpha_ram`/`MATH_INIT`/`MATH_CHANNEL`/`MATH_BRIGHT`
>    machinery) have been removed for now. Each LED now shows its
>    RAM-stored "on" or "off" colour directly and instantly, selected by
>    the mapped chain bit (or framebuffer bit). This does not change the
>    I/O port map, and the mapping table (`+5`) and framebuffer
>    (`+4`/`+6`) are unchanged and fully functional; only the fade/
>    interpolation/brightness stage was removed. The global-brightness
>    (`+0`) and fade-rate (`+1`) registers are still stored and
>    readable/writable but currently have no effect — they're reserved
>    for reintroduction once basic LED output is confirmed on hardware.
>
> Several further bugs were found and fixed after that first bring-up pass:
>
> 3. **Z-80 I/O decoder no longer re-triggers on every `clk` edge.**
>    `clk` runs far faster than the Z-80's own (divided-down) clock, so
>    `io_cs`/`iorq_n`/`wr_n`/`rd_n` stayed asserted for several `clk`
>    edges per Z-80 bus cycle; the decoder's write/read side effects
>    were gated on those raw levels, so a single `OUT`/`IN` instruction
>    caused pointer auto-increment and colour-stream byte collection to
>    fire several times instead of once. Fixed with one-shot
>    edge-detected strobes (`wr_pulse` at the start of a write,
>    `rd_done_pulse` at the end of a read) gating the side effects,
>    while `dout` itself stays level-driven so it remains valid for
>    however long the CPU holds `RD` low.
> 4. **`FP_RAM_Store` colour/map RAM restored.** The Master Controller's
>    real colour/map RAM readback (`r_col_b`/`r_map_b`) had been
>    temporarily swapped for hardcoded test literals, which caused
>    Quartus's optimizer to eliminate `color_ram` from the build
>    entirely (confirmed absent from the fitter report) and to collapse
>    `map_ram`'s dead second read port. The real RAM-backed logic is
>    restored (the old hardcoded literals are left commented out for
>    easy A/B testing). A fresh Quartus build confirms `color_ram` is
>    now a real 64×48 M10K block.
> 5. **RAM contents now re-initialize on every reset, not just once at
>    power-up.** `color_ram`/`map_ram`/`fb_ram` previously relied solely
>    on a Quartus-only `ram_init_file` attribute (which a plain VHDL
>    simulator like GHDL never honours) or a VHDL default value (which
>    only applies once, at elaboration/power-up, not on a later reset
>    pulse). `FP_RAM_Store` now has its own small init sequencer that
>    steps through every address writing the default content (identity
>    map, a visible default on/off colour, framebuffer all off) for
>    `NUM_LEDS` `clk` cycles every time `reset` is asserted, and exposes
>    `init_done` so `FrontPanel_Subsystem`'s Master Controller can hold
>    off starting the first refresh until it's finished. `colors.mif`/
>    `mapping.mif` are no longer used (also removed; see point 6) --
>    the defaults now live solely in `FP_RAM_Store.vhd`.
> 6. **Colour interface changed from GRB to RGB, hidden GRB reorder.**
>    The `+3` colour-stream port and `color_ram`'s storage format used
>    to match the WS2812/SK6812 wire's native G,R,B byte order, forcing
>    software to think in GRB. Storage and the `+3` port are now plain
>    R,G,B (matching how every other colour API works); the GRB reorder
>    the LEDs actually need happens only in the new `SCALE_BRIGHT` state,
>    immediately before the PHY, so it's entirely invisible to software.
> 7. **Global brightness (`+0`) re-implemented.** Removed during the
>    initial bring-up simplification (point 2 above) along with the
>    fade ramp, brightness scaling is back as a single extra pipeline
>    state (`SCALE_BRIGHT`) that scales each of the selected colour's
>    three channels independently by `global_bright` using the standard
>    8-bit "scale8" convention (`scaled = (channel * global_bright) /
>    256`; matches e.g. FastLED's `scale8()`). `global_bright = 0xFF` is
>    ~full brightness, `0x00` forces the LED fully off. The fade-rate
>    (`+1`) register remains stored/readable but inert; gradual fade
>    *between* on and off is still future work.
> 8. **Two write-path correctness bugs found and fixed while adding the
>    above:**
>    - The `+3`/`+5`/`+6` pointer auto-increment updated `global_ptr` in
>      the *same* cycle as the write commit (`we_col`/`we_map`/`we_fb`),
>      but `FP_RAM_Store`'s actual RAM write only takes effect one
>      cross-entity `clk` edge later -- by which point `global_ptr` (and
>      hence `addr_a`) had already advanced, so every auto-incrementing
>      write silently landed one slot ahead of where it should have.
>      Fixed by deferring the pointer update by one extra cycle
>      (`pending_incr`) so `FP_RAM_Store` still sees the original
>      address at the moment it actually commits the write.
>    - `global_ptr` could be driven past `NUM_LEDS-1` (e.g. by streaming
>      exactly `NUM_LEDS` accesses through `+5`/`+6`), which is an
>      out-of-bounds array index for `color_ram`/`map_ram`/`fb_ram` --
>      undefined in synthesis and a hard simulation failure under GHDL.
>      The auto-increment now wraps at `NUM_LEDS` back to 0.
> 9. **Shift-in capture chain was one bit short at each end (fixed).**
>    Symptom on hardware: with a 64-bit chain (`fpChain` + 8 more bits of
>    static test data + `fpChainEnd`, the latter two copies both sourced
>    from the port `0xFF` `fpLatch` register), writing a value to
>    `fpLatch` put its MSB one LED late at the head of the chain, and its
>    LSB was entirely missing at the tail (with the tail group's MSB
>    also one LED late). Root cause: the Master Controller's `LATCH_ST`
>    state moved straight to `SHADOW_SHIFT` the same cycle `latch` was
>    presented to the capture chains, but a capture chain's parallel
>    load (`shift_reg <= captured_bits` on `latch = '1'`) — and likewise
>    its shift (`shift_reg <= ... & chain_in` on `shift_en = '1'`) — only
>    commits one `clk` edge later (`chain_out` is combinational off
>    `shift_reg`, but `shift_reg` itself is an ordinary registered
>    update). `SHADOW_SHIFT` started sampling `chain_in` one cycle too
>    early relative to both the load and, separately, the first shift,
>    so bit 0 was captured twice (once as stale/pre-load data, again as
>    a duplicate of the true bit 0) while the very last real bit was
>    never sampled at all — the same 64-cycle budget was spent on 63
>    real bits plus one wasted/duplicate cycle instead of 64 real bits.
>    Fixed with a new `LATCH_WAIT` settle state between `LATCH_ST` and
>    `SHADOW_SHIFT` (mirroring the existing `FETCH_MEM`/`WAIT_MEM`
>    cross-entity-latency idiom) that also raises `shift_en` a full
>    state ahead of `SHADOW_SHIFT`'s own first iteration, so both the
>    load and the first shift have already committed by the time
>    capturing begins. No change to the 64-cycle `SHADOW_SHIFT` loop
>    bound was needed.
>
> **Profiles (new):** 8 profiles of per-LED map and ON/OFF colours, a
> profile-select register at `+7`, and a profile file loaded from the OSD
> (`FC5`). See the Profiles section below. Verified with the GHDL testbench
> `sim/tb_frontpanel.vhd` (`sim/run_frontpanel.sh`), which decodes the
> WS2812 output and checks every LED. Not yet tested on hardware.
>
> All four VHDL files (`FP_RAM_Store`, `Transparent_Capture_Chain`,
> `Universal_Capture_Chain`, `FrontPanel_Subsystem`) continue to analyze
> and elaborate cleanly under GHDL VHDL-2008, and a full Quartus 17.0
> build completes with 0 errors. Points 5-9 above were verified with
> dedicated GHDL testbenches: RAM defaults after both the first and a
> *second* reset, a `+3`/`+5`/`+6` write landing at the correct
> (pre-increment) address, the RGB-in/GRB-out colour path, brightness
> scaling at full/half/zero, and (point 9) all 64 `shadow_reg` bit
> positions checked bit-for-bit against a full 3-stage chain topology
> (matching `MicrocomputerZ80CPM.vhd`'s wiring) across four different
> bit patterns, including back-to-back refresh cycles. Re-verify
> hardware next.

## Ultimate front panel light display

The premise for this is: if you have a CPU implemented in an FPGA,
then you have access to _all_ of the internal signals inside the CPU
that are normally inaccessible.  Given that, why not implement the
ultimate in blinkenlights front panel!

Sure, like an IMSAI you can show the data and address bus.  But
wouldn't it be interesting to see what the current value of the A
register is?  Why stop there; how about having **ALL** the registers
displayed, each with their own LEDs?  And likewise for control
signals, too.

The implementation approach is to use RGB addressable LEDs (like the
WS2812 devices) for the indicators.  In this way, only a single output
line from the FPGA is required to operate all of the LEDs.  There's
also the opportunity to use different colors, either for grouping
signals/registers, or to denote some alternate function (e.g.,
physical vs. mapped logical address.)

### Features

1. Each LED indicator should have a configurable and programmable ON
and OFF color (8 bits each, RGB).  The idea is that when the LED
changes state to OFF, it doesn't go completely dark, but is just
another (likely much dimmer) color.

2. The individual LED ON and OFF RGB values should be settable from the software
running on the Z-80 CPU by accessing some I/O ports.  

3. It should be possible to configure a gradual fade between the ON
and OFF transition as well as the OFF to ON transition.  This would be
used to simulate effecs such as the behavior of incandescent lamps.
   > *(Temporarily removed — see Status above. The instant on/off
   > switch is the current bring-up behavior; fade is to be
   > reintroduced once basic LED output is confirmed on hardware.)*

4. It should be possible to select some LEDs to capture brief ON
conditions and stretch them so the brief ON state is visible to the
naked eye.  This would be used to indicate certain signals that do not
occur frequently, such as interrupt requests or other signals.

5. Some of the LEDs are just connected to latched I/O port output
values.  This is similar to port 0xFF on IMSAI computers which allow
programs to set indications.  In this system, we'll have enough LEDs
to have more than one 8 bit "register" for this purpose.

6. The implementation should have a component that connects to the
signals we want to monitor and indicate on the LEDs.   One or more
of these would be chained together in a long shift-register.


## I/O register map

The `FrontPanel_Subsystem` exposes a window of 8 consecutive I/O ports.
The base address of that window is set entirely by the external I/O
decoder that drives the `io_cs` input; this module only looks at the
low 3 bits of `addr` to pick a register within the window. The
integrator should align the window on a multiple-of-8 boundary so the
three low address bits are a clean offset into the window.

| Offset | R/W | Function                                                       |
|--------|-----|----------------------------------------------------------------|
| +0     | R/W | Global brightness (0..255, "scale8" style: 0xFF ~= full brightness, 0x00 = fully off). Applied to every channel of whichever colour is selected for display; see Status above. |
| +1     | R/W | **Map high** (replaces the former, inert fade-rate register). Write: bits 1:0 are map bits 9:8 for later `+5` writes (sticky, 0 at reset). Read: map bits 9:8 of the entry at the global pointer (read it *before* the `+5` read, which advances the pointer). Only meaningful for a chain longer than 256 bits; see Long capture chains. |
| +2     | R/W | Global pointer (LED index used by +3, +5, +6).                 |
| +3     | W   | Colour stream, R,G,B order (matches the LEDs' own on-wire GRB order internally, but never exposed to software -- see Status above). Six bytes per LED: on-R, on-G, on-B, off-R, off-G, off-B. On the sixth byte the global pointer advances by 1. |
| +4     | R/W | Mode register (bit 0: 0 = mirror capture chain, 1 = framebuffer). |
| +5     | R/W | Mapping-table entry at the global pointer. Both reads and writes auto-advance the pointer by 1. |
| +6     | R/W | Framebuffer bit at the global pointer. Both reads and writes auto-advance the pointer. |
| +7     | R/W | Active profile number (low 3 bits, reads back 0..7, 0 at reset). See Profiles below. |

The `+3`/`+5`/`+6` pointer auto-advance wraps at `NUM_LEDS` back to 0 rather than growing past it, so streaming exactly `NUM_LEDS` (or a multiple of it) accesses through any of those ports is always well-defined.

## Profiles

The subsystem holds **8 profiles**. A profile gives, for each of the 256
physical LEDs:

- the **map**: which capture-chain position drives the LED. Chain position
  0 is the first bit shifted out of the capture chain (the MSB of the
  first chain segment). This lets a different physical LED arrangement be
  used without rearranging the capture chain.
- the **ON** and **OFF** RGB colours.

Brightness (`+0`), the mode register (`+4`) and the framebuffer (`+6`) are
global, not per profile.

- **Selecting:** write the profile number to port `+7`. It is 0 after every
  reset. The profile is latched at the start of each refresh frame, so a
  switch never produces a frame that mixes two profiles.
- **OSD selection:** the OSD item **Front Panel Profile** (`Software`, `0`..`7`)
  forces a profile onto the LEDs on the fly. It does not reset or stall the
  CPU and software never sees it: port `+7` still reads back what the Z-80
  wrote, and `+3`/`+5` writes still go to the Z-80's own selected profile
  (so a program configuring a profile is unaffected by what the OSD is
  displaying). `Software` (the default) means no override: the profile the
  Z-80 selected through `+7` is displayed. The OSD value is sampled once
  per refresh frame, so a change takes effect on the next frame (at worst
  one frame still shows the old profile). The setting is part of the OSD
  status, so it is saved by MiSTer and is not changed by resets.
- **Defaults:** with no profile file, all 8 profiles are initialised to the
  identity map (LED *n* shows chain position *n*), ON = `#FF0001` and
  OFF = `#000009`. Profile 0 is therefore the same as before profiles
  existed.
- **Z-80 modification:** with a profile selected, the colour stream (`+3`)
  and mapping (`+5`) ports read/write that profile. The changes stay in
  that profile when another one is selected, and selecting it again shows
  them. **Any reset** (including OSD Reset) re-initialises all 8 profiles
  from the profile file, or from the defaults if none is loaded, so Z-80
  modifications do not survive a reset.
- **Profile file:** the OSD item **Front Panel Profiles** (config-string
  `FC5`, extension `.FPP`) loads a file that initialises all 8 profiles. The
  core is reset after the download, so the new profiles take effect
  immediately. The loaded file stays in effect across OSD Resets and is
  forgotten on a hard reset (the RESET button), like the boot ROM `.BIN`.
  A file with a bad header or the wrong length is ignored (defaults used).
  File indices 3 and 4 are reserved for future RAM-disk images; the profile
  file is never written to SDRAM.
- **Storage:** `FP_RAM_Store` keeps the working copy (`color_ram`,
  `map_ram`: 2048 entries addressed by `{profile, led}`) plus a pristine
  copy of the file (`pri_ram`) that is used to re-initialise the working
  copy on every reset (about 2050 `clk` cycles; the first refresh waits for
  it).

### Long capture chains (up to 1024 bits)

`FrontPanel_Subsystem` has a generic `CHAIN_BITS` (1..1024, default 256): the
total length of the capture chain. The LED string is still 256 LEDs, but a
profile's per-LED map can now select any of the `CHAIN_BITS` chain bits, so
different profiles can show different parts of the chain (for example one
profile for the registers, another for bus signals). Chain position 0 is the
first bit shifted out of the chain. A map value at or beyond `CHAIN_BITS` shows
that LED's OFF colour. A longer chain costs one `shadow_reg` flop per bit,
a wider map RAM (9 or 10 bits instead of 8), a longer capture phase
(`CHAIN_BITS` clocks per frame) and a bigger selection mux. Framebuffer mode is
unchanged: one bit per LED, at most 256.

Z-80 access to map entries above 255: write the high bits (map bits 9:8) to
port `+1`, then write the low byte to `+5`; the high bits stay set for later
`+5` writes, so clear `+1` when done (software that never touches `+1` sees
and writes maps 0..255 as before). To read an entry back, set the pointer, read
`+1` (high bits) and then `+5` (low byte, advances the pointer).

### Profile file format

All values are bytes; the file (version 2) is exactly **16400 bytes**. Version 1 files (one-byte map, 14352 bytes) are no longer accepted by the hardware (`fpprofile.py --dump` can still decode them).

| Offset | Size | Content |
|--------|------|---------|
| 0      | 4    | Magic `FPPF` (`46 50 50 46`) |
| 4      | 1    | Version, `02` |
| 5      | 1    | Number of profiles, `08` |
| 6      | 2    | LEDs per profile, little endian, `00 01` (256) |
| 8      | 8    | Reserved (ignored; the tool writes zeros) |
| 16     | 8 x 256 x 8 | Profile 0 LED 0 ... LED 255, then profile 1, ... profile 7. Each record is `map low, map high, onR, onG, onB, offR, offG, offB` (map is a 16-bit little-endian value, 0..1023 used). |

### Building a profile file: `tools/fpprofile.py`

    python3 Components/FRONTPANEL/tools/fpprofile.py example_profiles.yaml -o profiles.fpp
    python3 Components/FRONTPANEL/tools/fpprofile.py --dump profiles.fpp

The input is YAML (Python >= 3.9 with PyYAML -- Debian package
`python3-yaml`). TOML input was retired with this rework; a `.toml`
file is rejected with a pointer to the rewrite. The complete model and
every validation rule are specified in `tools/NEW-REQUIREMENTS.md`;
`tools/example_profiles.yaml` is an annotated example matching the
development panel. Profiles the config does not mention emit as the
default profile (identity map, ON = `#FF0001`, OFF = `#000009` -- the
hardware's own no-file defaults).

Command line:

| Argument | Meaning |
|----------|---------|
| `config` | YAML file to read. Omit it to produce an all-defaults file. |
| `-o FILE`, `--output FILE` | Profile file to write (required when building). |
| `--chain-bits N` | Override the `chain_bits` key (1..1024). |
| `--strict` | Treat warnings as errors (nothing is written). |
| `--dump FILE` | Decode and summarise an existing profile file (version 2; version 1 readable). |

#### Configuration model (summary; `tools/NEW-REQUIREMENTS.md` is the spec)

- **`layout`** -- one, global, wiring only: `rows` x `cols` (must equal
  `leds`, default 256) plus the wiring walk (`origin` corner, `major`,
  `serpentine`); the cell visited at step *n* holds physical LED *n*.
- **`signals`** -- named chain-position groups built from chain
  numbers, ranges `a..b` (inclusive, first endpoint emitted first --
  `"34..30"` descends), and earlier symbols or subsets `NAME[7..0]`
  (positional indices into the definition, written order). Forward
  references are errors; repeats are fine. Quoted `"a:b"`/`"a-b"` are
  accepted aliases; remember that an *unquoted* `16:23` is YAML 1.1
  sexagesimal (the integer 983), and the tool says so when rejecting
  such a value. In flow lists (`[...]`) subset tokens must be quoted.
- **`profile.N`** (`N` 0..7) -- optional `on`/`off` colours, an
  optional default run `dir`, and an ordered list of **runs**. A run
  places its expanded signal list on a straight line from
  `start: [row, col]` (top-left origin) toward the panel edge in
  `dir: right|left|up|down`, one element per cell; `dir` is optional
  and inherits the profile's `dir`, then the top-level `dir`, then
  `right`. No wrap: overflow past the edge is an error. The run
  claims exactly
  the cells its data covers -- never the bare edge past them -- so
  runs pack freely into one line; any two runs claiming the same cell
  is an error naming both runs and the shared cells.
- **Blanks** -- `-` occupies a cell as an unused LED, and cells no
  run claims are blank automatically (the grid always fills with the
  default OFF values).
  A blank maps chain position 0 with ON and OFF both baked to the
  resolved OFF colour, so it is static regardless of what chain bit 0
  does. `{sig: "-", off: "#101010"}` picks a custom darkness (`on` on
  a blank is an error).
- **Elements** -- a bare token inherits the run's colours;
  `{sig: X, on: C, off: C}` colours the cells of that one reference.
- **Colours** -- `#RRGGBB`, `RRGGBB`, `[r,g,b]`, or a name: the
  built-in CSS/HTML names, extended/overridden by the `colors` table.
  Per channel: element > run > profile > `defaults` > built-in.
- Warnings (errors under `--strict`): a `signals` symbol or `colors`
  entry nothing references. Duplicate chain positions are normal and
  silent. Unknown keys are errors with the config path and source
  line. Output bytes are deterministic.

Unit tests: `cd Components/FRONTPANEL/tools && python3 -m unittest -v test_fpprofile`.

## Current chain assignment (`MicrocomputerZ80CPM.vhd`)

The 256 chain positions (identity-mapped LED numbers in profile 0) are:

| Chain positions | Source |
|-----------------|--------|
| 0-7     | `fpLatch` (I/O port `$FF` style latch), MSB first |
| 8-23    | Z-80 address bus A15..A0 |
| 24-31   | Z-80 data bus (`cpuDataIn`) |
| 32-63   | `fpLatch` again (zero-extended to 32 bits; test data) |
| 64-255  | CPU registers from the T80s `REG` debug vector, MSB first, in this order: A, F, A', F', B, C, B', C', D, E, D', E', H, L, H', L' (8 bits each, positions 64-191), then IX, IY, PC, SP (16 bits each, positions 192-255) |

The register vector is split into symbolic `dbgReg_*` signals in the
architecture. B/C, D/E, H/L are always the *current* register set (the T80
swaps them on EXX); the primed registers are the alternate set.

## Capture-chain variants

Two interoperable PISO capture components are provided. Both share the
same `chain_in` / `chain_out` / `latch` / `shift_en` handshake, so any
mix of them can be daisy-chained to form one logical chain.

**Bit order:** both variants capture `combined_data` and shift it out
**MSB-first** — bit `TOTAL_WIDTH-1` is captured/output first (right
after `latch`), counting down to bit `0` last. For a source register
this means its most-significant bit reaches the first LED position in
the chain, matching left-to-right order on a physical PCB layout
rather than a bit-reversed one.

- **`Universal_Capture_Chain`** — supports both transparent and
  stretched bits in a single instance. `STRETCH_MASK` is a per-bit
  mask: `'1'` enables stretching, `'0'` is transparent. A VHDL-2008
  `if-generate` emits a per-bit hold counter only for bits where
  `STRETCH_MASK(i) = '1'`, so resource cost scales with the number of
  stretched bits, not with `TOTAL_WIDTH`.

- **`Transparent_Capture_Chain`** — no stretching, no per-bit
  conditional logic, no counters. Recommended for the bulk of signals
  (address bus, data bus, register contents) that don't need
  stretching. Use `Universal_Capture_Chain` only for blocks that
  actually mix transparent and stretched bits.

## Example integration/usage

In this example we wire two capture chains in series: one transparent
chain for the address/data/status bus signals, and one universal chain
for the few control signals that need pulse stretching.

VHDL

    -- 24-bit transparent chain for bus signals
    --   [23..16] = Address bus high (Transparent)
    --   [15..8]  = Address bus low  (Transparent)
    --   [7..0]   = Data bus         (Transparent)
    U_BUS : entity work.Transparent_Capture_Chain
        generic map (
            TOTAL_WIDTH => 24
        )
        port map (
            clk           => sys_clk,
            reset         => sys_rst,
            latch         => fp_latch,
            shift_en      => fp_shift,
            combined_data => z_addr & z_dout,
            chain_in      => '0',
            chain_out     => bus_chain_to_ctrl
        );

    -- 8-bit mixed chain for control signals; bits 1 and 0 are stretched
    --   [7..2]   = Status flags (Transparent)
    --   [1]      = IACK         (Stretched)
    --   [0]      = INT          (Stretched)
    U_CTRL : entity work.Universal_Capture_Chain
        generic map (
            TOTAL_WIDTH  => 8,
            HOLD_CYCLES  => 2500000,
            STRETCH_MASK => "00000011" -- Only bits 0 and 1 are stretched
        )
        port map (
            clk           => sys_clk,
            reset         => sys_rst,
            latch         => fp_latch,
            shift_en      => fp_shift,
            combined_data => cpu_status,
            chain_in      => bus_chain_to_ctrl,
            chain_out     => serial_state
        );

Why this split is useful:

    Resource Efficiency: Transparent_Capture_Chain instantiates no
    counters at all, so the 24 bus signals cost only their shift-
    register flops. Universal_Capture_Chain's if-generate emits hold
    counters only for the two control bits that need stretching.

    Synchronous Capture: All capture and stretching happen on the same
    clock, so latch/shift handshake is consistent across chain
    segments.
    or jitter between external modules.

This gives you a powerful, software-like "Config" at the top of your
VHDL file that determines the visual behavior of every single bit on
your front panel.


## LED String Update Rate

1. The Protocol Bottleneck

The WS2812/SK6812 protocol uses a fixed timing where each bit takes
exactly 1.25µs to transmit.

    Bits per LED: Each RGB LED requires 24 bits (8 bits Red+8 bits
    Green+8 bits Blue).

    Total Bits: For 256 LEDs, you must transmit 256×24=6,144 bits.

    Transmission Time: 6,144 bits×1.25μs/bit=7.68ms.

    Reset Time: After the data, the line must stay low for a "Reset"
    period (typically >80μs for SK6812).

Total time to update the entire 256-LED string once is approximately
7.76ms.

2. Maximum Theoretical Frame Rate

If you were to push the string as fast as the physical wire allows:
Max Frequency=0.00776s1​≈128.8Hz

Conclusion: target 100 Hz update rate, derived from the 50 MHz system clock
