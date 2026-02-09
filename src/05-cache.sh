# ==============================================================================
#  CACHE MANAGEMENT
# ==============================================================================

readonly CACHE_DIR="/tmp/.run_cache_$$"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

# Memoization: Hash wird nur neu berechnet, wenn config_path wechselt
_cache_file_last_path=""
_cache_file_last_result=""

get_cache_file() {
    # Gespeichertes Ergebnis zurückgeben, falls config_path unverändert
    if [ "$config_path" = "$_cache_file_last_path" ] && [ -n "$_cache_file_last_result" ]; then
        echo "$_cache_file_last_result"
        return 0
    fi
    local config_hash
    if command -v md5sum &>/dev/null; then
        config_hash=$(printf "%s" "$config_path" | md5sum | awk '{print $1}')
    elif command -v md5 &>/dev/null; then
        config_hash=$(printf "%s" "$config_path" | md5 -q)
    elif command -v shasum &>/dev/null; then
        config_hash=$(printf "%s" "$config_path" | shasum -a 256 | awk '{print $1}')
    else
        config_hash="default"
    fi
    _cache_file_last_path="$config_path"
    _cache_file_last_result="$CACHE_DIR/state_${config_hash}"
    echo "$_cache_file_last_result"
}

get_profile_cache_file() {
    echo "$CACHE_DIR/profiles_cache"
}

cache_profiles() {
    local cache_file
    cache_file=$(get_profile_cache_file)
    local cache_age=100000 
    
    if [ -f "$cache_file" ]; then
        local mtime
        mtime=$(get_file_mtime "$cache_file")
        local now
        now=$(date +%s)
        cache_age=$(( now - mtime ))
    fi
    
    # Cache valid for 60 seconds
    if [ "$cache_age" -ge 0 ] && [ "$cache_age" -lt 60 ]; then
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
    # Bash string-op instead of $(dirname) subshell: cf is always $CACHE_DIR/state_HASH
    mkdir -p "${cf%/*}" 2>/dev/null || true
    if ! echo "$selected_index" > "$cf" 2>/dev/null; then
        echo "WARN: failed to save state to $cf" >&2
    fi
}

load_state() {
    local c
    c=$(get_cache_file)
    if [ -f "$c" ]; then
        # read statt cat: kein Subshell-Fork für eine einzelne Zeile
        { read -r selected_index < "$c"; } 2>/dev/null || true
    fi
}

# Cleanup cache on exit
cleanup_wrapper() {
    rm -rf "$CACHE_DIR" 2>/dev/null
    if command -v cleanup_terminal >/dev/null 2>&1; then
        cleanup_terminal
    fi
}
trap cleanup_wrapper EXIT
trap 'cleanup_wrapper; exit 130' INT TERM
