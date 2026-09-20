#!/bin/bash
# Sourced by the install and uninstall scripts.
#
# run_as_root <script-file> runs a bash script as root. With a terminal (or when sudo needs no
# password) that is plain sudo. Without one - started from an editor, an agent, a GUI - sudo
# cannot ask for a password, so the system's own administrator dialog is used instead; the
# password goes to macOS, never through these scripts.
#
# DRY_RUN=1 prints the script and how it would have been run, and changes nothing.
run_as_root() {
    local script="$1" method
    if [[ "$(id -u)" -eq 0 ]]; then
        method="directly (already root)"
    elif [[ -t 0 ]] || sudo -n true 2>/dev/null; then
        method="with sudo"
    else
        method="through the macOS administrator dialog (no terminal for sudo to prompt on)"
    fi

    if [[ -n "${DRY_RUN:-}" ]]; then
        echo "DRY_RUN: would run this as root, $method:"
        sed 's/^/    /' "$script"
        return
    fi

    echo "running the privileged step $method"
    case "$method" in
    directly*) bash "$script" ;;
    "with sudo") sudo bash "$script" ;;
    *)
        # The dialog route returns the script's output only once it has finished, and turns a
        # cancelled dialog or a failed step into an AppleScript error; say what that means.
        if ! osascript \
            -e 'on run argv' \
            -e 'do shell script "/bin/bash " & quoted form of item 1 of argv with prompt "brother-mac-driver needs administrator access to change /Library/Printers." with administrator privileges' \
            -e 'end run' "$script"; then
            echo "the privileged step did not complete (dialog cancelled, or a command in it failed)" >&2
            return 1
        fi
        ;;
    esac
}
