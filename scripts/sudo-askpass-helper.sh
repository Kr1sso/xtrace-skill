#!/bin/bash
# Used as SUDO_ASKPASS — shows macOS dialog and prints password to stdout
exec osascript -e 'display dialog "xtrace needs administrator privileges to profile a root-owned process." with title "xtrace – sudo" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK"' -e 'text returned of result' 2>/dev/null
