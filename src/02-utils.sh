# ==============================================================================
#  POLYFILLS & UTILS
# ==============================================================================

# Use ripgrep (rg) when available — same flags, faster on large inputs.
# Falls back to system grep transparently.
if command -v rg >/dev/null 2>&1; then
    _grep() { rg "$@"; }
else
    _grep() { grep "$@"; }
fi

# Gibt das Verzeichnis einer Config-Datei zurück.
#
# Drei Sonderfälle, die alle Previously zu einem falschen Arbeitsverzeichnis
# führten:
#   * Pfad ohne Slash ("tasks")  -> "." (das aktuelle Verzeichnis)
#   * Pfad im Wurzelverzeichnis ("/.tasks") -> "/" — "${path%/*}" liefert
#     hier "" und ein "cd ''" schlägt fehl (das Task lief im falschen
#     Verzeichnis)
#   * leerer Pfad -> "." (kein Kontext vorhanden)
config_dir_of() {
    local _path="${1:-}"
    local _dir
    [ -z "$_path" ] && { printf "."; return 0; }
    _dir="${_path%/*}"
    # Kein Slash im Pfad -> der Dateiname selbst wäre das "Verzeichnis"
    [ "$_dir" = "$_path" ] && _dir="."
    # Pfad im Wurzelverzeichnis -> "${path%/*}" ist leer
    [ -z "$_dir" ] && _dir="/"
    printf "%s" "$_dir"
}
cleanup_terminal() {
    # Reset the terminal mode first: if the script dies inside the raw mode
    # the shell would stay without echo and without line editing.
    stty sane 2>/dev/null || true
    # The cursor-restore sequence is terminal control output, not data: it must
    # not end up in the stdout stream of `run --version` / `run --list`.
    # It is only emitted when stdout is a terminal and goes to stderr, so that a
    # piped stdout stays free of escape sequences.
    [ -t 1 ] || return 0
    if [ -n "${TPUT_CNORM:-}" ]; then
        echo -ne "$TPUT_CNORM" >&2
    else
        tput cnorm >&2 2>/dev/null || true
    fi
    echo -e "${COLOR_RESET}" >&2
}
handle_interrupt() { cleanup_terminal; clear; exit 130; }
trap cleanup_terminal EXIT
trap handle_interrupt INT TERM
hide_cursor() {
    if [ -n "${TPUT_CIVIS:-}" ]; then
        echo -ne "$TPUT_CIVIS"
    else
        tput civis 2>/dev/null || true
    fi
}

# Color output helpers
warn() { echo -e "${COLOR_WARN}$*${COLOR_RESET}"; }
error() { echo -e "${COLOR_ERR}$*${COLOR_RESET}"; }
success() { echo -e "${COLOR_SEL}✔ $*${COLOR_RESET}"; }

sanitize_filename() { sed 's/ /_/g; s/[^A-Za-z0-9._-]//g' <<< "$1"; }

# Sperrt eine Datei gegen konkurrierende Read-Modify-Write-Zyklen.
#
# "mkdir" ist auf POSIX-Dateisystemen atomar und damit als Lock geeignet
# (ein exklusiv angelegtes "lockfile" ist nicht überall verfügbar).  Das
# Sperr-Verzeichnis liegt neben der Datei — es darf nicht in $CACHE_DIR
# liegen, das ist pro Prozess und würde zwischen Instanzen nicht teilen.
_lock_acquire() {
    local _dir="${1}.lock"
    # Das übergeordnete Verzeichnis der Sperre — bei einem Pfad ohne
    # Slash (ein blosser Dateiname) ist es das aktuelle Verzeichnis.
    local _parent="${_dir%/*}"
    [ "$_parent" = "$_dir" ] && _parent="."
    local _n=0
    while ! mkdir "$_dir" 2>/dev/null; do
        _n=$(( _n + 1 ))
        # Kann das Verzeichnis nicht angelegt werden (z.B. ein nur lesbares
        # HOME), gibt es keine Sperre — dann nicht 2 s warten.
        if [ "$_n" -eq 1 ] && [ ! -w "$_parent" ]; then
            break
        fi
        # Der kritische Abschnitt ist kurz (wc + tail + mv).  Nach 2 s wird
        # die Sperre übernommen — ein hängender Lock (z.B. von einem
        # abgestürzten Prozess) darf den Runner nicht blockieren.
        if [ "$_n" -ge 20 ]; then
            rm -rf "$_dir" 2>/dev/null || true
            break
        fi
        sleep 0.1
    done
    return 0
}

_lock_release() {
    rm -rf "${1}.lock" 2>/dev/null || true
    return 0
}

# Kürzt eine Datei auf maximal $2 Zeilen (via tail).
# Wird von add_to_history, add_to_recent und save_search_term genutzt.
# Die Temp-Datei enthält die PID, damit parallele run.sh-Instanzen sich nicht
# gegenseitig die Temp-Datei wegschnappen (Race → "mv: No such file or directory").
#
# Die Sperre wird nicht genommen — der Aufrufer hält sie bereits.
_trim_file_to_lines() {
    local file="$1" max="$2"
    [ -f "$file" ] || return 0
    local lines
    lines=$(wc -l < "$file" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$max" ]; then
        local tmp="${file}.tmp.$$"
        if tail -n "$max" "$file" > "$tmp"; then
            mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
        else
            rm -f "$tmp"
        fi
    fi
    return 0
}

trim_file_to_lines() {
    local file="$1" max="$2"
    [ -f "$file" ] || return 0
    _lock_acquire "$file"
    _trim_file_to_lines "$file" "$max"
    _lock_release "$file"
    return 0
}

# Hängt eine Zeile an eine Datei an und kürzt sie anschließend auf max Zeilen.
#
# Append und Kürzung laufen unter einer Sperre: ohne Sperre verlor ein
# parallel laufender Prozess Einträge (gemessen: 12 parallele Schreiber,
# 5 verlorene Einträge) — das "tail + mv" ersetzte die Datei, während ein
# anderer Prozess gerade anhängte.
append_line() {
    local file="$1" line="$2" max="${3:-0}"
    [ -n "$file" ] || return 0
    _lock_acquire "$file"
    printf '%s\n' "$line" >> "$file"
    if [ "$max" -gt 0 ]; then
        _trim_file_to_lines "$file" "$max"
    fi
    _lock_release "$file"
    return 0
}

trim_whitespace() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf "%s" "$s"
}

# Splits a "level|name|command|description" line into its fields.
#
# A here-string (`IFS='|' read -r a b c d <<< "$line"`) creates a temporary
# file in Bash 3.2 and costs ~130 µs per call — in the menu loops (once per
# config line and once per visible entry) that alone dominated the redraw
# time.  Parameter expansion needs ~10 µs and no fork.
#
# Result: _f_level, _f_name, _f_cmd, _f_desc
# The last field keeps any remaining separators (same as `read`).
_f_level=""
_f_name=""
_f_cmd=""
_f_desc=""
split_task_line() {
    local _rest="$1"
    # Each field is extracted with exactly one expansion; the original
    # implementation needed two (test + assignment) per field.
    _f_level="${_rest%%|*}"
    if [ "$_f_level" = "$_rest" ]; then
        # No separator in the line
        _f_name=""
        _f_cmd=""
        _f_desc=""
        return 0
    fi
    _rest="${_rest#*|}"
    _f_name="${_rest%%|*}"
    if [ "$_f_name" = "$_rest" ]; then
        _f_cmd=""
        _f_desc=""
        return 0
    fi
    _rest="${_rest#*|}"
    _f_cmd="${_rest%%|*}"
    if [ "$_f_cmd" = "$_rest" ]; then
        _f_desc=""
        return 0
    fi
    _rest="${_rest#*|}"
    _f_desc="$_rest"
    return 0
}

# True when the line is a comment or a meta line that is not a task.
#
# Replaces five regex matches per config line with a single case statement
# (a regex match costs ~4 µs, a case pattern ~1 µs).
is_meta_task_line() {
    local _line="$1"
    # Leading whitespace is stripped for the check (comments may be indented)
    case "${_line#"${_line%%[![:space:]]*}"}" in
        \#*|TIMEOUT=*|VAR_*|THEME:*|TITLE:*) return 0 ;;
    esac
    return 1
}

# Change stamp of a file: "<mtime>:<size>".
#
# The mtime alone has a resolution of one second — a config that is edited
# and read back within the same second would not invalidate the menu cache
# and the new tasks would stay invisible.  The size makes the stamp change
# in that case as well.
get_file_stamp() {
    local file="$1"
    if [ -z "${_STAT_STAMP_CMD:-}" ]; then
        if stat -f '%m:%z' / >/dev/null 2>&1; then
            _STAT_STAMP_CMD="stat -f %m:%z"
        else
            _STAT_STAMP_CMD="stat -c %Y:%s"
        fi
    fi
    $_STAT_STAMP_CMD "$file" 2>/dev/null || echo "0:0"
}

# Change stamp of several files at once: one line per file, space separated.
#
# One `stat` call for all files instead of one per file — the menu cache
# checks the stamp of the config *and* of its overlays (.tasks.local,
# .tasks.dev) on every rebuild, and each additional fork costs ~2 ms.
#
# Usage: get_files_stamp <file> [file...]
get_files_stamp() {
    [ $# -eq 0 ] && { printf ""; return 0; }
    if [ -z "${_STAT_STAMP_CMD:-}" ]; then
        if stat -f '%m:%z' / >/dev/null 2>&1; then
            _STAT_STAMP_CMD="stat -f %m:%z"
        else
            _STAT_STAMP_CMD="stat -c %Y:%s"
        fi
    fi
    # Missing files must not abort the stamp — they get the "0:0" fallback.
    local _existing=()
    local _f
    for _f in "$@"; do
        [ -f "$_f" ] && _existing+=("$_f")
    done
    [ ${#_existing[@]} -eq 0 ] && { printf "0:0"; return 0; }
    $_STAT_STAMP_CMD "${_existing[@]}" 2>/dev/null | tr '\n' ' ' || printf "0:0"
    return 0
}

# Device and inode of a file — used to detect symlinked duplicates.
#
# "ls -i" is not used: it does not work for arbitrary paths on all systems.
# macOS' stat does not follow symlinks without "-L" (GNU stat always does).
get_file_id() {
    local file="$1"
    if [ -z "${_STAT_ID_CMD:-}" ]; then
        if stat -L -f '%d:%i' / >/dev/null 2>&1; then
            _STAT_ID_CMD="stat -L -f %d:%i"
        elif stat -f '%d:%i' / >/dev/null 2>&1; then
            _STAT_ID_CMD="stat -f %d:%i"
        else
            _STAT_ID_CMD="stat -c %d:%i"
        fi
    fi
    $_STAT_ID_CMD "$file" 2>/dev/null || echo ""
}

# Splits a string on a single separator character.
#
# Replaces "IFS=',' read -r -a arr <<< "$str"": a here-string creates a
# temporary file in Bash 3.2 (~130 µs) and the IFS-split silently depends on
# the caller's IFS.  Result: _SPLIT_ARR (array).
_SPLIT_ARR=()
split_by_char() {
    local sep="$1" s="$2"
    _SPLIT_ARR=()
    [ -z "$s" ] && return 0
    local rest="$s" part
    while :; do
        case "$rest" in
            *"$sep"*)
                part="${rest%%"$sep"*}"
                _SPLIT_ARR+=("$part")
                rest="${rest#*"$sep"}"
                ;;
            *)
                _SPLIT_ARR+=("$rest")
                break
                ;;
        esac
    done
    return 0
}

# Saves the current errexit/pipefail state.
#
# Functions that switch shell options temporarily (parse_config_vars,
# load_task_vars) must restore the previous state instead of forcing "set -e"
# — the interactive menu loop runs with "set +e" and a blind "set -e" would
# end the whole menu on the first failing command.
_ERREXIT_WAS=0
_PIPEFAIL_WAS=0
save_shell_opts() {
    case "$-" in *e*) _ERREXIT_WAS=1 ;; *) _ERREXIT_WAS=0 ;; esac
    case "$-" in *P*) _PIPEFAIL_WAS=1 ;; *) _PIPEFAIL_WAS=0 ;; esac
    return 0
}

restore_shell_opts() {
    if [ "${_ERREXIT_WAS:-0}" -eq 1 ]; then set -e; else set +e; fi
    if [ "${_PIPEFAIL_WAS:-0}" -eq 1 ]; then set -o pipefail; else set +o pipefail; fi
    return 0
}

# Prints a short, stable hash of a string (FNV-1a, 32 bit).
#
# Replaces "md5sum | awk" (2 forks) for cache file names.  The hash only has
# to be stable across runs of the same installation — it is not a security
# boundary.  LC_ALL=C makes the result byte-based and therefore independent
# of the locale.
hash_string() {
    local s="$1"
    local LC_ALL=C
    local h=2166136261 i c len=${#1} code
    for (( i=0; i<len; i++ )); do
        c=${s:i:1}
        printf -v code '%d' "'$c"
        [ "$code" -lt 0 ] && code=$(( code + 256 ))
        h=$(( (h ^ code) * 16777619 ))
        h=$(( h & 0xFFFFFFFF ))
    done
    printf '%08x' "$h"
}

# True when the argument is a non-negative integer.
is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Calculates the 0-based index of a menu selection.
#
# The digits may be one or two characters ("7" → 7, "12" → 12).  "10#"
# forces the decimal base — without it a leading zero ("08") is an invalid
# octal number and aborts the arithmetic ("value too great for base").
#
# Result: SELECT_INDEX (empty if the selection is invalid).
selection_index() {
    local _digits="${1:-}" _max="${2:-0}"
    SELECT_INDEX=""
    case "$_digits" in
        ''|*[!0-9]*) return 1 ;;
    esac
    local _idx=$(( 10#$_digits - 1 ))
    if [ "$_idx" -lt 0 ] || [ "$_idx" -ge "$_max" ]; then
        return 1
    fi
    SELECT_INDEX="$_idx"
    return 0
}

# Copies text to the system clipboard (pbcopy/xclip/xsel/wl-copy).
copy_to_clipboard() {
    local text="$1"
    if command -v pbcopy &>/dev/null; then
        echo -n "$text" | pbcopy && success "Copied to clipboard (pbcopy)"
    elif command -v xclip &>/dev/null; then
        echo -n "$text" | xclip -selection clipboard && success "Copied to clipboard (xclip)"
    elif command -v xsel &>/dev/null; then
        echo -n "$text" | xsel --clipboard && success "Copied to clipboard (xsel)"
    elif command -v wl-copy &>/dev/null; then
        echo -n "$text" | wl-copy && success "Copied to clipboard (wl-copy)"
    else
        warn "No clipboard tool available (pbcopy/xclip/xsel)"
    fi
}

validate_filename() {
    local fn="$1"

    # Reject empty names
    [ -z "$fn" ] && return 1

    # Reject dangerous paths
    [[ "$fn" =~ \.\. ]] && return 1      # Parent directory
    [[ "$fn" = *'/'* ]] && return 1      # Absolute/relative paths
    [[ "$fn" = *"\${"* ]] && return 1    # Variable expansion
    [[ "$fn" = *'`'* ]] && return 1      # Command substitution
    [[ "$fn" = *'|'* ]] && return 1      # Pipes
    [[ "$fn" = *';'* ]] && return 1      # Command separators
    [[ "$fn" = *'&'* ]] && return 1      # Background operators
    [[ "$fn" = *'>'* ]] && return 1      # Redirection
    [[ "$fn" = *'<'* ]] && return 1      # Redirection

    # Allow: alphanumeric, dots, dashes, underscores, plus common extensions
    [[ "$fn" =~ ^[a-zA-Z0-9._-]+$ ]] && return 0

    return 1
}
