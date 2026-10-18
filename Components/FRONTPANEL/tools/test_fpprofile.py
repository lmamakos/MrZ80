#!/usr/bin/env python3
"""Unit tests for fpprofile.py.  Run: python3 -m unittest -v test_fpprofile
(from this directory) or python3 test_fpprofile.py."""

import os
import tempfile
import unittest

import fpprofile as fp

RED = (0xFF, 0x00, 0x00)
BLACK = (0, 0, 0)
DARK = (16, 16, 16)


def conf(text):
    """Parse a YAML config snippet exactly as the CLI would."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "c.yaml")
        with open(path, "w") as f:
            f.write(text)
        return fp.load_config(path)


def build_yaml(text, override=None):
    return fp.build_profiles(conf(text), override)


class Ranges(unittest.TestCase):
    def test_ascending_and_descending(self):
        syms = fp.build_symbols(
            fp.LineDict({"A": ["2..5", "9..6"]}), 256, "signals", set())
        self.assertEqual(syms["A"], [2, 3, 4, 5, 9, 8, 7, 6])

    def test_descending_to_index_zero(self):
        # the negative-stop regression: NAME[7..0] must not be empty
        syms = fp.build_symbols(fp.LineDict({"A": ["16..23"]}), 256,
                               "signals", set())
        pos, _ = fp.expand_token("A[7..0]", syms, 256, "t", False)
        self.assertEqual(pos, [23, 22, 21, 20, 19, 18, 17, 16])

    def test_singletons_and_repeats(self):
        syms = fp.build_symbols(fp.LineDict({"A": [37, "37", "5..2"]}),
                               256, "signals", set())
        self.assertEqual(syms["A"], [37, 37, 5, 4, 3, 2])

    def test_alias_forms(self):
        syms = fp.build_symbols(fp.LineDict({"A": ["16:19", "4-1"]}),
                               256, "signals", set())
        self.assertEqual(syms["A"], [16, 17, 18, 19, 4, 3, 2, 1])

    def test_quoted_plain_int(self):
        syms = fp.build_symbols(fp.LineDict({"A": ["37"]}), 256,
                               "signals", set())
        self.assertEqual(syms["A"], [37])

    def test_endpoint_out_of_range(self):
        with self.assertRaises(fp.ConfigError) as cm:
            fp.build_symbols(fp.LineDict({"A": ["250..260"]}), 256,
                             "signals", set())
        self.assertIn("260", str(cm.exception))

    def test_sexagesimal_hint(self):
        # 983 is what YAML 1.1 reads an unquoted 16:23 as.
        with self.assertRaises(fp.ConfigError) as cm:
            fp.build_symbols(fp.LineDict({"A": [983]}), 256, "signals",
                             set())
        msg = str(cm.exception)
        self.assertIn("983", msg)
        self.assertIn("did you mean \"16..23\"?", msg)

    def test_no_hint_when_improbable(self):
        with self.assertRaises(fp.ConfigError) as cm:
            fp.build_symbols(fp.LineDict({"A": [99999]}), 256, "signals",
                             set())
        self.assertNotIn("did you mean", str(cm.exception))


class Subsets(unittest.TestCase):
    def setUp(self):
        self.symbols = fp.build_symbols(
            fp.LineDict({"LATCH": ["0..7"], "ADDR": ["8..23"],
                         "REG_AF": ["64..79"]}), 256, "signals", set())

    def test_positional_written_order(self):
        pos, _ = fp.expand_token("LATCH[7..4]", self.symbols, 256, "t", False)
        self.assertEqual(pos, [7, 6, 5, 4])
        pos, _ = fp.expand_token("LATCH[2..4]", self.symbols, 256, "t", False)
        self.assertEqual(pos, [2, 3, 4])

    def test_single_index(self):
        pos, _ = fp.expand_token("ADDR[15]", self.symbols, 256, "t", False)
        self.assertEqual(pos, [23])          # 15th element of ADDR

    def test_colon_alias(self):
        pos, _ = fp.expand_token("LATCH[1:0]", self.symbols, 256, "t", False)
        self.assertEqual(pos, [1, 0])

    def test_whole_symbol(self):
        pos, _ = fp.expand_token("REG_AF", self.symbols, 256, "t", False)
        self.assertEqual(pos, list(range(64, 80)))

    def test_index_out_of_range(self):
        with self.assertRaises(fp.ConfigError) as cm:
            fp.expand_token("LATCH[8..0]", self.symbols, 256, "t", False)
        self.assertIn("not in 0..7", str(cm.exception))

    def test_forward_reference_rejected(self):
        with self.assertRaises(fp.ConfigError) as cm:
            fp.build_symbols(
                fp.LineDict({"A": ["B"], "B": [1]}), 256, "signals", set())
        self.assertIn("not defined earlier", str(cm.exception))

    def test_nested_composition(self):
        syms = fp.build_symbols(
            fp.LineDict({"A": ["0..3"], "B": ["A[2..3]", 9]}), 256,
            "signals", set())
        self.assertEqual(syms["B"], [2, 3, 9])


class Colours(unittest.TestCase):
    def test_forms_and_names(self):
        pal = fp.build_palette(None, "colors")
        self.assertEqual(fp.parse_color("#FF8000", "t", pal), (255, 128, 0))
        self.assertEqual(fp.parse_color("FF8000", "t", pal), (255, 128, 0))
        self.assertEqual(fp.parse_color([1, 2, 3], "t", pal), (1, 2, 3))
        self.assertEqual(fp.parse_color("red", "t", pal), (255, 0, 0))
        self.assertEqual(fp.parse_color("black", "t", pal), (0, 0, 0))

    def test_css_table_complete(self):
        self.assertEqual(len(fp.CSS_COLORS), 148)

    def test_palette_override_and_names(self):
        pal = fp.build_palette(fp.LineDict({"red": "#010203",
                                            "custom": "teal"}), "colors")
        self.assertEqual(fp.parse_color("red", "t", pal), (1, 2, 3))
        self.assertEqual(fp.parse_color("custom", "t", pal), (0, 128, 128))

    def test_unknown_name(self):
        with self.assertRaises(fp.ConfigError):
            fp.parse_color("notacolor", "t", fp.build_palette(None, "c"))

    def test_six_hex_name_reads_as_hex(self):
        pal = fp.build_palette(fp.LineDict(), "colors")
        self.assertEqual(fp.parse_color("abcdef", "t", pal),
                         (0xAB, 0xCD, 0xEF))


class SpansAndRuns(unittest.TestCase):
    LAYOUT = {"rows": 4, "cols": 8, "origin": "top-left",
              "major": "row", "serpentine": False}

    def test_span_directions(self):
        self.assertEqual(fp.compute_span((1, 5), "right", 4, 8),
                         [(1, c) for c in range(5, 8)])
        self.assertEqual(fp.compute_span((1, 2), "left", 4, 8),
                         [(1, c) for c in range(2, -1, -1)])
        self.assertEqual(fp.compute_span((2, 3), "up", 4, 8),
                         [(r, 3) for r in range(2, -1, -1)])
        self.assertEqual(fp.compute_span((2, 3), "down", 4, 8),
                         [(r, 3) for r in range(2, 4)])

    def test_wiring_order_matches_geometry(self):
        cells = fp.wiring_order(2, 3, "top-left", "row", True, "t")
        self.assertEqual(cells, [(0, 0), (0, 1), (0, 2),
                                 (1, 2), (1, 1), (1, 0)])
        cells = fp.wiring_order(2, 2, "bottom-right", "column", False, "t")
        self.assertEqual(cells, [(1, 1), (0, 1), (1, 0), (0, 0)])

    def test_capacity_error_content(self):
        p, w, e = build_yaml(
            "leds: 32\n"
            "layout: {rows: 4, cols: 8}\n"
            "profile.0:\n"
            "  runs:\n"
            "    - start: [0, 5]\n"
            "      dir: right\n"
            "      signals: [\"0..7\"]\n")
        self.assertEqual(w, [])
        self.assertEqual(len(e), 1)
        self.assertIn("needs 8 cells", e[0])
        self.assertIn("capacity 3", e[0])

    def test_overlap_error_content(self):
        p, w, e = build_yaml(
            "leds: 32\n"
            "layout: {rows: 4, cols: 8}\n"
            "profile.0:\n"
            "  runs:\n"
            "    - start: [1, 0]\n"
            "      dir: right\n"
            "      signals: [\"0..3\"]\n"
            "    - start: [1, 2]\n"
            "      dir: right\n"
            "      signals: [\"8..9\"]\n")
        self.assertEqual(w, [])
        self.assertEqual(len(e), 1)
        msg = e[0]
        # only the DATA cells collide now: [1,2] and [1,3]
        self.assertIn("overlaps earlier run(s) on 2 cell(s)", msg)
        self.assertIn("run 0 places 0..3", msg)
        self.assertIn("run 1 would place 8..9", msg)
        self.assertIn("[1,2]", msg)
        self.assertNotIn("more)", msg)

    def test_claim_stops_at_data_edge(self):
        # A run claims only its data: a second run starting just past
        # the first run's last cell on the same line is not an overlap.
        p, w, e = build_yaml(
            "leds: 32\n"
            "layout: {rows: 4, cols: 8}\n"
            "profile.0:\n"
            "  runs:\n"
            "    - start: [0, 0]\n"
            "      signals: [\"0..4\"]\n"
            "    - start: [0, 5]\n"
            "      signals: [\"8..9\"]\n")
        self.assertEqual((w, e), ([], []))
        p0 = p[0]["map"]
        self.assertEqual(p0[0:5], [0, 1, 2, 3, 4])
        self.assertEqual(p0[5:7], [8, 9])
        self.assertEqual(p0[7], 0)          # unclaimed -> blank

    def test_edge_capacity_still_enforced(self):
        # claiming only data cells does not lift the no-wrap rule
        p, w, e = build_yaml(
            "leds: 32\n"
            "layout: {rows: 4, cols: 8}\n"
            "profile.0:\n"
            "  runs:\n"
            "    - start: [0, 5]\n"
            "      signals: [\"0..3\"]\n")   # needs 4 cells, 3 to the edge
        self.assertEqual(len(e), 1)
        self.assertIn("needs 4 cells", e[0])
        self.assertIn("capacity 3", e[0])

    def test_disjoint_spans_on_one_line_ok(self):
        p, w, e = build_yaml(
            "leds: 32\n"
            "layout: {rows: 4, cols: 8}\n"
            "profile.0:\n"
            "  runs:\n"
            "    - start: [0, 5]\n"
            "      dir: left\n"
            "      signals: [\"0..4\"]\n"
            "    - start: [0, 6]\n"
            "      dir: right\n"
            "      signals: [\"8..9\"]\n")
        self.assertEqual(e, [])
        led_of = {(r, c): r * 8 + c for r in range(4) for c in range(8)}
        p0 = p[0]["map"]
        # run0 claims (0,0)..(0,5): chains 0..4 land from [0,5] leftward,
        # so LED 0 is its blank tail; (0,6),(0,7) belong to run1.
        self.assertEqual([p0[led_of[(0, c)]] for c in range(6)],
                         [0, 4, 3, 2, 1, 0])
        self.assertEqual(p0[led_of[(0, 6)]], 8)


class BlanksAndPrecedence(unittest.TestCase):
    def test_blank_invariants_and_contexts(self):
        p, w, e = build_yaml(
            "leds: 16\n"
            "layout: {rows: 2, cols: 8}\n"
            "defaults: {on: '#F00000', off: '#0F0F0F'}\n"
            "profile.0:\n"
            "  on: '#00FF00'\n"
            "  runs:\n"
            "    - start: [0, 0]\n"
            "      dir: right\n"
            "      on: red\n"
            "      signals:\n"
            "        - \"0\"\n"
            "        - \"-\"\n"
            "        - {sig: \"-\", off: '#101010'}\n"
            "        - {sig: \"1\", on: black}\n")
        self.assertEqual((w, e), ([], []))
        p0 = p[0]
        # claimed signal: run ON red; element overrides to black
        self.assertEqual(p0["on"][0], RED)
        self.assertEqual(p0["on"][3], BLACK)
        # explicit blank: map 0, ON baked to resolved OFF (defaults)
        self.assertEqual(p0["map"][1], 0)
        self.assertEqual(p0["on"][1], p0["off"][1])
        # element off overrides the blank darkness
        self.assertEqual(p0["off"][2], DARK)
        # unclaimed cells: profile-context blank (defaults off; profile
        # 'on' does not apply to blanks)
        self.assertEqual(p0["map"][5], 0)
        self.assertEqual(p0["off"][5], (0x0F, 0x0F, 0x0F))
        self.assertEqual(p0["on"][5], (0x0F, 0x0F, 0x0F))

    def test_unclaimed_tail_takes_profile_darkness(self):
        # cells past a run's data are UNCLAIMED, not run-context:
        # they resolve like any other blank (profile > defaults)
        p, _, e = build_yaml(
            "leds: 6\n"
            "layout: {rows: 1, cols: 6}\n"
            "profile.0:\n"
            "  off: '#010101'\n"
            "  runs:\n"
            "    - start: [0, 0]\n"
            "      dir: right\n"
            "      off: '#020202'\n"
            "      signals: [0]\n")
        self.assertEqual(e, [])
        self.assertEqual(p[0]["off"][3], (1, 1, 1))   # profile, not run
        self.assertEqual(p[0]["on"][3], (1, 1, 1))    # baked static

    def test_explicit_blank_still_takes_run_darkness(self):
        # "-" IS claimed data, so its element/run context still applies
        p, _, e = build_yaml(
            "leds: 6\n"
            "layout: {rows: 1, cols: 6}\n"
            "profile.0:\n"
            "  off: '#010101'\n"
            "  runs:\n"
            "    - start: [0, 0]\n"
            "      dir: right\n"
            "      off: '#020202'\n"
            "      signals: ['-', 0]\n")
        self.assertEqual(e, [])
        self.assertEqual(p[0]["off"][0], (2, 2, 2))
        self.assertEqual(p[0]["on"][0], (2, 2, 2))

    def test_element_beats_run_beats_profile_beats_defaults(self):
        p, _, e = build_yaml(
            "leds: 8\n"
            "layout: {rows: 1, cols: 8}\n"
            "defaults: {on: '#040404', off: '#000000'}\n"
            "profile.0:\n"
            "  on: '#030303'\n"
            "  runs:\n"
            "    - start: [0, 0]\n"
            "      dir: right\n"
            "      on: '#020202'\n"
            "      signals: [\"0\", {sig: \"1\", on: '#010101'}]\n")
        self.assertEqual(e, [])
        self.assertEqual(p[0]["on"][0], (2, 2, 2))     # run
        self.assertEqual(p[0]["on"][1], (1, 1, 1))     # element
        self.assertEqual(p[0]["off"][0], BLACK)        # defaults
        p2 = fp.build_profiles(conf(
            "leds: 8\n"
            "layout: {rows: 1, cols: 8}\n"
            "defaults: {on: '#040404'}\n"
            "profile.0:\n"
            "  runs:\n"
            "    - start: [0, 0]\n"
            "      dir: right\n"
            "      signals: [\"0\"]\n"), None)[0][0]
        self.assertEqual(p2["on"][0], (4, 4, 4))       # defaults

    def test_blank_with_on_is_error(self):
        with self.assertRaises(fp.ConfigError) as cm:
            build_yaml("profile.0:\n  runs:\n"
                       "    - start: [0, 0]\n      dir: right\n"
                       "      signals: [{sig: '-', on: red}]\n")
        self.assertIn("static", str(cm.exception))

    def test_blank_in_signals_is_error(self):
        with self.assertRaises(fp.ConfigError):
            build_yaml("signals:\n  A: ['-']\n")


class DirDefaults(unittest.TestCase):
    def maps(self, text):
        p, w, e = build_yaml(text)
        self.assertEqual((w, e), ([], []))
        return p[0]["map"]

    def test_run_dir_defaults_to_right(self):
        m = self.maps("leds: 8\nlayout: {rows: 2, cols: 4}\n"
                      "profile.0:\n  runs:\n    - start: [0, 0]\n"
                      "      signals: [\"8..9\"]\n")
        self.assertEqual([m[0], m[1]], [8, 9])      # (0,0),(0,1)

    def test_config_dir_default(self):
        m = self.maps("leds: 8\nlayout: {rows: 2, cols: 4}\ndir: down\n"
                      "profile.0:\n  runs:\n    - start: [0, 0]\n"
                      "      signals: [\"8..9\"]\n")
        self.assertEqual([m[0], m[4]], [8, 9])      # (0,0),(1,0)

    def test_profile_dir_beats_config(self):
        m = self.maps("leds: 8\nlayout: {rows: 2, cols: 4}\ndir: down\n"
                      "profile.0:\n  dir: up\n  runs:\n    - start: [1, 0]\n"
                      "      signals: [\"8..9\"]\n")
        self.assertEqual([m[4], m[0]], [8, 9])      # (1,0),(0,0)

    def test_run_dir_beats_profile(self):
        m = self.maps("leds: 8\nlayout: {rows: 2, cols: 4}\ndir: down\n"
                      "profile.0:\n  dir: up\n  runs:\n"
                      "    - start: [0, 0]\n      dir: right\n"
                      "      signals: [\"8..9\"]\n")
        self.assertEqual([m[0], m[1]], [8, 9])

    def test_bad_dir_values_rejected(self):
        for text in ("dir: diagonal\n",
                     "profile.0:\n  dir: sideways\n  runs: []\n"):
            with self.subTest(text=text):
                with self.assertRaises(fp.ConfigError):
                    build_yaml("leds: 8\nlayout: {rows: 2, cols: 4}\n" + text)


class Validation(unittest.TestCase):
    def test_rows_cols_must_equal_leds(self):
        with self.assertRaises(fp.ConfigError) as cm:
            build_yaml("layout: {rows: 4, cols: 4}\n")
        self.assertIn("16 cells, but leds is 256", str(cm.exception))
        with self.assertRaises(fp.ConfigError) as cm:
            build_yaml("leds: 128\nlayout: {rows: 16, cols: 16}\n")
        self.assertIn("256 cells, but leds is 128", str(cm.exception))

    def test_chain_bits_bounds(self):
        with self.assertRaises(fp.ConfigError):
            build_yaml("chain_bits: 0\n")
        with self.assertRaises(fp.ConfigError):
            build_yaml("chain_bits: 1025\n")

    def test_override_narrows_validation(self):
        with self.assertRaises(fp.ConfigError):
            build_yaml("profile.0:\n  runs:\n    - start: [0, 0]\n"
                       "      dir: right\n      signals: [\"300\"]\n", 256)
        p, _, e = build_yaml("profile.0:\n  runs:\n    - start: [0, 0]\n"
                             "      dir: right\n      signals: [\"300\"]\n",
                             512)
        self.assertEqual(e, [])

    def test_start_out_of_grid(self):
        with self.assertRaises(fp.ConfigError) as cm:
            build_yaml("leds: 8\n"
                       "layout: {rows: 2, cols: 4}\n"
                       "profile.0:\n  runs:\n    - start: [2, 0]\n"
                       "      dir: right\n      signals: [0]\n")
        self.assertIn("row 2", str(cm.exception))

    def test_bad_dir(self):
        with self.assertRaises(fp.ConfigError) as cm:
            build_yaml("profile.0:\n  runs:\n    - start: [0, 0]\n"
                       "      dir: diagonal\n      signals: [0]\n")
        self.assertIn("dir", str(cm.exception))

    def test_unknown_keys_everywhere(self):
        for text in ("bogus: 1\n",
                     "profile: {}\n",
                     "profile.0:\n  bogus: 1\n",
                     "profile.8: {}\n",
                     "profile.0:\n  runs:\n    - start: [0, 0]\n"
                       "      dir: right\n      signals: [0]\n"
                       "      bogus: 1\n",
                     "profile.0:\n  runs:\n    - start: [0, 0]\n"
                       "      dir: right\n"
                       "      signals: [{sig: 1, extra: 2}]\n",
                     "layout: {rows: 1, cols: 256, bogus: 1}\n",
                     "defaults: {on: red, bogus: 1}\n",
                     "signals:\n  A: [0]\n  1X: [1]\n"):
            with self.subTest(text=text):
                with self.assertRaises(fp.ConfigError):
                    build_yaml(text)

    def test_bad_signal_name(self):
        with self.assertRaises(fp.ConfigError):
            build_yaml("signals:\n  2X: [1]\n")


class BooleanKeyTrap(unittest.TestCase):
    def test_on_off_keys_stay_strings(self):
        cfg = conf("defaults:\n  on: red\n  off: black\n"
                   "profile.0:\n  on: teal\n  runs:\n"
                   "    - start: [0, 0]\n      dir: right\n"
                   "      on: gold\n      signals:\n"
                   "        - {sig: 0, on: white, off: black}\n")
        self.assertIn("on", cfg["defaults"])
        self.assertEqual(cfg["profile.0"]["runs"][0]["signals"][0]["on"],
                         "white")
        # true/false are still booleans
        cfg = conf("layout:\n  rows: 2\n  cols: 128\n  serpentine: true\n")
        self.assertIs(cfg["layout"]["serpentine"], True)


class Toml(unittest.TestCase):
    def test_extension_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "c.toml")
            open(path, "w").write("on = \"red\"\n")
            with self.assertRaises(fp.ConfigError) as cm:
                fp.load_config(path)
            self.assertIn("TOML input was retired", str(cm.exception))

    def test_content_sniffed(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "c.yaml")
            with open(path, "w") as f:
                f.write("[profile.0.matrix]\ncols = 16\nrows = 16\n")
            with self.assertRaises(fp.ConfigError) as cm:
                fp.load_config(path)
            self.assertIn("rewrite it as YAML", str(cm.exception))

    def test_yaml_not_sniffed(self):
        cfg = conf("signals:\n  A: [1]\n")
        self.assertIn("signals", cfg)


class EncodeDecode(unittest.TestCase):
    def test_header_size_and_first_record(self):
        p, w, e = build_yaml("profile.0:\n  runs: []\n")
        data = fp.encode(p, 256)
        self.assertEqual(len(data), 16400)
        self.assertEqual(data[:16], b"FPPF\x02\x08\x00\x01" + bytes(8))

    def test_roundtrip_large_maps(self):
        p, _, e = build_yaml(
            "chain_bits: 1024\n"
            "profile.1:\n  runs:\n    - start: [0, 0]\n"
            "      dir: right\n      signals: [\"1023\", \"260\", \"511\"]\n",
            1024)
        self.assertEqual(e, [])
        data = fp.encode(p, 256)
        again = fp.decode(data)
        self.assertEqual(again[1]["map"][:3], [1023, 260, 511])
        o = 16 + (1 * 256 + 0) * 8
        self.assertEqual(data[o:o + 2], bytes([0xFF, 0x03]))

    def test_unspecified_profiles_are_identity(self):
        p, _, _ = build_yaml("profile.2:\n  runs: []\n"
                            "profile.7:\n  on: red\n  runs: []\n")
        for n in (0, 1, 3, 4, 5, 6):
            self.assertEqual(p[n]["map"], list(range(256)))
            self.assertEqual(set(p[n]["on"]), {fp.DEFAULT_ON})
            self.assertEqual(set(p[n]["off"]), {fp.DEFAULT_OFF})

    def test_defaults_apply_to_identity_profiles(self):
        p, _, _ = build_yaml("defaults: {on: '00FF00', off: [1, 1, 1]}\n")
        self.assertEqual(p[0]["on"][5], (0, 255, 0))
        self.assertEqual(p[0]["off"][5], (1, 1, 1))

    def test_decode_v1(self):
        v1 = bytearray(b"FPPF\x01\x08\x00\x01" + bytes(8))
        for _ in range(8):
            for i in range(256):
                v1 += bytes([i, 1, 2, 3, 4, 5, 6])
        profiles = fp.decode(bytes(v1))
        self.assertEqual(profiles[3]["map"], list(range(256)))
        self.assertEqual(profiles[3]["on"][9], (1, 2, 3))

    def test_decode_rejects_bad_files(self):
        good = fp.encode(fp.build_profiles({})[0], 256)
        for bad in (good[:-1], b"XPPF" + good[4:], b""):
            with self.subTest(n=len(bad)):
                with self.assertRaises(fp.ConfigError):
                    fp.decode(bad)

    def test_leds_key_changes_file_size(self):
        p, _, e = build_yaml("leds: 128\nlayout: {rows: 8, cols: 16}\n")
        self.assertEqual(e, [])
        data = fp.encode(p, 128)
        self.assertEqual(len(data), 16 + 8 * 128 * 8)
        self.assertEqual(fp.decode(data), p)


class DumpAndWarnings(unittest.TestCase):
    def test_compact_chain_canonical(self):
        self.assertEqual(fp.compact_chain([8, 9, 10, 11, 12]), ["8..12"])
        self.assertEqual(fp.compact_chain([12, 11, 10, 9]), ["12..9"])
        self.assertEqual(fp.compact_chain([64, 96, 128, 160]),
                         ["64", "96", "128", "160"])
        self.assertEqual(fp.compact_chain([1, 2, 3, 9]),
                         ["1", "2", "3", "9"])

    def test_unused_symbol_and_colour_warnings(self):
        _, w, e = build_yaml(
            "colors:\n  myred: '#FF1111'\n"
            "signals:\n  USED: [0]\n  UNUSED: [1]\n"
            "profile.0:\n  runs:\n    - start: [0, 0]\n"
            "      dir: right\n      signals: [USED]\n")
        self.assertEqual(e, [])
        self.assertEqual(len(w), 2)
        self.assertTrue(any("UNUSED" in x for x in w))
        self.assertTrue(any("myred" in x for x in w))

    def test_nested_symbol_reference_counts_as_used(self):
        _, w, _ = build_yaml(
            "signals:\n  IX: [0]\n  PTRS: [IX]\n"
            "profile.0:\n  runs:\n    - start: [0, 0]\n"
            "      dir: right\n      signals: [PTRS]\n")
        self.assertEqual(w, [])

    def test_subset_reference_counts_as_used(self):
        _, w, _ = build_yaml(
            "signals:\n  A: [0, 1]\n"
            "profile.0:\n  runs:\n    - start: [0, 0]\n"
            "      dir: right\n      signals: [\"A[1..0]\"]\n")
        self.assertEqual(w, [])

    def test_colour_used_in_run_is_not_flagged(self):
        _, w, _ = build_yaml(
            "colors:\n  glow: '#FFAA00'\n"
            "profile.0:\n  runs:\n    - start: [0, 0]\n"
            "      dir: right\n      on: glow\n      signals: [0]\n")
        self.assertEqual(w, [])


class Cli(unittest.TestCase):
    CFG = ("layout: {rows: 2, cols: 128}\n"
           "signals:\n  A: [\"0..3\"]\n"
           "profile.0:\n  runs:\n    - start: [0, 0]\n"
           "      dir: right\n      signals: [A]\n")

    def test_build_dump_and_default_file(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = os.path.join(d, "c.yaml")
            out = os.path.join(d, "o.fpp")
            with open(cfg, "w") as f:
                f.write(self.CFG)
            self.assertEqual(fp.main([cfg, "-o", out]), 0)
            self.assertEqual(os.path.getsize(out), 16400)
            self.assertEqual(fp.main(["--dump", out]), 0)
            default = os.path.join(d, "d.fpp")
            self.assertEqual(fp.main(["-o", default]), 0)
            self.assertEqual(fp.decode(open(default, "rb").read()),
                             fp.build_profiles({})[0])

    def test_error_leaves_no_output(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = os.path.join(d, "c.yaml")
            out = os.path.join(d, "o.fpp")
            with open(cfg, "w") as f:
                f.write("layout: {rows: 3, cols: 3}\n")
            self.assertEqual(fp.main([cfg, "-o", out]), 1)
            self.assertFalse(os.path.exists(out))

    def test_strict_rejects_warnings(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = os.path.join(d, "c.yaml")
            out = os.path.join(d, "o.fpp")
            with open(cfg, "w") as f:
                f.write("signals:\n  X: [1]\n")
            self.assertEqual(fp.main([cfg, "-o", out]), 0)
            self.assertEqual(fp.main([cfg, "-o", out, "--strict"]), 1)

    def test_deterministic_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = os.path.join(d, "c.yaml")
            with open(cfg, "w") as f:
                f.write(self.CFG)
            a, b = (os.path.join(d, n) for n in ("a.fpp", "b.fpp"))
            fp.main([cfg, "-o", a])
            fp.main([cfg, "-o", b])
            self.assertEqual(open(a, "rb").read(), open(b, "rb").read())


if __name__ == "__main__":
    unittest.main()
