#!/bin/bash
# Records what the macOS rasteriser actually produces for every paper the mono PPD offers, so the
# validator's row-width arithmetic can be checked against evidence instead of against itself
# (bherila/brother-mac-driver#27).
#
# For each paper: a calibration PDF of that size -> cupsfilter driven by the HL-2140 PPD -> the
# CUPS raster's first page header, read by scripts/raster-header.py (which shares no code with the
# driver) -> rastertobrother -> the PJL the job declares -> `pxltool check --fail-on policy`.
#
# Two resolutions:
#   600dpi  the PPD exactly as shipped; this is what users get.
#   300dpi  a test-only copy of that PPD with its one Resolution choice rewritten to 300 dpi. The
#           shipped PPD offers no 300 dpi choice; the backend accepts 300, so the width arithmetic
#           has to be right there too. The row is only recorded if the raster really comes out at
#           HWResolution 300x300 — asking for it is not taken as proof of getting it.
#
# usage: scripts/capture-mono-headers.sh [--check FIXTURE] [build-dir]
#   Prints the table (tab-separated, `#` lines are provenance). With --check, also compares its
#   rows with FIXTURE's and fails on any difference, so a change in the rasteriser, the PPD or the
#   paper list shows up as a failed check rather than as silently different expectations.
#   Without a build-dir the release build is refreshed first, as in e2e-test.sh.
set -euo pipefail

fixture=""
if [[ "${1:-}" == --check ]]; then
    fixture="${2:?--check needs a fixture file}"
    shift 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -eq 0 ]]; then
    swift build -c release --package-path "$repo_root" >/dev/null
fi
bin="${1:-$repo_root/.build/release}"
filter="$bin/rastertobrother"
pxltool="$bin/pxltool"
header_reader="$repo_root/scripts/raster-header.py"

for tool in "$filter" "$pxltool"; do
    if [[ ! -x "$tool" ]]; then
        echo "missing $tool (run: swift build -c release)" >&2
        exit 1
    fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$pxltool" ppd --out "$work/ppd" --model "HL-2140 series" >/dev/null
shipped="$work/ppd/Brother-HL-2140-series.ppd"
if ! grep -q '^\*Resolution 600dpi/600 dpi: "<</HWResolution\[600 600\]' "$shipped"; then
    echo "the shipped PPD's Resolution choice is not the single 600dpi one this script rewrites" >&2
    exit 1
fi
test_only="$work/ppd/Brother-HL-2140-series-300dpi.ppd"
sed -e 's/600dpi/300dpi/g' -e 's/600 dpi/300 dpi/' -e 's/HWResolution\[600 600\]/HWResolution[300 300]/' \
    "$shipped" >"$test_only"

# The papers are read from the PPD, not listed here: "every paper the PPD offers" has to follow the
# PPD when a paper is added or dropped.
papers=()
while IFS= read -r paper; do papers+=("$paper"); done < <(sed -n 's/^\*PageSize \([^/:]*\).*/\1/p' "$shipped")
if ((${#papers[@]} == 0)); then
    echo "no *PageSize entries in $shipped" >&2
    exit 1
fi

columns=(resolution page_size HWResolution cupsPageSizeName cupsPageSize PageSize ImagingBoundingBox
    cupsImagingBBox cupsWidth cupsHeight cupsBitsPerPixel cupsColorSpace cupsBytesPerLine
    pjl_PAPER pjl_RESOLUTION pjl_RAS1200MODE)

table="$work/table.tsv"
{
    echo "# Captured by scripts/capture-mono-headers.sh — see that script for how. Rows are compared;"
    echo "# these # lines are provenance and are not."
    echo "# macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) ($(sw_vers -buildVersion 2>/dev/null || echo unknown)), $(uname -m)"
    echo "# PPD 600dpi (shipped): sha256 $(shasum -a 256 "$shipped" | cut -d' ' -f1)"
    echo "# PPD 300dpi (test-only rewrite): sha256 $(shasum -a 256 "$test_only" | cut -d' ' -f1)"
    (IFS=$'\t'; echo "${columns[*]}")
} >"$table"

failures=0
for resolution in 600 300; do
    ppd="$shipped"
    [[ $resolution == 300 ]] && ppd="$test_only"
    for paper in "${papers[@]}"; do
        name="$paper-$resolution"
        options="PageSize=$paper Resolution=${resolution}dpi"
        "$pxltool" testpdf --out "$work/$name.pdf" --size "$paper" --gray yes
        # The logs live in $work, which is deleted on exit, so a failure has to show its log here or
        # CI is left with a bare exit status.
        if ! cupsfilter -p "$ppd" -m application/vnd.cups-raster -o "PageSize=$paper" -o "Resolution=${resolution}dpi" \
            "$work/$name.pdf" >"$work/$name.ras" 2>"$work/$name.cupsfilter.log"; then
            echo "FAIL: $name: cupsfilter failed:" >&2
            sed 's/^/   /' "$work/$name.cupsfilter.log" >&2
            exit 1
        fi

        "$header_reader" "$work/$name.ras" >"$work/$name.header"
        # A lookup rather than an associative array: macOS's /bin/bash is 3.2, which has none.
        field() { sed -n "s/^$1=//p" "$work/$name.header"; }

        if [[ "$(field HWResolution)" != "$resolution,$resolution" ]]; then
            echo "FAIL: $name: asked for $resolution dpi, the raster is $(field HWResolution)" >&2
            failures=$((failures + 1))
            continue
        fi
        if [[ "$(field cupsBitsPerPixel)" != 1 || "$(field cupsColorSpace)" != 3 ]]; then
            echo "FAIL: $name: not 1-bit black (bits $(field cupsBitsPerPixel), colour space $(field cupsColorSpace))" >&2
            failures=$((failures + 1))
            continue
        fi

        if ! PPD="$ppd" "$filter" 1 capture "$name" 1 "$options" "$work/$name.ras" >"$work/$name.prn" 2>"$work/$name.filter.log"; then
            echo "FAIL: $name: rastertobrother failed:" >&2
            sed 's/^/   /' "$work/$name.filter.log" >&2
            exit 1
        fi
        # head first: cutting a pipe short would fail the pipeline under pipefail.
        head -c 2000 "$work/$name.prn" | LC_ALL=C tr -d '\000' >"$work/$name.head"
        pjl() { LC_ALL=C sed -n "s/^@PJL SET $1 = \\([^[:cntrl:]]*\\).*/\\1/p" "$work/$name.head" | head -n 1; }
        pjl_paper="$(pjl PAPER)"
        pjl_resolution="$(pjl RESOLUTION)"
        pjl_ras1200="$(pjl RAS1200MODE)"
        if [[ "$pjl_resolution" != "$resolution" ]]; then
            echo "FAIL: $name: the job declares RESOLUTION = '$pjl_resolution'" >&2
            failures=$((failures + 1))
        fi

        # The consequence the issue is about: a wrong width expectation fails preflight on a
        # job this driver legitimately produced.
        if ! "$pxltool" check --fail-on policy "$work/$name.prn" 2>"$work/$name.check"; then
            echo "FAIL: $name: preflight rejected the job" >&2
            sed 's/^/   /' "$work/$name.check" >&2
            failures=$((failures + 1))
        fi

        row=("${resolution}dpi" "$paper")
        for column in "${columns[@]:2:11}"; do row+=("$(field "$column")"); done
        row+=("$pjl_paper" "$pjl_resolution" "$pjl_ras1200")
        (IFS=$'\t'; echo "${row[*]}") >>"$table"
    done
done

cat "$table"

if [[ -n "$fixture" ]]; then
    if [[ ! -f "$fixture" ]]; then
        echo "FAIL: no fixture at $fixture" >&2
        failures=$((failures + 1))
    elif ! diff -u <(grep -v '^#' "$fixture") <(grep -v '^#' "$table") >"$work/fixture.diff"; then
        echo "FAIL: the rasteriser no longer produces what $fixture records:" >&2
        cat "$work/fixture.diff" >&2
        echo "fixture provenance:" >&2
        grep '^#' "$fixture" >&2
        failures=$((failures + 1))
    fi
fi

if ((failures > 0)); then
    echo "$failures failure(s)" >&2
    exit 1
fi
