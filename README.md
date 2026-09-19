# brother-mac-driver

An open-source, native macOS printer driver for Brother laser printers that Brother no longer
(or never) supported on current macOS — starting with the **MFC-9330CDW** colour family and the
**HL-2140** mono family.

Written in Swift. Targets Apple Silicon Macs running macOS 26 or later.

> **Status: early development.** Nothing here prints yet.

## How it works

The driver is a classic CUPS driver: a PPD file per model plus one raster filter.

```
app → PDF → cgpdftoraster (macOS) → rastertobrother (this project) → USB / network backend
```

| Target | Role |
|---|---|
| `BrotherPDL` | Pure-Swift encoders for the printer languages (PCL XL for the colour models, Brother's mono raster format for the HL-2140 family). No CUPS dependency. |
| `rastertobrother` | The CUPS filter: reads CUPS raster, writes printer data. |
| `pxltool` | Developer tool for dumping, rendering and generating print streams. |
| `CCUPS` | Module map for the `libcups` that ships with macOS. |

## Building

```sh
swift build -c release
swift test
scripts/smoke-test.sh
```

Requires Xcode 26 or later.

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE).

This project is not affiliated with or endorsed by Brother Industries, Ltd.
