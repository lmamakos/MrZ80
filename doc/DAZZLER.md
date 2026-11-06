# Dazzler — Cromemco colour graphics for MrZ80

Status: **design for review (R48)**. Nothing here is built yet; this is the
functional specification and implementation plan for the MrZ80 Dazzler
peripheral. Historical facts come from the Cromemco *TV DAZZLER Instruction
Manual, Rev. C* (1976), in-repo at `doc/cromemco_dazzler_manual_text.pdf`,
cross-checked against independent secondary sources (§6).

---

# Part I — User's guide

## 1. What it is

The Cromemco TV Dazzler (1976) was the first commercial colour bitmap
graphics card for the S-100 bus. It had no frame buffer of its own: it
DMA-readed a region of the host's RAM and turned the bytes into a colour TV
signal, 32×32, 64×64 or 128×128 "picture elements" in up to 16 colours.

MrZ80 implements the Dazzler as an emulated peripheral of the Z-80 core with
three deliberate architecture changes from the original board:

1. **No DMA and no bus hold.** Instead of stealing memory cycles, the
   peripheral *sniffs every Z-80 memory write* and maintains a small internal
   picture buffer. The CPU suffers **zero** slow-down (the original cost about
   15 %), and memory reads are completely untouched.
2. **Digital RGB, not NTSC composite.** The picture is rendered in colour on
   the core's existing 800×526 / 59.4 Hz VGA timing — the same raster as the
   built-in video terminal — instead of encoding a 3.58 MHz composite signal.
3. **A "page" on the same screen.** The Dazzler picture *replaces* the video
   terminal display while it is enabled, and gives it back when disabled,
   exactly like the SSP monitor's video page (R44). The terminal keeps
   running underneath and keeps the keyboard.

## 2. The page model

```
  priority (top wins):   SSP monitor (video console, when shown)
                         Dazzler    (while enabled, port $0E bit 7 = 1)
                         video terminal   (default)
```

* The screen switches to the picture as soon as software sets the enable bit
  (port `$0E`, bit 7). Clearing it gives the screen straight back.
* Switching pages never disturbs sync: all three candidates run identical
  free-running timing off the same 50 MHz clock, so only the colour signals
  swap (the R44 mechanism).
* **Keyboard is not affected.** Keys keep going where they go today — to the
  video terminal, or to the SSP monitor when it has the screen. You can type
  "blind" behind a Dazzler picture and it appears when the page switches back.
* **Escape hatch.** If guest software enables the Dazzler and hangs, OSD
  **Enter SSP Monitor** takes the screen (the monitor outranks the Dazzler),
  and `RESET SYSTEM` (OSD Reset item, panel-style) clears the Dazzler
  entirely.
* A front-panel **Dazzler clear** (the original board's "clear" switch) is
  reserved in the front-panel function contract, like the reset functions
  reserved in R47; the panel itself is not implemented yet.

## 3. I/O ports

Faithful to the original's octal numbering: ports **016** and **017** =
hex **$0E** and **$0F**. Both are decoded with full 8-bit address match
(no S-100-style aliasing); both addresses are free in the current map.

### OUT $0E — start address / control

| Bit | Function |
|---|---|
| 7 | **Enable** — 1 = Dazzler on (picture page up, write-snoop armed); 0 = off (blank / terminal page) |
| 6..0 | **Picture base address**, bits A15..A9. `base = value[6:0] × $0200` — the picture region must begin on a 512-byte boundary |

Examples (verified against the original manual and field experience):
`OUT $0E, $80` → enabled, picture at `$0000`; `$81` → enabled at `$0200`;
`$88` → enabled at `$1000`.

### OUT $0F — picture format

| Bit | Function |
|---|---|
| 7 | not used |
| 6 | **Resolution**: 0 = normal (4 bits/element), 1 = ×4 (1 bit/element) |
| 5 | **Buffer size**: 0 = 512 bytes, 1 = 2 KB |
| 4 | 1 = colour, 0 = black-and-white |
| 3 | 1 = high intensity (normal & colour ×4); in ×4 black-and-white this bit is the MSB of the 4-bit grey word |
| 2 | blue (×4: foreground blue) |
| 1 | green (×4: foreground green) |
| 0 | red (×4: foreground red) |

### IN $0E — sync status

Live timing flags for software that wants to synchronise to the display,
as on the original (bit meanings adapted to the progressive render, §12):

| Bit | Function |
|---|---|
| 7 | 1 during even cell rows, 0 during odd cell rows (top row = row 0) |
| 6 | end-of-frame: goes low for ≈3.8 ms once per frame, during vertical blank |
| 5..0 | read as 1 |

`IN $0F` is not implemented and reads `$FF` like any unclaimed port.

## 4. Where the picture lives

The picture occupies a **512-byte or 2 KB window of logical Z-80 memory**
starting at the base programmed to port `$0E`:

```
size = 512  if port $0F bit 5 = 0        size = 2048 if bit 5 = 1
window = [base .. base + size - 1]   (16-bit arithmetic; a window that runs
                                       off $FFFF wraps to $0000)
```

The window is tracked in the **logical** address space the CPU sees — the
MMU may map that window onto any physical page, and the same window in any
memory frame (and an access issued by the SSP through the bus mux) snoops
into the *same* picture buffer. The window contents in real memory still
read back normally — the Dazzler never responds to reads.

## 5. How the picture gets on screen — write snooping

**Every Z-80 memory write to the window, while the Dazzler is enabled, is
captured into the Dazzler's internal buffer** (and, as always, also proceeds
to system memory). The display is driven from that buffer, not from the
memory. Consequences worth knowing:

* A program that draws by writing to the window — the way all classic
  Dazzler software does (Kaleidoscope, Life, Dazzlewriter, Dazzlemation) —
  behaves exactly as on the original hardware.
* Bytes that were **already in memory before the Dazzler was enabled**
  never reach the screen: nothing wrote them while the snoop was armed. A
  `.BIN` static image dropped from the OSD menu, or memory pre-loaded by
  any other means, will show as black until a program writes it once.
  This is an accepted, deliberate limitation of the snoop architecture
  (decision R48; see §12).
* Because writes are captured live, there is no "15 % slow-down" and no
  contention with the CPU or the SDRAM controller at all.
* Changing base, size or resolution via the ports while enabled takes
  effect immediately; already-captured bytes are kept in the buffer by
  window offset.

## 6. Element coding — normal resolution

Each picture element (cell) is one 4-bit **nybble**; two cells per byte.
Nybble bits, per the manual (p. 3–4):

```
bit 3 : intensity      (1 = high)
bit 2 : blue
bit 1 : green
bit 0 : red
```

In black-and-white mode the four bits are instead a **16-level grey** value
(0 = black … 15 = white).

Within a byte, the manual's diagram (p. 3, LSB shown leftmost) reads:

```
      +---------------+---------------+
byte: |  D7 D6 D5 D4 |  D3 D2 D1 D0|     low nybble  = "one picture element"
      +---------------+---------------+     high nybble = "adjacent element"
              right         left          -> low nybble is the LEFT cell (V-1)
```

The left/right order of the two nybbles is read off the manual diagram and
is on the hardware verification list (§4.4, **V-1**) because the primary
source is a single 1976 diagram.

## 7. Element coding — resolution ×4

Single bit per cell; 1 bit on = element lit in the single foreground colour
from port `$0F` D3–D0, 0 = background (black). The eight cells covered by
one byte are **not** a line of eight — the manual (p. 4) defines a 4-wide ×
2-tall patch:

```
        +------+------+------+------+
        |  D0  |  D1  |  D4  |  D5 |   top    row
        +------+------+------+------+
        |  D2  |  D3  |  D6  |  D7 |   bottom row
        +------+------+------+------+
   cell(x, y) = byte(col/4, row/2) + bit table above
```

In ×4 **black-and-white** mode, the nibble is not just on/off: bits D3–D0
of port `$0F` form a base colour/intensity, and D3 doubles as the MSB of a
4-bit intensity word (manual note, p. 2); see §10 for the implemented
mapping.

## 8. Quadrant layout (2 KB pictures)

A 2 KB picture is four 512-byte quadrants (manual p. 4). Byte offset
`off = addr − base`:

```
      +-------------------+-------------------+
      |  off      0..511  |  off   512..1023|     TL = quadrant 0
      |        (top-left) |      (top-right)|     TR = quadrant 1
      +-------------------+-------------------+     BL = quadrant 2
      |  off   1024..1535 |  off   1536..2047|    BR = quadrant 3
      |      (bottom-left)| (bottom-right)  |
      +-------------------+-------------------+
```

* Scan inside a quadrant is a plain raster: left→right, top→bottom, 16
  bytes per row-pair. (The zig-zag arrows in the manual's memory map are
  flyback strokes, not a serpentine scan — confirmed against two
  independent secondary accounts.)
* **Quadrant 0 alone fills the whole screen** when the buffer size is
  512 bytes, with the cells twice as large (this is how 32×32 and 64×64
  modes display).
* Byte 0 = **top-left** of its quadrant (BMP files therefore load
  "upside-down" relative to the picture — same quirk the original had).
* Quadrant ordering/orientation are verification items **V-2** (§4.4).

## 9. Modes at a glance

| $0F.D6 | $0F.D5 | buffer | cells per side | cells per byte | quadrant split |
|---|---|---|---|---|---|
| 0 | 0 | 512 B | 32 | 2 (nybbles) | no — single page fills screen |
| 0 | 1 | 2 KB | 64 | 2 (nybbles) | 4 × 32×32 |
| 1 | 0 | 512 B | 64 | 8 (4×2 patch) | no — single page fills screen |
| 1 | 1 | 2 KB | 128 | 8 (4×2 patch) | 4 × 64×64 |

## 10. Colours

The core renders 8 bits per gun (§11), so:

* **RGBI nibble** (normal colour mode, and ×4 foreground):
  `intensity/B/G/R` → per gun: off = `$00`, low = `$55`, high = `$FF` —
  the same eight shades × two intensities the video terminal already uses.

  | nibble | colour | nibble | colour |
  |---|---|---|---|
  | 0 | black | 8 | grey ~33 % |
  | 1 | dark red | 9 | bright red |
  | 2 | dark green | A | bright green |
  | 3 | dark yellow | B | bright yellow |
  | 4 | dark blue | C | bright blue |
  | 5 | dark magenta | D | bright magenta |
  | 6 | dark cyan | E | bright cyan |
  | 7 | dark white | F | white |

* **16-level grey** (B&W modes): grey value `g` → all three guns = `g × 17`
  (`$00, $11, $22 … $FF`) — true 16 levels, made possible by the 8-bit
  output path.
* **×4 colour**: foreground = RGBI from `$0F`.D3–D0 (intensity, B, G, R),
  background black. Full-colour imagery in ×4 is done, as originally, by
  interleaving frames with different colours chosen via port `$0F`.

## 11. What you see on the monitor

The Dazzler page reuses the terminal's raster: 800×526 pixels, ~59.41 Hz
(the terminal's vertical counter wraps at `> VERT_SCANLINES-1` = line 525,
so a frame is 526 lines, not 525; the Dazzler must mirror the exact wrap —
a 525-line page crept upward ~1 line/s against the syncs in hardware R48),
4:3 through the framework scaler. The picture box is a fixed **384×384
pixels centred** in the terminal's 640×400 text-active area (pixels
x 288…671, y 83…466), so all four modes share one square frame and cells
are **square** on-screen:

| cells per side | cell size (screen px) |
|---|---|
| 128 | 3 × 3 |
| 64 | 6 × 6 |
| 32 | 12 × 12 |

## 12. Deviations from the original board

| # | Original hardware | MrZ80 implementation |
|---|---|---|
| 1 | DMA with HOLD/HLDA, ~15 % CPU slow-down, 1 MB/s | Pure write-snoop; zero CPU cost, zero contention |
| 2 | Display source = live RAM contents | Display source = write-captured buffer; **content existing before enable is not shown** (no priming — R48 decision). Reads always serve RAM, never the Dazzler |
| 3 | NTSC composite video with 3.58 MHz subcarrier, imperfect interlace, ~68 %×77 % of active scan | Digital RGB, progressive, 384×384 box centred (≈60 %×96 % of the terminal's active box) |
| 4 | "Clear" front-panel switch disables the Dazzler | Front-panel function reserved; OSD **Enter SSP Monitor** and `RESET SYSTEM` are the escape hatches |
| 5 | Two boards, genlock between them | N/A — single internal render |
| 6 | `IN $0E`.D7 = TV line parity, D6 = ~4 ms EOF pulse | D7 = cell-row parity, D6 = low during the first ~60 scanlines (~3.84 ms) of vertical blank — same software use (frame/field hooks), progressive semantics |
| 7 | Port decode ≈6-bit, ports repeat through the S-100 map | Full 8-bit decode: only `$0E` / `$0F` respond |

## 13. Quick-start (Z-80, um80 syntax)

```asm
        MVI  A,81H          ; enable + picture base $0200
        OUT  0EH
        MVI  A,30H          ; normal resolution, 2K buffer, colour
        OUT  0FH
; ... draw by writing nybbles to $0200..$09FF ...
        MVI  A,00H          ; disable -> terminal page returns
        OUT  0EH
```

A 64×64 colour picture needs 2 KB starting on a 512-byte boundary; the
first byte lands top-left, the next seven bytes fill the rest of that row
of 16 bytes (32 cells), and so on; bytes `$200`–`$3FF` are the top-right
quadrant, `$400`–`$5FF` the bottom-left, `$600`–`$7FF` the bottom-right
(see §8; subject to V-2 confirmation).

---

# Part II — Architecture and implementation plan

## 14. Block diagram

```
 Z80 bus (in MicrocomputerZ80CPM.vhd, clk_sys 50 MHz)
   cpuAddress ──┬────────────┐
   cpuDataOut ──┼──┐  OUT $0E/$0F          IN $0E
   n_WR,n_MREQ ─┼──┼──┐  ┌───────────────────────┐
   n_IORQ ──────┘  └──┼─►│  dazzler (new VHDL)   │◄── N_RESET (= sys reset)
                       │  │  ┌─────────────────┐  │
        mem write      │  │  │ control regs  │  │  enable, base, format
        snoop window ──┼─►│  │ ┌───────────┐ │  │
                       │  │  │ │ FB RAM  │◄┼──┼── 2048×8, written by snoop
                       │  │  │ └─────┬───┘ │  │
                       │  │  │   renderer (own 800×526 counters, cell decode,
                       │  │  │         palette)  ────────► dz_show, dz_r/g/b [7:0]
                       │  │  └───────────────────┘
                       │  └───────────────────────┘
                       ▼
 MrZ80.sv:  VGA_R/G/B = (dz_show && !ssp_vdu_show) ? dz_rgb : video_cleaner_out
```

All new logic is in the `clk_sys` (50 MHz) domain — the same domain as the
video terminal and the Z80 bus observation. No CDC, no SDRAM involvement.

## 15. New file: `Components/DAZZLER/dazzler.vhd`

One entity, VHDL (so the GHDL lanes can elaborate it):

```vhdl
entity dazzler is
    generic (
        NYBBLE_LEFT_IS_LOW : boolean := true;  -- V-1 flip candidates
        QUADS_ASCEND_LR_TB : boolean := true   -- V-2
    );
    port (
        clk, n_reset   : in    std_logic;              -- clk_sys, system reset
        -- I/O port side (qualified by the core's new chip-select; reads
        -- are a pure combinational decode of rdata, so no n_rd is needed)
        addr           : in    std_logic_vector(7 downto 0);  -- cpuAddress(7:0)
        wdata          : in    std_logic_vector(7 downto 0);  -- cpuDataOut
        n_wr           : in    std_logic;     -- asserted-low $0E/$0F strobe
        rdata          : out   std_logic_vector(7 downto 0);  -- status, for $0E
        -- write-snoop side
        mem_wr         : in    std_logic;    -- raw CPU memory-write cycle
        mem_addr       : in    std_logic_vector(15 downto 0);
        mem_wdata      : in    std_logic_vector(7 downto 0);
        -- video side
        show           : out   std_logic;    -- page request (see §17 for precedence)
        r, g, b        : out   std_logic_vector(7 downto 0)
    );
end entity;
```

Internals:

* **Register file** — `en`, `base[14:8]` (A15..A9), `mode[5:0]` ($0F D5–D0:
  x4, size, bw/colour, int, B, G, R), all written on `OUT` cycles, cleared
  by `n_reset`.
* **Snoop** — capture condition:
  `en = 1 and mem_wr = 1 and (mem_addr − base) < size` using 16-bit
  arithmetic (gives the wrap of §4 for free); write-through into FB RAM at
  the offset. Sized for the CPU's worst-case write rate; one capture per
  cycle is plenty at `clk_sys`.
* **FB RAM** — 2048 × 8, 1R/1W, common clock (inferred altsyncram; same
  idiom as `Components/TERMINAL/DisplayRam2K.vhd`). One M10K block.
* **Renderer** — free-running `horizTick/line` counters with the terminal's
  constants (`CLOCKS_PER_SCANLINE=1600`, `HSYNC_CLOCKS=192`,
  `VERT_SCANLINES=525`, `VSYNC_SCANLINES=2`), **never reset**, started
  with the terminal at FPGA configuration — the R44 lock trick, so  `show`
  never breaks sync. The vertical wrap must match the terminal's off-by-one
  (`> VERT_SCANLINES-1` → 526 lines/frame). Derives its own ×2 pixel tick
  (CE_PIXEL is
  also available if simpler). Computes, per pixel tick: inside-picture-box?
  → cell (x, y) → inverse-map (§16) → FB byte → sub-cell nibble/bit →
  palette → `r,g,b`; outside the box (still on-page): black.
* **Status bits** — `D7 = not cell_y(0)` sampled at the last vsync for
  stability; `D6 = not vblank[0..59]`-window during vertical back porch;
  `D5..0 = '1'`.

## 16. Cell decode (renderer inverse map)

With `n` cells/side (§9), `box = 384`, `cellpx = 384/n`:

```
x = (px − 288) / cellpx          y = (line − 83) / cellpx        (0..n−1)

2K modes:   q  = 2·[y ≥ n/2] + [x ≥ n/2]   (§8 order TL,TR,BL,BR)
            xq = x mod (n/2)               yq = y mod (n/2)     quadrant-local
512 modes:  q = 0,  xq = x,  yq = y                            whole screen

normal mode: off = q·512 + yq·16 + ⌊xq/2⌋    nibble = low if xq even else high
×4 mode:     off = q·512 + ⌊yq/2⌋·16 + ⌊xq/4⌋
             bit  = PATCH[xq mod 4][yq mod 2]   (§7 patch table)
```

Both modes use exactly 16 bytes per quadrant row, which is what makes the
`·16` term common to them (normal row = 32 cells = 16 bytes; ×4 row-pair =
64 cells = 16 bytes).

## 17. Integration — edits to existing files

1. **`MicrocomputerZ80CPM.vhd`**
   * One chip-select beside the others (§"CHIP SELECTS GO HERE"), covering
     the pair as a 2-port window (the peripheral distinguishes `$0E/$0F`
     from `addr(0)` itself):
     `n_dazzlerCS <= '0' when cpuAddress(7 downto 1) = "0000111" and (n_ioWR='0' or n_ioRD='0') else '1';`
   * Instantiate `dazzler` with `dz_mem_wr <= not n_memWR` — i.e.
     `n_WR = '0' and n_MREQ = '0'` (raw bus cycle — see note below),
     `addr => cpuAddress(7 downto 0)`, `n_wr => n_dazzlerCS or n_ioWR`,
     `n_reset => N_RESET`.
   * Add a leg to the `cpuDataIn` mux, above the memory legs:
     `dazzlerDataOut when n_dazzlerCS = '0' else …` (IN `$0F` reads
     `$FF` — the unclaimed-register leg).
   * New entity ports: `dz_show`, `dz_r`, `dz_g`, `dz_b` (out, 8-bit).
   * Note: the snoop deliberately uses the plain `n_WR ∧ n_MREQ` term, so
     MMU-promoted I/O writes (`$B0–$BF` data port) are *not* captured; the
     picture window is defined as ordinary memory writes only.
2. **`MrZ80.sv`**
   * Wire `dz_*` from the core instance; route `video_cleaner`'s outputs to
     `clean_r/g/b` wires instead of directly to the ports; final mux at the
     8-bit output, after the cleaner:
     `assign VGA_R = dazzle_show ? dz_r : clean_r;` (same G/B) with
     `dazzle_show = dz_show & ~ssp_vdu_show;` — SSP monitor outranks the
     Dazzler page (R48 ruling), and both keep sync continuous because they
     share the cleaner's timing inputs.
   * No change to `CE_PIXEL`/`hs`/`vs`/blank sourcing, keyboard routing, or
     the R44 pre-cleaner mux (terminal/SSP stay 2-bit as today).
3. **`MrZ80.qsf`** — `set_global_assignment -name VHDL_FILE
   Components/DAZZLER/dazzler.vhd` (mechanism 2 of `AGENTS.md`).
4. **`sys/` is not touched.**

Reset wiring gives the intended semantics for free: `N_RESET` is
`~(reset_sys | ~bin_loaded)` — the **system** domain. OSD Reset /
`RESET SYSTEM` (~65 ms, R47) therefore clears enable, registers and the FB
RAM; the monitor's `RESET CPU` (vent + trampoline) does not touch the
Dazzler, so the picture survives a CPU reset exactly as it survived a
CPU-reset on the original board.

## 18. Resource estimate

~1 M10K block (FB) + a few hundred ALMs (decode + renderer). Negligible
against current usage (~34 % ALM, <½ block-RAM — `doc/OVERVIEW.md` §8).
No timing risk: everything is single-clock at 50 MHz with the same
constraints the terminal already meets.

## 19. Verification plan

### 19.1 New GHDL lane — `make -C sim dazzler`

`sim/tb_dazzler.vhd` (run by `sim/run_dazzler.sh`) drives synthetic bus
cycles and clocks. Passing today: enable/`show`, cell colours and widths,
quadrant sample points, disabled-window write rejection, 16-bit wrap,
`IN $0E` low bits, and the vertical cell-scan regression (row 1 cell colour
checked one cell-row below the top by line-period alignment — added after
hardware showed cell rows not advancing; the gate must be the line index,
not the box window, since a line-end lies outside the horizontal window),
and the frame-period lock (measuring the cell(0,0) burst gap across the
wrap gives exactly 521×1600 clks — the terminal's 526-line frame; this is
the check that would have caught the slow upward scroll seen in hardware).
The fuller matrix:

| # | Test |
|---|---|
| A | Power-on state: disabled, base 0, mode 0, `show=0` |
| B | Port writes/read-back; `IN $0E` values; `IN $0F` ⇒ `$FF` by the default leg |
| C | Base encoding vectors (`$80→$0000`, `$81→$0200`, `$88→$1000`) |
| D | Normal-mode capture: all 16 RGBI colours + 16 greys; FB byte checks + pixel assertions at sampled coordinates (edges/corners of the box) |
| E | ×4 capture: bit-patch geometry — each of D0..D7 alone lights exactly its documented cell |
| F | 2K quadrant routing: sentinel byte per quadrant, assert screen position (V-2 oracle) |
| G | Window edges: last/first byte in-window, out-of-window, disabled, 16-bit wrap; promoted-I/O writes ignored |
| H | `IN $0E`.D7 row-parity and D6 EOF timing against the raster; system reset clears; CPU-domain reset leaves state |
| I | Live mode/base switching mid-frame without sync disturbance; page `show` vs `ssp_vdu_show` precedence |
| J | Vertical cell scan at all three resolutions: cell colour asserted at several cell rows (guard against the row-advance gate regressing) |

Mutation pass on the snoop window arithmetic and quadrant decode, in the
style of the existing lanes. Lane wired into the full `make -C sim` loop.

### 19.2 Synthesis

`tools/build.sh synth` clean (no new warnings beyond the standing 18010s);
record pre-fit utilisation.

### 19.3 Hardware — demo + bench checklist

`testing/dazzldemo.azm` (built with `tools/z80asm.sh`; commit the .bin
with it as a deliberate deliverable, per the `AGENTS.md` exception):
vertical RGBI bar field, grey wedge (same bytes in B&W), solid R/G/B/white
quadrants, cell checkerboard (white, `0Fh`/`F0h` byte rows — a flat `AAh`
fill would be uniform green, both nibbles being `Ah`), fine ×4 stripes at
512 B and 2 K,
and enable-toggle page swaps ×4 — all four modes, live base/mode changes.
(A moving-pattern animation is deferred; a live-busy sweep is trivial to
 add.) Bench checklist (new section in this document, run and signed like
 R47's §4.4) — hardware session 2026-11-06:

 * **PASS** page swaps are sync-stable, terminal content intact underneath
   (per-stage terminal flashes with stage tags, plus ×4 page swaps)
 * **PASS** V-1 and V-2 closed: bars unmirrored, quadrants
   TL=red/TR=green/BL=blue/BR=white, checkerboard seams aligned —
   orientation generics confirmed at their defaults
 * **PASS** `IN $0E` frame hooks usable by a timing-sensitive program
   (the demo's frame sync drives every stage delay)
 * **PASS** images stable — no scroll (required the renderer to mirror the
   terminal's 526-line vertical wrap; see §11)
 * **TODO** `RESET CPU` keeps the picture; `RESET SYSTEM` clears it; SSP
   monitor outranks the page
 * **TODO** Kaleidoscope / Life reference programs (owner originals, if
   ever located) as an independent orientation cross-check

## 20. Documentation updates to follow in the implementation round

`HARDWARE.md` port table (+ `$0E/$0F` rows and the picture-window note),
`doc/ARCHITECTURE.md` block + port map, `doc/OVERVIEW.md` feature line,
`README.md`; `build_id.v` re-stamped in its own commit per the AGENTS rule
(the core netlist changes). Nothing is pushed, per standing rule.

## 21. Open questions — all resolved (owner rulings, 2026-11-06)

* **OQ-D1 — CLOSED.** V-1 (nybble left = low) and V-2 (quadrant order)
  confirmed correct on hardware; generics stay at their defaults (kept as
  documented flip candidates).
* **OQ-D2 — CLOSED.** Owner confirms `$0E/$0F` are free; no need to
  re-open at RomWBW port time beyond a normal port-map sanity pass.
* **OQ-D3 — CLOSED.** No dedicated front-panel "Dazzler clear" function;
  the existing system resets already clear the page (per design §12:
  RESET SYSTEM clears, RESET CPU does not).
* **Cell aspect** — owner ruling: keep cells pixel-square exactly as
  specified (the ~20% vertical stretch is the 4:3 display chain's doing,
  not the core's); no aspect-compensated box.

## 22. References

* Cromemco, *TV DAZZLER Instruction Manual*, Rev. C, 1976 —
  `doc/cromemco_dazzler_manual_text.pdf` (in-repo primary source; ports
  p. 2–3, element coding p. 3–4, troubleshooting DMA structure p. 5+).
* Wikipedia / HandWiki, *Cromemco Dazzler* — ports 0E/0F, 1 Mbit/s DMA,
  mode matrix (secondary).
* WorldPhaco, *The Cromemco Dazzler, Re-born* (2020) — working modern
  reproduction; confirms `base = port[6:0]×$0200` ($81→$0200, $88→$1000),
  the 4×2 ×4 byte patch (bits D0,D1/D2,D3 then D4,D5/D6,D7), byte 0 =
  top-left, non-sequential quadrants, and the timing quirks quoted in §12.
* Steve Ciarcia, "The Cybernetic Crayon," *BYTE*, Dec 1976 (referenced by
  the manual; not re-checked here).
