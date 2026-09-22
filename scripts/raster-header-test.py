#!/usr/bin/env python3
"""Regression tests for scripts/raster-header.py.

usage: scripts/raster-header-test.py

The reader is the independent evidence behind the mono width fixture, so what matters most is that
it never prints something that is not a header field. The positive case is a real header, the first
1800 bytes of a raster written by Ghostscript's CUPS device; its values were confirmed with
libcups's cupsRasterReadHeader2 before it was checked in. The other byte order and version 2 are
derived from it. The refusals are built by hand, and the version 1 ones deliberately include a file
long enough to satisfy a 1796-byte read, with recognisable values planted in its pixel data — the
case that used to be misread silently.
"""
import os
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
READER = os.path.join(HERE, "raster-header.py")
REAL = os.path.join(HERE, "..", "Tests", "Fixtures", "raster", "letter-600dpi-v3-le.header")
HEADER_SIZE = 1796

# What libcups read from the real header.
EXPECTED = {
    "HWResolution": "600,600",
    "cupsWidth": "5100",
    "cupsHeight": "6600",
    "cupsBitsPerPixel": "1",
    "cupsBytesPerLine": "638",
    "cupsColorSpace": "3",
    "PageSize": "612,792",
    "cupsPageSize": "612,792",
}


def big_endian(little):
    """The same header with every 32-bit field byte-swapped. The char arrays — MediaClass through
    OutputType (bytes 0-255) and cupsString onwards (580-) — are not numbers and stay as they are."""
    sync, header = little[:4], little[4:4 + HEADER_SIZE]
    words = struct.unpack(f"<{HEADER_SIZE // 4}I", header)
    swapped = struct.pack(f">{HEADER_SIZE // 4}I", *words)
    header = header[:256] + swapped[256:580] + header[580:]
    return {b"3SaR": b"RaS3", b"2SaR": b"RaS2"}[sync] + header + little[4 + HEADER_SIZE:]


def run(data):
    with tempfile.NamedTemporaryFile(suffix=".ras", delete=False) as handle:
        handle.write(data)
        path = handle.name
    try:
        result = subprocess.run([sys.executable, READER, path], capture_output=True, text=True)
    finally:
        os.unlink(path)
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return result.returncode, fields, result.stderr


def version_1(sync, length):
    """A version 1 raster: a 420-byte header, then pixel data. Anything a reader finds at the
    version 2 offsets is pixels — so plant values there that no real header would carry."""
    order = "<" if sync == b"tSaR" else ">"
    header = bytearray(420)
    struct.pack_into(f"{order}2I", header, 276, 600, 600)
    pixels = bytearray(max(0, length - 4 - 420))
    if len(pixels) >= 1732 - 420 + 64:
        struct.pack_into(f"{order}2f", pixels, 428 - 420, 123.0, 456.0)
        pixels[1732 - 420:1732 - 420 + 19] = b"PIXELS_NOT_METADATA"
    return sync + bytes(header) + bytes(pixels)


class RasterHeaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(REAL, "rb") as handle:
            cls.real = handle.read()

    def test_a_real_version_3_header_reads_as_libcups_read_it(self):
        status, fields, _ = run(self.real)
        self.assertEqual(status, 0)
        for name, value in EXPECTED.items():
            self.assertEqual(fields.get(name), value, name)

    def test_the_other_byte_order_reads_identically(self):
        self.assertEqual(run(big_endian(self.real))[:2], run(self.real)[:2])

    def test_version_2_is_the_same_layout(self):
        self.assertEqual(run(b"2SaR" + self.real[4:])[:2], run(self.real)[:2])
        self.assertEqual(run(big_endian(b"2SaR" + self.real[4:]))[:2], run(self.real)[:2])

    def test_version_1_is_refused_however_long_it_is(self):
        for sync in (b"tSaR", b"RaSt"):
            for length in (4 + 420 + 100, 4 + 420 + 4000):
                status, fields, error = run(version_1(sync, length))
                label = f"{sync!r}, {length} bytes"
                self.assertNotEqual(status, 0, label)
                self.assertEqual(fields, {}, label)
                self.assertIn("version 1", error, label)

    def test_the_long_version_1_file_would_have_fooled_a_plain_read(self):
        # Guards the test above: the planted values really are where a 1796-byte read looks, so a
        # reader that ignored the version would have printed them.
        data = version_1(b"tSaR", 4 + 420 + 4000)
        self.assertGreaterEqual(len(data), 4 + HEADER_SIZE)
        self.assertEqual(data[4 + 1732:4 + 1732 + 19], b"PIXELS_NOT_METADATA")
        self.assertEqual(struct.unpack_from("<2f", data, 4 + 428), (123.0, 456.0))

    def test_anything_else_is_refused_without_output(self):
        cases = {
            "empty": b"",
            "unknown sync word": b"NOPE" + self.real[4:],
            "truncated header": self.real[:4 + 1000],
            "sync word only": self.real[:4],
        }
        for label, data in cases.items():
            status, fields, error = run(data)
            self.assertNotEqual(status, 0, label)
            self.assertEqual(fields, {}, label)
            self.assertTrue(error.strip(), label)


if __name__ == "__main__":
    unittest.main(verbosity=2)
