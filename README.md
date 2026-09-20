# brother-mac-driver

An open-source, native macOS printer driver for Brother laser printers that Brother no longer
(or never) supported on current macOS — starting with the **MFC-9330CDW** colour family and the
**HL-2140** mono family.

Written in Swift. Targets Apple Silicon Macs running macOS 26 or later.

> **Status: early development.** The whole software path works and is verified without hardware —
> a PDF goes through the macOS rasteriser and this driver, and the PCL XL that comes out decodes
> back to exactly the pixels that went in. **Nothing has been tested on a real printer yet.**

## Is my printer supported?

Plug the printer in over USB and run:

```sh
/Library/Printers/BrotherOSS/bin/pxltool usb-probe      # after installing
.build/release/pxltool usb-probe                        # from a checkout
```

It reads what the printer reports about itself (nothing is printed) and says whether this driver
can drive it. Serial numbers are left out of the output, so it is safe to paste into an issue.
`scripts/probe-printer.sh` gathers the same facts with only the tools that ship with macOS.

| Model | Language | Status |
|---|---|---|
| MFC-9330CDW | PCL XL | untested on hardware |
| MFC-9340CDW, HL-3170CDW | PCL XL | untested on hardware; added because Brother lists the same PCL 6 emulation |
| HL-2140 series | Brother host-based mono | untested on hardware |

Other Brother colour lasers that accept PCL XL (PCL 6) — the probe says so — should be easy to add.
Models that only accept Brother's host-based XL2HB language are not supported.

## Installing

From a checkout (builds, then asks for your password to copy into `/Library/Printers`):

```sh
scripts/install.sh
```

Or build an installer package with `scripts/make-pkg.sh`; CI attaches an unsigned one to every run
as the `brother-mac-driver-pkg` artifact. The package is not signed with an Apple Developer ID. If
macOS refuses it (it will if the file was downloaded at any point, even when it was copied on
afterwards), allow it once under System Settings →
Privacy & Security → "Open Anyway", or install it with
`sudo installer -pkg brother-mac-driver-*.pkg -target /`. Anyone with a Developer ID can produce a
signed, notarized package: `scripts/make-pkg.sh` takes `CODESIGN_IDENTITY`, `INSTALLER_IDENTITY`
and `NOTARY_PROFILE`.

Then add the printer in System Settings → Printers & Scanners. A supported model picks this driver
by itself; otherwise choose "Brother <model>, brother-mac-driver" under "Select Software…".

`scripts/uninstall.sh` removes everything the installer added.

## How it works

The driver is a classic CUPS driver: a PPD file per model plus one raster filter.

```
app → PDF → cgpdftoraster (macOS) → rastertobrother (this project) → USB / network backend
```

| Target | Role |
|---|---|
| `BrotherPDL` | Pure-Swift encoders for the printer languages (PCL XL, and Brother's host-based mono format as documented by the brlaser project), the PPD generator, and readers for both formats used to check the encoders. No CUPS dependency. |
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
scripts/test-queue.sh   # after installing: print through the real print system into a fake printer
```

`scripts/make-visit-kit.sh` builds what a first session with a real printer needs — the installer,
numbered ready-made jobs that each answer one question, a log collector and
[a checklist](docs/hardware-visit.md). `pxltool usb-send` sends such a job straight to a Brother
printer over USB, with no print queue involved, and shows what the printer says back.

`test-queue.sh` creates a temporary queue pointed at a listener on localhost, prints a calibration
page to it, and decodes what the print system actually sent. It needs the driver installed and an
administrator account, and removes the queue again when it finishes.

Requires Xcode 26 or later.

## Releasing

Set `driverVersion` in `Sources/BrotherPDL/PPDGenerator.swift`, merge, then push a tag `v<version>`.
The release workflow refuses a tag that disagrees with that version, runs the tests and the
end-to-end check, and opens a **draft** release with the unsigned package and the visit kit
attached. To ship a signed package instead, build it locally with `scripts/make-pkg.sh` and the
signing variables, and swap it into the draft before publishing.

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE).

The mono-laser line and block encoding is a Swift port of the encoder in
[brlaser](https://github.com/pdewacht/brlaser) (Copyright 2013 Peter De Wachter, GPL-2.0-or-later),
which worked the format out.

This project is not affiliated with or endorsed by Brother Industries, Ltd.
