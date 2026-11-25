#!/bin/bash

# Ensure we are running in Bash, not Zsh (if sourced or run with 'zsh script.sh')
#
# Zsh has no BASH_SOURCE, and $0 cannot distinguish "sourced" from "executed":
# in both cases $0 is the path of the script itself.  $ZSH_EVAL_CONTEXT
# (zsh >= 5.0.3) does distinguish them:
#   toplevel            -> the script was executed  -> re-exec with bash
#   cmdarg:file         -> the script was sourced    -> refuse
#   cmdarg:shfunc:file -> the script was sourced    -> refuse
if [ -n "${ZSH_VERSION:-}" ]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
        toplevel)
            # Re-execute with bash if run as 'zsh script.sh'
            exec bash "$0" "$@"
            ;;
        *)
            echo "Error: This script is not meant to be sourced directly in Zsh." >&2
            return 1
            ;;
    esac
fi

# ==============================================================================
#  SHELL MENU RUNNER v1.7.0 (Task Tags & Shell Completion)
#  GitHub: https://github.com/MarioPeters/shell-menu-runner
#  Lizenz: MIT
# ==============================================================================

readonly VERSION="2.1.3"
# HOME wird für alle Konfigurationspfade gebraucht.  Ohne HOME brach das
# Skript später mit "HOME: unbound variable" ab — die Meldung sagt dem
# Nutzer nicht, was zu tun ist.
if [ -z "${HOME:-}" ]; then
    echo "Error: HOME is not set — cannot locate the configuration files." >&2
    exit 1
fi
readonly LOCAL_CONFIG=".tasks"
readonly GLOBAL_CONFIG="$HOME/.tasks"
readonly LOCAL_SETTINGS=".runrc"
readonly GLOBAL_SETTINGS="$HOME/.runrc"
readonly REPO_RAW_URL="https://raw.githubusercontent.com/MarioPeters/shell-menu-runner/main/run.sh"
readonly RUN_HISTORY_FILE="$HOME/.run_history"
readonly RUN_HISTORY_MAX=100
readonly RUN_TASK_TIMEOUT=300
readonly RUN_RECENT_FILE="$HOME/.run_recent"
readonly RUN_RECENT_MAX=50
readonly RUN_LOG_DIR="$HOME/.run_logs"
readonly RUN_VARS_FILE="$HOME/.run_vars"


# --- PERFORMANCE FLAGS (can be set via environment) ---
RUN_PARALLEL_DEPS="${RUN_PARALLEL_DEPS:-0}"      # Enable parallel dependency execution
# Enables the menu cache (the parsed task list is reused until the config
# files change).  The name is historic — the flag no longer controls a
# profile listing cache.
RUN_CACHE_PROFILES="${RUN_CACHE_PROFILES:-1}"   # Cache the parsed menu/task list
# The minimal build has no advanced features (search, tags, favorites,
# history, logs, file browser, config editor).  Set by the builder.
RUN_MINIMAL="${RUN_MINIMAL:-0}"
# Optimierung für macOS/BSD Grep (Locale-Reset für Geschwindigkeit bei Sortierung/Regex)
# Aber UTF-8 Zeichen müssen erhalten bleiben, daher nur Collate auf C setzen.
export LC_COLLATE=C

set -euo pipefail

# SIGPIPE ignorieren: `run --list | head` soll der Shell nicht mit einem Signal
# abbrechen, sondern sauber beenden (der EXIT-Trap laeuft dann noch).
# Hinweis: die Meldung "write error: Broken pipe" stammt vom Bash-Builtin
# selbst und wird an den Ausgabestellen unterdrueckt (siehe cli_list_tasks
# in 12-execution.sh).  Tasks bekommen die Standardbehandlung zurueck
# (siehe 12-execution.sh).
trap '' PIPE 2>/dev/null || true


# ==============================================================================
#  CONFIGURATION & SETTINGS
# ==============================================================================

# --- THEME CONFIGURATION ---
COLOR_HEAD=$'\e[1;34m'; COLOR_SEL=$'\e[1;32m'; COLOR_ERR=$'\e[1;31m'
COLOR_WARN=$'\e[1;33m'; COLOR_INFO=$'\e[33m';  COLOR_DIM=$'\e[2m'
COLOR_RESET=$'\e[0m';   COLOR_BOLD=$'\e[0;1m'

# --- GLOBAL STATE ---
current_level=0
selected_index=0
history_name_stack=("Main")
config_path=""
active_mode="local"
filter_query=""
tag_filter=""
dry_run_mode=0
declare -a menu_options
declare -a multi_select_map
declare -a task_config_files
readonly ALIAS_FILE="$HOME/.run_aliases"
task_timeout="$RUN_TASK_TIMEOUT"
task_execution_time=0
is_interactive=1
is_ssh_session=0
ssh_hint_shown=0
DEBUG_MODE=1
# Menu cache — the parsed task list of the current config.
#
# The cache key contains everything the result depends on: the config path,
# the change stamp of the file, the current level, the breadcrumb and the
# active filters.  Without the filters in the key every keypress in a
# filtered menu re-read and re-parsed the whole config (~250 ms for 2000
# tasks).
#
# The cached list itself lives in _cached_menu_array (13-ui.sh) — an array
# keeps the entries intact, a single string would have to be split again
# on every use.
_menu_cache_key=""
last_config_stamp=""
# Der Cache-Key enthält den Level, den Breadcrumb und die Filter — der
# Config-Pfad wird getrennt geprüft: zwei Configs mit identischem
# Änderungs-Stempel (mtime:size) sind sonst nicht unterscheidbar, und das
# Menü zeigte nach einem Wechsel ("g" global/lokal, "p" Profil) die Tasks
# der vorherigen Config.
_menu_cache_config_path=""
# shellcheck disable=SC2034
cli_mode=0          # 1 when --run is active; skips interactive prompts in execute_task
# shellcheck disable=SC2034
cli_run_query=""    # query string passed to --run
cli_list_mode=0     # 1 when --list is active

# --- SETTINGS STATE ---
readonly DEFAULT_LANG="DE"
readonly DEFAULT_THEME="CYBER"
readonly DEFAULT_COLS_MIN=1
readonly DEFAULT_COLS_MAX=6
readonly DEFAULT_COLS_MIN_WIDTH=28
readonly DEFAULT_CONTEXT_SHOW="git,hostname,env"
UI_LANG="$DEFAULT_LANG"
UI_THEME="$DEFAULT_THEME"
COLS_MIN="$DEFAULT_COLS_MIN"
COLS_MAX="$DEFAULT_COLS_MAX"
COLS_MIN_WIDTH="$DEFAULT_COLS_MIN_WIDTH"
CONTEXT_SHOW="$DEFAULT_CONTEXT_SHOW"
TASK_THEME=""
SETTINGS_THEME=""
SETTINGS_LANG=""
SETTINGS_COLS_MIN=""
SETTINGS_COLS_MAX=""
SETTINGS_COLS_MIN_WIDTH=""
SETTINGS_CONTEXT_SHOW=""

# ==============================================================================
#  CONFIG FILE PARSING
# ==============================================================================

parse_config_vars() {
    # The errexit/pipefail state is saved and restored: the interactive menu
    # loop runs with "set +e" and a blind "set -e" at the end of this function
    # would end the whole menu on the first failing command (e.g. draw_menu
    # returning 1 because tput is unavailable).
    save_shell_opts
    set +e +o pipefail
    [ ! -f "$config_path" ] && { restore_shell_opts; return; }
    TASK_THEME=$(awk -F':' '/^# THEME:/ {val=$2; gsub(/^[ \t]+|[ \t]+$/, "", val); print val; exit}' "$config_path" 2>/dev/null) || true
    task_timeout=$(extract_field_from_grep "^TIMEOUT=" "=" 2)
    task_timeout="${task_timeout:-$RUN_TASK_TIMEOUT}"
    load_task_vars
    restore_shell_opts
    return 0
}

# ==============================================================================
#  SETTINGS MANAGEMENT
# ==============================================================================

get_local_settings_path() {
    if [ -n "$config_path" ]; then
        local _dir="${config_path%/*}"
        # If no slash, config_path is a bare filename → same dir as PWD
        [ "$_dir" = "$config_path" ] && _dir="."
        echo "$_dir/$LOCAL_SETTINGS"
    else
        echo "$PWD/$LOCAL_SETTINGS"
    fi
}

parse_settings_file() {
    local file="$1"
    [ ! -f "$file" ] && return 0
    while IFS= read -r line || [ -n "$line" ]; do
        # Tolerate CRLF line endings (Windows editors / git core.autocrlf)
        line="${line%$'\r'}"
        case "$line" in
            ""|\#*) continue ;;
        esac
        local key="${line%%=*}"
        local value="${line#*=}"
        # Numeric settings are validated here: an invalid value (e.g.
        # "COLS_MIN_WIDTH=0") would cause a division by zero in the layout
        # calculation and kill the menu.
        # The if/else is important: a failed "&&" chain as the last command
        # of the case branch would return non-zero and abort the script.
        case "$key" in
            THEME)          SETTINGS_THEME="$value" ;;
            LANG)           SETTINGS_LANG="$value" ;;
            COLS_MIN)       if is_uint "$value" && [ "$value" -ge 1 ]; then SETTINGS_COLS_MIN="$value"; fi ;;
            COLS_MAX)       if is_uint "$value"; then SETTINGS_COLS_MAX="$value"; fi ;;
            COLS_MIN_WIDTH) if is_uint "$value" && [ "$value" -ge 1 ]; then SETTINGS_COLS_MIN_WIDTH="$value"; fi ;;
            CONTEXT_SHOW)   SETTINGS_CONTEXT_SHOW="$value" ;;
        esac
    done < "$file"
}

resolve_settings() {
    UI_LANG="$DEFAULT_LANG"
    UI_THEME="$DEFAULT_THEME"
    COLS_MIN="$DEFAULT_COLS_MIN"
    COLS_MAX="$DEFAULT_COLS_MAX"
    COLS_MIN_WIDTH="$DEFAULT_COLS_MIN_WIDTH"
    CONTEXT_SHOW="$DEFAULT_CONTEXT_SHOW"

    [ -n "$SETTINGS_LANG" ]          && UI_LANG="$SETTINGS_LANG"
    if [ -n "$SETTINGS_THEME" ]; then
        UI_THEME="$SETTINGS_THEME"
    elif [ -n "$TASK_THEME" ]; then
        UI_THEME="$TASK_THEME"
    fi
    [ -n "$SETTINGS_COLS_MIN" ]       && COLS_MIN="$SETTINGS_COLS_MIN"
    [ -n "$SETTINGS_COLS_MAX" ]       && COLS_MAX="$SETTINGS_COLS_MAX"
    [ -n "$SETTINGS_COLS_MIN_WIDTH" ] && COLS_MIN_WIDTH="$SETTINGS_COLS_MIN_WIDTH"
    [ -n "$SETTINGS_CONTEXT_SHOW" ]   && CONTEXT_SHOW="$SETTINGS_CONTEXT_SHOW"

    return 0
}

load_settings() {
    SETTINGS_THEME=""; SETTINGS_LANG=""
    SETTINGS_COLS_MIN=""; SETTINGS_COLS_MAX=""
    SETTINGS_COLS_MIN_WIDTH=""; SETTINGS_CONTEXT_SHOW=""
    parse_settings_file "$GLOBAL_SETTINGS"
    parse_settings_file "$(get_local_settings_path)"
    resolve_settings
}

save_settings() {
    local scope="$1"
    local target="$GLOBAL_SETTINGS"
    [ "$scope" = "local" ] && target="$(get_local_settings_path)"
    cat > "$target" <<EOF
# Shell Menu Runner Settings
THEME=$UI_THEME
LANG=$UI_LANG
COLS_MIN=$COLS_MIN
COLS_MAX=$COLS_MAX
COLS_MIN_WIDTH=$COLS_MIN_WIDTH
CONTEXT_SHOW=$CONTEXT_SHOW
EOF
}

# ==============================================================================
#  MULTI-FILE CONFIG SUPPORT
# ==============================================================================

detect_config_files() {
    local config_dir
    # Bash string-ops instead of $(dirname)/$(basename) subshells.
    # The &&...|| idiom was a bug: if the && branch succeeded but the assignment
    # somehow failed, the || branch would also run. Use if/else instead.
    if [ "$active_mode" = "local" ]; then
        config_dir="${config_path%/*}"
        # If no slash found, config_path is a bare filename → use current dir
        [ "$config_dir" = "$config_path" ] && config_dir="."
    else
        config_dir="$HOME"
    fi
    local base_name="${config_path##*/}"

    task_config_files=()
    local -a _candidates=()
    if [ "$base_name" = ".tasks" ]; then
        _candidates+=("$config_dir/.tasks" "$config_dir/.tasks.local" "$config_dir/.tasks.dev")
    else
        _candidates+=("$config_dir/$base_name" "$config_dir/${base_name}.local" "$config_dir/${base_name}.dev")
    fi

    # Ein Symlink auf eine bereits geladene Datei (z.B. ".tasks.local" ->
    # ".tasks") würde jeden Task doppelt in das Menü laden.  Die Dateien
    # werden deshalb über Device/Inode entdoppelt.
    local -a _seen_ids=()
    local _f _id _s _dup=0
    for _f in "${_candidates[@]}"; do
        [ -f "$_f" ] || continue
        _id=$(get_file_id "$_f")
        _dup=0
        if [ -n "$_id" ]; then
            for _s in "${_seen_ids[@]+"${_seen_ids[@]}"}"; do
                if [ "$_s" = "$_id" ]; then
                    _dup=1
                    break
                fi
            done
            [ "$_dup" -eq 0 ] && _seen_ids+=("$_id")
        fi
        [ "$_dup" -eq 1 ] && continue
        task_config_files+=("$_f")
    done

    return 0
}

merge_configs() {
    # Merge all config files into one stream (faster than loop+cat)
    if [ "${#task_config_files[@]}" -gt 0 ]; then
        cat "${task_config_files[@]}" 2>/dev/null || true
    elif [ -f "$config_path" ]; then
        cat "$config_path"
    elif [ -f ".tasks" ]; then
        cat ".tasks"
    fi
}

# Cache for the parsed task list (see get_all_tasks)
_all_tasks_cache=()
_all_tasks_cache_key=""

# Result of the last _build_all_tasks() call.
#
# The list is returned in a global array instead of on stdout: a caller that
# reads the result via a process substitution runs in a subshell, and every
# cache variable set there is lost when it exits — the cache never hit and
# the whole config was re-read and re-parsed for every dependency.
ALL_TASKS_ARRAY=()

_build_all_tasks() {
    # Cache the parsed task list.  find_task_in_menu() requests the list once
    # per dependency — without the cache the whole config was read and parsed
    # again for every single dependency.
    local _sig="${config_path}"
    _sig="${_sig}|$(get_file_stamp "$config_path")"
    local _f
    for _f in "${task_config_files[@]+"${task_config_files[@]}"}"; do
        _sig="${_sig}|$(get_file_stamp "$_f")"
    done
    if [ "$_sig" = "$_all_tasks_cache_key" ] && [ ${#_all_tasks_cache[@]} -gt 0 ]; then
        ALL_TASKS_ARRAY=("${_all_tasks_cache[@]}")
        return 0
    fi

    local -a _all_tasks_result=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        # Tolerate CRLF line endings — a trailing \r would end up in the
        # description and corrupt the menu layout.
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        is_meta_task_line "$line" && continue

        split_task_line "$line"
        level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
        [ -z "$name" ] && continue
        # Das Level muss eine Zahl sein — dieselbe Prüfung wie in
        # _build_menu_options().  Ohne sie-listete "run --list" Tasks mit
        # ungültigem Level auf, die im Menü nie sichtbar waren, und
        # "run --run <name>" konnte sie ausführen.
        case "$level" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
            continue
        fi
        _all_tasks_result+=("${level}|${name}|${cmd}|${desc}")
    done < <(merge_configs)

    # "[@]+" keeps an empty array safe under `set -u` on Bash 3.2
    _all_tasks_cache=("${_all_tasks_result[@]+"${_all_tasks_result[@]}"}")
    _all_tasks_cache_key="$_sig"
    ALL_TASKS_ARRAY=("${_all_tasks_result[@]+"${_all_tasks_result[@]}"}")
    return 0
}

# Prints the parsed task list (one task per line).
# Internal callers use _build_all_tasks() directly so that the cache
# variables survive (see ALL_TASKS_ARRAY).
get_all_tasks() {
    _build_all_tasks
    if [ ${#ALL_TASKS_ARRAY[@]} -gt 0 ]; then
        printf "%s\n" "${ALL_TASKS_ARRAY[@]}"
    fi
    return 0
}

file_sha256() {
    local f="$1"
    if command -v sha256sum &>/dev/null; then sha256sum "$f" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then shasum -a 256 "$f" | awk '{print $1}'
    else return 1; fi
}

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

# ==============================================================================
#  TERMINAL & SSH DETECTION
# ==============================================================================

# Context indicator — built once at init, read by draw_menu()
_CTX_LINE=""
_CTX_LINE_PLAIN=""
_CTX_BRANCH=""
_CTX_HOST=""
_CTX_ENV=""
_LAST_COL_WIDTH=0

# Border string cache — rebuilt when col_width changes (WINCH trap resets _LAST_COL_WIDTH)
# shellcheck disable=SC2034
_BORDER_TOP=""
# shellcheck disable=SC2034
_BORDER_BOT=""

# Terminal capabilities — defaults for the non-interactive path (SSH without
# -t, pipes, cron).  init_terminal_capabilities() overwrites them when a real
# terminal is available; without these defaults the script would abort with
# "unbound variable" as soon as set -u is active.
HAS_TPUT=0
TPUT_CUP=""
TPUT_CIVIS=""
TPUT_CNORM=""
TPUT_ED=""
TPUT_COLS=80
TPUT_LINES=24

# ==============================================================================
#  TERMINAL STATE SNAPSHOT
# ==============================================================================
# The current terminal settings (stty -g) are captured once before the menu
# switches to raw mode and restored after external programs (editors) have run.
# `stty sane` would override the user's own settings and the combination
# `stty sane; stty -echo; drain_stdin` left the shell in `-icanon` mode
# without echo — every following `read` was blind and without line editing.
_SAVED_STTY=""

save_terminal_state() {
    [ -n "$_SAVED_STTY" ] && return 0
    _SAVED_STTY=$(stty -g 2>/dev/null || true)
    return 0
}

restore_terminal_state() {
    if [ -n "$_SAVED_STTY" ]; then
        stty "$_SAVED_STTY" 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi
    return 0
}

# Restores the terminal settings of the menu.
#
# Module level (not inside main_interactive_loop): the INT trap installed by
# execute_task also runs in CLI mode (--run), where the interactive loop was
# never entered — a locally defined function would not exist there and the
# trap would fail with "restore_term: command not found".
restore_term() {
    restore_terminal_state
}

check_interactive() {
    # Check if stdin is a TTY (interactive session)
    if [ -t 0 ]; then
        is_interactive=1
        # Snapshot the user's terminal settings before anything changes them
        save_terminal_state
        init_terminal_capabilities
    else
        is_interactive=0
    fi
}

check_ssh_session() {
    # Check for SSH environment
    if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
        is_ssh_session=1
    else
        is_ssh_session=0
    fi
}

init_context() {
    _CTX_LINE=""; _CTX_LINE_PLAIN=""; _CTX_BRANCH=""; _CTX_HOST=""; _CTX_ENV=""
    local show="${CONTEXT_SHOW:-git,hostname,env}"
    local parts=()
    local plain_parts=()

    # Git branch — subprocess is acceptable at init (not in render loop)
    if [[ "$show" == *"git"* ]]; then
        _CTX_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        [ -n "$_CTX_BRANCH" ] && parts+=("${COLOR_INFO}⎇ ${_CTX_BRANCH}${COLOR_RESET}")
        [ -n "$_CTX_BRANCH" ] && plain_parts+=("⎇ ${_CTX_BRANCH}")
    fi

    # Hostname — only on SSH sessions
    if [[ "$show" == *"hostname"* ]]; then
        if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
            _CTX_HOST="${HOSTNAME:-$(hostname 2>/dev/null || true)}"
            [ -n "$_CTX_HOST" ] && parts+=("${COLOR_ERR}⚡ ${_CTX_HOST}${COLOR_RESET}")
            [ -n "$_CTX_HOST" ] && plain_parts+=("⚡ ${_CTX_HOST}")
        fi
    fi

    # Environment variable
    if [[ "$show" == *"env"* ]]; then
        _CTX_ENV="${APP_ENV:-${ENVIRONMENT:-${DEPLOY_ENV:-}}}"
        if [ -n "$_CTX_ENV" ]; then
            local env_lower env_upper env_color
            env_lower=$(tr '[:upper:]' '[:lower:]' <<< "$_CTX_ENV")
            env_upper=$(tr '[:lower:]' '[:upper:]' <<< "$_CTX_ENV")
            case "$env_lower" in
                production|prod) env_color="$COLOR_ERR"  ;;
                staging|stg)     env_color="$COLOR_WARN" ;;
                development|dev) env_color="$COLOR_INFO" ;;
                *)               env_color="$COLOR_DIM"  ;;
            esac
            parts+=("${env_color}${env_upper}${COLOR_RESET}")
            plain_parts+=("${env_upper}")
        fi
    fi

    # Join parts with " · " separator — pure Bash, no subshell
    if [ "${#parts[@]}" -gt 0 ]; then
        local line="${parts[0]}"
        local plain="${plain_parts[0]}"
        local i
        for (( i=1; i<${#parts[@]}; i++ )); do
            line+="${COLOR_DIM} · ${COLOR_RESET}${parts[$i]}"
            plain+=" · ${plain_parts[$i]}"
        done
        _CTX_LINE="$line"
        _CTX_LINE_PLAIN="$plain"
    fi
}

build_border_strings() {
    local col_width="$1"
    local inner=$(( col_width - 4 ))
    [ "$inner" -lt 1 ] && inner=1

    # Build dash string with pure Bash loop — no subshell, no seq
    local dashes="" i
    for (( i=0; i<inner; i++ )); do dashes+='─'; done

    _BORDER_TOP="┌${dashes}┐"
    _BORDER_BOT="└${dashes}┘"
    _LAST_COL_WIDTH="$col_width"
}

# ==============================================================================
#  UTF-8 DISPLAY WIDTH
# ==============================================================================
# Terminals count columns, not bytes or characters: CJK glyphs and emoji occupy
# two columns, combining marks none.  The helpers below decode UTF-8 byte-wise
# (locale independent, Bash 3.2 compatible) and return the real column count.
# Without this the menu boxes wrap or misalign as soon as a task name contains
# non-ASCII text.

# Decoder state — shared via globals (Bash 3.2 has no namerefs).
_U8_STR=""
_U8_POS=0
_U8_CP=0
_U8_LEN=0
_U8_WIDTH=0

# Result variables of the public helpers
DISPLAY_WIDTH=0
FIT_TEXT=""

# Cached column widths of the constant menu footer hints.
#
# The UTF-8 decoder needs ~4 ms for a non-ASCII string (one printf per
# byte) — measuring the same constant text again and again was the single
# biggest cost of a menu redraw.  Both variants are cached together: a
# cache with only one slot would miss on every call, because the two texts
# are measured alternately.
_HINT_MID_WIDTH=0
_HINT_FULL_WIDTH=0
_HINT_WIDTHS_KEY=""

# Sets _U8_WIDTH to the number of terminal columns used by a code point.
_u8_width() {
    local _cp="$1"
    _U8_WIDTH=1

    # ── Zero width: control characters and combining marks ─────────
    if [ "$_cp" -lt 32 ] \
       || { [ "$_cp" -ge 127 ] && [ "$_cp" -lt 160 ]; } \
       || { [ "$_cp" -ge 768 ] && [ "$_cp" -le 879 ]; } \
       || { [ "$_cp" -ge 1425 ] && [ "$_cp" -le 1479 ]; } \
       || { [ "$_cp" -ge 1536 ] && [ "$_cp" -le 1791 ]; } \
       || { [ "$_cp" -ge 1872 ] && [ "$_cp" -le 1919 ]; } \
       || { [ "$_cp" -ge 8202 ] && [ "$_cp" -le 8207 ]; } \
       || { [ "$_cp" -ge 8208 ] && [ "$_cp" -le 8231 ]; } \
       || { [ "$_cp" -ge 8240 ] && [ "$_cp" -le 8247 ]; } \
       || { [ "$_cp" -ge 8288 ] && [ "$_cp" -le 8299 ]; } \
       || { [ "$_cp" -ge 8400 ] && [ "$_cp" -le 8432 ]; } \
       || { [ "$_cp" -ge 8450 ] && [ "$_cp" -le 8531 ]; } \
       || { [ "$_cp" -ge 65024 ] && [ "$_cp" -le 65039 ]; } \
       || [ "$_cp" -eq 65279 ]; then
        _U8_WIDTH=0
        return 0
    fi

    # ── Wide: CJK, fullwidth forms and emoji ──────────────────────
    if { [ "$_cp" -ge 4352 ] && [ "$_cp" -le 4447 ]; } \
       || { [ "$_cp" -ge 11904 ] && [ "$_cp" -le 12350 ]; } \
       || { [ "$_cp" -ge 12352 ] && [ "$_cp" -le 13311 ]; } \
       || { [ "$_cp" -ge 13312 ] && [ "$_cp" -le 19903 ]; } \
       || { [ "$_cp" -ge 19968 ] && [ "$_cp" -le 40959 ]; } \
       || { [ "$_cp" -ge 40960 ] && [ "$_cp" -le 42191 ]; } \
       || { [ "$_cp" -ge 43360 ] && [ "$_cp" -le 43455 ]; } \
       || { [ "$_cp" -ge 44032 ] && [ "$_cp" -le 55203 ]; } \
       || { [ "$_cp" -ge 63744 ] && [ "$_cp" -le 64255 ]; } \
       || { [ "$_cp" -ge 65008 ] && [ "$_cp" -le 65023 ]; } \
       || { [ "$_cp" -ge 65040 ] && [ "$_cp" -le 65135 ]; } \
       || { [ "$_cp" -ge 65280 ] && [ "$_cp" -le 65376 ]; } \
       || { [ "$_cp" -ge 65504 ] && [ "$_cp" -le 65510 ]; } \
       || { [ "$_cp" -ge 127744 ] && [ "$_cp" -le 128591 ]; } \
       || { [ "$_cp" -ge 128640 ] && [ "$_cp" -le 128711 ]; } \
       || { [ "$_cp" -ge 128768 ] && [ "$_cp" -le 130303 ]; } \
       || { [ "$_cp" -ge 128992 ] && [ "$_cp" -le 129003 ]; } \
       || { [ "$_cp" -ge 131072 ] && [ "$_cp" -le 262143 ]; }; then
        _U8_WIDTH=2
        return 0
    fi

    return 0
}

# Decodes the UTF-8 sequence at byte position _U8_POS of _U8_STR.
# Result: _U8_CP (code point), _U8_LEN (bytes), _U8_WIDTH (columns).
_u8_decode() {
    local _b1 _b2 _b3 _b4 _v _rest

    printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
    _b1=$_v
    [ "$_b1" -lt 0 ] && _b1=$(( _b1 + 256 ))

    if [ "$_b1" -lt 128 ]; then
        _U8_CP=$_b1
        _U8_LEN=1
    elif [ "$_b1" -lt 224 ]; then
        _rest=$(( ${#_U8_STR} - _U8_POS ))
        if [ "$_rest" -lt 2 ]; then _U8_CP=$_b1; _U8_LEN=1; _u8_width "$_U8_CP"; return 0; fi
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b2=$_v; [ "$_b2" -lt 0 ] && _b2=$(( _b2 + 256 ))
        _U8_CP=$(( ((_b1 & 31) << 6) | (_b2 & 63) ))
        _U8_LEN=2
    elif [ "$_b1" -lt 240 ]; then
        _rest=$(( ${#_U8_STR} - _U8_POS ))
        if [ "$_rest" -lt 3 ]; then _U8_CP=$_b1; _U8_LEN=1; _u8_width "$_U8_CP"; return 0; fi
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b2=$_v; [ "$_b2" -lt 0 ] && _b2=$(( _b2 + 256 ))
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b3=$_v; [ "$_b3" -lt 0 ] && _b3=$(( _b3 + 256 ))
        _U8_CP=$(( ((_b1 & 15) << 12) | ((_b2 & 63) << 6) | (_b3 & 63) ))
        _U8_LEN=3
    else
        _rest=$(( ${#_U8_STR} - _U8_POS ))
        if [ "$_rest" -lt 4 ]; then _U8_CP=$_b1; _U8_LEN=1; _u8_width "$_U8_CP"; return 0; fi
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b2=$_v; [ "$_b2" -lt 0 ] && _b2=$(( _b2 + 256 ))
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b3=$_v; [ "$_b3" -lt 0 ] && _b3=$(( _b3 + 256 ))
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b4=$_v; [ "$_b4" -lt 0 ] && _b4=$(( _b4 + 256 ))
        _U8_CP=$(( ((_b1 & 7) << 18) | ((_b2 & 63) << 12) | ((_b3 & 63) << 6) | (_b4 & 63) ))
        _U8_LEN=4
    fi

    _u8_width "$_U8_CP"
    return 0
}

# Sets DISPLAY_WIDTH to the number of terminal columns of the given string.
display_width() {
    local _s="$1"
    local _w=0 _i=0 _len _lc_saved="" _lc_was_set=0

    # Fast path: pure ASCII → one column per character
    case "$_s" in
        *[![:ascii:]]*) ;;
        *) DISPLAY_WIDTH=${#_s}; return 0 ;;
    esac

    # Byte-wise decoding: LC_ALL=C makes ${#str} and ${str:i:n} byte based
    [ -n "${LC_ALL+x}" ] && { _lc_was_set=1; _lc_saved="$LC_ALL"; }
    LC_ALL=C

    _U8_STR="$_s"
    _len=${#_U8_STR}
    while [ "$_i" -lt "$_len" ]; do
        _U8_POS=$_i
        _u8_decode
        _w=$(( _w + _U8_WIDTH ))
        _i=$(( _i + _U8_LEN ))
    done

    if [ "$_lc_was_set" -eq 1 ]; then LC_ALL="$_lc_saved"; else unset LC_ALL; fi

    DISPLAY_WIDTH=$_w
    return 0
}

# Pads or truncates a string to exactly the given number of terminal columns.
# Result: FIT_TEXT.  Truncation never splits a UTF-8 character and appends
# an ellipsis so the column width stays stable.
fit_to_width() {
    local _s="$1" _max="$2"
    local _w=0 _i=0 _len _out="" _truncated=0 _limit _pad _spaces="" _lc_saved="" _lc_was_set=0

    FIT_TEXT=""
    [ "$_max" -lt 1 ] && return 0

    # Fast path: pure ASCII
    case "$_s" in
        *[![:ascii:]]*) ;;
        *)
            if [ "${#_s}" -le "$_max" ]; then
                printf -v _spaces '%*s' "$(( _max - ${#_s} ))" ''
                FIT_TEXT="${_s}${_spaces}"
            else
                printf -v FIT_TEXT '%s...' "${_s:0:$(( _max > 3 ? _max - 3 : 1 ))}"
            fi
            return 0
            ;;
    esac

    # Byte-wise decoding: LC_ALL=C makes ${#str} and ${str:i:n} byte based
    [ -n "${LC_ALL+x}" ] && { _lc_was_set=1; _lc_saved="$LC_ALL"; }
    LC_ALL=C

    _U8_STR="$_s"
    _len=${#_U8_STR}

    # First pass: does the text fit?
    while [ "$_i" -lt "$_len" ]; do
        _U8_POS=$_i
        _u8_decode
        if [ $(( _w + _U8_WIDTH )) -gt "$_max" ]; then
            _truncated=1
            break
        fi
        _w=$(( _w + _U8_WIDTH ))
        _i=$(( _i + _U8_LEN ))
    done

    if [ "$_truncated" -eq 0 ]; then
        _pad=$(( _max - _w ))
        [ "$_pad" -gt 0 ] && printf -v _spaces '%*s' "$_pad" ''
        if [ "$_lc_was_set" -eq 1 ]; then LC_ALL="$_lc_saved"; else unset LC_ALL; fi
        FIT_TEXT="${_s}${_spaces}"
        return 0
    fi

    # Second pass: cut at the column limit, reserve 3 columns for the ellipsis
    _limit=$(( _max - 3 ))
    [ "$_limit" -lt 1 ] && _limit=1
    _w=0
    _i=0
    _out=""
    while [ "$_i" -lt "$_len" ]; do
        local _start=$_i
        _U8_POS=$_i
        _u8_decode
        if [ $(( _w + _U8_WIDTH )) -gt "$_limit" ]; then
            break
        fi
        # _U8_POS was advanced by the decoder — cut at the original offset
        _out="${_out}${_U8_STR:_start:_U8_LEN}"
        _w=$(( _w + _U8_WIDTH ))
        _i=$(( _i + _U8_LEN ))
    done

    _out="${_out}..."
    _w=$(( _w + 3 ))
    _pad=$(( _max - _w ))
    [ "$_pad" -gt 0 ] && printf -v _spaces '%*s' "$_pad" ''
    if [ "$_lc_was_set" -eq 1 ]; then LC_ALL="$_lc_saved"; else unset LC_ALL; fi
    FIT_TEXT="${_out}${_spaces}"
    return 0
}

# Horizontal rule that always fits into the current terminal width.
# Usage: separator_line [max_width]
separator_line() {
    local _max="${1:-63}"
    local _width="${TPUT_COLS:-80}"
    local _len _i _out=""

    [ "$_width" -gt "$_max" ] && _width=$_max
    [ "$_width" -lt 10 ] && _width=10

    # ── characters ────────────────────────────────────────────────
    for (( _i=0; _i<_width; _i++ )); do _out+='─'; done
    printf "%s" "$_out"
}

# Optimized terminal capability caching
_TPUT_INITIALIZED=0
init_terminal_capabilities() {
    # Only run once — guard auf dediziertes Flag statt TPUT_COLS (könnte leer sein wenn tput cols versagt)
    [ "${_TPUT_INITIALIZED:-0}" -eq 1 ] && return
    _TPUT_INITIALIZED=1

    if command -v tput >/dev/null 2>&1; then
        # Every tput call must tolerate a failure: with "set -e" an assignment
        # whose command substitution fails aborts the whole script.  This
        # happens with TERM=dumb, an unknown TERM or a broken terminfo
        # database — the tool was completely unusable in those cases.
        TPUT_CUP="$(tput cup 0 0 2>/dev/null || true)"
        TPUT_CIVIS="$(tput civis 2>/dev/null || true)"
        TPUT_CNORM="$(tput cnorm 2>/dev/null || true)"
        TPUT_ED="$(tput ed 2>/dev/null || true)"
        TPUT_COLS="$(tput cols 2>/dev/null || true)"
        TPUT_LINES="$(tput lines 2>/dev/null || true)"
        HAS_TPUT=1
    else
        HAS_TPUT=0
        TPUT_COLS=80
        TPUT_LINES=24
    fi
    # Fallbacks for terminfo entries that do not exist (dumb terminals)
    is_uint "${TPUT_COLS:-}" && [ "${TPUT_COLS:-0}" -ge 1 ] || TPUT_COLS=80
    is_uint "${TPUT_LINES:-}" && [ "${TPUT_LINES:-0}" -ge 1 ] || TPUT_LINES=24

    # Update cols/lines on resize, reset border cache
    trap 'TPUT_COLS=$(tput cols 2>/dev/null || echo 80); TPUT_LINES=$(tput lines 2>/dev/null || echo 24); _LAST_COL_WIDTH=0' WINCH

    # Context indicator (git branch, hostname, env)
    init_context
}

consume_keypress() {
    # Suppress echo so arrow keys / escape sequences are not printed to the
    # terminal while waiting for the keypress (e.g. after stty sane in execute_task).
    # Every stty call tolerates a missing TTY — otherwise `set -e` would abort
    # the script in a pipe/SSH-without-TTY session.
    stty -echo 2>/dev/null || true
    read_key >/dev/null || true
    # Drain any remaining bytes from multi-byte escape sequences (e.g. arrow keys
    # send \x1b[A; read_key already consumed the full sequence, but defensive
    # drain prevents leftover bytes leaking into the main loop's key handler).
    drain_stdin
    stty echo 2>/dev/null || true
}

# Enable raw interactive input mode for the main loop.
# Flags: no echo, no canonical buffering, pass signals, block until 1 char min.
# NOTE: icrnl is intentionally left ON so Enter (\r→\n) is stripped by $()
# to "". Spurious "" from a failed read_key_raw is blocked by the _rk_status
# guard in the main loop (13-ui.sh), not by changing icrnl.
set_raw_mode() {
    stty -echo -icanon time 0 min 1 isig 2>/dev/null || true
}

drain_stdin() {
    # Only a terminal can have buffered bytes — on a pipe head would block
    # until the writer closes the pipe (hang).
    [ -t 0 ] || return 0
    # Non-blocking drain of any pending stdin bytes (e.g. escape sequence tails
    # or task output left in the buffer). Explicitly disables icanon so this
    # works regardless of the current terminal mode (e.g. after stty sane).
    # head -c reads everything that is available with a single fork instead of
    # one dd fork per 128 byte block.
    stty -icanon min 0 time 0 2>/dev/null || true
    head -c 4096 >/dev/null 2>&1 || true
    stty min 1 time 0 2>/dev/null || true
    return 0
}

# Re-installs the Ctrl+C handler that fits the current context: the menu loop
# needs the terminal restore, every other code path does not.
restore_int_trap() {
    if [ "${_MENU_LOOP_ACTIVE:-0}" -eq 1 ]; then
        trap 'restore_term; cleanup_wrapper; exit 130' INT TERM
    else
        trap 'cleanup_wrapper; exit 130' INT TERM
    fi
    return 0
}

# Runs an external editor on the given file and restores the terminal state.
#
# * `trap ':' INT` (handler, not ignore): bash resets a *trapped* signal to its
#   default disposition in the child process, so Ctrl+C terminates the editor
#   while the menu survives.  `trap '' INT` would be inherited by the child and
#   the editor could never be stopped.
# * The terminal settings are restored from the snapshot instead of
#   `stty sane; stty -echo` — that left the shell in `-icanon` mode without
#   echo, so the following `read` calls were blind.
run_external_editor() {
    local file="${1:-}"
    if [ -z "$file" ]; then
        error "No file to edit"
        return 0
    fi

    trap ':' INT
    ${EDITOR:-nano} "$file" || true
    restore_int_trap
    drain_stdin
    restore_terminal_state
    return 0
}

read_key() {
    local key=""
    # 1. Read first char (blocking)
    # This relies on the outer loop setting stty to blocking (min 1)
    # "IFS=" is mandatory: bash's `read` strips leading/trailing IFS
    # whitespace, so a space would arrive as an empty string and be
    # mistaken for Enter (the multi-select toggle was unreachable).
    if ! IFS= read -rsn1 key; then return 1; fi

    # 2. Check for ESC sequence
    if [ "$key" = $'\x1b' ]; then
        # Save current stty state and switch to non-blocking with 100ms window.
        # Use ONE dd call (bs=10) instead of a loop of bs=1 forks: fewer subshells,
        # no race between fork overhead and byte delivery.
        local previous_stty
        previous_stty=$(stty -g 2>/dev/null || true)
        stty -icanon min 0 time 1 2>/dev/null || true
        local seq
        seq=$(dd bs=10 count=1 2>/dev/null)
        if [ -n "$previous_stty" ]; then
            stty "$previous_stty" 2>/dev/null || true
        fi
        key="${key}${seq}"
    fi
    printf "%s" "$key"
}

# Optimized version of read_key that assumes stty is already set to raw mode.
# This avoids the overhead of calling stty twice per keypress.
read_key_raw() {
    local key=""
    # 1. Read first char (blocking 1 char, min 1 time 0)
    # "IFS=" keeps a space intact — see read_key().
    if ! IFS= read -rsn1 key; then return 1; fi

    # 2. Check for ESC sequence
    if [ "$key" = $'\x1b' ]; then
        # Read the remainder of the escape sequence with ONE dd call (up to 10 bytes).
        # Using time 1 (100ms window) with min 0: dd returns immediately once bytes
        # are available (arrow keys deliver [A within ~1ms on local terminals), and
        # waits at most 100ms if nothing arrives (pure ESC press).
        # One fork instead of 5 serial forks avoids the race condition where
        # fork overhead (~5-20ms) caused [A to be missed at time 0.
        stty min 0 time 1 2>/dev/null || true
        local seq
        seq=$(dd bs=10 count=1 2>/dev/null)
        stty min 1 time 0 2>/dev/null || true
        key="${key}${seq}"
    fi
    printf "%s" "$key"
}

# Reads a single key with a short timeout.
#
# Returns an empty string when no key arrives within the timeout.  Used by the
# tag and favorites menus for the two digit selection: a single digit selects
# immediately, a second digit (typed quickly) extends the number to 10+.
#
# Usage: read_key_optional [timeout-in-tenths-of-a-second]
read_key_optional() {
    local _key=""
    local _prev_stty
    local _timeout="${1:-2}"
    _prev_stty=$(stty -g 2>/dev/null || true)
    # -icanon is required: in canonical mode the read would block until a
    # whole line is available and the timeout would never trigger.
    stty -icanon min 0 time "$_timeout" 2>/dev/null || true
    _key=$(dd bs=1 count=1 2>/dev/null)
    if [ -n "$_prev_stty" ]; then
        stty "$_prev_stty" 2>/dev/null || true
    fi
    printf "%s" "$_key"
    return 0
}

print_ssh_hint() {
    cat << 'EOF'
════════════════════════════════════════════════════════════════
  ⚠️  SSH Session Detected (No TTY)
════════════════════════════════════════════════════════════════
  For interactive mode, reconnect with: ssh -t user@host

  Example:
    ssh -t user@server.com "cd myproject && run"

  Or using an alias:
    alias ssh-run="ssh -t"
    ssh-run user@server "cd myproject && run"
════════════════════════════════════════════════════════════════
EOF
}

# ==============================================================================
#  I18N / MESSAGES
# ==============================================================================

msg() {
    local key="$1"
    case "$UI_LANG" in
        EN)
            case "$key" in
                update_check) echo "Checking for updates..." ;;
                curl_missing) echo "curl not found. Please install and retry." ;;
                temp_file_fail) echo "Could not create temporary file." ;;
                no_hash) echo "No RUN_EXPECTED_SHA256 set. Update without hash check." ;;
                continue_prompt) echo "Continue? [y/N]" ;;
                hash_mismatch) echo "Integrity check mismatch:" ;;
                hash_skipped) echo "Warning: sha256sum/shasum not found. Skipping check." ;;
                update_same) echo "You already have the latest version" ;;
                update_found) echo "Update found:" ;;
                install_path_missing) echo "Could not determine install path (run not in PATH)." ;;
                update_success) echo "Update successful!" ;;
                update_failed) echo "The update could not be installed." ;;
                download_error) echo "Failed to download update." ;;
                config_exists) echo "File already exists." ;;
                init_header) echo "Initializing Shell Menu Runner..." ;;
                node_detected) echo "package.json detected. Importing scripts..." ;;
                docker_detected) echo "Docker Compose detected." ;;
                python_detected) echo "Python project detected." ;;
                init_done) echo "Configuration created with auto-detection." ;;
                select_option) echo "Select option:" ;;
                warning_label) echo "WARNING" ;;
                dropdown_hint) echo "[up/down] Navigate | [Enter] Select" ;;
                executing) echo "Executing:" ;;
                confirm_prompt) echo "Sure? [y/N]" ;;
                choose_for) echo "Choose for:" ;;
                input_for) echo "Input for:" ;;
                task_failed) echo "Task failed" ;;
                task_success) echo "Task successful." ;;
                task_cancelled) echo "Cancelled — the task was not executed." ;;
                task_depends) echo "Running dependencies" ;;
                press_key) echo "Press any key..." ;;
                executed_marked) echo "Executed" ;;
                marked_label) echo "marked" ;;
                recent_tasks) echo "Recent Tasks" ;;
                logs_title) echo "Recent Logs" ;;
                no_logs) echo "No log files found." ;;
                history_label) echo "History" ;;
                history_empty) echo "No history entries" ;;
                *) echo "$key" ;;
            esac
            ;;
        *)
            case "$key" in
                update_check) echo "Suche nach Updates..." ;;
                curl_missing) echo "curl nicht gefunden. Bitte installieren und erneut versuchen." ;;
                temp_file_fail) echo "Konnte temporäre Datei nicht anlegen." ;;
                no_hash) echo "Kein RUN_EXPECTED_SHA256 gesetzt. Update ohne Hash-Pruefung." ;;
                continue_prompt) echo "Fortfahren? [y/N]" ;;
                hash_mismatch) echo "Integritaetscheck ungueltig:" ;;
                hash_skipped) echo "Warnung: sha256sum/shasum nicht gefunden. Pruefung uebersprungen." ;;
                update_same) echo "Du nutzt bereits die neueste Version" ;;
                update_found) echo "Update gefunden:" ;;
                install_path_missing) echo "Konnte Installationspfad nicht bestimmen (run nicht im PATH)." ;;
                update_success) echo "Update erfolgreich!" ;;
                update_failed) echo "Das Update konnte nicht installiert werden." ;;
                download_error) echo "Fehler beim Herunterladen des Updates." ;;
                config_exists) echo "Datei existiert bereits." ;;
                init_header) echo "Initialisiere Shell Menu Runner..." ;;
                node_detected) echo "package.json erkannt. Importiere Scripts..." ;;
                docker_detected) echo "Docker Compose erkannt." ;;
                python_detected) echo "Python Projekt erkannt." ;;
                init_done) echo "Konfiguration wurde mit Auto-Detection erstellt." ;;
                select_option) echo "Option waehlen:" ;;
                warning_label) echo "ACHTUNG" ;;
                dropdown_hint) echo "[up/down] Navigation | [Enter] Auswahl" ;;
                executing) echo "Ausfuehren:" ;;
                confirm_prompt) echo "Sicher? [y/N]" ;;
                choose_for) echo "Waehle fuer:" ;;
                input_for) echo "Eingabe fuer:" ;;
                task_failed) echo "Task fehlgeschlagen" ;;
                task_success) echo "Task erfolgreich." ;;
                task_cancelled) echo "Abgebrochen — der Task wurde nicht ausgeführt." ;;
                task_depends) echo "Führe Abhängigkeiten aus" ;;
                press_key) echo "Taste druecken..." ;;
                executed_marked) echo "Ausgefuehrt" ;;
                marked_label) echo "markiert" ;;
                recent_tasks) echo "Zuletzt ausgeführt" ;;
                logs_title) echo "Letzte Logs" ;;
                no_logs) echo "Keine Log-Dateien gefunden." ;;
                history_label) echo "Verlauf" ;;
                history_empty) echo "Kein Verlaufseintrag vorhanden" ;;
                *) echo "$key" ;;
            esac
            ;;
    esac
}

# ==============================================================================
#  THEME SYSTEM & VISUAL EFFECTS
# ==============================================================================

apply_theme() {
    case "$UI_THEME" in
        "CYBER") 
            COLOR_HEAD=$'\e[1;36m'   # Cyan
            COLOR_SEL=$'\e[1;35m'    # Magenta
            COLOR_INFO=$'\e[1;32m'   # Bright Green
            COLOR_WARN=$'\e[1;33m'   # Bright Yellow
            COLOR_ERR=$'\e[1;31m'    # Bright Red
            COLOR_DIM=$'\e[2m'       # Dim
            ;;
        "MONO")
            COLOR_HEAD=$'\e[1;37m'   # Bright White
            COLOR_SEL=$'\e[4;37m'    # Underline White
            COLOR_INFO=$'\e[2m'      # Dim
            COLOR_WARN=$'\e[1;37m'   # Bright White
            COLOR_ERR=$'\e[1;37m'    # Bright White
            COLOR_DIM=$'\e[2m'       # Dim
            ;;
        "DARK")
            COLOR_HEAD=$'\e[1;94m'   # Bright Blue
            COLOR_SEL=$'\e[1;92m'    # Bright Green
            COLOR_INFO=$'\e[96m'     # Bright Cyan
            COLOR_WARN=$'\e[93m'     # Bright Yellow
            COLOR_ERR=$'\e[91m'      # Bright Red
            COLOR_DIM=$'\e[38;5;240m' # Gray
            ;;
        "LIGHT")
            COLOR_HEAD=$'\e[34m'     # Blue
            COLOR_SEL=$'\e[32m'      # Green
            COLOR_INFO=$'\e[36m'     # Cyan
            COLOR_WARN=$'\e[33m'     # Yellow
            COLOR_ERR=$'\e[31m'      # Red
            COLOR_DIM=$'\e[90m'      # Dark Gray
            ;;
    esac
}

# Spinner for long-running tasks
SPINNER_PID=""
SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

show_spinner() {
    local message="$1"
    local delay=0.1
    # Gecachte tput-Variable nutzen statt direktem tput-Aufruf zur Laufzeit.
    # "|| true": ein fehlgeschlagener tput darf das Skript nicht beenden.
    if [ -n "${TPUT_CIVIS:-}" ]; then echo -ne "$TPUT_CIVIS"; else tput civis 2>/dev/null || true; fi
    (
        local i=0
        while true; do
            local char="${SPINNER_CHARS:$i:1}"
            printf "\r${COLOR_INFO}%s${COLOR_RESET} %s" "$char" "$message"
            i=$(( (i + 1) % ${#SPINNER_CHARS} ))
            sleep "$delay"
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        # wait returns the killed process's exit code (128+signal) which is non-zero.
        # || true prevents set -e from aborting when stop_spinner is called at the
        # top level (e.g. --across mode) where set -e is still active.
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r%80s\r" " "  # Clear spinner line
        # Gecachte tput-Variable nutzen
        if [ -n "${TPUT_CNORM:-}" ]; then echo -ne "$TPUT_CNORM"; else tput cnorm 2>/dev/null || true; fi
    fi
}

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

# ==============================================================================
#  PROFILE MANAGEMENT
# ==============================================================================

find_local_config() {
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/$LOCAL_CONFIG" ]; then
            echo "$d/$LOCAL_CONFIG"
            return 0
        fi
        # Bash-String-Op statt dirname-Subshell
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    return 1
}

find_named_config() {
    local name="$1"
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/.tasks.$name" ]; then
            echo "$d/.tasks.$name"
            return 0
        fi
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    return 1
}

list_available_profiles() {
    local -a names=()
    local d="$PWD"
    while [ "$d" != "/" ]; do
        for f in "$d"/.tasks.*; do
            [ -f "$f" ] || continue
            local base
            base="${f##*/}"
            base="${base#.tasks.}"
            # "local" and "dev" are reserved overlay suffixes: they are merged
            # into the default config automatically (see detect_config_files)
            # and are therefore not separate profiles.
            [ "$base" = "local" ] && continue
            [ "$base" = "dev" ] && continue
            names+=("$base")
        done
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    local f
    for f in "$HOME"/.tasks.*; do
        [ -f "$f" ] || continue
        local base
        base="${f##*/}"
        base="${base#.tasks.}"
        [ "$base" = "local" ] && continue
        [ "$base" = "dev" ] && continue
        names+=("$base")
    done
    if [ ${#names[@]} -gt 0 ]; then
        printf "%s\n" "${names[@]}" | sort -u
    fi
}

init_profile() {
    local name="$1"
    [ -z "$name" ] && { echo "Error: profile name required"; return 1; }
    # Der Name landet im Dateinamen — Pfad-Traversal und Leerzeichen sind nicht
    # erlaubt (Format des Alias-Dateiformats "name=value" bzw. ".tasks.<name>").
    case "$name" in
        */*|*" "*) echo "Error: invalid profile name (no '/' or spaces)"; return 1 ;;
    esac

    local profile_file="$PWD/.tasks.$name"
    [ -f "$profile_file" ] && { echo "Profile $name already exists at $profile_file"; return 1; }

    echo "Creating profile: $name"
    local template
    template="$(cat << 'EOF'
# Profile: {NAME}
# Auto-generated task list for {NAME}

0|Task Name|command|Description here
0|Another Task|echo "Hello"|Runs a simple command
EOF
)"
    # Bash-String-Op statt sed -i (kein Fork, kein Escaping-Problem)
    template=${template//\{NAME\}/$name}
    printf '%s\n' "$template" > "$profile_file"

    echo "Profile created: $profile_file"
    echo "Edit with: ${EDITOR:-nano} $profile_file"
}

validate_config_file() {
    local profile_file="$1"
    local display_name="$2"

    if [ ! -f "$profile_file" ]; then
        error "Profile file not found: $profile_file"
        return 1
    fi

    echo "Validating profile: $display_name ($profile_file)"
    local errors=0
    local line_no=0
    local syntax_ok=true

    while IFS='|' read -r level name cmd desc extra || [ -n "$level" ]; do
        line_no=$((line_no + 1))
        # Tolerate CRLF line endings
        level="${level%$'\r'}"
        name="${name%$'\r'}"
        cmd="${cmd%$'\r'}"
        desc="${desc%$'\r'}"
        extra="${extra%$'\r'}"

        # Skip comments and empty lines
        [[ "$level" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$level" ]] && continue

        # Validate format
        if [ -z "$name" ] || [ -z "$cmd" ]; then
            echo "  Line $line_no: Invalid format (missing fields)"
            errors=$((errors + 1))
            syntax_ok=false
        fi

        # Das Level muss eine nicht-negative Zahl sein: das Menü überspringt
        # jede Zeile mit einem nicht-numerischen Level — der Task wäre
        # unsichtbar, die Validierung meldete aber "passed".
        if ! is_uint "$level"; then
            echo "  Line $line_no: Invalid level '$level' (must be a number)"
            errors=$((errors + 1))
            syntax_ok=false
        fi

        # The format uses "|" as the field separator — a command with a pipe
        # is cut off at the first separator.  Warning, because the
        # description may legitimately contain a pipe.
        if [ -n "$extra" ]; then
            echo "  Line $line_no: Warning - more than 4 fields"
            echo "            (a '|' in the command is not supported by the format)"
        fi
    done < "$profile_file"

    if [ "$syntax_ok" = true ]; then
        success "Profile validation passed: $display_name"
        return 0
    else
        error "Profile validation failed: $display_name ($errors errors)"
        return 1
    fi
}

# Escapes a string for a JSON string literal (backslash, quote, control chars).
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

list_profiles_all() {
    local mode="${1:-text}"
    local profiles_str
    profiles_str=$(list_available_profiles)

    if [ "$mode" = "json" ]; then
        # Auch ohne Profile wird gültiges JSON geliefert — "No profiles
        # found" konnte von einem JSON-Parser nicht gelesen werden.
        echo "{"
        echo "  \"profiles\": ["
        local first=1
        # Process-Substitution statt Here-String (kein temporäres File)
        if [ -n "$profiles_str" ]; then
            while IFS= read -r prof; do
                [ "$first" -eq 0 ] && echo ","
                first=0
                echo "    { \"name\": \"$(_json_escape "$prof")\" }"
            done < <(printf '%s\n' "$profiles_str")
        fi
        echo ""
        echo "  ]"
        echo "}"
    elif [ -z "$profiles_str" ]; then
        echo "No profiles found"
        return 0
    else
        echo "Available profiles:"
        echo ""
        while IFS= read -r prof; do
            echo "  • $prof"
        done < <(printf '%s\n' "$profiles_str")
    fi
    return 0
}

# ==============================================================================
#  PROFILE LOADING & VALIDATION
# ==============================================================================

load_profile_config() {
    local profile_name="$1"

    # Temporarily change active_mode and config_path
    local saved_mode="$active_mode"
    local saved_config_path="$config_path"

    # Lokale Profile zuerst (wie beim CLI-Aufruf "run <profil>"): das Profil
    # wird im aktuellen Verzeichnis und in allen übergeordneten Verzeichnissen
    # gesucht.  Vorher wurde ausschließlich $HOME/.tasks.<name> geprüft —
    # "run --across p1,p2 task" scheiterte dadurch für lokale Profile.
    local _found=""
    _found=$(find_named_config "$profile_name") || _found=""
    if [ -n "$_found" ]; then
        active_mode="local"
        config_path="$_found"
    elif [ -f "$HOME/.tasks.$profile_name" ]; then
        active_mode="global"
        config_path="$HOME/.tasks.$profile_name"
    else
        active_mode="$saved_mode"
        config_path="$saved_config_path"
        return 1
    fi

    # The task list comes from task_config_files — it has to be rebuilt for
    # the new profile, otherwise the task would be searched in the config of
    # the previous one.
    detect_config_files

    return 0
}

validate_profile() {
    local name="$1"
    [ -z "$name" ] && { echo "Error: profile name required"; return 1; }

    local profile_file
    profile_file=$(find_named_config "$name") || profile_file="$HOME/.tasks.$name"

    validate_config_file "$profile_file" "$name"
}

select_profile_menu() {
    local -a profiles=()
    local -a filtered_profiles=()
    local -a display_profiles=()
    IFS=$'\n' read -r -d '' -a profiles < <(list_available_profiles && printf '\0') || true
    local num=${#profiles[@]}
    [ "$num" -eq 0 ] && return 1
    [ ! -t 0 ] && return 1

    local page=0
    local per_page=9
    local filter_pattern=""
    local filter_active=0
    
    while true; do
        # Apply filter if active
        if [ "$filter_active" -eq 1 ] && [ -n "$filter_pattern" ]; then
            filtered_profiles=()
            for prof in "${profiles[@]}"; do
                if [[ "$prof" == *"$filter_pattern"* ]]; then
                    filtered_profiles+=("$prof")
                fi
            done
            # "[@]+" keeps an empty array safe under `set -u` on Bash 3.2 —
            # without it a filter without a match aborted the whole runner.
            display_profiles=("${filtered_profiles[@]+"${filtered_profiles[@]}"}")
            display_num=${#display_profiles[@]}
        else
            display_profiles=("${profiles[@]}")
            display_num=${#display_profiles[@]}
        fi
        
        # Reset page if out of bounds
        local max_pages=$(( (display_num + per_page - 1) / per_page ))
        [ "$page" -ge "$max_pages" ] && page=$((max_pages - 1))
        [ "$page" -lt 0 ] && page=0
        
        clear
        echo -e "${COLOR_HEAD}Profiles${COLOR_RESET}"
        if [ "$filter_active" -eq 1 ]; then
            echo -e "${COLOR_INFO}Filter: ${filter_pattern}_${COLOR_RESET} (ESC to clear)"
        fi
        echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
        
        local start=$((page * per_page))
        local end=$((start + per_page))
        [ "$end" -gt "$display_num" ] && end="$display_num"
        
        if [ "$display_num" -eq 0 ]; then
            echo -e "${COLOR_DIM}No profiles match filter${COLOR_RESET}"
        else
            local i
            for (( i=start; i<end; i++ )); do
                local idx=$((i - start + 1))
                echo "${idx}) ${display_profiles[$i]}"
            done
        fi
        
        echo ""
        if [ "$display_num" -gt "$per_page" ]; then
            echo -e "${COLOR_DIM}Page $((page + 1))/$max_pages  "
            [ "$page" -gt 0 ] && echo -n "[p]revious " || echo -n "           "
            [ "$end" -lt "$display_num" ] && echo "[n]ext"
        fi
        echo "[/] filter  0) Cancel"
        echo ""
        choice=$(read_key) || return 1
        
        case "$choice" in
            [1-9])
                local pick=$((start + choice - 1))
                [ "$pick" -ge "$end" ] && continue
                [ "$display_num" -eq 0 ] && continue
                local profile="${display_profiles[$pick]}"
                if found=$(find_named_config "$profile"); then
                    active_mode="local"
                    config_path="$found"
                    return 0
                fi
                if [ -f "$HOME/.tasks.$profile" ]; then
                    active_mode="global"
                    config_path="$HOME/.tasks.$profile"
                    return 0
                fi
                ;;
            0) return 1 ;;
            q|Q) return 1 ;;
            # if/else instead of "&&": a false condition would return 1 from
            # the case and abort the script (set -e).
            p) if [ "$page" -gt 0 ]; then page=$((page - 1)); fi ;;
            n) if [ "$end" -lt "$display_num" ]; then page=$((page + 1)); fi ;;
            /) filter_active=1; filter_pattern=""; 
               while true; do
                   clear
                   echo -e "${COLOR_HEAD}Filter Profiles${COLOR_RESET}"
                   echo -e "${COLOR_DIM}Type to filter, Enter to apply, ESC to cancel${COLOR_RESET}"
                   echo ""
                   echo -n "Filter: ${filter_pattern}_"
                   k=$(read_key) || { filter_active=0; filter_pattern=""; break; }
                   case "$k" in
                       $'\x1b') filter_active=0; filter_pattern=""; break ;;
                       $'\x7f'|$'\b') filter_pattern="${filter_pattern%?}" ;;
                       $'\r'|$'\n'|"") break ;;
                       *) if [[ "$k" =~ [[:print:]] ]]; then filter_pattern="${filter_pattern}${k}"; fi ;;
                   esac
               done
               page=0
               ;;
            $'\x1b') 
                if [ "$filter_active" -eq 1 ]; then
                    filter_active=0
                    filter_pattern=""
                    page=0
                else
                    return 1
                fi
                ;;
        esac
    done
}

# ==============================================================================
#  SEARCH & FILTER SYSTEM
# ==============================================================================

SEARCH_HISTORY_FILE="$HOME/.run_search_history"
SEARCH_HISTORY_MAX=20

save_search_term() {
    local term="$1"
    [ -z "$term" ] && return

    # Der komplette Read-Modify-Write-Zyklus läuft unter einer Sperre:
    # parallel laufende Instanzen überschrieben sich sonst gegenseitig
    # (Einträge gingen verloren).
    _lock_acquire "$SEARCH_HISTORY_FILE"

    # Remove duplicates (fixed-string match, safe with regex special chars)
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
        # PID im Temp-Namen: parallele run.sh-Instanzen dürfen sich nicht
        # gegenseitig die Temp-Datei wegschnappen.
        local tmp="${SEARCH_HISTORY_FILE}.tmp.$$"
        # "-e <pattern> -- <file>": ein Suchbegriff, der mit "-" beginnt
        # ("-x", "--"), würde sonst als Option interpretiert.  rg las dann
        # den Dateinamen als Muster und blockierte auf stdin — der Verlauf
        # wurde dabei leer geschrieben.
        _grep -vxF -e "$term" -- "$SEARCH_HISTORY_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$SEARCH_HISTORY_FILE" 2>/dev/null || rm -f "$tmp"
    fi

    printf '%s\n' "$term" >> "$SEARCH_HISTORY_FILE"

    # Keep only last N entries
    _trim_file_to_lines "$SEARCH_HISTORY_FILE" "$SEARCH_HISTORY_MAX"

    _lock_release "$SEARCH_HISTORY_FILE"
    return 0
}

get_search_history() {
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
        # tail -r ist auf macOS/BSD nativ verfügbar; tac nur mit GNU coreutils.
        # Reihenfolge: macOS-first, kein nutzloser fork für 'tac: command not found'.
        tail -r "$SEARCH_HISTORY_FILE" 2>/dev/null || tac "$SEARCH_HISTORY_FILE" 2>/dev/null || true
    fi
}

interactive_search() {
    local current_query=""
    local -a history_items=()
    IFS=$'\n' read -r -d '' -a history_items < <(get_search_history && printf '\0') || true
    local history_pos=-1

    clear
    echo -e "${COLOR_HEAD}Search Tasks${COLOR_RESET}"
    echo -e "${COLOR_INFO}Type to search (ESC to cancel, Enter to apply):${COLOR_RESET}"
    if [ ${#history_items[@]} -gt 0 ]; then
        echo -e "${COLOR_DIM}Recent: ${history_items[0]}${COLOR_RESET}"
    fi
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
    echo -n "Search: "

    while true; do
        char=$(read_key) || return 1
        case "$char" in
            $'\x7f'|$'\x08')  # Backspace
                if [ -n "$current_query" ]; then
                    current_query="${current_query%?}"
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                fi
                ;;
            $'\x1b')  # Pure ESC
                filter_query=""
                return 1
                ;;
            $'\x1b[A'|$'\x1bOA')
                if [ ${#history_items[@]} -gt 0 ]; then
                    # Arrow Up - previous history
                    history_pos=$((history_pos + 1))
                    [ "$history_pos" -ge ${#history_items[@]} ] && history_pos=$((${#history_items[@]} - 1))
                    current_query="${history_items[$history_pos]}"
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                fi
                ;;
            $'\x1b[B'|$'\x1bOB')
                if [ "$history_pos" -gt 0 ]; then
                    # Arrow Down - next history
                    history_pos=$((history_pos - 1))
                    if [ "$history_pos" -lt 0 ]; then
                        history_pos=-1
                        current_query=""
                    else
                        current_query="${history_items[$history_pos]}"
                    fi
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                fi
                ;;
            "")  # Enter
                filter_query="$current_query"
                [ -n "$filter_query" ] && save_search_term "$filter_query"
                return 0
                ;;
            *)
                if [[ "$char" =~ [[:print:]] ]]; then
                    current_query="${current_query}${char}"
                    history_pos=-1
                    echo -n "${char}"
                fi
                ;;
        esac
    done
}

# ==============================================================================
#  TAG SYSTEM
# ==============================================================================

# Extracts all #tags from a description.
# Result: EXTRACTED_TAG_LIST (array).
#
# An array instead of a space separated string: the string variant needed word
# splitting, and word splitting depends on the current IFS — a prefix
# assignment like `IFS=$'\n' read ... < <(get_all_tags)` leaks into the
# process substitution subshell and turned all tags into a single one.
EXTRACTED_TAG_LIST=()
extract_tags() {
    local desc="$1"
    EXTRACTED_TAG_LIST=()
    # Bash-Regex statt echo|grep|tr (3 externe Prozesse gespart)
    local rest="$desc"
    while [[ "$rest" =~ (#[a-zA-Z0-9_-]+) ]]; do
        local _tag="${BASH_REMATCH[1]}"
        EXTRACTED_TAG_LIST+=("$_tag")
        # SC2295: BASH_REMATCH in ${#} als Pattern muss über Variable referenziert werden
        rest="${rest#*"$_tag"}"
    done
}

has_tag() {
    local desc="$1"
    local tag="$2"
    # Exact token match: "#dev" must not match "#developer" and "#de" must not
    # match "#dev".  The tag is matched literally (it may only contain
    # [a-zA-Z0-9_-]), surrounded by non-tag characters or string boundaries.
    local needle="${tag#\#}"
    case "$needle" in
        ''|*[!a-zA-Z0-9_-]*) return 1 ;;
    esac
    local rest="$desc"
    while :; do
        case "$rest" in
            *"#$needle")
                # The match must not be followed by another tag character
                local after="${rest#*\#"$needle"}"
                case "$after" in
                    [a-zA-Z0-9_-]*) ;;
                    *) return 0 ;;
                esac
                rest="$after"
                ;;
            *) return 1 ;;
        esac
    done
}

get_all_tags() {
    local -a tags=()
    local tag _tag_line
    # Default-IFS hart setzen: die Funktion läuft in einem
    # Process-Substitution-Subshell, in den der IFS des Aufrufers leakt.
    local IFS=$' \t\n'
    # Process-Substitution: kein all_output-String im Speicher
    # `|| [ -n "$_tag_line" ]` → die letzte Zeile ohne Newline wird mit gelesen
    while read -r _tag_line || [ -n "$_tag_line" ]; do
        # Tolerate CRLF line endings
        _tag_line="${_tag_line%$'\r'}"
        split_task_line "$_tag_line"
        extract_tags "$_f_desc"
        # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
        if [ ${#EXTRACTED_TAG_LIST[@]} -gt 0 ]; then
            for tag in "${EXTRACTED_TAG_LIST[@]}"; do
                tags+=("$tag")
            done
        fi
    done < <(
        if [ "${#task_config_files[@]}" -gt 0 ]; then
            cat "${task_config_files[@]}" 2>/dev/null || true
        elif [ -f "$config_path" ]; then
            cat "$config_path"
        fi
    )
    # Unique sort — leeres Array würde in Bash 3.2 "unbound variable" werfen
    [ ${#tags[@]} -eq 0 ] && return 0
    printf "%s\n" "${tags[@]}" | sort -u
}

show_tag_menu() {
    local -a all_tags=()
    IFS=$'\n' read -r -d '' -a all_tags < <(get_all_tags && printf '\0') || true
    local num_tags=${#all_tags[@]}
    
    if [ "$num_tags" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tags found. Add tags with #tagname in task descriptions.${COLOR_RESET}"
        sleep 1
        return
    fi
    
    clear
    echo -e "${COLOR_HEAD}🏷  Filter by Tag${COLOR_RESET}"
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
    
    echo "0) ${COLOR_SEL}[All Tasks]${COLOR_RESET}"
    local i
    for (( i=0; i<num_tags; i++ )); do
        if [ "$tag_filter" == "${all_tags[$i]}" ]; then
            printf "%d) ${COLOR_SEL}✓ %s${COLOR_RESET}\n" "$((i+1))" "${all_tags[$i]}"
        else
            printf "%d) %s\n" "$((i+1))" "${all_tags[$i]}"
        fi
    done
    
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
    # Two digit selection: with more than nine tags the single digit keys
    # could not reach the entries 10+ — they were displayed but not selectable.
    if [ "$num_tags" -gt 9 ]; then
        echo "[1-9] [0-9+Enter] Filter [q]uit"
    else
        echo "[1-9] Filter [q]uit"
    fi
    
    # Buffered numeric input: a single digit selects immediately, a second
    # digit extends the number (10+), Enter confirms.
    local _buf=""
    while true; do
        key=$(read_key) || break
        case "$key" in
            "0")
                if [ -n "$_buf" ]; then
                    # "0" as the first digit is not a valid entry (0 = All)
                    _buf=""
                    continue
                fi
                tag_filter=""
                echo -e "${COLOR_SEL}✔ Showing all tasks${COLOR_RESET}"
                sleep 0.5
                break
                ;;
            [1-9])
                if [ -n "$_buf" ]; then
                    # Second digit: 10..99
                    local _idx=$(( _buf * 10 + key - 1 ))
                    _buf=""
                    if [ "$_idx" -lt "$num_tags" ]; then
                        tag_filter="${all_tags[$_idx]}"
                        echo -e "${COLOR_SEL}✔ Filtering by ${tag_filter}${COLOR_RESET}"
                        sleep 0.5
                        break
                    fi
                    continue
                fi
                # First digit: could be 1..9 or the start of a two digit number
                if [ "$num_tags" -gt 9 ]; then
                    _buf="$key"
                    # A short timeout collects the second digit
                    # 0,5 s Zeitfenster fuer die zweite Ziffer (10+)
                    _second=$(read_key_optional 5)
                    if [ -n "$_second" ] && [[ "$_second" =~ ^[0-9]$ ]]; then
                        local _idx2=$(( key * 10 + _second - 1 ))
                        if [ "$_idx2" -lt "$num_tags" ]; then
                            tag_filter="${all_tags[$_idx2]}"
                            echo -e "${COLOR_SEL}✔ Filtering by ${tag_filter}${COLOR_RESET}"
                            sleep 0.5
                            break
                        fi
                        _buf=""
                        continue
                    fi
                    _buf=""
                fi
                local _idx=$(( key - 1 ))
                if [ "$_idx" -lt "$num_tags" ]; then
                    tag_filter="${all_tags[$_idx]}"
                    echo -e "${COLOR_SEL}✔ Filtering by ${tag_filter}${COLOR_RESET}"
                    sleep 0.5
                    break
                fi
                ;;
            $'\r'|$'\n')
                [ -n "$_buf" ] || continue
                local _idx3=$(( _buf - 1 ))
                _buf=""
                if [ "$_idx3" -lt "$num_tags" ]; then
                    tag_filter="${all_tags[$_idx3]}"
                    echo -e "${COLOR_SEL}✔ Filtering by ${tag_filter}${COLOR_RESET}"
                    sleep 0.5
                    break
                fi
                ;;
            "q"|"Q"|$'\x1b')
                break
                ;;
        esac
    done
    selected_index=0
}

# ==============================================================================
#  TASK FAVORITES
# ==============================================================================

readonly RUN_FAVORITES_FILE="$HOME/.run_favorites"

is_favorite() {
    local task_name="$1"
    if [ -f "$RUN_FAVORITES_FILE" ]; then
        # "-e <pattern> -- <file>": ein Task-Name, der mit "-" beginnt,
        # würde sonst als Option interpretiert (rg las den Dateinamen als
        # Muster und blockierte auf stdin).
        _grep -qxF -e "$task_name" -- "$RUN_FAVORITES_FILE" || return 1
    else
        return 1
    fi
}

toggle_favorite() {
    local task_name="$1"
    # Read-Modify-Write unter einer Sperre: parallel laufende Instanzen
    # überschrieben sich sonst gegenseitig (Favoriten gingen verloren).
    _lock_acquire "$RUN_FAVORITES_FILE"
    if is_favorite "$task_name"; then
        # PID im Temp-Namen: parallele run.sh-Instanzen dürfen sich nicht
        # gegenseitig die Temp-Datei wegschnappen.
        local tmp="${RUN_FAVORITES_FILE}.tmp.$$"
        if _grep -vxF -e "$task_name" -- "$RUN_FAVORITES_FILE" > "$tmp"; then
            mv "$tmp" "$RUN_FAVORITES_FILE" 2>/dev/null || rm -f "$tmp"
        else
            rm -f "$tmp"
        fi
        _lock_release "$RUN_FAVORITES_FILE"
        echo -e "${COLOR_INFO}⭐ Removed from favorites${COLOR_RESET}"
    else
        printf '%s\n' "$task_name" >> "$RUN_FAVORITES_FILE"
        _lock_release "$RUN_FAVORITES_FILE"
        echo -e "${COLOR_SEL}⭐ Added to favorites!${COLOR_RESET}"
    fi
    sleep 0.5
}

show_favorites() {
    clear
    echo -e "${COLOR_HEAD}⭐ Favorite Tasks${COLOR_RESET}"

    # Datei einmalig in Array lesen — kein sed-Fork pro Tastendruck
    local -a fav_list=()
    if [ -f "$RUN_FAVORITES_FILE" ] && [ -s "$RUN_FAVORITES_FILE" ]; then
        while IFS= read -r _fline || [ -n "$_fline" ]; do
            _fline="${_fline%$'\r'}"
            [ -n "$_fline" ] && fav_list+=("$_fline")
        done < "$RUN_FAVORITES_FILE"
    fi

    local fav_count=${#fav_list[@]}
    if [ "$fav_count" -eq 0 ]; then
        echo -e "${COLOR_DIM}No favorites yet. Press [*] on a task to add it!${COLOR_RESET}"
    else
        echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
        local idx=1
        for _fav in "${fav_list[@]}"; do
            # Every entry gets a number — entries 10+ were displayed without
            # a number and could therefore not be selected.
            printf "%d) ${COLOR_SEL}%s${COLOR_RESET}\n" "$idx" "$_fav"
            idx=$((idx + 1))
        done
    fi
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
    if [ "$fav_count" -gt 9 ]; then
        echo -e "\n[1-9] [two digits] Execute [q]uit"
    else
        echo -e "\n[1-9] Execute [q]uit"
    fi

    while true; do
        key=$(read_key) || break
        if [[ "$key" =~ ^[0-9]$ ]]; then
            # Zwei-stellige Auswahl: die Einträge 10+ wurden angezeigt, waren
            # aber nicht erreichbar — es wurde nur eine Ziffer akzeptiert.
            local _num="$key"
            if [ "$fav_count" -gt 9 ] && [ "$_num" != "0" ]; then
                local _second
                # 0,5 s Zeitfenster fuer die zweite Ziffer (10+)
                _second=$(read_key_optional 5)
                if [ -n "$_second" ] && [[ "$_second" =~ ^[0-9]$ ]]; then
                    _num="${_num}${_second}"
                fi
            fi
            # "10#" erzwingt die Basis 10 (sonst wäre "08" ein Oktal-Fehler)
            if selection_index "$_num" "$fav_count"; then
                local fav_name="${fav_list[$SELECT_INDEX]}"  # Array-Index statt sed-Fork
                if [ -n "$fav_name" ]; then
                    local _rc=0
                    find_task_in_menu "$fav_name" "_execute_fav_callback" || _rc=$?
                    if [ "$_TASK_FOUND" -eq 0 ]; then
                        echo -e "${COLOR_ERR}Task not found in current profile${COLOR_RESET}"
                        sleep 1
                    elif [ "$_rc" -eq 0 ]; then
                        clear
                        return 0
                    else
                        echo -e "${COLOR_ERR}Task failed (exit $_rc)${COLOR_RESET}"
                        sleep 1
                    fi
                fi
            fi
        elif [[ "$key" == "q" ]] || [[ "$key" == "Q" ]] || [[ "$key" == $'\x1b' ]]; then
            break
        fi
    done
    clear
}

_execute_fav_callback() {
    local name="$1"
    local cmd="$2"
    local desc="$3"
    execute_task "$cmd" "$name" "$desc"
}

# ==============================================================================
#  TASK HISTORY & LOGGING
# ==============================================================================

add_to_history() {
    local task_name="$1"
    local exit_code="$2"
    local exec_time="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local status="✔"
    [ "$exit_code" -ne 0 ] && status="✗"
    # append_line hängt an und kürzt unter einer Sperre — bei parallelen
    # Tasks gingen sonst Einträge verloren.
    append_line "$RUN_HISTORY_FILE" \
        "$timestamp | $status | $task_name | exit:$exit_code | time:${exec_time}s" \
        "$RUN_HISTORY_MAX"

    add_to_recent "$task_name" "$exec_time"
}

show_history() {
    clear
    echo -e "${COLOR_HEAD}$(msg history_label)${COLOR_RESET}"
    if [ ! -f "$RUN_HISTORY_FILE" ] || [ ! -s "$RUN_HISTORY_FILE" ]; then
        echo -e "${COLOR_DIM}$(msg history_empty)${COLOR_RESET}"
    else
        local line _s
        # Process-Substitution statt Here-String (kein temporäres File)
        while IFS= read -r line; do
            # Bash-String-Op statt echo|cut|xargs (2 externe Prozesse gespart)
            _s="${line#*| }"
            _s="${_s%% |*}"
            if [ "$_s" = "✔" ]; then
                echo -e "${COLOR_SEL}$line${COLOR_RESET}"
            else
                echo -e "${COLOR_ERR}$line${COLOR_RESET}"
            fi
        done < <(tail -20 "$RUN_HISTORY_FILE" 2>/dev/null)
    fi
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    consume_keypress
}

add_to_recent() {
    local task_name="$1"
    local exec_time="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Format: timestamp|config_path|task_name|exec_time
    append_line "$RUN_RECENT_FILE" \
        "$timestamp|$config_path|$task_name|${exec_time}s" \
        "$RUN_RECENT_MAX"
}

show_recent() {
    clear
    echo -e "${COLOR_HEAD}$(msg recent_tasks)${COLOR_RESET}"

    if [ ! -f "$RUN_RECENT_FILE" ] || [ ! -s "$RUN_RECENT_FILE" ]; then
        echo -e "${COLOR_DIM}No recent tasks yet.${COLOR_RESET}"
        echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
        consume_keypress
        return
    fi

    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
    local -a lines=()
    IFS=$'\n' read -r -d '' -a lines < <(tail -n 20 "$RUN_RECENT_FILE" 2>/dev/null && printf '\0') || true

    # Leeres Array → "${lines[@]}" würde in Bash 3.2 mit set -u abbrechen
    if [ ${#lines[@]} -eq 0 ]; then
        echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
        consume_keypress
        return
    fi

    local idx=1
    local line _path _name _rest
    for line in "${lines[@]}"; do
        # Split "timestamp|config_path|task_name|exec_time" ohne Here-String
        _rest="${line#*|}"
        _path="${_rest%%|*}"
        _rest="${_rest#*|}"
        _name="${_rest%%|*}"
        # ${##*/} statt basename-Subshell
        local short_path="${_path##*/}"
        printf "%d) ${COLOR_SEL}%s${COLOR_RESET} ${COLOR_DIM}(%s)${COLOR_RESET}\n" "$idx" "$_name" "$short_path"
        idx=$((idx + 1))
    done
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
    local _num_entries=${#lines[@]}
    if [ "$_num_entries" -gt 9 ]; then
        echo -e "\n[1-9] [two digits] Execute [q]uit"
    else
        echo -e "\n[1-9] Execute [q]uit"
    fi

    while true; do
        key=$(read_key) || break
        if [[ "$key" =~ ^[0-9]$ ]]; then
            # Zwei-stellige Auswahl: die Einträge 10+ wurden angezeigt, waren
            # aber nicht erreichbar — es wurde nur eine Ziffer akzeptiert.
            local _num="$key"
            if [ "$_num_entries" -gt 9 ] && [ "$_num" != "0" ]; then
                local _second
                # 0,5 s Zeitfenster fuer die zweite Ziffer (10+)
                _second=$(read_key_optional 5)
                if [ -n "$_second" ] && [[ "$_second" =~ ^[0-9]$ ]]; then
                    _num="${_num}${_second}"
                fi
            fi
            # "10#" erzwingt die Basis 10 (sonst wäre "08" ein Oktal-Fehler)
            if selection_index "$_num" "$_num_entries"; then
                local sel="$SELECT_INDEX"
                # ":-" verhindert "unbound variable" bei einem Index außerhalb der Liste
                local entry="${lines[$sel]:-}"
                if [ -n "$entry" ]; then
                    _rest="${entry#*|}"
                    _path="${_rest%%|*}"
                    _rest="${_rest#*|}"
                    _name="${_rest%%|*}"
                    if [ -f "$_path" ]; then
                        local _rc=0
                        _run_recent_task "$_path" "$_name" || _rc=$?
                        if [ "$_rc" -eq 0 ]; then
                            clear
                            return 0
                        elif [ "$_rc" -eq 1 ]; then
                            echo -e "${COLOR_ERR}Task not found: $_name${COLOR_RESET}"
                            sleep 1
                        else
                            echo -e "${COLOR_ERR}Task failed (exit $_rc): $_name${COLOR_RESET}"
                            sleep 1
                        fi
                    else
                        echo -e "${COLOR_ERR}Profile not found: $_path${COLOR_RESET}"
                        sleep 1
                    fi
                fi
            fi
        elif [[ "$key" == "q" ]] || [[ "$key" == "Q" ]] || [[ "$key" == $'\x1b' ]]; then
            break
        fi
    done
    clear
}

# Führt einen zuletzt gelaufenen Task aus: Config auf das Config des Tasks
# umstellen, den Task suchen und danach den alten Zustand wiederherstellen.
_run_recent_task() {
    local path="$1"
    local name="$2"
    local prev_config="$config_path"
    local prev_mode="$active_mode"

    config_path="$path"
    case "$path" in
        "$HOME"/*) active_mode="global" ;;
        *)         active_mode="local"  ;;
    esac
    # Die Taskliste kommt aus task_config_files — sie muss für das Config des
    # letzten Tasks neu aufgebaut werden, sonst wird der falsche Task gefunden.
    detect_config_files

    local _rc=0
    find_task_in_menu "$name" "_execute_recent_callback" || _rc=$?
    local _found="$_TASK_FOUND"

    # Zustand immer zurücksetzen (auch nach erfolgreicher Ausführung)
    config_path="$prev_config"
    active_mode="$prev_mode"
    detect_config_files

    # 1 → task not found, otherwise the exit code of the task
    [ "$_found" -eq 0 ] && return 1
    return "$_rc"
}

_execute_recent_callback() {
    local name="$1"
    local cmd="$2"
    local desc="$3"
    execute_task "$cmd" "$name" "$desc"
}

show_logs() {
    clear
    echo -e "${COLOR_HEAD}$(msg logs_title)${COLOR_RESET}"
    echo -e "${COLOR_DIM}Last 9 log files:${COLOR_RESET}"
    echo ""
    
    local -a log_files=()
    # Die Log-Dateien beginnen mit dem Zeitstempel (create_log_file) — die
    # Sortierung nach Name ist damit chrono-logisch (neueste zuerst).
    IFS=$'\n' read -r -d '' -a log_files < <(find "$RUN_LOG_DIR" -type f -name "*.log" 2>/dev/null | sort -r | head -9 && printf '\0') || true

    if [ ${#log_files[@]} -eq 0 ]; then
        echo -e "${COLOR_DIM}$(msg no_logs)${COLOR_RESET}"
    else
        local idx=1
        local log_file
        for log_file in "${log_files[@]}"; do
            # ${##*/} statt basename-Subshell
            echo "$idx) ${log_file##*/}"
            idx=$((idx + 1))
        done
        echo ""
        echo "[1-9] View [q]uit"
        
        while true; do
            key=$(read_key) || break
            if [[ "$key" =~ ^[0-9]$ ]]; then
                local sel=$((key - 1))
                if [ "$sel" -lt "${#log_files[@]}" ]; then
                    clear
                    echo -e "${COLOR_HEAD}Log: ${log_files[$sel]##*/}${COLOR_RESET}"
                    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
                    cat "${log_files[$sel]}"
                    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
                    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
                    consume_keypress
                    return
                fi
            elif [[ "$key" == "q" ]] || [[ "$key" == "Q" ]] || [[ "$key" == $'\x1b' ]]; then
                break
            fi
        done
    fi
    
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    consume_keypress
}

# ==============================================================================
#  TASK DEPENDENCIES & PARALLEL EXECUTION
# ==============================================================================

parse_task_deps() {
    local task_cmd="$1"
    local task_desc="${2:-}"
    # Extract [depends: task1,task2] from the command or from the description
    #
    # Both fields are searched: the documentation describes the annotation in
    # the description ("0|Test|npm test|Run tests [depends: Build]"), the
    # implementation read it from the command.  A config that follows the
    # documentation therefore ran the dependency *not*.
    if [[ "$task_cmd" =~ \[depends:([^\]]+)\] ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$task_desc" =~ \[depends:([^\]]+)\] ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 0
}

execute_task_deps() {
    local deps_str="$1"
    # IFS-Split ohne Here-String (kein temporäres File, ~130 µs pro Aufruf)
    split_by_char ',' "$deps_str"
    local -a deps=("${_SPLIT_ARR[@]}")

    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"

    # Check if parallel execution is enabled
    if [ "${RUN_PARALLEL_DEPS:-0}" = "1" ] && [ "${#deps[@]}" -gt 1 ]; then
        echo -e "${COLOR_DIM}  (running ${#deps[@]} dependencies in parallel)${COLOR_RESET}"
        local -a dep_pids=()
        local -a dep_names=()
        local -a dep_logs=()

        for dep in "${deps[@]}"; do
            dep=$(trim_whitespace "$dep")
            [ -z "$dep" ] && continue
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"

            # Log in CACHE_DIR ablegen — wird bei EXIT automatisch bereinigt
            local dep_log="${CACHE_DIR}/dep_${dep}_$$.log"
            dep_logs+=("$dep_log")
            dep_names+=("$dep")

            # Execute in background.  PIPESTATUS[0] carries the real status of
            # find_task_in_menu — the status of "tee" is always 0 and would
            # report every failed dependency as success.
            #
            # The quiet callback runs the task without any terminal
            # interaction: a background process must not touch the terminal
            # of the menu (no preview, no screen clear, no terminal reset
            # and no "press any key" prompt — the prompt alone deadlocked
            # the menu, because the dependency waited for a key that the
            # parent process was waiting for).
            (
                find_task_in_menu "$dep" '_execute_dep_callback_quiet' 2>&1 | tee "$dep_log"
                exit "${PIPESTATUS[0]}"
            ) &
            dep_pids+=("$!")
        done

        # Wait for all dependencies to complete
        echo ""
        show_spinner "Waiting for ${#deps[@]} parallel dependencies..."

        local all_success=1
        for i in "${!dep_pids[@]}"; do
            if ! wait "${dep_pids[$i]}"; then
                stop_spinner
                echo -e "${COLOR_ERR}❌ Dependency '${dep_names[$i]}' failed${COLOR_RESET}"
                all_success=0
            fi
        done

        stop_spinner
        [ "$all_success" -eq 1 ] && echo -e "${COLOR_SEL}✔ All dependencies completed${COLOR_RESET}"

        # Cleanup log files
        for log in "${dep_logs[@]+"${dep_logs[@]}"}"; do
            [ -f "$log" ] && rm -f "$log"
        done

        [ "$all_success" -eq 0 ] && return 1
        return 0
    else
        # Sequential execution (default)
        for dep in "${deps[@]}"; do
            dep=$(trim_whitespace "$dep")
            [ -z "$dep" ] && continue
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"

            # Find and execute the dependency task using helper.
            # The status of the dependency is propagated: a failed dependency
            # must stop the dependent task.
            if ! find_task_in_menu "$dep" '_execute_dep_callback'; then
                echo -e "${COLOR_ERR}❌ Dependency '$dep' failed or not found in:${COLOR_RESET}"
                if [ ${#task_config_files[@]} -gt 0 ]; then
                    for cf in "${task_config_files[@]}"; do echo -e "  ${COLOR_DIM}$cf${COLOR_RESET}"; done
                fi
                return 1
            fi
        done
    fi
    return 0
}

_execute_dep_callback() {
    local dep_name="$1"
    local dep_cmd="$2"
    local dep_desc="$3"
    execute_task "$dep_cmd" "$dep_name" "$dep_desc" || return 1
}

# Quiet variant for the parallel branch — see execute_task_quiet().
_execute_dep_callback_quiet() {
    local dep_name="$1"
    local dep_cmd="$2"
    local dep_desc="$3"
    execute_task_quiet "$dep_cmd" "$dep_name" "$dep_desc" || return 1
}

# ==============================================================================
#  MULTI-PROFILE EXECUTION
# ==============================================================================

execute_multi_profile_task() {
    local task_name="$1"
    local profiles_str="$2"  # comma-separated
    # IFS-Split ohne Here-String (kein temporäres File)
    split_by_char ',' "$profiles_str"
    local -a profiles=("${_SPLIT_ARR[@]}")

    echo -e "${COLOR_HEAD}Running task across ${#profiles[@]} profiles:${COLOR_RESET}"

    # Check if parallel execution is enabled
    if [ "${RUN_PARALLEL_MULTI:-0}" = "1" ] && [ "${#profiles[@]}" -gt 1 ]; then
        echo -e "${COLOR_DIM}  (running in parallel)${COLOR_RESET}"
        local -a profile_pids=()
        local -a profile_names=()
        local -a profile_logs=()

        for prof in "${profiles[@]}"; do
            prof=$(trim_whitespace "$prof")
            echo -e "  ${COLOR_DIM}→ [$prof] $task_name${COLOR_RESET}"

            # Log in CACHE_DIR ablegen — wird bei EXIT automatisch bereinigt
            local prof_log="${CACHE_DIR}/multi_prof_${prof}_$$.log"
            profile_logs+=("$prof_log")
            profile_names+=("$prof")

            # Execute in background with profile context
            (
                # Load profile configuration
                if ! load_profile_config "$prof"; then
                    echo -e "${COLOR_ERR}Failed to load profile: $prof${COLOR_RESET}" | tee "$prof_log"
                    exit 1
                fi

                # Find and execute the task in this profile
                if ! find_task_in_menu "$task_name" '_execute_profile_callback'; then
                    echo -e "${COLOR_ERR}Task not found in profile: $prof${COLOR_RESET}" | tee "$prof_log"
                    exit 1
                fi
            ) &
            profile_pids+=("$!")
        done

        # Wait for all profile executions
        echo ""
        show_spinner "Waiting for ${#profiles[@]} profile executions..."

        local all_success=1
        for i in "${!profile_pids[@]}"; do
            if ! wait "${profile_pids[$i]}"; then
                stop_spinner
                echo -e "${COLOR_ERR}❌ Profile '${profile_names[$i]}' failed${COLOR_RESET}"
                all_success=0
            fi
        done

        stop_spinner
        [ "$all_success" -eq 1 ] && echo -e "${COLOR_SEL}✔ All profiles completed${COLOR_RESET}"

        # Cleanup log files
        for log in "${profile_logs[@]+"${profile_logs[@]}"}"; do
            [ -f "$log" ] && rm -f "$log"
        done

        [ "$all_success" -eq 0 ] && return 1
        return 0
    else
        # Sequential execution
        for prof in "${profiles[@]}"; do
            prof=$(trim_whitespace "$prof")
            echo -e "  ${COLOR_INFO}→ Profile: $prof${COLOR_RESET}"

            # Load profile configuration
            if ! load_profile_config "$prof"; then
                echo -e "${COLOR_ERR}Failed to load profile: $prof${COLOR_RESET}"
                return 1
            fi

            # Find and execute the task in this profile
            if ! find_task_in_menu "$task_name" '_execute_profile_callback'; then
                echo -e "${COLOR_ERR}Task not found in profile: $prof${COLOR_RESET}"
                return 1
            fi
        done

        echo -e "${COLOR_SEL}✔ All profiles completed${COLOR_RESET}"
    fi
}

_execute_profile_callback() {
    local task_name="$1"
    local task_cmd="$2"
    local task_desc="$3"
    execute_task "$task_cmd" "$task_name" "$task_desc" || return 1
}

# ==============================================================================
#  PROJECT ANALYSIS
# ==============================================================================

analyze_project() {
    local profile="${1:-.}"
    local config_file=".tasks"

    if [ "$profile" != "." ] && [ "$profile" != "" ]; then
        config_file=".tasks.$profile"
    fi

    if [ ! -f "$config_file" ]; then
        echo -e "${COLOR_ERR}✗ No .tasks file found${COLOR_RESET}"
        return 1
    fi

    # Einmaliger awk-Durchlauf statt 10 separater grep-Aufrufe
    local total_tasks level_0 level_1 deps_count parallel_count \
          has_lint has_test has_build has_deploy test_count
    read -r total_tasks level_0 level_1 deps_count parallel_count \
             has_lint has_test has_build has_deploy test_count < <(
        awk '
            /^[0-9]/                           { tot++ }
            /^0\|/                             { l0++ }
            /^1\|/                             { l1++ }
            /depends:/                         { dep++ }
            /RUN_PARALLEL_DEPS=1|RUN_PARALLEL_MULTI=1/ { par++ }
            tolower($0) ~ /lint|eslint|pylint/ { lint++ }
            tolower($0) ~ /test|jest|pytest/   { tst++ }
            tolower($0) ~ /build|compile/      { bld++ }
            tolower($0) ~ /deploy|push|release/{ dpl++ }
            tolower($0) ~ /test/               { tc++ }
            END { print (tot+0),(l0+0),(l1+0),(dep+0),(par+0),(lint+0),(tst+0),(bld+0),(dpl+0),(tc+0) }
        ' "$config_file" 2>/dev/null
    ) || true
    # Leere Werte (z.B. bei einer nicht lesbaren Config) als 0 behandeln —
    # sonst wäre der Vergleich "[] -gt 0" ein arithmetischer Fehler.
    total_tasks="${total_tasks:-0}"; level_0="${level_0:-0}"; level_1="${level_1:-0}"
    deps_count="${deps_count:-0}"; parallel_count="${parallel_count:-0}"
    has_lint="${has_lint:-0}"; has_test="${has_test:-0}"; has_build="${has_build:-0}"
    has_deploy="${has_deploy:-0}"; test_count="${test_count:-0}"

    echo -e "\n${COLOR_SEL}📊 Project Analysis${COLOR_RESET}"
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"

    # 1. Basic Stats
    echo -e "${COLOR_INFO}📈 Statistics:${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Total Tasks:${COLOR_RESET} $total_tasks"
    echo -e "  ${COLOR_DIM}Main Tasks (Level 0):${COLOR_RESET} $level_0"
    [ "$level_1" -gt 0 ] && echo -e "  ${COLOR_DIM}Sub Tasks (Level 1):${COLOR_RESET} $level_1"
    echo -e "  ${COLOR_DIM}Tasks with Dependencies:${COLOR_RESET} $deps_count"
    echo -e "  ${COLOR_DIM}Parallel-ready Tasks:${COLOR_RESET} $parallel_count"

    echo ""

    # 2. Recommendations
    echo -e "${COLOR_INFO}💡 Recommendations:${COLOR_RESET}"

    if [ "$total_tasks" -gt 50 ]; then
        echo -e "  ${COLOR_WARN}⚠${COLOR_RESET}  ${COLOR_DIM}High task count (${total_tasks}):${COLOR_RESET}"
        echo -e "     Consider splitting into profiles:"
        echo -e "     ${COLOR_DIM}• .tasks.dev  (development)${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• .tasks.prod (production)${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• .tasks.test (testing)${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}Command: run dev / run prod / run test${COLOR_RESET}"
        echo ""
    fi

    if [ "$deps_count" -eq 0 ] && [ "$total_tasks" -gt 5 ]; then
        echo -e "  ${COLOR_INFO}ℹ${COLOR_RESET}  ${COLOR_DIM}No dependencies found:${COLOR_RESET}"
        echo -e "     Consider adding task chains for workflows:"
        echo -e "     ${COLOR_DIM}• 0|Build|npm run build|Build${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• 0|Test|npm test|Test [depends: Build]${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• 0|Deploy|./deploy.sh|[!] Deploy [depends: Test]${COLOR_RESET}"
        echo ""
    fi

    if [ "$parallel_count" -eq 0 ] && [ "$total_tasks" -gt 10 ]; then
        echo -e "  ${COLOR_INFO}⚡${COLOR_RESET}  ${COLOR_DIM}Parallel execution not configured:${COLOR_RESET}"
        echo -e "     Enable for faster execution:"
        echo -e "     ${COLOR_DIM}export RUN_PARALLEL_DEPS=1${COLOR_RESET}"
        if [ "$test_count" -gt 2 ]; then
            echo -e "     ${COLOR_DIM}Performance boost expected: ~2-3x faster${COLOR_RESET}"
        fi
        echo ""
    fi

    # (has_lint/has_test/has_build/has_deploy/test_count wurden bereits oben via awk befüllt)

    echo -e "${COLOR_INFO}✓ Quality Score:${COLOR_RESET}"
    [ "$has_lint" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Linting${COLOR_RESET} (code quality)" || echo -e "  ✗ ${COLOR_DIM}Linting${COLOR_RESET} (code quality) - consider adding"
    [ "$has_test" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Testing${COLOR_RESET} (test coverage)" || echo -e "  ✗ ${COLOR_DIM}Testing${COLOR_RESET} (test coverage) - consider adding"
    [ "$has_build" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Building${COLOR_RESET} (production ready)" || echo -e "  ✗ ${COLOR_DIM}Building${COLOR_RESET} (production ready) - consider adding"
    [ "$has_deploy" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Deployment${COLOR_RESET} (automation)" || echo -e "  ✗ ${COLOR_DIM}Deployment${COLOR_RESET} (automation) - consider adding"

    echo ""

    # 3. Quick wins
    local quick_wins=0
    echo -e "${COLOR_INFO}🎯 Quick Wins:${COLOR_RESET}"

    if [ "$total_tasks" -lt 20 ] && [ "$deps_count" -eq 0 ]; then
        echo -e "  1. Add dependencies to create task workflows"
        quick_wins=$((quick_wins + 1))
    fi
    if [ "$parallel_count" -eq 0 ] && [ "$deps_count" -gt 0 ]; then
        quick_wins=$((quick_wins + 1))
        echo -e "  ${quick_wins}. Enable RUN_PARALLEL_DEPS=1 for speed boost"
    fi
    if [ "$total_tasks" -gt 80 ]; then
        quick_wins=$((quick_wins + 1))
        echo -e "  ${quick_wins}. Create 2-3 profiles to reduce menu clutter"
    fi

    if [ "$quick_wins" -eq 0 ]; then
        echo -e "  ${COLOR_SEL}✓ No immediate improvements needed - project well-structured!${COLOR_RESET}"
    fi

    echo ""

    # 4. Next steps
    echo -e "${COLOR_INFO}📚 Next Steps:${COLOR_RESET}"
    echo -e "  • Run: ${COLOR_DIM}run${COLOR_RESET}  (use interactive menu)"
    echo -e "  • Edit: ${COLOR_DIM}run --edit${COLOR_RESET}  (edit .tasks file)"
    echo -e "  • Validate: ${COLOR_DIM}run --validate${COLOR_RESET}  (check syntax)"
    echo -e "  • Documentation: ${COLOR_DIM}docs/ADVANCED_USAGE.md${COLOR_RESET}  (learn patterns)"

    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}\n"

    return 0
}

# ==============================================================================
#  TASK EXECUTION HELPERS
# ==============================================================================

# Set to 1 by find_task_in_menu when the task was found.
# Needed to distinguish "task not found" (exit 1) from "task failed with
# exit code 1" — both would otherwise be indistinguishable.
_TASK_FOUND=0

find_task_in_menu() {
    # Find task by name across all tasks and execute callback.
    # Task format: level|name|cmd|desc — skip level field with _level.
    #
    # Return value:
    #   1 → task not found (see _TASK_FOUND)
    #   0 → task found and callback succeeded
    #   N → task found, callback failed with exit code N
    #
    # The callback status must be propagated: otherwise a failing dependency
    # was silently ignored and the dependent task ran anyway.
    local search_name="$1"
    local callback="$2"
    local -a opts=()
    _TASK_FOUND=0
    # In-process: the cache of _build_all_tasks() only survives when the
    # function runs in the current shell.
    _build_all_tasks
    opts=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    [ ${#opts[@]} -eq 0 ] && return 1

    local _rc=0
    for opt in "${opts[@]}"; do
        split_task_line "$opt"
        if [ "$_f_name" = "$search_name" ]; then
            # Direkter Funktionsaufruf statt eval: schneller und sicherer
            _TASK_FOUND=1
            "$callback" "$_f_name" "$_f_cmd" "$_f_desc"
            _rc=$?
            return "$_rc"
        fi
    done
    return 1
}

preview_task() {
    local cmd="$1"
    local name="$2"
    local desc="$3"

    clear
    echo -e "${COLOR_HEAD}Preview: $name${COLOR_RESET}"
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"

    echo -e "${COLOR_INFO}Description:${COLOR_RESET}"
    echo -e "  $desc\n"

    echo -e "${COLOR_INFO}Command to execute:${COLOR_RESET}"
    echo -e "  ${COLOR_SEL}$cmd${COLOR_RESET}\n"

    if [[ "$desc" == "[!]"* ]]; then
        echo -e "${COLOR_WARN}⚠ Requires confirmation${COLOR_RESET}\n"
    fi

    # Bash-Regex statt echo|grep-Fork
    if [[ "$cmd" == *'<<'* ]]; then
        echo -e "${COLOR_INFO}ℹ This task has inputs that will be prompted${COLOR_RESET}\n"
    fi

    # Check for dependencies
    local deps
    deps=$(parse_task_deps "$cmd" "$desc")
    if [ -n "$deps" ]; then
        echo -e "${COLOR_INFO}Dependencies:${COLOR_RESET}"
        split_by_char ',' "$deps"
        local d
        for d in "${_SPLIT_ARR[@]}"; do
            [ -z "$d" ] && continue
            echo -e "  ${COLOR_DIM}→ $d${COLOR_RESET}"
        done
        echo ""
    fi

    echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    consume_keypress
}

# ==============================================================================
#  TASK EXECUTION ENGINE
# ==============================================================================

# Lets the user pick one of several values for a task parameter.
#
# The caller captures the result with `r=$(select_dropdown ...)`, so the
# selection goes to stdout while the whole UI goes to stderr — otherwise the
# option list would end up inside the variable and the picked value would be
# lost.
select_dropdown() {
    local options_str="$1"
    local -a options=()
    # IFS-Split ohne Here-String (kein temporäres File, kein Fork)
    split_by_char ',' "$options_str"
    local _opt
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    if [ ${#_SPLIT_ARR[@]} -gt 0 ]; then
        for _opt in "${_SPLIT_ARR[@]}"; do
            [ -n "$_opt" ] && options+=("$_opt")
        done
    fi
    local selected=0
    local num=${#options[@]}
    [ "$num" -eq 0 ] && return 1

    # Without a TTY (pipe, SSH without -t) the options are chosen by number
    if [ ! -t 0 ]; then
        echo -e "${COLOR_HEAD}$(msg select_option)${COLOR_RESET}" >&2
        local _i
        for (( _i=0; _i<num; _i++ )); do
            printf "  %d)  %s\n" "$(( _i + 1 ))" "${options[$_i]}" >&2
        done
        local _pick=""
        printf "Select [1-%d] (empty = first): " "$num" >&2
        IFS= read -r _pick || _pick=""
        case "$_pick" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$_pick" -ge 1 ] && [ "$_pick" -le "$num" ]; then
                    echo "${options[$(( _pick - 1 ))]}"
                    return 0
                fi
                ;;
        esac
        echo "${options[0]}"
        return 0
    fi

    while true; do
        # Cursor zurück auf 0,0 statt clear → kein Flicker (wie Hauptmenü)
        if [ "${HAS_TPUT:-0}" -eq 1 ] && [ -n "${TPUT_CUP:-}" ]; then
            echo -ne "$TPUT_CUP" >&2
        else
            clear >&2
        fi
        echo -e "${COLOR_HEAD}$(msg select_option)${COLOR_RESET}" >&2
        for (( i=0; i<num; i++ )); do
            if [ "$i" -eq "$selected" ]; then
                echo -e "${COLOR_SEL}›${COLOR_RESET} ${options[$i]}" >&2
            else
                echo "  ${options[$i]}" >&2
            fi
        done
        echo -e "\n${COLOR_DIM}$(msg dropdown_hint)${COLOR_RESET}" >&2
        # Rest der Zeilen löschen damit alte Einträge nicht stehen bleiben
        [ "${HAS_TPUT:-0}" -eq 1 ] && [ -n "${TPUT_ED:-}" ] && echo -ne "$TPUT_ED" >&2

        key=$(read_key) || return 1
        case "$key" in
            $'\x1b[A'|$'\x1bOA') selected=$((selected - 1));;
            $'\x1b[B'|$'\x1bOB') selected=$((selected + 1));;
            $'\x1b') return 1;; # Pure Escape = cancel
            "k") selected=$((selected - 1));; "j") selected=$((selected + 1));;
            $'\r'|"") echo "${options[$selected]}"; return 0;; # Enter
        esac
        if [ "$selected" -lt 0 ]; then
            selected=$((num-1))
        fi
        if [ "$selected" -ge "$num" ]; then
            selected=0
        fi
    done
}

render_progress_bar() {
    local percent=$1
    local width=${2:-30}
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    local bar_filled bar_empty
    # printf -v mit Padding baut den Balken in einem einzigen Aufruf (bash 3.1+, kein Loop)
    printf -v bar_filled '%*s' "$filled" ''
    printf -v bar_empty  '%*s' "$empty"  ''
    printf "%s[%s%s] %3d%%${COLOR_RESET}" \
        "$COLOR_SEL" "${bar_filled// /=}" "${bar_empty// /-}" "$percent"
}

process_progress_output() {
    local line="$1"

    # Check for [progress:X%] marker
    if [[ "$line" =~ \[progress:([0-9]+)%\] ]]; then
        local percent="${BASH_REMATCH[1]}"
        render_progress_bar "$percent"
        echo ""
        return 0  # Suppress original line
    fi

    # Check for [progress:X/Y] marker (e.g., [progress:3/10])
    if [[ "$line" =~ \[progress:([0-9]+)/([0-9]+)\] ]]; then
        local current="${BASH_REMATCH[1]}"
        local total="${BASH_REMATCH[2]}"
        local percent=$((current * 100 / total))
        render_progress_bar "$percent"
        echo ""
        return 0  # Suppress original line
    fi

    # Return line normally if no progress marker
    echo "$line"
    return 0  # 0 statt 1: stabiler bei set -e, semantisch korrekt (kein Fehler)
}

_execute_pipeline_callback() {
    local step_name="$1"
    local step_cmd="$2"
    local step_desc="$3"
    execute_task "$step_cmd" "$step_name" "$step_desc" || return 1
}

# ==============================================================================
#  COMMAND RUNNER — TIMEOUT, INTERRUPT AND OUTPUT STREAMING
# ==============================================================================

# Quelltext des Env-Guards.
#
# Das Task-Skript läuft in einem Kind-Bash ("bash -c") — dort sind die
# Funktionen des Runners nicht verfügbar.  Der Guard wird deshalb als
# Quelltext in das Task-Skript eingebettet.
#
# Aufgabe: die ".env" des Projektverzeichnisses laden, ohne dass sie den
# Runner oder den Task beschädigen kann.  "set -a; source .env" exportiert
# *alle* Variablen der Datei — ein "PATH=/broken" therein zerstörte die
# Kommandosuche des Tasks, ein "BASH_ENV=..." wurde in jedem Kind-Bash
# ausgeführt.  Dieselbe Lücke wie bei "~/.run_vars" (siehe
# load_global_vars), deshalb werden die gefährlichen Namen nach dem Sourcing
# wiederhergestellt.
# shellcheck disable=SC2016
RUN_ENV_GUARD_SCRIPT='
_run_env_guard() {
    _g_path="$PATH"
    _g_ifs_set=0
    if [ -n "${IFS+set}" ]; then _g_ifs_set=1; _g_ifs="$IFS"; fi
    if [ -f ".env" ]; then
        set -a
        # "./.env" und nicht "source .env": "source" sucht den Dateinamen
        # im PATH, wenn er keinen Slash enthält — ein .env aus dem PATH
        # würde sonst geladen.
        . ./.env
        set +a
    fi
    PATH="$_g_path"
    if [ "$_g_ifs_set" -eq 1 ]; then IFS="$_g_ifs"; else unset IFS; fi
    unset BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT
    unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
}
'

# PIDs of the running parallel tasks — used by the Ctrl+C handler.
_parallel_task_pids=()

# Beendet alle direkten Kinder eines Prozesses.
#
# "pkill -P <ppid>" beendet auf macOS nichts: ohne Muster ist der Aufruf
# wirkungslos (der Kindprozess lebt weiter) — die Kinder werden deshalb über
# "pgrep -P" gesucht und einzeln beendet.
#
# Usage: kill_children <pid> [SIGNAL]
kill_children() {
    local _pid="$1" _sig="${2:-TERM}" _child
    for _child in $(pgrep -P "$_pid" 2>/dev/null); do
        kill -"$_sig" "$_child" 2>/dev/null || true
    done
    return 0
}

# Stops all running parallel tasks (task command + wrapper).
_kill_parallel_tasks() {
    local _p
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    [ ${#_parallel_task_pids[@]} -eq 0 ] && return 0
    for _p in "${_parallel_task_pids[@]}"; do
        kill_children "$_p" TERM
        kill -TERM "$_p" 2>/dev/null || true
    done
}

# Kills a process and all of its descendants.
#
# Killing only the direct child left the grandchildren (npm, docker, dev
# servers) running as orphans — after a timeout two "sleep 60" processes were
# still alive.  pgrep -P lists the children; the recursion covers the whole
# tree.  Systems without pgrep fall back to killing the single process.
#
# Usage: _kill_process_tree <pid> [SIGNAL]
_kill_process_tree() {
    local _pid="$1" _sig="${2:-TERM}" _child
    for _child in $(pgrep -P "$_pid" 2>/dev/null); do
        _kill_process_tree "$_child" "$_sig"
    done
    kill -"$_sig" "$_pid" 2>/dev/null || true
    return 0
}

# Runs a task command and streams its output to the terminal and the log file.
#
# Two details make the difference between "the menu comes back" and "the
# terminal has to be closed":
#
#  * The command runs in the *foreground*.  Bash sets SIGINT/SIGQUIT to
#    "ignore" for background jobs, so a task started with `&` could never be
#    stopped with Ctrl+C.  Foreground + `trap ':' INT` in the menu keeps the
#    default disposition in the child — Ctrl+C kills the task, the menu lives.
#
#  * The menu waits for the *command*, never for the end of the output pipe.
#    A task that leaves a background process behind (release script, dev
#    server, `cmd &`) keeps the pipe open forever — waiting for EOF froze the
#    menu until the terminal was closed.
#
# A watchdog enforces the timeout because macOS ships no `timeout` binary
# (only GNU coreutils provides it), so the configured TIMEOUT was silently
# ignored on macOS.  The watchdog kills the whole process tree, not just the
# direct child.
#
# Usage: run_task_streamed <script> <log-file> <timeout> [command args...]
# Exit status of the last run_task_streamed() call.
# The output has to reach the terminal, so the status cannot be returned
# via a command substitution.
TASK_EXIT_STATUS=0

# PID of the running timeout watchdog — the EXIT trap terminates it (a
# watchdog that outlives the runner would run until the timeout expires).
_WATCHDOG_PID=""
run_task_streamed() {
    local _script="$1" _log="$2" _secs="$3"
    shift 3
    local _fifo _pidfile _donefile _timeoutfile _reader_done
    local _rc=0 _n=0 _line

    TASK_EXIT_STATUS=0
    case "$_secs" in
        ''|*[!0-9]*) _secs=300 ;;
    esac
    [ "$_secs" -le 0 ] && _secs=300

    _fifo="${CACHE_DIR}/task_fifo_$$_${_log##*/}"
    _pidfile="${_fifo}.pid"
    _donefile="${_fifo}.done"
    _timeoutfile="${_fifo}.timeout"
    _reader_done="${_fifo}.reader"
    rm -f "$_fifo" "$_pidfile" "$_donefile" "$_timeoutfile" "$_reader_done"

    if ! mkfifo "$_fifo" 2>/dev/null; then
        # No FIFO available → run without live streaming
        ( exec "$@" ) 2>&1 | tee -a "$_log"
        TASK_EXIT_STATUS="${PIPESTATUS[0]}"
        return 0
    fi

    # Reader: forwards the FIFO content to the terminal and the log file.
    # `|| [ -n "$_line" ]` keeps the last line when the task output has no
    # trailing newline (e.g. `printf SUCCESS`).
    # The log file is opened once (fd 3) — one open/close per line was a
    # noticeable syscall overhead for output-heavy tasks.
    (
        exec 3>>"$_log" 2>/dev/null || exit 0
        while IFS= read -r _line || [ -n "$_line" ]; do
            process_progress_output "$_line"
            printf '%s\n' "$_line" >&3
            _line=""
        done < "$_fifo"
        exec 3>&-
        : > "$_reader_done"
    ) &
    local _reader_pid=$!

    # Watchdog: stops the command when the timeout expires.
    # Its output goes to /dev/null — a background job that keeps stdout open
    # would block `run --list | command` until the timeout expired.
    # The TERM trap makes the watchdog exit cleanly: a job that is killed
    # by a signal is reported by bash ("Terminated: 15 (…)" plus the whole
    # command text) and that garbage ended up in the user's terminal.
    (
        trap 'exit 0' TERM
        # Wait for the command PID (max ~2 s) so the timeout is not lost
        # because the watchdog woke up before the PID was published.
        _n=0
        while [ ! -s "$_pidfile" ] && [ "$_n" -lt 20 ]; do
            sleep 0.1
            _n=$(( _n + 1 ))
        done
        sleep "$_secs"
        _wpid=$(cat "$_pidfile" 2>/dev/null)
        if [ -n "$_wpid" ] && [ ! -f "$_donefile" ]; then
            printf '1' > "$_timeoutfile"
            # Kill the whole tree, not only the direct child — otherwise
            # grandchildren keep running as orphans.
            _kill_process_tree "$_wpid" TERM
            sleep 1
            _kill_process_tree "$_wpid" KILL
        fi
    ) >/dev/null 2>&1 &
    local _watchdog_pid=$!
    # Der Watchdog wird im EXIT-Trap beendet: bricht der Runner ab (SIGTERM,
    # SIGHUP), blieb er sonst als Waise zurück und lief bis zum Timeout
    # (300 s) weiter.
    _WATCHDOG_PID="$_watchdog_pid"

    # Command (foreground): `sh -c 'echo $PPID'` publishes the PID of this
    # subshell for the watchdog, `exec` replaces it with the command itself.
    ( sh -c 'echo $PPID' > "$_pidfile"; exec "$@" ) > "$_fifo" 2>&1
    _rc=$?

    : > "$_donefile"
    # Stop the watchdog and its sleep before it is killed itself — otherwise
    # the sleep would survive as an orphan (and the watchdog would stay alive
    # until the timeout expires).
    kill_children "$_watchdog_pid" TERM
    kill "$_watchdog_pid" 2>/dev/null || true
    _WATCHDOG_PID=""

    # Let the reader flush the remaining output, then stop it.
    # The wait is bounded: a task that leaves a background process behind
    # keeps the FIFO open forever and the reader would never see EOF.
    _n=0
    while [ ! -f "$_reader_done" ] && [ "$_n" -lt 40 ]; do
        sleep 0.05 2>/dev/null || sleep 1
        _n=$(( _n + 1 ))
    done
    kill "$_reader_pid" 2>/dev/null || true
    wait "$_reader_pid" 2>/dev/null || true

    [ -f "$_timeoutfile" ] && _rc=124
    rm -f "$_fifo" "$_pidfile" "$_donefile" "$_timeoutfile" "$_reader_done"

    TASK_EXIT_STATUS="$_rc"
    return 0
}

execute_task_pipeline() {
    local task_cmd="$1"
    local steps_str="${task_cmd#tasks:}"
    # IFS-Split ohne Here-String (kein temporäres File)
    split_by_char ';' "$steps_str"
    local -a steps=("${_SPLIT_ARR[@]}")
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    [ ${#steps[@]} -eq 0 ] && return 0
    for step in "${steps[@]}"; do
        step=$(trim_whitespace "$step")
        [ -z "$step" ] && continue
        echo -e "  ${COLOR_DIM}→ $step${COLOR_RESET}"
        if ! find_task_in_menu "$step" '_execute_pipeline_callback'; then
            echo -e "${COLOR_ERR}❌ Task '$step' failed or not found in:${COLOR_RESET}"
            if [ ${#task_config_files[@]} -gt 0 ]; then
                for cf in "${task_config_files[@]}"; do echo -e "  ${COLOR_DIM}$cf${COLOR_RESET}"; done
            fi
            return 1
        fi
    done
    return 0
}

execute_tasks_parallel() {
    local -a keys=()
    IFS=$'\n' read -r -d '' -a keys < <(printf "%s\n" "${!multi_select_map[@]}" | sort -n && printf '\0') || true
    if [ "${#keys[@]}" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tasks selected.${COLOR_RESET}"
        sleep 1
        return
    fi
    local -a pids=()
    local -a names=()
    local -a starts=()
    local started=0
    # Das Arbeitsverzeichnis der Tasks — config_dir_of() löst auch die
    # Sonderfälle auf (Pfad ohne Slash -> ".", Pfad in "/" -> "/").
    # "${config_path%/*}" lieferte für einen Pfad ohne Slash den Dateinamen
    # (das "cd" schlug fehl, der Task lief im falschen Verzeichnis) und für
    # einen Pfad in "/" einen leeren String ("cd ''" schlug fehl).
    local RUN_CONFIG_DIR
    RUN_CONFIG_DIR="$(config_dir_of "$config_path")"
    local _timeout="$task_timeout"
    for idx in "${keys[@]}"; do
        split_task_line "${menu_options[$idx]}"
        level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
        if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
            continue
        fi
        if [[ "$desc" == "[!]"* ]] || [[ "$cmd" == *"<<"* ]] || [[ "$cmd" == tasks:* ]]; then
            echo -e "${COLOR_WARN}Skipping '$name' (interactive or pipeline).${COLOR_RESET}"
            continue
        fi
        # Dependenz-Annotationen im Parallel-Modus behandeln wie im
        # sequentiellen: Dependencies laufen sequentiell VOR dem Task,
        # und die Annotation wird aus dem Kommando entfernt (sieht man
        # vorher als Literal-Argument im eval).
        local deps
        deps=$(parse_task_deps "$cmd" "$desc")
        if [ -n "$deps" ]; then
            if ! execute_task_deps "$deps"; then
                echo -e "${COLOR_ERR}✗ $name (dependencies failed)${COLOR_RESET}"
                continue
            fi
            cmd="${cmd// \[depends:[^]]*\]/}"
        fi
        # Der Timeout kann pro Task in der Beschreibung stehen ("[timeout: 120]")
        # — sonst gilt der globale Wert.  Die pro-Task-Regel galt vormals nur
        # im sequentiellen Modus, der Parallel-Modus nahm blind den globalen.
        task_timeout_for_desc "$desc"
        _timeout="$TASK_TIMEOUT_VALUE"
        local log_file
        create_log_file "$name"
        log_file="$LOG_FILE"
        local start_time
        start_time=$(date +%s)
        # shellcheck disable=SC2016
        local _par_body='
            trap - INT
            trap - PIPE
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            _run_env_guard
            eval "$RUN_CMD"
        '
        local _par_script="$RUN_ENV_GUARD_SCRIPT$_par_body"
        (
            run_task_streamed "$_par_script" "$log_file" "$_timeout" \
                env \
                RUN_MODE="$active_mode" \
                RUN_DIR="$RUN_CONFIG_DIR" \
                RUN_CMD="$cmd" \
                bash -c "$_par_script"
            # run_task_streamed liefert den echten Status in TASK_EXIT_STATUS
            # und gibt immer 0 zurück — ohne das explizite exit meldete der
            # Parallel-Modus jeden Task als "erfolgreich" (auch einen, der
            # mit exit 1 endete), und die Historie zeichnete "exit:0" auf.
            exit "${TASK_EXIT_STATUS:-0}"
        ) &
        pids+=("$!")
        _parallel_task_pids+=("$!")
        names+=("$name")
        starts+=("$start_time")
        started=$((started + 1))
    done
    if [ "$started" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tasks eligible for parallel run.${COLOR_RESET}"
        sleep 1
        # Nichts wurde ausgeführt — der Aufrufer muss das unterscheiden
        # können (vorher meldete die Funktion hier Erfolg).
        return 1
    fi
    # Ctrl+C stops all running parallel tasks.  Bash sets SIGINT to "ignore"
    # for background jobs, so the tasks themselves cannot be interrupted —
    # the menu kills them (and their children) instead.
    trap '_kill_parallel_tasks' INT
    local _failed=0
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}"
        local status=$?
        local end_time
        end_time=$(date +%s)
        local dur=$((end_time - starts[i]))
        add_to_history "${names[$i]}" "$status" "$dur"
        if [ "$status" -eq 0 ]; then
            echo -e "${COLOR_SEL}✔ ${names[$i]}${COLOR_RESET} (${dur}s)"
        else
            echo -e "${COLOR_ERR}✗ ${names[$i]}${COLOR_RESET} (${dur}s)"
            _failed=1
        fi
    done
    trap 'restore_term; cleanup_wrapper; exit 130' INT
    # The PID list is only valid for this run — an old entry would kill an
    # unrelated process on the next Ctrl+C.
    _parallel_task_pids=()
    # Parallel tasks may have altered terminal state — restore and suppress echo
    # before the "press key" prompt so no garbage appears on screen.
    stty sane 2>/dev/null || true
    stty -echo 2>/dev/null || true
    drain_stdin
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
    # Der Exit-Code meldet, ob alle Tasks erfolgreich waren — vorher
    # meldete die Funktion immer Erfolg, auch wenn ein Task fehlschlug.
    return "$_failed"
}

# Resolves the placeholders of a task command ("<<Name>>", "<<Name=a>>",
# "<<Name:a,b>>") and asks the user for the values.
#
# Result: RESOLVED_CMD (the command with the replaced placeholders).
#
# Endlosschleife: enthielt der eingegebene Wert den Platzhalter selbst
# ("<<Name>>"), blieb dieser im Kommando stehen und die while-Schleife fragte
# endlos nach.  Der verbliebene Platzhalter wird deshalb entfernt; zusätzlich
# begrenzt ein Zähler die Iterationen.
RESOLVED_CMD=""
resolve_placeholders() {
    local cmd="$1"
    local _iterations=0
    while [[ "$cmd" =~ \<\<([^:=>]+)(=[^:>]*)?(:[^>]*)?\>\> ]]; do
        _iterations=$(( _iterations + 1 ))
        if [ "$_iterations" -gt 20 ]; then
            echo -e "${COLOR_ERR}Zu viele Eingabefelder — der Task wird abgebrochen.${COLOR_RESET}"
            RESOLVED_CMD=""
            return 1
        fi
        local p="${BASH_REMATCH[1]}"
        local default_spec="${BASH_REMATCH[2]}"  # "=value" or ""
        local default_val="${default_spec#=}"     # strip leading "="
        local rest="${BASH_REMATCH[3]}"
        # Der vollständige Platzhalter-Text (für die Erkennung im Ergebnis)
        local _ph="<<${p}${default_spec}${rest}>>"
        if [[ "$rest" == :* ]]; then
            local opts_str="${rest:1}"
            echo -e "\n${COLOR_INFO}$(msg choose_for)${COLOR_RESET} $p"
            local r=""
            # Ein Abbruch (ESC) muss den Task abbrechen: vorher ersetzte der
            # leere Wert den Platzhalter und der Task lief mit einem
            # leeren Parameter ("--env ").
            if ! r=$(select_dropdown "$opts_str"); then
                echo -e "${COLOR_INFO}$(msg task_cancelled)${COLOR_RESET}"
                RESOLVED_CMD=""
                return 1
            fi
            cmd="${cmd//\<\<"$p":"$opts_str"\>\>/${r:-}}"
        else
            echo -e "\n${COLOR_INFO}$(msg input_for)${COLOR_RESET} $p"
            # "r" vorbelegen: bei EOF (Pipe ohne Eingabe) setzt "read" die
            # Variable auf "unset" — unter "set -u" wäre die Ersetzung dann
            # ein Abbruch.
            local r=""
            if [ -n "$default_val" ]; then
                read -r -p "[${default_val}] > " r || true
                [ -z "${r:-}" ] && r="$default_val"
            else
                read -r -p "> " r || true
            fi
            cmd="${cmd//<<${p}${default_spec}>>/${r:-}}"
        fi
        # Der Wert enthält den Platzhalter selbst → er wird entfernt,
        # damit die Schleife endet.
        if [[ "$cmd" == *"$_ph"* ]]; then
            cmd="${cmd//"$_ph"/}"
        fi
    done
    RESOLVED_CMD="$cmd"
    return 0
}

execute_task() {
    local cmd="$1"; local name="$2"; local desc="$3"; shift 3; local args=("$@")
    # dry_run_mode is set externally (--dry-run flag or future interactive 'd' key).
    # Do NOT reset here — it is consumed and cleared inside the dry-run block below.
    #
    # Quiet mode: the task runs in the background (parallel dependencies).
    # A background process must not touch the terminal of the menu — no
    # preview, no screen clear, no terminal reset and no key prompt.
    local _quiet=0
    [ "${TASK_QUIET:-0}" = "1" ] && _quiet=1
    # Show preview if interactive and not in CLI mode
    if [ "$_quiet" -eq 0 ] && [ "$is_interactive" -eq 1 ] && [ "${cli_mode:-0}" -eq 0 ]; then
        if ! preview_task "$cmd" "$name" "$desc"; then
            return  # User cancelled
        fi
    fi

    if [[ "$cmd" == tasks:* ]]; then
        execute_task_pipeline "$cmd"
        return $?
    fi

    if [ "$_quiet" -eq 0 ] && [ "$is_interactive" -eq 1 ]; then
        # "|| true": a failing tput (TERM=dumb, broken terminfo) must not
        # abort the script — the cursor restore is cosmetic.
        tput cnorm 2>/dev/null || true
    fi
    if [ "$_quiet" -eq 0 ] && [ "${cli_mode:-0}" -eq 0 ]; then
        clear
    fi
    echo -e "${COLOR_HEAD}$(msg executing)${COLOR_RESET} $name"

    if [[ "$desc" == "[!]"* ]]; then
        echo -e "\n${COLOR_WARN}⚠ $(msg warning_label): ${desc#"[!] "}${COLOR_RESET}"
        # "|| true": ohne TTY (SSH ohne -t, Pipe, cron) liefert read sofort
        # EOF — ohne das würde das Skript unter "set -e" abbrechen.
        read -p "$(msg confirm_prompt) " -n 1 -r || true; echo ""
        if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
            # Abgelehnt (oder gar keine Bestätigung möglich): der Task wurde
            # NICHT ausgeführt.  Der Rückgabewert muss das widerspiegeln —
            # sonst meldete "run --run <task>" Erfolg, obwohl nichts lief.
            echo -e "${COLOR_INFO}$(msg task_cancelled)${COLOR_RESET}"
            return 1
        fi
    fi

    # Handle task dependencies
    # Die Annotation wird im Kommando *und* in der Beschreibung gesucht:
    # die Doku beschreibt beide Formen ("cmd [depends: X]" und
    # "desc [depends: X]").
    local deps
    deps=$(parse_task_deps "$cmd" "$desc")
    if [ -n "$deps" ]; then
        execute_task_deps "$deps" || return 1
        # Remove dependency annotation from command — alle Vorkommen, nicht
        # nur das letzte: "%" hätte bei einer Annotation mitten im Kommando
        # nichts entfernt (das Muster muss am Ende stehen) und der Task
        # wäre mit "[depends: X]" in der Kommandozeile gescheitert.
        cmd="${cmd// \[depends:[^]]*\]/}"
    fi

    # Platzhalter-Eingaben ("<<Name>>", "<<Name=a>>", "<<Name:a,b>>")
    if ! resolve_placeholders "$cmd"; then
        return 1
    fi
    cmd="$RESOLVED_CMD"

    set +u; echo -e "${COLOR_DIM}> $cmd ${args[*]:-}${COLOR_RESET}\n"; set -u
    save_state

    if [ "$dry_run_mode" -eq 1 ]; then
        dry_run_mode=0  # Consume the flag — one-shot per execution
        echo -e "${COLOR_INFO}🔍 DRY-RUN: Command would execute as above${COLOR_RESET}"
        echo -e "${COLOR_DIM}(No actual execution)${COLOR_RESET}\n"
        if [ "${cli_mode:-0}" -eq 0 ]; then
            echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
        fi
        return 0
    fi

    # Measure execution time
    local start_time
    # Record terminal state before running task
    start_time=$(date +%s)
    :

    # Execute with timeout
    local exit_status=0
    local log_file
    create_log_file "$name"
    log_file="$LOG_FILE"

    # Bash string-op instead of $(dirname) subshell (called on every task execution)
    # config_dir_of() löst die Sonderfälle auf (Pfad ohne Slash -> ".",
    # Pfad in "/" -> "/").  "${config_path%/*}" lieferte für "/.tasks" einen
    # leeren String — ein "cd ''" schlägt fehl und der Task lief im
    # falschen Verzeichnis.
    local config_dir
    config_dir="$(config_dir_of "$config_path")"
    # Der Timeout kann pro Task in der Beschreibung stehen ("[timeout: 120]"),
    # sonst gilt der globale Wert aus der "TIMEOUT="-Zeile.
    task_timeout_for_desc "$desc"
    local _timeout="$TASK_TIMEOUT_VALUE"
    # Ersten Token prüfen (Schutz vor kaputten Kommandos).
    # Env-Zuweisungen ("FOO=bar cmd") sind gültig — der geprüfte Token ist dann
    # das Kommando, nicht die Zuweisung.  Variablen ("$CMD") sind ebenfalls
    # gültig: der Wert wird erst zur Laufzeit aufgelöst, `command -v` kann
    # ihn nicht kennen.
    local first_token="${cmd%% *}"
    if [[ "$first_token" == *=* ]]; then
        # "FOO=bar cmd ..." → skip the assignment and check the command
        local _rest="${cmd#* }"
        if [[ "$_rest" == *'"'* || "$_rest" == *"'"* ]]; then
            # Der Wert der Zuweisung darf Leerzeichen und Anführungszeichen
            # enthalten ("FOO=\"a b\" cmd") — dann ist das Kommando nicht
            # zuverlässig zerlegbar und wird nicht geprüft (sonst wurde der
            # Task fälschlich als "Invalid task command" abgelehnt).
            first_token=""
        else
            first_token="${_rest%% *}"
        fi
    fi
    if [ -n "$first_token" ] && [[ "$first_token" != */* ]] && [[ "$first_token" != \$* ]] \
       && ! command -v "$first_token" >/dev/null 2>&1; then
        echo -e "\n${COLOR_ERR}Invalid task command: '$first_token' — skipping execution.${COLOR_RESET}"
        exit_status=127
    else
        # Script-String einmal definieren – shared zwischen timeout- und fallback-Pfad
        # shellcheck disable=SC2016
        local _exec_body='
            trap - INT
            trap - PIPE
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            _run_env_guard
            eval "$RUN_CMD $RUN_ARGS"
        '
        local _exec_script="$RUN_ENV_GUARD_SCRIPT$_exec_body"
        # `trap ':' INT` keeps the menu alive while Ctrl+C reaches the task:
        # a *trapped* signal is reset to its default disposition in the child,
        # while `trap '' INT` (ignore) would be inherited by the task and make
        # it impossible to stop — the terminal had to be closed instead.
        # The errexit state is restored afterwards — the interactive loop runs
        # with `set +e` and must not be switched to strict mode by a task.
        local _errexit_was=0
        case "$-" in *e*) _errexit_was=1 ;; esac
        set +e
        trap ':' INT
        run_task_streamed "$_exec_script" "$log_file" "$_timeout" \
            env \
            RUN_MODE="$active_mode" \
            RUN_DIR="$config_dir" \
            RUN_CMD="$cmd" \
            RUN_ARGS="${args[*]:-}" \
            bash -c "$_exec_script"
        exit_status="$TASK_EXIT_STATUS"
        [ "$_errexit_was" -eq 1 ] && set -e
        # Restore the menu's Ctrl+C handler now that the child has finished
        if [ "${is_interactive:-0}" -eq 1 ]; then
            trap 'restore_term; cleanup_wrapper; exit 130' INT
        else
            trap handle_interrupt INT TERM
        fi
    fi

    local end_time
    end_time=$(date +%s)
    task_execution_time=$((end_time - start_time))

    if [ "$exit_status" -eq 0 ]; then
        echo -e "\n${COLOR_SEL}✔ $(msg task_success)${COLOR_RESET}"
    elif [ "$exit_status" -eq 130 ]; then
        echo -e "\n${COLOR_WARN}⚡ Abgebrochen (Ctrl+C)${COLOR_RESET}"
    elif [ "$exit_status" -eq 124 ]; then
        echo -e "\n${COLOR_ERR}$(msg task_failed) (timeout ${_timeout}s).${COLOR_RESET}"
    else
        echo -e "\n${COLOR_ERR}$(msg task_failed) (exit $exit_status).${COLOR_RESET}"
    fi

    # Show execution time
    echo -e "${COLOR_DIM}⏱ ${task_execution_time}s${COLOR_RESET}"

    # Log to history
    add_to_history "$name" "$exit_status" "$task_execution_time"

    echo -e "${COLOR_DIM}Log: $log_file${COLOR_RESET}"

    # Invalidate menu cache after task execution (config may have changed)
    if command -v invalidate_menu_cache >/dev/null 2>&1; then
        invalidate_menu_cache
    else
        last_config_stamp=""
        _menu_cache_key=""
    fi

    # Interactive cleanup and keypress prompt — skipped in CLI mode and in
    # quiet mode (a background process must not reset the terminal).
    if [ "$_quiet" -eq 0 ] && [ "${cli_mode:-0}" -eq 0 ]; then
        # Reset terminal state to clean state after task execution
        # This prevents issues with arrow keys and terminal modes.
        # Immediately re-disable echo after sane so arrow keys pressed between the
        # log line and "Taste drücken..." are not echoed as [A / [B garbage.
        stty sane 2>/dev/null || true
        stty -echo 2>/dev/null || true
        tput cnorm 2>/dev/null || true
        # Drain any bytes the task may have left in stdin (e.g. arrow-key sequences
        # typed during/after task execution) before the "press key" prompt.
        drain_stdin
        echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
    fi
    return "$exit_status"
}

# Runs a task without any terminal interaction: no preview, no screen clear,
# no terminal reset and no "press any key" prompt.
#
# Used for tasks that run in the background (parallel dependencies) — a
# background process must not touch the terminal of the menu.  The prompt
# alone deadlocked the menu: the dependency waited for a key that the
# parent process was waiting for.
execute_task_quiet() {
    local _prev_quiet="${TASK_QUIET:-0}"
    local _rc=0
    TASK_QUIET=1
    execute_task "$@" || _rc=$?
    TASK_QUIET="$_prev_quiet"
    return "$_rc"
}

# ==============================================================================
#  CLI MODE (non-interactive --list / --run)
# ==============================================================================

# shellcheck disable=SC2034
_cli_matches=()   # populated by cli_match_tasks(); array of matching indices

cli_match_tasks() {
    local query="$1"
    _cli_matches=()
    if [ ${#menu_options[@]} -eq 0 ]; then
        _build_all_tasks
        menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    fi
    local total=${#menu_options[@]}

    # Numeric query: direct 1-based index lookup
    if [[ "$query" =~ ^[0-9]+$ ]]; then
        # "10#" erzwingt die Basis 10: "08" ist sonst eine ungültige
        # Oktalzahl ("value too great for base") — die Rechnung bricht ab
        # und der Task wird nicht ausgeführt.
        local idx=$(( 10#$query - 1 ))
        if [ "$idx" -lt 0 ] || [ "$idx" -ge "$total" ]; then
            echo "Task number $query out of range (1–$total)" >&2
            return 1
        fi
        _cli_matches=("$idx")
        return 0
    fi

    local i _lvl _name _cmd _desc
    local _nocase_was=0
    shopt -q nocasematch && _nocase_was=1
    shopt -s nocasematch

    # Pass 1: exact name match (case-insensitive full string)
    for (( i=0; i<total; i++ )); do
        split_task_line "${menu_options[$i]}"
        [[ "$_f_name" == "$query" ]] && _cli_matches+=("$i")
    done
    [ "${#_cli_matches[@]}" -gt 0 ] && { [ "$_nocase_was" -eq 0 ] && shopt -u nocasematch; return 0; }

    # Pass 2: substring match (case-insensitive)
    for (( i=0; i<total; i++ )); do
        split_task_line "${menu_options[$i]}"
        [[ "$_f_name" == *"$query"* ]] && _cli_matches+=("$i")
    done

    [ "$_nocase_was" -eq 0 ] && shopt -u nocasematch

    if [ "${#_cli_matches[@]}" -eq 0 ]; then
        echo "No task found matching '$query'" >&2
        return 1
    fi
    return 0
}

cli_run_task() {
    local query="$1"
    if [ ${#menu_options[@]} -eq 0 ]; then
        _build_all_tasks
        menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    fi
    local total=${#menu_options[@]}

    if [ "$total" -eq 0 ]; then
        echo "No tasks found." >&2
        return 1
    fi

    if ! cli_match_tasks "$query"; then
        return 1
    fi

    local match_count=${#_cli_matches[@]}
    local chosen_idx=""

    if [ "$match_count" -eq 1 ]; then
        chosen_idx="${_cli_matches[0]}"
    else
        # Disambiguation: print matches, read the selection.
        # Two-digit selection: the prompt promises "Select [1-N]" — with
        # only single digits accepted the entries 10+ were unreachable and
        # the loop spun forever on an invalid key.
        echo "Multiple matches for \"$query\":"
        local j
        for (( j=0; j<match_count; j++ )); do
            split_task_line "${menu_options[${_cli_matches[$j]}]}"
            printf "  %d)  %s\n" "$(( j + 1 ))" "$_f_name"
        done
        echo ""
        printf "Select [1-%d] or q to cancel: " "$match_count"

        local key
        while true; do
            if [ -t 0 ]; then
                stty -icanon min 1 time 0 2>/dev/null || true
                key=$(dd bs=1 count=1 2>/dev/null)
                stty sane 2>/dev/null || true
                # A closed stdin would spin this loop forever
                [ -z "$key" ] && { echo ""; echo "Cancelled."; return 0; }
            else
                # No TTY (pipe/SSH): read a whole line
                IFS= read -r key || { echo ""; echo "Cancelled."; return 0; }
            fi
            key="${key%$'\r'}"
            case "$key" in
                q|Q|$'\x1b')
                    echo ""
                    echo "Cancelled."
                    return 0
                    ;;
                ''|*[!0-9]*)
                    echo "Invalid selection. Try again."
                    continue
                    ;;
            esac
            # Two-digit selection: with more than nine matches the entries
            # 10+ were displayed but could not be selected.
            if [ -t 0 ] && [ "${#key}" -eq 1 ] && [ "$match_count" -gt 9 ] && [ "$key" != "0" ]; then
                local _next
                # 1 s — long enough to type a second digit
                _next=$(read_key_optional 10)
                if [ -n "$_next" ] && [[ "$_next" =~ ^[0-9]$ ]]; then
                    key="${key}${_next}"
                fi
            fi
            # "10#" forces the decimal base (a leading zero would be octal)
            local _sel=$(( 10#$key - 1 ))
            if [ "$_sel" -ge 0 ] && [ "$_sel" -lt "$match_count" ]; then
                echo "$key"
                chosen_idx="${_cli_matches[$_sel]}"
                break
            fi
            echo "Invalid selection. Try again."
        done
    fi

    local _lvl _name _cmd _desc
    split_task_line "${menu_options[$chosen_idx]}"
    execute_task "$_f_cmd" "$_f_name" "$_f_desc"
    return $?
}

cli_list_tasks() {
    if [ ${#menu_options[@]} -eq 0 ]; then
        _build_all_tasks
        menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    fi
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        echo "No tasks found."
        return 0
    fi
    # 2>/dev/null: a closed stdout (`run --list | head`) must not produce a
    # "write error: Broken pipe" message from the bash builtin.
    echo "Tasks ($total)" 2>/dev/null || return 0
    local i
    for (( i=0; i<total; i++ )); do
        split_task_line "${menu_options[$i]}"
        local num=$(( i + 1 ))
        printf "  %2d)  %-22s  %s\n" "$num" "${_f_name:0:22}" "$_f_desc" 2>/dev/null || break
    done
    return 0
}

# ==============================================================================
#  UTILITY HELPERS
# ==============================================================================

load_global_vars() {
    if [ ! -f "$RUN_VARS_FILE" ]; then
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) continue ;;
        esac
        local key="${line%%=*}"
        local value="${line#*=}"
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            # Sicherheits-Gate: einige Variablen dürfen nicht gesetzt werden.
            #   PATH/CDPATH  — zerstören die Kommandosuche (der Runner fand
            #                   danach keine Tasks mehr: "No tasks found")
            #   IFS          — ändern die Wortzerlegung im Runner selbst
            #   BASH_ENV/ENV — führen zu Codeausführung in jedem Kind-Bash
            #   LD_*/DYLD_*  — injizieren Code in die Task-Prozesse
            #   SHELLOPTS/…  — sind in bash readonly (ein "export" wäre ein
            #                   Fehler und würde das Skript abbrechen)
            case "$key" in
                PATH|CDPATH|GLOBIGNORE|IFS|\
                BASH_ENV|ENV|SHELLOPTS|BASHOPTS|PROMPT_COMMAND|PS4|\
                LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|\
                DYLD_INSERT_LIBRARIES|DYLD_LIBRARY_PATH|DYLD_FRAMEWORK_PATH)
                    continue
                    ;;
            esac
            # Der Runner deklariert eigene readonly-Konstanten (VERSION,
            # RUN_LOG_DIR, RUN_TASK_TIMEOUT, …).  Ein "export" auf einen der
            # readonly-Namen bricht unter "set -e" das GESAMTE Skript ab
            # (einzelne "readonly variable"-Zeile, kein Menü) — und der
            # EXIT-Trap maskierte diesen Abbruch sogar als Erfolg (Exit 0).
            # Readonly-Namen werden deshalb übersprungen.
            if declare -p "$key" 2>/dev/null | grep -qE 'declare -[A-Za-z]*r' ; then
                continue
            fi
            export "$key"="$value"
        fi
    done < "$RUN_VARS_FILE"
}

load_task_vars() {
    # The errexit/pipefail state is saved and restored instead of being
    # forced on: the interactive menu loop runs with "set +e" and a blind
    # "set -e" at the end of this function would end the whole menu.
    save_shell_opts
    set +e +o pipefail  # Disable errexit and pipefail for regex operations
    if [ ! -f "$config_path" ]; then
        restore_shell_opts
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^VAR_[A-Za-z0-9_]+= ]] || continue
        local key="${line%%=*}"
        local value="${line#*=}"
        export "$key"="$value" 2>/dev/null || true
    done < "$config_path"
    restore_shell_opts  # Restore errexit and pipefail
}

# Counter for the log file names — makes the name unique per task.
_LOG_SEQ=0

# Path of the log file created by the last create_log_file() call.
#
# The function sets a global instead of printing the path: the counter is
# incremented inside the function, and a command substitution would run the
# function in a subshell — the increment was lost and every log file got the
# same sequence number.  Two tasks with the same name (or the same task
# twice in the same second) then shared one log file and their output was
# interleaved.
LOG_FILE=""

create_log_file() {
    local task_name="$1"
    mkdir -p "$RUN_LOG_DIR" 2>/dev/null || true
    local safe_name
    safe_name=$(sanitize_filename "$task_name")
    [ -z "$safe_name" ] && safe_name="task"
    # The timestamp has a resolution of one second: two tasks with the same
    # name (parallel execution) would share one log file and their output
    # would interleave.  The PID and the counter make the name unique.
    _LOG_SEQ=$(( _LOG_SEQ + 1 ))
    LOG_FILE="$RUN_LOG_DIR/$(date '+%Y-%m-%d_%H-%M-%S')_$$_${_LOG_SEQ}_${safe_name}.log"
    return 0
}

# Determines the timeout of a task.
#
# A task can carry its own timeout in the description ("[timeout: 120]");
# otherwise the global value from the "TIMEOUT=" line applies.  An invalid
# value falls back to the global one.
#
# Result: TASK_TIMEOUT_VALUE
TASK_TIMEOUT_VALUE=""
task_timeout_for_desc() {
    local desc="${1:-}"
    TASK_TIMEOUT_VALUE="$task_timeout"
    # "[:space:]*": die Doku schreibt "[timeout: 120]" mit einem Leerzeichen
    # nach dem Doppelpunkt.
    if [[ "$desc" =~ \[timeout:[[:space:]]*([0-9]+)\] ]]; then
        local _t="${BASH_REMATCH[1]}"
        if [ "$_t" -gt 0 ]; then
            TASK_TIMEOUT_VALUE="$_t"
        fi
    fi
    return 0
}


extract_field_from_grep() {
    # Extract field from grep result
    # Usage: extract_field_from_grep "^TIMEOUT=" "=" 2
    local pattern="$1"
    local delimiter="$2"
    local field_idx="$3"
    if [ -f "$config_path" ]; then
        awk -F"$delimiter" -v pat="$pattern" -v idx="$field_idx" '$0 ~ pat {val=$idx; gsub(/^[ \t]+|[ \t]+$/, "", val); print val; exit}' "$config_path" 2>/dev/null || true
    fi
}

# ==============================================================================
#  UI RENDERING & KEYBOARD INPUT HANDLING
# ==============================================================================

# Terminal capabilities are initialized in 03-terminal.sh via init_terminal_capabilities

# Cache for the padded name fields of the menu (index → padded text).
# Measuring the display width of every entry is expensive, and the fields
# only change when the menu or the terminal width changes.
declare -a _name_field_cache=()
_name_field_cache_key=""

# Result of the last _build_menu_options() call and its cache copy.
#
# Both are arrays: the cache only works when the menu is built in the
# current shell — a process substitution would discard the cache variables
# when the subshell exits.
MENU_RESULT_ARRAY=()
_cached_menu_array=()

# Cached header line (see draw_menu)
_HEADER_CACHE_KEY=""
_HEADER_CACHE_TEXT=""

# Change stamp of the whole config set (config + overlays).
#
# The overlays (.tasks.local, .tasks.dev, .tasks.<profile>.local) are part
# of the menu — a change in one of them must invalidate the cache, otherwise
# new tasks stay invisible until the next restart.
_menu_config_stamp() {
    get_files_stamp "$config_path" "${task_config_files[@]+"${task_config_files[@]}"}"
}

# Verwirft den Menü-Cache.
#
# Nötig, wenn sich die Config geändert hat, ohne dass der Änderungs-Stempel
# (mtime:size) das erkennen kann: eine Bearbeitung mit gleicher Größe in
# derselben Sekunde blieb sonst unsichtbar.
invalidate_menu_cache() {
    last_config_stamp=""
    _menu_cache_key=""
    _menu_cache_config_path=""
    return 0
}

# Redraw counter — used to poll the terminal width (not every SSH client
# sends SIGWINCH when the window is resized).
_redraw_counter=0

# Setzt _layout_rows/_layout_cols direkt — kein Subshell-Overhead bei jedem Redraw
calculate_layout() {
    local total="$1"
    local term_width="${TPUT_COLS:-80}"
    local min_col_width="${COLS_MIN_WIDTH:-30}"
    local max_cols="${COLS_MAX:-4}"
    local min_cols="${COLS_MIN:-1}"

    # Derive column count from terminal width
    local cols=$(( term_width / min_col_width ))

    # Apply COLS_MAX (0 = unlimited)
    if [ "$max_cols" -gt 0 ] && [ "$cols" -gt "$max_cols" ]; then
        cols="$max_cols"
    fi

    # Don't use more columns than makes sense (at least 2 items per column)
    if [ "$total" -gt 0 ]; then
        local max_useful=$(( (total + 1) / 2 ))
        [ "$cols" -gt "$max_useful" ] && cols="$max_useful"
    fi

    # Apply minimum column count
    [ "$cols" -lt "$min_cols" ] && cols="$min_cols"
    [ "$cols" -lt 1 ] && cols=1

    local rows=$(( (total + cols - 1) / cols ))
    [ "$rows" -lt 1 ] && rows=1

    _layout_rows=$rows
    _layout_cols=$cols
}

show_help_panel() {
    clear
    # Box width adapts to the terminal — a fixed 64 column frame wraps on
    # narrow terminals and breaks the layout.
    local _w=$(( ${TPUT_COLS:-80} - 2 ))
    [ "$_w" -gt 64 ] && _w=64
    [ "$_w" -lt 30 ] && _w=30

    local _bar="" _i
    for (( _i=0; _i<_w; _i++ )); do _bar+='═'; done

    local _title="SHELL MENU RUNNER v${VERSION}"
    local _inner=$(( _w - 2 ))
    local _tpad=$(( (_inner - ${#_title}) / 2 ))
    [ "$_tpad" -lt 0 ] && _tpad=0
    local _lead="" _trail=""
    printf -v _lead '%*s' "$_tpad" ''
    printf -v _trail '%*s' "$(( _inner - ${#_title} - _tpad ))" ''

    echo -e "${COLOR_HEAD}${_bar}${COLOR_RESET}"
    echo -e "${COLOR_HEAD}║${_lead}${_title}${_trail}║${COLOR_RESET}"
    echo -e "${COLOR_HEAD}${_bar}${COLOR_RESET}"
    echo ""

    # The help lines are cut to the terminal width so they cannot wrap.
    # Section headers (no indent, own line) are printed coloured, the
    # indented entries are cut to the available width.
    local _line
    while IFS= read -r _line; do
        if [ -z "$_line" ]; then
            echo ""
        elif [ "${_line%%:*}" != "$_line" ] && [ "${_line:0:2}" != "  " ]; then
            echo -e "${COLOR_SEL}${_line}${COLOR_RESET}"
        else
            fit_to_width "$_line" "$_w"
            echo "${FIT_TEXT}"
        fi
    done << EOF
Navigation:
  ↑/↓ or j/k      Navigate tasks
  ←/→ or h/l      Multi-column navigation
  [Enter]         Execute selected task
  [1-9]           Quick execute (hotkey)
  [Space]         Multi-select (execute multiple)
  [ESC] or q      Exit / Go back
EOF
    if [ "${RUN_MINIMAL:-0}" != "1" ]; then
        while IFS= read -r _line; do
            if [ -z "$_line" ]; then
                echo ""
            elif [ "${_line%%:*}" != "$_line" ] && [ "${_line:0:2}" != "  " ]; then
                echo -e "${COLOR_SEL}${_line}${COLOR_RESET}"
            else
                fit_to_width "$_line" "$_w"
                echo "${FIT_TEXT}"
            fi
        done << EOF

Features:
  /               Search/filter tasks
  #               Filter by tags
  g               Toggle local/global config
  p               Switch profile
  s               Settings menu
  e               Edit config
  f               File browser
  *               Toggle favorite
  c               Copy command to clipboard
  r               Show favorite tasks
  R               Show recent tasks
  L               Show log files
  !               Show history
  a               Alias editor
  ?               This help

Profiles:
  run [profile]   Load specific profile
  run --list      List all tasks
  run --run <q>   Execute a task non-interactively
  run --init      Initialize new .tasks config
EOF
    else
        # Der Minimal-Build schaltet die erweiterten Tasten ab — die
        # verbleibenden werden hier trotzdem aufgelistet, damit die Hilfe
        # nicht mehr Tasten verschweigt als es gibt.
        while IFS= read -r _line; do
            if [ -z "$_line" ]; then
                echo ""
            elif [ "${_line%%:*}" != "$_line" ] && [ "${_line:0:2}" != "  " ]; then
                echo -e "${COLOR_SEL}${_line}${COLOR_RESET}"
            else
                fit_to_width "$_line" "$_w"
                echo "${FIT_TEXT}"
            fi
        done << EOF

Features (minimal build):
  g               Toggle local/global config
  p               Switch profile
  s               Settings menu
  c               Copy command to clipboard
  ?               This help

Profiles:
  run [profile]   Load specific profile
  run --list      List all tasks
  run --run <q>   Execute a task non-interactively
  run --init      Initialize new .tasks config
EOF
    fi

    echo ""
    echo -e "${COLOR_DIM}Press any key to continue...${COLOR_RESET}"
    consume_keypress
}

get_menu_options() {
    _build_menu_options
    if [ ${#MENU_RESULT_ARRAY[@]} -gt 0 ]; then
        printf "%s\n" "${MENU_RESULT_ARRAY[@]}"
    fi
    return 0
}

# Normalizes selected_index after every key press: the selection must stay
# inside the current menu grid.
#
# An empty menu (cnt == 0) must reset to 0 — the wrap formula "(cnt - 1)"
# would otherwise leave the index stuck at -1, and the next "*" / "c" / " "
# key would hit "menu_options[-1]": on Bash 3.2 (macOS default) that is a
# fatal "bad array subscript" that killed the whole runner.
clamp_selected_index() {
    local _cnt=${#menu_options[@]}
    if [ "$_cnt" -eq 0 ]; then
        selected_index=0
    elif [ "$selected_index" -lt 0 ]; then
        selected_index=$((_cnt - 1))
    elif [ "$selected_index" -ge "$_cnt" ]; then
        selected_index=0
    fi
    return 0
}

# Builds the menu list for the current level/filters and stores it in
# MENU_RESULT_ARRAY.
#
# The result is returned in a global array instead of on stdout: a caller
# that reads the result via a process substitution runs in a subshell, and
# every cache variable set there is lost when it exits — the cache never hit
# and the whole config was re-read and re-parsed for every menu rebuild.
_build_menu_options() {
    local current_stack_key=""
    if [ "$current_level" -gt 0 ]; then
        current_stack_key="${history_name_stack[*]}"
    fi

    # Cache check for performance.  The key contains every input the result
    # depends on (level, breadcrumb, filters) — the change stamp of the
    # config files detects modifications.  The config path is checked
    # separately: two configs with the same stamp (mtime:size) would
    # otherwise be indistinguishable and the menu would keep showing the
    # tasks of the previous config after a switch ("g" / "p").
    local _cache_key="${current_level}|${current_stack_key}|${filter_query}|${tag_filter}"
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ ${#_cached_menu_array[@]} -gt 0 ] \
       && [ "$_cache_key" = "$_menu_cache_key" ] \
       && [ "$config_path" = "$_menu_cache_config_path" ]; then
        local _stamp
        _stamp=$(_menu_config_stamp)
        if [ "$_stamp" = "$last_config_stamp" ]; then
            MENU_RESULT_ARRAY=("${_cached_menu_array[@]}")
            return 0
        fi
    fi

    # Build menu options
    local search_pattern=""
    local tag_pattern=""

    if [ -n "$filter_query" ]; then
        # Kein tr-Fork: die Gross-/Kleinschreibung wird unten über
        # "shopt -s nocasematch" erledigt (der Vergleich selbst ist literal).
        search_pattern="$filter_query"
    fi

    if [ -n "$tag_filter" ]; then
        tag_pattern="$tag_filter"
    fi

    local -a _result_arr=()
    local -a active_parents=()
    local k i
    local _haystack=""

    # nocasematch makes the filter comparison case-insensitive — that replaces
    # a `tr` fork per config line.  The previous shell option is restored below.
    local _nocase_was=0
    shopt -q nocasematch && _nocase_was=1
    [ -n "$search_pattern" ] && shopt -s nocasematch

    # Process substitution: Config-Inhalt direkt streamen — kein all_output-String-Kopie im Speicher
    while IFS= read -r line || [ -n "$line" ]; do
        # Tolerate CRLF line endings — a trailing \r corrupts the box layout
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        is_meta_task_line "$line" && continue

        split_task_line "$line"
        level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
        [ -z "$name" ] && continue
        # The level must be a number (a case pattern is much cheaper than a
        # regex match)
        case "$level" in
            ''|*[!0-9]*) continue ;;
        esac

        # Update active_parents tracker for positional submenus.
        # Only the levels up to current_level are relevant — resetting all 20
        # levels per config line cost 40,000 assignments for 2000 tasks.
        for ((k = level; k <= current_level; k++)); do
            active_parents[k]=""
        done
        if [ "$cmd" = "SUB" ]; then
            active_parents[level]="$name"
        fi

        # Level filtering
        if [ "$level" -ne "$current_level" ]; then
            continue
        fi

        if [ "$current_level" -gt 0 ]; then
            local parent_match=1
            for ((i = 0; i < current_level; i++)); do
                if [ "${active_parents[i]:-}" != "${history_name_stack[$((i + 1))]:-}" ]; then
                    parent_match=0
                    break
                fi
            done
            [ "$parent_match" -eq 0 ] && continue
        fi

        # Search filtering — literal, case-insensitive substring match.
        # A regex would break on characters like "(" (the menu would silently
        # become empty) and "Build." would match "BuildX".
        if [ -n "$search_pattern" ]; then
            _haystack="$name $desc"
            [[ "$_haystack" != *"$search_pattern"* ]] && continue
        fi

        # Tag filtering
        if [ -n "$tag_pattern" ]; then
            has_tag "$desc" "$tag_pattern" || continue
        fi

        # Append to result buffer (do not echo here to avoid recursion)
        _result_arr+=("${level}|${name}|${cmd}|${desc}")
    done < <(merge_configs)

    # Restore the previous nocasematch state
    [ "$_nocase_was" -eq 0 ] && shopt -u nocasematch

    # Cache result (store the parsed list, avoid re-parsing the config)
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -f "$config_path" ]; then
        _cached_menu_array=("${_result_arr[@]+"${_result_arr[@]}"}")
        _menu_cache_key="$_cache_key"
        _menu_cache_config_path="$config_path"
        last_config_stamp=$(_menu_config_stamp)
    fi

    MENU_RESULT_ARRAY=("${_result_arr[@]+"${_result_arr[@]}"}")
    return 0
}

draw_menu() {
    if [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_CUP" ]; then
        echo -ne "$TPUT_CUP"
    else
        clear
    fi
    hide_cursor
    local _EL='\033[K'   # erase-to-EOL — prevents ghost text from shorter redraws
    local term_width="${TPUT_COLS:-80}"

    # Not every SSH client delivers SIGWINCH on a resize — poll the width from
    # time to time so the menu still adapts (one fork every 20 redraws).
    _redraw_counter=$(( _redraw_counter + 1 ))
    if [ "$_redraw_counter" -ge 20 ]; then
        _redraw_counter=0
        local _new_cols
        _new_cols=$(tput cols 2>/dev/null || true)
        if [ -n "$_new_cols" ] && [ "$_new_cols" != "$TPUT_COLS" ]; then
            TPUT_COLS="$_new_cols"
            _LAST_COL_WIDTH=0
        fi
        term_width="${TPUT_COLS:-80}"
    fi

    # ── Header ───────────────────────────────────────────────────────
    local mode_indicator="[${active_mode}]"
    if [ "$active_mode" = "global" ] && [ -f "$config_path" ]; then
        local _bn="${config_path##*/}"
        local _pname="${_bn##.tasks}"; _pname="${_pname#.}"
        [ -n "$_pname" ] && mode_indicator="[${_pname}]"
    fi
    # The header text only changes with the version, the mode and the
    # terminal width — the fitted result is cached (the UTF-8 decoder
    # needs ~4 ms for the box-drawing characters).
    local _header_text="════ Shell Menu Runner ${VERSION} ${mode_indicator} ════"
    local _header_key="${_header_text}|${term_width}"
    if [ "${_HEADER_CACHE_KEY:-}" != "$_header_key" ]; then
        fit_to_width "$_header_text" "$term_width"
        _HEADER_CACHE_TEXT="$FIT_TEXT"
        _HEADER_CACHE_KEY="$_header_key"
    fi
    FIT_TEXT="$_HEADER_CACHE_TEXT"
    echo -e "${COLOR_HEAD}${FIT_TEXT}${COLOR_RESET}${_EL}"

    # Context line (git branch, hostname, env) — empty string = no line
    if [ -n "${_CTX_LINE:-}" ]; then
        display_width "${_CTX_LINE_PLAIN:-$_CTX_LINE}"
        if [ "$DISPLAY_WIDTH" -le "$term_width" ]; then
            echo -e "${_CTX_LINE}${_EL}"
        else
            fit_to_width "${_CTX_LINE_PLAIN:-$_CTX_LINE}" "$term_width"
            echo -e "${COLOR_DIM}${FIT_TEXT}${COLOR_RESET}${_EL}"
        fi
    fi

    if [ "$current_level" -gt 0 ]; then
        local _bc=""
        for _bname in "${history_name_stack[@]}"; do _bc="${_bc}${_bname} > "; done
        fit_to_width "${_bc%> }" "$term_width"
        echo -e "${COLOR_DIM}${FIT_TEXT}${COLOR_RESET}${_EL}"
    fi
    if [ -n "$filter_query" ]; then
        fit_to_width "📎 Filter: $filter_query" "$term_width"
        echo -e "${COLOR_INFO}${FIT_TEXT}${COLOR_RESET}${_EL}"
    fi
    if [ -n "$tag_filter" ]; then
        fit_to_width "🏷  Tag: $tag_filter" "$term_width"
        echo -e "${COLOR_INFO}${FIT_TEXT}${COLOR_RESET}${_EL}"
    fi
    echo -e "${_EL}"

    # ── Empty state ──────────────────────────────────────────────────
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        fit_to_width "No tasks found. Press 'e' to edit config or '?' for help." "$term_width"
        echo -e "${COLOR_DIM}${FIT_TEXT}${COLOR_RESET}${_EL}"
        [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
        return 0
    fi

    # ── Layout ───────────────────────────────────────────────────────
    calculate_layout "$total"
    local rows=$_layout_rows cols=$_layout_cols
    local col_width=$(( term_width / cols ))
    local inner=$(( col_width - 4 ))
    [ "$inner" -lt 1 ] && inner=1
    local name_max=$(( inner - 4 ))
    [ "$name_max" -lt 1 ] && name_max=1

    # The cached name fields are only valid for the current column width
    if [ "$_name_field_cache_key" != "$name_max" ]; then
        _name_field_cache=()
        _name_field_cache_key="$name_max"
    fi

    # Rebuild border strings when col_width changed (e.g. terminal resize)
    if [ "$col_width" -ne "${_LAST_COL_WIDTH:-0}" ]; then
        build_border_strings "$col_width"
    fi

    # ── Viewport ─────────────────────────────────────────────────────
    # Only the rows that fit on the screen are drawn.  Without the viewport a
    # config with 2000 tasks produced 3000 lines / 326 KB per redraw — the
    # menu flooded the terminal and every keypress cost ~200 ms.
    # The grid index (idx = r + c * rows) is unchanged, so the navigation
    # (up/down = ±1, left/right = ±rows) keeps working.
    local visible_rows="$rows"
    local first_row=0
    local _term_lines="${TPUT_LINES:-24}"
    is_uint "$_term_lines" && [ "$_term_lines" -ge 6 ] || _term_lines=24
    # Overhead: title + context + breadcrumb + filter + blank + footer
    local _chrome=9
    local _max_rows=$(( (_term_lines - _chrome) / 3 ))
    [ "$_max_rows" -lt 1 ] && _max_rows=1
    if [ "$rows" -gt "$_max_rows" ]; then
        visible_rows="$_max_rows"
        # Keep the selected entry visible: the row of an entry is idx % rows
        local _sel_row=$(( selected_index % rows ))
        first_row=$(( _sel_row - visible_rows / 2 ))
        [ "$first_row" -lt 0 ] && first_row=0
        [ "$first_row" -gt $(( rows - visible_rows )) ] && first_row=$(( rows - visible_rows ))
    fi

    # ── Grid rendering (3 lines per item, separate boxes) ───────────
    local r c idx
    local gap="  "   # 2-space gap between columns; added BEFORE column (not after)

    for (( r=first_row; r<first_row + visible_rows; r++ )); do
        local top_line="" content_line="" bot_line=""
        local first_in_row=1

        for (( c=0; c<cols; c++ )); do
            idx=$(( r + c * rows ))
            [ "$idx" -ge "$total" ] && continue

            local border_color="$COLOR_DIM"
            [ "$idx" -eq "$selected_index" ] && border_color="$COLOR_SEL"

            if [ "$first_in_row" -eq 0 ]; then
                top_line+="$gap"
                content_line+="$gap"
                bot_line+="$gap"
            fi
            first_in_row=0

            # Hotkey number (column-first, left side) — revert to top border only
            top_line+="${border_color}${_BORDER_TOP}${COLOR_RESET}"
            bot_line+="${border_color}${_BORDER_BOT}${COLOR_RESET}"

            # Content
            # shellcheck disable=SC2034
            split_task_line "${menu_options[$idx]}"
            _lvl="$_f_level"; _name="$_f_name"; _cmd="$_f_cmd"; _desc="$_f_desc"

            # Hotkey prefix (2 chars) + marker (1 char) = 3 chars, same total as before.
            # Keeping them separate avoids "1►" overlap: shows "1 ►" instead.
            local _item_num=$(( idx + 1 ))
            local _hotkey_pfx="  "
            [ "$_item_num" -le 9 ] && _hotkey_pfx="${COLOR_DIM}${_item_num}${COLOR_RESET} "

            local marker=" "
            local text_color="$COLOR_DIM"
            if [ "$idx" -eq "$selected_index" ]; then
                marker="►"; text_color="$COLOR_BOLD"
            fi
            if [ -n "${multi_select_map[$idx]:-}" ]; then
                marker="☑"; text_color="$COLOR_INFO"
            fi

            # Name field: exactly $name_max terminal columns.
            # fit_to_width counts wide characters (CJK/emoji = 2 columns) and
            # truncates without splitting a UTF-8 character — otherwise the
            # content line overflows the box border and the terminal wraps.
            #
            # The result is cached per menu index: the field only changes when
            # the menu or the terminal width changes, and measuring the width
            # of every entry on every redraw is far too slow.
            local _padded
            if [ -n "${_name_field_cache[idx]:+set}" ]; then
                _padded="${_name_field_cache[idx]}"
            else
                fit_to_width "$_name" "$name_max"
                _padded="$FIT_TEXT"
                _name_field_cache[idx]="$FIT_TEXT"
            fi

            content_line+="${border_color}│${COLOR_RESET}${_hotkey_pfx}${text_color}${marker}${_padded}${COLOR_RESET} ${border_color}│${COLOR_RESET}"
        done

        echo -e "${top_line}${_EL}"
        echo -e "${content_line}${_EL}"
        echo -e "${bot_line}${_EL}"
    done

    # ── Footer hints (width-adaptive to prevent wrapping) ───────────
    echo -e "${_EL}"
    local _nav_lr=""; [ "$cols" -gt 1 ] && _nav_lr=" ←→ h/l"
    local _hint_full="[↑↓${_nav_lr}] Navigate | [Enter] Execute | [/] Search | [Space] Multi | [?] Help"
    local _hint_mid="[↑↓←→] Nav | [Enter] Run | [/] Search | [?] Help"
    local _hint_min="[↑↓←→] [Enter] [/] [?]"
    # Pick the most detailed hint that still fits into the terminal width.
    # The hint texts are constant (two variants, depending on the column
    # count) — their column width is measured once and then cached.
    if [ "$_HINT_WIDTHS_KEY" != "$_hint_full" ]; then
        display_width "$_hint_mid";  _HINT_MID_WIDTH="$DISPLAY_WIDTH"
        display_width "$_hint_full"; _HINT_FULL_WIDTH="$DISPLAY_WIDTH"
        _HINT_WIDTHS_KEY="$_hint_full"
    fi
    local _hint="$_hint_min"
    [ "$_HINT_MID_WIDTH" -le "$term_width" ] && _hint="$_hint_mid"
    [ "$_HINT_FULL_WIDTH" -le "$term_width" ] && _hint="$_hint_full"
    # Scroll indicator — only shown when the viewport is active
    if [ "$visible_rows" -lt "$rows" ]; then
        local _pos=$(( first_row + 1 ))
        local _end=$(( first_row + visible_rows ))
        _hint="${_hint} | ${_pos}-${_end}/${rows}"
    fi
    echo -e "${COLOR_DIM}${_hint}${COLOR_RESET}${_EL}"

    [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
    return 0
}

# ==============================================================================
#  MAIN INTERACTIVE LOOP WITH KEYBOARD HANDLING
# ==============================================================================

# Prints the task list — used in the non-interactive mode (no TTY) where no
# menu can be drawn, e.g. `ssh host "run"`.
print_task_list() {
    local total=${#menu_options[@]}
    echo ""
    echo -e "${COLOR_HEAD}Tasks ($total)${COLOR_RESET}"
    local i
    for (( i=0; i<total; i++ )); do
        split_task_line "${menu_options[$i]}"
        printf "  %2d)  %-24s  %s\n" "$(( i + 1 ))" "$_f_name" "$_f_desc"
    done
    echo ""
    echo -e "${COLOR_DIM}Type a task number or name to execute it (q = quit):${COLOR_RESET}"
    echo ""
}

# Lädt menu_options neu und aktualisiert calculate_layout.
_reload_menu() {
    # In-process: the cache of _build_menu_options() only survives when the
    # function runs in the current shell.
    _build_menu_options
    menu_options=("${MENU_RESULT_ARRAY[@]+"${MENU_RESULT_ARRAY[@]}"}")
    calculate_layout "${#menu_options[@]}"
    # Die gepufferten Namensfelder gehören zum alten Menü → verwerfen
    _name_field_cache=()
    _name_field_cache_key=""
}

# Lädt Konfiguration + Menü neu — ersetzt das 5-Funktionen-Pattern
# parse_config_vars+load_settings+load_state+detect_config_files+load_aliases.
_reinit_menu() {
    parse_config_vars
    load_settings
    load_state
    detect_config_files
    load_aliases
    _reload_menu
}

# Führt "$@" mit wiederhergestellten Terminal-Einstellungen aus und schaltet
# danach wieder in den Raw-Mode. Ersetzt das 15× vorhandene
# restore_term; <call>; [ is_interactive ] && stty ... -Pattern.
run_with_term_paused() {
    restore_term
    "$@"
    if [ "${is_interactive:-0}" -eq 1 ]; then
        set_raw_mode
        drain_stdin  # flush any escape sequence tails from the secondary screen
    fi
}

main_interactive_loop() {
    # Disable strict error checking for the interactive loop to prevent
    # accidental exits during navigation (arithmetic 0 results, etc.)
    set +e

    # Initialize
    _reload_menu
    local num=${#menu_options[@]}
    local rows=$_layout_rows cols=$_layout_cols
    local redraw_needed=1

    # OPTIMIZATION: Set raw mode once to avoid stty overhead
    # The terminal settings live in a global snapshot (03-terminal.sh) so the
    # submenus (file browser, config editor) can restore them after an editor
    # has run.  restore_term() is defined on module level (03-terminal.sh) —
    # the INT trap of execute_task also runs outside the interactive loop.

    if [ "$is_interactive" -eq 1 ]; then
        _MENU_LOOP_ACTIVE=1
        save_terminal_state
        set_raw_mode
        trap 'restore_term; cleanup_wrapper; exit 130' INT TERM
    else
        _MENU_LOOP_ACTIVE=0
        # No TTY (SSH without -t, pipe): there is no menu to draw, so the task
        # list is printed once and the tasks are selected by number or name.
        print_task_list
    fi

    while true; do
        # Only redraw if needed (performance optimization).
        # Without a TTY the task list is printed instead of the menu.
        if [ "$redraw_needed" -eq 1 ] && [ "$is_interactive" -eq 1 ]; then
            draw_menu
            redraw_needed=0
        fi

        # ══════════════════════════════════════════════════════════════
        #  KEYBOARD INPUT HANDLING
        # ══════════════════════════════════════════════════════════════
        local key="" _rk_status=0 _read_failures=0
        if [ "$is_interactive" -eq 1 ]; then
            # Capture exit status separately: command substitution strips trailing \n,
            # so a real Enter (\n) correctly becomes "".  But if read_key_raw fails
            # (e.g. EINTR from a signal), we must NOT treat the empty result as Enter.
            key=$(read_key_raw); _rk_status=$?
            if [ "$_rk_status" -ne 0 ]; then
                # A single failed read is normal (terminal resize interrupts the
                # read) — but a permanently closed stdin would spin the loop at
                # 100% CPU and freeze the menu.  Give up after a few attempts.
                _read_failures=$(( _read_failures + 1 ))
                if [ "$_read_failures" -ge 3 ]; then
                    break
                fi
                redraw_needed=1
                continue
            fi
            _read_failures=0
        else
            # Non-interactive (SSH without -t, pipe, cron): the input is a
            # task number or a task name and is executed directly.
            read -r key || break
            [ -z "$key" ] && break
            case "$key" in
                q|Q) restore_term; exit 0 ;;
            esac
            cli_run_task "$key" || true
            continue
        fi

        # ══════════════════════════════════════════════════════════════
        #  KEY HANDLING
        # ══════════════════════════════════════════════════════════════
        # The minimal build has no advanced features (search, tags,
        # favorites, history, logs, alias editor, browser, config editor).
        local _key="$key"
        if [ "${RUN_MINIMAL:-0}" = "1" ]; then
            case "$key" in
                "/" | "#" | "*" | "r" | "R" | "L" | "!" | "a" | "A" | "e" | "E" | "f" | "F")
                    _key="__disabled__"
                    ;;
            esac
        fi
        case "$_key" in
            $'\x1b[A'|$'\x1bOA') selected_index=$((selected_index - 1)); redraw_needed=1;; # Arrow Up
            $'\x1b[B'|$'\x1bOB') selected_index=$((selected_index + 1)); redraw_needed=1;; # Arrow Down
            $'\x1b[C'|$'\x1bOC') [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows)); redraw_needed=1;; # Arrow Right
            $'\x1b[D'|$'\x1bOD') [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows)); redraw_needed=1;; # Arrow Left
            $'\x1b') # Pure ESC key
                if [ "$current_level" -gt 0 ]; then
                    current_level=$((current_level - 1))
                    history_name_stack=("${history_name_stack[@]:0:${#history_name_stack[@]}-1}")
                    selected_index=0
                    _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                    redraw_needed=1
                else
                    restore_term; clear; exit 0
                fi;;
            "k") selected_index=$((selected_index - 1)); redraw_needed=1;; # Vim up
            "j") selected_index=$((selected_index + 1)); redraw_needed=1;; # Vim down
            "h") [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows)); redraw_needed=1;; # Vim left
            "l") [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows)); redraw_needed=1;; # Vim right
            " ") # Space: Multi-select toggle
                # Guard auch für selected_index == -1 (leeres Menü + "↑"
                # lässt den Index bei -1 hängen): ohne Guard wäre
                # "multi_select_map[-1]" unter Bash 3.2 ein fataler
                # "bad array subscript".
                if [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "${#menu_options[@]}" ]; then
                    if [[ -n "${multi_select_map[$selected_index]:-}" ]]; then
                        unset 'multi_select_map[$selected_index]'
                    else
                        multi_select_map["$selected_index"]=1
                    fi
                fi
                redraw_needed=1;;
            [1-9]) # Hotkey: direct execution by column-first index (matches displayed number)
                local hotkey_idx=$((key - 1))
                if [ "$hotkey_idx" -lt "$num" ]; then
                    selected_index="$hotkey_idx"
                    split_task_line "${menu_options[$selected_index]}"
                    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                    if [ "$cmd" != "EXIT" ] && [ "$cmd" != "SUB" ] && [ "$cmd" != "BACK" ]; then
                        run_with_term_paused execute_task "$cmd" "$name" "$desc"
                    fi
                    redraw_needed=1
                fi;;
            "/") # Search
                restore_term
                interactive_search && selected_index=0
                if [ "${is_interactive:-0}" -eq 1 ]; then
                    set_raw_mode
                    drain_stdin
                fi
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "g") # Toggle local/global
                if [ "$active_mode" == "local" ]; then
                    active_mode="global"
                    config_path="$GLOBAL_CONFIG"
                elif found=$(find_local_config); then
                    active_mode="local"
                    config_path="$found"
                fi
                selected_index=0
                current_level=0
                # Die Filter gehören zur bisherigen Config: ohne das Reset
                # blieb der Tag-Filter aktiv und das neue Menü war leer
                # ("No tasks found"), ohne einen sichtbaren Grund.
                filter_query=""
                tag_filter=""
                _reinit_menu
                num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "p"|"P") # Profile selection
                restore_term
                if select_profile_menu; then
                    selected_index=0
                    current_level=0
                    history_name_stack=("Main")
                    # Siehe Taste "g": der Filter gilt der alten Config.
                    filter_query=""
                    tag_filter=""
                    _reinit_menu
                    num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                fi
                clear  # remove profile-menu artefacts before redraw
                if [ "${is_interactive:-0}" -eq 1 ]; then
                    set_raw_mode
                    drain_stdin
                fi
                redraw_needed=1;;
            "s") run_with_term_paused settings_menu; redraw_needed=1;;
            "!") run_with_term_paused show_history; redraw_needed=1;;
            "a"|"A") run_with_term_paused show_alias_editor; redraw_needed=1;;
            "?") run_with_term_paused show_help_panel; redraw_needed=1;;
            $'\r'|$'\n'|"") # ENTER: \r = raw CR, \n = LF, "" = \n stripped by $()
                set +u
                [ ${#menu_options[@]} -eq 0 ] && { set -u; continue; }

                # Multi-select execution
                if [ ${#multi_select_map[@]} -gt 0 ]; then
                    set -u
                    restore_term
                    local -a multi_keys=()
                    IFS=$'\n' read -r -d '' -a multi_keys < <(printf "%s\n" "${!multi_select_map[@]}" | sort -n && printf '\0') || true
                    # Parallel execution of the marked tasks (opt-in via
                    # RUN_PARALLEL_MULTI=1) — otherwise sequential.
                    if [ "${RUN_PARALLEL_MULTI:-0}" = "1" ] && [ "${#multi_keys[@]}" -gt 1 ]; then
                        execute_tasks_parallel
                    else
                        for mi in "${multi_keys[@]}"; do
                            split_task_line "${menu_options[$mi]}"
                            level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                            [ "$cmd" == "EXIT" ] && continue
                            [ "$cmd" == "SUB" ] && continue
                            [ "$cmd" == "BACK" ] && continue
                            execute_task "$cmd" "$name" "$desc"
                        done
                    fi
                    if [ "$is_interactive" -eq 1 ]; then
                        set_raw_mode
                        drain_stdin
                    fi
                    echo -e "${COLOR_INFO}$(msg executed_marked):${COLOR_RESET} ${#multi_keys[@]} $(msg marked_label)"
                    multi_select_map=()
                    redraw_needed=1
                    continue
                fi
                set -u

                # Single execution
                split_task_line "${menu_options[$selected_index]}"
                level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                if [ "$cmd" == "EXIT" ]; then
                    restore_term; clear; exit 0
                elif [ "$cmd" == "SUB" ]; then
                    current_level=$((current_level + 1))
                    history_name_stack+=("$name")
                    selected_index=0
                    _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                    redraw_needed=1
                elif [ "$cmd" == "BACK" ] && [ "$current_level" -gt 0 ]; then
                    current_level=$((current_level - 1))
                    history_name_stack=("${history_name_stack[@]:0:${#history_name_stack[@]}-1}")
                    selected_index=0
                    _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                    redraw_needed=1
                else
                    run_with_term_paused execute_task "$cmd" "$name" "$desc"
                    redraw_needed=1
                fi;;
            "e"|"E") # Edit config
                [ -z "$config_path" ] && config_path="$LOCAL_CONFIG"
                run_with_term_paused edit_config_menu "$config_path"
                # The config file may have changed — reload the menu, otherwise
                # new or edited tasks only appear after a restart.
                # The cache is invalidated explicitly: the change stamp
                # (mtime:size) only detects an edit when mtime or size
                # change — an edit of the same size within the same second
                # stayed invisible.
                invalidate_menu_cache
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "f"|"F") run_with_term_paused file_browser; redraw_needed=1;;
            "#") # Tag filter
                run_with_term_paused show_tag_menu
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "*") # Toggle favorite
                # Internal operation, no restore needed
                # "-ge 0": siehe Space-Handler — ein leeres Menü mit "↑"
                # ließ selected_index bei -1 hängen und "menu_options[-1]"
                # brach unter Bash 3.2 den ganzen Runner ab.
                if [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "$num" ]; then
                    split_task_line "${menu_options[$selected_index]}"
                    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                    toggle_favorite "$name"
                fi
                redraw_needed=1;;
            "r") run_with_term_paused show_favorites; redraw_needed=1;;
            "R") run_with_term_paused show_recent; redraw_needed=1;;
            "L") run_with_term_paused show_logs; redraw_needed=1;;
            "c"|"C") # Copy the selected command to the clipboard
                if [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "$num" ]; then
                    split_task_line "${menu_options[$selected_index]}"
                    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                    copy_to_clipboard "$cmd"
                fi
                redraw_needed=1;;
            "q"|"Q") restore_term; clear; exit 0;;
        esac

        # Wrap around selection index (also resets on an empty menu — an
        # index of -1 would kill the runner with a "bad array subscript"
        # on Bash 3.2, see comment on clamp_selected_index)
        clamp_selected_index
    done

    # The menu-specific Ctrl+C handler is no longer the active one
    _MENU_LOOP_ACTIVE=0
}

# ==============================================================================
#  FILE BROWSER
# ==============================================================================

file_browser() {
    while true; do
        clear
        echo -e "${COLOR_HEAD}File Browser${COLOR_RESET}"
        echo -e "${COLOR_DIM}Current directory: $PWD${COLOR_RESET}"
        echo ""
        
        # Priority files
        local -a priority_files=(".tasks" ".env" "README.md" "package.json" "docker-compose.yml")
        local found_priority=0
        
        echo -e "${COLOR_INFO}Priority Files:${COLOR_RESET}"
        for pf in "${priority_files[@]}"; do
            if [ -f "$pf" ]; then
                echo "  - $pf"
                found_priority=1
            fi
        done
        
        [ "$found_priority" -eq 0 ] && echo -e "${COLOR_DIM}  (none)${COLOR_RESET}"
        
        echo ""
        echo "1) Create new file"
        echo "2) Edit .tasks"
        echo "3) Edit .env"
        echo "4) Browse all files"
        echo "0) Back"
        echo ""
        choice=$(read_key) || break
        
        case "$choice" in
            "1")
                clear
                echo -e "${COLOR_HEAD}Create New File${COLOR_RESET}"
                echo -e "${COLOR_INFO}Enter filename:${COLOR_RESET}"
                # Bei EOF (Pipe ohne Eingabe) setzt "read" die Variable auf
                # "unset" — unter "set -u" wäre die Prüfung ein Abbruch.
                local filename=""
                read -r filename || true

                if [ -z "${filename:-}" ]; then
                    echo -e "${COLOR_ERR}Filename cannot be empty!${COLOR_RESET}"
                    sleep 1
                    continue
                fi
                
                if ! validate_filename "$filename"; then
                    echo -e "${COLOR_ERR}Invalid filename!${COLOR_RESET}"
                    sleep 1
                    continue
                fi
                
                local filepath="$PWD/$filename"
                if [ -f "$filepath" ]; then
                    echo -e "${COLOR_ERR}File already exists!${COLOR_RESET}"
                    sleep 2
                    continue
                fi
                
                echo -e "${COLOR_INFO}Choose creation method:${COLOR_RESET}"
                echo "1) Open in editor"
                echo "2) Paste content"
                method=$(read_key) || break

                case "$method" in
                    "1")
                        run_external_editor "$filepath"
                        ;;
                    "2")
                        echo -e "${COLOR_INFO}Paste content (Ctrl+D to save):${COLOR_RESET}"
                        # Without a terminal `cat` would swallow the remaining
                        # input instead of ending at EOF.
                        if [ -t 0 ]; then
                            cat > "$filepath"
                            echo -e "${COLOR_SEL}✔ File created: $filename${COLOR_RESET}"
                        else
                            echo -e "${COLOR_ERR}Paste mode needs an interactive terminal${COLOR_RESET}"
                        fi
                        sleep 1
                        ;;
                esac
                ;;
            "2")
                if [ -f ".tasks" ]; then
                    run_external_editor ".tasks"
                else
                    echo -e "${COLOR_ERR}.tasks not found${COLOR_RESET}"
                fi
                ;;
            "3")
                if [ -f ".env" ]; then
                    run_external_editor ".env"
                else
                    echo -e "\n${COLOR_INFO}Create .env? [y/N]${COLOR_RESET} "
                    local reply=""
                    read -n 1 -r reply || true
                    echo ""
                    if [[ "${reply:-}" =~ ^[Yy]$ ]]; then
                        touch ".env"
                        run_external_editor ".env"
                    fi
                fi
                ;;
            "4")
                local -a all_files=()
                IFS=$'\n' read -r -d '' -a all_files < <(find . -maxdepth 2 -type f ! -path '*/\.*' 2>/dev/null && printf '\0') || true
                if [ ${#all_files[@]} -eq 0 ]; then
                    echo -e "${COLOR_DIM}No files found${COLOR_RESET}"
                    sleep 1
                else
                    clear
                    echo -e "${COLOR_HEAD}Files:${COLOR_RESET}"
                    local idx=1
                    for f in "${all_files[@]}"; do
                        [ "$idx" -le 9 ] && echo "$idx) $f"
                        idx=$((idx + 1))
                    done
                    echo -e "\n[1-9] Edit [q]uit"
                    fkey=$(read_key) || break
                    # Verankert: eine Escape-Sequenz, die eine Ziffer enthält
                    # (z.B. "\e[1~"), wäre sonst eine gültige Auswahl.
                    if [[ "$fkey" =~ ^[1-9]$ ]]; then
                        local fsel=$((fkey - 1))
                        if [ "$fsel" -lt "${#all_files[@]}" ]; then
                            run_external_editor "${all_files[$fsel]}"
                        fi
                    fi
                fi
                ;;
            "0"|$'\x1b')
                break
                ;;
        esac
    done
}

# ==============================================================================
#  CONFIG EDITOR
# ==============================================================================

edit_config_menu() {
    local file="${1:-$config_path}"

    while true; do
        clear
        echo -e "${COLOR_HEAD}Config Editor${COLOR_RESET}"
        echo -e "${COLOR_DIM}File: $file${COLOR_RESET}"
        echo ""
        echo "1) Open in Editor (${EDITOR:-nano})"
        echo "2) Replace entire content (paste mode)"
        echo "3) View file"
        echo "0) Back"
        echo ""
        choice=$(read_key) || break

        case "$choice" in
            "1")
                run_external_editor "$file"
                ;;
            "2")
                clear
                echo -e "${COLOR_HEAD}Replace File Content${COLOR_RESET}"
                echo -e "${COLOR_INFO}Paste your content below, then press Ctrl+D (or Ctrl+Z on Windows)${COLOR_RESET}"
                echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"

                # Create temp file inside $CACHE_DIR — the EXIT trap cleans it up
                local tmp_file
                tmp_file="${CACHE_DIR}/edit_$$_${RANDOM}.tmp"
                if ! : > "$tmp_file" 2>/dev/null; then
                    echo -e "${COLOR_ERR}$(msg temp_file_fail)${COLOR_RESET}"
                    sleep 1
                    continue
                fi
                # Without a terminal `cat` would swallow the remaining input
                # instead of ending at EOF.
                if [ -t 0 ]; then
                    cat > "$tmp_file"
                else
                    echo -e "${COLOR_ERR}Paste mode needs an interactive terminal${COLOR_RESET}"
                    rm -f "$tmp_file"
                    sleep 1
                    continue
                fi

                # Show preview
                echo ""
                echo -e "${COLOR_WARN}Preview (first 10 lines):${COLOR_RESET}"
                head -10 "$tmp_file"
                echo ""
                read -p "Replace $file with this content? [y/N] " -n 1 -r || true
                echo ""
                if [[ "${REPLY:-}" =~ ^[Yy]$ ]]; then
                    mv "$tmp_file" "$file"
                    echo -e "${COLOR_SEL}✔ File updated!${COLOR_RESET}"
                else
                    rm -f "$tmp_file"
                    echo -e "${COLOR_INFO}Cancelled.${COLOR_RESET}"
                fi
                sleep 1
                ;;
            "3")
                clear
                echo -e "${COLOR_HEAD}Current content:${COLOR_RESET}"
                echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
                cat "$file"
                echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
                echo ""
                echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
                consume_keypress
                ;;
            "0"|$'\x1b')
                break
                ;;
        esac
    done
}

show_alias_editor() {
    clear
    echo -e "${COLOR_HEAD}Alias Manager${COLOR_RESET}"

    if [ ! -f "$ALIAS_FILE" ] || [ ! -s "$ALIAS_FILE" ]; then
        echo -e "${COLOR_DIM}No aliases defined yet.${COLOR_RESET}"
        echo -e "${COLOR_INFO}Create alias file? [y/N]${COLOR_RESET}"
        REPLY=$(read_key) || REPLY=""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cat > "$ALIAS_FILE" << 'EOF'
# Task Aliases
# Format: alias_name=actual_task_name
# Example:
# build=npm run build
# test=npm test
EOF
            run_external_editor "$ALIAS_FILE"
        fi
    else
        echo -e "${COLOR_DIM}Current aliases:${COLOR_RESET}"
        # Einzelner _grep statt zwei Pipes — spart einen Fork
        _grep -Ev '^#|^[[:space:]]*$' "$ALIAS_FILE" || true
        echo ""
        echo "1) Edit aliases"
        echo "2) Add new alias"
        echo "0) Back"
        choice=$(read_key) || return

        case "$choice" in
            "1")
                run_external_editor "$ALIAS_FILE"
                ;;
            "2")
                echo -e "\n${COLOR_INFO}Alias name:${COLOR_RESET}"
                # Bei EOF setzt "read" die Variable auf "unset" — unter
                # "set -u" wäre die Prüfung ein Abbruch.
                local alias_name=""
                local task_name=""
                read -r alias_name || true
                echo -e "${COLOR_INFO}Task name:${COLOR_RESET}"
                read -r task_name || true
                # The alias file format is "alias_name=task_name" — an '=' or
                # whitespace in the alias name would break the parsing.
                if [ -z "${alias_name:-}" ] || [ -z "${task_name:-}" ] \
                   || [[ "$alias_name" == *"="* ]] || [[ "$alias_name" == *[[:space:]]* ]]; then
                    echo -e "${COLOR_ERR}Invalid alias name (no '=' or whitespace allowed)${COLOR_RESET}"
                    sleep 1
                else
                    echo "${alias_name}=${task_name}" >> "$ALIAS_FILE"
                    echo -e "${COLOR_SEL}✔ Alias added!${COLOR_RESET}"
                    sleep 1
                fi
                ;;
        esac
    fi

    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    consume_keypress
}

load_aliases() {
    # Create alias file if not exists
    if [ ! -f "$ALIAS_FILE" ]; then
        touch "$ALIAS_FILE"
    fi
}

resolve_alias() {
    local input="$1"
    if [ -f "$ALIAS_FILE" ]; then
        # awk for exact match – safe with special chars, no grep regex risks, no cut fork.
        # sub() instead of $2: the alias value may contain '=' itself.
        local resolved
        resolved=$(awk -v a="$input" 'index($0, a "=") == 1 { print substr($0, length(a) + 2); exit }' "$ALIAS_FILE" 2>/dev/null || true)
        if [ -n "$resolved" ]; then
            echo "$resolved"
            return 0
        fi
    fi
    echo "$input"
}

settings_menu() {
    while true; do
        clear
        echo -e "${COLOR_HEAD}Settings${COLOR_RESET}"
        echo ""
        echo "Current Settings:"
        echo -e "  Theme:       ${COLOR_SEL}$UI_THEME${COLOR_RESET}"
        echo -e "  Language:    ${COLOR_SEL}$UI_LANG${COLOR_RESET}"
        echo -e "  Columns:     ${COLOR_SEL}$COLS_MIN-$COLS_MAX${COLOR_RESET}"
        echo ""
        echo "1) Change Theme"
        echo "2) Change Language"
        echo "3) Change Column Layout"
        echo "4) Save Globally"
        echo "5) Save Locally"
        echo "0) Back"
        echo ""
        choice=$(read_key) || break

        case "$choice" in
            "1")
                echo -e "\n${COLOR_INFO}Select Theme:${COLOR_RESET}"
                echo "1) CYBER"
                echo "2) MONO"
                echo "3) DARK"
                echo "4) LIGHT"
                theme_choice=$(read_key) || break
                case "$theme_choice" in
                    "1") UI_THEME="CYBER";;
                    "2") UI_THEME="MONO";;
                    "3") UI_THEME="DARK";;
                    "4") UI_THEME="LIGHT";;
                esac
                apply_theme
                ;;
            "2")
                echo -e "\n${COLOR_INFO}Select Language:${COLOR_RESET}"
                echo "1) EN (English)"
                echo "2) DE (Deutsch)"
                lang_choice=$(read_key) || continue
                case "$lang_choice" in
                    "1") UI_LANG="EN";;
                    "2") UI_LANG="DE";;
                esac
                ;;
            "3")
                echo -e "\n${COLOR_INFO}Column Layout (1-4):${COLOR_RESET}"
                col_val=$(read_key) || break
                # Verankert: eine Escape-Sequenz, die eine Ziffer enthält
                # (z.B. "\e[1~"), wäre sonst eine gültige Auswahl.
                if [[ "$col_val" =~ ^[1-4]$ ]]; then
                    COLS_MIN="$col_val"
                    COLS_MAX="$col_val"
                fi
                ;;
            "4")
                save_settings "global"
                echo -e "\n${COLOR_SEL}✔ Saved globally${COLOR_RESET}"
                sleep 1
                ;;
            "5")
                save_settings "local"
                echo -e "\n${COLOR_SEL}✔ Saved locally${COLOR_RESET}"
                sleep 1
                ;;
            "0"|$'\x1b')
                break
                ;;
        esac
    done
}

# ==============================================================================
#  SELF-UPDATE
# ==============================================================================

self_update() {
    echo -e "${COLOR_HEAD}$(msg update_check)${COLOR_RESET}"
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${COLOR_ERR}$(msg curl_missing)${COLOR_RESET}"
        return 1
    fi
    local tmp_file
    tmp_file=$(mktemp /tmp/run_update.XXXXXX) || { echo -e "${COLOR_ERR}$(msg temp_file_fail)${COLOR_RESET}"; return 1; }
    if curl -fsSL "$REPO_RAW_URL" -o "$tmp_file"; then
        # Version check first — no hash prompt needed when already up to date
        local new_ver=""
        new_ver=$(_grep -m1 "readonly VERSION=" "$tmp_file" 2>/dev/null | cut -d'"' -f2 2>/dev/null || true)
        if [ -z "$new_ver" ]; then
            echo -e "${COLOR_ERR}$(msg download_error)${COLOR_RESET}"
            rm -f "$tmp_file"
            return 1
        fi
        if [ "$new_ver" == "$VERSION" ]; then
            echo -e "${COLOR_SEL}$(msg update_same) ($VERSION).${COLOR_RESET}"
            rm -f "$tmp_file"
        else
            echo -e "${COLOR_WARN}$(msg update_found) $VERSION -> $new_ver${COLOR_RESET}"
            # Hash verification only when an actual update is about to be installed
            if [ -n "${RUN_EXPECTED_SHA256:-}" ]; then
                local dl_hash=""
                dl_hash=$(file_sha256 "$tmp_file") || echo -e "${COLOR_WARN}$(msg hash_skipped)${COLOR_RESET}"
                if [ -n "$dl_hash" ] && [ "$dl_hash" != "${RUN_EXPECTED_SHA256:-}" ]; then
                    echo -e "${COLOR_ERR}$(msg hash_mismatch) ${RUN_EXPECTED_SHA256:-} != $dl_hash${COLOR_RESET}"
                    rm -f "$tmp_file"
                    return 1
                fi
            else
                echo -e "${COLOR_WARN}$(msg no_hash)${COLOR_RESET}"
                read -p "$(msg continue_prompt) " -n 1 -r || true; echo ""
                if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
                    rm -f "$tmp_file"
                    return 1
                fi
            fi
            local install_path
            # "|| install_path=''": eine fehlgeschlagene Zuweisung (fehlendes
            # "run" auf dem PATH) bricht unter "set -e" sonst das Skript ab,
            # BEVOR die darunter stehende Fehlermeldung eine Chance hat —
            # der Update-Flow endete dann stumm ohne jeden Hinweis.
            install_path=$(command -v run 2>/dev/null) || install_path=""
            if [ -z "$install_path" ]; then
                echo -e "${COLOR_ERR}$(msg install_path_missing)${COLOR_RESET}"
                rm -f "$tmp_file"
                return 1
            fi
            # "command -v" liefert bei einer Shell-Funktion oder einem Alias
            # nur den Namen ("run") — das wäre ein relatives Ziel im
            # aktuellen Verzeichnis.  Nur ein absoluter Pfad ist gültig.
            case "$install_path" in
                /*) ;;
                *)
                    echo -e "${COLOR_ERR}$(msg install_path_missing)${COLOR_RESET}"
                    rm -f "$tmp_file"
                    return 1
                    ;;
            esac
            local _install_failed=0
            if [ -w "$install_path" ]; then
                mv "$tmp_file" "$install_path" && chmod +x "$install_path" || _install_failed=1
            else
                sudo mv "$tmp_file" "$install_path" && sudo chmod +x "$install_path" || _install_failed=1
            fi
            # Ein fehlgeschlagener Installationsschritt darf NICHT als Erfolg
            # gemeldet werden (vorher stand hier "✔ Update erfolgreich", auch
            # wenn das sudo fehlschlug).
            if [ "$_install_failed" -ne 0 ]; then
                echo -e "${COLOR_ERR}$(msg update_failed)${COLOR_RESET}"
                rm -f "$tmp_file"
                return 1
            fi
            echo -e "${COLOR_SEL}✔ $(msg update_success) $new_ver${COLOR_RESET}"
            command -v run >/dev/null 2>&1 && echo -e "${COLOR_INFO}Aktuelle Version:${COLOR_RESET} $(run --version 2>/dev/null)"
            return 0
        fi
    else
        echo -e "${COLOR_ERR}$(msg download_error)${COLOR_RESET}"
        rm -f "$tmp_file"
        return 1
    fi
}

# ==============================================================================
#  SMART INIT (AUTO-DETECTION)
# ==============================================================================

# Extracts the script names from a package.json.
#
# jq is used when available; the awk fallback counts the key lines of the
# "scripts" object.  The previous implementation ("sed -n '/"scripts": {/,/}/p'")
# picked up the container key itself ("npm scripts") and stopped at the first
# "}" — a script value containing a brace truncated the whole list.
_package_json_scripts() {
    local file="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '(.scripts // {}) | keys[]' "$file" 2>/dev/null
        return 0
    fi
    awk '
        /"scripts"[[:space:]]*:[[:space:]]*\{/ { in_scripts = 1; next }
        in_scripts && /^[[:space:]]*\}/ { in_scripts = 0; next }
        in_scripts && match($0, /^[[:space:]]*"[^"]+"[[:space:]]*:/) {
            key = substr($0, RSTART, RLENGTH)
            sub(/^[[:space:]]*"/, "", key)
            sub(/".*/, "", key)
            print key
        }
    ' "$file" 2>/dev/null
}

smart_init() {
    local mode="$1"
    local target="$LOCAL_CONFIG"; [ "$mode" == "global" ] && target="$GLOBAL_CONFIG"

    if [ -f "$target" ]; then
        echo -e "${COLOR_WARN}$(msg config_exists) '$target'.${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_HEAD}$(msg init_header)${COLOR_RESET}"
    echo "# Shell Menu Runner Configuration" > "$target"
    echo "# THEME: CYBER" >> "$target"
    echo "" >> "$target"

    if [ "$mode" == "global" ]; then
        echo "0|🔄 System Update|sudo apt update && sudo apt upgrade -y|Systempflege" >> "$target"
        echo "0|🧹 Cache Cleanup|rm -rf /tmp/*|Temporäre Dateien löschen" >> "$target"
    else
        local target_dir
        target_dir="$(dirname "$target")"

        # Git profile tasks (separate menu via: run git)
        if [ -d "$target_dir/.git" ]; then
            local git_tasks_file="$target_dir/.tasks.git"
            if [ ! -f "$git_tasks_file" ]; then
                echo -e "${COLOR_INFO}→ Git repo detected. Creating .tasks.git...${COLOR_RESET}"
                cat > "$git_tasks_file" <<'EOF'
# Shell Menu Runner Git Tasks
# TITLE: GIT
0|📌 Status|git status -sb|Working tree status
0|🧭 Branches|git branch -a|List branches
0|🧾 Log (short)|git log --oneline --decorate -n 20|Recent commits
0|🧩 Diff|git diff|Show unstaged diff
0|✅ Add All|git add -A|Stage all changes
0|📝 Commit|git commit -m "<<Commit message>>"|Create commit
0|⬇ Pull|git pull --rebase|Pull with rebase
0|⬆ Push|git push|Push current branch
0|📦 Stash|git stash push -m "<<Stash message>>"|Stash changes
0|📦 Stash Pop|git stash pop|Apply latest stash
0|❌ Exit|EXIT|Back
EOF
            fi
        fi

        # Docker profile tasks (separate menu via: run docker)
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            local docker_tasks_file="$target_dir/.tasks.docker"
            if [ ! -f "$docker_tasks_file" ]; then
                echo -e "${COLOR_INFO}→ Docker Compose detected. Creating .tasks.docker...${COLOR_RESET}"
                cat > "$docker_tasks_file" <<'EOF'
# Shell Menu Runner Docker Tasks
# TITLE: DOCKER
0|🐳 Up|docker compose up -d|Start containers
0|🐳 Down|docker compose down|Stop containers
0|🐳 Logs|docker compose logs -f --tail=200|Follow logs
0|🐳 Restart|docker compose restart|Restart containers
0|🐳 Ps|docker compose ps|Show status
0|❌ Exit|EXIT|Back
EOF
            fi
        fi

        # 1. Node.js / React Detection
        if [ -f "package.json" ]; then
            echo -e "${COLOR_INFO}→ $(msg node_detected)${COLOR_RESET}"
            local scripts
            scripts=$(_package_json_scripts "package.json")
            for s in $scripts; do
                echo "0|📦 npm $s|npm run $s|Aus package.json" >> "$target"
            done

            if [ -f "pnpm-lock.yaml" ]; then
                echo "0|📦 pnpm install|pnpm install|Install dependencies" >> "$target"
            fi
            if [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then
                echo "0|📦 bun install|bun install|Install dependencies" >> "$target"
            fi
        fi

        # 2. Docker Detection
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            echo -e "${COLOR_INFO}→ $(msg docker_detected)${COLOR_RESET}"
            echo "0|🐳 Docker Up|docker compose up -d|Container starten" >> "$target"
            echo "0|🐳 Docker Down|docker compose down|Container stoppen" >> "$target"
        fi

        # 3. Python Detection
        if [ -f "requirements.txt" ] || [ -f "main.py" ] || [ -f "manage.py" ]; then
            echo -e "${COLOR_INFO}→ $(msg python_detected)${COLOR_RESET}"
            [ -f "manage.py" ] && echo "0|🐍 Django Run|python3 manage.py runserver|Django Dev Server" >> "$target"
            [ -f "main.py" ] && echo "0|🐍 Run Main|python3 main.py|Python Script starten" >> "$target"
        fi

        if [ -f "pyproject.toml" ] || [ -f "poetry.lock" ]; then
            echo "0|🐍 Poetry Install|poetry install|Install dependencies" >> "$target"
            echo "0|🐍 Poetry Shell|poetry shell|Enter virtualenv" >> "$target"
        fi
        if [ -f "Pipfile" ]; then
            echo "0|🐍 Pipenv Install|pipenv install|Install dependencies" >> "$target"
            echo "0|🐍 Pipenv Shell|pipenv shell|Enter virtualenv" >> "$target"
        fi

        # 4. Makefile Detection
        if [ -f "Makefile" ] || [ -f "makefile" ]; then
            echo "0|🛠 Make|make|Default target" >> "$target"
            echo "0|🛠 Make Test|make test|Run tests" >> "$target"
        fi

        # 5. Go Detection
        if [ -f "go.mod" ]; then
            {
                echo "0|🐹 Go Build|go build ./...|Build modules"
                echo "0|🐹 Go Test|go test ./...|Run tests"
                echo "0|🐹 Go Run|go run .|Run module"
            } >> "$target"
        fi

        # 6. Rust Detection
        if [ -f "Cargo.toml" ]; then
            {
                echo "0|🦀 Cargo Build|cargo build|Build project"
                echo "0|🦀 Cargo Test|cargo test|Run tests"
                echo "0|🦀 Cargo Run|cargo run|Run project"
            } >> "$target"
        fi

        # 7. Java Detection
        if [ -f "pom.xml" ]; then
            echo "0|☕ Maven Test|mvn test|Run tests" >> "$target"
            echo "0|☕ Maven Package|mvn package|Build package" >> "$target"
        fi
        if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
            echo "0|☕ Gradle Test|./gradlew test|Run tests" >> "$target"
            echo "0|☕ Gradle Build|./gradlew build|Build project" >> "$target"
        fi

        # 8. PHP Detection
        if [ -f "composer.json" ]; then
            echo "0|🐘 Composer Install|composer install|Install dependencies" >> "$target"
            echo "0|🐘 PHP Server|php -S localhost:8000 -t public|Dev server" >> "$target"
        fi

        # 9. Ruby Detection
        if [ -f "Gemfile" ]; then
            echo "0|💎 Bundle Install|bundle install|Install gems" >> "$target"
            echo "0|💎 Rake Test|bundle exec rake test|Run tests" >> "$target"
        fi

        # 10. Terraform Detection
        if compgen -G "*.tf" >/dev/null; then
            echo "0|🌍 Terraform Init|terraform init|Initialize" >> "$target"
            echo "0|🌍 Terraform Plan|terraform plan|Show plan" >> "$target"
        fi

        # Fallback falls nichts gefunden wurde
        if [ "$(wc -l < "$target")" -lt 4 ]; then
            echo "0|🚀 Hello World|echo 'Edit .tasks to add commands'|Beispiel Task" >> "$target"
        fi
    fi

    echo "0|❌ Exit|EXIT|Menü beenden" >> "$target"
    echo -e "${COLOR_SEL}✔ $(msg init_done) '$target'.${COLOR_RESET}"
}

# ==============================================================================
#  MAIN ENTRY POINT
# ==============================================================================

# Parse CLI arguments
args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            # 2>/dev/null: a closed stdout (`run --help | head`) must not
            # produce a "write error: Broken pipe" message from the builtin.
            {
                echo "Usage: run [options] [profile]"
                echo ""
                echo "CLI Mode (no menu):"
                echo "  run --list              List all tasks for current profile"
                echo "  run --run <name|num>    Execute task by name (substring) or number"
                echo "  run --dry-run --run <n> Preview command without executing"
                echo "  run git --run build     Profile + task combined"
                echo ""
                echo "Profiles:"
                echo "  run <name>              Load profile .tasks.<name>"
                echo "  run --list-profiles     List all available profiles"
                echo "  run --list-profiles=json  List profiles in JSON format"
                echo "  run --init-profile <name>  Create new profile"
                echo "  run --validate <name>   Validate profile syntax"
                echo ""
                echo "Multi-Profile Execution:"
                echo "  run --across p1,p2,p3 task  Execute task across multiple profiles"
                echo ""
                echo "Analysis & Recommendations:"
                echo "  run --analyze [profile]  Show analysis & improvement suggestions"
                echo ""
                echo "Other:"
                echo "  run --help, -h          Show this help"
                echo "  run --version, -v       Show version"
                echo "  run --init              Initialize .tasks in current dir"
                echo "  run --global            Switch to global mode"
                echo "  run --edit, -e          Edit config file"
                echo "  run --update            Update script to latest version"
                echo "  run --debug             Enable debug mode"
            } 2>/dev/null || true
            exit 0
            ;;
        --version|-v)
            echo "$VERSION"
            exit 0
            ;;
        --debug)
            DEBUG_MODE=1
            shift
            ;;
        --across)
            shift
            if [ $# -lt 2 ]; then
                echo "Usage: run --across <profile1,profile2> <task>" >&2
                exit 1
            fi
            multi_profiles="$1"
            shift
            multi_task="$1"
            shift
            execute_multi_profile_task "$multi_task" "$multi_profiles"
            exit $?
            ;;
        --init)
            smart_init "local"
            exit 0
            ;;
        --list-profiles*)
            format="${1#*=}"
            [ "$format" = "--list-profiles" ] && format="text"
            list_profiles_all "$format"
            exit 0
            ;;
        --init-profile)
            shift
            # "${1:-}": ohne Argument wäre "$1" eine ungebundene Variable —
            # der Fehler endete mit Exit-Code 0 (der EXIT-Trap verwirft den
            # Status) und die Meldung war für den Nutzer unverständlich.
            init_profile "${1:-}"
            exit $?
            ;;
        --validate)
            shift
            if [ -n "${1:-}" ]; then
                validate_profile "$1"
            else
                if found=$(find_local_config); then
                    validate_config_file "$found" "local"
                elif [ -f "$GLOBAL_CONFIG" ]; then
                    validate_config_file "$GLOBAL_CONFIG" "global"
                else
                    echo "Error: profile name required"
                    exit 1
                fi
            fi
            exit $?
            ;;
        --analyze)
            shift
            analyze_project "$@"
            exit 0
            ;;
        --update)
            # Der Rückgabewert von self_update wird durchgereicht — ein
            # fehlgeschlagenes Update darf nicht mit Exit 0 enden.
            self_update
            exit $?
            ;;
        --global)
            active_mode="global"
            config_path="$GLOBAL_CONFIG"
            if [ ! -f "$config_path" ]; then
                if smart_init "global"; then
                    exit 0
                fi
            fi
            # The flag is consumed in any case — otherwise it would end up in
            # the profile list and be treated as a profile name.
            shift
            ;;
        --edit|-e)
            # Der Config-Pfad wird erst nach der Argument-Auswertung
            # aufgelöst — hier muss derselbe Pfad wie im Menü verwendet
            # werden.  Sonst öffnete der Editor in einem Unterverzeichnis
            # eine neue (nicht existierende) ".tasks" statt der Config,
            # die der Runner tatsächlich verwendet.
            if [ -z "$config_path" ]; then
                if [ "$active_mode" = "global" ]; then
                    config_path="$GLOBAL_CONFIG"
                elif found=$(find_local_config); then
                    config_path="$found"
                else
                    config_path="$LOCAL_CONFIG"
                fi
            fi
            # Terminal-Snapshot, damit der Editor-Zustand danach wiederhergestellt
            # werden kann (läuft vor check_interactive)
            save_terminal_state
            edit_config_menu "$config_path"
            exit 0
            ;;
        --run)
            shift
            cli_run_query="${1:-}"
            if [ -z "$cli_run_query" ]; then
                echo "Usage: --run <name-or-number>" >&2
                exit 1
            fi
            cli_mode=1
            shift
            ;;
        --dry-run)
            dry_run_mode=1
            shift
            ;;
        --list)
            cli_list_mode=1
            shift
            ;;
        *)
            # Ein unbekanntes Flag ist ein Tippfehler, kein Profilname —
            # ein Profilname darf nicht mit einem Bindestrich beginnen.
            # Vorher wurde "--foo" als Profilname interpretiert und der
            # Runner startete normal ("Profile '--foo' not found").
            case "$1" in
                -*)
                    echo "Error: unknown option '$1'" >&2
                    echo "Run 'run --help' for the list of options." >&2
                    exit 1
                    ;;
            esac
            args+=("$1")
            shift
            ;;
    esac
done
set +u  # Disable nounset for array check
if [ "${#args[@]}" -gt 0 ]; then
    set -- "${args[@]}"
else
    set --
fi
set -u  # Re-enable nounset

if [ "${RUN_DEBUG:-0}" = "1" ]; then
    DEBUG_MODE=1
fi

if [ "$DEBUG_MODE" -eq 1 ]; then
    set -x
fi

# Profile selection on startup was removed — use [p] in the menu instead.

set +u  # Disable nounset for array check
# Name des Alias-Ziels, das ein Task sein könnte (siehe _alias_task).
_alias_task=""
if [ "${#args[@]}" -gt 0 ]; then
    set -u  # Re-enable nounset
    load_aliases
    profile_input="${args[0]}"
    profile="$(resolve_alias "$profile_input")"

    if found=$(find_named_config "$profile"); then
        active_mode="local"
        config_path="$found"
    elif [ -f "$HOME/.tasks.$profile" ]; then
        active_mode="global"
        config_path="$HOME/.tasks.$profile"
    elif [ "$profile" != "$profile_input" ]; then
        # Der Alias zeigt nicht auf ein Profil, sondern auf einen Task-Namen
        # (das Alias-File-Template dokumentiert "alias=task_name").  Der
        # Task wird später aus der Standard-Config ausgeführt.
        _alias_task="$profile"
    else
        echo -e "${COLOR_WARN}Profile '$profile' not found. Using default config.${COLOR_RESET}"
        profiles_list=$(list_available_profiles)
        if [ -n "$profiles_list" ]; then
            echo -e "${COLOR_INFO}Available profiles:${COLOR_RESET} ${profiles_list//$'\n'/ }"
        fi
    fi
else
    set -u  # Re-enable nounset if condition was false
fi

if [ -z "$config_path" ]; then
    if found=$(find_local_config); then
        config_path="$found"
    elif [ -f "$GLOBAL_CONFIG" ]; then
        active_mode="global"
        config_path="$GLOBAL_CONFIG"
    else
        # Fallback: Load default global profile or show error
        echo -e "${COLOR_WARN}No .tasks file found.${COLOR_RESET}"
        exit 1
    fi
fi

# Global variables from ~/.run_vars are loaded before the config so that the
# VAR_* entries of the config can overwrite them.
load_global_vars

parse_config_vars
load_settings
# The theme from .runrc / the config file was never applied before — the
# colours were only changed when the settings menu was opened.
apply_theme
load_state
# Ensure selected_index is initialized
selected_index="${selected_index:-0}"
detect_config_files
load_aliases
check_interactive
check_ssh_session

# If not interactive and SSH, show hint (only once)
if [ "$is_interactive" -eq 0 ] && [ "$is_ssh_session" -eq 1 ] && [ "$ssh_hint_shown" -eq 0 ]; then
    echo ""
    print_ssh_hint
    echo ""
    echo "Proceeding in non-interactive mode. Type task number to execute:"
    echo ""
    ssh_hint_shown=1
fi

# Without a TTY there is nobody to answer the interactive prompts (preview,
# "press any key") — the tasks run in CLI mode instead.
if [ "$is_interactive" -eq 0 ] && [ "${cli_mode:-0}" -eq 0 ]; then
    cli_mode=1
fi

# CLI mode dispatch
if [ "${cli_list_mode:-0}" -eq 1 ]; then
    _build_all_tasks
    menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    cli_list_tasks
    exit 0
fi
# An alias that points to a task name (not to a profile) executes the task
# from the current config — the alias file template documents exactly that
# ("alias_name=actual_task_name").
if [ -n "$_alias_task" ]; then
    _build_all_tasks
    menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    cli_run_task "$_alias_task"
    exit $?
fi
if [ -n "${cli_run_query:-}" ]; then
    _build_all_tasks
    menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    cli_run_task "$cli_run_query"
    exit $?
fi

# Load menu options once before loop
_build_menu_options
menu_options=("${MENU_RESULT_ARRAY[@]+"${MENU_RESULT_ARRAY[@]}"}")
num=${#menu_options[@]}
calculate_layout "$num"; rows=$_layout_rows; cols=$_layout_cols
redraw_needed=1

# Main interactive loop is in 13-ui.sh
main_interactive_loop
