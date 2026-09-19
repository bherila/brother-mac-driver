#!/bin/bash
# Builds the filter + PPDs and installs them to their system locations.
# The build runs as the invoking user; only the final copy steps use sudo,
# because /Library/Printers must be owned by root for CUPS to trust the filter.
#
# usage: scripts/install.sh
#   BUILD_DIR=<dir>          use prebuilt binaries instead of building
#   CODESIGN_IDENTITY=<name> sign with this identity instead of ad hoc
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
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

echo "installing filter and PPDs (sudo may prompt for your password)"
sudo install -o root -g wheel -m 0755 -d "$filter_dest_dir"
sudo install -o root -g wheel -m 0755 "$work/rastertobrother" "$filter_dest"
sudo install -o root -g wheel -m 0755 -d "$tool_dest_dir"
sudo install -o root -g wheel -m 0755 "$work/pxltool" "$tool_dest_dir/pxltool"
sudo install -o root -g wheel -m 0755 -d "$ppd_dest_dir"

for ppd in "$work"/ppd/Brother-*.ppd; do
    name="$(basename "$ppd")"
    gzip -c "$ppd" >"$work/$name.gz"
    sudo install -o root -g wheel -m 0644 "$work/$name.gz" "$ppd_dest_dir/$name.gz"
done

cat <<'EOF'

Done. Open System Settings > Printers & Scanners, add the printer; the driver is selected
automatically for supported models (or choose "Brother <model>, brother-mac-driver" under
"Select Software...").
EOF
