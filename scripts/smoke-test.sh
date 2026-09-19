#!/bin/bash
# Push a PDF through the system's own PDF-to-raster filter and feed the result to
# rastertobrother. Proves the filter can read what the macOS print system really produces.
#
# usage: scripts/smoke-test.sh [path-to-rastertobrother]
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-$repo_root/.build/release/rastertobrother}"

if [[ ! -x "$filter" ]]; then
    echo "filter not found at $filter (run: swift build -c release)" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Until this project ships its own PPDs, borrow a raster PPD from the CUPS samples.
ppdc -d "$work/ppd" /usr/share/cups/drv/sample.drv >/dev/null 2>&1
cupsfilter -m application/pdf /etc/hosts >"$work/page.pdf" 2>/dev/null
cupsfilter -p "$work/ppd/laserjet.ppd" -m application/vnd.cups-raster "$work/page.pdf" \
    >"$work/page.ras" 2>"$work/cupsfilter.log"

"$filter" 1 smoke "smoke test" 1 "" "$work/page.ras" >"$work/out.bin" 2>"$work/filter.log"
cat "$work/filter.log"

grep -q '^DEBUG: page 1: ' "$work/filter.log"
echo "smoke test passed"
