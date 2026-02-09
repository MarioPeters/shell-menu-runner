#!/bin/bash

# Test script to debug the docker profile issue
set -euo pipefail

echo "=== Debug Test ==="
echo "PWD: $PWD"
echo "HOME: $HOME"

# Check alias file
echo "Alias file exists: $([ -f ~/.run_aliases ] && echo "yes" || echo "no")"

# Test resolve_alias function (simplified version)
resolve_alias_test() {
    local input="$1"
    local ALIAS_FILE="$HOME/.run_aliases"
    [ ! -f "$ALIAS_FILE" ] && echo "$input" && return 0
    
    local resolved
    resolved=$(grep "^${input}=" "$ALIAS_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2-)
    
    if [ -n "$resolved" ]; then
        echo "$resolved"
    else
        echo "$input"
    fi
}

profile_input="docker"
profile=$(resolve_alias_test "$profile_input")
echo "Profile input: $profile_input"
echo "Profile resolved: $profile"

# Check if docker profile exists
echo "Docker profile exists: $([ -f "$HOME/.tasks.docker" ] && echo "yes" || echo "no")"
echo "Docker profile path: $HOME/.tasks.docker"

# Test the logic from the script
echo "=== Testing profile resolution logic ==="
if [ -f "$HOME/.tasks.$profile" ]; then
    echo "✅ Found global profile: $HOME/.tasks.$profile"
else
    echo "❌ Global profile not found: $HOME/.tasks.$profile"
fi