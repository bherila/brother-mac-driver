# Protocol notes

What is known about how these printers are driven, and where each fact came from. Anything not
yet confirmed on hardware says so.

## Languages by model

| Family | Models | Languages |
|---|---|---|
| Colour LED, PCL-capable | MFC-9330CDW, MFC-9340CDW, HL-3170CDW | PCL 6 (PCL XL), BR-Script3, XL2HB |
| Colour LED, host-based only | HL-3140CW, HL-3150CDW, MFC-9130CW, … | XL2HB |
| Mono laser, host-based | HL-2140 and relatives | Brother's PJL-wrapped compressed 1-bit raster (documented by the brlaser project) |

Only the MFC-9330CDW row has been checked against Brother's published specification; the
grouping of the other models is from memory of Brother's line-up and needs confirming. The
authoritative answer for a given unit is the `CMD:` field of its IEEE-1284 device ID
(`lpinfo -l -v`).

This driver sends PCL XL to the first family and the mono format to the third. XL2HB is not implemented.

## PJL, as sent by Brother's own Linux filter

Observed as string constants in Brother's Linux LPR filter for the MFC-9330CDW. Lines end with a
bare LF. The job opens with `ESC %-12345X` followed by `@PJL ` (with a trailing space) on a line of
its own.

| Line | Values seen |
|---|---|
| `@PJL SET ECONOMODE=` | `ON`, `OFF` (toner save) |
| `@PJL SET RESOLUTION=` | `600` |
| `@PJL SET RENDERMODE=` | `COLOR`, `GRAYSCALE` |
| `@PJL SET SOURCETRAY=` | `AUTO`, `TRAY1`, `TRAY2` |
| `@PJL SET COLORADAPT=` | not determined |
| `@PJL SET LESSPAPERCURL=` / `FIXINTENSITYUP=` | "improve print output" options |
| `@PJL SET PAGEPROTECT=` | `AUTO` |
| `@PJL SET APTMODE=` | `ON4`, `OFF` — appears tied to the 2400-dpi-class "Fine" mode |
| `@PJL SET IMPROVEGRAY=` / `UCRGCRFORIMAGE=` | `ON`, `OFF` |
| `@PJL SET RET=` | `LIGHT`, `MEDIUM`, `DARK` |
| `@PJL SET MANUALDPX=ON` | manual duplex |
| `@PJL SET JOBTIME = "YYYYMMDDhhmmss"` | |
| `@PJL SET AUTOSLEEP = ON`, `@PJL SET TIMEOUTSLEEP = <n>` (also as `DEFAULT`) | |
| `@PJL ENTER LANGUAGE=XL2HB` | |

**Unconfirmed:** these were sent ahead of XL2HB. Whether the firmware accepts each of them ahead
of `ENTER LANGUAGE=PCLXL` has to be checked on hardware (`@PJL INFO VARIABLES` lists what it
knows). The driver therefore sends only `ECONOMODE`, `RESOLUTION`, `RENDERMODE` and `SOURCETRAY`,
and can switch all of them off together.

## XL2HB (not implemented)

- Stream header is `) BROTHER XL2HB;…` — the shape of a PCL XL stream header with a different
  name, so the body is probably a PCL XL-style tagged binary stream.
- The host does colour conversion and halftoning. The Linux filter ships per-plane dither tables
  for C, M, Y and K, in normal and toner-save variants, for a 600 dpi mode and a "CAPT"
  (2400-dpi-class) mode, plus colour-matching tables named `Match Monitor`, `Vivid` and `None`.
- Media type is carried inside the stream, not in PJL: `dRegular`, `dThin`, `dThick`, `dThick2`,
  `dBond`, `dRecycled`, `dEnvelopes`, `dEnvthin`, `dEnvthick`, `dPostcard`, `dLabel`, `dGlossy`,
  `dTransparency`.
- The Linux filter is a self-contained i386 executable (libc and libm only) that reads a PPM
  stream and writes the job, which makes it usable as a byte-exact reference under emulation.

## PCL XL, as emitted by this driver

Raster only: little-endian binding, protocol class 2.0 (2.1 when DeltaRow is selected), 600 units
per inch so user units are device pixels, origin at the physical page corner. Each page is a stack
of 8-bit direct-pixel images (gray or RGB), one per 128-row band, cropped to the ink they contain.

Details that are easy to get wrong:

- Uncompressed and RLE image rows are padded with zero bytes to a multiple of 4. DeltaRow rows are
  not padded; each is prefixed with a 2-byte little-endian byte count, and the seed row is zeros at
  the start of every ReadImage block.
- MediaSize code 12 ("eB5Envelope") is ISO B5, 176 × 250 mm. Code 13 ("eB5Paper") is JIS B5 again.
- A page's gray-or-colour decision is made once for the whole page. Mixing gray and RGB images on
  one page risks a visible seam where neutral content changes from black toner to composite black.

**Unconfirmed on hardware:** which protocol class Brother's emulation accepts, whether custom
media sizes are honoured, MediaSource codes for the trays, and duplex back-side orientation.

## Brother's host-based mono format (HL-2140 family)

Worked out by the [brlaser](https://github.com/pdewacht/brlaser) project (GPL-2.0-or-later), whose
encoder this driver's `BrotherMonoLine` / `BrotherMonoBackend` are a Swift port of. The device ID
calls the language `HBP`.

**Job.** 128 NUL bytes, then `ESC %-12345X@PJL` and `@PJL JOB NAME="…"`. Before the first page (and
again whenever a setting changes) a page header: `ESC %-12345X@PJL`, then `SET RAS1200MODE = FALSE`,
`SET RESOLUTION = 600`, `SET ECONOMODE = ON|OFF`, `SET SOURCETRAY = AUTO|T1|T2|MANUAL`,
`SET MEDIATYPE = PLAIN`, `SET PAPER = LETTER|A4|…`, `SET PAGEPROTECT = AUTO`,
`SET ORIENTATION = PORTRAIT`, `ENTER LANGUAGE = PCL`; then `ESC E`, `ESC &l1X` (one copy) and, for
duplex models, `ESC &l2S`. The job ends with `ESC %-12345X@PJL`, `@PJL EOJ NAME="…"`,
`ESC %-12345X` and a newline. Note the spaces around `=`, unlike the colour models' PJL.

**Page.** PCL is only an envelope: `ESC *b1030m`, then blocks, then `1030M` and a form feed. A block
is `<n>w`, a zero byte, a line-count byte, and the encoded lines; `n` counts the two bytes after the
`w` as well as the line data. brlaser keeps a block's line data under 16350 bytes and starts a new
block every 64 lines; Brother's own driver is said to use 128.

**Line.** 1 bit per pixel, 1 = black. A line is either the single byte `0xFF` (entirely white) or an
edit count (at most 254) followed by that many edits, applied left to right against the previous
line; each edit starts `offset` bytes after the end of the previous one:

- substitute, `0b0ooooccc`: replace `c + 1` bytes with the literal bytes that follow;
- repeat, `0b1oonnnnn`: replace `n + 2` bytes with the single byte that follows.

A field at its maximum (15 / 7 for substitute, 3 / 31 for repeat) is extended by overflow bytes,
each added to the field, continuing while the byte is 255; offset overflow comes before count
overflow. The first line of a block is sent as one substitute covering the whole line, so a block
never depends on the one before it.

**Raster.** The printer places the raster at the top-left of its printable area. brlaser's margins
are 8 pt left, right and bottom and 16 pt top, and this driver uses the same; US Letter therefore
arrives from the macOS rasteriser as 4967 × 6400 pixels at 600 dpi.

**Unconfirmed on hardware with this driver:** everything. brlaser's users have run this format on
the HL-2140 for years, but this port has only been checked by decoding its own output.

## Page geometry

Brother's Linux driver uses a 12 pt (4.23 mm) unprintable margin on every edge of every size, and
renders at 600 dpi. One exception in Brother's PPD: the "DL Long Edge" envelope has 18 pt left and
right margins.
