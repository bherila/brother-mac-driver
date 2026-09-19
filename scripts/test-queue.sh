#!/bin/bash
# End-to-end test through the real CUPS stack, aimed at a fake network printer on
# localhost instead of real (USB) hardware, so the queue/filter/capture path can be
# exercised without a printer attached.
#
# usage: [MODEL=<name>] scripts/test-queue.sh [-o key=value ...]
#   MODEL picks the PPD (default MFC-9330CDW; e.g. MODEL=HL-2140-series).
#   Extra arguments are passed straight through to `lp`, so specific PPD options
#   (e.g. -o BRCompression=DeltaRow) can be exercised.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${BUILD_DIR:-$repo_root/.build/release}"
pxltool="$build_dir/pxltool"
queue="BrotherOSS_Test"
port=9100
filter_path="/Library/Printers/BrotherOSS/filter/rastertobrother"
timeout_seconds=120

if [[ ! -x "$filter_path" ]]; then
    echo "driver not installed: $filter_path is missing (run scripts/install.sh first)" >&2
    exit 1
fi
if [[ ! -x "$pxltool" ]]; then
    echo "missing $pxltool (run: swift build -c release, or set BUILD_DIR)" >&2
    exit 1
fi
if nc -z 127.0.0.1 "$port" 2>/dev/null; then
    echo "port $port is already in use; stop whatever is listening there and retry" >&2
    exit 1
fi

work="$(mktemp -d)"
nc_pid=""
queue_created=0

# Always tears down the test queue and capture listener, even on failure, so a
# crashed run never leaves a stray CUPS queue or an orphaned nc behind.
cleanup() {
    local status=$?
    if [[ -n "$nc_pid" ]] && kill -0 "$nc_pid" 2>/dev/null; then
        kill "$nc_pid" 2>/dev/null || true
        wait "$nc_pid" 2>/dev/null || true
    fi
    if ((queue_created)); then
        cancel -a "$queue" >/dev/null 2>&1 || true
        lpadmin -x "$queue" >/dev/null 2>&1 || true
    fi
    if ((status != 0)); then
        echo "== test-queue.sh failed; recent CUPS log lines for $queue ==" >&2
        if [[ -r /var/log/cups/error_log ]]; then
            grep "$queue" /var/log/cups/error_log 2>/dev/null | tail -30 >&2 || true
        else
            echo "(cannot read /var/log/cups/error_log; try running as an admin)" >&2
        fi
        echo "hint: cupsctl --debug-logging, then retry for more detail" >&2
    fi
    rm -rf "$work" || true
    exit "$status"
}
trap cleanup EXIT

"$pxltool" ppd --out "$work/ppd" >/dev/null
ppd="$work/ppd/Brother-${MODEL:-MFC-9330CDW}.ppd"
if [[ ! -f "$ppd" ]]; then
    echo "no PPD for model '${MODEL:-}'; available:" >&2
    ls "$work/ppd" >&2
    exit 1
fi

lpadmin -p "$queue" -E -v "socket://127.0.0.1:$port" -P "$ppd" -o printer-is-shared=false
queue_created=1

nc -l 127.0.0.1 "$port" >"$work/capture.pxl" &
nc_pid=$!

"$pxltool" testpdf --out "$work/test.pdf" --pages 2

lp -d "$queue" "$@" "$work/test.pdf"

echo "waiting for the job to finish (up to ${timeout_seconds}s)..."
elapsed=0
while [[ -n "$(lpstat -W not-completed -o "$queue" 2>/dev/null)" ]]; do
    if ((elapsed >= timeout_seconds)); then
        echo "job on $queue did not finish within ${timeout_seconds}s" >&2
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

kill "$nc_pid" 2>/dev/null || true
wait "$nc_pid" 2>/dev/null || true
nc_pid=""

echo
echo "capture: $(wc -c <"$work/capture.pxl" | tr -d ' ') bytes"
if grep -q '^\*BRBackend: "pclxl"' "$ppd"; then
    # Dump to a file first: cutting the pipe short with head would fail the pipeline under pipefail.
    "$pxltool" dump "$work/capture.pxl" >"$work/capture.dump"
    echo "== job dump (first 40 lines) =="
    head -40 "$work/capture.dump"

    render_dir="$repo_root/build/test-queue"
    "$pxltool" render "$work/capture.pxl" --out "$render_dir"
    echo "rendered pages: $render_dir"
else
    # The mono format is only checkable against its raster (pxltool compare); show its text preamble.
    echo "== job preamble =="
    head -c 700 "$work/capture.pxl" | LC_ALL=C tr -d '\000' | LC_ALL=C tr -c '[:print:]\n' '.'
    echo
fi
