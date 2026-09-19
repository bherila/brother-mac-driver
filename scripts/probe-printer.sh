#!/bin/bash
# Read-only identification of a USB-connected Brother printer, meant to be run by a
# non-expert and pasted into a bug report. Never changes print configuration.
#
# usage: scripts/probe-printer.sh
#   PROBE_SAMPLE=<file>   skip the real system queries; instead run the redaction and
#                         device-id parsing below on the sample file's contents, so
#                         those two functions can be exercised without hardware.
set -euo pipefail

# --- redaction ---------------------------------------------------------------
# Reads text on stdin and writes it back with every serial-number-shaped field blanked:
# system_profiler's "Serial Number:", an lpinfo URI's "?serial=...", and a device-id's serial
# field under any of its names, in any letter case. The key must start a word, so a field that
# merely ends in the same letters (DSN:) is left alone. sed here has no case-insensitive flag,
# hence the bracket pairs.
redact() {
    local key='([Ss][Ee][Rr][Ii][Aa][Ll][Nn][Uu][Mm][Bb][Ee][Rr]|[Ss][Ee][Rr][Ii][Aa][Ll]|[Ss][Ee][Rr][Nn]|[Ss][Nn])'
    # A quoted value is taken whole, spaces included, before the unquoted rule gets a look at it.
    sed -E \
        -e 's/([Ss][Ee][Rr][Ii][Aa][Ll] [Nn][Uu][Mm][Bb][Ee][Rr]: *).*/\1REDACTED/' \
        -e "s/(^|[^A-Za-z0-9])$key([:=])\"[^\"]*\"?/\\1\\2\\3REDACTED/g" \
        -e "s/(^|[^A-Za-z0-9])$key([:=])[^;&[:space:]]*/\\1\\2\\3REDACTED/g"
}

# --- device-id parsing ---------------------------------------------------------
# Reads an IEEE-1284 device-id string on stdin and reports the model and which
# printer languages it advertises, in particular whether PCL XL is one of them.
describe_device_id() {
    local device_id model commands
    device_id="$(cat)"
    # grep exits 1 when a field is absent; that must not be fatal under set -e.
    # Fields come in a short and a long spelling (MDL/MODEL, CMD/COMMAND SET), and a key only counts
    # at the start of a field. Values are trimmed: "PJL, PCLXL" must still yield PCLXL.
    model="$(printf ';%s' "$device_id" | grep -oiE ';[[:space:]]*(MDL|MODEL):[^;]*' | head -1 | cut -d: -f2- | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')" || true
    commands="$(printf ';%s' "$device_id" | grep -oiE ';[[:space:]]*(CMD|COMMAND SET):[^;]*' | head -1 | cut -d: -f2- | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')" || true

    echo "  model: ${model:-unknown}"
    if [[ -z "$commands" ]]; then
        echo "  no CMD/COMMAND SET field in device-id; cannot determine supported languages"
        return
    fi
    echo "  languages reported: $(printf '%s' "$commands" | paste -sd, -)"
    if printf '%s\n' "$commands" | grep -qiE '^(pclxl|pcl6|pxl)$'; then
        echo "  PCL XL (or PCL6/PXL) is present -> supported by this driver's PCL XL backend"
    elif printf '%s\n' "$commands" | grep -qiE '^(xl2hb|hbp)'; then
        echo "  only host-based languages (XL2HB/HBP-style) reported -> not supported yet"
    else
        echo "  none of PCLXL/PCL6/PXL or XL2HB/HBP found; support is unclear from this device-id alone"
    fi
}

# --- self-test ---------------------------------------------------------------
# Exercises redact() and describe_device_id() on saved sample text instead of the
# real system, so they can be checked on a machine with no Brother printer attached.
if [[ -n "${PROBE_SAMPLE:-}" ]]; then
    echo "== self-test (PROBE_SAMPLE=$PROBE_SAMPLE) =="
    echo "-- redaction --"
    redact <"$PROBE_SAMPLE"
    echo
    echo "-- device-id parsing (last line of the sample, after redaction) --"
    tail -n1 "$PROBE_SAMPLE" | redact | describe_device_id
    exit 0
fi

# --- USB device listing -------------------------------------------------------
# Prints the device's name line and every more-indented field under it; skips
# everything else in the (large, deeply nested) system_profiler tree.
extract_brother_usb() {
    awk '
        function indent(s,    i) { i = 0; while (i < length(s) && substr(s, i + 1, 1) == " ") i++; return i }
        /:$/ && /[Bb]rother/ { name_indent = indent($0); print; printing = 1; next }
        printing { if (indent($0) > name_indent) { print; next } else { printing = 0 } }
    '
}

extract_brother_lpinfo() {
    awk '
        /^Device:/ {
            if (block != "" && block ~ /[Bb]rother/) print block
            block = $0
            next
        }
        NF { block = block "\n" $0 }
        END { if (block != "" && block ~ /[Bb]rother/) print block }
    '
}

echo "macOS $(sw_vers -productVersion) ($(uname -m))"
echo

usb_block="$(system_profiler SPUSBHostDataType 2>/dev/null | extract_brother_usb)"
if [[ -z "$usb_block" ]]; then
    usb_block="$(system_profiler SPUSBDataType 2>/dev/null | extract_brother_usb)"
fi

echo "== USB (Brother) =="
if [[ -n "$usb_block" ]]; then
    printf '%s\n' "$usb_block" | redact
else
    echo "none found"
fi
echo

echo "== lpinfo (Brother) =="
if ! lpinfo_output="$(lpinfo -l -v 2>&1)"; then
    echo "lpinfo failed; it can need an admin account and can take ~10s -- try again from an admin account" >&2
    lpinfo_output=""
fi
lpinfo_block="$(printf '%s\n' "$lpinfo_output" | extract_brother_lpinfo)"
if [[ -n "$lpinfo_block" ]]; then
    printf '%s\n' "$lpinfo_block" | redact
else
    echo "none found"
fi
echo

if [[ -z "$usb_block" && -z "$lpinfo_block" ]]; then
    echo "No Brother printer found on this Mac."
    exit 0
fi

echo "== printer languages =="
device_ids="$(printf '%s\n' "$lpinfo_block" | grep -oE 'device-id[[:space:]]*=.*' | sed -E 's/^device-id[[:space:]]*=[[:space:]]*//')" || true
if [[ -z "$device_ids" ]]; then
    echo "no device-id reported by lpinfo; cannot determine supported languages"
else
    while IFS= read -r device_id; do
        [[ -n "$device_id" ]] || continue
        describe_device_id <<<"$device_id"
    done <<<"$device_ids"
fi
