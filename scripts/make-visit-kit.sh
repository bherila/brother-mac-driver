#!/bin/bash
# Builds everything needed for one session with a printer that has never been tried:
# the installer, numbered ready-made jobs that each answer one question, a log collector and the
# checklist. Every job is produced by the real filter chain and checked against its raster before
# it goes into the kit, so a job that prints wrongly is the printer's verdict, not a broken file.
#
# usage: scripts/make-visit-kit.sh          -> build/visit-kit/ and build/visit-kit.zip
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
swift build -c release --package-path "$repo_root" >/dev/null
bin="$repo_root/.build/release"
filter="$bin/rastertobrother"
pxltool="$bin/pxltool"

kit="$repo_root/build/visit-kit"
rm -rf "$kit"
mkdir -p "$kit/jobs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$pxltool" ppd --out "$work/ppd" >/dev/null
"$pxltool" testpdf --out "$work/colour.pdf"
"$pxltool" testpdf --out "$work/gray.pdf" --gray yes
"$pxltool" testpdf --out "$work/two-pages.pdf" --pages 2

# file name | model | source PDF | job options
jobs=(
    "01-baseline.pxl|MFC-9330CDW|colour|"
    "02-without-brother-pjl.pxl|MFC-9330CDW|colour|BRPJL=OFF"
    "03-error-report-on.pxl|MFC-9330CDW|colour|BRErrorPage=ON"
    "04-deltarow.pxl|MFC-9330CDW|colour|BRCompression=DeltaRow"
    "05-neutral-page.pxl|MFC-9330CDW|gray|"
    "06-forced-black-and-white.pxl|MFC-9330CDW|colour|ColorModel=Gray"
    "07-duplex-long-edge.pxl|MFC-9330CDW|two-pages|Duplex=DuplexNoTumble"
    "08-duplex-short-edge.pxl|MFC-9330CDW|two-pages|Duplex=DuplexTumble"
    "09-tray-1.pxl|MFC-9330CDW|gray|InputSlot=Tray1"
    "10-manual-feed.pxl|MFC-9330CDW|gray|InputSlot=Manual"
    "20-hl2140-baseline.prn|HL-2140-series|gray|"
    "21-hl2140-toner-save.prn|HL-2140-series|gray|BRTonerSaveMode=ON"
)

for entry in "${jobs[@]}"; do
    IFS='|' read -r name model source job_options <<<"$entry"
    ppd="$work/ppd/Brother-$model.ppd"
    cups_options=()
    for option in $job_options; do cups_options+=(-o "$option"); done
    # The tools are chatty on stderr, so it is kept aside and shown only if a step fails.
    log="$work/$name.log"
    if ! {
        cupsfilter -p "$ppd" -m application/vnd.cups-raster ${cups_options[@]+"${cups_options[@]}"} \
            "$work/$source.pdf" >"$work/$name.ras" 2>"$log" &&
            PPD="$ppd" "$filter" 1 kit "${name%.*}" 1 "$job_options" "$work/$name.ras" >"$kit/jobs/$name" 2>>"$log" &&
            "$pxltool" compare "$work/$name.ras" "$kit/jobs/$name" >/dev/null 2>>"$log" &&
            "$pxltool" check "$kit/jobs/$name" >/dev/null 2>>"$log"
    }; then
        echo "failed to build or verify $name:" >&2
        tail -20 "$log" >&2
        exit 1
    fi
    printf '  %-34s %8s bytes  verified, preflight clean\n' "$name" "$(wc -c <"$kit/jobs/$name" | tr -d ' ')"
done

cp "$work/colour.pdf" "$kit/calibration-colour.pdf"
cp "$work/gray.pdf" "$kit/calibration-gray.pdf"
cp "$work/two-pages.pdf" "$kit/calibration-two-pages.pdf"
cp "$repo_root/scripts/collect-logs.sh" "$kit/collect-logs.sh"
cp "$repo_root/docs/hardware-visit.md" "$kit/CHECKLIST.md"

# Exactly the package just built: build/ may hold installers from earlier versions.
package="$(BUILD_DIR="$bin" "$repo_root/scripts/make-pkg.sh" | sed -n 's/^built //p')"
if [[ ! -f "$package" ]]; then
    echo "make-pkg.sh did not report the package it built" >&2
    exit 1
fi
cp "$package" "$kit/"

(cd "$repo_root/build" && rm -f visit-kit.zip && zip -qr visit-kit.zip visit-kit)
echo "kit: $kit"
echo "zip: $repo_root/build/visit-kit.zip ($(du -h "$repo_root/build/visit-kit.zip" | cut -f1 | tr -d ' '))"
