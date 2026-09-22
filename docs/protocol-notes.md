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

Everything below was read out of Brother's own Linux filter for the HL-3140CW, by running it and
decoding what it produced. `scripts/xl2hb-reference.sh` reproduces any of it: it fetches the
driver package (checksum-pinned, nothing of Brother's is kept in this repository), runs a PPM
through the filter and blanks the `JOBTIME` line, which is the only part of the output that is not
a function of the input. Two runs of the same page are then byte-identical, so the filter answers
"what should these pixels encode to" exactly. It is a 32-bit x86 binary needing only libc and
libm, so it runs on a Linux x86 host with the 32-bit loader installed, or under `qemu-i386-static`.

**The body is PCL XL's tag encoding.** Not merely "PCL XL-shaped": the same data tags, the same
`0xF8` attribute prefix, the same attribute numbers and the same operator codes. `PCLXLReader`
parses a Brother XL2HB job end to end with no changes, and `pxltool dump` disassembles one. The
stream header is `) BROTHER XL2HB;1;0` — protocol class 1.0, where this driver's PCL XL is 2.0.

A single-page job from the filter decodes to:

```
BeginSession    Measure=inch UnitsPerMeasure=[600, 600]
OpenDataSource  SourceType=default DataOrg=binaryLowByteFirst
BeginPage       Orientation=0 MediaSource=1 MediaSize=0 MediaType="dRegular" SimplexPageMode=0
SetPageOrigin   attr42=[100, 100]
BeginImage      ColorMapping=0 ColorDepth=0 SourceWidth=4928 SourceHeight=6400
                DestinationSize=[4928, 6400] CommentData=[…] PageCopies=0
ReadImage       StartLine=… BlockHeight=… CompressMode=1 CommentData=<plane> data=…
…
EndImage / EndPage / CloseDataSource / EndSession
```

- `ColorDepth=0` is 1 bit per pixel, so the planes arrive already halftoned — the host does the
  colour conversion and the screening, which is what the per-plane dither tables in the package
  are for (C, M, Y, K, in normal and toner-save variants, for a 600 dpi and a "CAPT" 2400-dpi-class
  mode, plus colour-matching tables named `Match Monitor`, `Vivid` and `None`).
### What was run

Seven synthetic pages, 600 × 400 px, through the pinned filter. Every figure below comes from
these; `scripts/xl2hb-reference.sh --manifest` prints the identity of what it executes, and the
runs were byte-identical when repeated against a freshly extracted copy of the package.

| | |
|---|---|
| package | `hl3140cwlpr-1.1.2-1.i386.deb`, sha256 `601f392b…` |
| filter binary | sha256 `51157a28…` |
| `paperinfij2` | sha256 `71fd58ef…` |
| `brhl3140cwrc` | sha256 `90803f6e…` |

### Observed

`CommentData` on `ReadImage` carries a small integer that tracks which colourant the block
contains. Each page below is a flat colour, and each row gives the blocks in the order sent, as
(plane, `StartLine`, `BlockHeight`):

| Page | Blocks | Planes present |
|---|---|---|
| white | (0, 48, 2249) (0, 2297, 2249) (0, 4546, 1854) | 0 |
| black | (0, 0, 2249) (0, 2249, 2249) (0, 4498, 1902) | 0 |
| cyan | (1, 0, 49) (0, 48, 2249) (0, 2297, 2249) (0, 4546, 1854) | 1, 0 |
| magenta | as cyan, with plane 2 | 2, 0 |
| yellow | as cyan, with plane 3 | 3, 0 |
| red | (3, 0, 44) (2, 0, 49) (3, 44, 5) (0, 48, 2249) … | 3, 2, 0 |

Three things follow directly, and two of them correct what this file said before:

- **Plane 0 is sent on every page, including a blank one.** A pure white page still carries three
  plane-0 blocks. So "planes with no ink are not sent" is true of planes 1–3 and false of plane 0.
- **`CommentData` on `BeginImage` is the same array on all seven pages**, flat white to red:
  `[0, 3, 1, 1, 5, 0, 4, 1034, 1, 5, 1, 4, 532, 1, 5, 2, 4, 532, 1, 5, 3, 4, 1034]`. It therefore
  does not describe which planes follow, which is what this file previously guessed. Its shape is
  four per-plane entries whose last field is 1034, 532, 532, 1034 for planes 0, 1, 2, 3 — matching
  the plane order, but what the numbers are is not established.
- **Blocks of different planes interleave, and each plane keeps its own `StartLine`.** Red sends
  plane 3, then plane 2, then plane 3 again continuing from line 44. Row accounting is per plane,
  not per image.

`StartLine` also skips leading rows with nothing on them: black starts at 0 and every other page
at 48, so per-plane row totals differ between pages (6400 for black, 6352 for the rest).

### Interpreted

**0 = K, 1 = C, 2 = M, 3 = Y** is an inference from these pages, not something the format states:
a cyan page adds plane 1, magenta plane 2, yellow plane 3, and red — which is magenta plus yellow —
adds exactly 2 and 3. It is consistent across every page tried and it matches the order of the
per-plane entries in `BeginImage`'s `CommentData`, but it rests on one model's filter and on flat
synthetic colours. A page mixing colourants in known proportions, decoded back to pixels, would
settle it properly.

- `SetPageOrigin` carries **attribute 42, which is `PageOrigin`** — the operator's own operand in
  HP's schema, not a Brother extension. It is [100, 100]: 100 units at 600 per inch is the 12 pt
  unprintable margin documented below. (Reading this as `Point`, attribute 76, is a mistake this
  repository made in `PCLXLValidator` until the owner's review caught it.)
- `MediaType` travels inside the stream as a `ubyteArray` string, not in PJL: `dRegular`, `dThin`,
  `dThick`, `dThick2`, `dBond`, `dRecycled`, `dEnvelopes`, `dEnvthin`, `dEnvthick`, `dPostcard`,
  `dLabel`, `dGlossy`, `dTransparency`.
- `CompressMode=1` is RLE, the same compression this driver already encodes and decodes for PCL XL.

**What this means for implementing it:** the framing, the tag writer, the RLE encoder and the
reader are all already in `BrotherPDL` and appear to apply unchanged. What is genuinely new is the
colour path — RGB to CMYK, then halftoning against Brother's dither tables — and the meaning of
`BeginImage`'s `CommentData`.

**Not established:** what the 1034/532 figures are; how `StartLine` is chosen; whether the plane
order is required or incidental; and whether any of it is what the firmware wants. Agreeing with
Brother's encoder is much better evidence than agreeing with our own decoder, and it is still not
a printer accepting a page.

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

The rules above are encoded in `PCLXLValidator`, which `pxltool check` runs over a finished job:
attribute data types and ranges per operator, session/page/image nesting, protocol class against
the compression used, image row accounting, and whether the images fit the sheet.
`BrotherMonoValidator` does the same for the mono format's PJL, PCL envelope and block framing.

What it reports is of three kinds, and they are not interchangeable:

- **protocol** — the job breaks the language, so a printer may answer
  `PCL XL error … Operator: … Position: …` and print nothing.
- **policy** — legal, and not what this driver means to emit. An image reaching past the sheet is
  the clearest case: PCL XL clips painting to the clipping region rather than refusing the job, so
  the printer prints the part that fits. It is still a bug here, because every image this driver
  places should land on the paper.
- **coverage** — a check that was not made, because the job used something the validator does not
  model. A claim about the validator, not about the job.

`pxltool check` fails on the first by default, on the first two with `--fail-on policy` (what CI
uses for jobs this driver wrote), and on all three with `--fail-on all`. Reporting all three as
"the printer will reject this" was this file's earlier claim and was too broad.

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
