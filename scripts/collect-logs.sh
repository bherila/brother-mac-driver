#!/bin/bash
# Gathers what is needed to diagnose a printing problem into one folder, with serial numbers
# blanked so it can be attached to a public issue. Changes nothing on the system.
#
# usage: collect-logs.sh [output-dir]      (default: ~/Desktop/brother-mac-driver-logs-<time>)
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# An installed pxltool can be older than this script; only one that can redact will do, because
# nothing is written unredacted.
pxltool=""
for candidate in /Library/Printers/BrotherOSS/bin/pxltool "$here/../.build/release/pxltool"; do
    if [[ -x "$candidate" ]] && [[ "$(printf 'SN:x;' | "$candidate" redact 2>/dev/null)" == "SN:<redacted>;" ]]; then
        pxltool="$candidate"
        break
    fi
done
if [[ -z "$pxltool" ]]; then
    echo "no pxltool that supports 'redact' was found; install the current driver package first" >&2
    echo "(it installs /Library/Printers/BrotherOSS/bin/pxltool)" >&2
    exit 1
fi

out="${1:-$HOME/Desktop/brother-mac-driver-logs-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"

# Every capture goes through the redactor; a command that fails leaves its error in the file
# rather than stopping the collection.
capture() {
    local name="$1"
    shift
    { "$@" 2>&1 || echo "(exit status $?)"; } | "$pxltool" redact >"$out/$name.txt"
}

capture system sw_vers
capture arch uname -m
capture usb-probe "$pxltool" usb-probe
capture queues lpstat -t
capture drivers sh -c "lpinfo -m | grep -i 'brother'"
capture installed-files ls -laR /Library/Printers/BrotherOSS
capture filter-signature codesign -dv /Library/Printers/BrotherOSS/filter/rastertobrother
capture cups-error-log sh -c "grep -iE 'rastertobrother|brother|PAGE:|Started filter|filter failed' /var/log/cups/error_log | tail -400"

# The PPD of every queue that uses this driver, as CUPS holds it (it records the chosen defaults).
for ppd in /etc/cups/ppd/*.ppd; do
    [[ -e "$ppd" ]] || continue
    if grep -q "brother-mac-driver" "$ppd" 2>/dev/null; then
        queue="$(basename "$ppd" .ppd)"
        "$pxltool" redact <"$ppd" >"$out/queue-$queue.txt"
    fi
done

echo "collected into $out"
echo "for more detail in the CUPS log: run 'cupsctl --debug-logging', print again, collect again, then 'cupsctl --no-debug-logging'"
