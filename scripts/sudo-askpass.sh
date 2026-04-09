#!/bin/bash
# sudo-askpass.sh — Acquire sudo credentials via macOS GUI dialog
#
# Used by xtrace/trace-record/sample-quick when profiling root-owned processes.
# Shows a native macOS password dialog (osascript) so it works from
# non-interactive terminals (LLM agents, IDE terminals, etc.).
#
# Usage (from other scripts):
#   source "$(dirname "$0")/sudo-askpass.sh"
#   ensure_sudo_if_needed "$TARGET_PID"
#   # Now sudo is primed — subsequent sudo calls won't prompt
#
# Or standalone:
#   ./sudo-askpass.sh            # just acquire sudo
#   ./sudo-askpass.sh 12345      # acquire if PID 12345 is root-owned

set -euo pipefail

# Check if a process is owned by root (or another user we can't attach to)
process_needs_sudo() {
    local pid="$1"
    local owner
    owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    
    if [ "$owner" = "root" ] || [ "$owner" != "$(whoami)" ]; then
        return 0  # needs sudo
    fi
    return 1  # our own process, no sudo needed
}

# Acquire sudo via macOS GUI dialog if not already primed
acquire_sudo() {
    # Already have sudo?
    if sudo -n true 2>/dev/null; then
        return 0
    fi

    echo "Root privileges required. Requesting via password dialog..." >&2

    # Use osascript to show a native macOS password dialog
    # This works from non-interactive terminals (LLM agents, SSH, etc.)
    local password
    password=$(osascript -e 'display dialog "xtrace needs administrator privileges to profile a root-owned process." with title "xtrace – sudo" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK"' -e 'text returned of result' 2>/dev/null) || {
        echo "Error: Password dialog cancelled or failed." >&2
        return 1
    }

    # Prime sudo with the password
    echo "$password" | sudo -S true 2>/dev/null || {
        echo "Error: Incorrect password." >&2
        return 1
    }

    echo "Sudo acquired." >&2
    return 0
}

# Main entry point: check if pid needs sudo, acquire if so
ensure_sudo_if_needed() {
    local pid="${1:-}"
    
    if [ -z "$pid" ]; then
        # No PID specified — caller wants sudo unconditionally
        acquire_sudo
        return $?
    fi

    if process_needs_sudo "$pid"; then
        local owner
        owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
        echo "Process $pid is owned by '$owner' — sudo required." >&2
        acquire_sudo
        return $?
    fi
    
    # Process is ours, no sudo needed
    return 0
}

# If run standalone (not sourced), acquire sudo
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ensure_sudo_if_needed "${1:-}"
fi
