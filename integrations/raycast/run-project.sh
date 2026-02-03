#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Run Project
# @raycast.mode silent
# @raycast.packageName Dev Tools
# @raycast.icon 🚀
if ! command -v run &> /dev/null; then echo "Error: Install 'run' first."; exit 1; fi
DIR=$(osascript -e 'tell application "Finder" to get POSIX path of (target of front window as alias)' 2>/dev/null)
[ -z "$DIR" ] && DIR="$HOME/Desktop"
osascript -e "tell application \"Terminal\" to do script \"cd \\\"$DIR\\\" && run\"" -e "tell application \"Terminal\" to activate"
