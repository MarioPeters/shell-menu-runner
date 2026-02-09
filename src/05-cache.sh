# ==============================================================================
#  CACHE MANAGEMENT
# ==============================================================================

readonly CACHE_DIR="/tmp/.run_cache_$$"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

get_cache_file() {
    local config_hash
    config_hash=$(echo "$config_path" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "default")
    echo "$CACHE_DIR/state_${config_hash}"
}

get_profile_cache_file() {
    echo "$CACHE_DIR/profiles_cache"
}

cache_profiles() {
    local cache_file
    cache_file=$(get_profile_cache_file)
    local cache_age=0
    
    if [ -f "$cache_file" ]; then
        cache_age=$(( $(date +%s) - $(stat -f '%m' "$cache_file" 2>/dev/null || stat -c '%Y' "$cache_file" 2>/dev/null || echo 0) )) || cache_age=0
    fi
    
    # Cache valid for 60 seconds
    if [ "$cache_age" -lt 60 ] && [ -f "$cache_file" ]; then
        cat "$cache_file"
        return 0
    fi
    
    # Regenerate cache
    list_available_profiles > "$cache_file"
    cat "$cache_file"
}

clear_cache() {
    rm -rf "$CACHE_DIR" 2>/dev/null || true
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
}

save_state() {
    local cf
    cf=$(get_cache_file)
    mkdir -p "$(dirname "$cf")" 2>/dev/null || true
    if ! echo "$selected_index" > "$cf" 2>/dev/null; then
        echo "WARN: failed to save state to $cf" >&2
    fi
}

load_state() {
    local c
    c=$(get_cache_file)
    if [ -f "$c" ]; then
        selected_index=$(cat "$c")
    fi
}

# Cleanup cache on exit
trap 'rm -rf "$CACHE_DIR" 2>/dev/null' EXIT INT TERM
