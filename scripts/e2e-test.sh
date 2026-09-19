#!/bin/bash
# End-to-end check without a printer:
#   calibration PDF -> the system's PDF-to-raster filter, driven by our PPD -> rastertobrother
#   -> decode the PCL XL -> compare pixel for pixel with the raster the filter was given.
#
# usage: scripts/e2e-test.sh [build-dir]
#   Without an argument the release build is refreshed first, so stale binaries are never tested.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -eq 0 ]]; then
    swift build -c release --package-path "$repo_root" >/dev/null
fi
bin="${1:-$repo_root/.build/release}"
filter="$bin/rastertobrother"
pxltool="$bin/pxltool"

for tool in "$filter" "$pxltool"; do
    if [[ ! -x "$tool" ]]; then
        echo "missing $tool (run: swift build -c release)" >&2
        exit 1
    fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$pxltool" ppd --out "$work/ppd" >/dev/null

# The filter is not installed at its final path here, so skip only that check. Size-name warnings
# are for the millimetre sizes, whose "standard" names are unreadable.
cupstestppd -I filters -W sizes "$work"/ppd/*.ppd

# model | name | testpdf arguments | job options | text the job must contain | what compare must report per page
cases=(
    "MFC-9330CDW|colour|--pages 2||MediaSize=letter(0)|rgb8"
    "MFC-9330CDW|neutral|--gray yes||ColorSpace=gray(1)|gray8"
    "MFC-9330CDW|forced-gray|--pages 1|ColorModel=Gray|RENDERMODE=GRAYSCALE|gray8"
    "MFC-9330CDW|forced-colour|--gray yes|ColorModel=RGB|ColorSpace=rgb(2)|rgb8"
    "MFC-9330CDW|duplex-a4|--size A4 --pages 3|PageSize=A4 Duplex=DuplexNoTumble|DuplexPageSide=back(1)|rgb8"
    "MFC-9330CDW|tumble|--pages 2|Duplex=DuplexTumble|DuplexPageMode=horizontalBinding(0)|rgb8"
    "MFC-9330CDW|deltarow|--pages 1|BRCompression=DeltaRow|CompressMode=deltaRow(3)|rgb8"
    "MFC-9330CDW|tray-tonersave|--gray yes|InputSlot=Tray1 BRTonerSaveMode=ON|ECONOMODE=ON|gray8"
    "MFC-9330CDW|envelope|--size EnvDL --gray yes|PageSize=EnvDL InputSlot=Manual|MediaSource=manualFeed(2)|gray8"
    "MFC-9330CDW|custom-size|--size 3x5 --gray yes|PageSize=3x5|CustomMediaSize=[762, 1270]|gray8"
)

failures=0
for entry in "${cases[@]}"; do
    IFS='|' read -r model name pdf_args job_options expect_dump expect_format <<<"$entry"
    echo "== $name ($model)"
    ppd="$work/ppd/Brother-$model.ppd"

    # shellcheck disable=SC2086  # arguments are deliberately word-split
    "$pxltool" testpdf --out "$work/$name.pdf" $pdf_args

    cups_options=()
    for option in $job_options; do cups_options+=(-o "$option"); done
    cupsfilter -p "$ppd" -m application/vnd.cups-raster ${cups_options[@]+"${cups_options[@]}"} \
        "$work/$name.pdf" >"$work/$name.ras" 2>"$work/$name.cupsfilter.log"

    PPD="$ppd" "$filter" 1 e2e "$name" 1 "$job_options" "$work/$name.ras" >"$work/$name.pxl" 2>"$work/$name.filter.log"

    "$pxltool" dump "$work/$name.pxl" >"$work/$name.dump"
    if ! grep -qF -- "$expect_dump" "$work/$name.dump"; then
        echo "FAIL: job does not contain '$expect_dump'" >&2
        failures=$((failures + 1))
    fi

    "$pxltool" compare "$work/$name.ras" "$work/$name.pxl" | tee "$work/$name.compare"
    # A blank page (the rasteriser pads duplex jobs to an even page count) carries no images.
    if grep -v -e ", $expect_format)" -e "(0 images)" "$work/$name.compare" | grep -q .; then
        echo "FAIL: expected every page to be sent as $expect_format" >&2
        failures=$((failures + 1))
    fi

    echo "   $(wc -c <"$work/$name.ras" | tr -d ' ') raster bytes -> $(wc -c <"$work/$name.pxl" | tr -d ' ') job bytes"
done

ends_with_uel() {
    [[ "$(tail -c 9 "$1" | xxd -p)" == "1b252d313233343558" ]]
}

# Input that stops mid-page: the job must still be well-formed, must not finish the page it never
# fully received, must end on a UEL so the printer drops the partial page — and the filter must
# report failure, or a rasteriser that died would look like a successful job with a page missing.
echo "== truncated"
ppd="$work/ppd/Brother-MFC-9330CDW.ppd"
head -c 60000000 "$work/colour.ras" >"$work/truncated.ras"
status=0
PPD="$ppd" "$filter" 1 e2e truncated 1 "" "$work/truncated.ras" >"$work/truncated.pxl" 2>"$work/truncated.filter.log" || status=$?
"$pxltool" dump "$work/truncated.pxl" >"$work/truncated.dump"
if ((status == 0)); then
    echo "FAIL: truncated input was reported as a successful job" >&2
    failures=$((failures + 1))
fi
if ! ends_with_uel "$work/truncated.pxl"; then
    echo "FAIL: truncated job does not end with a UEL" >&2
    failures=$((failures + 1))
fi
if grep -q "EndPage\|EndSession" "$work/truncated.dump"; then
    echo "FAIL: truncated job finished a page it never fully received" >&2
    failures=$((failures + 1))
fi
grep -c "EndImage" "$work/truncated.dump" | sed 's/^/   complete images sent before the cut: /'

if ((failures > 0)); then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "e2e test passed"
