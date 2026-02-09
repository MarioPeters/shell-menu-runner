#!/bin/bash

# Minimal test script to isolate the docker profile issue
set -euo pipefail

# Define necessary variables
HOME="/Users/mariopeters"
ALIAS_FILE="$HOME/.run_aliases"

# Simulate the relevant parts of the script
load_aliases() {
    echo "DEBUG: Entering load_aliases"
    [ ! -f "$ALIAS_FILE" ] && touch "$ALIAS_FILE"
    echo "DEBUG: Exiting load_aliases"
}

resolve_alias() {
    local input="$1"
    [ ! -f "$ALIAS_FILE" ] && echo "$input" && return 0
    
    local resolved
    resolved=$(grep "^${input}=" "$ALIAS_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2-)
    
    if [ -n "$resolved" ]; then
        echo "$resolved"
    else
        echo "$input"
    fi
}

find_named_config() {
    local name="$1"
    set +e
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/.tasks.$name" ]; then echo "$d/.tasks.$name"; set -e; return 0; fi
        d=$(dirname "$d")
    done
    set -e
    return 1
}

# Main execution logic
args=("docker")
if [ "${#args[@]}" -gt 0 ]; then
    echo "DEBUG: Starting profile resolution"
    load_aliases
    profile_input="${args[0]}"
    echo "DEBUG: profile_input = $profile_input"
    profile="$(resolve_alias "$profile_input")"
    echo "DEBUG: profile = $profile"

    if found=$(find_named_config "$profile"); then
        echo "DEBUG: Found local config: $found"
        active_mode="local"
        config_path="$found"
    elif [ -f "$HOME/.tasks.$profile" ]; then
        echo "DEBUG: Found global config: $HOME/.tasks.$profile"
        active_mode="global"
        config_path="$HOME/.tasks.$profile"
    else
        echo "DEBUG: No profile found"
        echo "Profile '$profile' not found. Using default config."
    fi
    
    echo "DEBUG: config_path = $config_path"
    echo "DEBUG: active_mode = $active_mode"
fi

echo "DEBUG: Script completed successfully"