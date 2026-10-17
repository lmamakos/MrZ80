#!/usr/bin/env python3
"""fpprofile.py - build (or inspect) a MrZ80 front-panel profile file.

The file is loaded from the MiSTer OSD ("Front Panel Profiles", index
FC5) and initialises all 8 profiles of FrontPanel_Subsystem. A profile
defines, for each of the 256 physical LEDs in string order:

  * map : which capture-chain position drives the LED. Chain position 0
          is the first bit shifted out of the capture chain (the MSB of
          the first chain segment); the identity map (LED n shows chain
          position n) is the default.
  * on  : RGB colour when the mapped chain bit is 1
  * off : RGB colour when the mapped chain bit is 0

File layout (README.md has the authoritative description):

  16-byte header:  'F' 'P' 'P' 'F', version (1), profile count (8),
                   LEDs per profile little-endian (256 -> 00 01),
                   8 reserved zero bytes
  then 8 profiles x 256 LEDs x 7 bytes:  map, onR, onG, onB, offR, offG, offB
  = 16 + 8*256*7 = 14352 bytes.

Profiles that are not mentioned in the configuration, and LEDs that a
profile does not override, get the built-in defaults (identity map, ON =
#FF0001, OFF = #000009 -- the same as the hardware's no-file defaults).

Configuration (TOML; see example_profiles.toml):

  [defaults]                  # optional; replaces the built-in colours
  on  = "#FF0001"             # "#RRGGBB", "RRGGBB" or [r, g, b]
  off = "#000009"

  [profile.N]                 # N = 0..7; all keys optional
  on  = "#00FF00"             # colours for every LED of this profile
  off = "#001000"
  map = [0, 1, 2, ...]        # per-LED map, exactly 256 entries
                              #   (index = physical LED, value = chain position)

  [profile.N.matrix]          # shorthand for an X by Y LED matrix
  cols = 16                   # X
  rows = 16                   # Y
  # How the *chain* enumerates the matrix cells (default: row-major from
  # the top-left, not serpentine):
  chain_origin = "top-left"   # top-left|top-right|bottom-left|bottom-right
  chain_major  = "row"        # "row" or "column": which direction runs first
  chain_serpentine = false    # alternate direction on every row/column
  # How the physical LED string is wired through the matrix:
  strip_origin = "top-left"
  strip_major  = "row"
  strip_serpentine = true
  # map[physical n] = chain position of the cell that LED n sits at.
  #
  # chain_* vs strip_*: both use the same three settings (origin corner,
  # major direction, serpentine) to describe a *walk* over the cells of
  # the matrix, but they describe two different walks:
  #
  #   chain_*  = the order of the SOFTWARE/HARDWARE side. Cell k of the
  #              chain walk is the cell that shows capture-chain bit k.
  #              This is how the signals you are displaying are arranged
  #              on the front panel, e.g. a 16-bit register drawn as
  #              left-to-right rows from the top-left corner. It does not
  #              depend on how the LEDs are physically wired.
  #   strip_*  = the order of the PHYSICAL side. Cell n of the strip walk
  #              is where the n-th LED of the WS2812 string is mounted,
  #              i.e. how the data wire snakes through the board.
  #
  # The tool lines the two walks up: physical LED n sits at cell n of the
  # strip walk, and that cell is cell k of the chain walk, so
  # map[n] = k. Change chain_* when you want the signals laid out
  # differently on the panel; change strip_* to match how the board is
  # wired. If both walks are identical the map is the identity.
  #
  # Worked example, 4 columns x 3 rows (the numbers are shown in the
  # cells; "chain" is the chain bit shown there, "strip" the LED number):
  #
  #     chain walk (top-left, row, no serpentine):   chain bit in each cell
  #         0  1  2  3
  #         4  5  6  7
  #         8  9 10 11
  #
  #   (a) strip_origin="top-left", strip_major="row", strip_serpentine=true
  #       (rows zig-zag, the usual WS2812 matrix panel):
  #       LED number in each cell      map = [0,1,2,3, 7,6,5,4, 8,9,10,11]
  #         0  1  2  3                 (LED 4 sits where chain bit 7 is, ...)
  #         7  6  5  4
  #         8  9 10 11
  #
  #   (b) strip_origin="bottom-left", strip_major="column",
  #       strip_serpentine=true (string starts bottom-left, runs up the
  #       first column, down the next, ...):
  #       LED number in each cell      map = [8,4,0, 1,5,9, 10,6,2, 3,7,11]
  #         2  3  8  9
  #         1  4  7 10
  #         0  5  6 11
  #
  # In both cases the panel still displays chain bit 0 at the top-left
  # and bit 11 at the bottom-right; only the LED wiring differs.
  #
  # Common cases: panel wired as a row serpentine, signals laid out in
  # plain rows -> chain_* all default, strip_serpentine = true. Panel
  # wired plain but you want the chain to count up from the bottom
  # -> strip_* default, chain_origin = "bottom-left".

  [[profile.N.led]]           # per-LED overrides; applied after map/matrix
  index = 5                   # physical LED (default: position in the list)
  map = 12                    # optional
  on  = "#FFFFFF"             # optional
  off = [0, 0, 0]             # optional

Exit status is non-zero on errors. A profile whose geometry does not
produce exactly 256 LEDs is an error unless --force is given (the
profile is then padded with identity-map/default LEDs or truncated).
Duplicate map values only produce a warning (--strict makes warnings
errors).
"""

import argparse
import struct
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11
    tomllib = None

NUM_LEDS = 256
NUM_PROFILES = 8
RECORD = 7
MAGIC = b"FPPF"
VERSION = 1
HEADER_SIZE = 16
FILE_SIZE = HEADER_SIZE + NUM_PROFILES * NUM_LEDS * RECORD

DEFAULT_ON = (0xFF, 0x00, 0x01)
DEFAULT_OFF = (0x00, 0x00, 0x09)

CORNERS = ("top-left", "top-right", "bottom-left", "bottom-right")


class ConfigError(Exception):
    pass


# --------------------------------------------------------------------
# Colours
# --------------------------------------------------------------------
def parse_color(value, where):
    """'#RRGGBB' / 'RRGGBB' / [r, g, b] -> (r, g, b)."""
    if isinstance(value, str):
        s = value.strip()
        if s.startswith("#"):
            s = s[1:]
        if len(s) != 6:
            raise ConfigError(f"{where}: bad colour {value!r} (want #RRGGBB)")
        try:
            return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))
        except ValueError:
            raise ConfigError(f"{where}: bad colour {value!r} (want #RRGGBB)")
    if isinstance(value, (list, tuple)) and len(value) == 3:
        if all(isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 255
               for v in value):
            return tuple(value)
    raise ConfigError(f"{where}: bad colour {value!r} (want #RRGGBB or [r, g, b] 0..255)")


# --------------------------------------------------------------------
# Matrix geometry
# --------------------------------------------------------------------
def matrix_order(rows, cols, origin, major, serpentine):
    """List of (row, col) cells (row 0 = top, col 0 = left) in the order a
    string of LEDs visits them.

    The walk starts at the `origin` corner. major="row": it runs along a
    row first (horizontally, away from the origin's side), then steps to
    the next row (away from the origin's vertical edge); major="column"
    is the transpose. With `serpentine` every second line runs the
    opposite way instead of restarting at the same edge.
    """
    if origin not in CORNERS:
        raise ConfigError(f"unknown origin {origin!r} (use one of {', '.join(CORNERS)})")
    if major not in ("row", "column"):
        raise ConfigError(f"unknown major {major!r} (use 'row' or 'column')")
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


def matrix_map(rows, cols, chain, strip):
    """Physical-LED -> chain-position map for a matrix.

    chain / strip are (origin, major, serpentine) tuples. Returns a list
    indexed by physical LED n whose value is the chain position of the
    cell LED n occupies.
    """
    chain_pos = {cell: k for k, cell in enumerate(matrix_order(rows, cols, *chain))}
    return [chain_pos[cell] for cell in matrix_order(rows, cols, *strip)]


# --------------------------------------------------------------------
# Profile construction
# --------------------------------------------------------------------
def default_profile(on=DEFAULT_ON, off=DEFAULT_OFF):
    return {"map": list(range(NUM_LEDS)), "on": [on] * NUM_LEDS, "off": [off] * NUM_LEDS}


def _fit(lst, fill, count_where, warnings, errors, force):
    """Pad/truncate a per-LED list to NUM_LEDS (or flag an error)."""
    n = len(lst)
    if n == NUM_LEDS:
        return lst
    msg = f"{count_where}: produces {n} LEDs, expected {NUM_LEDS}"
    if not force:
        errors.append(msg + " (use --force to pad/truncate)")
        return lst[:NUM_LEDS] + [fill(i) for i in range(n, NUM_LEDS)]
    warnings.append(msg + "; padded/truncated (--force)")
    return lst[:NUM_LEDS] + [fill(i) for i in range(n, NUM_LEDS)]


def build_profile(num, cfg, base_on, base_off, warnings, errors, force):
    where = f"profile {num}"
    known = {"on", "off", "map", "matrix", "led"}
    for k in cfg:
        if k not in known:
            raise ConfigError(f"{where}: unknown key {k!r}")

    on = parse_color(cfg["on"], where + ".on") if "on" in cfg else base_on
    off = parse_color(cfg["off"], where + ".off") if "off" in cfg else base_off
    prof = default_profile(on, off)

    if "map" in cfg and "matrix" in cfg:
        raise ConfigError(f"{where}: give either 'map' or 'matrix', not both")

    if "map" in cfg:
        m = cfg["map"]
        if not isinstance(m, list) or not all(
                isinstance(v, int) and not isinstance(v, bool) for v in m):
            raise ConfigError(f"{where}.map must be a list of integers")
        m = _fit(list(m), lambda i: i, where + ".map", warnings, errors, force)
        prof["map"] = m

    if "matrix" in cfg:
        mx = cfg["matrix"]
        mwhere = where + ".matrix"
        mknown = {"cols", "rows", "chain_origin", "chain_major", "chain_serpentine",
                  "strip_origin", "strip_major", "strip_serpentine"}
        for k in mx:
            if k not in mknown:
                raise ConfigError(f"{mwhere}: unknown key {k!r}")
        for k in ("cols", "rows"):
            if k not in mx or not isinstance(mx[k], int) or isinstance(mx[k], bool) or mx[k] < 1:
                raise ConfigError(f"{mwhere}: '{k}' is required and must be a positive integer")
        cols, rows = mx["cols"], mx["rows"]
        chain = (mx.get("chain_origin", "top-left"), mx.get("chain_major", "row"),
                 bool(mx.get("chain_serpentine", False)))
        strip = (mx.get("strip_origin", "top-left"), mx.get("strip_major", "row"),
                 bool(mx.get("strip_serpentine", False)))
        try:
            m = matrix_map(rows, cols, chain, strip)
        except ConfigError as e:
            raise ConfigError(f"{mwhere}: {e}")
        if rows * cols != NUM_LEDS:
            msg = f"{mwhere}: {cols} x {rows} geometry produces {rows * cols} LEDs, expected {NUM_LEDS}"
            if force:
                warnings.append(msg + "; padded/truncated (--force)")
            else:
                errors.append(msg + " (use --force to pad/truncate)")
        # Pad (identity) or truncate to 256 LEDs; chain positions >= 256
        # can't exist, so such LEDs fall back to the identity map.
        m = m[:NUM_LEDS] + list(range(len(m), NUM_LEDS))
        m = [v if v < NUM_LEDS else i for i, v in enumerate(m)]
        prof["map"] = m

    if "led" in cfg:
        leds = cfg["led"]
        if not isinstance(leds, list):
            raise ConfigError(f"{where}.led must be an array of tables ([[profile.{num}.led]])")
        for pos, ent in enumerate(leds):
            lwhere = f"{where}.led[{pos}]"
            for k in ent:
                if k not in ("index", "map", "on", "off"):
                    raise ConfigError(f"{lwhere}: unknown key {k!r}")
            idx = ent.get("index", pos)
            if not isinstance(idx, int) or isinstance(idx, bool) or not 0 <= idx < NUM_LEDS:
                raise ConfigError(f"{lwhere}: index {idx!r} out of range 0..{NUM_LEDS - 1}")
            if "map" in ent:
                prof["map"][idx] = ent["map"]
            if "on" in ent:
                prof["on"][idx] = parse_color(ent["on"], lwhere + ".on")
            if "off" in ent:
                prof["off"][idx] = parse_color(ent["off"], lwhere + ".off")

    # Map validation.
    for i, v in enumerate(prof["map"]):
        if not isinstance(v, int) or isinstance(v, bool) or not 0 <= v < NUM_LEDS:
            errors.append(f"{where}: LED {i} map value {v!r} out of range 0..{NUM_LEDS - 1}")
    good = [v for v in prof["map"] if isinstance(v, int) and 0 <= v < NUM_LEDS]
    dups = sorted({v for v in good if good.count(v) > 1})
    if dups:
        shown = ", ".join(map(str, dups[:8])) + (" ..." if len(dups) > 8 else "")
        warnings.append(f"{where}: chain position(s) used by more than one LED: {shown}")
    return prof


def build_profiles(config, force=False):
    """config dict -> (list of 8 profiles, warnings, errors)."""
    warnings, errors = [], []
    for k in config:
        if k not in ("defaults", "profile"):
            raise ConfigError(f"unknown top-level key {k!r}")

    d = config.get("defaults", {})
    for k in d:
        if k not in ("on", "off"):
            raise ConfigError(f"[defaults]: unknown key {k!r}")
    base_on = parse_color(d["on"], "defaults.on") if "on" in d else DEFAULT_ON
    base_off = parse_color(d["off"], "defaults.off") if "off" in d else DEFAULT_OFF

    pcfg = config.get("profile", {})
    if not isinstance(pcfg, dict):
        raise ConfigError("'profile' must be a table: [profile.0], [profile.1], ...")
    for k in pcfg:
        if not (k.isdigit() and 0 <= int(k) < NUM_PROFILES):
            raise ConfigError(f"profile {k!r}: profile numbers are 0..{NUM_PROFILES - 1}")

    profiles = []
    for n in range(NUM_PROFILES):
        if str(n) in pcfg:
            profiles.append(build_profile(n, pcfg[str(n)], base_on, base_off,
                                          warnings, errors, force))
        else:
            profiles.append(default_profile(base_on, base_off))
    return profiles, warnings, errors


# --------------------------------------------------------------------
# File encode / decode
# --------------------------------------------------------------------
def encode(profiles):
    out = bytearray(MAGIC)
    out += bytes([VERSION, NUM_PROFILES]) + struct.pack("<H", NUM_LEDS) + bytes(8)
    for p in profiles:
        for i in range(NUM_LEDS):
            out.append(p["map"][i])
            out += bytes(p["on"][i])
            out += bytes(p["off"][i])
    assert len(out) == FILE_SIZE
    return bytes(out)


def decode(data):
    if len(data) != FILE_SIZE:
        raise ConfigError(f"file is {len(data)} bytes, expected {FILE_SIZE}")
    if data[:4] != MAGIC:
        raise ConfigError("bad magic (not a front-panel profile file)")
    ver, nprof = data[4], data[5]
    nleds = struct.unpack("<H", data[6:8])[0]
    if (ver, nprof, nleds) != (VERSION, NUM_PROFILES, NUM_LEDS):
        raise ConfigError(f"unsupported version/profiles/LEDs: {ver}/{nprof}/{nleds}")
    profiles = []
    o = HEADER_SIZE
    for _ in range(NUM_PROFILES):
        p = {"map": [], "on": [], "off": []}
        for _ in range(NUM_LEDS):
            p["map"].append(data[o])
            p["on"].append(tuple(data[o + 1:o + 4]))
            p["off"].append(tuple(data[o + 4:o + 7]))
            o += RECORD
        profiles.append(p)
    return profiles


def hexcol(c):
    return "#%02X%02X%02X" % c


def dump(profiles, out=sys.stdout):
    for n, p in enumerate(profiles):
        ident = p["map"] == list(range(NUM_LEDS))
        ons, offs = set(p["on"]), set(p["off"])
        print(f"profile {n}: map {'identity' if ident else 'custom'}; "
              f"{len(ons)} distinct ON colour(s), {len(offs)} distinct OFF colour(s)", file=out)
        if len(ons) <= 4:
            print("    ON : " + " ".join(hexcol(c) for c in sorted(ons)), file=out)
        if len(offs) <= 4:
            print("    OFF: " + " ".join(hexcol(c) for c in sorted(offs)), file=out)
        if not ident:
            print("    first 32 map entries: " + " ".join(map(str, p["map"][:32])), file=out)


# --------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Build or inspect a MrZ80 front-panel profile file "
                    "(OSD 'Front Panel Profiles', FC5).",
        epilog="See the module docstring (or Components/FRONTPANEL/README.md) "
               "for the TOML schema and example_profiles.toml for an example.")
    ap.add_argument("config", nargs="?", help="TOML configuration (omit for an all-defaults file)")
    ap.add_argument("-o", "--output", help="output profile file (e.g. profiles.fpp)")
    ap.add_argument("--force", action="store_true",
                    help="pad/truncate profiles whose LED count is not 256 instead of failing")
    ap.add_argument("--strict", action="store_true", help="treat warnings as errors")
    ap.add_argument("--dump", metavar="FILE", help="decode and summarise an existing profile file")
    args = ap.parse_args(argv)

    try:
        if args.dump:
            with open(args.dump, "rb") as f:
                dump(decode(f.read()))
            return 0

        config = {}
        if args.config:
            if tomllib is None:
                ap.error("Python 3.11+ is required (tomllib) to read the TOML configuration")
            with open(args.config, "rb") as f:
                try:
                    config = tomllib.load(f)
                except tomllib.TOMLDecodeError as e:
                    raise ConfigError(f"{args.config}: {e}")
        profiles, warnings, errors = build_profiles(config, args.force)
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

    if not args.output:
        ap.error("no output file given (-o)")
    with open(args.output, "wb") as f:
        f.write(encode(profiles))
    print(f"wrote {args.output} ({FILE_SIZE} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
