#!/bin/bash
# End-to-end test through the real CUPS stack, aimed at a fake network printer on
# localhost instead of real (USB) hardware, so the queue/filter/capture path can be
# exercised without a printer attached.
#
# usage: [MODEL=<name>] [PPD_SOURCE=generated|installed] scripts/test-queue.sh [-o key=value ...]
#   MODEL picks the PPD (default MFC-9330CDW; e.g. MODEL=HL-2140-series).
#   PPD_SOURCE=installed builds the queue from the PPD the installer put in
#     /Library/Printers/PPDs, chosen by the model name cupsd indexed — the way System Settings
#     does it — so what is tested is the file a user actually gets. The default, `generated`,
#     uses a freshly generated PPD, which is what a developer wants before installing anything.
#   Extra arguments are passed straight through to `lp`, so specific PPD options
#   (e.g. -o BRCompression=DeltaRow) can be exercised.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${BUILD_DIR:-$repo_root/.build/release}"
pxltool="$build_dir/pxltool"
queue="BrotherOSS_Test"
port=9100
ppd_source="${PPD_SOURCE:-generated}"
installed_ppd_dir="/Library/Printers/PPDs/Contents/Resources"
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

# How the queue gets its PPD. Naming the installed file by hand would bypass cupsd's own index,
# which is what a print dialog picks from, so the installed case asks cupsd for it by model name.
if [[ "$ppd_source" == "installed" ]]; then
    installed="$installed_ppd_dir/$(basename "$ppd").gz"
    if [[ ! -f "$installed" ]]; then
        echo "no installed PPD at $installed (run scripts/install.sh first)" >&2
        exit 1
    fi
    listing="$(lpinfo -m 2>/dev/null || true)"
    model_uri="$(awk -v name="$(basename "$installed")" 'index($1, name) { print $1; exit }' <<<"$listing")"
    if [[ -z "$model_uri" ]]; then
        echo "cupsd does not offer $(basename "$installed"); it may not have indexed it yet" >&2
        exit 1
    fi
    echo "using the installed PPD, as cupsd offers it: $model_uri"
    # Unpacked only to read *BRBackend below; the queue uses cupsd's copy, not this one.
    gzip -dc "$installed" >"$work/installed.ppd"
    ppd="$work/installed.ppd"
    ppd_option=(-m "$model_uri")
elif [[ "$ppd_source" == "generated" ]]; then
    ppd_option=(-P "$ppd")
else
    echo "PPD_SOURCE must be 'generated' or 'installed', not '$ppd_source'" >&2
    exit 1
fi

# The listener goes up before the queue exists, so nothing can be sent to the port before it is
# ready. nc serves one connection and exits; if that happens before our job is done, something
# else took the connection and the job would only sit in retry until the timeout.
nc -l 127.0.0.1 "$port" >"$work/capture.pxl" &
nc_pid=$!

lpadmin -p "$queue" -E -v "socket://127.0.0.1:$port" "${ppd_option[@]}" -o printer-is-shared=false
queue_created=1

"$pxltool" testpdf --out "$work/test.pdf" --pages 2

lp -d "$queue" "$@" "$work/test.pdf"

echo "waiting for the job to finish (up to ${timeout_seconds}s)..."
elapsed=0
while [[ -n "$(lpstat -W not-completed -o "$queue" 2>/dev/null)" ]]; do
    if ((elapsed >= timeout_seconds)); then
        echo "job on $queue did not finish within ${timeout_seconds}s" >&2
        exit 1
    fi
    if ! kill -0 "$nc_pid" 2>/dev/null && [[ ! -s "$work/capture.pxl" ]]; then
        echo "the listener on port $port closed before receiving the job (did something else connect to it?)" >&2
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

kill "$nc_pid" 2>/dev/null || true
wait "$nc_pid" 2>/dev/null || true
nc_pid=""

captured_bytes="$(wc -c <"$work/capture.pxl" | tr -d ' ')"
echo
echo "capture: $captured_bytes bytes"
if ((captured_bytes == 0)); then
    echo "the print system sent nothing to the listener" >&2
    exit 1
fi

# The job came out of the real print system, so this is the closest thing to a printer's verdict
# that can be had without one: everything a printer would reject, checked on the captured bytes.
echo "== preflight =="
"$pxltool" check "$work/capture.pxl"

if grep -q '^\*BRBackend: "pclxl"' "$ppd"; then
    # Dump to a file first: cutting the pipe short with head would fail the pipeline under pipefail.
    "$pxltool" dump "$work/capture.pxl" >"$work/capture.dump"
    pages="$(grep -c '^page ' "$work/capture.dump" || true)"
    echo "== job dump (first 40 lines) =="
    head -40 "$work/capture.dump"

    render_dir="$repo_root/build/test-queue"
    "$pxltool" render "$work/capture.pxl" --out "$render_dir"
    echo "rendered pages: $render_dir"
else
    # shellcheck disable=SC2126  # counting occurrences, not matching lines: grep -c would undercount
    pages="$(LC_ALL=C grep -o -a '1030M' "$work/capture.pxl" | wc -l | tr -d ' ')"
    # The mono format is only checkable against its raster (pxltool compare); show its text preamble.
    echo "== job preamble =="
    head -c 700 "$work/capture.pxl" | LC_ALL=C tr -d '\000' | LC_ALL=C tr -c '[:print:]\n' '.'
    echo
fi

# The test PDF has two pages. Two is already even, so duplex padding adds nothing, and anything
# other than two means the print system lost or multiplied a page. (A run that asks for printer
# copies would legitimately send more; this script does not.)
if [[ "$pages" -ne 2 ]]; then
    echo "the captured job has $pages page(s); the job sent had 2" >&2
    exit 1
fi
echo "queue test passed: $pages page(s) through $queue"
