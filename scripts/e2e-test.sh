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
    "HL-2140-series|mono|--pages 2 --gray yes||@PJL SET PAPER = LETTER|black1"
    "HL-2140-series|mono-a4-tray|--size A4 --gray yes|PageSize=A4 InputSlot=Tray1 BRTonerSaveMode=ON|@PJL SET SOURCETRAY = T1|black1"
    "HL-2140-series|mono-colour-input|--pages 1|PageSize=Legal|@PJL SET PAPER = LEGAL|black1"
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

    # PCL XL jobs are checked through their disassembly; the mono format is mostly text up front.
    if [[ "$expect_format" == black1 ]]; then
        # head first: cutting a pipe short would fail the pipeline under pipefail.
        head -c 2000 "$work/$name.pxl" | LC_ALL=C tr -d '\000' >"$work/$name.dump"
    else
        "$pxltool" dump "$work/$name.pxl" >"$work/$name.dump"
    fi
    if ! LC_ALL=C grep -qaF -- "$expect_dump" "$work/$name.dump"; then
        echo "FAIL: job does not contain '$expect_dump'" >&2
        failures=$((failures + 1))
    fi

    # Preflight: what a printer would reject and what this driver should not have emitted, neither
    # of which any amount of pixel comparison can see. These are our own jobs, so policy findings
    # are failures here — an image clipped off the sheet is a bug even though PCL XL allows it.
    if ! "$pxltool" check --fail-on policy "$work/$name.pxl" 2>"$work/$name.check"; then
        echo "FAIL: preflight rejected the job" >&2
        cat "$work/$name.check" >&2
        failures=$((failures + 1))
    elif [[ -s "$work/$name.check" ]]; then
        sed 's/^/   /' "$work/$name.check"
    fi

    "$pxltool" compare "$work/$name.ras" "$work/$name.pxl" | tee "$work/$name.compare"
    # A blank page (the rasteriser pads duplex jobs to an even page count) carries no images.
    if grep -v -e ", $expect_format)" -e " $expect_format identical" -e "(0 images)" "$work/$name.compare" | grep -q .; then
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
# grep exits 1 on no match; that must not end the script before the summary.
echo "   complete images sent before the cut: $(grep -c "EndImage" "$work/truncated.dump" || true)"

# The preflight must reject what the filter had to abandon: a validator that passes everything
# would have passed every check above too.
if "$pxltool" check "$work/truncated.pxl" >/dev/null 2>&1; then
    echo "FAIL: preflight accepted a job that was cut short" >&2
    failures=$((failures + 1))
fi

# A page the backend refuses (here: a second page at 300 dpi), after the first page has already
# gone out. The filter must fail, but only after closing the job: the printer must not be left
# inside an open session waiting for data that will never come.
echo "== unprintable second page"
python3 - "$work/neutral.ras" "$work/badpage.ras" <<'PY'
import struct, sys
raster = open(sys.argv[1], "rb").read()
assert raster[:4] == b"3SaR", "expected an uncompressed little-endian CUPS raster"
header = bytearray(raster[4:4 + 1796])
header[276:284] = struct.pack("<2I", 300, 300)  # HWResolution
open(sys.argv[2], "wb").write(raster + bytes(header))
PY
status=0
PPD="$ppd" "$filter" 1 e2e badpage 1 "" "$work/badpage.ras" >"$work/badpage.pxl" 2>"$work/badpage.filter.log" || status=$?
"$pxltool" dump "$work/badpage.pxl" >"$work/badpage.dump"
if ((status == 0)); then
    echo "FAIL: a job with an unprintable page was reported as successful" >&2
    failures=$((failures + 1))
fi
if ! ends_with_uel "$work/badpage.pxl"; then
    echo "FAIL: the job was abandoned without a UEL" >&2
    failures=$((failures + 1))
fi
if [[ "$(grep -c "EndPage" "$work/badpage.dump")" != 1 ]]; then
    echo "FAIL: the good first page should have been sent complete" >&2
    failures=$((failures + 1))
fi
echo "   $(grep -m1 "ERROR" "$work/badpage.filter.log" || echo "(the filter logged no ERROR line)")"
# The point of closing the job on the way out is that what did go to the printer is still a
# complete, well-formed job, so the preflight has to accept it.
if ! "$pxltool" check --fail-on policy "$work/badpage.pxl" >/dev/null 2>"$work/badpage.check"; then
    echo "FAIL: the job left behind by an unprintable page is not well-formed" >&2
    cat "$work/badpage.check" >&2
    failures=$((failures + 1))
fi

# stdout that is non-blocking with a slow reader (not what CUPS normally gives a filter, but
# nothing forbids it): the job must arrive intact, and the filter must wait for room rather than
# spin, so its CPU time stays a small part of the elapsed time.
echo "== non-blocking stdout"
if ! python3 - "$filter" "$ppd" "$work/colour.ras" "$work/colour.pxl" <<'PY'
import fcntl, hashlib, os, resource, subprocess, sys, time
filter_path, ppd, raster, expected = sys.argv[1:5]
read_end, write_end = os.pipe()
fcntl.fcntl(write_end, fcntl.F_SETFL, fcntl.fcntl(write_end, fcntl.F_GETFL) | os.O_NONBLOCK)
start = time.time()
child = subprocess.Popen(
    [filter_path, "1", "e2e", "colour", "1", "", raster],
    stdout=write_end, stderr=subprocess.DEVNULL, env={**os.environ, "PPD": ppd})
os.close(write_end)
digest = hashlib.sha256()
while chunk := os.read(read_end, 65536):
    digest.update(chunk)
    time.sleep(0.01)
status = child.wait()
elapsed = time.time() - start
usage = resource.getrusage(resource.RUSAGE_CHILDREN)
cpu = usage.ru_utime + usage.ru_stime
print(f"   {elapsed:.1f} s elapsed, {cpu:.2f} s of CPU")
problems = []
if status != 0:
    problems.append(f"filter exited {status}")
if digest.hexdigest() != hashlib.sha256(open(expected, "rb").read()).hexdigest():
    problems.append("output differs from the blocking run")
if cpu > elapsed / 2:
    problems.append("filter spent most of its time spinning")
for problem in problems:
    print(f"FAIL: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
then
    failures=$((failures + 1))
fi

if ((failures > 0)); then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "e2e test passed"
