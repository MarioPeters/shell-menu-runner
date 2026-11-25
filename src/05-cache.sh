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
    # Fallback: a stable directory that survives the run.  The per-run
    # scratch space ($CACHE_DIR) is removed by the EXIT trap — the persisted
    # state (the selected index) was therefore lost after every run.
    RUN_CACHE_DIR="${TMPDIR:-/tmp}/.shell-menu-runner-${UID:-0}"
    if ! mkdir -p "$RUN_CACHE_DIR" 2>/dev/null; then
        # Last resort: no persistent location available -> the state is not
        # persisted, but the runner keeps working.
        RUN_CACHE_DIR="$CACHE_DIR"
    fi
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
    # hash_string: reiner Bash-Hash statt "md5sum | awk" (2 Forks pro Aufruf).
    local config_hash
    config_hash=$(hash_string "$config_path")
    _cache_file_last_path="$config_path"
    _cache_file_last_result="$RUN_CACHE_DIR/state_${config_hash}"
    echo "$_cache_file_last_result"
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
        local _stored_index=""
        { read -r _stored_index < "$c"; } 2>/dev/null || true
        # Nur gültige Indizes übernehmen — ein beschädigter State-File darf
        # keinen arithmetischen Fehler in der Auswahl-Logik auslösen.
        if is_uint "${_stored_index:-}" && [ "${_stored_index:-0}" -ge 0 ]; then
            selected_index="$_stored_index"
        fi
    fi
    return 0
}

# Cleanup cache on exit
# Only the per-run scratch space (CACHE_DIR) is removed — the persistent cache
# (RUN_CACHE_DIR) must survive so that the profile/state cache can be reused.
cleanup_wrapper() {
    # A running timeout watchdog must not outlive the runner: it would keep
    # running (with its "sleep") until the timeout expires.
    if [ -n "${_WATCHDOG_PID:-}" ]; then
        if command -v kill_children >/dev/null 2>&1; then
            kill_children "$_WATCHDOG_PID" TERM
        fi
        kill "$_WATCHDOG_PID" 2>/dev/null || true
        _WATCHDOG_PID=""
    fi
    rm -rf "$CACHE_DIR" 2>/dev/null
    if command -v cleanup_terminal >/dev/null 2>&1; then
        cleanup_terminal
    fi
}
trap cleanup_wrapper EXIT
trap 'cleanup_wrapper; exit 130' INT TERM
