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

# Two ways to get this wrong, and the second is the dangerous one.
#
# `lpinfo -m | grep -q` looks right and is a trap: grep exits at its first match, lpinfo dies of
# SIGPIPE, and under `set -o pipefail` the pipeline then reports failure even though the driver was
# found. So the listing is taken once and searched without a pipe.
#
# `lpinfo ... || true` is the same trap wearing a different hat: it turns a failed query into an
# empty listing, an empty listing has no match, and no match reads as "absent". A cupsd that is not
# answering would then certify that uninstalling worked. A query that did not run proves nothing
# either way, so it is kept apart from a query that ran and found nothing.
#
# 0 = listed, 1 = ran and did not list it, 2 = the query itself failed.
driver_listed() {
    local listing
    if ! listing="$(lpinfo -m 2>/dev/null)"; then
        return 2
    fi
    grep -q "brother-mac-driver" <<<"$listing"
}

elapsed=0
query_failures=0
while true; do
    # `driver_listed || status=$?` and not `driver_listed && x || y`: the latter reports the status
    # of the whole `&&` list, so "ran, found nothing" comes back looking like "found it".
    status=0
    driver_listed || status=$?
    case "$status" in
        0) state=present ;;
        1) state=absent ;;
        # Keep retrying — cupsd may be restarting — but never let this count as an answer.
        *) state=unknown; query_failures=$((query_failures + 1)) ;;
    esac
    if [[ "$state" == "$want" ]]; then
        echo "the print system reports this driver as $want"
        exit 0
    fi
    if ((elapsed >= timeout_seconds)); then
        if ((query_failures > 0)); then
            echo "lpinfo -m failed on $query_failures of the last attempts, so whether this driver is" >&2
            echo "$want was never established. Treating that as unknown, not as $want." >&2
        else
            echo "after ${timeout_seconds}s the print system still does not report this driver as $want" >&2
            if brother="$(lpinfo -m 2>/dev/null)"; then
                grep -i brother <<<"$brother" || echo "  (no Brother drivers listed at all)" >&2
            fi
        fi
        exit 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done
