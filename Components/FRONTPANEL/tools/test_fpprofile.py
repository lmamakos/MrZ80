#!/usr/bin/env python3
"""Unit tests for fpprofile.py.  Run: python3 -m unittest -v test_fpprofile
(from this directory) or python3 test_fpprofile.py."""

import os
import tempfile
import unittest

import fpprofile as fp


def build(cfg, force=False):
    return fp.build_profiles(cfg, force)


class MatrixOrder(unittest.TestCase):
    def test_row_major_plain(self):
        self.assertEqual(fp.matrix_order(2, 3, "top-left", "row", False),
                         [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2)])

    def test_row_major_serpentine(self):
        self.assertEqual(fp.matrix_order(2, 3, "top-left", "row", True),
                         [(0, 0), (0, 1), (0, 2), (1, 2), (1, 1), (1, 0)])

    def test_column_major_plain(self):
        self.assertEqual(fp.matrix_order(2, 3, "top-left", "column", False),
                         [(0, 0), (1, 0), (0, 1), (1, 1), (0, 2), (1, 2)])

    def test_column_major_serpentine(self):
        self.assertEqual(fp.matrix_order(2, 3, "top-left", "column", True),
                         [(0, 0), (1, 0), (1, 1), (0, 1), (0, 2), (1, 2)])

    def test_origins(self):
        self.assertEqual(fp.matrix_order(2, 2, "bottom-right", "row", False),
                         [(1, 1), (1, 0), (0, 1), (0, 0)])
        self.assertEqual(fp.matrix_order(2, 2, "top-right", "column", True),
                         [(0, 1), (1, 1), (1, 0), (0, 0)])
        self.assertEqual(fp.matrix_order(2, 2, "bottom-left", "row", True),
                         [(1, 0), (1, 1), (0, 1), (0, 0)])

    def test_all_orders_are_permutations(self):
        for o in fp.CORNERS:
            for m in ("row", "column"):
                for s in (False, True):
                    cells = fp.matrix_order(4, 5, o, m, s)
                    self.assertEqual(len(set(cells)), 20)

    def test_bad_args(self):
        with self.assertRaises(fp.ConfigError):
            fp.matrix_order(2, 2, "middle", "row", False)
        with self.assertRaises(fp.ConfigError):
            fp.matrix_order(2, 2, "top-left", "diagonal", False)


class MatrixMap(unittest.TestCase):
    def test_same_wiring_is_identity(self):
        t = ("top-left", "row", True)
        self.assertEqual(fp.matrix_map(16, 16, t, t), list(range(256)))

    def test_serpentine_strip_on_row_chain(self):
        # 2x3: chain = row-major positions 0..5; strip = serpentine rows
        m = fp.matrix_map(2, 3, ("top-left", "row", False), ("top-left", "row", True))
        self.assertEqual(m, [0, 1, 2, 5, 4, 3])

    def test_column_strip_on_row_chain(self):
        # 2x3 cells: chain pos = r*3+c; strip walks columns top-left
        m = fp.matrix_map(2, 3, ("top-left", "row", False), ("top-left", "column", False))
        self.assertEqual(m, [0, 3, 1, 4, 2, 5])


class Build(unittest.TestCase):
    def test_all_defaults(self):
        profiles, w, e = build({})
        self.assertEqual((w, e), ([], []))
        self.assertEqual(len(profiles), 8)
        for p in profiles:
            self.assertEqual(p["map"], list(range(256)))
            self.assertEqual(set(p["on"]), {fp.DEFAULT_ON})
            self.assertEqual(set(p["off"]), {fp.DEFAULT_OFF})

    def test_file_size_and_header(self):
        profiles, _, _ = build({})
        data = fp.encode(profiles)
        self.assertEqual(len(data), 14352)
        self.assertEqual(data[:16], b"FPPF\x01\x08\x00\x01" + bytes(8))
        # record 0: identity map, on FF0001, off 000009
        self.assertEqual(data[16:23], bytes([0, 0xFF, 0x00, 0x01, 0x00, 0x00, 0x09]))
        # record 255 of profile 7
        o = 16 + (7 * 256 + 255) * 7
        self.assertEqual(data[o:o + 7], bytes([255, 0xFF, 0x00, 0x01, 0x00, 0x00, 0x09]))

    def test_roundtrip(self):
        profiles, _, _ = build({"profile": {"3": {"on": "#102030", "map": list(reversed(range(256)))}}})
        again = fp.decode(fp.encode(profiles))
        self.assertEqual(again, profiles)
        self.assertEqual(again[3]["map"][0], 255)
        self.assertEqual(again[3]["on"][0], (0x10, 0x20, 0x30))
        self.assertEqual(again[2]["map"][0], 0)

    def test_matrix_16x16_ok(self):
        cfg = {"profile": {"1": {"matrix": {"cols": 16, "rows": 16, "strip_serpentine": True}}}}
        profiles, w, e = build(cfg)
        self.assertEqual((w, e), ([], []))
        m = profiles[1]["map"]
        self.assertEqual(m[:17], list(range(16)) + [31])
        self.assertEqual(sorted(m), list(range(256)))

    def test_matrix_wrong_count_is_error(self):
        cfg = {"profile": {"1": {"matrix": {"cols": 10, "rows": 10}}}}
        _, w, e = build(cfg)
        self.assertTrue(e)
        self.assertIn("100 LEDs", e[0])

    def test_matrix_wrong_count_force(self):
        cfg = {"profile": {"1": {"matrix": {"cols": 10, "rows": 10}}}}
        profiles, w, e = build(cfg, force=True)
        self.assertEqual(e, [])
        self.assertTrue(w)
        m = profiles[1]["map"]
        self.assertEqual(len(m), 256)
        self.assertEqual(m[100:], list(range(100, 256)))

    def test_matrix_oversize_force(self):
        cfg = {"profile": {"0": {"matrix": {"cols": 20, "rows": 20}}}}
        profiles, w, e = build(cfg, force=True)
        self.assertEqual(e, [])
        self.assertTrue(all(0 <= v < 256 for v in profiles[0]["map"]))

    def test_map_list_wrong_length(self):
        _, _, e = build({"profile": {"0": {"map": [0, 1, 2]}}})
        self.assertTrue(e)
        _, _, e = build({"profile": {"0": {"map": [0, 1, 2]}}}, force=True)
        self.assertEqual(e, [])

    def test_map_out_of_range(self):
        m = list(range(256))
        m[10] = 300
        _, _, e = build({"profile": {"0": {"map": m}}})
        self.assertTrue(any("out of range" in x for x in e))

    def test_duplicate_map_warns(self):
        m = list(range(256))
        m[10] = 11
        _, w, e = build({"profile": {"0": {"map": m}}})
        self.assertEqual(e, [])
        self.assertTrue(any("more than one LED" in x for x in w))

    def test_led_overrides(self):
        cfg = {"profile": {"2": {"on": "#112233", "led": [
            {"on": "#FFFFFF"}, {"index": 9, "map": 200, "off": [1, 2, 3]}]}}}
        profiles, w, e = build(cfg)
        self.assertEqual(e, [])
        p = profiles[2]
        self.assertEqual(p["on"][0], (255, 255, 255))
        self.assertEqual(p["on"][1], (0x11, 0x22, 0x33))
        self.assertEqual(p["map"][9], 200)
        self.assertEqual(p["off"][9], (1, 2, 3))

    def test_defaults_table(self):
        profiles, _, _ = build({"defaults": {"on": "00FF00", "off": [1, 1, 1]},
                                "profile": {"4": {"off": "#000000"}}})
        self.assertEqual(profiles[0]["on"][5], (0, 255, 0))
        self.assertEqual(profiles[0]["off"][5], (1, 1, 1))
        self.assertEqual(profiles[4]["off"][5], (0, 0, 0))

    def test_bad_input(self):
        for cfg in ({"profile": {"8": {}}},
                    {"profile": {"0": {"bogus": 1}}},
                    {"profile": {"0": {"on": "#12345"}}},
                    {"profile": {"0": {"on": [1, 2, 300]}}},
                    {"profile": {"0": {"map": [0], "matrix": {"cols": 1, "rows": 1}}}},
                    {"profile": {"0": {"led": [{"index": 256}]}}},
                    {"profile": {"0": {"matrix": {"rows": 4}}}},
                    {"nonsense": 1}):
            with self.subTest(cfg=cfg):
                with self.assertRaises(fp.ConfigError):
                    build(cfg)

    def test_decode_rejects_bad_files(self):
        profiles, _, _ = build({})
        good = fp.encode(profiles)
        with self.assertRaises(fp.ConfigError):
            fp.decode(good[:-1])
        with self.assertRaises(fp.ConfigError):
            fp.decode(b"XPPF" + good[4:])


class Cli(unittest.TestCase):
    def test_cli_roundtrip_and_refusal(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = os.path.join(d, "c.toml")
            out = os.path.join(d, "o.fpp")
            with open(cfg, "w") as f:
                f.write("[profile.1.matrix]\ncols = 10\nrows = 10\n")
            self.assertEqual(fp.main([cfg, "-o", out]), 1)
            self.assertFalse(os.path.exists(out))
            self.assertEqual(fp.main([cfg, "-o", out, "--force"]), 0)
            self.assertEqual(os.path.getsize(out), 14352)
            self.assertEqual(fp.main([cfg, "-o", out, "--force", "--strict"]), 1)
            self.assertEqual(fp.main(["--dump", out]), 0)

    def test_cli_default_file(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "o.fpp")
            self.assertEqual(fp.main(["-o", out]), 0)
            with open(out, "rb") as f:
                self.assertEqual(f.read(), fp.encode(build({})[0]))


if __name__ == "__main__":
    unittest.main()
