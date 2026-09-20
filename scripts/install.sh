#!/bin/bash
# Builds the filter + PPDs and installs them to their system locations.
# The build runs as the invoking user; only the final copy steps use sudo,
# because /Library/Printers must be owned by root for CUPS to trust the filter.
#
# usage: scripts/install.sh
#   BUILD_DIR=<dir>          use prebuilt binaries instead of building
#   CODESIGN_IDENTITY=<name> sign with this identity instead of ad hoc
#   DRY_RUN=1                build and stage, show what would run as root, install nothing
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/scripts/as-root.sh"
build_dir="${BUILD_DIR:-$repo_root/.build/release}"
filter_dest_dir="/Library/Printers/BrotherOSS/filter"
filter_dest="$filter_dest_dir/rastertobrother"
tool_dest_dir="/Library/Printers/BrotherOSS/bin"
ppd_dest_dir="/Library/Printers/PPDs/Contents/Resources"

if [[ -z "${BUILD_DIR:-}" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "run install.sh as your normal user, not root; sudo prompts happen automatically for the copy step" >&2
        exit 1
    fi
    swift build -c release --package-path "$repo_root"
fi

filter="$build_dir/rastertobrother"
pxltool="$build_dir/pxltool"
for tool in "$filter" "$pxltool"; do
    if [[ ! -x "$tool" ]]; then
        echo "missing $tool (run: swift build -c release, or set BUILD_DIR)" >&2
        exit 1
    fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$pxltool" ppd --out "$work/ppd" >/dev/null

# Sign copies so signing never mutates the build output.
cp "$filter" "$work/rastertobrother"
cp "$pxltool" "$work/pxltool"
for binary in "$work/rastertobrother" "$work/pxltool"; do
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp "$binary"
    else
        codesign --force --sign - "$binary"
    fi
done

for ppd in "$work"/ppd/Brother-*.ppd; do
    gzip -c "$ppd" >"$ppd.gz"
done

# Everything that needs root goes into one script, so there is a single password prompt whichever
# way it ends up being run. %q keeps the paths safe to paste into it.
{
    echo "set -euo pipefail"
    # install -d gives its mode only to the last component; directories it creates on the way
    # there take the caller's umask, and with 077 CUPS could not reach the filter.
    echo "umask 022"
    printf 'install -o root -g wheel -m 0755 -d %q %q %q %q\n' \
        "$(dirname "$filter_dest_dir")" "$filter_dest_dir" "$tool_dest_dir" "$ppd_dest_dir"
    printf 'install -o root -g wheel -m 0755 %q %q\n' "$work/rastertobrother" "$filter_dest"
    printf 'install -o root -g wheel -m 0755 %q %q\n' "$work/pxltool" "$tool_dest_dir/pxltool"
    for ppd in "$work"/ppd/Brother-*.ppd.gz; do
        printf 'install -o root -g wheel -m 0644 %q %q\n' "$ppd" "$ppd_dest_dir/$(basename "$ppd")"
    done
} >"$work/as-root.sh"

echo "installing the filter, pxltool and PPDs into /Library/Printers"
run_as_root "$work/as-root.sh"
if [[ -n "${DRY_RUN:-}" ]]; then
    exit 0
fi

cat <<'EOF'

Done. Open System Settings > Printers & Scanners, add the printer; the driver is selected
automatically for supported models (or choose "Brother <model>, brother-mac-driver" under
"Select Software...").
EOF
