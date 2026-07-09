#!/bin/bash

# Ensure we are running in Bash, not Zsh (if sourced or run with 'zsh script.sh')
if [ -n "${ZSH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "$0" ]; then
        echo "Error: This script is not meant to be sourced directly in Zsh."
        return 1
    else
        # Re-execute with bash if run as 'zsh script.sh'
        exec bash "$0" "$@"
    fi
fi

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


# --- PERFORMANCE FLAGS (can be set via environment) ---
RUN_PARALLEL_DEPS="${RUN_PARALLEL_DEPS:-0}"      # Enable parallel dependency execution
RUN_CACHE_PROFILES="${RUN_CACHE_PROFILES:-1}"   # Cache profile listings (60s TTL)
# Optimierung für macOS/BSD Grep (Locale-Reset für Geschwindigkeit bei Sortierung/Regex)
# Aber UTF-8 Zeichen müssen erhalten bleiben, daher nur Collate auf C setzen.
export LC_COLLATE=C

# --- PLATFORM DETECTION ---
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
last_config_mtime=0
cached_menu_options=""
DEBUG_MODE=0

# --- SETTINGS STATE ---
readonly DEFAULT_LANG="DE"
readonly DEFAULT_THEME="CYBER"
readonly DEFAULT_COLS_MIN=1
readonly DEFAULT_COLS_MAX=4
readonly DEFAULT_COLS_MIN_WIDTH=30
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
    set +e +o pipefail  # Disable errexit and pipefail for grep operations
    [ ! -f "$config_path" ] && return
    TASK_THEME=$(awk -F':' '/^# THEME:/ {val=$2; gsub(/^[ \t]+|[ \t]+$/, "", val); print val; exit}' "$config_path" 2>/dev/null)
    task_timeout=$(extract_field_from_grep "^TIMEOUT=" "=" 2)
    task_timeout="${task_timeout:-$RUN_TASK_TIMEOUT}"
    load_task_vars
    set -e -o pipefail  # Re-enable errexit and pipefail
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
        case "$line" in
            ""|\#*) continue ;;
        esac
        local key="${line%%=*}"
        local value="${line#*=}"
        case "$key" in
            THEME)          SETTINGS_THEME="$value" ;;
            LANG)           SETTINGS_LANG="$value" ;;
            COLS_MIN)       SETTINGS_COLS_MIN="$value" ;;
            COLS_MAX)       SETTINGS_COLS_MAX="$value" ;;
            COLS_MIN_WIDTH) SETTINGS_COLS_MIN_WIDTH="$value" ;;
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
#  POLYFILLS & UTILS
# ==============================================================================

get_realpath() {
    if command -v realpath &>/dev/null; then
        realpath "$1"
    elif [[ "$1" = /* ]]; then
        # Absoluter Pfad: direkt zurückgeben (macOS ohne GNU-coreutils hat kein realpath)
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

# Color output helpers
info() { echo -e "${COLOR_INFO}$*${COLOR_RESET}"; }
warn() { echo -e "${COLOR_WARN}$*${COLOR_RESET}"; }
error() { echo -e "${COLOR_ERR}$*${COLOR_RESET}"; }
success() { echo -e "${COLOR_SEL}✔ $*${COLOR_RESET}"; }
dim() { echo -e "${COLOR_DIM}$*${COLOR_RESET}"; }

sanitize_filename() { sed 's/ /_/g; s/[^A-Za-z0-9._-]//g' <<< "$1"; }

# Kürzt eine Datei auf maximal $2 Zeilen (via tail).
# Wird von add_to_history, add_to_recent und save_search_term genutzt.
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

# Cross-platform file mtime (optimization: check method once)
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
#  UI RENDERING & KEYBOARD INPUT HANDLING
# ==============================================================================

# Terminal capabilities are initialized in 03-terminal.sh via init_terminal_capabilities

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
  #               Filter by tags
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
    # Cache check for performance
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
    
    # Build menu options
    local level_str=""
    local search_pattern=""
    local tag_pattern=""
    
    if [ "$current_level" -gt 0 ]; then
        level_str="${history_name_stack[$current_level]}"
    fi
    
    if [ -n "$filter_query" ]; then
        # tr mit here-string: kein echo-Subshell-Pipe
        search_pattern=$(tr '[:upper:]' '[:lower:]' <<< "$filter_query")
    fi
    
    if [ -n "$tag_filter" ]; then
        tag_pattern="$tag_filter"
    fi
    
    local result=""
    # Process substitution: Config-Inhalt direkt streamen — kein all_output-String-Kopie im Speicher
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^TIMEOUT= ]] && continue
        [[ "$line" =~ ^VAR_ ]] && continue
        [[ "$line" =~ ^THEME: ]] && continue
        [[ "$line" =~ ^TITLE: ]] && continue

        IFS='|' read -r level name cmd desc <<< "$line"
        [ -z "$name" ] && continue

        # Level filtering
        if [ "$current_level" -eq 0 ]; then
            [ "$level" != "0" ] && continue
        else
            [ "$level" != "$((current_level))" ] && continue
            if [ -n "$level_str" ] && [[ ! "$name" =~ ^$level_str\. ]]; then
                continue
            fi
        fi

        # Search filtering
        if [ -n "$search_pattern" ]; then
            local search_text
            # here-string statt echo|tr: spart einen Subshell-Pipe-Prozess pro Zeile
            search_text=$(tr '[:upper:]' '[:lower:]' <<< "$name $desc")
            [[ ! "$search_text" =~ $search_pattern ]] && continue
        fi

        # Tag filtering
        if [ -n "$tag_pattern" ]; then
            has_tag "$desc" "$tag_pattern" || continue
        fi

        # Append to result buffer (do not echo here to avoid recursion)
        result+="${level}|${name}|${cmd}|${desc}"$'\n'
    done < <(
        if [ "${#task_config_files[@]}" -gt 0 ]; then
            cat "${task_config_files[@]}" 2>/dev/null || true
        elif [ -f "$config_path" ]; then
            cat "$config_path"
        fi
    )

    # Cache result (store the constructed string, avoid calling get_menu_options again)
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -z "$filter_query" ] && [ -z "$tag_filter" ] && [ -f "$config_path" ]; then
        cached_menu_options="$result"
        last_config_mtime=$(get_file_mtime "$config_path")
    fi

    # Emit result
    printf "%s" "$result"
}

draw_menu() {
    if [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_CUP" ]; then
        echo -ne "$TPUT_CUP"
    else
        clear
    fi
    hide_cursor

    # ── Header ───────────────────────────────────────────────────────
    local mode_indicator="[${active_mode}]"
    if [ "$active_mode" = "global" ] && [ -f "$config_path" ]; then
        local _bn="${config_path##*/}"
        local _pname="${_bn##.tasks}"; _pname="${_pname#.}"
        [ -n "$_pname" ] && mode_indicator="[${_pname}]"
    fi
    echo -e "${COLOR_HEAD}════ Shell Menu Runner ${VERSION} ${mode_indicator} ════${COLOR_RESET}"

    # Context line (git branch, hostname, env) — empty string = no line
    [ -n "${_CTX_LINE:-}" ] && echo -e "${_CTX_LINE}"

    if [ "$current_level" -gt 0 ]; then
        local _bc=""
        for _bname in "${history_name_stack[@]}"; do _bc="${_bc}${_bname} > "; done
        echo -e "${COLOR_DIM}${_bc%> }${COLOR_RESET}"
    fi
    [ -n "$filter_query" ] && echo -e "${COLOR_INFO}📎 Filter: $filter_query${COLOR_RESET}"
    [ -n "$tag_filter"   ] && echo -e "${COLOR_INFO}🏷  Tag: $tag_filter${COLOR_RESET}"
    echo ""

    # ── Empty state ──────────────────────────────────────────────────
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tasks found. Press 'e' to edit config or '?' for help.${COLOR_RESET}"
        [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
        return
    fi

    # ── Layout ───────────────────────────────────────────────────────
    calculate_layout "$total"
    local rows=$_layout_rows cols=$_layout_cols
    local term_width="${TPUT_COLS:-80}"
    local col_width=$(( term_width / cols ))
    local inner=$(( col_width - 4 ))
    [ "$inner" -lt 1 ] && inner=1
    local name_max=$(( inner - 4 ))
    [ "$name_max" -lt 1 ] && name_max=1

    # Rebuild border strings when col_width changed (e.g. terminal resize)
    if [ "$col_width" -ne "${_LAST_COL_WIDTH:-0}" ]; then
        build_border_strings "$col_width"
    fi

    # ── Grid rendering (3 lines per row) ─────────────────────────────
    local r c idx
    local gap="  "   # 2-space gap between columns; added BEFORE column (not after)

    for (( r=0; r<rows; r++ )); do
        local top_line="" content_line="" bot_line=""
        local first_in_row=1

        for (( c=0; c<cols; c++ )); do
            idx=$(( r + c * rows ))
            [ "$idx" -ge "$total" ] && continue

            local border_color="$COLOR_DIM"
            [ "$idx" -eq "$selected_index" ] && border_color="$COLOR_SEL"

            # Gap before all columns except the first in this row
            if [ "$first_in_row" -eq 0 ]; then
                top_line+="$gap"
                content_line+="$gap"
                bot_line+="$gap"
            fi
            first_in_row=0

            # Top/bottom border
            top_line+="${border_color}${_BORDER_TOP}${COLOR_RESET}"
            bot_line+="${border_color}${_BORDER_BOT}${COLOR_RESET}"

            # Content
            # shellcheck disable=SC2034
            IFS='|' read -r _lvl _name _cmd _desc <<< "${menu_options[$idx]}"

            local marker="  "
            local text_color="$COLOR_DIM"
            if [ "$idx" -eq "$selected_index" ]; then
                marker="► "; text_color="$COLOR_BOLD"
            fi
            if [ -n "${multi_select_map[$idx]:-}" ]; then
                marker="☑ "; text_color="$COLOR_INFO"
            fi

            # Truncate name to fit
            if [ "${#_name}" -gt "$name_max" ]; then
                local _trunc=$(( name_max - 3 ))
                [ "$_trunc" -lt 1 ] && _trunc=1
                _name="${_name:0:$_trunc}..."
            fi
            # Pad name to name_max chars — printf -v avoids subshell
            local _padded
            printf -v _padded "%-*s" "$name_max" "$_name"

            content_line+="${border_color}│${COLOR_RESET} ${text_color}${marker}${_padded}${COLOR_RESET} ${border_color}│${COLOR_RESET}"
        done

        echo -e "$top_line"
        echo -e "$content_line"
        echo -e "$bot_line"
    done

    # ── Footer hints ─────────────────────────────────────────────────
    echo ""
    if [ "$cols" -gt 1 ]; then
        echo -e "${COLOR_DIM}[↑↓ ←→ h/l] Navigate | [Enter] Execute | [/] Search | [Space] Multi | [?] Help${COLOR_RESET}"
    else
        echo -e "${COLOR_DIM}[↑↓] Navigate | [Enter] Execute | [/] Search | [Space] Multi | [?] Help${COLOR_RESET}"
    fi

    [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
}

# ==============================================================================
#  MAIN INTERACTIVE LOOP WITH KEYBOARD HANDLING
# ==============================================================================

# Lädt menu_options neu und aktualisiert calculate_layout.
_reload_menu() {
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    calculate_layout "${#menu_options[@]}"
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
        # Only redraw if needed (performance optimization)
        if [ "$redraw_needed" -eq 1 ]; then
            draw_menu
            redraw_needed=0
        fi
        
        # ══════════════════════════════════════════════════════════════
        #  KEYBOARD INPUT HANDLING
        # ══════════════════════════════════════════════════════════════
        local key="" _rk_status=0
        if [ "$is_interactive" -eq 1 ]; then
            # Capture exit status separately: command substitution strips trailing \n,
            # so a real Enter (\n) correctly becomes "".  But if read_key_raw fails
            # (e.g. EINTR from a signal), we must NOT treat the empty result as Enter.
            key=$(read_key_raw); _rk_status=$?
            [ "$_rk_status" -ne 0 ] && continue
        else
            # Non-interactive: read line (for SSH without TTY)
            read -r key || break
        fi
        
        # ══════════════════════════════════════════════════════════════
        #  KEY HANDLING
        # ══════════════════════════════════════════════════════════════
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
            $'\r'|$'\n'|"") # ENTER: \r = raw CR, \n = LF, "" = \n stripped by $()
                set +u
                [ ${#menu_options[@]} -eq 0 ] && { set -u; continue; }
                
                # Multi-select execution
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
                
                # Single execution
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
                # Internal operation, no restore needed
                if [ "$selected_index" -lt "$num" ]; then
                    IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
                    toggle_favorite "$name"
                fi
                redraw_needed=1;;
            "r"|"R") run_with_term_paused show_favorites; redraw_needed=1;;
            "q"|"Q") restore_term; clear; exit 0;;
        esac
        
        # Wrap around selection index
        local cnt=${#menu_options[@]}
        [ "$selected_index" -lt 0 ] && selected_index=$((cnt-1))
        [ "$selected_index" -ge "$cnt" ] && selected_index=0
    done
}

# ==============================================================================
#  CONTEXT MENU
# ==============================================================================

context_menu() {
    # menu_options ist global stets aktuell — kein erneuter get_menu_options-Aufruf nötig
    local num=${#menu_options[@]}
    [ "$num" -eq 0 ] && return
    [ "$selected_index" -ge "$num" ] && return
    IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
    if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
        echo -e "${COLOR_WARN}No context actions for this entry.${COLOR_RESET}"
        sleep 1
        return
    fi
    
    # Show context menu with available actions
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
        # ${RUN_EXPECTED_SHA256:-} guards against 'unbound variable' with set -u
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
        # Bash-String-Op statt echo|tr-Pipe (kein Fork)
        echo -e "${COLOR_INFO}Profiles available:${COLOR_RESET} ${profiles_list//$'\n'/ }"
        echo -e "${COLOR_DIM}Press [p] to choose a profile or any other key to continue...${COLOR_RESET}"
        key=$(read_key) || key=""
        # Drain any remaining bytes (arrow-key sequences etc.) so they don't
        # leak into the main interactive loop that starts afterwards.
        drain_stdin
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
        # Fallback: Load default global profile or show error
        echo -e "${COLOR_WARN}No .tasks file found.${COLOR_RESET}"
        exit 1
    fi
fi

parse_config_vars
load_settings
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

# Load menu options once before loop
IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
num=${#menu_options[@]}
calculate_layout "$num"; rows=$_layout_rows; cols=$_layout_cols
redraw_needed=1

# Main interactive loop is in 13-ui.sh
main_interactive_loop
