# First session with a real printer

Everything here is built by `scripts/make-visit-kit.sh` into `build/visit-kit/`. The point is to
leave with every open question answered, because the printer may not be reachable again soon.
Work from the top; each step says what it decides. Write results into the table at the end.

You need: the Mac (Apple Silicon, macOS 26 or later), the printer on USB, plain Letter paper in the
tray, a ruler in millimetres, and a phone to photograph each sheet next to its job number.

Commands below are run in Terminal from inside the kit folder. `pxltool` is installed by the
package in step 1; the kit does not carry its own copy, because a program that arrives in a
downloaded zip is quarantined by macOS and would be refused.

```sh
alias pxltool=/Library/Printers/BrotherOSS/bin/pxltool
```

## 1. Install (prints nothing)

The package is not signed with an Apple Developer ID. macOS refuses such a package when the file
carries a quarantine mark, which anything downloaded (browser, AirDrop, Messages) gets — and the
mark survives unzipping and usually survives being copied on to a USB stick or a shared folder. So
a kit that was downloaded at any point should be expected to be refused once. To see:

```sh
xattr -p com.apple.quarantine brother-mac-driver-*.pkg    # prints a value if the file is marked
```

If it is refused: open System Settings → Privacy & Security, scroll to the message about the
package, choose "Open Anyway", and open it again. Or install it from Terminal, which is not expected
to apply that check (not yet tried on macOS 26; "Open Anyway" is the fallback):

```sh
sudo installer -pkg brother-mac-driver-*.pkg -target /
```

Either way it asks for an administrator password, and installs only into `/Library/Printers`.

## 2. What is this printer? (prints nothing)

```sh
pxltool usb-probe --pjl yes | tee probe.txt
```

- **"supported by this driver"** → carry on.
- **"accepts PCL XL … not in this driver's model list"** → carry on; note the exact `MDL:` text so a
  PPD can be added.
- **"not supported"** and `CMD:` shows only `XL2HB` (colour) → skip to step 6 and collect logs.
  This unit is host-based only, the PCL XL jobs below will print garbage or nothing, and the project
  needs the XL2HB work instead. Do not run the numbered colour jobs.
- The PJL replies list every setting the firmware knows (`INFO VARIABLES`). Keep `probe.txt`: it
  says which of `ECONOMODE`, `RENDERMODE`, `SOURCETRAY`, `RESOLUTION` exist, and their legal values.

## 3. Raw jobs, sent around the print system

These go straight to the printer over USB with no queue involved, so the only thing being tested
is whether the printer accepts the bytes. Pause or delete any existing queue for this printer
first, or the two will fight over the USB connection.

```sh
pxltool usb-send jobs/01-baseline.pxl
```

Each run ends by printing whatever the printer said back. **A PCL XL error arrives there as
text** (`PCL XL error … Operator: … Position: …`); copy it into the table.

| Job | What it is | What it decides |
|---|---|---|
| `01-baseline` | calibration page, RLE, Brother PJL settings sent | Does PCL XL print at all? |
| `02-without-brother-pjl` | same, without the Brother PJL settings | If 01 failed and 02 works, one of the PJL lines is rejected; step 2's `INFO VARIABLES` says which |
| `03-error-report-on` | same as 01, asks for a printed error sheet | Only if 01 and 02 both printed nothing: the sheet names the operator the printer choked on |
| `04-deltarow` | DeltaRow compression (protocol class 2.1) | Can the smaller compression become the default? |
| `05-neutral-page` | no colour anywhere, sent as grayscale | Is it printed with black toner only? Look at the gray ramp under a loupe or phone macro: coloured dots mean composite gray |
| `06-forced-black-and-white` | colour page with `RENDERMODE=GRAYSCALE` | Same question, for the Black & White option |
| `07-duplex-long-edge` | two pages, long-edge binding | Back page the right way up when turned like a book? |
| `08-duplex-short-edge` | two pages, short-edge binding | Back page the right way up when flipped like a notepad? |
| `09-tray-1` | explicit Tray 1 | Does the tray code work, or does the printer ask for paper? |
| `10-manual-feed` | manual feed slot | Does it wait for a sheet in the manual slot? (Feed one.) |
| `20-hl2140-baseline` | HL-2140 only: calibration page | Does the mono format print? |
| `21-hl2140-toner-save` | HL-2140 only: toner save on | Visibly lighter than 20? |

If 01 prints correctly, 02 and 03 can be skipped.

## 4. Measure sheet 01

The frame is drawn exactly on the margin the driver assumes (12 pt = 4.2 mm on every side for the
colour models; 8 pt = 2.8 mm left, right and bottom and 16 pt = 5.6 mm at the top for the HL-2140).
Ticks are every quarter inch, long ticks every inch.

Measure from each paper edge to the outside of the frame line, in millimetres: top, bottom, left,
right. If a side of the frame is missing, the real unprintable margin there is larger than
assumed: measure to where the ticks start instead. Check that the 0.12 pt hairline is present and
unbroken, and that the 6 pt text is legible.

## 5. Through the print system

Add the printer in System Settings → Printers & Scanners. Note whether this driver was chosen
**automatically** (the "Use" field shows "Brother … brother-mac-driver") or had to be picked under
"Select Software…". Then print `calibration-colour.pdf` from Preview, once as is and once
two-sided, and compare with sheets 01 and 07. They should be identical.

While a multi-page job is printing, cancel it from the queue window. The printer should stop after
the current sheet and accept the next job normally; if it sits with its data light on, note that.

Unplug the USB cable mid-idle and plug it back in: the queue should resume without being re-added.

## 6. Collect

```sh
bash collect-logs.sh
```

It writes a folder on the Desktop with serial numbers blanked. Bring back that folder, `probe.txt`,
the photos, and this table.

| Job | Printed? | Looks right? | Printer's reply / notes |
|---|---|---|---|
| 01 | | | |
| 02 | | | |
| 03 | | | |
| 04 | | | |
| 05 | | | |
| 06 | | | |
| 07 | | | |
| 08 | | | |
| 09 | | | |
| 10 | | | |
| 20 | | | |
| 21 | | | |

Margins on sheet 01 (mm): top ____ bottom ____ left ____ right ____

Driver chosen automatically when adding the printer: yes / no. `MDL:` text from step 2: ________
