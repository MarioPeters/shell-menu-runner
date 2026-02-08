#!/bin/bash

# ==============================================================================
#  SHELL MENU RUNNER v1.7.0 (Task Tags & Shell Completion)
#  GitHub: https://github.com/MarioPeters/shell-menu-runner
#  Lizenz: MIT
# ==============================================================================

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
readonly C_BOLD=$'\e[1m'

# --- PERFORMANCE FLAGS (can be set via environment) ---
RUN_PARALLEL_DEPS="${RUN_PARALLEL_DEPS:-0}"      # Enable parallel dependency execution
RUN_CACHE_PROFILES="${RUN_CACHE_PROFILES:-1}"   # Cache profile listings (60s TTL)
RUN_FAST_GREP="${RUN_FAST_GREP:-1}"             # Use optimized grep for large configs

set -euo pipefail

# --- THEME CONFIGURATION ---
COLOR_HEAD=$'\e[1;34m'; COLOR_SEL=$'\e[1;32m'; COLOR_ERR=$'\e[1;31m'
COLOR_WARN=$'\e[1;33m'; COLOR_INFO=$'\e[33m';  COLOR_DIM=$'\e[2m'
COLOR_RESET=$'\e[0m'

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
last_config_mtime=0
cached_menu_options=""
DEBUG_MODE=0

# --- SETTINGS STATE ---
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

# ==============================================================================
#  POLYFILLS & UTILS
# ==============================================================================

get_realpath() { command -v realpath &>/dev/null && realpath "$1" || echo "$PWD/${1#./}"; }
cleanup_terminal() { tput cnorm 2>/dev/null || true; echo -e "${COLOR_RESET}"; }
handle_interrupt() { cleanup_terminal; clear; exit 130; }
trap cleanup_terminal EXIT
trap handle_interrupt INT TERM
hide_cursor() { tput civis 2>/dev/null || true; }

# Color output helpers
info() { echo -e "${COLOR_INFO}$*${COLOR_RESET}"; }
warn() { echo -e "${COLOR_WARN}$*${COLOR_RESET}"; }
error() { echo -e "${COLOR_ERR}$*${COLOR_RESET}"; }
success() { echo -e "${COLOR_SEL}✔ $*${COLOR_RESET}"; }
dim() { echo -e "${COLOR_DIM}$*${COLOR_RESET}"; }

# ==============================================================================
#  PROGRESS BAR RENDERING
# ==============================================================================

render_progress_bar() {
    local percent=$1
    local width=${2:-30}
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    local i=0
    
    printf "%s[" "${COLOR_SEL}"
    while [ "$i" -lt "$filled" ]; do
        printf "="
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "$empty" ]; do
        printf "-"
        i=$((i + 1))
    done
    printf "] %3d%%${COLOR_RESET}" "$percent"
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
    return 1
}

# ==============================================================================
#  SSH & TERMINAL DETECTION
# ==============================================================================

check_interactive() {
    # Check if stdin is a TTY (interactive session)
    if [ -t 0 ]; then
        is_interactive=1
    else
        is_interactive=0
    fi
}

check_ssh_session() {
    # Check for SSH environment
    if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
        is_ssh_session=1
    else
        is_ssh_session=0
    fi
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
    tput civis 2>/dev/null  # Hide cursor
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
        tput cnorm 2>/dev/null  # Show cursor
    fi
}

# Status bar for additional context
render_status_bar() {
    local current_time
    current_time=$(date "+%H:%M:%S")
    local mode_label
    [ "$active_mode" = "global" ] && mode_label="GLOBAL" || mode_label="LOCAL"
    
    local filter_info=""
    [ -n "$filter_query" ] && filter_info=" | Filter: $filter_query"
    [ -n "$tag_filter" ] && filter_info=" | Tag: $tag_filter"
    
    local profile_info=""
    local base_name
    base_name="$(basename "$config_path")"
    if [[ "$base_name" == .tasks.* ]]; then
        local profile_name="${base_name#.tasks.}"
        profile_name="${profile_name%%.local}"
        profile_name="${profile_name%%.dev}"
        profile_info=" | Profile: $profile_name"
    fi
    
    echo -e "${COLOR_DIM}⏰ $current_time | Mode: $mode_label${profile_info}${filter_info}${COLOR_RESET}"
    echo -e "${COLOR_DIM}$(printf '─%.0s' {1..63})${COLOR_RESET}"
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

    case "$COLS_MIN" in
        ""|*[!0-9]*) COLS_MIN="$DEFAULT_COLS_MIN" ;;
    esac
    case "$COLS_MAX" in
        ""|*[!0-9]*) COLS_MAX="$DEFAULT_COLS_MAX" ;;
    esac
    [ "$COLS_MIN" -lt 1 ] && COLS_MIN=1
    [ "$COLS_MAX" -lt 1 ] && COLS_MAX=1
    [ "$COLS_MIN" -gt 4 ] && COLS_MIN=4
    [ "$COLS_MAX" -gt 4 ] && COLS_MAX=4
    [ "$COLS_MIN" -gt "$COLS_MAX" ] && COLS_MAX="$COLS_MIN"

    apply_theme
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
# Shell Menu Runner Settings
THEME=$UI_THEME
LANG=$UI_LANG
COLS_MIN=$COLS_MIN
COLS_MAX=$COLS_MAX
EOF
}

find_local_config() {
    set +e
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/$LOCAL_CONFIG" ]; then echo "$d/$LOCAL_CONFIG"; set -e; return 0; fi
        d=$(dirname "$d")
    done
    set -e
    return 1
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

list_available_profiles() {
    local -a names=()
    local d="$PWD"
    while [ "$d" != "/" ]; do
        local f
        for f in "$d"/.tasks.*; do
            [ -e "$f" ] || continue
            local base
            base=$(basename "$f")
            names+=("${base#.tasks.}")
        done
        d=$(dirname "$d")
    done
    local f
    for f in "$HOME"/.tasks.*; do
        [ -e "$f" ] || continue
        local base
        base=$(basename "$f")
        names+=("${base#.tasks.}")
    done
    if [ ${#names[@]} -gt 0 ]; then
        printf "%s\n" "${names[@]}" | sort -u
    fi
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
        # Apply filter if active
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
        
        # Reset page if out of bounds
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
        read -rsn1 choice
        
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
                return 1
                ;;
            "/")
                filter_active=1
                filter_pattern=""
                page=0
                while true; do
                    clear
                    echo -e "${COLOR_HEAD}Filter Profiles${COLOR_RESET}"
                    echo -e "${COLOR_INFO}Type to filter (ESC to cancel, Enter to apply):${COLOR_RESET}"
                    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                    echo -n "Filter: ${filter_pattern}"
                    
                    read -rsn1 char
                    case "$char" in
                        $'\x7f'|$'\x08')  # Backspace
                            [ -n "$filter_pattern" ] && filter_pattern="${filter_pattern%?}"
                            ;;
                        $'\x1b')  # ESC
                            read -rsn2 -t 0.01 extra || true
                            if [ -z "$extra" ]; then
                                filter_active=0
                                filter_pattern=""
                                break
                            fi
                            ;;
                        "")  # Enter
                            break
                            ;;
                        *)
                            if [[ "$char" =~ [a-zA-Z0-9._-] ]]; then
                                filter_pattern="${filter_pattern}${char}"
                            fi
                            ;;
                    esac
                done
                ;;
            "n"|"N")
                [ "$end" -lt "$display_num" ] && ((page++))
                ;;
            "p"|"P")
                [ "$page" -gt 0 ] && ((page--))
                ;;
            $'\x1b')  # ESC - clear filter
                read -rsn2 -t 0.01 extra || true
                if [ -z "$extra" ]; then
                    filter_active=0
                    filter_pattern=""
                    page=0
                fi
                ;;
            "0")
                return 1
                ;;
        esac
    done
}

# ==============================================================================
#  PERFORMANCE CACHE
# ==============================================================================

CACHE_DIR="/tmp/run_cache_$$"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

get_cache_file() {
    local t="$config_path"; local h
    if command -v md5sum &>/dev/null; then h=$(echo -n "$t" | md5sum | cut -d' ' -f1);
    else h=$(echo -n "$t" | cksum | cut -d' ' -f1); fi
    echo "/tmp/run_menu_${h}.state"
}

get_profile_cache_file() {
    echo "$CACHE_DIR/profiles.cache"
}

cache_profiles() {
    local cache_file
    cache_file=$(get_profile_cache_file)
    local cache_age=0
    
    if [ -f "$cache_file" ]; then
        cache_age=$(( $(date +%s) - $(stat -f '%m' "$cache_file" 2>/dev/null || stat -c '%Y' "$cache_file" 2>/dev/null || echo 0) ))
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

save_state() { echo "$selected_index" > "$(get_cache_file)"; }
load_state() { local c; c=$(get_cache_file); [ -f "$c" ] && selected_index=$(cat "$c"); }

# Cleanup cache on exit
trap 'rm -rf "$CACHE_DIR" 2>/dev/null' EXIT INT TERM

# ==============================================================================
#  PROFILE UTILITIES
# ==============================================================================

list_profiles_all() {
    local mode="${1:-text}"
    local profiles_str
    profiles_str=$(list_available_profiles)
    
    if [ -z "$profiles_str" ]; then
        [ "$mode" = "json" ] && echo "{\"profiles\": [], \"total\": 0}" || echo "No profiles found"
        return 0
    fi
    
    if [ "$mode" = "json" ]; then
        echo "{"
        echo "  \"profiles\": ["
        local first=1
        while IFS= read -r profile; do
            [ -z "$profile" ] && continue
            [ "$first" = "0" ] && echo ","
            first=0
            local local_file; local_file=$(find_named_config "$profile" 2>/dev/null) || local_file=""
            local global_file="$HOME/.tasks.$profile"
            echo -n "    {"
            echo -n "\"name\": \"$profile\", "
            if [ -f "$local_file" ]; then
                echo -n "\"location\": \"local ($local_file)\", "
            elif [ -f "$global_file" ]; then
                echo -n "\"location\": \"global ($global_file)\", "
            fi
            local count=0
            if [ -f "$local_file" ]; then
                count=$(grep -c "^[0-9]|" "$local_file" 2>/dev/null || echo "0")
            elif [ -f "$global_file" ]; then
                count=$(grep -c "^[0-9]|" "$global_file" 2>/dev/null || echo "0")
            fi
            echo "\"tasks\": $count}"
        done <<< "$profiles_str"
        echo "  ],"
        echo "  \"total\": $(echo "$profiles_str" | wc -l)"
        echo "}"
    else
        while IFS= read -r profile; do
            [ -z "$profile" ] && continue
            local local_file; local_file=$(find_named_config "$profile" 2>/dev/null) || local_file=""
            local global_file="$HOME/.tasks.$profile"
            if [ -f "$local_file" ]; then
                echo "$profile (local: $local_file)"
            elif [ -f "$global_file" ]; then
                echo "$profile (global: $global_file)"
            else
                echo "$profile (not found)"
            fi
        done <<< "$profiles_str"
    fi
}

init_profile() {
    local name="$1"
    [ -z "$name" ] && { echo "Error: profile name required"; return 1; }
    
    local profile_file="$PWD/.tasks.$name"
    [ -f "$profile_file" ] && { echo "Profile $name already exists at $profile_file"; return 1; }
    
    echo "Creating profile: $name"
    cat > "$profile_file" << 'EOF'
# Profile: {NAME}
# Auto-generated task list for {NAME}

0|Task Name|command|Description here
0|Another Task|echo "Hello"|Runs a simple command
EOF
    
    sed -i '' "s/{NAME}/$name/g" "$profile_file"
    echo "Profile created: $profile_file"
    echo "Edit with: ${EDITOR:-nano} $profile_file"
}

validate_config_file() {
    local profile_file="$1"
    local display_name="$2"

    [ ! -f "$profile_file" ] && { echo "Error: Profile $display_name not found"; return 1; }

    echo "Validating profile: $display_name ($profile_file)"
    local errors=0
    local line_no=0
    local syntax_ok=true

    while IFS='|' read -r level name cmd desc || [ -n "$level" ]; do
        ((line_no++))
        [ -z "$level" ] || [[ "$level" =~ ^# ]] && continue

        if [ -z "$level" ] || [ -z "$cmd" ]; then
            echo "  Line $line_no: Invalid format (missing fields)"
            ((errors++))
            syntax_ok=false
        fi

        if ! [[ "$level" =~ ^[0-9]+$ ]]; then
            echo "  Line $line_no: LEVEL must be numeric, got '$level'"
            ((errors++))
            syntax_ok=false
        fi
    done < "$profile_file"

    if [ "$syntax_ok" = true ]; then
        echo "✓ Syntax valid"
        echo "  - Lines: $((line_no - 1))"
        local task_count
        task_count=$(grep -c "^[0-9]|" "$profile_file")
        echo "  - Tasks: $task_count"
        return 0
    else
        echo "✗ Found $errors syntax error(s)"
        return 1
    fi
}

validate_profile() {
    local name="$1"
    [ -z "$name" ] && { echo "Error: profile name required"; return 1; }

    local profile_file
    profile_file=$(find_named_config "$name") || profile_file="$HOME/.tasks.$name"

    validate_config_file "$profile_file" "$name"
}

# ==============================================================================
#  SEARCH HISTORY
# ==============================================================================

SEARCH_HISTORY_FILE="$HOME/.run_search_history"
SEARCH_HISTORY_MAX=20

save_search_term() {
    local term="$1"
    [ -z "$term" ] && return
    
    # Remove duplicates and add to top
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
        grep -v "^${term}$" "$SEARCH_HISTORY_FILE" > "${SEARCH_HISTORY_FILE}.tmp" 2>/dev/null || true
        mv "${SEARCH_HISTORY_FILE}.tmp" "$SEARCH_HISTORY_FILE"
    fi
    
    echo "$term" >> "$SEARCH_HISTORY_FILE"
    
    # Keep only last N entries
    tail -n "$SEARCH_HISTORY_MAX" "$SEARCH_HISTORY_FILE" > "${SEARCH_HISTORY_FILE}.tmp"
    mv "${SEARCH_HISTORY_FILE}.tmp" "$SEARCH_HISTORY_FILE"
}

get_search_history() {
    [ -f "$SEARCH_HISTORY_FILE" ] && tac "$SEARCH_HISTORY_FILE" || true
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
        read -rsn1 char
        case "$char" in
            $'\x7f'|$'\x08')  # Backspace
                if [ -n "$current_query" ]; then
                    current_query="${current_query%?}"
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                fi
                ;;
            $'\x1b')  # ESC or Arrow keys
                read -rsn2 -t 0.01 arrow
                if [ -z "$arrow" ]; then
                    # Pure ESC - cancel
                    filter_query=""
                    return 1
                elif [ "$arrow" = "[A" ] && [ ${#history_items[@]} -gt 0 ]; then
                    # Arrow Up - previous history
                    ((history_pos++))
                    [ "$history_pos" -ge ${#history_items[@]} ] && history_pos=$((${#history_items[@]} - 1))
                    current_query="${history_items[$history_pos]}"
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                elif [ "$arrow" = "[B" ] && [ "$history_pos" -gt 0 ]; then
                    # Arrow Down - next history
                    ((history_pos--))
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
#  TASK HISTORY
# ==============================================================================

add_to_history() {
    local task_name="$1"
    local exit_code="$2"
    local exec_time="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local status="✔"; [ "$exit_code" -ne 0 ] && status="✗"
    echo "$timestamp | $status | $task_name | exit:$exit_code | time:${exec_time}s" >> "$RUN_HISTORY_FILE"
    
    # Keep history file size manageable
    if [ -f "$RUN_HISTORY_FILE" ]; then
        local lines
        lines=$(wc -l < "$RUN_HISTORY_FILE")
        if [ "$lines" -gt "$RUN_HISTORY_MAX" ]; then
            tail -n "$RUN_HISTORY_MAX" "$RUN_HISTORY_FILE" > "${RUN_HISTORY_FILE}.tmp"
            mv "${RUN_HISTORY_FILE}.tmp" "$RUN_HISTORY_FILE"
        fi
    fi

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
            local status
            status=$(echo "$line" | cut -d'|' -f2 | xargs)
            if [ "$status" = "✔" ]; then
                echo -e "${COLOR_SEL}$line${COLOR_RESET}"
            else
                echo -e "${COLOR_ERR}$line${COLOR_RESET}"
            fi
        done <<< "$lastlines"
    fi
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; read -r -n1 -s
}

add_to_recent() {
    local task_name="$1"
    local exec_time="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="$timestamp|$config_path|$task_name|time:${exec_time}s"
    local tmp_file
    tmp_file=$(mktemp)
    if [ -f "$RUN_RECENT_FILE" ]; then
        grep -v "^.*|$config_path|$task_name|" "$RUN_RECENT_FILE" > "$tmp_file" || true
    fi
    echo "$line" >> "$tmp_file"
    local lines
    lines=$(wc -l < "$tmp_file")
    if [ "$lines" -gt "$RUN_RECENT_MAX" ]; then
        tail -n "$RUN_RECENT_MAX" "$tmp_file" > "${tmp_file}.trim"
        mv "${tmp_file}.trim" "$tmp_file"
    fi
    mv "$tmp_file" "$RUN_RECENT_FILE"
}

show_recent() {
    clear
    echo -e "${COLOR_HEAD}🕘 Recent Tasks${COLOR_RESET}"
    if [ ! -f "$RUN_RECENT_FILE" ] || [ ! -s "$RUN_RECENT_FILE" ]; then
        echo -e "${COLOR_DIM}No recent tasks yet.${COLOR_RESET}"
        echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; read -r -n1 -s
        return
    fi
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    local -a lines=()
    mapfile -t lines < <(tail -n 20 "$RUN_RECENT_FILE")
    local idx=1
    for line in "${lines[@]}"; do
        IFS='|' read -r _ path name rest <<< "$line"
        local short_path
        short_path=$(basename "${path:-}" 2>/dev/null)
        [ "$idx" -le 9 ] && printf "%d) ${COLOR_SEL}%s${COLOR_RESET} ${COLOR_DIM}(%s)${COLOR_RESET}\n" "$idx" "$name" "$short_path" || printf "  ${COLOR_DIM}%s (%s)${COLOR_RESET}\n" "$name" "$short_path"
        ((idx++))
    done
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "\n[1-9] Execute [q]uit"
    while true; do
        read -rsn1 key
        if [[ "$key" =~ [1-9] ]]; then
            local sel=$((key - 1))
            local entry="${lines[$sel]}"
            if [ -n "$entry" ]; then
                IFS='|' read -r _ path name rest <<< "$entry"
                if [ -f "$path" ]; then
                    local prev_config="$config_path"
                    local prev_mode="$active_mode"
                    config_path="$path"
                    if [ "$path" = "$GLOBAL_CONFIG" ]; then active_mode="global"; else active_mode="local"; fi
                    detect_config_files
                    parse_config_vars
                    load_settings
                    load_aliases
                    last_config_mtime=0
                    if ! find_task_in_menu "$name" 'execute_task'; then
                        echo -e "${COLOR_WARN}Task not found in config${COLOR_RESET}"
                        sleep 1
                    fi
                    config_path="$prev_config"
                    active_mode="$prev_mode"
                    detect_config_files
                    parse_config_vars
                    load_settings
                    load_aliases
                else
                    echo -e "${COLOR_WARN}Config not found: $path${COLOR_RESET}"
                    sleep 1
                fi
            fi
            break
        elif [[ "$key" =~ [qQ] ]]; then
            break
        fi
    done
}

# ==============================================================================
#  TASK FAVORITES
# ==============================================================================

readonly RUN_FAVORITES_FILE="$HOME/.run_favorites"

is_favorite() {
    local task_name="$1"
    [ -f "$RUN_FAVORITES_FILE" ] && grep -q "^$task_name$" "$RUN_FAVORITES_FILE"
}

toggle_favorite() {
    local task_name="$1"
    if is_favorite "$task_name"; then
        grep -v "^$task_name$" "$RUN_FAVORITES_FILE" > "${RUN_FAVORITES_FILE}.tmp"
        mv "${RUN_FAVORITES_FILE}.tmp" "$RUN_FAVORITES_FILE"
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
    
    if [ ! -f "$RUN_FAVORITES_FILE" ] || [ ! -s "$RUN_FAVORITES_FILE" ]; then
        echo -e "${COLOR_DIM}No favorites yet. Press [*] on a task to add it!${COLOR_RESET}"
    else
        echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
        local idx=1
        while IFS= read -r fav_name; do
            [ "$idx" -le 9 ] && printf "%d) ${COLOR_SEL}%s${COLOR_RESET}\n" "$idx" "$fav_name" || printf "  ${COLOR_DIM}%s${COLOR_RESET}\n" "$fav_name"
            ((idx++))
        done < "$RUN_FAVORITES_FILE"
    fi
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "\n[1-9] Execute [q]uit"
    
    while true; do
        read -rsn1 key
        if [[ "$key" =~ [1-9] ]]; then
            local fav_idx=$((key - 1))
            local fav_task
            fav_task=$(sed -n "$((fav_idx + 1))p" "$RUN_FAVORITES_FILE" 2>/dev/null)
            if [ -n "$fav_task" ]; then
                # Find and execute the favorite task using helper
                if ! find_task_in_menu "$fav_task" 'execute_task'; then
                    echo -e "${COLOR_WARN}Task not found in current config${COLOR_RESET}" && sleep 1
                fi
            fi
            break
        elif [[ "$key" =~ [qQ] ]]; then
            break
        fi
    done
}

# ==============================================================================
#  TASK LOGS
# ==============================================================================

show_logs() {
    clear
    echo -e "${COLOR_HEAD}📜 Task Logs${COLOR_RESET}"
    mkdir -p "$RUN_LOG_DIR"
    local -a logs=()
    mapfile -t logs < <(
        find "$RUN_LOG_DIR" -maxdepth 1 -type f -name "*.log" -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        head -n 9 |
        cut -d' ' -f2-
    )
    if [ "${#logs[@]}" -eq 0 ]; then
        echo -e "${COLOR_DIM}No logs yet.${COLOR_RESET}"
        echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; read -r -n1 -s
        return
    fi
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    local idx=1
    for log in "${logs[@]}"; do
        printf "%d) ${COLOR_SEL}%s${COLOR_RESET}\n" "$idx" "$(basename "$log")"
        ((idx++))
    done
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "\n[1-9] View [q]uit"
    while true; do
        read -rsn1 key
        if [[ "$key" =~ [1-9] ]]; then
            local sel=$((key - 1))
            local log_file="${logs[$sel]}"
            if [ -f "$log_file" ]; then
                ${PAGER:-less} "$log_file"
            fi
            break
        elif [[ "$key" =~ [qQ] ]]; then
            break
        fi
    done
}

# ==============================================================================
#  CONTEXT MENU
# ==============================================================================

context_menu() {
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    local num=${#menu_options[@]}
    [ "$num" -eq 0 ] && return
    [ "$selected_index" -ge "$num" ] && return
    IFS='|' read -r name cmd desc <<< "${menu_options[$selected_index]}"
    if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
        echo -e "${COLOR_WARN}No context actions for this entry.${COLOR_RESET}"
        sleep 1
        return
    fi
    clear
    echo -e "${COLOR_HEAD}Context: $name${COLOR_RESET}"
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo "1) Copy command"
    echo "2) Duplicate task"
    echo "3) Schedule task (cron)"
    echo "4) View full command"
    echo "0) Back"
    read -rsn1 choice
    case "$choice" in
        "1")
            if copy_to_clipboard "$cmd"; then
                echo -e "${COLOR_SEL}✔ Copied to clipboard${COLOR_RESET}"
            else
                echo -e "${COLOR_WARN}Clipboard not available. Command below:${COLOR_RESET}\n$cmd"
            fi
            sleep 1
            ;;
        "2")
            echo -e "${COLOR_INFO}New task name:${COLOR_RESET}"
            read -r new_name
            if [ -z "$new_name" ] || [[ "$new_name" == *"|"* ]]; then
                echo -e "${COLOR_ERR}Invalid name.${COLOR_RESET}"
                sleep 1
            else
                printf "%s|%s|%s|%s\n" "$current_level" "$new_name" "$cmd" "$desc" >> "$config_path"
                echo -e "${COLOR_SEL}✔ Task duplicated.${COLOR_RESET}"
                last_config_mtime=0
                sleep 1
            fi
            ;;
        "3")
            if ! command -v crontab >/dev/null 2>&1; then
                echo -e "${COLOR_ERR}crontab not available.${COLOR_RESET}"
                sleep 1
                return
            fi
            echo -e "${COLOR_INFO}Cron schedule (e.g. '0 2 * * *'):${COLOR_RESET}"
            read -r cron_expr
            [ -z "$cron_expr" ] && echo -e "${COLOR_INFO}Cancelled.${COLOR_RESET}" && sleep 1 && return
            local workdir
            workdir=$(dirname "$config_path")
            local cron_cmd="cd \"$workdir\" && $cmd"
            ( crontab -l 2>/dev/null; echo "$cron_expr $cron_cmd # run:$name" ) | crontab -
            echo -e "${COLOR_SEL}✔ Scheduled.${COLOR_RESET}"
            sleep 1
            ;;
        "4")
            clear
            echo -e "${COLOR_HEAD}$name${COLOR_RESET}"
            echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
            echo -e "${COLOR_INFO}Description:${COLOR_RESET}\n$desc\n"
            echo -e "${COLOR_INFO}Command:${COLOR_RESET}\n$cmd"
            echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
            read -r -n1 -s
            ;;
        "0"|$'\x1b')
            ;;
    esac
}

# ==============================================================================
#  TASK DEPENDENCIES
# ==============================================================================

parse_task_deps() {
    local task_cmd="$1"
    # Extract [depends: task1,task2] from command
    if [[ "$task_cmd" =~ \[depends:([^\]]+)\] ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Function: execute_task_deps
# Desc: Execute dependency tasks in order (or parallel if RUN_PARALLEL_DEPS=1)
# Args: $1 - comma-separated dependency list
# Returns: 0 on success, 1 on failure
execute_task_deps() {
    local deps_str="$1"
    local IFS=','
    local -a deps
    read -r -a deps <<< "$deps_str"
    
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    
    # Check if parallel execution is enabled
    if [ "${RUN_PARALLEL_DEPS:-0}" = "1" ] && [ "${#deps[@]}" -gt 1 ]; then
        echo -e "${COLOR_DIM}  (running ${#deps[@]} dependencies in parallel)${COLOR_RESET}"
        local -a dep_pids=()
        local -a dep_names=()
        local -a dep_logs=()
        
        for dep in "${deps[@]}"; do
            dep=$(echo "$dep" | xargs)
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"
            
            # Create log file for this dependency
            local dep_log="/tmp/run_dep_${dep}_$$.log"
            dep_logs+=("$dep_log")
            dep_names+=("$dep")
            
            # Execute in background
            (
                if ! find_task_in_menu "$dep" '_execute_dep_callback' 2>&1 | tee "$dep_log"; then
                    exit 1
                fi
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
        for log in "${dep_logs[@]}"; do
            [ -f "$log" ] && rm -f "$log"
        done
        
        [ "$all_success" -eq 0 ] && return 1
        return 0
    else
        # Sequential execution (default)
        for dep in "${deps[@]}"; do
            dep=$(echo "$dep" | xargs)
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"
            
            # Find and execute the dependency task using helper
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

# Project Analysis Function
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
    
    # Count tasks
    local total_tasks
    total_tasks=$(grep -c "^[0-9]" "$config_file" || true)
    
    echo -e "\n${COLOR_SEL}📊 Project Analysis${COLOR_RESET}"
    echo -e "${COLOR_DIM}─────────────────────────────────────────────────────────────${COLOR_RESET}"
    
    # 1. Basic Stats
    echo -e "${COLOR_INFO}📈 Statistics:${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Total Tasks:${COLOR_RESET} $total_tasks"
    
    # Count levels
    local level_0
    local level_1
    level_0=$(grep -c "^0|" "$config_file" || true)
    level_1=$(grep -c "^1|" "$config_file" || true)
    echo -e "  ${COLOR_DIM}Main Tasks (Level 0):${COLOR_RESET} $level_0"
    [ "$level_1" -gt 0 ] && echo -e "  ${COLOR_DIM}Sub Tasks (Level 1):${COLOR_RESET} $level_1"
    
    # Count dependencies
    local deps_count
    deps_count=$(grep -c "depends:" "$config_file" || true)
    echo -e "  ${COLOR_DIM}Tasks with Dependencies:${COLOR_RESET} $deps_count"
    
    # Count parallel markers
    local parallel_count
    parallel_count=$(grep -c "\-\-parallel" "$config_file" || true)
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
        echo -e "     ${COLOR_DIM}• 1|Test|npm run test depends:0|Test (after build)${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• 2|Deploy|npm deploy depends:1|Deploy (after test)${COLOR_RESET}"
        echo ""
    fi
    
    if [ "$parallel_count" -eq 0 ] && [ "$total_tasks" -gt 10 ]; then
        echo -e "  ${COLOR_INFO}⚡${COLOR_RESET}  ${COLOR_DIM}Parallel execution not configured:${COLOR_RESET}"
        echo -e "     Enable for faster execution:"
        echo -e "     ${COLOR_DIM}export RUN_PARALLEL_DEPS=1${COLOR_RESET}"
        local test_count
        test_count=$(grep -ci "test" "$config_file" || true)
        if [ "$test_count" -gt 2 ]; then
            echo -e "     ${COLOR_DIM}Performance boost expected: ~2-3x faster${COLOR_RESET}"
        fi
        echo ""
    fi
    
    # Check for common patterns
    local has_lint
    local has_test
    local has_build
    local has_deploy
    has_lint=$(grep -Eci "lint|eslint|pylint" "$config_file" || true)
    has_test=$(grep -Eci "test|jest|pytest" "$config_file" || true)
    has_build=$(grep -Eci "build|compile" "$config_file" || true)
    has_deploy=$(grep -Eci "deploy|push|release" "$config_file" || true)
    
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
        ((quick_wins+=1))
    fi
    
    if [ "$parallel_count" -eq 0 ] && [ "$deps_count" -gt 0 ]; then
        echo -e "  $((quick_wins+=1)). Enable RUN_PARALLEL_DEPS=1 for speed boost"
    fi
    
    if [ "$total_tasks" -gt 80 ]; then
        echo -e "  $((quick_wins+=1)). Create 2-3 profiles to reduce menu clutter"
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
    
    echo -e "${COLOR_DIM}─────────────────────────────────────────────────────────────${COLOR_RESET}\n"
    
    return 0
}

# Multi-Profile Execution
execute_multi_profile_task() {
    local task_name="$1"
    local profiles_str="$2"  # comma-separated
    local IFS=','
    local -a profiles
    read -r -a profiles <<< "$profiles_str"
    
    echo -e "${COLOR_HEAD}Running task across ${#profiles[@]} profiles:${COLOR_RESET}"
    
    # Check if parallel execution is enabled
    if [ "${RUN_PARALLEL_MULTI:-0}" = "1" ] && [ "${#profiles[@]}" -gt 1 ]; then
        echo -e "${COLOR_DIM}  (running in parallel)${COLOR_RESET}"
        local -a profile_pids=()
        local -a profile_names=()
        local -a profile_logs=()
        
        for prof in "${profiles[@]}"; do
            prof=$(echo "$prof" | xargs)
            echo -e "  ${COLOR_DIM}→ [$prof] $task_name${COLOR_RESET}"
            
            # Create log file for this profile execution
            local prof_log="/tmp/run_multi_prof_${prof}_$$.log"
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
                    echo -e "${COLOR_ERR}Task '$task_name' not found in profile: $prof${COLOR_RESET}" | tee "$prof_log"
                    exit 1
                fi
            ) 2>&1 | tee "$prof_log" &
            profile_pids+=("$!")
        done
        
        # Wait for all profiles to complete
        echo ""
        show_spinner "Executing across ${#profiles[@]} profiles..."
        
        local all_success=1
        for i in "${!profile_pids[@]}"; do
            if ! wait "${profile_pids[$i]}"; then
                stop_spinner
                echo -e "${COLOR_ERR}❌ Execution failed for '${profile_names[$i]}'${COLOR_RESET}"
                all_success=0
            fi
        done
        
        stop_spinner
        if [ "$all_success" -eq 1 ]; then
            echo -e "${COLOR_SEL}✔ Task executed successfully across all profiles${COLOR_RESET}"
        else
            echo -e "${COLOR_WARN}⚠ Some profiles had failures${COLOR_RESET}"
        fi
        
        # Show summary
        echo -e "${COLOR_DIM}───────────────────────────────────────────────${COLOR_RESET}"
        for i in "${!profile_names[@]}"; do
            local log="${profile_logs[$i]}"
            if [ -f "$log" ]; then
                local last_line
                last_line=$(tail -1 "$log")
                echo -e "${COLOR_DIM}[${profile_names[$i]}] $(echo "$last_line" | cut -c1-50)${COLOR_RESET}"
            fi
        done
        
        # Cleanup log files
        for log in "${profile_logs[@]}"; do
            [ -f "$log" ] && rm -f "$log"
        done
        
        [ "$all_success" -eq 0 ] && return 1
        return 0
    else
        # Sequential execution (default)
        for prof in "${profiles[@]}"; do
            prof=$(echo "$prof" | xargs)
            echo -e "  ${COLOR_DIM}→ [$prof] $task_name${COLOR_RESET}"
            
            # Load profile configuration
            if ! load_profile_config "$prof"; then
                echo -e "${COLOR_ERR}Failed to load profile: $prof${COLOR_RESET}"
                return 1
            fi
            
            # Find and execute the task in this profile
            if ! find_task_in_menu "$task_name" '_execute_profile_callback'; then
                echo -e "${COLOR_ERR}Task '$task_name' not found in profile: $prof${COLOR_RESET}"
                return 1
            fi
        done
        
        echo -e "${COLOR_SEL}✔ Task executed successfully across all profiles${COLOR_RESET}"
        return 0
    fi
}

# Helper: Load profile config for multi-profile execution
load_profile_config() {
    local profile_name="$1"
    
    # Temporarily change active_mode and config_path
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

# Callback: Execute task in specific profile context
_execute_profile_callback() {
    local task_cmd="$1"
    local task_name="$2"
    local task_desc="$3"
    execute_task "$task_cmd" "$task_name" "$task_desc" || return 1
}

execute_task_pipeline() {
    local task_cmd="$1"
    local steps_str="${task_cmd#tasks:}"
    local IFS=';'
    local -a steps
    read -r -a steps <<< "$steps_str"
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    for step in "${steps[@]}"; do
        step=$(echo "$step" | xargs)
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
        IFS='|' read -r name cmd desc <<< "${menu_options[$idx]}"
        if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
            continue
        fi
        if [[ "$desc" == "[!]"* ]] || echo "$cmd" | grep -q '<<' || [[ "$cmd" == tasks:* ]]; then
            echo -e "${COLOR_WARN}Skipping '$name' (interactive or pipeline).${COLOR_RESET}"
            continue
        fi
        local log_file
        log_file=$(create_log_file "$name")
        local start_time
        start_time=$(date +%s)
        (
            if command -v timeout >/dev/null 2>&1; then
                timeout "$task_timeout" bash -c "[ \"$active_mode\" == \"local\" ] && cd \"$(dirname "$config_path")\"; [ -f \".env\" ] && set -a && source .env && set +a; eval \"$cmd\"" 2>&1 | tee "$log_file"
                exit "${PIPESTATUS[0]}"
            else
                bash -c "[ \"$active_mode\" == \"local\" ] && cd \"$(dirname "$config_path")\"; [ -f \".env\" ] && set -a && source .env && set +a; eval \"$cmd\"" 2>&1 | tee "$log_file"
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
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; read -r -n1 -s
}

# ==============================================================================
#  MULTI-FILE CONFIG SUPPORT
# ==============================================================================

detect_config_files() {
    local config_dir
    [ "$active_mode" = "local" ] && config_dir="$(dirname "$config_path")" || config_dir="$HOME"
    local base_name
    base_name="$(basename "$config_path")"
    
    task_config_files=()
    if [ "$base_name" = ".tasks" ]; then
        [ -f "$config_dir/.tasks" ] && task_config_files+=("$config_dir/.tasks")
        [ -f "$config_dir/.tasks.local" ] && task_config_files+=("$config_dir/.tasks.local")
        [ -f "$config_dir/.tasks.dev" ] && task_config_files+=("$config_dir/.tasks.dev")
    else
        [ -f "$config_dir/$base_name" ] && task_config_files+=("$config_dir/$base_name")
        [ -f "$config_dir/${base_name}.local" ] && task_config_files+=("$config_dir/${base_name}.local")
        [ -f "$config_dir/${base_name}.dev" ] && task_config_files+=("$config_dir/${base_name}.dev")
    fi
}

merge_configs() {
    # Merge all config files into one stream (faster than loop+cat)
    cat "${task_config_files[@]}" 2>/dev/null || true
}

file_sha256() {
    local f="$1"
    if command -v sha256sum &>/dev/null; then sha256sum "$f" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then shasum -a 256 "$f" | awk '{print $1}'
    else return 1; fi
}

# ==============================================================================
#  SELF UPDATE
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
        new_ver=$(grep -m1 "readonly VERSION=" "$tmp_file" | cut -d'"' -f2 || true)
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

# ==============================================================================
#  SMART INIT (AUTO-DETECTION)
# ==============================================================================

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
0|🐳 Up|docker-compose up -d|Start containers
0|🐳 Down|docker-compose down|Stop containers
0|🐳 Logs|docker-compose logs -f --tail=200|Follow logs
0|🐳 Restart|docker-compose restart|Restart containers
0|🐳 Ps|docker-compose ps|Show status
0|❌ Exit|EXIT|Back
EOF
            fi
        fi

        # 1. Node.js / React Detection
        if [ -f "package.json" ]; then
            echo -e "${COLOR_INFO}→ $(msg node_detected)${COLOR_RESET}"
            local scripts
            scripts=$(sed -n '/"scripts": {/,/}/p' package.json | grep ":" | sed 's/^[[:space:]]*"//; s/":.*//')
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
            echo "0|🐳 Docker Up|docker-compose up -d|Container starten" >> "$target"
            echo "0|🐳 Docker Down|docker-compose down|Container stoppen" >> "$target"
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
#  CORE LOGIC & UI
# ==============================================================================

calculate_layout() {
    local num=$1
    local cols=1
    if [ "$num" -gt 10 ]; then cols=3; elif [ "$num" -gt 5 ]; then cols=2; fi
    [ "$cols" -lt "$COLS_MIN" ] && cols="$COLS_MIN"
    [ "$cols" -gt "$COLS_MAX" ] && cols="$COLS_MAX"
    [ "$num" -gt 0 ] && [ "$cols" -gt "$num" ] && cols="$num"
    local rows=$(( (num + cols - 1) / cols ))
    echo "$rows|$cols"
}

show_help_panel() {
    clear
    echo -e "${COLOR_HEAD}⌨️  Keyboard Shortcuts & Help${COLOR_RESET}"
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_INFO}Navigation:${COLOR_RESET}"
    echo "  ↑ ↓ / j k     Move selection up/down"
    echo "  ← → / h l     Navigate between columns"
    echo "  1-9           Quick execute task by number"
    echo "  Enter         Execute selected task"
    echo "  Space         Toggle multi-select"
    echo "  ESC           Go back / Exit"
    echo ""
    echo -e "${COLOR_INFO}Search & Filter:${COLOR_RESET}"
    echo "  /             Search tasks (with history)"
    echo "                ↑ ↓ Browse search history"
    echo "                ESC Cancel search"
    echo "  #             Filter by tag"
    echo ""
    echo -e "${COLOR_INFO}Management:${COLOR_RESET}"
    echo "  p             Switch profile"
    echo "  g             Toggle global/local mode"
    echo "  e             Edit config file"
    echo "  f             File browser"
    echo "  s             Settings menu"
    echo ""
    echo -e "${COLOR_INFO}Quick Access:${COLOR_RESET}"
    echo "  *             Toggle favorite"
    echo "  r             View recent/favorites"
    echo "  !             Show execution history"
    echo "  a             Edit aliases"
    echo "  ?             Show this help panel"
    echo ""
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "${COLOR_INFO}Press any key to continue...${COLOR_RESET}"
    read -rsn1
}

# ==============================================================================
#  HELPERS & UTILITY FUNCTIONS
# ==============================================================================

find_task_in_menu() {
    # Find task by name in menu_options and execute callback
    local search_name="$1"
    local callback="$2"
    local -a opts
    IFS=$'\n' read -d '' -r -a opts < <(get_menu_options) || true
    
    for opt in "${opts[@]}"; do
        IFS='|' read -r opt_name opt_cmd opt_desc <<< "$opt"
        if [ "$opt_name" = "$search_name" ]; then
            eval "$callback \"$opt_name\" \"$opt_cmd\" \"$opt_desc\""
            return 0
        fi
    done
    return 1
}

extract_field_from_grep() {
    # Extract field from grep result
    # Usage: extract_field_from_grep "^TIMEOUT=" "=" 2
    local pattern="$1"
    local delimiter="$2"
    local field_idx="$3"
    grep -m1 "$pattern" "$config_path" 2>/dev/null | cut -d"$delimiter" -f"$field_idx" | xargs || true
}

load_global_vars() {
    [ ! -f "$RUN_VARS_FILE" ] && return 0
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
    [ ! -f "$config_path" ] && return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^VAR_[A-Za-z0-9_]+= ]] || continue
        local key="${line%%=*}"
        local value="${line#*=}"
        export "$key"="$value"
    done < "$config_path"
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
    echo "$out"
}

sanitize_filename() {
    echo "$1" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-'
}

create_log_file() {
    local task_name="$1"
    mkdir -p "$RUN_LOG_DIR"
    local safe_name
    safe_name=$(sanitize_filename "$task_name")
    [ -z "$safe_name" ] && safe_name="task"
    echo "$RUN_LOG_DIR/$(date '+%Y-%m-%d_%H-%M-%S')_${safe_name}.log"
}

copy_to_clipboard() {
    local text="$1"
    if command -v pbcopy >/dev/null 2>&1; then
        echo -n "$text" | pbcopy
        return 0
    fi
    if command -v xclip >/dev/null 2>&1; then
        echo -n "$text" | xclip -selection clipboard
        return 0
    fi
    if command -v wl-copy >/dev/null 2>&1; then
        echo -n "$text" | wl-copy
        return 0
    fi
    return 1
}

# ==============================================================================
#  TASK TAGS
# ==============================================================================

extract_tags() {
    local desc="$1"
    # Extract all #tag occurrences from description
    grep -oE '#[a-zA-Z0-9_-]+' <<< "$desc" | tr '\n' ' ' | xargs
}

has_tag() {
    local desc="$1"
    local search_tag="$2"
    local tags
    tags=$(extract_tags "$desc")
    [[ " $tags " == *" $search_tag "* ]]
}

get_all_tags() {
    # Scan all tasks and extract unique tags
    local config_stream
    if [ ${#task_config_files[@]} -gt 1 ]; then
        config_stream=$(merge_configs)
    else
        config_stream=$(cat "$config_path" 2>/dev/null)
    fi
    
    echo "$config_stream" | grep -oE '#[a-zA-Z0-9_-]+' | sort -u | xargs
}

show_tag_menu() {
    clear
    echo -e "${COLOR_HEAD}🏷 Filter by Tag${COLOR_RESET}"
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    
    local -a all_tags
    mapfile -t all_tags < <(get_all_tags)
    local num_tags=${#all_tags[@]}
    
    if [ "$num_tags" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tags found in tasks${COLOR_RESET}"
        sleep 1
        return
    fi
    
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
        read -rsn1 key
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

# ==============================================================================
#  TASK ALIASES
# ==============================================================================

load_aliases() {
    # Create alias file if not exists
    [ ! -f "$ALIAS_FILE" ] && touch "$ALIAS_FILE"
}

resolve_alias() {
    local input="$1"
    [ ! -f "$ALIAS_FILE" ] && echo "$input" && return 0
    
    # Search for exact alias match
    local resolved
    resolved=$(grep "^${input}=" "$ALIAS_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2-)
    
    if [ -n "$resolved" ]; then
        echo "$resolved"
    else
        echo "$input"
    fi
}

show_alias_editor() {
    clear
    echo -e "${COLOR_HEAD}🔧 Task Aliases${COLOR_RESET}"
    echo -e "${COLOR_DIM}Define shortcuts for common tasks${COLOR_RESET}\n"
    echo -e "${COLOR_INFO}Format: alias_name=task_name${COLOR_RESET}"
    echo -e "${COLOR_DIM}Example: d=Deploy, b=Build${COLOR_RESET}\n"
    
    if [ -f "$ALIAS_FILE" ] && [ -s "$ALIAS_FILE" ]; then
        echo -e "${COLOR_INFO}Existing aliases:${COLOR_RESET}"
        while IFS='=' read -r alias cmd || [ -n "$alias" ]; do
            [ -z "$alias" ] || [[ "$alias" =~ ^# ]] && continue
            printf "  ${COLOR_SEL}%-15s${COLOR_RESET} -> %s\n" "$alias" "$cmd"
        done < "$ALIAS_FILE"
    else
        echo -e "${COLOR_DIM}No aliases defined yet.${COLOR_RESET}"
    fi
    
    echo -e "\n${COLOR_INFO}Edit ${ALIAS_FILE}:${COLOR_RESET}"
    ${EDITOR:-nano} "$ALIAS_FILE"
    load_aliases
    echo -e "${COLOR_SEL}✔ Aliases updated${COLOR_RESET}"
    sleep 0.5
}

# ==============================================================================
#  PREVIEW & DRY-RUN
# ==============================================================================

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
    
    if echo "$cmd" | grep -q '<<'; then
        echo -e "${COLOR_INFO}ℹ This task has inputs that will be prompted\n"
    fi
    
    echo -e "${COLOR_DIM}──────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "\n[Enter] Execute  [d]ry-run  [q]uit"
    
    while true; do
        read -rsn1 key
        case "$key" in
            "") echo -e "\n${COLOR_INFO}Executing...${COLOR_RESET}"; return 0 ;;
            "d"|"D") dry_run_mode=1; return 0 ;;
            "q"|"Q"|$'\x1b') return 1 ;;
        esac
    done
}

validate_filename() {
    local fn="$1"
    
    # Reject empty names
    [ -z "$fn" ] && return 1
    
    # Reject dangerous paths
    [[ "$fn" =~ \.\. ]] && return 1      # Parent directory  
    [[ "$fn" = *'/'* ]] && return 1      # Absolute/relative paths
    [[ "$fn" = *"\${"* ]] && return 1     # Variable expansion
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

parse_config_vars() {
    [ ! -f "$config_path" ] && return
    TASK_THEME=$(grep "^# THEME:" "$config_path" | head -n 1 | cut -d: -f2 | xargs)
    task_timeout=$(extract_field_from_grep "^TIMEOUT=" "=" 2)
    task_timeout="${task_timeout:-$RUN_TASK_TIMEOUT}"
    load_task_vars
}

get_menu_options() {
    # Check if config file has changed (cache invalidation)
    local current_mtime=0
    if [ -n "$config_path" ] && [ -f "$config_path" ]; then
        current_mtime=$(stat -f '%m' "$config_path" 2>/dev/null || stat -c '%Y' "$config_path" 2>/dev/null || echo 0)
    fi
    
    # Return cached result if file hasn't changed (and tag filter is same)
    if [ "$current_mtime" -eq "$last_config_mtime" ] && [ -n "$cached_menu_options" ]; then
        # Still apply tag filter to cached options
        if [ -n "$tag_filter" ]; then
            echo "$cached_menu_options" | while IFS='|' read -r name cmd desc; do
                if has_tag "$desc" "$tag_filter"; then
                    desc=$(expand_env_vars "$desc")
                    echo "$name|$cmd|$desc"
                fi
            done
        else
            echo "$cached_menu_options" | while IFS='|' read -r name cmd desc; do
                desc=$(expand_env_vars "$desc")
                echo "$name|$cmd|$desc"
            done
        fi
        return 0
    fi
    
    # Regenerate cache
    local config_stream
    if [ ${#task_config_files[@]} -gt 1 ]; then
        config_stream=$(merge_configs)
    else
        config_stream=$(cat "$config_path")
    fi
    
    cached_menu_options=$(echo "$config_stream" | awk -F'|' -v lvl="$current_level" -v q="$filter_query" \
        'BEGIN {IGNORECASE=1} /^[^#]/ && !/^VAR_/ && NF >= 2 && $1 == lvl { \
            if (q != "" && index(tolower($2), tolower(q)) == 0) next; \
            desc = ($4 != "") ? $4 : ""; print $2"|"$3"|"desc \
        }' || true)
    
    # Apply tag filter if set
    if [ -n "$tag_filter" ]; then
        echo "$cached_menu_options" | while IFS='|' read -r name cmd desc; do
            if has_tag "$desc" "$tag_filter"; then
                desc=$(expand_env_vars "$desc")
                echo "$name|$cmd|$desc"
            fi
        done
    else
        echo "$cached_menu_options" | while IFS='|' read -r name cmd desc; do
            desc=$(expand_env_vars "$desc")
            echo "$name|$cmd|$desc"
        done
    fi
    
    last_config_mtime="$current_mtime"
}


select_dropdown() {
    local options_str="$1"
    local IFS=','
    local -a options=()
    mapfile -t options < <(echo "$options_str" | tr ',' '\n')
    local selected=0
    local num=${#options[@]}
    
    while true; do
        clear
        echo -e "${COLOR_HEAD}$(msg select_option)${COLOR_RESET}"
        for (( i=0; i<num; i++ )); do
            if [ "$i" -eq "$selected" ]; then
                echo -e "${COLOR_SEL}›${COLOR_RESET} ${options[$i]}"
            else
                echo "  ${options[$i]}"
            fi
        done
        echo -e "\n${COLOR_DIM}$(msg dropdown_hint)${COLOR_RESET}"
        
        read -rsn1 key
        case "$key" in
            $'\x1b') 
                read -rsn2 -t 0.1 k
                case "$k" in 
                    '[A') ((selected--));; 
                    '[B') ((selected++));;
                    '') return 1;; # Pure Escape = cancel
                esac;;
            "k") ((selected--));; "j") ((selected++));;
            "") echo "${options[$selected]}"; return 0;;
        esac
        [ "$selected" -lt 0 ] && selected=$((num-1))
        [ "$selected" -ge "$num" ] && selected=0
    done
}

execute_task() {
    local cmd="$1"; local name="$2"; local desc="$3"; shift 3; local args=("$@")
    dry_run_mode=0  # Reset dry-run flag
    
    # Show preview if interactive
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

    # Handle task dependencies
    local deps
    deps=$(parse_task_deps "$cmd")
    if [ -n "$deps" ]; then
        execute_task_deps "$deps" || return 1
        # Remove dependency annotation from command
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
    
    echo -e "${COLOR_DIM}> $cmd ${args[*]}${COLOR_RESET}\n"; save_state
    
    if [ "$dry_run_mode" -eq 1 ]; then
        echo -e "${COLOR_INFO}🔍 DRY-RUN: Command would execute as above${COLOR_RESET}"
        echo -e "${COLOR_DIM}(No actual execution)${COLOR_RESET}\n"
        echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; read -r -n1 -s
        return 0
    fi
    
    # Measure execution time
    local start_time
    start_time=$(date +%s)
    
    # Execute with timeout
    local exit_status=0
    local log_file
    log_file=$(create_log_file "$name")
    local temp_output
    temp_output=$(mktemp)
    trap 'rm -f "$temp_output"' RETURN
    
    if command -v timeout >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        if timeout "$task_timeout" bash -c "[ \"$active_mode\" == \"local\" ] && cd \"$(dirname "$config_path")\"; [ -f \".env\" ] && set -a && source .env && set +a; eval \"$cmd ${args[*]}\"" > "$temp_output" 2>&1; then
            exit_status=0
        else
            exit_status=$?
        fi
        if [ "$exit_status" -eq 124 ]; then
            echo -e "\n${COLOR_ERR}$(msg task_timeout) (${task_timeout}s).${COLOR_RESET}"
        fi
    else
        # Fallback without timeout
        # shellcheck disable=SC1091
        if ( [ "$active_mode" == "local" ] && cd "$(dirname "$config_path")"; [ -f ".env" ] && set -a && source .env && set +a; eval "$cmd ${args[*]}" ) > "$temp_output" 2>&1; then
            exit_status=0
        else
            exit_status=$?
        fi
    fi
    
    # Process output with progress parsing and logging
    while IFS= read -r line; do
        process_progress_output "$line"
        echo "$line" >> "$log_file"
    done < "$temp_output"
    
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
    
    # Show execution time
    echo -e "${COLOR_DIM}⏱ ${task_execution_time}s${COLOR_RESET}"
    
    # Log to history
    add_to_history "$name" "$exit_status" "$task_execution_time"

    echo -e "${COLOR_DIM}Log: $log_file${COLOR_RESET}"
    
    # Invalidate menu cache after task execution (config may have changed)
    last_config_mtime=0
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; read -r -n1 -s
}

settings_menu() {
    local scope="global"
    if [ "$active_mode" = "local" ]; then
        scope="local"
    fi

    while true; do
        clear
        local scope_label
        [ "$scope" = "local" ] && scope_label="$(msg scope_local)" || scope_label="$(msg scope_global)"
        echo -e "${COLOR_HEAD}$(msg settings_title) (${scope_label})${COLOR_RESET}"
        echo "1) $(msg settings_theme): $UI_THEME"
        echo "2) $(msg settings_cols_min): $COLS_MIN"
        echo "3) $(msg settings_cols_max): $COLS_MAX"
        echo "4) $(msg settings_lang): $UI_LANG"
        echo "5) $(msg settings_scope): $scope_label"
        echo "0) $(msg settings_back)"
        read -rsn1 key
        case "$key" in
            "1") UI_THEME=$(select_dropdown "CYBER,MONO,DARK,LIGHT"); apply_theme ;;
            "2") COLS_MIN=$(select_dropdown "1,2,3,4"); [ "$COLS_MIN" -gt "$COLS_MAX" ] && COLS_MAX="$COLS_MIN" ;;
            "3") COLS_MAX=$(select_dropdown "1,2,3,4"); [ "$COLS_MAX" -lt "$COLS_MIN" ] && COLS_MIN="$COLS_MAX" ;;
            "4") UI_LANG=$(select_dropdown "DE,EN") ;;
            "5") if [ "$scope" = "global" ]; then scope="local"; else scope="global"; fi ;;
            "0"|"q"|$'\x1b') break ;;
        esac
        save_settings "$scope"
        echo -e "${COLOR_DIM}$(msg settings_saved)${COLOR_RESET}"
        sleep 0.5
    done
    load_settings
}

# ==============================================================================
#  FILE BROWSER
# ==============================================================================

file_browser() {
    local base_dir
    base_dir="$(dirname "$config_path")"
    
    while true; do
        clear
        echo -e "${COLOR_HEAD}📁 File Browser${COLOR_RESET}"
        echo -e "${COLOR_DIM}Directory: $base_dir${COLOR_RESET}"
        echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
        
        local -a files=()
        local idx=1
        
        # Priority files first
        local priority_files=(".tasks" ".tasks.local" ".tasks.dev" ".env" ".runrc" "README.md")
        for f in "${priority_files[@]}"; do
            if [ -f "$base_dir/$f" ]; then
                printf "%d) ${COLOR_INFO}%s${COLOR_RESET} (exists)\n" "$idx" "$f"
                files[idx]="$base_dir/$f"
                ((idx++))
            fi
        done
        
        # Other files - show common ones
        if [ "$idx" -le 9 ]; then
            local common_patterns=("package.json" "docker-compose*.yml" "Dockerfile" ".gitignore" "Makefile")
            for pattern in "${common_patterns[@]}"; do
                for f in "$base_dir"/$pattern; do
                    [ -f "$f" ] || continue
                    local basename
                    basename=$(basename "$f")
                    
                    # Skip already listed
                    local found=0
                    for pf in "${priority_files[@]}"; do
                        [ "$basename" = "$pf" ] && found=1
                    done
                    [ "$found" -eq 1 ] && continue
                    
                    [ "$idx" -gt 9 ] && break
                    printf "%d) ${COLOR_DIM}%s${COLOR_RESET}\n" "$idx" "$basename"
                    files[idx]="$f"
                    ((idx++))
                done
                [ "$idx" -gt 9 ] && break
            done
        fi
        
        echo ""
        echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
        echo "[1-9] Edit  [c]reate new  [q]uit"
        echo ""
        read -rsn1 choice
        
        case "$choice" in
            [1-9])
                if [ -n "${files[$choice]}" ]; then
                    edit_config_menu "${files[$choice]}"
                fi
                ;;
            "c"|"C")
                clear
                echo -e "${COLOR_HEAD}Create New File${COLOR_RESET}"
                echo -n "Filename: "
                read -r filename
                
                if [ -z "$filename" ]; then
                    echo "Cancelled."
                    sleep 1
                    continue
                fi
                
                # Validate filename
                if ! validate_filename "$filename"; then
                    echo -e "${COLOR_ERR}Invalid filename! Use only alphanumeric, dots, dashes, underscores.${COLOR_RESET}"
                    sleep 2
                    continue
                fi
                
                local filepath="$base_dir/$filename"
                
                if [ -f "$filepath" ]; then
                    echo -e "${COLOR_ERR}File already exists!${COLOR_RESET}"
                    sleep 2
                    continue
                fi
                
                echo -e "${COLOR_INFO}Paste content (Ctrl+D to save):${COLOR_RESET}"
                cat > "$filepath"
                echo -e "${COLOR_SEL}✔ File created: $filename${COLOR_RESET}"
                sleep 1
                ;;
            "q"|"Q"|$'\x1b')
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
        read -rsn1 choice
        
        case "$choice" in
            "1")
                ${EDITOR:-nano} "$file"
                ;;
            "2")
                clear
                echo -e "${COLOR_HEAD}Replace File Content${COLOR_RESET}"
                echo -e "${COLOR_INFO}Paste your content below, then press Ctrl+D (or Ctrl+Z on Windows)${COLOR_RESET}"
                echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                
                # Create temp file
                local tmp_file
                tmp_file=$(mktemp)
                cat > "$tmp_file"
                
                # Show preview
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
                read -n1 -rs
                ;;
            "0"|$'\x1b')
                break
                ;;
        esac
    done
}

draw_menu() {
    if [ "$is_interactive" -eq 1 ]; then
        hide_cursor
        printf "\033[H\033[J"
    else
        echo ""
    fi
    
    # Render status bar
    render_status_bar
    
    local active_desc=""
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    local num=${#menu_options[@]}
    IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
    
    local title
    title=$(grep "^# TITLE:" "$config_path" | head -n 1 | cut -d: -f2)
    [ -z "$title" ] && title="$(basename "$(dirname "$config_path")" | tr '[:lower:]' '[:upper:]')"
    [ "$active_mode" == "global" ] && title="$(msg system_control)"
    
    echo -e "${COLOR_HEAD}${C_BOLD}${title}${COLOR_RESET}"
    local crumbs=""; for name in "${history_name_stack[@]}"; do [ -z "$crumbs" ] && crumbs="${name}" || crumbs="${crumbs} ${COLOR_DIM}>${COLOR_RESET} ${name}"; done
    echo -e "${COLOR_DIM}$(msg path_label)${COLOR_RESET} $crumbs"
    local base_name
    local profile_name
    base_name="$(basename "$config_path")"
    if [[ "$base_name" == .tasks.* ]]; then
        profile_name="${base_name#.tasks.}"
        profile_name="${profile_name%%.local}"
        profile_name="${profile_name%%.dev}"
        local scope_label
        [ "$active_mode" = "global" ] && scope_label="global" || scope_label="local"
        echo -e "${COLOR_INFO}Profile:${COLOR_RESET} $profile_name (${scope_label})"
    fi
    [ -n "$filter_query" ] && echo -e "${COLOR_INFO}🔍 Filter:${COLOR_RESET} '$filter_query'"
    [ -n "$tag_filter" ] && echo -e "${COLOR_INFO}🏷 Tag:${COLOR_RESET} '$tag_filter'"
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"

    for (( r=0; r<rows; r++ )); do
        for (( c=0; c<cols; c++ )); do
            local idx=$(( r + c * rows ))
            if [ "$idx" -lt "$num" ]; then
                IFS='|' read -r name cmd desc <<< "${menu_options[$idx]}"
                local marker=" "
                local star=" "
                [[ -n "${multi_select_map[$idx]}" ]] && marker="${COLOR_WARN}✔${COLOR_RESET}"
                is_favorite "$name" && star="${COLOR_SEL}⭐${COLOR_RESET}"
                if [ "$idx" -eq "$selected_index" ]; then printf "${COLOR_SEL}›${marker}${star} %-20s${COLOR_RESET}" "${name:0:20}"; active_desc="$desc"
                else printf "  ${marker}${star} %-20s" "${name:0:20}"; fi
            fi
        done
        echo "" 
    done
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    if [ -n "$active_desc" ]; then echo -e "${COLOR_INFO}ℹ $active_desc${COLOR_RESET}"
    else
        local hint
        hint="$(msg hint_global)"; [ "$active_mode" == "global" ] && hint="$(msg hint_local)"
        local multi_hint=""; local marked=${#multi_select_map[@]}
        [ "$marked" -gt 0 ] && multi_hint=" [$marked $(msg marked_label)]"
        if [ "$is_interactive" -eq 1 ]; then
            echo -e "${COLOR_DIM} $(msg hint_nav)$multi_hint $hint [p]rofile [s]ettings [e]dit [f]ile [a]lias [#] tags [*] fav [r]ecent [!] hist [?] help [1-9] [Enter] run${COLOR_RESET}"
        else
            echo -e "${COLOR_DIM} Type: NUMBER [e]dit [f]ile [a]lias [s]ettings [g]lobal [#] tags [*] fav [!]istory [?] help [q]uit${COLOR_RESET}"
        fi
    fi
}

# --- MAIN LOOP ---
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
            [ ! -f "$config_path" ] && smart_init "global" && exit 0
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
set -- "${args[@]}"

if [ "${RUN_DEBUG:-0}" = "1" ]; then
    DEBUG_MODE=1
fi

if [ "$DEBUG_MODE" -eq 1 ]; then
    set -x
fi

if [ "${#args[@]}" -eq 0 ] && [ -z "$config_path" ] && [ -t 0 ]; then
    profiles_list=$(list_available_profiles)
    if [ -n "$profiles_list" ]; then
        echo -e "${COLOR_INFO}Profiles available:${COLOR_RESET} $(echo "$profiles_list" | tr '\n' ' ')"
        echo -e "${COLOR_DIM}Press [p] to choose a profile or any other key to continue...${COLOR_RESET}"
        read -rsn1 key
        if [ "$key" = "p" ] || [ "$key" = "P" ]; then
            select_profile_menu || true
        fi
    fi
fi

if [ "${#args[@]}" -gt 0 ]; then
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
            echo -e "${COLOR_INFO}Available profiles:${COLOR_RESET} $(echo "$profiles_list" | tr '\n' ' ')"
        fi
    fi
fi

if [ -z "$config_path" ]; then
    if found=$(find_local_config); then config_path="$found"
    elif [ -f "$GLOBAL_CONFIG" ]; then active_mode="global"; config_path="$GLOBAL_CONFIG"
    else
        if select_profile_menu; then
            :
        else
            smart_init "local"
            exit 0
        fi
    fi
fi

parse_config_vars; load_settings; load_state; detect_config_files; load_aliases
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

while true; do
    draw_menu
    
    # Handle input - interactive or non-interactive
    key=""
    if [ "$is_interactive" -eq 1 ]; then
        read -rsn1 key
    else
        # Non-interactive: read line (for SSH without TTY)
        read -r key || break
    fi
    
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    num=${#menu_options[@]}
    IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
    
    case "$key" in
        $'\x1b') 
            if [ "$is_interactive" -eq 1 ]; then
                read -rsn2 -t 0.1 k
                case "$k" in 
                    '[A') ((selected_index--));; 
                    '[B') ((selected_index++));; 
                    '[C') [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows));; 
                    '[D') [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows));; 
                    '')   # Pure Escape pressed (no arrow key)
                        if [ "$current_level" -gt 0 ]; then
                            ((current_level--))
                            history_name_stack=("${history_name_stack[@]:0:${#history_name_stack[@]}-1}")
                            selected_index=0
                        else
                            # At root level: exit
                            clear; exit 0
                        fi;;
                esac
            else
                # Non-interactive: Escape = go back or exit
                if [ "$current_level" -gt 0 ]; then
                    ((current_level--))
                    history_name_stack=("${history_name_stack[@]:0:${#history_name_stack[@]}-1}")
                    selected_index=0
                else
                    clear; exit 0
                fi
            fi;;
        "k") ((selected_index--));; "j") ((selected_index++));;
        "h") [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows));;
        "l") [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows));;
        " ") if [[ -n "${multi_select_map[$selected_index]}" ]]; then unset 'multi_select_map[$selected_index]'; else multi_select_map["$selected_index"]=1; fi;;
        [1-9]) # Hotkey: direct task execution by number
            hotkey_idx=$((key - 1))
            if [ "$hotkey_idx" -lt "$num" ]; then
                selected_index="$hotkey_idx"
                # Execute immediately
                IFS='|' read -r n cm d <<< "${menu_options[$selected_index]}"
                [ "$cm" != "EXIT" ] && [ "$cm" != "SUB" ] && [ "$cm" != "BACK" ] && execute_task "$cm" "$n" "$d"
            fi;;
        "/") interactive_search && selected_index=0;;
        "g") if [ "$active_mode" == "local" ]; then active_mode="global"; config_path="$GLOBAL_CONFIG"; elif found=$(find_local_config); then active_mode="local"; config_path="$found"; fi; selected_index=0; current_level=0; parse_config_vars; load_settings; load_state; detect_config_files; load_aliases;;
        "p"|"P") if select_profile_menu; then selected_index=0; current_level=0; history_name_stack=("Main"); parse_config_vars; load_settings; load_state; detect_config_files; load_aliases; fi;;
        "s") settings_menu;;
        "!") show_history;;
        "a"|"A") show_alias_editor;;
        "?") show_help_panel;;
        "") [ ${#menu_options[@]} -eq 0 ] && continue
            if [ ${#multi_select_map[@]} -gt 0 ]; then
                IFS=$'\n' read -r -d '' -a multi_keys < <(printf "%s\n" "${!multi_select_map[@]}" | sort -n && printf '\0') || true
                for mi in "${multi_keys[@]}"; do
                    IFS='|' read -r n cm d <<< "${menu_options[$mi]}"
                    [ "$cm" == "EXIT" ] && continue
                    execute_task "$cm" "$n" "$d"
                done
                echo -e "${COLOR_INFO}$(msg executed_marked):${COLOR_RESET} ${#multi_keys[@]} $(msg marked_label)"
                multi_select_map=()
                continue
            fi
            IFS='|' read -r n cm d <<< "${menu_options[$selected_index]}"
            if [ "$cm" == "EXIT" ]; then 
                clear; exit 0
            elif [ "$cm" == "SUB" ]; then
                ((current_level++)); history_name_stack+=("$n"); selected_index=0
            elif [ "$cm" == "BACK" ] && [ "$current_level" -gt 0 ]; then
                ((current_level--)); history_name_stack=("${history_name_stack[@]:0:${#history_name_stack[@]}-1}"); selected_index=0
            else
                execute_task "$cm" "$n" "$d"
            fi;;
        "e"|"E") [ -z "$config_path" ] && config_path="$LOCAL_CONFIG"; edit_config_menu "$config_path";;
        "f"|"F") file_browser;;
        "#") show_tag_menu;;
        "*") if [ "$selected_index" -lt "$num" ]; then IFS='|' read -r n cm d <<< "${menu_options[$selected_index]}"; toggle_favorite "$n"; fi;;
        "r"|"R") show_favorites;;
        "q"|"Q") clear; exit 0;;
    esac
    cnt=${#menu_options[@]}; [ "$selected_index" -lt 0 ] && selected_index=$((cnt-1)); [ "$selected_index" -ge "$cnt" ] && selected_index=0
done