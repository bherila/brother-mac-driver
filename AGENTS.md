# Working on this repository

Notes for anyone — person or agent — making changes here. The README says what the driver is and
how to use it; this says how the work is done.

## The one thing to keep straight

**No page has ever come out of a real printer from this driver.** Everything is verified in
software: a PDF goes through the macOS rasteriser and this driver, and the output decodes back to
exactly the pixels that went in. That is a strong check and it is not the same as printing.

So: never write, in a commit message, a comment, the README or an issue, that something "works",
"is confirmed" or "is verified" on hardware. Say what was actually checked and how. Facts about
the printers' languages belong in [docs/protocol-notes.md](docs/protocol-notes.md), each with
where it came from, and anything unconfirmed says so there. `PrinterModel.verified` is false for
every model and stays false until a sheet with that model's name on it comes out of a printer.

[Issue #25](https://github.com/bherila/brother-mac-driver/issues/25) is the roadmap; the
`needs-hardware` label marks what cannot be settled from here.

## Layout

| Path | What lives there |
|---|---|
| `Sources/BrotherPDL` | The printer languages: PCL XL and Brother's host-based mono format, their readers, their validators, the PPD generator, the media table. Pure Swift, no CUPS, almost no Foundation — which is what makes it testable anywhere. |
| `Sources/rastertobrother` | The CUPS filter. CUPS raster in, printer bytes out. Everything CUPS-shaped lives here. |
| `Sources/pxltool` | Developer tool: `dump`, `render`, `compare`, `check`, `ppd`, `testpdf`, `usb-probe`, `usb-send`, `redact`. |
| `Sources/CCUPS`, `Sources/CCUPSShim` | The system `libcups` and C wrappers for its PPD API, which Swift cannot call directly. |
| `Sources/CUPSRaster` | Reading a CUPS raster header into a `PageGeometry`. Shared by the filter and `pxltool`, so the two cannot disagree about where on the sheet a page's pixels belong. |
| `scripts/` | Install, uninstall, package, and the checks below. |
| `docs/` | What is known about the printers, and the hardware-visit checklist. |

`BrotherPDL` must not gain a CUPS dependency, and the CUPS-facing targets must not grow encoding
logic. That split is what keeps the encoders unit-testable.

## Building and checking

```sh
swift build -c release
swift test                 # unit tests, no system dependencies
scripts/e2e-test.sh        # PDF → the system rasteriser → the filter → decode → pixel compare
scripts/make-visit-kit.sh  # builds the installer, the ready-made jobs, and checks every one
scripts/test-queue.sh      # after installing: print through the real print system into a listener
```

Needs macOS with Xcode 26 or later. CI runs all of it on `macos-26`, plus a second job that
installs the driver, prints through a real CUPS queue for every model PPD, and uninstalls again.

### Working on a machine without macOS

`BrotherPDL` and its tests are plain Swift, so they build and run on Linux even though the package
declares a macOS platform. Point a throwaway package at the same directories:

```sh
mkdir -p /tmp/shadow/Sources /tmp/shadow/Tests
ln -s "$PWD/Sources/BrotherPDL" /tmp/shadow/Sources/BrotherPDL
ln -s "$PWD/Tests/BrotherPDLTests" /tmp/shadow/Tests/BrotherPDLTests
cat > /tmp/shadow/Package.swift <<'EOF'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "shadow", targets: [
    .target(name: "BrotherPDL"),
    .testTarget(name: "BrotherPDLTests", dependencies: ["BrotherPDL"]),
])
EOF
(cd /tmp/shadow && swift test)
```

That covers the encoders, the readers, the validators, the media table and the PPD generator —
most of the code. It cannot build `rastertobrother` or `pxltool`, so changes to those are only
checked by CI, which is a reason to keep them thin. An older toolchain may need a slow-to-type-check
test file excluded; the package above is a scratch file, so exclude it there and never in the
repository's own `Package.swift`.

## What each check is for

- **`swift test`** — the encoders and everything around them, including the preflight validators.
- **`scripts/e2e-test.sh`** — the real macOS rasteriser and the real filter binary, then the output
  decoded and compared pixel for pixel with the raster that produced it. Also the failure paths: a
  raster that stops mid-page, a page the backend must refuse, a non-blocking stdout.
- **`pxltool check`** — the preflight: what a printer would reject in a finished job, which pixel
  comparison cannot see (attribute types, operator nesting, protocol class, PJL spellings, block
  framing, images falling off the sheet). Runs over every job the e2e test and the visit kit build.
- **`scripts/test-queue.sh`** — cupsd itself: the filter run the way CUPS runs it, the options a
  print dialog sets, and the bytes that reach the backend. `PPD_SOURCE=installed` builds the queue
  from the PPD the installer put in `/Library/Printers`, chosen by the model name cupsd indexed —
  the way System Settings does it — so the file under test is the one a user gets. CI runs every
  model that way.

A change to an encoder that no check notices is a change without evidence. Add the check.

`scripts/xl2hb-reference.sh` is not a check but a source of evidence: it runs Brother's own Linux
filter as a byte-exact reference for XL2HB ([#21](https://github.com/bherila/brother-mac-driver/issues/21)),
which is how the facts in `docs/protocol-notes.md` about that format were established. It needs a
Linux x86 host and so is deliberately outside CI.

## Conventions

- Comments say **why**, not what. A comment that restates the code is noise; one that records a
  constraint, a source, or a mistake not to repeat again is worth having.
- British spelling in prose and comments (colour, rasteriser, behaviour). Identifiers follow the
  platform: `colorSpace` is a PCL XL attribute name, not a spelling choice.
- Every magic number in the printer languages has a source, named in a comment or in
  `docs/protocol-notes.md`.
- Keep line length near 120 columns, the format the existing files use.
- The mono encoder is a port of [brlaser](https://github.com/pdewacht/brlaser) (GPL-2.0-or-later).
  The whole project is GPL-2.0-or-later because of it; keep the attribution intact.

## Review

Pull requests get an automatic security review, and a general code review on request:

- Comment **`@codex review`** on the pull request to ask for the code review. It has to be asked
  for each time; it does not run by itself.
- The security review runs automatically. It frequently fails with a **quota error** — that is
  expected, and it does not usually affect the code review. Do not treat a security review quota
  error as a problem with the change.
- The code review has a separate limit and can run out too, answering `@codex review` with "you
  have reached your Codex usage limits for code reviews" instead of findings. A review that cannot
  run is not a clean review: say so rather than reading the silence as approval, and leave the
  request standing until someone tops the account up.

Address review findings or say why not. The encoders in `Sources/BrotherPDL/PCLXL/` and
`Sources/BrotherPDL/Mono/` were merged before an external reviewer was connected to this
repository and have had one pass of local review only; a second pair of eyes on them is welcome
([#24](https://github.com/bherila/brother-mac-driver/issues/24)).

## Releasing

Set `driverVersion` in `Sources/BrotherPDL/PPDGenerator.swift`, merge, then push a tag `v<version>`.
The release workflow refuses a tag that disagrees with that version and opens a draft release.
