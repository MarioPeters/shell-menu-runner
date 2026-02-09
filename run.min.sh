#!/bin/bash
if [ -n "${ZSH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "$0" ]; then
        echo "Error: This script is not meant to be sourced directly in Zsh."
        return 1
    else
        exec bash "$0" "$@"
    fi
fi
readonly VERSION="1.7.0"
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
RUN_PARALLEL_DEPS="${RUN_PARALLEL_DEPS:-0}"      # Enable parallel dependency execution
RUN_CACHE_PROFILES="${RUN_CACHE_PROFILES:-1}"   # Cache profile listings (60s TTL)
export LC_COLLATE=C
OS_NAME="$(uname -s 2>/dev/null || echo "Unknown")"
readonly OS_NAME
ARCH_NAME="$(uname -m 2>/dev/null || echo "Unknown")"
readonly ARCH_NAME
IS_MACOS_ARM=0
if [[ "$OS_NAME" == "Darwin" && "$ARCH_NAME" == "arm64" ]]; then
    IS_MACOS_ARM=1
fi
export IS_MACOS_ARM
set -euo pipefail
COLOR_HEAD=$'\e[1;34m'; COLOR_SEL=$'\e[1;32m'; COLOR_ERR=$'\e[1;31m'
COLOR_WARN=$'\e[1;33m'; COLOR_INFO=$'\e[33m';  COLOR_DIM=$'\e[2m'
COLOR_RESET=$'\e[0m'
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
last_config_mtime=0
cached_menu_options=""
DEBUG_MODE=0
readonly DEFAULT_LANG="DE"
readonly DEFAULT_THEME="CYBER"
readonly DEFAULT_COLS_MIN=1
readonly DEFAULT_COLS_MAX=3
UI_LANG="$DEFAULT_LANG"
UI_THEME="$DEFAULT_THEME"
COLS_MIN="$DEFAULT_COLS_MIN"
COLS_MAX="$DEFAULT_COLS_MAX"
TASK_THEME=""
SETTINGS_THEME=""
SETTINGS_LANG=""
SETTINGS_COLS_MIN=""
SETTINGS_COLS_MAX=""
parse_config_vars() {
    set +e +o pipefail  # Disable errexit and pipefail for grep operations
    [ ! -f "$config_path" ] && return
    TASK_THEME=$(awk -F':' '/^# THEME:/ {val=$2; gsub(/^[ \t]+|[ \t]+$/, "", val); print val; exit}' "$config_path" 2>/dev/null)
    task_timeout=$(extract_field_from_grep "^TIMEOUT=" "=" 2)
    task_timeout="${task_timeout:-$RUN_TASK_TIMEOUT}"
    load_task_vars
    set -e -o pipefail  # Re-enable errexit and pipefail
}
get_local_settings_path() {
    if [ -n "$config_path" ]; then
        echo "$(dirname "$config_path")/$LOCAL_SETTINGS"
    else
        echo "$PWD/$LOCAL_SETTINGS"
    fi
}
parse_settings_file() {
    local file="$1"
    [ ! -f "$file" ] && return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) continue ;;
        esac
        local key="${line%%=*}"
        local value="${line#*=}"
        case "$key" in
            THEME) SETTINGS_THEME="$value" ;;
            LANG) SETTINGS_LANG="$value" ;;
            COLS_MIN) SETTINGS_COLS_MIN="$value" ;;
            COLS_MAX) SETTINGS_COLS_MAX="$value" ;;
        esac
    done < "$file"
}
resolve_settings() {
    UI_LANG="$DEFAULT_LANG"
    UI_THEME="$DEFAULT_THEME"
    COLS_MIN="$DEFAULT_COLS_MIN"
    COLS_MAX="$DEFAULT_COLS_MAX"
    [ -n "$SETTINGS_LANG" ] && UI_LANG="$SETTINGS_LANG"
    if [ -n "$SETTINGS_THEME" ]; then
        UI_THEME="$SETTINGS_THEME"
    elif [ -n "$TASK_THEME" ]; then
        UI_THEME="$TASK_THEME"
    fi
    [ -n "$SETTINGS_COLS_MIN" ] && COLS_MIN="$SETTINGS_COLS_MIN"
    [ -n "$SETTINGS_COLS_MAX" ] && COLS_MAX="$SETTINGS_COLS_MAX"
    return 0
}
load_settings() {
    SETTINGS_THEME=""; SETTINGS_LANG=""; SETTINGS_COLS_MIN=""; SETTINGS_COLS_MAX=""
    parse_settings_file "$GLOBAL_SETTINGS"
    parse_settings_file "$(get_local_settings_path)"
    resolve_settings
}
save_settings() {
    local scope="$1"
    local target="$GLOBAL_SETTINGS"
    [ "$scope" = "local" ] && target="$(get_local_settings_path)"
    cat > "$target" <<EOF
THEME=$UI_THEME
LANG=$UI_LANG
COLS_MIN=$COLS_MIN
COLS_MAX=$COLS_MAX
EOF
}
detect_config_files() {
    local config_dir
    [ "$active_mode" = "local" ] && config_dir="$(dirname "$config_path")" || config_dir="$HOME"
    local base_name
    base_name="$(basename "$config_path")"
    task_config_files=()
    if [ "$base_name" = ".tasks" ]; then
        [ -f "$config_dir/.tasks" ] && task_config_files+=("$config_dir/.tasks") || true
        [ -f "$config_dir/.tasks.local" ] && task_config_files+=("$config_dir/.tasks.local") || true
        [ -f "$config_dir/.tasks.dev" ] && task_config_files+=("$config_dir/.tasks.dev") || true
    else
        [ -f "$config_dir/$base_name" ] && task_config_files+=("$config_dir/$base_name") || true
        [ -f "$config_dir/${base_name}.local" ] && task_config_files+=("$config_dir/${base_name}.local") || true
        [ -f "$config_dir/${base_name}.dev" ] && task_config_files+=("$config_dir/${base_name}.dev") || true
    fi
    return 0
}
merge_configs() {
    cat "${task_config_files[@]}" 2>/dev/null || true
}
file_sha256() {
    local f="$1"
    if command -v sha256sum &>/dev/null; then sha256sum "$f" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then shasum -a 256 "$f" | awk '{print $1}'
    else return 1; fi
}
get_realpath() {
    if command -v realpath &>/dev/null; then
        realpath "$1"
    elif [[ "$1" = /* ]]; then
        echo "$1"
    else
        echo "$PWD/${1#./}"
    fi
}
cleanup_terminal() { 
    if [ -n "${TPUT_CNORM:-}" ]; then
        echo -ne "$TPUT_CNORM"
    else
        tput cnorm 2>/dev/null || true
    fi
    echo -e "${COLOR_RESET}"; 
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
info() { echo -e "${COLOR_INFO}$*${COLOR_RESET}"; }
warn() { echo -e "${COLOR_WARN}$*${COLOR_RESET}"; }
error() { echo -e "${COLOR_ERR}$*${COLOR_RESET}"; }
success() { echo -e "${COLOR_SEL}✔ $*${COLOR_RESET}"; }
dim() { echo -e "${COLOR_DIM}$*${COLOR_RESET}"; }
sanitize_filename() { sed 's/ /_/g; s/[^A-Za-z0-9._-]//g' <<< "$1"; }
trim_file_to_lines() {
    local file="$1" max="$2"
    [ -f "$file" ] || return 0
    local lines
    lines=$(wc -l < "$file" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$max" ]; then
        tail -n "$max" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file" || true
    fi
}
trim_whitespace() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf "%s" "$s"
}
get_file_mtime() {
    local file="$1"
    if [ -z "${_STAT_CMD:-}" ]; then
        if stat -f %m "$0" >/dev/null 2>&1; then
            _STAT_CMD="stat -f %m"
        else
            _STAT_CMD="stat -c %Y"
        fi
    fi
    $_STAT_CMD "$file" 2>/dev/null || echo 0
}
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
    [ -z "$fn" ] && return 1
    [[ "$fn" =~ \.\. ]] && return 1      # Parent directory
    [[ "$fn" = *'/'* ]] && return 1      # Absolute/relative paths
    [[ "$fn" = *"\${"* ]] && return 1    # Variable expansion
    [[ "$fn" = *'`'* ]] && return 1      # Command substitution
    [[ "$fn" = *'|'* ]] && return 1      # Pipes
    [[ "$fn" = *';'* ]] && return 1      # Command separators
    [[ "$fn" = *'&'* ]] && return 1      # Background operators
    [[ "$fn" = *'>'* ]] && return 1      # Redirection
    [[ "$fn" = *'<'* ]] && return 1      # Redirection
    [[ "$fn" =~ ^[a-zA-Z0-9._-]+$ ]] && return 0
    return 1
}
check_interactive() {
    if [ -t 0 ]; then
        is_interactive=1
        init_terminal_capabilities
    else
        is_interactive=0
    fi
}
check_ssh_session() {
    if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
        is_ssh_session=1
    else
        is_ssh_session=0
    fi
}
_TPUT_INITIALIZED=0
init_terminal_capabilities() {
    [ "${_TPUT_INITIALIZED:-0}" -eq 1 ] && return
    _TPUT_INITIALIZED=1
    if command -v tput >/dev/null 2>&1; then
        TPUT_CUP="$(tput cup 0 0 2>/dev/null)"
        TPUT_CIVIS="$(tput civis 2>/dev/null)"
        TPUT_CNORM="$(tput cnorm 2>/dev/null)"
        TPUT_ED="$(tput ed 2>/dev/null)"
        TPUT_COLS="$(tput cols 2>/dev/null)"
        HAS_TPUT=1
    else
        HAS_TPUT=0
        TPUT_COLS=80
    fi
    trap 'TPUT_COLS=$(tput cols 2>/dev/null || echo 80)' WINCH
}
consume_keypress() {
    stty -echo 2>/dev/null
    read_key >/dev/null
    stty echo 2>/dev/null
}
set_raw_mode() {
    stty -echo -icanon time 0 min 1 isig 2>/dev/null
}
drain_stdin() {
    stty -icanon min 0 time 0 2>/dev/null
    local _d
    while true; do
        _d=$(dd bs=128 count=1 2>/dev/null)
        [ -z "$_d" ] && break
    done
    stty min 1 time 0 2>/dev/null
}
read_key() {
    local key=""
    if ! read -rsn1 key; then return 1; fi
    if [ "$key" = $'\x1b' ]; then
        local previous_stty
        previous_stty=$(stty -g)
        stty -icanon min 0 time 1 2>/dev/null
        local seq
        seq=$(dd bs=10 count=1 2>/dev/null)
        stty "$previous_stty" 2>/dev/null
        key="${key}${seq}"
    fi
    printf "%s" "$key"
}
read_key_raw() {
    local key=""
    if ! read -rsn1 key; then return 1; fi
    if [ "$key" = $'\x1b' ]; then
        stty min 0 time 1 2>/dev/null
        local seq
        seq=$(dd bs=10 count=1 2>/dev/null)
        stty min 1 time 0 2>/dev/null
        key="${key}${seq}"
    fi
    printf "%s" "$key"
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
                hash_failed) echo "Integrity check failed." ;;
                hash_mismatch) echo "Integrity check mismatch:" ;;
                hash_skipped) echo "Warning: sha256sum/shasum not found. Skipping check." ;;
                update_same) echo "You already have the latest version" ;;
                update_found) echo "Update found:" ;;
                install_path_missing) echo "Could not determine install path (run not in PATH)." ;;
                update_success) echo "Update successful!" ;;
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
                task_timeout) echo "Task timeout (killed)" ;;
                task_depends) echo "Running dependencies" ;;
                press_key) echo "Press any key..." ;;
                path_label) echo "Path:" ;;
                filter_label) echo "Filter:" ;;
                search_label) echo "Search:" ;;
                hint_nav) echo "[j/k/h/l] Move [Space] Multi" ;;
                hint_global) echo "[g] Global" ;;
                hint_local) echo "[g] Local" ;;
                hint_run) echo "Run" ;;
                executed_marked) echo "Executed" ;;
                marked_label) echo "marked" ;;
                settings_title) echo "Settings" ;;
                edit_label) echo "Edit" ;;
                file_browser) echo "File browser" ;;
                favorites_label) echo "Favorites" ;;
                settings_theme) echo "Theme" ;;
                settings_cols_min) echo "Columns min" ;;
                settings_cols_max) echo "Columns max" ;;
                settings_lang) echo "Language" ;;
                settings_scope) echo "Scope" ;;
                system_control) echo "SYSTEM CONTROL" ;;
                settings_back) echo "Back" ;;
                settings_saved) echo "Saved" ;;
                scope_global) echo "Global" ;;
                scope_local) echo "Local" ;;
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
                hash_failed) echo "Integritaetscheck fehlgeschlagen." ;;
                hash_mismatch) echo "Integritaetscheck ungueltig:" ;;
                hash_skipped) echo "Warnung: sha256sum/shasum nicht gefunden. Pruefung uebersprungen." ;;
                update_same) echo "Du nutzt bereits die neueste Version" ;;
                update_found) echo "Update gefunden:" ;;
                install_path_missing) echo "Konnte Installationspfad nicht bestimmen (run nicht im PATH)." ;;
                update_success) echo "Update erfolgreich!" ;;
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
                task_timeout) echo "Task Timeout (abgebrochen)" ;;
                task_depends) echo "Führe Abhängigkeiten aus" ;;
                press_key) echo "Taste druecken..." ;;
                path_label) echo "Pfad:" ;;
                filter_label) echo "Filter:" ;;
                search_label) echo "Suche:" ;;
                hint_nav) echo "[j/k/h/l] Bewegen [Space] Multi" ;;
                hint_global) echo "[g] Global" ;;
                hint_local) echo "[g] Lokal" ;;
                hint_run) echo "Start" ;;
                executed_marked) echo "Ausgefuehrt" ;;
                marked_label) echo "markiert" ;;
                settings_title) echo "Einstellungen" ;;
                edit_label) echo "Bearbeiten" ;;
                file_browser) echo "Datei-Browser" ;;
                favorites_label) echo "Favoriten" ;;
                settings_theme) echo "Theme" ;;
                settings_cols_min) echo "Spalten min" ;;
                settings_cols_max) echo "Spalten max" ;;
                settings_lang) echo "Sprache" ;;
                settings_scope) echo "Bereich" ;;
                system_control) echo "SYSTEM CONTROL" ;;
                settings_back) echo "Zurueck" ;;
                settings_saved) echo "Gespeichert" ;;
                scope_global) echo "Global" ;;
                scope_local) echo "Lokal" ;;
                history_label) echo "Verlauf" ;;
                history_empty) echo "Kein Verlaufseintrag vorhanden" ;;
                *) echo "$key" ;;
            esac
            ;;
    esac
}
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
SPINNER_PID=""
SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
show_spinner() {
    local message="$1"
    local delay=0.1
    if [ -n "${TPUT_CIVIS:-}" ]; then echo -ne "$TPUT_CIVIS"; else tput civis 2>/dev/null; fi
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
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        printf "\r%80s\r" " "  # Clear spinner line
        if [ -n "${TPUT_CNORM:-}" ]; then echo -ne "$TPUT_CNORM"; else tput cnorm 2>/dev/null; fi
    fi
}
render_status_bar() {
    local text="$1"
    local bar_width=60
    local padding=$(( (bar_width - ${#text}) / 2 ))
    local left_pad right_pad
    printf -v left_pad  '%*s' "$padding" ''
    printf -v right_pad '%*s' "$((bar_width - ${#text} - padding))" ''
    : "${_STATUS_BAR_BORDER:=$(printf '═%.0s' {1..60})}"
    echo -e "${COLOR_DIM}╔${_STATUS_BAR_BORDER}╗${COLOR_RESET}"
    echo -e "${COLOR_DIM}║${left_pad}${COLOR_RESET}${text}${COLOR_DIM}${right_pad}║${COLOR_RESET}"
    echo -e "${COLOR_DIM}╚${_STATUS_BAR_BORDER}╝${COLOR_RESET}"
}
readonly CACHE_DIR="/tmp/.run_cache_$$"
mkdir -p "$CACHE_DIR" 2>/dev/null || true
_cache_file_last_path=""
_cache_file_last_result=""
get_cache_file() {
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
    if [ "$cache_age" -ge 0 ] && [ "$cache_age" -lt 60 ]; then
        cat "$cache_file"
        return 0
    fi
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
        { read -r selected_index < "$c"; } 2>/dev/null || true
    fi
}
cleanup_wrapper() {
    rm -rf "$CACHE_DIR" 2>/dev/null
    if command -v cleanup_terminal >/dev/null 2>&1; then
        cleanup_terminal
    fi
}
trap cleanup_wrapper EXIT
trap 'cleanup_wrapper; exit 130' INT TERM
find_local_config() {
    set +e
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/$LOCAL_CONFIG" ]; then
            echo "$d/$LOCAL_CONFIG"
            set -e
            return 0
        fi
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    set -e
    return 1
}
find_named_config() {
    local name="$1"
    set +e
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/.tasks.$name" ]; then
            echo "$d/.tasks.$name"
            set -e
            return 0
        fi
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    set -e
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
        names+=("${base#.tasks.}")
    done
    if [ ${#names[@]} -gt 0 ]; then
        printf "%s\n" "${names[@]}" | sort -u
    fi
}
init_profile() {
    local name="$1"
    [ -z "$name" ] && { echo "Error: profile name required"; return 1; }
    local profile_file="$PWD/.tasks.$name"
    [ -f "$profile_file" ] && { echo "Profile $name already exists at $profile_file"; return 1; }
    echo "Creating profile: $name"
    cat > "$profile_file" << 'EOF'
0|Task Name|command|Description here
0|Another Task|echo "Hello"|Runs a simple command
EOF
    sed -i '' "s/{NAME}/$name/g" "$profile_file" 2>/dev/null || sed -i "s/{NAME}/$name/g" "$profile_file"
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
    while IFS='|' read -r level name cmd desc || [ -n "$level" ]; do
        line_no=$((line_no + 1))
        [[ "$level" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$level" ]] && continue
        if [ -z "$name" ] || [ -z "$cmd" ]; then
            echo "  Line $line_no: Invalid format (missing fields)"
            errors=$((errors + 1))
            syntax_ok=false
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
list_profiles_all() {
    local mode="${1:-text}"
    local profiles_str
    profiles_str=$(list_available_profiles)
    if [ -z "$profiles_str" ]; then
        echo "No profiles found"
        return 0
    fi
    if [ "$mode" = "json" ]; then
        echo "{"
        echo "  \"profiles\": ["
        local first=1
        while IFS= read -r prof; do
            [ "$first" -eq 0 ] && echo ","
            first=0
            echo "    { \"name\": \"$prof\" }"
        done <<< "$profiles_str"
        echo ""
        echo "  ]"
        echo "}"
    else
        echo "Available profiles:"
        echo ""
        while IFS= read -r prof; do
            echo "  • $prof"
        done <<< "$profiles_str"
    fi
}
load_profile_config() {
    local profile_name="$1"
    local saved_mode="$active_mode"
    local saved_config_path="$config_path"
    active_mode="global"
    config_path="$HOME/.tasks.$profile_name"
    if [ ! -f "$config_path" ]; then
        active_mode="$saved_mode"
        config_path="$saved_config_path"
        return 1
    fi
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
    IFS=$'\n' read -r -d '' -a profiles < <(list_available_profiles && printf '\0') || true
    local num=${#profiles[@]}
    [ "$num" -eq 0 ] && return 1
    [ ! -t 0 ] && return 1
    local page=0
    local per_page=9
    local filter_pattern=""
    local filter_active=0
    while true; do
        if [ "$filter_active" -eq 1 ] && [ -n "$filter_pattern" ]; then
            filtered_profiles=()
            for prof in "${profiles[@]}"; do
                if [[ "$prof" == *"$filter_pattern"* ]]; then
                    filtered_profiles+=("$prof")
                fi
            done
            local display_profiles=("${filtered_profiles[@]}")
            local display_num=${#display_profiles[@]}
        else
            local display_profiles=("${profiles[@]}")
            local display_num=${#display_profiles[@]}
        fi
        local max_pages=$(( (display_num + per_page - 1) / per_page ))
        [ "$page" -ge "$max_pages" ] && page=$((max_pages - 1))
        [ "$page" -lt 0 ] && page=0
        clear
        echo -e "${COLOR_HEAD}Profiles${COLOR_RESET}"
        if [ "$filter_active" -eq 1 ]; then
            echo -e "${COLOR_INFO}Filter: ${filter_pattern}_${COLOR_RESET} (ESC to clear)"
        fi
        echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
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
            p) [ "$page" -gt 0 ] && page=$((page - 1)) ;;
            n) [ "$end" -lt "$display_num" ] && page=$((page + 1)) ;;
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
                       *) [[ "$k" =~ [[:print:]] ]] && filter_pattern="${filter_pattern}${k}" ;;
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
SEARCH_HISTORY_FILE="$HOME/.run_search_history"
SEARCH_HISTORY_MAX=20
save_search_term() {
    local term="$1"
    [ -z "$term" ] && return
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
        grep -vxF "$term" "$SEARCH_HISTORY_FILE" > "${SEARCH_HISTORY_FILE}.tmp" 2>/dev/null || true
        mv "${SEARCH_HISTORY_FILE}.tmp" "$SEARCH_HISTORY_FILE" || true
    fi
    echo "$term" >> "$SEARCH_HISTORY_FILE"
    trim_file_to_lines "$SEARCH_HISTORY_FILE" "$SEARCH_HISTORY_MAX"
}
get_search_history() {
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
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
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
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
                    history_pos=$((history_pos + 1))
                    [ "$history_pos" -ge ${#history_items[@]} ] && history_pos=$((${#history_items[@]} - 1))
                    current_query="${history_items[$history_pos]}"
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                fi
                ;;
            $'\x1b[B'|$'\x1bOB')
                if [ "$history_pos" -gt 0 ]; then
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
extract_tags() {
    local desc="$1"
    local result=""
    local rest="$desc"
    while [[ "$rest" =~ (#[a-zA-Z0-9_-]+) ]]; do
        local _tag="${BASH_REMATCH[1]}"
        result+="$_tag "
        rest="${rest#*"$_tag"}"
    done
    printf '%s' "$result"
}
has_tag() {
    local desc="$1"
    local tag="$2"
    [[ "$desc" =~ $tag ]]
}
get_all_tags() {
    local -a tags=()
    while IFS='|' read -r level name cmd desc; do
        local task_tags
        task_tags=$(extract_tags "$desc")
        for tag in $task_tags; do
            tags+=("$tag")
        done
    done < <(
        if [ "${#task_config_files[@]}" -gt 0 ]; then
            cat "${task_config_files[@]}" 2>/dev/null || true
        elif [ -f "$config_path" ]; then
            cat "$config_path"
        fi
    )
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
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo "0) ${COLOR_SEL}[All Tasks]${COLOR_RESET}"
    for (( i=0; i<num_tags; i++ )); do
        if [ "$tag_filter" == "${all_tags[$i]}" ]; then
            printf "%d) ${COLOR_SEL}✓ %s${COLOR_RESET}\n" "$((i+1))" "${all_tags[$i]}"
        else
            printf "%d) %s\n" "$((i+1))" "${all_tags[$i]}"
        fi
    done
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo "[1-9] Filter [q]uit"
    while true; do
        key=$(read_key) || break
        case "$key" in
            "0")
                tag_filter=""
                echo -e "${COLOR_SEL}✔ Showing all tasks${COLOR_RESET}"
                sleep 0.5
                break
                ;;
            [1-9])
                local idx=$((key - 1))
                if [ "$idx" -lt "$num_tags" ]; then
                    tag_filter="${all_tags[$idx]}"
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
readonly RUN_FAVORITES_FILE="$HOME/.run_favorites"
is_favorite() {
    local task_name="$1"
    if [ -f "$RUN_FAVORITES_FILE" ]; then
        grep -qxF "$task_name" "$RUN_FAVORITES_FILE" || return 1
    else
        return 1
    fi
}
toggle_favorite() {
    local task_name="$1"
    if is_favorite "$task_name"; then
        if grep -vxF "$task_name" "$RUN_FAVORITES_FILE" > "${RUN_FAVORITES_FILE}.tmp"; then
            mv "${RUN_FAVORITES_FILE}.tmp" "$RUN_FAVORITES_FILE"
        fi
        echo -e "${COLOR_INFO}⭐ Removed from favorites${COLOR_RESET}"
    else
        echo "$task_name" >> "$RUN_FAVORITES_FILE"
        echo -e "${COLOR_SEL}⭐ Added to favorites!${COLOR_RESET}"
    fi
    sleep 0.5
}
show_favorites() {
    clear
    echo -e "${COLOR_HEAD}⭐ Favorite Tasks${COLOR_RESET}"
    local -a fav_list=()
    if [ -f "$RUN_FAVORITES_FILE" ] && [ -s "$RUN_FAVORITES_FILE" ]; then
        while IFS= read -r _fline || [ -n "$_fline" ]; do
            [ -n "$_fline" ] && fav_list+=("$_fline")
        done < "$RUN_FAVORITES_FILE"
    fi
    if [ "${#fav_list[@]}" -eq 0 ]; then
        echo -e "${COLOR_DIM}No favorites yet. Press [*] on a task to add it!${COLOR_RESET}"
    else
        echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
        local idx=1
        for _fav in "${fav_list[@]}"; do
            if [ "$idx" -le 9 ]; then
                printf "%d) ${COLOR_SEL}%s${COLOR_RESET}\n" "$idx" "$_fav"
            else
                printf "  ${COLOR_DIM}%s${COLOR_RESET}\n" "$_fav"
            fi
            idx=$((idx + 1))
        done
    fi
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "\n[1-9] Execute [q]uit"
    while true; do
        key=$(read_key) || break
        if [[ "$key" =~ [1-9] ]]; then
            local sel=$((key - 1))
            local fav_name="${fav_list[$sel]:-}"  # Array-Index statt sed-Fork
            if [ -n "$fav_name" ]; then
                if find_task_in_menu "$fav_name" "_execute_fav_callback"; then
                    clear
                    return 0
                else
                    echo -e "${COLOR_ERR}Task not found in current profile${COLOR_RESET}"
                    sleep 1
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
add_to_history() {
    local task_name="$1"
    local exit_code="$2"
    local exec_time="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local status="✔"
    [ "$exit_code" -ne 0 ] && status="✗"
    echo "$timestamp | $status | $task_name | exit:$exit_code | time:${exec_time}s" >> "$RUN_HISTORY_FILE"
    trim_file_to_lines "$RUN_HISTORY_FILE" "$RUN_HISTORY_MAX"
    add_to_recent "$task_name" "$exec_time"
}
show_history() {
    clear
    echo -e "${COLOR_HEAD}$(msg history_label)${COLOR_RESET}"
    if [ ! -f "$RUN_HISTORY_FILE" ] || [ ! -s "$RUN_HISTORY_FILE" ]; then
        echo -e "${COLOR_DIM}$(msg history_empty)${COLOR_RESET}"
    else
        local lastlines
        lastlines=$(tail -20 "$RUN_HISTORY_FILE")
        while IFS= read -r line; do
            local _s="${line#*| }"
            _s="${_s%% |*}"
            if [ "$_s" = "✔" ]; then
                echo -e "${COLOR_SEL}$line${COLOR_RESET}"
            else
                echo -e "${COLOR_ERR}$line${COLOR_RESET}"
            fi
        done <<< "$lastlines"
    fi
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    consume_keypress
}
add_to_recent() {
    local task_name="$1"
    local exec_time="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp|$config_path|$task_name|${exec_time}s" >> "$RUN_RECENT_FILE"
    trim_file_to_lines "$RUN_RECENT_FILE" "$RUN_RECENT_MAX"
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
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    local -a lines=()
    IFS=$'\n' read -r -d '' -a lines < <(tail -n 20 "$RUN_RECENT_FILE" 2>/dev/null && printf '\0') || true
    local idx=1
    for line in "${lines[@]}"; do
        IFS='|' read -r _ path name rest <<< "$line"
        local short_path="${path##*/}"
        [ "$idx" -le 9 ] && printf "%d) ${COLOR_SEL}%s${COLOR_RESET} ${COLOR_DIM}(%s)${COLOR_RESET}\n" "$idx" "$name" "$short_path" || printf "  ${COLOR_DIM}%s (%s)${COLOR_RESET}\n" "$name" "$short_path"
        idx=$((idx + 1))
    done
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "\n[1-9] Execute [q]uit"
    while true; do
        key=$(read_key) || break
        if [[ "$key" =~ [1-9] ]]; then
            local sel=$((key - 1))
            local entry="${lines[$sel]}"
            if [ -n "$entry" ]; then
                IFS='|' read -r _ path name rest <<< "$entry"
                if [ -f "$path" ]; then
                    local prev_config="$config_path"
                    local prev_mode="$active_mode"
                    config_path="$path"
                    if find_task_in_menu "$name" "_execute_recent_callback"; then
                        clear
                        return 0
                    else
                        echo -e "${COLOR_ERR}Task not found: $name${COLOR_RESET}"
                        sleep 1
                    fi
                    config_path="$prev_config"
                    active_mode="$prev_mode"
                else
                    echo -e "${COLOR_ERR}Profile not found: $path${COLOR_RESET}"
                    sleep 1
                fi
            fi
        elif [[ "$key" == "q" ]] || [[ "$key" == "Q" ]] || [[ "$key" == $'\x1b' ]]; then
            break
        fi
    done
    clear
}
_execute_recent_callback() {
    local name="$1"
    local cmd="$2"
    local desc="$3"
    execute_task "$cmd" "$name" "$desc"
}
show_logs() {
    clear
    echo -e "${COLOR_HEAD}Recent Logs${COLOR_RESET}"
    echo -e "${COLOR_DIM}Last 9 log files:${COLOR_RESET}"
    echo ""
    local -a log_files=()
    IFS=$'\n' read -r -d '' -a log_files < <(find "$RUN_LOG_DIR" -type f -name "*.log" 2>/dev/null | sort -r | head -9 && printf '\0') || true
    if [ ${#log_files[@]} -eq 0 ]; then
        echo -e "${COLOR_DIM}No log files found.${COLOR_RESET}"
    else
        local idx=1
        for log_file in "${log_files[@]}"; do
            echo "$idx) ${log_file##*/}"
            idx=$((idx + 1))
        done
        echo ""
        echo "[1-9] View [q]uit"
        while true; do
            key=$(read_key) || break
            if [[ "$key" =~ [1-9] ]]; then
                local sel=$((key - 1))
                if [ "$sel" -lt "${#log_files[@]}" ]; then
                    clear
                    echo -e "${COLOR_HEAD}Log: $(basename "${log_files[$sel]}")${COLOR_RESET}"
                    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                    cat "${log_files[$sel]}"
                    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
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
parse_task_deps() {
    local task_cmd="$1"
    if [[ "$task_cmd" =~ \[depends:([^\]]+)\] ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}
execute_task_deps() {
    local deps_str="$1"
    local IFS=','
    local -a deps
    read -r -a deps <<< "$deps_str"
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    if [ "${RUN_PARALLEL_DEPS:-0}" = "1" ] && [ "${#deps[@]}" -gt 1 ]; then
        echo -e "${COLOR_DIM}  (running ${#deps[@]} dependencies in parallel)${COLOR_RESET}"
        local -a dep_pids=()
        local -a dep_names=()
        local -a dep_logs=()
        for dep in "${deps[@]}"; do
            dep=$(trim_whitespace "$dep")
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"
            local dep_log="${CACHE_DIR}/dep_${dep}_$$.log"
            dep_logs+=("$dep_log")
            dep_names+=("$dep")
            (
                if ! find_task_in_menu "$dep" '_execute_dep_callback' 2>&1 | tee "$dep_log"; then
                    exit 1
                fi
            ) &
            dep_pids+=("$!")
        done
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
        for log in "${dep_logs[@]}"; do
            [ -f "$log" ] && rm -f "$log"
        done
        [ "$all_success" -eq 0 ] && return 1
        return 0
    else
        for dep in "${deps[@]}"; do
            dep=$(trim_whitespace "$dep")
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"
            if ! find_task_in_menu "$dep" '_execute_dep_callback'; then
                echo -e "${COLOR_ERR}❌ Dependency '$dep' not found in:${COLOR_RESET}"
                for cf in "${task_config_files[@]}"; do echo -e "  ${COLOR_DIM}$cf${COLOR_RESET}"; done
                return 1
            fi
        done
    fi
}
_execute_dep_callback() {
    local dep_name="$1"
    local dep_cmd="$2"
    local dep_desc="$3"
    execute_task "$dep_cmd" "$dep_name" "$dep_desc" || return 1
}
execute_multi_profile_task() {
    local task_name="$1"
    local profiles_str="$2"  # comma-separated
    local IFS=','
    local -a profiles
    read -r -a profiles <<< "$profiles_str"
    echo -e "${COLOR_HEAD}Running task across ${#profiles[@]} profiles:${COLOR_RESET}"
    if [ "${RUN_PARALLEL_MULTI:-0}" = "1" ] && [ "${#profiles[@]}" -gt 1 ]; then
        echo -e "${COLOR_DIM}  (running in parallel)${COLOR_RESET}"
        local -a profile_pids=()
        local -a profile_names=()
        local -a profile_logs=()
        for prof in "${profiles[@]}"; do
            prof=$(trim_whitespace "$prof")
            echo -e "  ${COLOR_DIM}→ [$prof] $task_name${COLOR_RESET}"
            local prof_log="${CACHE_DIR}/multi_prof_${prof}_$$.log"
            profile_logs+=("$prof_log")
            profile_names+=("$prof")
            (
                if ! load_profile_config "$prof"; then
                    echo -e "${COLOR_ERR}Failed to load profile: $prof${COLOR_RESET}" | tee "$prof_log"
                    exit 1
                fi
                if ! find_task_in_menu "$task_name" '_execute_profile_callback'; then
                    echo -e "${COLOR_ERR}Task not found in profile: $prof${COLOR_RESET}" | tee "$prof_log"
                    exit 1
                fi
            ) &
            profile_pids+=("$!")
        done
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
        for log in "${profile_logs[@]}"; do
            [ -f "$log" ] && rm -f "$log"
        done
        [ "$all_success" -eq 0 ] && return 1
        return 0
    else
        for prof in "${profiles[@]}"; do
            prof=$(trim_whitespace "$prof")
            echo -e "  ${COLOR_INFO}→ Profile: $prof${COLOR_RESET}"
            if ! load_profile_config "$prof"; then
                echo -e "${COLOR_ERR}Failed to load profile: $prof${COLOR_RESET}"
                return 1
            fi
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
    local total_tasks level_0 level_1 deps_count parallel_count \
          has_lint has_test has_build has_deploy test_count
    read -r total_tasks level_0 level_1 deps_count parallel_count \
             has_lint has_test has_build has_deploy test_count < <(
        awk '
            /^[0-9]/                           { tot++ }
            /^0\|/                             { l0++ }
            /^1\|/                             { l1++ }
            /depends:/                         { dep++ }
            /--parallel/                       { par++ }
            tolower($0) ~ /lint|eslint|pylint/ { lint++ }
            tolower($0) ~ /test|jest|pytest/   { tst++ }
            tolower($0) ~ /build|compile/      { bld++ }
            tolower($0) ~ /deploy|push|release/{ dpl++ }
            tolower($0) ~ /test/               { tc++ }
            END { print (tot+0),(l0+0),(l1+0),(dep+0),(par+0),(lint+0),(tst+0),(bld+0),(dpl+0),(tc+0) }
        ' "$config_file" 2>/dev/null
    )
    echo -e "\n${COLOR_SEL}📊 Project Analysis${COLOR_RESET}"
    echo -e "${COLOR_DIM}─────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "${COLOR_INFO}📈 Statistics:${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Total Tasks:${COLOR_RESET} $total_tasks"
    echo -e "  ${COLOR_DIM}Main Tasks (Level 0):${COLOR_RESET} $level_0"
    [ "$level_1" -gt 0 ] && echo -e "  ${COLOR_DIM}Sub Tasks (Level 1):${COLOR_RESET} $level_1"
    echo -e "  ${COLOR_DIM}Tasks with Dependencies:${COLOR_RESET} $deps_count"
    echo -e "  ${COLOR_DIM}Parallel-ready Tasks:${COLOR_RESET} $parallel_count"
    echo ""
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
        echo -e "     ${COLOR_DIM}• 1|Test|npm run test depends:0|Test (after build)${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• 2|Deploy|npm deploy depends:1|Deploy (after test)${COLOR_RESET}"
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
    echo -e "${COLOR_INFO}✓ Quality Score:${COLOR_RESET}"
    [ "$has_lint" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Linting${COLOR_RESET} (code quality)" || echo -e "  ✗ ${COLOR_DIM}Linting${COLOR_RESET} (code quality) - consider adding"
    [ "$has_test" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Testing${COLOR_RESET} (test coverage)" || echo -e "  ✗ ${COLOR_DIM}Testing${COLOR_RESET} (test coverage) - consider adding"
    [ "$has_build" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Building${COLOR_RESET} (production ready)" || echo -e "  ✗ ${COLOR_DIM}Building${COLOR_RESET} (production ready) - consider adding"
    [ "$has_deploy" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Deployment${COLOR_RESET} (automation)" || echo -e "  ✗ ${COLOR_DIM}Deployment${COLOR_RESET} (automation) - consider adding"
    echo ""
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
    echo -e "${COLOR_INFO}📚 Next Steps:${COLOR_RESET}"
    echo -e "  • Run: ${COLOR_DIM}run${COLOR_RESET}  (use interactive menu)"
    echo -e "  • Edit: ${COLOR_DIM}run --edit${COLOR_RESET}  (edit .tasks file)"
    echo -e "  • Validate: ${COLOR_DIM}run --validate${COLOR_RESET}  (check syntax)"
    echo -e "  • Documentation: ${COLOR_DIM}docs/ADVANCED_USAGE.md${COLOR_RESET}  (learn patterns)"
    echo -e "${COLOR_DIM}─────────────────────────────────────────────────────────────${COLOR_RESET}\n"
    return 0
}
find_task_in_menu() {
    local search_name="$1"
    local callback="$2"
    local -a opts
    IFS=$'\n' read -d '' -r -a opts < <(get_menu_options) || true
    for opt in "${opts[@]}"; do
        IFS='|' read -r _level opt_name opt_cmd opt_desc <<< "$opt"
        if [ "$opt_name" = "$search_name" ]; then
            "$callback" "$opt_name" "$opt_cmd" "$opt_desc"
            return 0
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
    echo -e "${COLOR_DIM}──────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "${COLOR_INFO}Description:${COLOR_RESET}"
    echo -e "  $desc\n"
    echo -e "${COLOR_INFO}Command to execute:${COLOR_RESET}"
    echo -e "  ${COLOR_SEL}$cmd${COLOR_RESET}\n"
    if [[ "$desc" == "[!]"* ]]; then
        echo -e "${COLOR_WARN}⚠ Requires confirmation${COLOR_RESET}\n"
    fi
    if [[ "$cmd" == *'<<'* ]]; then
        echo -e "${COLOR_INFO}ℹ This task has inputs that will be prompted${COLOR_RESET}\n"
    fi
    local deps
    deps=$(parse_task_deps "$cmd")
    if [ -n "$deps" ]; then
        echo -e "${COLOR_INFO}Dependencies:${COLOR_RESET}"
        local IFS=','
        local -a dep_arr
        read -r -a dep_arr <<< "$deps"
        for d in "${dep_arr[@]}"; do
            echo -e "  ${COLOR_DIM}→ $d${COLOR_RESET}"
        done
        echo ""
    fi
    echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    consume_keypress
}
select_dropdown() {
    local options_str="$1"
    local -a options=()
    local -a _raw_opts
    IFS=',' read -r -a _raw_opts <<< "$options_str"
    local _opt
    for _opt in "${_raw_opts[@]}"; do
        [ -n "$_opt" ] && options+=("$_opt")
    done
    local selected=0
    local num=${#options[@]}
    while true; do
        if [ "${HAS_TPUT:-0}" -eq 1 ] && [ -n "${TPUT_CUP:-}" ]; then
            echo -ne "$TPUT_CUP"
        else
            clear
        fi
        echo -e "${COLOR_HEAD}$(msg select_option)${COLOR_RESET}"
        for (( i=0; i<num; i++ )); do
            if [ "$i" -eq "$selected" ]; then
                echo -e "${COLOR_SEL}›${COLOR_RESET} ${options[$i]}"
            else
                echo "  ${options[$i]}"
            fi
        done
        echo -e "\n${COLOR_DIM}$(msg dropdown_hint)${COLOR_RESET}"
        [ "${HAS_TPUT:-0}" -eq 1 ] && [ -n "${TPUT_ED:-}" ] && echo -ne "$TPUT_ED"
        key=$(read_key) || return 1
        case "$key" in
            $'\x1b[A'|$'\x1bOA') selected=$((selected - 1));;
            $'\x1b[B'|$'\x1bOB') selected=$((selected + 1));;
            $'\x1b') return 1;; # Pure Escape = cancel
            "k") selected=$((selected - 1));; "j") selected=$((selected + 1));;
            "") echo "${options[$selected]}"; return 0;;
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
    printf -v bar_filled '%*s' "$filled" ''
    printf -v bar_empty  '%*s' "$empty"  ''
    printf "%s[%s%s] %3d%%${COLOR_RESET}" \
        "$COLOR_SEL" "${bar_filled// /=}" "${bar_empty// /-}" "$percent"
}
process_progress_output() {
    local line="$1"
    if [[ "$line" =~ \[progress:([0-9]+)%\] ]]; then
        local percent="${BASH_REMATCH[1]}"
        render_progress_bar "$percent"
        echo ""
        return 0  # Suppress original line
    fi
    if [[ "$line" =~ \[progress:([0-9]+)/([0-9]+)\] ]]; then
        local current="${BASH_REMATCH[1]}"
        local total="${BASH_REMATCH[2]}"
        local percent=$((current * 100 / total))
        render_progress_bar "$percent"
        echo ""
        return 0  # Suppress original line
    fi
    echo "$line"
    return 0  # 0 statt 1: stabiler bei set -e, semantisch korrekt (kein Fehler)
}
execute_task_pipeline() {
    local task_cmd="$1"
    local steps_str="${task_cmd#tasks:}"
    local IFS=';'
    local -a steps
    read -r -a steps <<< "$steps_str"
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    for step in "${steps[@]}"; do
        step=$(trim_whitespace "$step")
        [ -z "$step" ] && continue
        echo -e "  ${COLOR_DIM}→ $step${COLOR_RESET}"
        if ! find_task_in_menu "$step" 'execute_task'; then
            echo -e "${COLOR_ERR}❌ Task '$step' not found in:${COLOR_RESET}"
            for cf in "${task_config_files[@]}"; do echo -e "  ${COLOR_DIM}$cf${COLOR_RESET}"; done
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
    local -a logs=()
    local started=0
    for idx in "${keys[@]}"; do
        IFS='|' read -r level name cmd desc <<< "${menu_options[$idx]}"
        if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
            continue
        fi
        if [[ "$desc" == "[!]"* ]] || [[ "$cmd" == *"<<"* ]] || [[ "$cmd" == tasks:* ]]; then
            echo -e "${COLOR_WARN}Skipping '$name' (interactive or pipeline).${COLOR_RESET}"
            continue
        fi
        local log_file
        log_file=$(create_log_file "$name")
        local start_time
        start_time=$(date +%s)
        (
            if command -v timeout >/dev/null 2>&1; then
                timeout "$task_timeout" env \
                    RUN_MODE="$active_mode" \
                    RUN_DIR="$(dirname "$config_path")" \
                    RUN_CMD="$cmd" \
                    bash -c '
                        [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
                        [ -f ".env" ] && set -a && source .env && set +a
                        eval "$RUN_CMD"
                    ' 2>&1 | tee "$log_file"
                exit "${PIPESTATUS[0]}"
            else
                env \
                    RUN_MODE="$active_mode" \
                    RUN_DIR="$(dirname "$config_path")" \
                    RUN_CMD="$cmd" \
                    bash -c '
                        [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
                        [ -f ".env" ] && set -a && source .env && set +a
                        eval "$RUN_CMD"
                    ' 2>&1 | tee "$log_file"
                exit "${PIPESTATUS[0]}"
            fi
        ) &
        pids+=("$!")
        names+=("$name")
        starts+=("$start_time")
        logs+=("$log_file")
        started=$((started + 1))
    done
    if [ "$started" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tasks eligible for parallel run.${COLOR_RESET}"
        sleep 1
        return
    fi
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
        fi
    done
    stty sane 2>/dev/null || true
    stty -echo 2>/dev/null || true
    drain_stdin
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
}
execute_task() {
    local cmd="$1"; local name="$2"; local desc="$3"; shift 3; local args=("$@")
    dry_run_mode=0  # Reset dry-run flag
    if [ "$is_interactive" -eq 1 ]; then
        if ! preview_task "$cmd" "$name" "$desc"; then
            return  # User cancelled
        fi
    fi
    if [[ "$cmd" == tasks:* ]]; then
        execute_task_pipeline "$cmd"
        return $?
    fi
    if [ "$is_interactive" -eq 1 ]; then
        tput cnorm 2>/dev/null
    fi
    clear 
    echo -e "${COLOR_HEAD}$(msg executing)${COLOR_RESET} $name"
    if [[ "$desc" == "[!]"* ]]; then
        echo -e "\n${COLOR_WARN}⚠ $(msg warning_label): ${desc#"[!] "}${COLOR_RESET}"
        read -p "$(msg confirm_prompt) " -n 1 -r; echo ""; [[ ! $REPLY =~ ^[Yy]$ ]] && return
    fi
    local deps
    deps=$(parse_task_deps "$cmd")
    if [ -n "$deps" ]; then
        execute_task_deps "$deps" || return 1
        cmd="${cmd%% \[depends:*\]}"
    fi
    while [[ "$cmd" =~ \<\<([^:>]+)(:[^>]*)?\>\> ]]; do
        local p="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}" 
        if [[ "$rest" == :* ]]; then
            local opts_str="${rest:1}"
            echo -e "\n${COLOR_INFO}$(msg choose_for)${COLOR_RESET} $p"
            local r
            r=$(select_dropdown "$opts_str")
            cmd="${cmd//\<\<"$p":"$opts_str"\>\>/$r}"
        else
            echo -e "\n${COLOR_INFO}$(msg input_for)${COLOR_RESET} $p"; read -r -p "> " r; cmd="${cmd//<<$p>>/$r}"
        fi
    done
    set +u; echo -e "${COLOR_DIM}> $cmd ${args[*]:-}${COLOR_RESET}\n"; set -u
    save_state
    if [ "$dry_run_mode" -eq 1 ]; then
        echo -e "${COLOR_INFO}🔍 DRY-RUN: Command would execute as above${COLOR_RESET}"
        echo -e "${COLOR_DIM}(No actual execution)${COLOR_RESET}\n"
        echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
        return 0
    fi
    local start_time
    start_time=$(date +%s)
    :
    local exit_status=0
    local log_file
    log_file=$(create_log_file "$name")
    local temp_output=""
    temp_output=$(mktemp)
    trap '[[ -n "${temp_output:-}" ]] && rm -f "$temp_output"' RETURN
    local config_dir
    config_dir=$(dirname "$config_path")
    local first_token="${cmd%% *}"
    if [ -n "$first_token" ] && ! command -v "$first_token" >/dev/null 2>&1 && [[ "$first_token" != */* ]]; then
        echo -e "\n${COLOR_ERR}Invalid task command: '$first_token' — skipping execution.${COLOR_RESET}"
        exit_status=127
    else
        local _exec_script='
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            [ -f ".env" ] && set -a && source .env && set +a
            eval "$RUN_CMD $RUN_ARGS"
        '
        if command -v timeout >/dev/null 2>&1; then
            timeout "$task_timeout" env \
                RUN_MODE="$active_mode" \
                RUN_DIR="$config_dir" \
                RUN_CMD="$cmd" \
                RUN_ARGS="${args[*]:-}" \
                bash -c "$_exec_script" > "$temp_output" 2>&1
            exit_status=$?
            [ "$exit_status" -eq 124 ] && \
                echo -e "\n${COLOR_ERR}$(msg task_timeout) (${task_timeout}s).${COLOR_RESET}"
        else
            env \
                RUN_MODE="$active_mode" \
                RUN_DIR="$config_dir" \
                RUN_CMD="$cmd" \
                RUN_ARGS="${args[*]:-}" \
                bash -c "$_exec_script" > "$temp_output" 2>&1
            exit_status=$?
        fi
    fi
    exec 3>>"$log_file"
    while IFS= read -r line; do
        process_progress_output "$line"
        printf '%s\n' "$line" >&3
    done < "$temp_output"
    exec 3>&-
    local end_time
    end_time=$(date +%s)
    task_execution_time=$((end_time - start_time))
    if [ "$exit_status" -eq 0 ] || [ "$exit_status" -eq 124 ]; then
        if [ "$exit_status" -eq 124 ]; then
            echo -e "\n${COLOR_ERR}$(msg task_failed) (timeout).${COLOR_RESET}"
        else
            echo -e "\n${COLOR_SEL}✔ $(msg task_success)${COLOR_RESET}"
        fi
    else
        echo -e "\n${COLOR_ERR}$(msg task_failed) (exit $exit_status).${COLOR_RESET}"
    fi
    echo -e "${COLOR_DIM}⏱ ${task_execution_time}s${COLOR_RESET}"
    add_to_history "$name" "$exit_status" "$task_execution_time"
    echo -e "${COLOR_DIM}Log: $log_file${COLOR_RESET}"
    stty sane 2>/dev/null || true
    stty -echo 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    drain_stdin
    last_config_mtime=0
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
}
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
            export "$key"="$value"
        fi
    done < "$RUN_VARS_FILE"
}
load_task_vars() {
    set +e +o pipefail  # Disable errexit and pipefail for regex operations
    if [ ! -f "$config_path" ]; then
        set -e -o pipefail
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^VAR_[A-Za-z0-9_]+= ]] || continue
        local key="${line%%=*}"
        local value="${line#*=}"
        export "$key"="$value" 2>/dev/null || true
    done < "$config_path"
    set -e -o pipefail  # Re-enable errexit and pipefail
}
expand_env_vars() {
    local text="$1"
    local out="$text"
    local guard=0
    while [[ "$out" =~ (\$\{?[A-Za-z_][A-Za-z0-9_]*\}?) ]]; do
        local token="${BASH_REMATCH[1]}"
        local name="${token#\$}"
        name="${name#\{}"
        name="${name%\}}"
        local value="${!name-}"
        out="${out//$token/$value}"
        guard=$((guard + 1))
        [ "$guard" -gt 50 ] && break
    done
    printf '%s\n' "$out"
}
create_log_file() {
    local task_name="$1"
    mkdir -p "$RUN_LOG_DIR" 2>/dev/null || true
    local safe_name
    safe_name=$(sanitize_filename "$task_name")
    [ -z "$safe_name" ] && safe_name="task"
    echo "$RUN_LOG_DIR/$(date '+%Y-%m-%d_%H-%M-%S')_${safe_name}.log"
}
extract_field_from_grep() {
    local pattern="$1"
    local delimiter="$2"
    local field_idx="$3"
    if [ -f "$config_path" ]; then
        awk -F"$delimiter" -v pat="$pattern" -v idx="$field_idx" '$0 ~ pat {val=$idx; gsub(/^[ \t]+|[ \t]+$/, "", val); print val; exit}' "$config_path" 2>/dev/null || true
    fi
}
calculate_layout() {
    local total="$1"
    local cols=1
    local rows="$total"
    local term_width="${TPUT_COLS:-80}"
    if [ "$total" -gt 12 ] && [ "$term_width" -ge 120 ] && [ "$COLS_MAX" -ge 3 ]; then
        cols=3
        rows=$(( (total + cols - 1) / cols ))
    elif [ "$total" -gt 6 ] && [ "$term_width" -ge 100 ] && [ "$COLS_MAX" -ge 2 ]; then
        cols=2
        rows=$(( (total + cols - 1) / cols ))
    fi
    [ "$cols" -lt "$COLS_MIN" ] && cols="$COLS_MIN"
    [ "$cols" -gt "$COLS_MAX" ] && cols="$COLS_MAX"
    _layout_rows=$rows
    _layout_cols=$cols
}
show_help_panel() {
    clear
    cat << EOF
${COLOR_HEAD}════════════════════════════════════════════════════════════════${COLOR_RESET}
${COLOR_HEAD}║                    SHELL MENU RUNNER v${VERSION}                 ║${COLOR_RESET}
${COLOR_HEAD}════════════════════════════════════════════════════════════════${COLOR_RESET}
${COLOR_SEL}Navigation:${COLOR_RESET}
  ↑/↓ or j/k      Navigate tasks
  ←/→ or h/l      Multi-column navigation
  [Enter]         Execute selected task
  [1-9]           Quick execute (hotkey)
  [Space]         Multi-select (execute multiple)
  [ESC] or q      Exit / Go back
${COLOR_SEL}Features:${COLOR_RESET}
  /               Search/filter tasks
  g               Toggle local/global config
  p               Switch profile
  s               Settings menu
  e               Edit config
  f               File browser
  *               Toggle favorite
  r               Show recent tasks
  !               Show history
  a               Alias editor
  ?               This help
${COLOR_SEL}Profiles:${COLOR_RESET}
  run [profile]   Load specific profile
  run --list      List all profiles
  run --init      Initialize new .tasks config
${COLOR_DIM}Press any key to continue...${COLOR_RESET}
EOF
    consume_keypress
}
get_menu_options() {
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -n "$cached_menu_options" ]; then
        if [ -f "$config_path" ]; then
            local current_mtime
            current_mtime=$(get_file_mtime "$config_path")
            if [ "$current_mtime" -eq "$last_config_mtime" ] && [ -z "$filter_query" ] && [ -z "$tag_filter" ]; then
                echo "$cached_menu_options"
                return 0
            fi
        fi
    fi
    local level_str=""
    local search_pattern=""
    local tag_pattern=""
    if [ "$current_level" -gt 0 ]; then
        level_str="${history_name_stack[$current_level]}"
    fi
    if [ -n "$filter_query" ]; then
        search_pattern=$(tr '[:upper:]' '[:lower:]' <<< "$filter_query")
    fi
    if [ -n "$tag_filter" ]; then
        tag_pattern="$tag_filter"
    fi
    local result=""
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^TIMEOUT= ]] && continue
        [[ "$line" =~ ^VAR_ ]] && continue
        [[ "$line" =~ ^THEME: ]] && continue
        [[ "$line" =~ ^TITLE: ]] && continue
        IFS='|' read -r level name cmd desc <<< "$line"
        [ -z "$name" ] && continue
        if [ "$current_level" -eq 0 ]; then
            [ "$level" != "0" ] && continue
        else
            [ "$level" != "$((current_level))" ] && continue
            if [ -n "$level_str" ] && [[ ! "$name" =~ ^$level_str\. ]]; then
                continue
            fi
        fi
        if [ -n "$search_pattern" ]; then
            local search_text
            search_text=$(tr '[:upper:]' '[:lower:]' <<< "$name $desc")
            [[ ! "$search_text" =~ $search_pattern ]] && continue
        fi
        if [ -n "$tag_pattern" ]; then
            has_tag "$desc" "$tag_pattern" || continue
        fi
        result+="${level}|${name}|${cmd}|${desc}"$'\n'
    done < <(
        if [ "${#task_config_files[@]}" -gt 0 ]; then
            cat "${task_config_files[@]}" 2>/dev/null || true
        elif [ -f "$config_path" ]; then
            cat "$config_path"
        fi
    )
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -z "$filter_query" ] && [ -z "$tag_filter" ] && [ -f "$config_path" ]; then
        cached_menu_options="$result"
        last_config_mtime=$(get_file_mtime "$config_path")
    fi
    printf "%s" "$result"
}
draw_menu() {
    if [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_CUP" ]; then
        echo -ne "$TPUT_CUP"
    else
        clear
    fi
    hide_cursor
    local mode_indicator="[${active_mode}]"
    local profile_name=""
    if [ "$active_mode" = "global" ] && [ -f "$config_path" ]; then
        profile_name=$(basename "$config_path" .tasks)
        [ "$profile_name" != ".tasks" ] && mode_indicator="[${profile_name}]"
    fi
    echo -e "${COLOR_HEAD}════ Shell Menu Runner ${VERSION} ${mode_indicator} ════${COLOR_RESET}"
    if [ "$current_level" -gt 0 ]; then
        local breadcrumb=""
        for bname in "${history_name_stack[@]}"; do
            breadcrumb="${breadcrumb}${bname} > "
        done
        echo -e "${COLOR_DIM}${breadcrumb%> }${COLOR_RESET}"
    fi
    if [ -n "$filter_query" ]; then
        echo -e "${COLOR_INFO}📎 Filter: $filter_query${COLOR_RESET}"
    fi
    if [ -n "$tag_filter" ]; then
        echo -e "${COLOR_INFO}🏷  Tag: $tag_filter${COLOR_RESET}"
    fi
    echo ""
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tasks found. Press 'e' to edit config or '?' for help.${COLOR_RESET}"
        return
    fi
    calculate_layout "$total"
    local rows=$_layout_rows cols=$_layout_cols
    for ((r=0; r<rows; r++)); do
        for ((c=0; c<cols; c++)); do
            local idx=$((r + c * rows))
            [ "$idx" -ge "$total" ] && continue
            IFS='|' read -r level name cmd desc <<< "${menu_options[$idx]}"
            local marker="  "
            local color="$COLOR_RESET"
            if [ "$idx" -eq "$selected_index" ]; then
                marker="► "
                color="$COLOR_SEL"
            fi
            if [ -n "${multi_select_map[$idx]:-}" ]; then
                marker="☑ "
            fi
            local max_len=35
            if [ "${#name}" -gt "$max_len" ]; then
                name="${name:0:$((max_len-3))}..."
            fi
            printf "%s%s%-${max_len}s%s  " "$color" "$marker" "$name" "$COLOR_RESET"
        done
        echo ""
    done
    echo ""
    echo -e "${COLOR_DIM}[↑↓] Navigate | [Enter] Execute | [/] Search | [Space] Multi-Select | [?] Help${COLOR_RESET}"
    if [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ]; then
        echo -ne "$TPUT_ED"
    fi
}
_reload_menu() {
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    calculate_layout "${#menu_options[@]}"
}
_reinit_menu() {
    parse_config_vars
    load_settings
    load_state
    detect_config_files
    load_aliases
    _reload_menu
}
run_with_term_paused() {
    restore_term
    "$@"
    if [ "${is_interactive:-0}" -eq 1 ]; then
        set_raw_mode
        drain_stdin  # flush any escape sequence tails from the secondary screen
    fi
}
main_interactive_loop() {
    set +e
    _reload_menu
    local num=${#menu_options[@]}
    local rows=$_layout_rows cols=$_layout_cols
    local redraw_needed=1
    local old_stty=""
    restore_term() {
        [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null
    }
    if [ "$is_interactive" -eq 1 ]; then
        old_stty=$(stty -g 2>/dev/null)
        set_raw_mode
        trap 'restore_term; cleanup_wrapper; exit 130' INT TERM
    fi
    while true; do
        if [ "$redraw_needed" -eq 1 ]; then
            draw_menu
            redraw_needed=0
        fi
        local key=""
        if [ "$is_interactive" -eq 1 ]; then
            key=$(read_key_raw) || key=""
        else
            read -r key || break
        fi
        case "$key" in
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
                if [[ -n "${multi_select_map[$selected_index]:-}" ]]; then
                    unset 'multi_select_map[$selected_index]'
                else
                    multi_select_map["$selected_index"]=1
                fi
                redraw_needed=1;;
            [1-9]) # Hotkey: direct execution by number
                local hotkey_idx=$((key - 1))
                if [ "$hotkey_idx" -lt "$num" ]; then
                    selected_index="$hotkey_idx"
                    IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
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
                _reinit_menu
                num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "p"|"P") # Profile selection
                restore_term
                if select_profile_menu; then
                    selected_index=0
                    current_level=0
                    history_name_stack=("Main")
                    _reinit_menu
                    num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                fi
                if [ "${is_interactive:-0}" -eq 1 ]; then
                    set_raw_mode
                    drain_stdin
                fi
                redraw_needed=1;;
            "s") run_with_term_paused settings_menu; redraw_needed=1;;
            "!") run_with_term_paused show_history; redraw_needed=1;;
            "a"|"A") run_with_term_paused show_alias_editor; redraw_needed=1;;
            "?") run_with_term_paused show_help_panel; redraw_needed=1;;
            $'\r'|$'\n'|"") # ENTER key (BUG-FIX: Accept both \r and \n)
                set +u
                [ ${#menu_options[@]} -eq 0 ] && { set -u; continue; }
                if [ ${#multi_select_map[@]} -gt 0 ]; then
                    set -u
                    restore_term
                    IFS=$'\n' read -r -d '' -a multi_keys < <(printf "%s\n" "${!multi_select_map[@]}" | sort -n && printf '\0') || true
                    for mi in "${multi_keys[@]}"; do
                        IFS='|' read -r level name cmd desc <<< "${menu_options[$mi]}"
                        [ "$cmd" == "EXIT" ] && continue
                        execute_task "$cmd" "$name" "$desc"
                    done
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
                IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
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
                redraw_needed=1;;
            "f"|"F") run_with_term_paused file_browser; redraw_needed=1;;
            "#") # Tag filter
                run_with_term_paused show_tag_menu
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "*") # Toggle favorite
                if [ "$selected_index" -lt "$num" ]; then
                    IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
                    toggle_favorite "$name"
                fi
                redraw_needed=1;;
            "r"|"R") run_with_term_paused show_favorites; redraw_needed=1;;
            "q"|"Q") restore_term; clear; exit 0;;
        esac
        local cnt=${#menu_options[@]}
        [ "$selected_index" -lt 0 ] && selected_index=$((cnt-1))
        [ "$selected_index" -ge "$cnt" ] && selected_index=0
    done
}
context_menu() {
    local num=${#menu_options[@]}
    [ "$num" -eq 0 ] && return
    [ "$selected_index" -ge "$num" ] && return
    IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
    if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
        echo -e "${COLOR_WARN}No context actions for this entry.${COLOR_RESET}"
        sleep 1
        return
    fi
    clear
    echo -e "${COLOR_HEAD}Context Menu: ${name}${COLOR_RESET}"
    echo -e "${COLOR_DIM}${desc}${COLOR_RESET}"
    echo ""
    echo "1) Copy name to clipboard"
    echo "2) Copy command to clipboard"
    echo "3) Copy description to clipboard"
    echo "0) Cancel"
    echo ""
    read -rsn1 choice
    case "$choice" in
        1) copy_to_clipboard "$name" ;;
        2) copy_to_clipboard "$cmd" ;;
        3) copy_to_clipboard "$desc" ;;
    esac
}
file_browser() {
    while true; do
        clear
        echo -e "${COLOR_HEAD}File Browser${COLOR_RESET}"
        echo -e "${COLOR_DIM}Current directory: $PWD${COLOR_RESET}"
        echo ""
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
                read -r filename
                if [ -z "$filename" ]; then
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
                method=$(read_key) || continue
                case "$method" in
                    "1")
                        ${EDITOR:-nano} "$filepath"
                        stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin
                        ;;
                    "2")
                        echo -e "${COLOR_INFO}Paste content (Ctrl+D to save):${COLOR_RESET}"
                        cat > "$filepath"
                        echo -e "${COLOR_SEL}✔ File created: $filename${COLOR_RESET}"
                        sleep 1
                        ;;
                esac
                ;;
            "2")
                [ -f ".tasks" ] && ${EDITOR:-nano} ".tasks" || echo -e "${COLOR_ERR}.tasks not found${COLOR_RESET}"
                stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin
                ;;
            "3")
                if [ -f ".env" ]; then
                    ${EDITOR:-nano} ".env"                    stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin                else
                    echo -e "\n${COLOR_INFO}Create .env? [y/N]${COLOR_RESET} "
                    read -n 1 -r REPLY
                    echo ""
                    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                        touch ".env"
                        ${EDITOR:-nano} ".env"
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
                    if [[ "$fkey" =~ [1-9] ]]; then
                        local fsel=$((fkey - 1))
                        if [ "$fsel" -lt "${#all_files[@]}" ]; then
                            ${EDITOR:-nano} "${all_files[$fsel]}"
                            stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin
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
                ${EDITOR:-nano} "$file"
                stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin
                ;;
            "2")
                clear
                echo -e "${COLOR_HEAD}Replace File Content${COLOR_RESET}"
                echo -e "${COLOR_INFO}Paste your content below, then press Ctrl+D (or Ctrl+Z on Windows)${COLOR_RESET}"
                echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                local tmp_file
                tmp_file=$(mktemp)
                cat > "$tmp_file"
                echo ""
                echo -e "${COLOR_WARN}Preview (first 10 lines):${COLOR_RESET}"
                head -10 "$tmp_file"
                echo ""
                read -p "Replace $file with this content? [y/N] " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    mv "$tmp_file" "$file"
                    echo -e "${COLOR_SEL}✔ File updated!${COLOR_RESET}"
                else
                    rm "$tmp_file"
                    echo -e "${COLOR_INFO}Cancelled.${COLOR_RESET}"
                fi
                sleep 1
                ;;
            "3")
                clear
                echo -e "${COLOR_HEAD}Current content:${COLOR_RESET}"
                echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                cat "$file"
                echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
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
EOF
            ${EDITOR:-nano} "$ALIAS_FILE"
            stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin
        fi
    else
        echo -e "${COLOR_DIM}Current aliases:${COLOR_RESET}"
        grep -Ev '^#|^[[:space:]]*$' "$ALIAS_FILE" || true
        echo ""
        echo "1) Edit aliases"
        echo "2) Add new alias"
        echo "0) Back"
        choice=$(read_key) || return
        case "$choice" in
            "1")
                ${EDITOR:-nano} "$ALIAS_FILE"
                stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin
                ;;
            "2")
                echo -e "\n${COLOR_INFO}Alias name:${COLOR_RESET}"
                read -r alias_name
                echo -e "${COLOR_INFO}Task name:${COLOR_RESET}"
                read -r task_name
                echo "${alias_name}=${task_name}" >> "$ALIAS_FILE"
                echo -e "${COLOR_SEL}✔ Alias added!${COLOR_RESET}"
                sleep 1
                ;;
        esac
    fi
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    consume_keypress
}
load_aliases() {
    if [ ! -f "$ALIAS_FILE" ]; then
        touch "$ALIAS_FILE"
    fi
}
resolve_alias() {
    local input="$1"
    if [ -f "$ALIAS_FILE" ]; then
        local resolved
        resolved=$(awk -F'=' -v a="$input" '$1 == a { print $2; exit }' "$ALIAS_FILE" 2>/dev/null || true)
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
                theme_choice=$(read_key) || continue
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
                col_val=$(read_key) || continue
                if [[ "$col_val" =~ [1-4] ]]; then
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
self_update() {
    echo -e "${COLOR_HEAD}$(msg update_check)${COLOR_RESET}"
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${COLOR_ERR}$(msg curl_missing)${COLOR_RESET}"
        return 1
    fi
    local tmp_file
    tmp_file=$(mktemp /tmp/run_update.XXXXXX) || { echo -e "${COLOR_ERR}$(msg temp_file_fail)${COLOR_RESET}"; return 1; }
    if curl -fsSL "$REPO_RAW_URL" -o "$tmp_file"; then
        if [ -n "$RUN_EXPECTED_SHA256" ]; then
            local dl_hash=""
            dl_hash=$(file_sha256 "$tmp_file") || echo -e "${COLOR_WARN}$(msg hash_skipped)${COLOR_RESET}"
            if [ -n "$dl_hash" ] && [ "$dl_hash" != "$RUN_EXPECTED_SHA256" ]; then
                echo -e "${COLOR_ERR}$(msg hash_mismatch) $RUN_EXPECTED_SHA256 != $dl_hash${COLOR_RESET}"
                rm -f "$tmp_file"
                return 1
            fi
        else
            echo -e "${COLOR_WARN}$(msg no_hash)${COLOR_RESET}"
            read -p "$(msg continue_prompt) " -n 1 -r; echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                rm -f "$tmp_file"
                return 1
            fi
        fi
        local new_ver=""
        new_ver=$(grep -m1 "readonly VERSION=" "$tmp_file" 2>/dev/null | cut -d'"' -f2 2>/dev/null || true)
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
            local install_path
            install_path=$(command -v run)
            if [ -z "$install_path" ]; then
                echo -e "${COLOR_ERR}$(msg install_path_missing)${COLOR_RESET}"
                rm -f "$tmp_file"
                return 1
            fi
            if [ -w "$install_path" ]; then
                mv "$tmp_file" "$install_path" && chmod +x "$install_path"
            else
                sudo mv "$tmp_file" "$install_path" && sudo chmod +x "$install_path"
            fi
            echo -e "${COLOR_SEL}✔ $(msg update_success) $new_ver${COLOR_RESET}"
            command -v run >/dev/null 2>&1 && echo -e "${COLOR_INFO}Aktuelle Version:${COLOR_RESET} $(run --version 2>/dev/null)"
        fi
    else
        echo -e "${COLOR_ERR}$(msg download_error)${COLOR_RESET}"
        rm -f "$tmp_file"
    fi
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
        if [ -d "$target_dir/.git" ]; then
            local git_tasks_file="$target_dir/.tasks.git"
            if [ ! -f "$git_tasks_file" ]; then
                echo -e "${COLOR_INFO}→ Git repo detected. Creating .tasks.git...${COLOR_RESET}"
                cat > "$git_tasks_file" <<'EOF'
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
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            local docker_tasks_file="$target_dir/.tasks.docker"
            if [ ! -f "$docker_tasks_file" ]; then
                echo -e "${COLOR_INFO}→ Docker Compose detected. Creating .tasks.docker...${COLOR_RESET}"
                cat > "$docker_tasks_file" <<'EOF'
0|🐳 Up|docker compose up -d|Start containers
0|🐳 Down|docker compose down|Stop containers
0|🐳 Logs|docker compose logs -f --tail=200|Follow logs
0|🐳 Restart|docker compose restart|Restart containers
0|🐳 Ps|docker compose ps|Show status
0|❌ Exit|EXIT|Back
EOF
            fi
        fi
        if [ -f "package.json" ]; then
            echo -e "${COLOR_INFO}→ $(msg node_detected)${COLOR_RESET}"
            local scripts
            scripts=$(sed -n '/"scripts": {/,/}/p' package.json | grep ":" | sed 's/^[[:space:]]*"//; s/":.*//' || true)
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
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            echo -e "${COLOR_INFO}→ $(msg docker_detected)${COLOR_RESET}"
            echo "0|🐳 Docker Up|docker compose up -d|Container starten" >> "$target"
            echo "0|🐳 Docker Down|docker compose down|Container stoppen" >> "$target"
        fi
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
        if [ -f "Makefile" ] || [ -f "makefile" ]; then
            echo "0|🛠 Make|make|Default target" >> "$target"
            echo "0|🛠 Make Test|make test|Run tests" >> "$target"
        fi
        if [ -f "go.mod" ]; then
            {
                echo "0|🐹 Go Build|go build ./...|Build modules"
                echo "0|🐹 Go Test|go test ./...|Run tests"
                echo "0|🐹 Go Run|go run .|Run module"
            } >> "$target"
        fi
        if [ -f "Cargo.toml" ]; then
            {
                echo "0|🦀 Cargo Build|cargo build|Build project"
                echo "0|🦀 Cargo Test|cargo test|Run tests"
                echo "0|🦀 Cargo Run|cargo run|Run project"
            } >> "$target"
        fi
        if [ -f "pom.xml" ]; then
            echo "0|☕ Maven Test|mvn test|Run tests" >> "$target"
            echo "0|☕ Maven Package|mvn package|Build package" >> "$target"
        fi
        if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
            echo "0|☕ Gradle Test|./gradlew test|Run tests" >> "$target"
            echo "0|☕ Gradle Build|./gradlew build|Build project" >> "$target"
        fi
        if [ -f "composer.json" ]; then
            echo "0|🐘 Composer Install|composer install|Install dependencies" >> "$target"
            echo "0|🐘 PHP Server|php -S localhost:8000 -t public|Dev server" >> "$target"
        fi
        if [ -f "Gemfile" ]; then
            echo "0|💎 Bundle Install|bundle install|Install gems" >> "$target"
            echo "0|💎 Rake Test|bundle exec rake test|Run tests" >> "$target"
        fi
        if compgen -G "*.tf" >/dev/null; then
            echo "0|🌍 Terraform Init|terraform init|Initialize" >> "$target"
            echo "0|🌍 Terraform Plan|terraform plan|Show plan" >> "$target"
        fi
        if [ "$(wc -l < "$target")" -lt 4 ]; then
            echo "0|🚀 Hello World|echo 'Edit .tasks to add commands'|Beispiel Task" >> "$target"
        fi
    fi
    echo "0|❌ Exit|EXIT|Menü beenden" >> "$target"
    echo -e "${COLOR_SEL}✔ $(msg init_done) '$target'.${COLOR_RESET}"
}
args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            echo "Usage: run [--init|--analyze|--global|--edit|--update|--debug] [profile]"
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
            echo "  run --init              Initialize .tasks in current dir"
            echo "  run --global            Switch to global mode"
            echo "  run --edit, -e          Edit config file"
            echo "  run --update            Update script to latest version"
            echo "  run --debug             Enable debug mode"
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
            multi_profiles="$1"
            shift
            multi_task="$1"
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
            init_profile "$1"
            exit 0
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
            analyze_project "$@"
            exit 0
            ;;
        --update)
            self_update
            exit 0
            ;;
        --global)
            active_mode="global"
            config_path="$GLOBAL_CONFIG"
            if [ ! -f "$config_path" ]; then
                smart_init "global" && exit 0
            fi
            shift
            ;;
        --edit|-e)
            [ -z "$config_path" ] && config_path="$LOCAL_CONFIG"
            edit_config_menu "$config_path"
            exit 0
            ;;
        *)
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
set +u  # Disable nounset for array check
if [ "${#args[@]}" -eq 0 ] && [ -z "$config_path" ]; then
    set -u  # Re-enable nounset
    profiles_list=$(list_available_profiles)
    if [ -n "$profiles_list" ]; then
        echo -e "${COLOR_INFO}Profiles available:${COLOR_RESET} ${profiles_list//$'\n'/ }"
        echo -e "${COLOR_DIM}Press [p] to choose a profile or any other key to continue...${COLOR_RESET}"
        key=$(read_key) || key=""
        sleep 0.1
        if [ "$key" = "p" ] || [ "$key" = "P" ]; then
            select_profile_menu || true
        fi
    fi
else
    set -u  # Re-enable nounset if condition was false
fi
set +u  # Disable nounset for array check
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
        echo -e "${COLOR_WARN}No .tasks file found.${COLOR_RESET}"
        exit 1
    fi
fi
parse_config_vars
load_settings
load_state
selected_index="${selected_index:-0}"
detect_config_files
load_aliases
check_interactive
check_ssh_session
if [ "$is_interactive" -eq 0 ] && [ "$is_ssh_session" -eq 1 ] && [ "$ssh_hint_shown" -eq 0 ]; then
    echo ""
    print_ssh_hint
    echo ""
    echo "Proceeding in non-interactive mode. Type task number to execute:"
    echo ""
    ssh_hint_shown=1
fi
IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
num=${#menu_options[@]}
calculate_layout "$num"; rows=$_layout_rows; cols=$_layout_cols
redraw_needed=1
main_interactive_loop
