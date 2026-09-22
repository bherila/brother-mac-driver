#!/bin/bash
# Runs Brother's own Linux filter as a reference encoder for XL2HB, the host-based colour
# language this driver does not implement yet (issue #21).
#
# usage: scripts/xl2hb-reference.sh <input.ppm> [output.xl2hb] [-- <filter options>]
#        scripts/xl2hb-reference.sh --setup      # fetch and install the reference only
#        scripts/xl2hb-reference.sh --manifest   # print what a run here would actually execute
#
# Why this exists: XL2HB has no public specification. Brother ships a filter that turns a PPM
# into an XL2HB job, so it can answer "what should these pixels encode to" byte for byte, which
# is the only way to write an encoder for this format without a printer to try it on.
#
# Nothing of Brother's is kept in this repository — this downloads it on demand. The package is
# theirs, under their licence; the driver's own files say they are GPL-2.0-or-later, but the LUT
# tables and the filter binary are not ours to redistribute, so they are not vendored here.
#
# This runs on Linux/x86. The filter is a 32-bit x86 binary needing only libc and libm, so an
# x86_64 host needs the 32-bit loader (`dpkg --add-architecture i386 && apt-get install libc6:i386`
# on Debian or Ubuntu); elsewhere `qemu-i386-static` runs it. It cannot run on macOS, which is why
# this is not part of any CI job.
set -euo pipefail

# The HL-3140CW's driver. Any host-based colour model's package carries the same filter under a
# different name; this one is pinned so a changed upload is noticed rather than silently used.
model="hl3140cw"
package="${model}lpr-1.1.2-1.i386.deb"
url="https://www.brother.com/pub/bsc/linux/dlf/$package"
sha256="601f392b52ed7080f71b780181823bb8f6abfd0591146b452ba1f23e21f9f865"

root="${BROTHER_ROOT:-/opt/brother/Printers/$model}"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/brother-mac-driver"
filter="$root/lpd/br${model}filter"

# The package checksum is verified on every run, and the tree is replaced from the verified
# package every time.
#
# The earlier version returned early whenever an executable was already at $filter, so any binary
# that happened to be sitting there was used unchecked — and a run of it was then described as
# "the pinned reference", which it had not been shown to be. An install is not evidence of its own
# provenance. Re-extracting costs a fraction of a second and means the binary that runs is the one
# the checksum covers.
setup() {
    echo "verifying Brother's reference filter ($package)" >&2
    mkdir -p "$cache"
    if [[ ! -f "$cache/$package" ]]; then
        curl -fsSL -o "$cache/$package.part" "$url"
        mv "$cache/$package.part" "$cache/$package"
    fi
    if ! echo "$sha256  $cache/$package" | sha256sum -c --status; then
        echo "$package does not match the pinned checksum; refusing to run it" >&2
        echo "  expected $sha256" >&2
        echo "  got      $(sha256sum <"$cache/$package" | cut -d' ' -f1)" >&2
        exit 1
    fi

    # The filter looks for its lookup tables under /opt/brother, so it is installed where its own
    # package would put it rather than run from a scratch directory.
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' RETURN
    dpkg-deb -x "$cache/$package" "$work"
    mkdir -p "$(dirname "$root")"
    rm -rf "$root"
    cp -r "$work/opt/brother/Printers/$model" "$(dirname "$root")/"
    echo "installed the reference under $root" >&2
}

# What a run actually used, so a later one can be compared with it rather than assumed equal to
# it. The package checksum says what was downloaded; this says what was executed.
manifest() {
    echo "# xl2hb-reference manifest"
    echo "package        $package"
    echo "package-sha256 $sha256"
    echo "filter-sha256  $(sha256sum "$filter" | cut -d" " -f1)"
    for table in "$root/inf/paperinfij2" "$root/inf/br${model}rc"; do
        [[ -r "$table" ]] && echo "$(basename "$table")   $(sha256sum "$table" | cut -d" " -f1)"
    done
}

run() {
    local input="$1" output="$2"
    shift 2
    if [[ ! -r "$input" ]]; then
        echo "cannot read '$input'" >&2
        exit 1
    fi
    # JOBTIME carries the wall clock, so two runs of the same page differ in the PJL header and
    # nowhere else. It is blanked here, which is what makes this a byte-exact reference.
    "$filter" -pi "$root/inf/paperinfij2" -rc "$root/inf/br${model}rc" "$@" <"$input" \
        | sed 's/@PJL SET JOBTIME = "[0-9]*"/@PJL SET JOBTIME = "0"/' >"$output"
    echo "$output: $(wc -c <"$output" | tr -d ' ') bytes of XL2HB from $input" >&2
    # Both ends of the run, so a claim about what these bytes mean can be checked against the
    # bytes it was made from.
    echo "  in  $(sha256sum "$input" | cut -d" " -f1)" >&2
    echo "  out $(sha256sum "$output" | cut -d" " -f1)" >&2
}

if [[ "${1:-}" == "--setup" ]]; then
    setup
    exit 0
fi
if [[ "${1:-}" == "--manifest" ]]; then
    setup
    manifest
    exit 0
fi
if [[ $# -lt 1 ]]; then
    sed -n '2,8p' "$0" >&2
    exit 64
fi

setup
input="$1"
output="${2:-${input%.*}.xl2hb}"
shift $(($# > 1 ? 2 : 1))
[[ "${1:-}" == "--" ]] && shift
run "$input" "$output" "$@"
