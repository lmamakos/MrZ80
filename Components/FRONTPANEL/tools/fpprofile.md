# `fpprofile.py` — Front-Panel Profile File Generator

User guide for the tool that turns a human-readable YAML panel
description into the binary `.fpp` profile file the core loads through
the OSD. For the hardware side — I/O map, chain signals, file loading —
see [`../README.md`](../README.md); this document covers the tool and
its YAML configuration language only.

    cd Components/FRONTPANEL/tools
    python3 fpprofile.py example_profiles.yaml -o profiles.fpp
    python3 fpprofile.py --dump profiles.fpp

## Requirements

* Python ≥ 3.9.
* **PyYAML** — Debian/Ubuntu package `python3-yaml` or
  `pip install pyyaml`. If the import fails the tool says so with this
  hint; there is no silent fallback.
* YAML rules: two-space indentation (tabs are invalid YAML), single
  document, no tags or anchors (`safe_load` only).

## Mental model

| Term | Meaning |
|------|---------|
| **chain** | The capture chain: a vector of signal bits the hardware clockes out to the LED controller. |
| **chain position** | Zero-based index into the chain. Position 0 is the first bit shifted out. Which signal lives at each position is fixed by the FPGA build — the table is in `../README.md` § *Current capture chain*. |
| **chain_bits** | The chain length the tool validates against (1..1024). It must match the `CHAIN_BITS` of your core build — the shipped build is **384**. |
| **LED** | One of the `leds` (default 256) physical LEDs, numbered 0..leds-1 in strip data-wire order. |
| **panel / cell** | The LEDs arranged as a `rows` × `cols` grid. Cells are `[row, col]`, zero-based, origin **top-left**. |
| **layout** | The single global description of the panel: grid size and wiring order. It applies to every profile. |
| **wiring walk** | The traversal of all cells defined by the layout: the cell visited at step *n* holds physical LED *n*. |
| **run** | A placement inside a profile: a start cell, a direction, and an ordered list of signal references. |
| **span** | The cells of a run's line: from `start` to the panel edge in the run's direction, inclusive. The span size is the run's **capacity**. |
| **claim** | The cells a run actually occupies: exactly its expanded data, never the bare edge beyond it. |
| **element** | One item of a run's `signals` list: a bare reference token, or a map with a token and optional colours. |
| **reference token** | A chain position number, a range `a..b`, a symbol name, a subset `NAME[..]`, or the blank marker `-`. |
| **symbol** | A named group of chain positions defined in the `signals` table. |
| **blank** | A cell showing no signal: a static dim LED (see § Blanks). |
| **profile** | One of the 8 profiles (0..7) the hardware holds. |

The flow: `signals` name chain bits → `signal_colors` colours
them → `profile.N` runs place them on cells → the layout converts cells
to LED numbers → the output file gives every LED its chain position plus
ON/OFF colours.

## Configuration reference

Input is YAML; **unknown keys are errors**, reported with the
configuration path and source line.

### Top-level keys

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `chain_bits` | integer | 256 | Validation chain length, 1..1024. Override with `--chain-bits`. **Match your build** (shipped core: 384). |
| `leds` | integer | 256 | Physical LED count (mirrors the FPGA `NUM_LEDS` generic). The layout must cover it exactly. |
| `dir` | `right` \| `left` \| `up` \| `down` | `right` | Default run direction for every profile that does not set its own. |
| `signal_colors` | mapping | — | Colours attached to **signals** (chain positions) instead of LEDs; every LED displaying the bit in any **defined** profile inherits them. See § [`signal_colors`](#signal_colors). |

`rows * cols` must equal `leds`; a mismatch fails loudly rather than
emitting a silently wrong map.

### `layout` — panel wiring (one, global)

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `rows` | integer ≥ 1 | required | Grid rows. |
| `cols` | integer ≥ 1 | required | Grid columns. |
| `origin` | corner | `top-left` | Where the wiring walk starts: `top-left`, `top-right`, `bottom-left`, `bottom-right` (the physical feed corner). |
| `major` | `row` \| `column` | `row` | Direction the walk runs within a line before stepping to the next. |
| `serpentine` | bool | `false` | If true, every second line reverses direction. |

The wiring affects only the cell ↔ LED-number conversion; it never
changes which chain position a cell displays.

### `signals` — symbolic chain groups

An optional table mapping symbol names to definitions. A definition is
a list of reference tokens: chain numbers, ranges, earlier symbols, and
subsets of earlier symbols. A symbol's **length** is the total number
of chain positions its expansion occupies, repeats included.

```yaml
signals:
  ADDR:   ["8..23"]                   # A15..A0: element 0 is chain 8
  DATA:   ["24..31"]                  # D7..D0
  LATCH:  ["0..7"]                    # port $FF latch, bit 7 first
  FLAGS:  [280, 281, 282, 283]       # WR RD MREQ IORQ (stretched)
  STATUS: ["LATCH[7..4]", FLAGS]      # subset of an earlier symbol + more
```

Rules:

* **Names**: `[A-Za-z_][A-Za-z0-9_]*`, case-sensitive.
* **Order**: definitions may reference only *earlier* symbols — no
  forward references, hence no cycles.
* **Repeats**: any chain position may appear more than once, anywhere.
  Repeats are a supported feature, silent and warning-free.

#### Ranges

Canonical syntax `a..b`, **inclusive**, first endpoint emitted first —
direction is written, not assumed:

```yaml
ADDR:   ["16..23", "34..30", 37, 39, 44]   # "34..30" emits 34,33,32,31,30
```

* Either endpoint may be larger; there is no "MSB must be left" rule.
* Ranges parse unquoted (`16..23` is a string in any YAML parser), but
  quote them for consistency.
* Quoted aliases `"a:b"` and `"a-b"` are also accepted. **Quote them**:
  unquoted `16:23` is a YAML 1.1 *sexagesimal* integer and PyYAML reads
  it as **983**. When an out-of-range integer could plausibly have been
  a colon range, the error says so:

      error: signals.ADDR[2]: chain position 983 is not in 0..383
        note: 983 is how YAML reads an unquoted 16:23 -- did you mean "16..23"?

#### Subsets

`NAME[..]` selects part of a symbol. The indices are **positional** —
they index the elements of the symbol's expansion list in order
(0..length-1), *not* chain positions:

* `NAME[n]` — one element; `NAME[a..b]` — elements a, a+1, … stepping
  toward b, written order first.
* `NAME` alone is the whole vector.
* For `LATCH: ["0..7"]`, `LATCH[7..4]` emits chain 7, 6, 5, 4.
* In flow-style (`[...]`) lists the `[` `]` tokens **must be quoted**
  (YAML reserves them there); in block lists they may appear bare.

### Colours

A colour may be:

* a string `"#RRGGBB"` or `"RRGGBB"` (hex, either case),
* an array `[r, g, b]` of three integers 0..255,
* a **colour name**: the ~148 built-in CSS/HTML names (`red`,
  `midnightblue`, …), extended and overridable by an optional top-level
  `colors` table:

```yaml
colors:
  heartbeat: "#FF2800"
  amber: "#FFBF00"        # (amber is not a CSS keyword -- define it once)
```

A user entry that collides with a built-in overrides it. Colour names
are recognised only in colour positions, so a signal symbol and a
colour may share a name without ambiguity. There is no colour
arithmetic — literals, names, and table references only; every colour
resolves to a concrete RGB triple at emit time.

**Precedence** (each of ON and OFF resolves independently):

> **element > run > profile signal colour > global signal colour >
> profile > `defaults` > built-in**

Built-in defaults match the hardware's power-on values: ON `#FF0001`,
OFF `#000009`. For a cell no run claims (automatic blank), element and
run levels do not exist in its context, so resolution starts at the
profile level — and signal-colour levels never apply to blanks (§
Blanks). A specific signal colour anywhere beats any profile/default
theme: that is the point of naming colours after signals.

### `defaults`

```yaml
defaults:
  on:  "#FF0001"         # same as the built-in
  off: "#000009"
```

Fallback colours for everything below the top level.

### `signal_colors`

Colours that travel with a **signal** rather than with an LED position:

```yaml
signal_colors:
  PC:   {on: cyan}                 # either field optional
  SP:   {on: magenta, off: "#002020"}
  DATA: red                        # bare colour = ON only
```

The table maps **reference tokens** — chain numbers, `"a..b"` ranges,
symbol names, subsets (`"PC[7..0]"`) — to a colour pair. It expands to
a per-chain-bit table at build time; within one table, a later entry
overrides an earlier one **per bit and per field** (same composition
rule as `signals` references). Keys that name unknown symbols or reach
outside `0..chain_bits-1` are errors; `-` is not a signal and is not a
legal key.

Effect: every **claimed, non-blank** cell whose chain position is in
the table takes the signal's colour, unless an element- or run-level
colour overrides it (see Precedence). The same signal looks the same on
every LED of every **defined** profile that displays it — and survives
profiles that re-theme their default colours, because signal colours sit
above the profile level. Profiles 3..7 in the worked example below show
this: it names `PC` cyan globally and profile 1 recolors only PC's dark
half.

Per-profile override: `profile.N` may carry its own `signal_colors`
table, merged field-wise over the global one for that profile only —
`{off: …}` there replaces just the OFF field of a globally-coloured
signal.

Two limits follow from the hardware being per-LED storage that the tool
bakes at build time:

* Profiles the config does not define emit built-in colours — signal
  colours apply only to defined profiles.
* A Z-80 rewriting the map RAM (`+5`) at runtime does **not** re-associate
  colours; colours reach an LED through the map that was baked for it.

### `profile.N` and runs

`profile.N` (N = 0..7) defines one profile; any subset of the 8 may be
given. A profile not mentioned emits as the **default profile**:
identity map (LED/cell *n* shows chain *n*) with built-in colours.

A profile may set `on`/`off` (defaults for all its runs), `dir`
(default direction for its runs), and `signal_colors` (per-profile
overlay of the global signal-colour table), and carries a `runs` list.
Each run:

| Key | Type | Meaning |
|-----|------|---------|
| `start` | `[row, col]` | First cell of the run, top-left origin. |
| `dir` | `right` \| `left` \| `up` \| `down`, optional | Cell advance: fixed row, col ±1; or fixed col, row −1 (up) / +1 (down). Omitted → profile `dir` → top-level `dir` → `right`. |
| `on` / `off` | colour, optional | Colours for this run's signal cells. |
| `signals` | list of elements | References consumed as the run advances, in order. |

(Yes: `signals` is a *table* at top level — definitions — and a *list*
inside a run — references. Context disambiguates.)

An **element** is either

* a bare reference token (chain number, `"a..b"` string, symbol name,
  subset, or `-`), which inherits the run's colours, or
* a map `{sig: <token>, on: <colour>, off: <colour>}` — either colour
  key optional individually; unspecified keys inherit from the run.

```yaml
signals:
  - ADDR                                      # inherits run colours
  - "DATA[3..0]"                              # inherits
  - {sig: "DATA[7..4]", on: red, off: black}  # this group, other colours
  - "-"                                       # blank cell
  - {sig: "-", off: "#101010"}                # blank, custom darkness
```

A colour on a map element applies to every cell that element's vector
occupies; to colour part of a vector differently, split it into two
subset elements. Giving `on` to a `-` element is an error — a blank is
static by definition; `off` is its darkness.

### Placement semantics

For each profile the grid starts fully unclaimed; runs are applied in
list order:

1. **Span** — the cells from `start` to the panel edge in `dir`,
   inclusive: the run's capacity.
2. **Expansion** — the `signals` list expands left to right into
   individual cell assignments; each token contributes its chain
   positions in order (`-` contributes one blank).
3. **Capacity** — more cells than capacity is an error naming the run
   index, the capacity, and the number needed. No wrapping.
4. **Claim** — the run claims **exactly the cells its expanded data
   covers**, never the bare edge beyond them. A cell already claimed by
   an earlier run is an **overlap error** naming both runs and the
   shared cells. Because claims are data-sized, runs *pack*: a run may
   start immediately after the last data cell of the run before it,
   mid-line.
5. **Assignment** — each claimed cell takes its chain position (or
   blank) from its element.

Cells no run claims are still filled: they become automatic blanks with
default OFF colours. Every profile describes all `leds` cells, always.

### Blanks

A blank cell emits map = chain position 0 with **both** ON and OFF
colours set to the resolved darkness — so the cell shows a static
colour no matter what chain bit 0 does. Darkness resolves along the
normal chain restricted to OFF values: element `off` > run `off` >
signal `off` > profile `off` > `defaults.off` > built-in, and is baked
into the binary as a literal triple. (Signal colours never apply to
blanks: a blank shows no signal.)

## Command line

```
python3 fpprofile.py config.yaml -o profiles.fpp
python3 fpprofile.py --dump profiles.fpp
python3 fpprofile.py -o all-defaults.fpp          # no config: 8 identity profiles
```

| Argument | Meaning |
|----------|---------|
| `config` | YAML configuration file. Omit (with `-o`) to emit an all-defaults file. |
| `-o FILE`, `--output FILE` | Binary profile file to write (required when building). |
| `--chain-bits N` | Override `chain_bits` for this run (1..1024). The effective `chain_bits`/`leds` are echoed to stdout after a build. |
| `--strict` | Warnings become errors; nothing is written. |
| `--dump FILE` | Human-readable summary of an existing file (version 2; version 1 decodable for archaeology). Any ranges shown use canonical `..` form. There is no YAML export. |

Exit status is zero only on success, so the tool drops into scripts and
makefiles directly. Output bytes are deterministic: the same input
always produces identical files.

## Errors and warnings

Unknown keys, bad types, and out-of-range values are always errors,
reported with the key path and source line. The full catalogue:

* `chain_bits` outside 1..1024; `leds` < 1; `rows * cols != leds`.
* Chain position or range endpoint outside `0..chain_bits-1` (with the
  sexagesimal hint where applicable).
* Symbol name pattern violation; forward reference; subset index
  outside the symbol's length.
* `start` outside the grid; bad `dir` at any level.
* Profile number outside 0..7; bad `start`/`dir`/`sig` token.
* Colour parse failure; array component outside 0..255; unknown colour
  name.
* Run element count exceeding span capacity.
* **Overlap** — two runs claiming a shared cell; the message names both
  run indices, the shared cells as `[row, col]`, and the element each
  run would have placed there. This is the most common error while
  tuning a panel layout.
* `on` given on a `-` element.
* `signal_colors` key that is not a reference token, names an unknown
  symbol, is `-`, or reaches outside `0..chain_bits-1`; entry that is
  not a colour or an `on`/`off` mapping; unknown key or empty mapping
  in an entry.
* TOML input (see § Migration).

Warnings (errors under `--strict`): a `signals` symbol or `colors`
entry that nothing references; a `signal_colors` entry (global or
profile-level) whose chain position no defined profile displays.
Duplicate chain positions across LEDs are *not* a warning — repeats are
a feature.

Two YAML gotchas the tool defends against:

* **Boolean keys** — YAML 1.1 resolves bare `on`/`off`/`yes`/`no` to
  booleans, which would silently turn every `on:`/`off:` key into
  `True`/`False`. The tool loads through a loader that accepts only
  `true`/`false` as booleans (YAML 1.2 convention), so bare `on:`/`off:`
  keys work as written and need no quoting.
* **Sexagesimal** — unquoted `16:23` reads as the integer 983; use
  `"16..23"` (see Ranges).

## Output format

Version 2, byte-identical to what the hardware loads —
`16 + 8 × leds × 8` bytes (16400 at `leds: 256`):

| Offset | Size | Content |
|--------|------|---------|
| 0 | 4 | Magic `FPPF` |
| 4 | 1 | Version, `02` |
| 5 | 1 | Number of profiles, `08` |
| 6 | 2 | LEDs per profile, little endian (`leds`) |
| 8 | 8 | Reserved; zero |
| 16 | 8 × leds × 8 | Profile 0 LED 0..leds-1, then profiles 1..7. Each record: `map low, map high, onR, onG, onB, offR, offG, offB` (map 16-bit little endian). |

Normative description with the load procedure: `../README.md`
§ *Profile file format*.

## Testing the tool

```
cd Components/FRONTPANEL/tools
python3 -m unittest -v test_fpprofile
```

The suite covers ranges both directions, subsets and written-order
emission, alias/sexagesimal handling, capacity and overlap diagnostics,
blank baking, colour precedence at every level, geometry validation,
TOML sniffing, unknown-key rejection, and the boolean-key trap.

## Migration from TOML

TOML input is **retired**; old `.toml` configs are not converted and a
TOML-looking input is rejected with an explanatory error rather than a
confusing YAML parse failure. Superseded concepts: multiple named
layouts (now one global `layout`), per-profile `matrix`/`chain_*`/
`strip_*` walks (now `layout` + run `start`/`dir`), parallel `led:`
colour overrides (now run/element colours), and `--force` (short vectors
auto-blank, long vectors error — nothing to force).

## Appendix — worked example

An 8 × 32 development panel on the shipped 384-bit chain:

```yaml
chain_bits: 384          # match the FPGA build
leds: 256

layout:
  rows: 8
  cols: 32
  origin: top-left
  major: column          # string runs down columns...
  serpentine: true       # ...zig-zagging into each next column

signals:
  LATCH: ["0..7"]                          # $FF latch, bit 7 first
  ADDR:  ["8..23"]                         # A15..A0
  DATA:  ["24..31"]                        # D7..D0
  REG_AF:  ["32..47"]                      # A then F
  REG_AP:  ["48..63"]                      # A' then F'
  REG_BC:  ["64..79"]
  REG_BCP: ["80..95"]
  REG_DE:  ["96..111"]
  REG_DEP: ["112..127"]
  REG_HL:  ["128..143"]
  REG_HLP: ["144..159"]
  IX: ["160..175"]
  IY: ["176..191"]
  PC: ["192..207"]
  SP: ["208..223"]
  STROBES: ["280..283"]                   # WR RD MREQ IORQ (stretched)
  PTRS: [IX, IY]                           # composed of earlier symbols

colors:
  heartbeat: "#FF2800"
  amber: "#FFBF00"

defaults:
  on:  "#FF0001"
  off: "#000009"

signal_colors:
  PC: {on: cyan}                     # every defined profile shows PC cyan…
  SP: {on: magenta}                  # …unless placement overrides

profile.0:               # one-frame overview of bus + registers
  runs:
    - start: [0, 0]
      signals: [LATCH, ADDR, DATA]         # 8+16+8 = exactly one row
    - start: [1, 0]
      signals: [REG_AF, REG_AP]            # AF pair plus its shadow
    - start: [2, 0]
      signals: [REG_BC, REG_BCP]           # BC/BC' span exactly one row
    - start: [3, 0]
      signals: [REG_DE, REG_DEP]
    - start: [4, 0]
      signals: [REG_HL, REG_HLP]
    - start: [5, 0]
      signals: [IX, IY]
    - start: [6, 0]
      on: amber                            # pointers highlighted
      signals: [PC, SP]
    - start: [7, 0]
      signals:
        - STROBES
        - {sig: LATCH, on: teal}           # second latch copy, recoloured

profile.1:               # pointers + recoloured low address
  on: "#00FF40"
  signal_colors:
    PC: {off: "#003040"}            # PC's dark half only; global cyan ON stays
  runs:
    - start: [0, 0]
      signals: [PTRS]                      # IX then IY, 32 cells
    - start: [1, 0]
      signals: [PC, SP]
    - start: [3, 0]
      signals:                             # per-element colours
        - {sig: "ADDR[7..0]", on: red, off: black}
        - "-"
        - {sig: DATA, on: heartbeat}
        - LATCH                            # run claims 25 cells...
    - start: [3, 25]                       # ...and this one packs right in
      on: skyblue
      signals: [STROBES]

profile.2:               # vertical feed-corner column, upward
  dir: up
  runs:
    - start: [7, 0]
      on: red
      signals: ["ADDR[7..0]"]              # one full column of A7..A0
```

Profiles 3..7 are not mentioned and emit as the identity profile.
Build it, dump it, load it from the OSD, and LED-number 0..255 on
profile 0's row 0 shows `$FF` latch, then A15..A0, then D7..D0, exactly
as wired. Note the precedence at work: profile 0's amber run still beats
the global `PC: cyan`, but profile 0's SP cells and all of profile 1's
PC/SP take the signal colours — and profile 1's PC is cyan-on over a
`#003040` dark.
