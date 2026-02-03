#!/bin/bash

DIR=$(osascript -e 'tell application "Finder" to get POSIX path of (target of front window as alias)' 2>/dev/null)
[ -z "$DIR" ] && DIR="$HOME/Desktop"
if ! command -v run &> /dev/null; then exit 1; fi
osascript -e "tell application \"Terminal\" to do script \"cd \\\"$DIR\\\" && run\"" -e "tell application \"Terminal\" to activate"
