# Front Panel Subsystem

A WS2812/SK6812 "blinkenlights" front panel for the MrZ80 core: 256 RGB
LEDs driven from a single FPGA pin, mirroring live CPU state — data and
address buses, plus every register of the T80, including shadow banks,
IX/IY, and interrupt state.

This document is the user guide and datasheet: what the hardware does,
the I/O map, the profile file format, and the current signal chain.
Development history lives in `../../HISTORY.md`; the wish-list the
feature grew from is in `FEATURE.md`; the CPU-side signal source is
documented in `../../doc/t80_reg_debug_vector.md`.

## Where it connects (current build)

| Item | Value |
|---|---|
| LED data line | `USER_OUT[6]` of the MiSTer `USER_IO` header |
| Subsystem I/O window | `$A0–$A7` (decoder: `cpuAddress(7 downto 3) = "10100"`) |
| Latch port feeding chain bits | `$FF` (R/W, legacy IMSAI-style output latch) |
| Capture-chain length | `CHAIN_BITS => 384` at the `FrontPanel_Subsystem` instantiation |
| LED count | `NUM_LEDS = 256` |
| Refresh rate | ~62.5 Hz (a `refresh_tick` every 800 000 clk at 50 MHz) |
| Simulation | `sim/tb_frontpanel.vhd` — decodes the WS2812 stream and checks every LED; run via `sim/run_frontpanel.sh` |

### Current behaviour notes

* Bits shift out of the capture chains **MSB-first**; with the default
  identity profile, LED *i* shows bit *i* of the chain in natural
  left-to-right order.
* LED state changes are **instant**. Gradual fade between the ON and OFF
  colours (simulated incandescent lag) is designed but not currently
  implemented; the `+1` port was repurposed (see the register map) and
  the fade machinery is future work.
* **Global brightness (`+0`) is live**: each output channel is scaled by
  the classic 8-bit `scale8` rule (`out = ch * bright / 256`); `0xFF` ≈
  full, `0x00` fully off.
* Colours are handled as **plain RGB everywhere software can see**. The
  GRB byte reordering the WS2812 wire requires happens internally
  immediately before the PHY and never appears on a port.
* Profile RAM (colours, maps, framebuffer) **re-initializes on every
  reset** (~2050 clk for 256 LEDs × 8 profiles) from the loaded profile
  file or the built-in defaults; the first refresh waits for it. This
  means Z-80 modifications to profiles deliberately do not survive a
  reset, and simulation (GHDL) matches hardware — no hidden
  power-up-only init.
* The global pointer auto-increments **wrap at `NUM_LEDS`**, so streaming
  any multiple of LED accesses is well-defined.
* Z80-side I/O strobes are edge-gated internally: one `OUT`/`IN` is one
  access regardless of how long the FPGA clock oversamples the bus cycle.

## Concept

If the CPU lives in an FPGA, every internal signal is observable — so
show them all. Each LED has independent, programmable ON and OFF colours
(OFF is usually dim, not dark, so a register of all-zeros still glows
faintly), and the mapping from LED to signal bit is a per-profile RAM
table. Briefly-pulsed signals (interrupts, bus strobes) can be
*stretched* — held lit long enough to see — by the chain hardware
itself. Different profiles can paint the same panel completely
differently (all registers one frame, bus signals the next), switchable
by software or on the fly from the OSD.

## I/O register map

`FrontPanel_Subsystem` decodes 8 consecutive ports; the example build
places the window at `$A0–$A7` (the module itself only inspects `addr(2
downto 0)`, so the decoder sets the base).

| Offset | R/W | Function |
|--------|-----|----------|
| `+0` | R/W | Global brightness (scale8 factor; `0xFF` ≈ full, `0x00` off). |
| `+1` | R/W | **Map high**: write — bits 1:0 become map bits 9:8 for later `+5` writes (sticky; 0 after reset). Read — map bits 9:8 of the entry at the global pointer (read it *before* the `+5` read, which advances the pointer). Only meaningful when the chain is longer than 256 bits; see *Long capture chains*. |
| `+2` | R/W | Global pointer (LED index used by `+3`, `+5`, `+6`). |
| `+3` | W  | Colour stream, R,G,B order. Six bytes per LED: on-R,G,B then off-R,G,B. The pointer advances after the sixth byte. |
| `+4` | R/W | Mode: bit 0 = 0 mirror capture chain (default), 1 = framebuffer. |
| `+5` | R/W | Mapping-table entry of the profile at the pointer (low byte). Reads and writes auto-advance the pointer. |
| `+6` | R/W | Framebuffer bit at the pointer. Reads and writes auto-advance. |
| `+7` | R/W | Active profile number (low 3 bits, reads 0..7, 0 after reset). |

Pointer auto-advance on `+3`/`+5`/`+6` wraps at `NUM_LEDS` back to 0.

## Profiles

The subsystem holds **8 profiles**. A profile gives, for each of the 256
physical LEDs:

- the **map**: which capture-chain position drives that LED (chain
  position 0 is the first bit shifted out of the chain), and
- the **ON** and **OFF** RGB colours.

Brightness (`+0`), the mode (`+4`) and the framebuffer (`+6`) are
global, not per profile.

* **Selecting (software):** write the profile number to `+7`. The choice
  is latched at the start of each refresh frame, so a switch never shows
  a frame that mixes two profiles.
* **Selecting (OSD):** the OSD item **Front Panel Profile**
  (`Software`, `0`..`7`) overrides which profile the LEDs show, on the
  fly, without resetting or stalling the CPU — and invisibly to
  software: `+7` still reads back what the Z-80 wrote, and `+3`/`+5`
  writes still go to the Z-80's own selected profile. `Software`
  (default) means no override. The value is sampled once per frame and
  is saved in the MiSTer settings.
* **Defaults:** with no profile file loaded, all 8 profiles are the
  identity map (LED *n* shows chain bit *n*) with ON = `#FF0001`,
  OFF = `#000009`.
* **Z-80 modifications** (`+3`, `+5`) apply to the Z-80-selected
  profile and persist across profile switches — but **any reset**
  (including OSD Reset) re-initialises all profiles from the loaded
  file, or from the defaults.
* **Profile file:** the OSD item **Front Panel Profiles** (config-string
  `FC5`, extension `.FPP`) loads a file that initialises all 8
  profiles; the core resets after the download so it takes effect
  immediately. The file survives OSD Resets, is forgotten on the front-
  panel RESET button (like the boot `.BIN`), and is never written to
  SDRAM. A file with a bad header or wrong length is ignored (defaults
  stay in effect). File indices 3 and 4 are reserved for RAM-disk
  images.
* **Storage:** `FP_RAM_Store` holds the working RAM (`color_ram`,
  `map_ram`: 2048 entries addressed `{profile, led}`) plus a pristine
  copy of the loaded file (`pri_ram`) used to restore the working copy
  on every reset.

### Signal colours (authoring-time)

The hardware keys colours to physical LEDs, but the profile *tool* lets
colours be authored per **signal** instead: a `signal_colors` table in
the YAML attaches ON/OFF colours to chain positions (by name, range or
number), and at build time each colour is written into every LED whose
map selects that bit — see `tools/fpprofile.md` §
[`signal_colors`](tools/fpprofile.md#signal_colors). The binary file
and the core are unchanged (still v2, still per-LED). Two consequences
of baking:

- A Z-80 rewriting a map entry (`+5`) at runtime does **not** move the
  colour with the new signal: the LED keeps whatever colour was baked
  for the old one until the file is regenerated and reloaded.
- Colour edits over the bus (`+3`) address LEDs, as before; there is no
  "edit signal *n*'s colour" port.

### Long capture chains (up to 1024 bits)

`FrontPanel_Subsystem` has generic `CHAIN_BITS` (1..1024; the shipped
core builds 384): the LED string stays 256, but a profile map may select
any of `CHAIN_BITS` chain positions, so different profiles can paint
different slices of a longer chain (one for registers, one for bus
signals). A map value ≥ `CHAIN_BITS` renders that LED's OFF colour.
Cost: one `shadow_reg` flop per extra bit, a wider map RAM, and a
longer capture phase per frame. Framebuffer mode is unchanged (one bit
per LED, 256 max).

Z-80 access to map entries above 255: write the high bits (map 9:8) to
`+1`, then the low byte to `+5`; the high bits stay sticky for subsequent
`+5` writes — clear `+1` when done. Software that never touches `+1`
sees and writes maps 0..255 exactly as before. To read an entry back:
set the pointer, read `+1` (high bits), then `+5` (low byte, advances
the pointer).

### Profile file format

Version 2, exactly **16400 bytes** (all values are bytes):

| Offset | Size | Content |
|--------|------|---------|
| 0      | 4    | Magic `FPPF` (`46 50 50 46`) |
| 4      | 1    | Version, `02` |
| 5      | 1    | Number of profiles, `08` |
| 6      | 2    | LEDs per profile, little endian, `01 00` (256) |
| 8      | 8    | Reserved (ignored; the tool writes zeros) |
| 16     | 8 × 256 × 8 | Profile 0 LED 0..255, then profile 1, ... profile 7. Each record: `map low, map high, onR, onG, onB, offR, offG, offB` (map is 16-bit little-endian, valid < `CHAIN_BITS`). |

Version 1 files (1-byte maps, 14352 bytes) are no longer accepted by the
hardware; `fpprofile.py --dump` can still decode them.

### Building profile files — `tools/fpprofile.py`

The full user guide for the Python tool is **[`tools/fpprofile.md`](tools/fpprofile.md)**.
Quick reference:

    cd Components/FRONTPANEL/tools
    python3 fpprofile.py example_profiles.yaml -o example_profiles.fpp
    python3 fpprofile.py --dump example_profiles.fpp

Input is YAML (Python ≥ 3.9, PyYAML — Debian `python3-yaml`). Copy the
output to the MiSTer SD card and load it via the OSD. `tools/example_profiles.yaml`
is an annotated example for the development panel (8 × 32 matrix)
matching the signal chain below. Unit tests:
`python3 -m unittest -v test_fpprofile` in `tools/`.

## Current capture chain (`MicrocomputerZ80CPM.vhd`, 292 wired bits)

> Authoritative bit map: [`../../SIGNAL-CAPTURES.md`](../../SIGNAL-CAPTURES.md)
> — update that table whenever the chain changes. Summary below.

Chain positions below are also the LED numbers under the identity
profile, MSB-first throughout. The chain is built from six daisy-chained
segments, in order toward the LED controller: `fpChainEnd` →
`fpChainCPUctl` → `fpChainPhysAddrBus` → `fpChainRegs` →
`fpChainStaticTest` → `fpChain`. Source detail for the register bits is
in [`doc/t80_reg_debug_vector.md`](../../doc/t80_reg_debug_vector.md).

| Positions | Source |
|-----------|--------|
| 0–7 | `fpLatch` — the `$FF` output latch, bit 7 first |
| 8–23 | address bus A15..A0 |
| 24–31 | data bus `D7..D0` (bus contents; CPU-driven during writes) |
| 32–223 | CPU registers (exact order in the next table) |
| 224–251 | `mmu_phys_addr[27:0]` — MMU physical address, bit 27 first |
| 252–259 | CPU control, active-high: `/WR` `/RD` `/INT` `/NMI` `/BUSRQ` `/M1` `/HALT` `/BUSAK` (`/INT`, `/NMI`, `/BUSRQ` currently tied inactive) |
| 260–279 | reserved, tied 0 |
| 280–283 | `/WR` `/RD` `/MREQ` `/IORQ` — **stretched** (glow ≈ 50 ms per pulse) |
| 284–291 | `fpLatch` again (bit 7 first) |

The register region (32–223) mirrors the T80 `REG` export through the
symbolic `dbgReg_*` signals, in this exact LED order:

| Positions | Register | Positions | Register |
|-----------|----------|-----------|----------|
| 32–39 | `A` | 128–135 | `H` |
| 40–47 | `F` | 136–143 | `L` |
| 48–55 | `A'` | 144–151 | `H'` |
| 56–63 | `F'` | 152–159 | `L'` |
| 64–71 | `B` | 160–175 | `IX` |
| 72–79 | `C` | 176–191 | `IY` |
| 80–87 | `B'` | 192–207 | `PC` |
| 88–95 | `C'` | 208–223 | `SP` |
| 96–103 | `D` | | |
| 104–111 | `E` | | |
| 112–119 | `D'` | | |
| 120–127 | `E'` | | |

Notes:

* `B/C`, `D/E`, `H/L` are always the **current** bank and the primed
  names the alternate bank: after an odd number of `EXX`, the T80
  reports both banks correctly through this fixed layout (the `REG`
  vector re-orders internally; verified by `sim/tb_cpuregs.vhd`).
* The wired chain is 292 bits but `CHAIN_BITS => 384`: positions
  292–383 exist and read 0 (shifted in from the far `chain_in = '0'`),
  giving headroom for added segments. An identity profile map exposes
  bits 0–255 only — the upper control bits at 256–291 (upper CPU
  control, reserved filler, and the `fpLatch` echo) need a profile that
  maps them explicitly (maps are 16-bit).

## Capture-chain components

Two interoperable PISO capture entities share the same
`latch` / `shift_en` / `chain_in` / `chain_out` handshake, so any mix
daisy-chains into one logical chain. Both capture `combined_data` and
shift it out **MSB-first**: bit `TOTAL_WIDTH-1` leaves first (right after
`latch`), bit 0 last — a source register's MSB reaches the first LED
position, matching left-to-right layouts rather than a bit-reversed one.

### `Transparent_Capture_Chain`

| Generic | Meaning |
|---|---|
| `TOTAL_WIDTH` | bits captured |

No counters, no stretching — use for the bulk of signals (buses,
registers).

### `Universal_Capture_Chain`

| Generic | Meaning |
|---|---|
| `TOTAL_WIDTH` | bits captured |
| `HOLD_CYCLES` | how long a captured 1 stays asserted |
| `STRETCH_MASK` | per-bit enable: 1 = stretched, 0 = transparent |

A VHDL-2008 `if-generate` emits a hold counter only for bits with
`STRETCH_MASK(i) = '1'`, so cost scales with stretched bits, not chain
width. Stretching makes brief pulses (interrupts, strobes) visible to
the eye. Use this entity only where stretching (or mixed blocks) are
actually needed.

### Example wiring

Two segments in series — a transparent chain for bus signals and a
universal chain for two stretched control signals:

```vhdl
-- 24-bit transparent chain for bus signals
--   [23..16] address high   [15..8] address low   [7..0] data
U_BUS : entity work.Transparent_Capture_Chain
    generic map (TOTAL_WIDTH => 24)
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
--   [7..2] status flags (transparent)   [1] IACK   [0] INT
U_CTRL : entity work.Universal_Capture_Chain
    generic map (
        TOTAL_WIDTH  => 8,
        HOLD_CYCLES  => 2500000,
        STRETCH_MASK => "00000011"      -- only bits 0 and 1 stretch
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
```

The split keeps resource use minimal: the bus segment costs only shift
flops, and counters exist only for the two stretched bits. All capture,
stretching, and shifting happen on one clock, so the latch/shift
handshake is consistent across segments.

## LED string update rate

The WS2812/SK6812 bit time is fixed at 1.25 µs:

* bits per frame: 256 LEDs × 24 bits = 6 144 bits
* data time: 6 144 × 1.25 µs = 7.68 ms
* plus the reset low period (> 80 µs for SK6812)

⇒ one full-string update ≈ **7.76 ms**, so the physical ceiling is
1/0.00776 ≈ **129 Hz**. The design ticks a refresh every 800 000 clk
(~62.5 Hz at 50 MHz), comfortably inside the budget even with the
longer capture phase of a 384-bit chain.
