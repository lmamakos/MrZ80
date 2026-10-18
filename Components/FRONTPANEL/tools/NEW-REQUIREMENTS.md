# Requirements: rework of `fpprofile.py`

> **Status: decisions resolved; implementation pending.** This document
> supersedes the original draft requirements and the "open questions"
> section that followed them. Every question raised there has been
> answered; the answers are folded into the body below. Where the
> original draft described a superseded model (named layouts, a
> matrix-in-profile mapping, TOML input, `led:` overrides, `--force`),
> the superseded terms appear only in "What changed" at the end.

## Background

For background information, see `../README.md` about the front panel
system in general, and the VHDL that implements it in that directory.
Additional information is in `../../HARDWARE.md`, which describes the
external interface.

The FPGA side of this rework is **already implemented**:
`FrontPanel_Subsystem` supports a capture chain longer than the LED
string (generic `CHAIN_BITS`, 1..1024, default 256), per-LED map
entries wider than 8 bits, and the version 2 profile file format with
16-bit map entries. This document is about the tool only.

`fpprofile.py` moves from TOML to **YAML** input and adopts the
signal-vector / run-placement model described below.

## Scope

1. Replace TOML input with YAML (PyYAML). Drop TOML completely.
2. Model the capture chain as a one-dimensional vector of chain
   positions, referenced symbolically in the configuration.
3. Describe the physical panel once, globally, as a single wiring
   `layout`.
4. Build each profile from an ordered list of **runs**: a start cell,
   a direction, and a list of signal references, with colours attached
   to the run and its elements.
5. Keep emitting the existing binary profile file (version 2), so the
   hardware and OSD loader need no changes.

## Terminology

| Term | Meaning |
|------|---------|
| **chain** | The capture chain: a vector of signal bits clocked out by the capture chains. |
| **chain position** | Zero-based index into the chain. Position 0 is the first bit shifted out (unchanged from the hardware documentation). |
| **chain_bits** | The chain length the tool validates against (1..1024). The FPGA's actual length is fixed at synthesis by the `CHAIN_BITS` generic; the tool value must be kept consistent with the build by the user. |
| **LED** | One of the `leds` (default 256) physical LEDs, numbered 0..leds-1 in strip order (the order the data wire visits them). |
| **panel / cell** | The LEDs arranged as a `rows` x `cols` grid. A cell is addressed `[row, col]`, zero-based, origin at the **top-left**. |
| **layout** | The single global description of the panel: grid size and wiring order. |
| **wiring walk** | The traversal of all cells defined by the layout. The cell visited at step *n* holds physical LED *n*. |
| **run** | A profile placement: a start cell, a direction, and an ordered list of elements. |
| **span** | The cells of a run's line: from the start cell to the panel edge, inclusive, in the run's direction. The span size is the run's **capacity**; the run *claims* only the first *N* span cells, where *N* is its expanded element count. |
| **element** | One item of a run's `signals` list: a bare reference token, or a map with a token and optional colours. |
| **reference token** | A chain position, a range, a symbol name, a subset `NAME[..]`, or the blank marker `-`. |
| **symbol** | A named group of chain positions defined in the `signals` table. |
| **blank** | A cell showing no signal: mapped to chain position 0 with a static colour (see Blanks). |
| **profile** | One of the 8 profiles (0..7) held by the hardware. |

Prose in this document uses the spelling "colour"; configuration keys
use US spelling (`colors:`).

## Configuration file format

Input is YAML, parsed with PyYAML `safe_load`. Unknown keys are
errors. A complete annotated example is in "Example configuration"
near the end.

### Top-level parameters

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `chain_bits` | integer | 256 | Chain length for validation, 1..1024. Overridden by `--chain-bits` (see CLI). |
| `leds` | integer | 256 | Physical LED count, mirroring the FPGA `NUM_LEDS` generic. Validated against the layout. |
| `dir` | `right` \| `left` \| `up` \| `down` | `right` | Default run direction for every profile that does not set its own. |

Both parameters exist so a future hardware build with different
generics needs only a changed declaration; a configuration whose
geometry does not match its declared `leds` fails loudly rather than
silently emitting a wrong map.

### Colours

A colour value may be written as:

- a string `"#RRGGBB"` or `"RRGGBB"` (hex, either case),
- an array `[r, g, b]` of three integers 0..255,
- a **colour name**.

Colour names are the standard CSS/HTML colour names (about 148:
`red`, `amber`, `midnightblue`, ...), built in, extended and
overridden by an optional top-level `colors` table:

```yaml
colors:
  heartbeat: "#FF2800"
  dimwhite:  [24, 24, 24]
```

A user name that collides with a built-in name overrides it. Colour
names are recognised only in colour positions, never in signal
positions, so a symbol and a colour may share a name without
ambiguity. There is no colour arithmetic; literals, names, and table
references only. All colours are resolved to concrete RGB triples at
emit time.

### Signals (symbolic definitions)

The optional top-level `signals` table maps symbol names to
definitions. A definition is a list of **reference tokens**: chain
position integers, ranges, individual numbers, earlier symbols, and
subsets of earlier symbols. A symbol has a **length**: the total
number of chain positions its expansion occupies, repeats included.

```yaml
signals:
  ADDR:   ["8..23"]                   # A15..A0: chain 8 holds A15
  DATA:   ["24..31"]                  # D7..D0
  LATCH:  ["0..7"]                    # port $FF latch, bit 7 first
  FLAGS:  [25, 26, 27]
  STATUS: ["LATCH[7..4]", FLAGS]      # symbol + subset of an earlier symbol
```

Subset tokens contain `[` and `]`, which YAML reserves inside
flow-style (`[...]`) lists, so they **must be quoted** there; in
block-style lists they may appear bare, but examples and docs always
quote them.

Rules:

- **Names**: `[A-Za-z_][A-Za-z0-9_]*`, case-sensitive. Anything else
  (empty, a bare number) is an error.
- **Order**: a definition may reference only symbols defined earlier
  in the file. Forward references are errors. Cycles are therefore
  impossible.
- **Repeats**: a chain position may appear more than once, in a
  definition or across a run's references. This is a supported
  feature, not a warning.

#### Ranges

Canonical range syntax is `a..b` (inclusive):

```yaml
ADDR:   ["16..23", "34..30", 37, 39, 44]
```

- The first endpoint is the **first emitted** element; the second is
  the last. Direction is written, not assumed: `34..30` emits
  34, 33, 32, 31, 30.
- Either endpoint may be the larger; there is no "MSB must be left"
  rule.
- A range may be written unquoted (`16..23` parses as a string in
  every YAML parser). Examples quote all tokens for consistency.
- **Aliases**: the quoted forms `"a:b"` and `"a-b"` are also
  accepted and normalised internally. They must be quoted: unquoted
  `16:23` is a YAML 1.1 sexagesimal integer and PyYAML reads it as
  **983**. When validation rejects an integer that could have been a
  colon range (any `n` where `divmod(n, 60)` yields a plausible
  `hi:lo`), the error must say so and offer the canonical form:

      error: signals.ADDR[2]: chain position 983 is not in 0..255
        note: 983 is how YAML reads an unquoted 16:23 -- did you mean "16..23"?

#### Subsets

`NAME[..]` selects part of a symbol. The indices are **positional**:
they index the elements of the symbol's expansion list, in order,
0..length-1. They are *not* chain positions.

- `NAME[n]` selects one element; `NAME[a..b]` selects elements
  `a, a+1, ...` stepping toward `b`, written order first.
- `NAME` alone is the whole vector.
- Subsets may be referenced inside later definitions and inside
  runs.

For `LATCH: ["0..7"]` (element 0 is chain 0, element 7 is chain 7),
`LATCH[7..4]` emits chain positions 7, 6, 5, 4 in that order.

### Layout (single, global)

There is exactly **one** layout for the whole configuration. It
describes the physical panel and how the LEDs are wired; it applies to
every profile, and profiles do not name or override layouts.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `rows` | integer >= 1 | required | Grid rows. |
| `cols` | integer >= 1 | required | Grid columns. |
| `origin` | corner | `top-left` | Where the wiring walk starts: `top-left`, `top-right`, `bottom-left`, `bottom-right`. |
| `major` | `row` \| `column` | `row` | Direction the walk runs within a line before stepping to the next. |
| `serpentine` | bool | `false` | If true, every second line reverses direction. |

`rows * cols` must equal `leds`; anything else is an error naming
both numbers. The wiring walk assigns: cell visited at step *n*
contains physical LED *n*. The wiring walk parameters affect only the
conversion between cells and physical LED numbers; they never affect
which chain position a cell displays.

### Defaults

The optional top-level `defaults` table gives fallback colours for
everything below it:

| Key | Colour | Built-in default |
|-----|--------|------------------|
| `on`  | chain bit 1 | `#FF0001` |
| `off` | chain bit 0 | `#000009` |

These match the hardware's built-in power-on defaults, and are
repeatable in the same `#RGB`/array/name syntax as any colour.

### Profiles and runs

`profile.N` (N in 0..7; any other number is an error) defines one
profile. Any subset of the 8 profiles may be given; a profile that is
not mentioned emits as the **default profile**: identity map (cell/LED
*n* shows chain position *n*; where *n* >= `chain_bits` the hardware
shows the LED's OFF colour) with the built-in colours. Profile 0 is
therefore unchanged from the pre-profile hardware baseline when no
configuration names it.

A profile may carry `on`/`off` colours (its own defaults for all its
runs) and a `dir` (default run direction for its runs), and requires a
`runs` list to deviate from the identity map.

Each entry of `runs` is a placement:

| Key | Type | Meaning |
|-----|------|---------|
| `start` | `[row, col]` | First cell of the run, top-left origin, within the grid. |
| `dir` | `right` \| `left` \| `up` \| `down`, optional | Cell-advance direction: fixed row with col +1/-1, or fixed col with row -1/+1. Omitted runs inherit the profile's `dir`, then the top-level `dir`, then `right`. |
| `on` | colour, optional | Colour for this run's signal cells when their chain bit is 1. |
| `off` | colour, optional | Colour for this run's signal cells when their chain bit is 0. |
| `signals` | list of elements | References consumed as the run advances, in order. |

Note: `signals` is a table at top level (symbol definitions) and a
list inside a run (references). Context disambiguates; documentation
always shows both.

An **element** is either

- a bare reference token (chain number, range string, symbol name,
  subset, or `-`), which inherits the run's colours, or
- a map `{sig: <token>, on: <colour>, off: <colour>}`, where each
  colour key is individually optional and unkeyed colours inherit
  from the run:

```yaml
signals:
  - ADDR                                    # inherits run colours
  - DATA[3..0]                              # inherits
  - {sig: "DATA[7..4]", on: red, off: black}  # this group, other colours
  - "-"                                     # blank cell, inherited darkness
  - {sig: "-", off: "#101010"}              # blank, custom darkness
```

A colour on a map element applies to every cell that element's vector
occupies. To colour part of a vector differently, split it into two
subset elements, as above. Giving `on` to a `-` element is an error:
a blank is static by definition (see Blanks); `off` is the darkness.

### Placement algorithm

For each profile, the grid starts fully unclaimed. Runs are applied
in list order:

1. **Span.** The run's span is every cell from `start` to the panel
   edge in `dir`, inclusive. Its size is the run's capacity.
2. **Expansion.** The `signals` list is expanded left to right into
   individual cell assignments: each reference token contributes its
   chain positions in order (a `-` contributes one blank cell).
3. **Capacity.** More cell assignments than capacity is an error
   naming the run index, the capacity, and the number needed.
4. **Claim.** The run claims **exactly the cells its expanded list
   covers** -- never the bare edge beyond them. Any claimed cell of an
   earlier run hit again is an **overlap error** (see Errors). Runs
   pack freely: a run may start immediately after the last data cell
   of the run before it, even mid-line.
5. **Assignment.** Expanded cells take their chain positions from
   their element. A cell whose element is `-` renders as a blank
   inheriting that run's colours.

Cells left unclaimed by every run also render as blanks -- the rest of
the grid always fills with the default OFF values -- with colours
resolved without run context (profile, then `defaults`, then
built-ins).

### Blanks

A blank cell emits:

- **map** = chain position 0 (every chain has at least one bit), and
- **ON and OFF colours both set** to the blank's resolved OFF colour.

Because ON equals OFF, the cell displays a static colour and is
visually independent of the state of chain position 0 — blank is
robust against whatever the hardware actually clocks in. The
resolution chain for a blank's colour is the normal precedence chain
restricted to OFF values: element `off` > run `off` > profile `off` >
`defaults.off` > built-in. The result is baked into the binary as a
literal triple.

### Colour precedence

For a claimed signal cell, each of ON and OFF resolves
independently:

**element > run > profile > `defaults` > built-in**

For an unclaimed blank cell, element and run do not exist in the
context, so resolution starts at the profile level.

## Validation and errors

Unknown keys, bad types, and out-of-range values are always errors.
Errors must report the configuration key path and, when PyYAML
provides it, the file line. The complete error list:

- `chain_bits` outside 1..1024; `leds` < 1; `rows * cols != leds`.
- Chain position or range endpoint outside `0..chain_bits-1`
  (with the sexagesimal hint where applicable).
- Symbol name not matching the name pattern; forward reference;
  subset index outside the symbol's length.
- `start` cell outside the grid; bad `dir` (at run, profile or top
  level).
- Profile number outside 0..7; bad `start`/`dir`/`sig` token.
- Colour parse failure; array component outside 0..255; unknown
  colour name.
- Run element count exceeding span capacity.
- **Overlap**: two runs whose spans share a cell. The diagnostic must
  name both run indices, the shared cell(s) as `[row, col]`, and the
  element each run would have placed there — this will be the most
  common error users hit while adjusting a panel, and its quality is
  a stated goal of this rework.
- `on` given on a `-` element.
- TOML input (see Migration).

Warnings (errors under `--strict`): a defined symbol or `colors`
entry that no profile references. Duplicate chain positions across
LEDs are **not** a warning; repeats are a supported feature.

## Binary output format (unchanged)

The tool emits version 2, byte-identical to what the current hardware
accepts — exactly `16 + 8 x leds x 8` bytes (16400 at `leds: 256`):

| Offset | Size | Content |
|--------|------|---------|
| 0 | 4 | Magic `FPPF` |
| 4 | 1 | Version, `02` |
| 5 | 1 | Number of profiles, `08` |
| 6 | 2 | LEDs per profile, little endian (`leds`) |
| 8 | 8 | Reserved; zero |
| 16 | 8 x leds x 8 | Profile 0 LED 0..leds-1, then profile 1, ... Each record: `map low, map high, onR, onG, onB, offR, offG, offB` (map 16-bit little endian). |

All cells are covered: every profile describes all `leds` cells
(signals and blanks), so the output never leaves a record unset.
Output is deterministic: the same input always produces identical
bytes.

## Command line

```
python3 fpprofile.py config.yaml -o profiles.fpp
python3 fpprofile.py --dump profiles.fpp
```

| Argument | Meaning |
|----------|---------|
| `config` | YAML configuration file. Omitting it (with `-o`) emits an all-defaults file: 8 identity profiles. |
| `-o FILE`, `--output FILE` | Binary profile file to write (required when building). |
| `--chain-bits N` | Override `chain_bits` for this run (1..1024). The effective `chain_bits` and `leds` values are echoed to stdout after a build. |
| `--strict` | Warnings become errors (nothing written). |
| `--dump FILE` | Decode and summarise an existing profile file (human-readable summary only; decodes version 2, and version 1 for archaeology). Any ranges shown use canonical `..` form. |

Retired: `--force` (its pad/truncate job is gone: short vectors
auto-blank, long vectors error, geometry mismatches error).
Not offered: YAML export (`--to-yaml`) — `--dump` is a summary only.

## Implementation notes

- **PyYAML** is a new dependency. It is installed in the current
  dev environment as the Debian package `python3-yaml` (6.0.3), but
  must not be assumed present elsewhere: an `import yaml` failure
  must produce a clear error with an install hint (apt
  `python3-yaml`, or `pip install pyyaml`). Use `safe_load` only: no
  tags, anchors, or multi-document files.
- **Boolean-key trap**: PyYAML implements YAML 1.1, in which the
  bare words `on`, `off`, `yes`, and `no` resolve to booleans. Left
  alone, every `on:`/`off:` mapping key in this schema becomes the
  key `True`/`False` (verified: PyYAML reads
  `{sig: X, on: red, off: black}` as boolean keys). The tool must
  load through a `SafeLoader` subclass whose resolver treats only
  `true`/`false` as booleans (the YAML 1.2 convention). The examples
  in this document are written for, and must parse unmodified under,
  that loader.
- Python >= 3.9 (the TOML version needed 3.11 for stdlib `tomllib`).
- Tab-indented YAML is an error (YAML forbids it); examples and docs
  use two-space indentation.
- Unit tests: `cd Components/FRONTPANEL/tools && python3 -m unittest
  -v test_fpprofile` (module name unchanged).

## Migration from TOML

- TOML support is dropped completely; there is **no conversion** of
  the old `.toml` configuration files.
- A configuration file ending in `.toml`, or whose content looks like
  TOML (a top-level `key = value` line or a `[dotted.table]` header
  that is not a YAML mapping), is rejected with an error explaining
  that TOML input was retired with this rework, rather than being
  fed to PyYAML and failing with a confusing diagnostic.
- `profiles.toml` and `example_profiles.toml` are deleted from
  `tools/` (git preserves them). A new annotated `example_profiles.yaml`
  is written from scratch, using the current chain assignment from
  `../README.md` (latch, address, data, register bits).
- Update, in the same change: the `fpprofile.py` module docstring,
  the tool section of `../README.md`, `HISTORY.md`, and any
  `FEATURE.md` cross-references.

## Tests and definition of done

1. `test_fpprofile.py` rewritten for this schema, covering at least:
   ranges in both directions, singletons, repeats, alias forms and
   the sexagesimal hint; subset indexing and written-order emission;
   forward-reference rejection; span capacity errors; overlap error
   message content; blank emission (map 0, ON==OFF baked); colour
   precedence at every level; `rows*cols` validation; TOML sniffing;
   unknown-key rejection; the boolean-key trap (bare `on:`/`off:`
   keys stay strings).
2. `profiles.fpp` regenerated from `example_profiles.yaml`; re-running
   the build reproduces byte-identical output.
3. The GHDL simulation still passes: `sim/run_frontpanel.sh` (the
   front-panel testbench decodes the WS2812 stream and checks every
   LED).
4. Documentation updated as listed under Migration.

## What changed relative to the original draft

| Original | Now |
|----------|-----|
| TOML input | YAML (PyYAML); TOML rejected with a helpful error |
| Multiple named layouts, chosen per profile | One global `layout`; profiles never name it |
| Per-profile `matrix` geometry + `chain_*`/`strip_*` walks | Layout owns wiring (`origin`/`major`/`serpentine`); placement moved into runs (start cell + `dir`) |
| Profile signal vector bound to a panel-wide walk | Runs claim straight lines (span) only; no wrap |
| Parallel `led:` colour overrides by LED/cell | Colours attach to runs and elements; `led:` retired entirely |
| Implicit colour duplication everywhere | Named colours: CSS built-ins + `colors:` table |
| Chain fixed at 256, 1-byte maps assumed | `chain_bits`/`leds` parameters; 16-bit maps (v2), already in hardware |
| Geometry mismatch: warn or `--force` | Always an error; `--force` retired |
| "256 LEDs must be specified" | Grid size must equal `leds` (default 256); runs claim only their data and the unclaimed grid fills with blanks |

## Example configuration

```yaml
# example_profiles.yaml -- see NEW-REQUIREMENTS.md for semantics.
# chain_bits: 256 (default), leds: 256 (default); pass --chain-bits to override.

colors:
  heartbeat: "#FF2800"
  amber: "#FFBF00"        # (amber is not a built-in CSS name)

signals:
  ADDR:   ["8..23"]                   # Z80 address bus, A15 first
  DATA:   ["24..31"]                  # Z80 data bus, D7 first
  LATCH:  ["0..7"]                    # port $FF latch, bit 7 first
  FLAGS:  [25, 26, 27]
  STATUS: ["LATCH[7..4]", FLAGS]

layout:
  rows: 16
  cols: 16
  origin: bottom-left                 # wiring walk starts at the feed corner
  major: row
  serpentine: true

defaults:
  on:  "#FF0001"
  off: "#000009"

profile.0:
  runs:
    - start: [0, 0]
      dir: right
      signals: [LATCH, LATCH]                 # 16 cells: latch twice
    - start: [1, 0]
      dir: right
      signals: [ADDR]                          # exactly one row of address
    - start: [2, 0]
      dir: right
      signals: [DATA]                 # 8 cells; the rest of the row stays free
    - start: [2, 8]                   # packs in right behind it: runs claim
      dir: right                      # exactly their data, not the edge
      signals: [LATCH]
      on: heartbeat
    - start: [3, 0]
      dir: right
      signals: [DATA, {sig: "ADDR[7..0]", on: red, off: black}]

profile.1:
  on:  "#00FF40"
  runs:
    - start: [0, 0]
      dir: right
      signals:
        - ADDR
        - {sig: "DATA[7..0]", on: heartbeat, off: black}
    - start: [5, 4]                            # second run: a column, no span
      dir: down                                # overlap with the row-0 run
      on: amber
      signals: [STATUS]

profile.2:
  runs:
    - start: [15, 15]
      dir: up
      signals: [ADDR]                          # one full column, upward
```
