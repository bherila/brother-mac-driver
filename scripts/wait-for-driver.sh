#!/bin/bash
# Waits for cupsd's driver list to agree that this driver is (or is no longer) installed.
#
# usage: scripts/wait-for-driver.sh present|absent [seconds]
#
# cupsd indexes /Library/Printers/PPDs itself and rebuilds that index when the directory changes,
# so `lpinfo -m` can lag an install or an uninstall by a moment. Anything that checks it right
# after touching those files has to wait, or it is testing the timing of a cache.
set -euo pipefail

want="${1:-present}"
timeout_seconds="${2:-30}"
if [[ "$want" != "present" && "$want" != "absent" ]]; then
    echo "usage: $0 present|absent [seconds]" >&2
    exit 64
fi

elapsed=0
while true; do
    found=0
    lpinfo -m 2>/dev/null | grep -q "brother-mac-driver" && found=1
    if [[ "$want" == "present" && "$found" -eq 1 ]] || [[ "$want" == "absent" && "$found" -eq 0 ]]; then
        echo "the print system reports this driver as $want"
        exit 0
    fi
    if ((elapsed >= timeout_seconds)); then
        echo "after ${timeout_seconds}s the print system still does not report this driver as $want" >&2
        lpinfo -m 2>/dev/null | grep -i brother || echo "  (no Brother drivers listed at all)" >&2
        exit 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done
