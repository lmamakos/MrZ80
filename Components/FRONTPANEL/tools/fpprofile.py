#!/usr/bin/env python3
"""fpprofile.py - build (or inspect) a MrZ80 front-panel profile file.

The output file is loaded from the MiSTer OSD ("Front Panel Profiles",
index FC5) and initialises all 8 profiles of FrontPanel_Subsystem.
A profile record gives, for each physical LED: the capture-chain
position it displays (the map) and its ON and OFF RGB colours.

Input is YAML (PyYAML).  The authoritative description of the model
and of every validation rule is tools/NEW-REQUIREMENTS.md; this
docstring is the working reference.

  python3 fpprofile.py example_profiles.yaml -o profiles.fpp
  python3 fpprofile.py --dump profiles.fpp            (inspect a file)

Command line:

  config             YAML configuration (omit with -o for an all-defaults
                     file: 8 identity profiles)
  -o / --output      binary profile file to write (required when building)
  --chain-bits N     override the `chain_bits` key (1..1024)
  --strict           warnings become errors (nothing written)
  --dump FILE        decode and summarise an existing profile file
                     (version 2; legacy version 1 is also readable)

TOML input was retired: a .toml file (or TOML-looking content) is
rejected with a pointer to the YAML rework.

Binary output (version 2, unchanged):

  16-byte header: 'F' 'P' 'P' 'F', version (02), profile count (08),
                  LEDs per profile little endian, 8 reserved zero bytes
  then 8 profiles x leds x 8-byte records:
      map low, map high, onR, onG, onB, offR, offG, offB
  = 16 + 8 * leds * 8 bytes (16400 with the default leds: 256).

Configuration (YAML):

  chain_bits: 256       # optional, 1..1024; validation only (the FPGA's
                        # chain length is fixed at synthesis).  --chain-bits
                        # overrides it for one invocation.
  leds: 256             # optional; mirrors the FPGA NUM_LEDS generic
  dir: right            # optional default run direction (right|left|up|down)

  colors:               # optional; extends/overrides built-in CSS names.
    heartbeat: "#FF2800"   # values: hex, [r,g,b], or a built-in CSS name.
  defaults:             # optional; fallback colours
    on:  "#FF0001"
    off: "#000009"

  signals:              # optional; named groups of chain positions.
    ADDR:   ["8..23"]     #   order matters: references may use only
    DATA:   ["24..31"]    #   EARLIER symbols (forward references are
    FLAGS:  [25, 26, 27]  #   errors).  Repeats are allowed.
    STATUS: ["ADDR[7..0]", FLAGS]

  layout:               # optional (defaults to one row of `leds`);
    rows: 8             #   exactly one layout, global, wiring only.
    cols: 32
    origin: top-left    # top-left|top-right|bottom-left|bottom-right
    major: column       # row|column
    serpentine: true

  profile.0:            # N is 0..7; any subset of the 8 may be given.
                        # An unspecified profile emits as the default
                        # profile: identity map, built-in colours.
    on:  "#00FF40"      # optional profile-level colours (all its runs)
    runs:               # placements, applied in list order
      - start: [0, 0]   # first cell, [row, col] from the top-left
        dir: right      # optional: right|left|up|down (straight line, no
                        # wrap); defaults to the profile's dir, then the
                        # top-level dir, then "right"
        on:  amber      # optional run colours (all its cells)
        signals:        # elements consumed as the run advances:
          - ADDR        #   bare token inherits the run colours; a
          - {sig: DATA, on: red, off: black}   #   map sets them per element
          - "-"         #   blank cell
          - {sig: "-", off: "#101010"}         # blank with custom darkness

A run's SPAN is every cell from `start` to the panel edge in `dir`; its
size is the run's capacity, and an expanded list longer than that is an
error.  A run claims EXACTLY the cells its expanded list covers -- never
the bare edge past them -- so runs pack freely into one line and any two
runs claiming the same data cell is an overlap error.  A cell occupied
by "-" renders as a BLANK: map 0 with ON and OFF both baked to the
blank's resolved OFF colour, so the cell is static regardless of what
chain bit 0 does.  Cells no run claims are blanks too, resolved in
profile context -- the rest of the panel always fills with blanks.

Colour precedence (each of ON and OFF independently):
  element > run > profile > defaults > built-in (#FF0001 / #000009).
Any colour position accepts "#RRGGBB", "RRGGBB", [r, g, b], or a
colour name (built-in CSS/HTML names plus the `colors` table; a
6-character all-hex string is always read as hex, never as a name).

Ranges: canonical `a..b`, inclusive, first endpoint emitted first
(both directions allowed: "34..30" emits 34,33,32,31,30).  Quoted
"a:b" and "a-b" are accepted aliases; UNQUOTED 16:23 is YAML 1.1
sexagesimal and parses as the integer 983 -- rejected out-of-range
integers that look like eaten ranges get a hint.  Subset `NAME[a..b]`
indices are POSITIONS in the symbol's element list, not chain
numbers, and emit in written order.  In flow lists ([...]) subset
tokens must be quoted (YAML reserves brackets there).

Warnings (errors under --strict): an unused `signals` symbol or
unused `colors` entry.  Duplicate chain positions across LEDs are
normal and silent.  Errors report the configuration key path and the
line of the enclosing table or list.  Output is deterministic: the
same input always produces identical bytes.
"""

import argparse
import re
import struct
import sys

try:
    import yaml
except ImportError:
    yaml = None

MAX_CHAIN = 1024          # longest capture chain the hardware supports
DEFAULT_LEDS = 256        # mirrors the FPGA NUM_LEDS generic
NUM_PROFILES = 8
RECORD = 8
MAGIC = b"FPPF"
VERSION = 2
HEADER_SIZE = 16

DEFAULT_ON = (0xFF, 0x00, 0x01)
DEFAULT_OFF = (0x00, 0x00, 0x09)

CORNERS = ("top-left", "top-right", "bottom-left", "bottom-right")
DIRECTIONS = ("right", "left", "up", "down")
BLANK = "-"

NAME_RE = re.compile(r"\A[A-Za-z_][A-Za-z0-9_]*\Z")
HEX_RE = re.compile(r"\A[0-9a-fA-F]{6}\Z")
RANGE_RE = re.compile(r"\A(\d+)\.\.(\d+)\Z|\A(\d+):(\d+)\Z|\A(\d+)-(\d+)\Z")
SUBSET_RE = re.compile(r"\A([A-Za-z_][A-Za-z0-9_]*)\[(.+)\]\Z")

# --------------------------------------------------------------------
# Built-in colour names (CSS/HTML keywords).  Values are re-parsed
# through parse_color's hex path, so a typo fails loudly at import.
# --------------------------------------------------------------------
CSS_NAMES = {
    "aliceblue": "f0f8ff", "antiquewhite": "faebd7", "aqua": "00ffff",
    "aquamarine": "7fffd4", "azure": "f0ffff", "beige": "f5f5dc",
    "bisque": "ffe4c4", "black": "000000", "blanchedalmond": "ffebcd",
    "blue": "0000ff", "blueviolet": "8a2be2", "brown": "a52a2a",
    "burlywood": "deb887", "cadetblue": "5f9ea0", "chartreuse": "7fff00",
    "chocolate": "d2691e", "coral": "ff7f50", "cornflowerblue": "6495ed",
    "cornsilk": "fff8dc", "crimson": "dc143c", "cyan": "00ffff",
    "darkblue": "00008b", "darkcyan": "008b8b", "darkgoldenrod": "b8860b",
    "darkgray": "a9a9a9", "darkgreen": "006400", "darkgrey": "a9a9a9",
    "darkkhaki": "bdb76b", "darkmagenta": "8b008b",
    "darkolivegreen": "556b2f", "darkorange": "ff8c00",
    "darkorchid": "9932cc", "darkred": "8b0000", "darksalmon": "e9967a",
    "darkseagreen": "8fbc8f", "darkslateblue": "483d8b",
    "darkslategray": "2f4f4f", "darkslategrey": "2f4f4f",
    "darkturquoise": "00ced1", "darkviolet": "9400d3",
    "deeppink": "ff1493", "deepskyblue": "00bfff", "dimgray": "696969",
    "dimgrey": "696969", "dodgerblue": "1e90ff", "firebrick": "b22222",
    "floralwhite": "fffaf0", "forestgreen": "228b22", "fuchsia": "ff00ff",
    "gainsboro": "dcdcdc", "ghostwhite": "f8f8ff", "gold": "ffd700",
    "goldenrod": "daa520", "gray": "808080", "green": "008000",
    "greenyellow": "adff2f", "grey": "808080", "honeydew": "f0fff0",
    "hotpink": "ff69b4", "indianred": "cd5c5c", "indigo": "4b0082",
    "ivory": "fffff0", "khaki": "f0e68c", "lavender": "e6e6fa",
    "lavenderblush": "fff0f5", "lawngreen": "7cfc00",
    "lemonchiffon": "fffacd", "lightblue": "add8e6",
    "lightcoral": "f08080", "lightcyan": "e0ffff",
    "lightgoldenrodyellow": "fafad2", "lightgray": "d3d3d3",
    "lightgreen": "90ee90", "lightgrey": "d3d3d3", "lightpink": "ffb6c1",
    "lightsalmon": "ffa07a", "lightseagreen": "20b2aa",
    "lightskyblue": "87cefa", "lightslategray": "778899",
    "lightslategrey": "778899", "lightsteelblue": "b0c4de",
    "lightyellow": "ffffe0", "lime": "00ff00", "limegreen": "32cd32",
    "linen": "faf0e6", "magenta": "ff00ff", "maroon": "800000",
    "mediumaquamarine": "66cdaa", "mediumblue": "0000cd",
    "mediumorchid": "ba55d3", "mediumpurple": "9370db",
    "mediumseagreen": "3cb371", "mediumslateblue": "7b68ee",
    "mediumspringgreen": "00fa9a", "mediumturquoise": "48d1cc",
    "mediumvioletred": "c71585", "midnightblue": "191970",
    "mintcream": "f5fffa", "mistyrose": "ffe4e1", "moccasin": "ffe4b5",
    "navajowhite": "ffdead", "navy": "000080", "oldlace": "fdf5e6",
    "olive": "808000", "olivedrab": "6b8e23", "orange": "ffa500",
    "orangered": "ff4500", "orchid": "da70d6", "palegoldenrod": "eee8aa",
    "palegreen": "98fb98", "paleturquoise": "afeeee",
    "palevioletred": "db7093", "papayawhip": "ffefd5",
    "peachpuff": "ffdab9", "peru": "cd853f", "pink": "ffc0cb",
    "plum": "dda0dd", "powderblue": "b0e0e6", "purple": "800080",
    "rebeccapurple": "663399", "red": "ff0000", "rosybrown": "bc8f8f",
    "royalblue": "4169e1", "saddlebrown": "8b4513", "salmon": "fa8072",
    "sandybrown": "f4a460", "seagreen": "2e8b57", "seashell": "fff5ee",
    "sienna": "a0522d", "silver": "c0c0c0", "skyblue": "87ceeb",
    "slateblue": "6a5acd", "slategray": "708090", "slategrey": "708090",
    "snow": "fffafa", "springgreen": "00ff7f", "steelblue": "4682b4",
    "tan": "d2b48c", "teal": "008080", "thistle": "d8bfd8",
    "tomato": "ff6347", "turquoise": "40e0d0", "violet": "ee82ee",
    "wheat": "f5deb3", "white": "ffffff", "whitesmoke": "f5f5f5",
    "yellow": "ffff00", "yellowgreen": "9acd32",
}


def _hex_to_rgb(s):
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


CSS_COLORS = {name: _hex_to_rgb(h) for name, h in CSS_NAMES.items()}


class ConfigError(Exception):
    pass


# --------------------------------------------------------------------
# YAML loading
#
# Two departures from plain safe_load, both required by the schema:
#   * YAML 1.1 resolves the bare words on/off/yes/no to booleans,
#     which would turn every `on:`/`off:` key in this schema into the
#     key True/False.  The resolver is replaced so only true/false
#     (any canonical capitalisation) are booleans.
#   * Mappings and lists remember the source line of their first
#     token so errors can quote it.
# --------------------------------------------------------------------
class LineDict(dict):
    __slots__ = ("line",)

    def __init__(self, items=(), line=None):
        super().__init__(items)
        self.line = line


class LineList(list):
    __slots__ = ("line",)

    def __init__(self, items=(), line=None):
        super().__init__(items)
        self.line = line


if yaml is not None:
    class Loader(yaml.SafeLoader):
        pass

    Loader.yaml_implicit_resolvers = {
        first: [r for r in resolvers if r[0] != "tag:yaml.org,2002:bool"]
        for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }
    Loader.add_implicit_resolver(
        "tag:yaml.org,2002:bool",
        re.compile(r"\A(?:true|True|TRUE|false|False|FALSE)\Z"),
        list("tTfF"))

    def _construct_mapping(self, node, deep=False):
        return LineDict(yaml.SafeLoader.construct_mapping(self, node, deep),
                        line=node.start_mark.line + 1)

    def _construct_sequence(self, node, deep=False):
        return LineList(yaml.SafeLoader.construct_sequence(self, node, deep),
                        line=node.start_mark.line + 1)

    Loader.construct_mapping = _construct_mapping
    Loader.construct_sequence = _construct_sequence


def where(path, obj):
    """Error-location string: key path plus the object's source line."""
    line = getattr(obj, "line", None)
    return f"{path} (line {line})" if line else path


TOML_TABLE_RE = re.compile(r"\A\[[^\]]+\]\s*\Z")
TOML_ASSIGN_RE = re.compile(r"\A[A-Za-z0-9_.\"-]+\s*=(?!=)")


def looks_like_toml(text):
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if TOML_TABLE_RE.match(line) or TOML_ASSIGN_RE.match(line):
            return True
    return False


def load_config(path):
    if yaml is None:
        raise ConfigError(
            "PyYAML is required: apt install python3-yaml "
            "(or pip install pyyaml)")
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if path.endswith(".toml") or looks_like_toml(text):
        raise ConfigError(
            f"{path}: TOML input was retired with the YAML rework; rewrite "
            f"it as YAML (see NEW-REQUIREMENTS.md and example_profiles.yaml)")
    try:
        doc = yaml.load(text, Loader=Loader)
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        loc = f" (line {mark.line + 1})" if mark else ""
        raise ConfigError(f"{path}: YAML syntax error{loc}: {e}")
    if doc is None:
        doc = LineDict()
    if not isinstance(doc, dict):
        raise ConfigError(f"{path}: top level must be a mapping of keys")
    return doc


# --------------------------------------------------------------------
# Integers, colours
# --------------------------------------------------------------------
def require_int(value, path, lo, hi):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ConfigError(f"{path}: must be an integer, got {value!r}")
    if not lo <= value <= hi:
        raise ConfigError(f"{path}: {value} is not in {lo}..{hi}")
    return value


def sexagesimal_hint(n, hi_limit):
    """Hint for an integer that looks like an unquoted `a:b` YAML ate."""
    if n < 61:
        return ""
    a, b = divmod(n, 60)
    if a > 0 and b < 60 and a <= hi_limit and b <= hi_limit:
        return (f"\n  note: {n} is how YAML reads an unquoted {a}:{b} "
                f"-- did you mean \"{a}..{b}\"?")
    return ""


def parse_color(value, path, palette):
    """'#RRGGBB' / 'RRGGBB' / [r, g, b] / colour name -> (r, g, b)."""
    if isinstance(value, str):
        s = value.strip()
        if s.startswith("#"):
            s = s[1:]
        if HEX_RE.match(s):
            return _hex_to_rgb(s)
        if s in palette:
            return palette[s]
        low = s.lower()
        if low in CSS_COLORS:
            return CSS_COLORS[low]
        raise ConfigError(f"{path}: unknown colour name {value!r}")
    if (isinstance(value, (list, tuple)) and len(value) == 3
            and all(isinstance(v, int) and not isinstance(v, bool)
                    and 0 <= v <= 255 for v in value)):
        return tuple(value)
    raise ConfigError(f"{path}: bad colour {value!r} "
                      f"(want #RRGGBB, [r,g,b] 0..255, or a colour name)")


def build_palette(colors_cfg, path):
    """User `colors` table on top of the built-in CSS names.  Table
    values may be hex, [r,g,b], or a BUILT-IN name (user entries may
    not reference each other -- there is no ordering promise)."""
    palette = dict(CSS_COLORS)
    if colors_cfg is None:
        return palette
    if not isinstance(colors_cfg, dict):
        raise ConfigError(f"{where(path, colors_cfg)}: must be a mapping "
                          f"of name -> colour")
    for k, v in colors_cfg.items():
        p = f"{path}.{k}"
        if not isinstance(k, str) or not NAME_RE.match(k):
            raise ConfigError(f"{where(path, colors_cfg)}: bad colour name "
                              f"{k!r} (want [A-Za-z_][A-Za-z0-9_]*)")
        if isinstance(v, str):
            s = v.strip().lstrip("#")
            if not HEX_RE.match(s) and s not in CSS_COLORS and s.lower() not in CSS_COLORS:
                raise ConfigError(
                    f"{where(path, colors_cfg)}: {p}: colours in the colors "
                    f"table must be #RRGGBB, [r,g,b], or a built-in CSS "
                    f"colour name")
        palette[k] = parse_color(v, p, palette)
    return palette


# --------------------------------------------------------------------
# Reference tokens: numbers, ranges, symbols, subsets, blanks
# --------------------------------------------------------------------
def expand_token(tok, symbols, chain_bits, path, allow_blank, referenced=None):
    """One reference token -> (list of chain positions, label).
    A blank yields (None, label).  `symbols` holds only definitions
    seen so far, so forward references are naturally unknown.  Symbol
    names mentioned by the token are added to `referenced`."""
    if tok == BLANK:
        if allow_blank:
            return None, f"'{BLANK}'"
        raise ConfigError(f"{path}: blank '{BLANK}' is only allowed in "
                          f"profile run signals")
    if isinstance(tok, bool):
        raise ConfigError(f"{path}: bad reference token {tok!r}")
    if isinstance(tok, int):
        if not 0 <= tok < chain_bits:
            raise ConfigError(
                f"{path}: chain position {tok} is not in "
                f"0..{chain_bits - 1}"
                + sexagesimal_hint(tok, chain_bits - 1))
        return [tok], str(tok)
    if not isinstance(tok, str):
        raise ConfigError(f"{path}: bad reference token {tok!r}")
    s = tok.strip()

    m = SUBSET_RE.match(s)
    if m:
        name, inside = m.group(1), m.group(2)
        if name not in symbols:
            raise ConfigError(
                f"{path}: subset '{s}' references "
                f"{name!r}, which is not defined earlier in 'signals'")
        if referenced is not None:
            referenced.add(name)
        items = s[s.index("[") + 1:-1]
        bounds = [p.strip() for p in items.split("..")] \
            if ".." in items else re.split(r"[:\-]", items)
        if len(bounds) == 1:
            bounds = [bounds[0], bounds[0]]
        try:
            a, b = (int(x) for x in bounds)
        except ValueError:
            raise ConfigError(f"{path}: subset indices in '{s}' must be "
                              f"integers")
        n = len(symbols[name])
        for v in (a, b):
            if not 0 <= v < n:
                raise ConfigError(f"{path}: subset '{s}': index {v} is not "
                                  f"in 0..{n - 1} (length of {name})")
        step = 1 if b >= a else -1
        # explicit range(): a slice [a:b+step:step] with b == 0 would hit
        # Python's negative-stop trap (lst[7:-1:-1] == []).
        idxs = range(a, b + step, step)
        return [symbols[name][k] for k in idxs], s

    m = RANGE_RE.match(s)
    if m:
        a = int(m.group(1) or m.group(3) or m.group(5))
        b = int(m.group(2) or m.group(4) or m.group(6))
        for v in (a, b):
            if not 0 <= v < chain_bits:
                raise ConfigError(f"{path}: range endpoint {v} in '{s}' is "
                                  f"not in 0..{chain_bits - 1}")
        step = 1 if b >= a else -1
        return list(range(a, b + step, step)), s

    if NAME_RE.match(s):
        if s not in symbols:
            raise ConfigError(
                f"{path}: '{s}' is not defined earlier in 'signals' "
                f"(definitions may only reference earlier symbols)")
        if referenced is not None:
            referenced.add(s)
        return list(symbols[s]), s

    try:  # a quoted plain integer, e.g. "37"
        v = int(s)
        if not 0 <= v < chain_bits:
            raise ConfigError(
                f"{path}: chain position {v} in {tok!r} is not in "
                f"0..{chain_bits - 1}" + sexagesimal_hint(v, chain_bits - 1))
        return [v], str(v)
    except ValueError:
        pass
    raise ConfigError(f"{path}: bad reference token {tok!r}")


def build_symbols(cfg_symbols, chain_bits, path, referenced):
    """`signals` table -> ordered dict name -> expanded chain positions."""
    symbols = {}
    if cfg_symbols is None:
        return symbols
    if not isinstance(cfg_symbols, dict):
        raise ConfigError(f"{where(path, cfg_symbols)}: 'signals' must be a "
                          f"mapping of name -> definition list")
    for name, defn in cfg_symbols.items():
        p = f"{path}.{name}"
        if not isinstance(name, str) or not NAME_RE.match(name):
            raise ConfigError(f"{where(path, cfg_symbols)}: bad signal name "
                              f"{name!r} (want [A-Za-z_][A-Za-z0-9_]*)")
        if not isinstance(defn, (list, tuple)):
            raise ConfigError(f"{where(p, defn)}: definition must be a list "
                              f"of tokens")
        expanded = []
        for i, tok in enumerate(defn):
            positions, _ = expand_token(tok, symbols, chain_bits,
                                        f"{p}[{i}]", allow_blank=False,
                                        referenced=referenced)
            expanded.extend(positions)
        symbols[name] = expanded
    return symbols


# --------------------------------------------------------------------
# Layout / grid geometry
# --------------------------------------------------------------------
def wiring_order(rows, cols, origin, major, serpentine, path):
    """Cell (row, col) visited at each step of the layout's wiring walk.
    Identical geometry to the retired matrix walk, now used for one
    thing only: step n of the walk is where physical LED n sits."""
    top = origin.startswith("top")
    left = origin.endswith("left")
    row_seq = list(range(rows)) if top else list(range(rows - 1, -1, -1))
    col_seq = list(range(cols)) if left else list(range(cols - 1, -1, -1))
    cells = []
    if major == "row":
        for line, r in enumerate(row_seq):
            seq = col_seq[::-1] if (serpentine and line % 2) else col_seq
            cells.extend((r, c) for c in seq)
    else:
        for line, c in enumerate(col_seq):
            seq = row_seq[::-1] if (serpentine and line % 2) else row_seq
            cells.extend((r, c) for r in seq)
    return cells


def get_layout(cfg, leds, path):
    """-> dict(rows, cols, origin, major, serpentine).  Absent layout
    means one row of `leds` (identity wiring)."""
    lay = {"rows": 1, "cols": leds, "origin": "top-left",
           "major": "row", "serpentine": False}
    if cfg is None:
        return lay
    if not isinstance(cfg, dict):
        raise ConfigError(f"{where(path, cfg)}: 'layout' must be a mapping")
    for k in cfg:
        if k not in ("rows", "cols", "origin", "major", "serpentine"):
            raise ConfigError(f"{where(path, cfg)}: unknown key {k!r}")
    for k in ("rows", "cols"):
        if k in cfg:
            lay[k] = require_int(cfg[k], f"{path}.{k}", 1, 1024)
    if "origin" in cfg:
        if cfg["origin"] not in CORNERS:
            raise ConfigError(f"{where(path, cfg)}: origin must be one of "
                              f"{', '.join(CORNERS)}")
        lay["origin"] = cfg["origin"]
    if "major" in cfg:
        if cfg["major"] not in ("row", "column"):
            raise ConfigError(f"{where(path, cfg)}: major must be 'row' or "
                              f"'column'")
        lay["major"] = cfg["major"]
    if "serpentine" in cfg:
        lay["serpentine"] = bool(cfg["serpentine"])
    if lay["rows"] * lay["cols"] != leds:
        raise ConfigError(
            f"{where(path, cfg)}: {lay['rows']} x {lay['cols']} = "
            f"{lay['rows'] * lay['cols']} cells, but leds is {leds}")
    return lay


def compute_span(start, dirn, rows, cols):
    r, c = start
    if dirn == "right":
        return [(r, x) for x in range(c, cols)]
    if dirn == "left":
        return [(r, x) for x in range(c, -1, -1)]
    if dirn == "up":
        return [(x, c) for x in range(r, -1, -1)]
    return [(x, c) for x in range(r, rows)]


# --------------------------------------------------------------------
# Runs and profiles
# --------------------------------------------------------------------
def resolve_off(bases, palette, default):
    """First defined colour in a precedence chain of (path, value) pairs."""
    for p, v in bases:
        if v is not None:
            return parse_color(v, p, palette)
    return default


def parse_run(run, ri, layout, symbols, chain_bits, palette, path, referenced,
              default_dir):
    """-> dict with span + expanded cell assignments, or None on error."""
    wherepath = f"{path}.runs[{ri}]"
    if not isinstance(run, dict):
        raise ConfigError(f"{where(wherepath, run)}: run must be a mapping")
    for k in run:
        if k not in ("start", "dir", "on", "off", "signals"):
            raise ConfigError(f"{where(wherepath, run)}: unknown key {k!r}")
    for k in ("start", "signals"):
        if k not in run:
            raise ConfigError(f"{where(wherepath, run)}: '{k}' is required")

    start = run["start"]
    if (not isinstance(start, (list, tuple)) or len(start) != 2
            or any(isinstance(v, bool) or not isinstance(v, int)
                   for v in start)):
        raise ConfigError(f"{where(wherepath, start)}: start must be "
                          f"[row, col] integers")
    rows, cols = layout["rows"], layout["cols"]
    for v, lim, nm in ((start[0], rows, "row"), (start[1], cols, "col")):
        if not 0 <= v < lim:
            raise ConfigError(f"{where(wherepath, start)}: {nm} {v} is not "
                              f"in 0..{lim - 1}")
    dirn = run.get("dir", default_dir)
    if dirn not in DIRECTIONS:
        raise ConfigError(f"{where(wherepath, run)}: dir must be one of "
                          f"{', '.join(DIRECTIONS)}")
    span = compute_span(start, dirn, rows, cols)

    if not isinstance(run["signals"], (list, tuple)):
        raise ConfigError(f"{where(wherepath, run['signals'])}: signals "
                          f"must be a list of elements")

    cells = []  # (chain position or None, on_override, off_override, label)
    for ei, elem in enumerate(run["signals"]):
        ep = f"{wherepath}.signals[{ei}]"
        on = off = None
        if isinstance(elem, str) and elem.strip() == BLANK:
            tok = BLANK
        elif isinstance(elem, dict):
            for k in elem:
                if k not in ("sig", "on", "off"):
                    raise ConfigError(f"{where(ep, elem)}: unknown key {k!r}")
            if "sig" not in elem:
                raise ConfigError(f"{where(ep, elem)}: 'sig' is required")
            tok = elem["sig"]
            on = elem.get("on")
            off = elem.get("off")
            if on is not None and isinstance(tok, str) and tok.strip() == BLANK:
                raise ConfigError(f"{where(ep, elem)}: a blank is static; "
                                  f"set 'off', not 'on'")
            for k, v in (("on", on), ("off", off)):
                if v is not None:
                    parse_color(v, f"{ep}.{k}", palette)  # validate early
        else:
            tok = elem
        try:
            positions, label = expand_token(tok, symbols, chain_bits, ep,
                                            allow_blank=True,
                                            referenced=referenced)
        except ConfigError as e:
            raise ConfigError(f"{e}")
        if positions is None:
            cells.append((None, on, off, label))
        else:
            for pos in positions:
                cells.append((pos, on, off, label))
    return {"start": tuple(start), "dir": dirn, "span": span,
            "cells": cells,
            "on": run.get("on"), "off": run.get("off")}


def build_profile(num, pcfg, base_on, base_off, layout, symbols,
                  chain_bits, leds, palette, errors, referenced, base_dir):
    """-> dict(map=[...], on=[...], off=[...]) of length leds."""
    path = f"profile.{num}"
    if not isinstance(pcfg, dict):
        raise ConfigError(f"{where(path, pcfg)}: profile must be a mapping")
    for k in pcfg:
        if k not in ("on", "off", "dir", "runs"):
            raise ConfigError(f"{where(path, pcfg)}: unknown key {k!r}")

    run_dir = pcfg.get("dir", base_dir)
    if run_dir not in DIRECTIONS:
        raise ConfigError(f"{where(path, pcfg)}: dir must be one of "
                          f"{', '.join(DIRECTIONS)}")

    prof_on = pcfg.get("on")
    prof_off = pcfg.get("off")
    if prof_on is not None:
        parse_color(prof_on, f"{path}.on", palette)
    if prof_off is not None:
        parse_color(prof_off, f"{path}.off", palette)

    runs = pcfg.get("runs", [])
    if not isinstance(runs, (list, tuple)):
        raise ConfigError(f"{where(path, runs)}: runs must be a list")
    parsed = [parse_run(run, ri, layout, symbols, chain_bits, palette, path,
                        referenced, run_dir)
              for ri, run in enumerate(runs)]

    # Claim cells first (overlap detection), then resolve colours.  A
    # run claims exactly the cells its expanded list covers -- never
    # the bare edge past them -- so runs can pack into one line.
    claimed = {}  # cell -> (run_index, label, list_index)
    for ri, run in enumerate(parsed):
        if run is None:
            continue
        span, cells = run["span"], run["cells"]
        if len(cells) > len(span):
            r0, c0 = run["start"]
            errors.append(
                f"{path}.runs[{ri}]: needs {len(cells)} cells but the line "
                f"from start [{r0}, {c0}] dir {run['dir']} has capacity "
                f"{len(span)}")
            continue
        taken = span[:len(cells)]
        overlaps = [cell for cell in taken if cell in claimed]
        if overlaps:
            detail = []
            for cell in overlaps[:3]:
                own_i = taken.index(cell)
                other_i, other_label, _ = claimed[cell]
                detail.append(f"[{cell[0]},{cell[1]}] (run {other_i} places "
                              f"{other_label}, run {ri} would place "
                              f"{cells[own_i][3]})")
            more = f" (+{len(overlaps) - 3} more)" if len(overlaps) > 3 else ""
            errors.append(f"{path}: runs[{ri}] overlaps earlier run(s) on "
                          f"{len(overlaps)} cell(s): {'; '.join(detail)}"
                          f"{more}")
            continue
        for i, cell in enumerate(taken):
            claimed[cell] = (ri, cells[i][3], i)

    # Resolve every claimed cell.
    cellcolor = {}  # cell -> (map, on, off)
    for cell, (ri, _, i) in claimed.items():
        pos, e_on, e_off, _ = parsed[ri]["cells"][i]
        off = resolve_off([(f"{path}.runs[{ri}].signals.off", e_off),
                           (f"{path}.runs[{ri}].off", parsed[ri]["off"]),
                           (f"{path}.off", prof_off),
                           ("defaults.off", base_off[0])],
                          palette, DEFAULT_OFF)
        if pos is None:  # explicit blank: ON baked to OFF, static
            cellcolor[cell] = (0, off, off)
        else:
            on = resolve_off([(f"{path}.runs[{ri}].signals.on", e_on),
                              (f"{path}.runs[{ri}].on", parsed[ri]["on"]),
                              (f"{path}.on", prof_on),
                              ("defaults.on", base_on[0])],
                             palette, DEFAULT_ON)
            cellcolor[cell] = (pos, on, off)

    # Layout wiring: cell -> physical LED number.
    led_at = {}
    for step, cell in enumerate(wiring_order(
            layout["rows"], layout["cols"], layout["origin"],
            layout["major"], layout["serpentine"], path)):
        led_at[cell] = step

    # Unclaimed cells are profile-context blanks.
    default_off = resolve_off([(f"{path}.off", prof_off),
                               ("defaults.off", base_off[0])],
                              palette, DEFAULT_OFF)

    maps, ons, offs = [0] * leds, [None] * leds, [None] * leds
    for r in range(layout["rows"]):
        for c in range(layout["cols"]):
            led = led_at[(r, c)]
            if (r, c) in cellcolor:
                maps[led], ons[led], offs[led] = cellcolor[(r, c)]
            else:
                maps[led], ons[led], offs[led] = 0, default_off, default_off
    return {"map": maps, "on": ons, "off": offs}


def default_profile(leds, on=DEFAULT_ON, off=DEFAULT_OFF):
    return {"map": list(range(leds)),
            "on": [on] * leds, "off": [off] * leds}


# --------------------------------------------------------------------
# Whole configuration -> profiles
# --------------------------------------------------------------------
TOP_KEYS = ("chain_bits", "leds", "dir", "colors", "defaults", "signals",
            "layout")


def build_profiles(config, chain_bits_override=None):
    """Parsed config -> (list of 8 profiles, warnings, errors)."""
    errors = []
    if config is None:
        config = {}
    for k in config:
        if k in TOP_KEYS:
            continue
        if isinstance(k, str) and k.startswith("profile."):
            continue
        hint = ""
        if k == "profile":
            hint = " (profiles are top-level keys 'profile.0' ... 'profile.7')"
        raise ConfigError(f"unknown top-level key {k!r}{hint}")

    chain_bits = require_int(config.get("chain_bits", 256), "chain_bits",
                             1, MAX_CHAIN)
    if chain_bits_override is not None:
        chain_bits = chain_bits_override
    leds = require_int(config.get("leds", DEFAULT_LEDS), "leds", 1, 1024)
    base_dir = config.get("dir", "right")
    if base_dir not in DIRECTIONS:
        raise ConfigError(f"dir: must be one of {', '.join(DIRECTIONS)}")

    palette = build_palette(config.get("colors"), "colors")

    d = config.get("defaults", {})
    if not isinstance(d, dict):
        raise ConfigError(f"{where('defaults', d)}: defaults must be a mapping")
    for k in d:
        if k not in ("on", "off"):
            raise ConfigError(f"{where('defaults', d)}: unknown key {k!r}")
    if "on" in d:
        parse_color(d["on"], "defaults.on", palette)
    if "off" in d:
        parse_color(d["off"], "defaults.off", palette)
    base_on = (d.get("on", DEFAULT_ON), "defaults.on")
    base_off = (d.get("off", DEFAULT_OFF), "defaults.off")

    referenced = set()
    symbols = build_symbols(config.get("signals"), chain_bits, "signals",
                            referenced)
    layout = get_layout(config.get("layout"), leds, "layout")

    pcfgs = {}
    for k in config:
        if isinstance(k, str) and k.startswith("profile."):
            num = k[len("profile."):]
            if not num.isdigit() or not 0 <= int(num) < NUM_PROFILES:
                raise ConfigError(f"{k}: profile numbers are "
                                  f"0..{NUM_PROFILES - 1}")
            pcfgs[int(num)] = config[k]

    fb_on = resolve_off([("defaults.on", d.get("on"))], palette, DEFAULT_ON)
    fb_off = resolve_off([("defaults.off", d.get("off"))], palette,
                         DEFAULT_OFF)

    profiles = []
    for n in range(NUM_PROFILES):
        if n in pcfgs:
            profiles.append(build_profile(n, pcfgs[n], base_on, base_off,
                                          layout, symbols, chain_bits, leds,
                                          palette, errors, referenced,
                                          base_dir))
        else:
            profiles.append(default_profile(leds, fb_on, fb_off))

    warnings = [f"signal '{name}' is defined but no profile references it"
                for name in symbols if name not in referenced]
    if isinstance(config.get("colors"), dict):
        warnings += [
            f"colour '{name}' in the colors table is never referenced"
            for name in config["colors"]
            if not color_name_used(name, config)]
    return profiles, warnings, errors


def color_name_used(name, config):
    """Scan every colour position of the raw config for a name match."""
    target = str(name)

    def walk(node):
        if isinstance(node, dict):
            return any(walk(v) for v in node.values())
        if isinstance(node, (list, tuple)):
            return any(walk(v) for v in node)
        if isinstance(node, str):
            s = node.strip()
            return s == target or s == "#" + target
        return False

    for key in ("defaults",):
        if key in config and walk(config[key]):
            return True
    for k in config:
        if isinstance(k, str) and k.startswith("profile.") and walk(config[k]):
            return True
    return False


# --------------------------------------------------------------------
# File encode / decode
# --------------------------------------------------------------------
def encode(profiles, leds):
    out = bytearray(MAGIC)
    out += bytes([VERSION, NUM_PROFILES]) + struct.pack("<H", leds) + bytes(8)
    for p in profiles:
        for i in range(leds):
            out += struct.pack("<H", p["map"][i])
            out += bytes(p["on"][i])
            out += bytes(p["off"][i])
    want = HEADER_SIZE + NUM_PROFILES * leds * RECORD
    assert len(out) == want
    return bytes(out)


def decode(data):
    """Version 2 file -> profiles (a legacy version 1 file is also
    decoded, for --dump)."""
    if data[:4] != MAGIC:
        raise ConfigError("bad magic (not a front-panel profile file)")
    if len(data) < HEADER_SIZE:
        raise ConfigError("file too short")
    ver, nprof, nleds = data[4], data[5], struct.unpack("<H", data[6:8])[0]
    if nprof != NUM_PROFILES or nleds < 1:
        raise ConfigError(f"unsupported profile/LED counts: {nprof}/{nleds}")
    if ver not in (1, 2):
        raise ConfigError(f"unsupported version {ver}")
    if ver == 1 and nleds != DEFAULT_LEDS:
        raise ConfigError(f"version 1 files always have 256 LEDs, got {nleds}")
    rec = 7 if ver == 1 else RECORD
    want = HEADER_SIZE + NUM_PROFILES * nleds * rec
    if len(data) != want:
        raise ConfigError(f"file is {len(data)} bytes, expected {want} for "
                          f"version {ver} with {nleds} LEDs")
    profiles = []
    o = HEADER_SIZE
    for _ in range(NUM_PROFILES):
        p = {"map": [], "on": [], "off": []}
        for _ in range(nleds):
            if ver == 1:
                p["map"].append(data[o])
                c = o + 1
            else:
                p["map"].append(struct.unpack("<H", data[o:o + 2])[0])
                c = o + 2
            p["on"].append(tuple(data[c:c + 3]))
            p["off"].append(tuple(data[c + 3:c + 6]))
            o += rec
        profiles.append(p)
    return profiles


def hexcol(c):
    return "#%02X%02X%02X" % c


def compact_chain(seq):
    """Token list of canonical `a..b` ranges for +-1 runs of 4+."""
    out, i = [], 0
    while i < len(seq):
        j = i
        if i + 1 < len(seq):
            step = seq[i + 1] - seq[i]
            if step in (1, -1):
                while j + 1 < len(seq) and seq[j + 1] - seq[j] == step:
                    j += 1
        if j - i + 1 >= 4:
            out.append(f"{seq[i]}..{seq[j]}")
        else:
            out.extend(str(v) for v in seq[i:j + 1])
        i = j + 1
    return out


def dump(profiles, out=sys.stdout):
    nleds = len(profiles[0]["map"])
    for n, p in enumerate(profiles):
        ident = p["map"] == list(range(nleds))
        static = all(o == f for o, f in zip(p["on"], p["off"]))
        ons, offs = set(p["on"]), set(p["off"])
        print(f"profile {n}: {'identity' if ident else 'custom'} map; "
              f"{len(ons)} distinct ON, {len(offs)} distinct OFF"
              + (" (all static/blanks)" if static else ""), file=out)
        if len(ons) <= 4:
            print("    ON : " + " ".join(hexcol(c) for c in sorted(ons)),
                  file=out)
        if len(offs) <= 4:
            print("    OFF: " + " ".join(hexcol(c) for c in sorted(offs)),
                  file=out)
        if not ident:
            tokens = compact_chain(p["map"][:16])
            print("    map[:16]: " + " ".join(tokens), file=out)


# --------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Build or inspect a MrZ80 front-panel profile file "
                    "(OSD 'Front Panel Profiles', FC5).",
        epilog="See the module docstring, NEW-REQUIREMENTS.md, and "
               "example_profiles.yaml for the YAML schema.")
    ap.add_argument("config", nargs="?",
                    help="YAML configuration (omit with -o for an "
                         "all-defaults file)")
    ap.add_argument("-o", "--output",
                    help="output profile file (e.g. profiles.fpp)")
    ap.add_argument("--strict", action="store_true",
                    help="treat warnings as errors")
    ap.add_argument("--chain-bits", type=int, metavar="N",
                    help="override the chain_bits key (1..1024)")
    ap.add_argument("--dump", metavar="FILE",
                    help="decode and summarise an existing profile file")
    args = ap.parse_args(argv)

    if args.chain_bits is not None and not 1 <= args.chain_bits <= MAX_CHAIN:
        ap.error(f"--chain-bits must be 1..{MAX_CHAIN}")

    try:
        if args.dump:
            with open(args.dump, "rb") as f:
                dump(decode(f.read()))
            return 0

        if not args.output:
            ap.error("no output file given (-o)")
        config = load_config(args.config) if args.config else {}
        profiles, warnings, errors = build_profiles(config, args.chain_bits)
        leds = require_int(config.get("leds", DEFAULT_LEDS), "leds",
                           1, 1024)
    except ConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    if errors or (args.strict and warnings):
        print("not writing output", file=sys.stderr)
        return 1

    data = encode(profiles, leds)
    with open(args.output, "wb") as f:
        f.write(data)
    print(f"wrote {args.output} ({len(data)} bytes; "
          f"chain_bits={args.chain_bits or config.get('chain_bits', 256)}, "
          f"leds={leds})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
