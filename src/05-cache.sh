# ==============================================================================
#  CACHE MANAGEMENT
# ==============================================================================

readonly CACHE_DIR="/tmp/.run_cache_$$"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

# Persistent cache directory — survives between runs.
# CACHE_DIR above is removed by the EXIT trap, so anything stored there would
# never be reused: the profile list cache (60s TTL) and the selected-index
# state need a directory that outlives the process.
RUN_CACHE_DIR="${RUN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/shell-menu-runner}"
if ! mkdir -p "$RUN_CACHE_DIR" 2>/dev/null; then
    # Fallback: no writable persistent location -> cache never hits, but the
    # script keeps working.
    RUN_CACHE_DIR="$CACHE_DIR"
fi
readonly RUN_CACHE_DIR

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
    _cache_file_last_result="$RUN_CACHE_DIR/state_${config_hash}"
    echo "$_cache_file_last_result"
}

get_profile_cache_file() {
    echo "$RUN_CACHE_DIR/profiles_cache"
}

# Caches the profile list for 60 seconds in the persistent cache directory.
# NOTE: not wired into the UI paths on purpose — a 60 s TTL would hide a
# freshly created .tasks.<profile> from the profile menu, and the listing
# itself is only a handful of stat calls.
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
    rm -rf "$RUN_CACHE_DIR" 2>/dev/null || true
    mkdir -p "$RUN_CACHE_DIR" 2>/dev/null || true
}

save_state() {
    local cf
    cf=$(get_cache_file)
    # Bash string-op instead of $(dirname) subshell: cf is always $RUN_CACHE_DIR/state_HASH
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
# Only the per-run scratch space (CACHE_DIR) is removed — the persistent cache
# (RUN_CACHE_DIR) must survive so that the profile/state cache can be reused.
cleanup_wrapper() {
    rm -rf "$CACHE_DIR" 2>/dev/null
    if command -v cleanup_terminal >/dev/null 2>&1; then
        cleanup_terminal
    fi
}
trap cleanup_wrapper EXIT
trap 'cleanup_wrapper; exit 130' INT TERM
