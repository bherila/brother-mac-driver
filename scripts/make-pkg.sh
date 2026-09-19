#!/bin/bash
# Builds an installer package (unsigned unless the env vars below are set).
#
# usage: scripts/make-pkg.sh
#   BUILD_DIR=<dir>            use prebuilt binaries instead of building
#   VERSION=<version>          override the version read from PPDGenerator.swift
#   CODESIGN_IDENTITY=<name>   Developer ID Application identity for the filter binary
#   INSTALLER_IDENTITY=<name>  Developer ID Installer identity, passed to productbuild --sign
#   NOTARY_PROFILE=<profile>   notarytool keychain profile; submits and staples when set
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${BUILD_DIR:-$repo_root/.build/release}"
pkg_id="io.github.bherila.brother-mac-driver"

version="${VERSION:-$(sed -n 's/.*driverVersion = "\(.*\)".*/\1/p' "$repo_root/Sources/BrotherPDL/PPDGenerator.swift")}"
if [[ -z "$version" ]]; then
    echo "could not read driverVersion from PPDGenerator.swift; set VERSION to override" >&2
    exit 1
fi

if [[ -z "${BUILD_DIR:-}" ]]; then
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

# --- stage the payload ------------------------------------------------------
# --ownership recommended (below) makes pkgbuild install this root:wheel, matching
# what CUPS requires of the filter, so nothing here needs to run as root.

root="$work/root"
filter_dest_dir="$root/Library/Printers/BrotherOSS/filter"
tool_dest_dir="$root/Library/Printers/BrotherOSS/bin"
ppd_dest_dir="$root/Library/Printers/PPDs/Contents/Resources"
mkdir -p "$filter_dest_dir" "$tool_dest_dir" "$ppd_dest_dir"
chmod 0755 "$root/Library" "$root/Library/Printers" "$root/Library/Printers/BrotherOSS" "$filter_dest_dir" "$tool_dest_dir"
chmod 0755 "$root/Library/Printers/PPDs" "$root/Library/Printers/PPDs/Contents" "$ppd_dest_dir"

# pxltool ships alongside the filter so `pxltool usb-probe` is there to identify a printer on a
# Mac that has no checkout of this repository.
cp "$filter" "$filter_dest_dir/rastertobrother"
cp "$pxltool" "$tool_dest_dir/pxltool"
chmod 0755 "$filter_dest_dir/rastertobrother" "$tool_dest_dir/pxltool"
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "no CODESIGN_IDENTITY set; ad-hoc signing the binaries"
fi
for binary in "$filter_dest_dir/rastertobrother" "$tool_dest_dir/pxltool"; do
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp "$binary"
    else
        codesign --force --sign - "$binary"
    fi
done

"$pxltool" ppd --out "$work/ppd" >/dev/null
for ppd in "$work"/ppd/Brother-*.ppd; do
    name="$(basename "$ppd")"
    gzip -c "$ppd" >"$ppd_dest_dir/$name.gz"
    chmod 0644 "$ppd_dest_dir/$name.gz"
done

# --- component package -------------------------------------------------------

component_pkg="$work/component.pkg"
pkgbuild --root "$root" --identifier "$pkg_id" --version "$version" \
    --install-location / --ownership recommended "$component_pkg" >/dev/null

# --- product archive ---------------------------------------------------------

sed -e "s/@VERSION@/$version/g" -e "s/@PKG_ID@/$pkg_id/g" -e "s/@COMPONENT_PKG@/component.pkg/g" \
    "$repo_root/scripts/pkg/distribution.xml.in" >"$work/distribution.xml"

mkdir -p "$repo_root/build"
output_pkg="$repo_root/build/brother-mac-driver-$version.pkg"
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
    productbuild --distribution "$work/distribution.xml" --package-path "$work" \
        --sign "$INSTALLER_IDENTITY" "$output_pkg" >/dev/null
else
    echo "no INSTALLER_IDENTITY set; producing an unsigned installer package"
    productbuild --distribution "$work/distribution.xml" --package-path "$work" "$output_pkg" >/dev/null
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$output_pkg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$output_pkg"
else
    echo "no NOTARY_PROFILE set; skipping notarization"
fi

# Entries named ._<file> are how a package payload carries extended attributes; Installer folds
# them back into the file and never creates them. Recent macOS tags every new file with
# com.apple.provenance, which cannot be removed, so they are listed apart from the real payload.
echo
echo "payload:"
pkgutil --payload-files "$component_pkg" | grep -v '/\._[^/]*$' || true

echo
echo "built $output_pkg"
