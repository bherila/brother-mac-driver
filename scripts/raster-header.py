#!/usr/bin/env python3
"""Print the first page header of a CUPS raster file, one `field=value` per line.

usage: scripts/raster-header.py <raster-file>

This deliberately shares nothing with the driver: not the filter's reading of the header, not
`PageGeometry`, not the validator's width arithmetic. It exists so that what the rasteriser
produced can be recorded and compared against the driver's expectations as independent evidence
(bherila/brother-mac-driver#27). Field names are libcups's own, from `cups_page_header2_t`, and
the offsets were taken with `offsetof` against libcups's `<cups/raster.h>`.

The header of every raster version (1, 2 and 3) is stored uncompressed straight after the
4-byte sync word, whose spelling gives the byte order.
"""
import struct
import sys

HEADER_SIZE = 1796

SYNC = {
    b"RaSt": ">", b"RaS2": ">", b"RaS3": ">",
    b"tSaR": "<", b"2SaR": "<", b"3SaR": "<",
}

# name: (offset, struct code, count)
FIELDS = {
    "HWResolution": (276, "I", 2),
    "ImagingBoundingBox": (284, "I", 4),
    "Margins": (312, "I", 2),
    "PageSize": (352, "I", 2),
    "cupsWidth": (372, "I", 1),
    "cupsHeight": (376, "I", 1),
    "cupsBitsPerColor": (384, "I", 1),
    "cupsBitsPerPixel": (388, "I", 1),
    "cupsBytesPerLine": (392, "I", 1),
    "cupsColorOrder": (396, "I", 1),
    "cupsColorSpace": (400, "I", 1),
    "cupsPageSize": (428, "f", 2),
    "cupsImagingBBox": (436, "f", 4),
}
PAGE_SIZE_NAME = (1732, 64)


def number(value):
    # Floats are printed so that the same header always prints the same text: whole numbers
    # without a fraction, anything else to two places (the rasteriser works in points).
    if isinstance(value, float):
        return str(int(value)) if value == int(value) else f"{value:.2f}"
    return str(value)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[2])
    with open(sys.argv[1], "rb") as raster:
        sync = raster.read(4)
        header = raster.read(HEADER_SIZE)
    if sync not in SYNC:
        sys.exit(f"{sys.argv[1]}: not a CUPS raster (sync word {sync!r})")
    if len(header) != HEADER_SIZE:
        sys.exit(f"{sys.argv[1]}: header is {len(header)} bytes, expected {HEADER_SIZE}")
    order = SYNC[sync]
    for name, (offset, code, count) in FIELDS.items():
        values = struct.unpack_from(f"{order}{count}{code}", header, offset)
        print(f"{name}={','.join(number(v) for v in values)}")
    offset, length = PAGE_SIZE_NAME
    name = header[offset:offset + length].split(b"\0", 1)[0].decode("ascii", "replace")
    print(f"cupsPageSizeName={name}")


if __name__ == "__main__":
    main()
