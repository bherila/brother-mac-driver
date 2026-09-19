# brother-mac-driver

An open-source, native macOS printer driver for Brother laser printers that Brother no longer
(or never) supported on current macOS — starting with the **MFC-9330CDW** colour family and the
**HL-2140** mono family.

Written in Swift. Targets Apple Silicon Macs running macOS 26 or later.

> **Status: early development.** The whole software path works and is verified without hardware —
> a PDF goes through the macOS rasteriser and this driver, and the PCL XL that comes out decodes
> back to exactly the pixels that went in. **Nothing has been tested on a real printer yet**, and
> there is no installer yet.

## How it works

The driver is a classic CUPS driver: a PPD file per model plus one raster filter.

```
app → PDF → cgpdftoraster (macOS) → rastertobrother (this project) → USB / network backend
```

| Target | Role |
|---|---|
| `BrotherPDL` | Pure-Swift encoders for the printer languages (PCL XL today), the PPD generator, and a PCL XL reader used to check the encoder. No CUPS dependency. |
| `rastertobrother` | The CUPS filter: reads CUPS raster, writes printer data. |
| `pxltool` | Developer tool: `dump` and `render` a print job, `compare` a job against the raster it came from, generate the `ppd` files, and draw a calibration `testpdf`. |
| `CCUPS`, `CCUPSShim` | Module map for the `libcups` that ships with macOS, and C wrappers for its PPD API (which Swift cannot call directly). |

Colour pages are sent as RGB and neutral pages as grayscale, decided once per page, so black
text prints with black toner only. See [docs/protocol-notes.md](docs/protocol-notes.md) for what
is known about the printers' languages and what still needs confirming on hardware.

## Building and testing

```sh
swift build -c release
swift test
scripts/e2e-test.sh     # PDF → macOS rasteriser → filter → decode → pixel compare, plus cupstestppd
```

Requires Xcode 26 or later.

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE).

This project is not affiliated with or endorsed by Brother Industries, Ltd.
