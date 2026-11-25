#!/bin/bash
if [ -n "${ZSH_VERSION:-}" ]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
        toplevel)
            exec bash "$0" "$@"
            ;;
        *)
            echo "Error: This script is not meant to be sourced directly in Zsh." >&2
            return 1
            ;;
    esac
fi
readonly VERSION="2.1.3"
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
RUN_PARALLEL_DEPS="${RUN_PARALLEL_DEPS:-0}"      # Enable parallel dependency execution
RUN_CACHE_PROFILES="${RUN_CACHE_PROFILES:-1}"   # Cache the parsed menu/task list
RUN_MINIMAL="${RUN_MINIMAL:-0}"
export LC_COLLATE=C
set -euo pipefail
trap '' PIPE 2>/dev/null || true
COLOR_HEAD=$'\e[1;34m'; COLOR_SEL=$'\e[1;32m'; COLOR_ERR=$'\e[1;31m'
COLOR_WARN=$'\e[1;33m'; COLOR_INFO=$'\e[33m';  COLOR_DIM=$'\e[2m'
COLOR_RESET=$'\e[0m';   COLOR_BOLD=$'\e[0;1m'
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
DEBUG_MODE=0
_menu_cache_key=""
last_config_stamp=""
_menu_cache_config_path=""
cli_mode=0          # 1 when --run is active; skips interactive prompts in execute_task
cli_run_query=""    # query string passed to --run
cli_list_mode=0     # 1 when --list is active
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
parse_config_vars() {
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
get_local_settings_path() {
    if [ -n "$config_path" ]; then
        local _dir="${config_path%/*}"
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
        line="${line%$'\r'}"
        case "$line" in
            ""|\#*) continue ;;
        esac
        local key="${line%%=*}"
        local value="${line#*=}"
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
THEME=$UI_THEME
LANG=$UI_LANG
COLS_MIN=$COLS_MIN
COLS_MAX=$COLS_MAX
COLS_MIN_WIDTH=$COLS_MIN_WIDTH
CONTEXT_SHOW=$CONTEXT_SHOW
EOF
}
detect_config_files() {
    local config_dir
    if [ "$active_mode" = "local" ]; then
        config_dir="${config_path%/*}"
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
    if [ "${#task_config_files[@]}" -gt 0 ]; then
        cat "${task_config_files[@]}" 2>/dev/null || true
    elif [ -f "$config_path" ]; then
        cat "$config_path"
    elif [ -f ".tasks" ]; then
        cat ".tasks"
    fi
}
_all_tasks_cache=()
_all_tasks_cache_key=""
ALL_TASKS_ARRAY=()
_build_all_tasks() {
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
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        is_meta_task_line "$line" && continue
        split_task_line "$line"
        level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
        [ -z "$name" ] && continue
        case "$level" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
            continue
        fi
        _all_tasks_result+=("${level}|${name}|${cmd}|${desc}")
    done < <(merge_configs)
    _all_tasks_cache=("${_all_tasks_result[@]+"${_all_tasks_result[@]}"}")
    _all_tasks_cache_key="$_sig"
    ALL_TASKS_ARRAY=("${_all_tasks_result[@]+"${_all_tasks_result[@]}"}")
    return 0
}
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
if command -v rg >/dev/null 2>&1; then
    _grep() { rg "$@"; }
else
    _grep() { grep "$@"; }
fi
get_realpath() {
    if command -v realpath &>/dev/null; then
        realpath "$1"
    elif [[ "$1" = /* ]]; then
        echo "$1"
    else
        echo "$PWD/${1#./}"
    fi
}
config_dir_of() {
    local _path="${1:-}"
    local _dir
    [ -z "$_path" ] && { printf "."; return 0; }
    _dir="${_path%/*}"
    [ "$_dir" = "$_path" ] && _dir="."
    [ -z "$_dir" ] && _dir="/"
    printf "%s" "$_dir"
}
cleanup_terminal() {
    stty sane 2>/dev/null || true
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
warn() { echo -e "${COLOR_WARN}$*${COLOR_RESET}"; }
error() { echo -e "${COLOR_ERR}$*${COLOR_RESET}"; }
success() { echo -e "${COLOR_SEL}✔ $*${COLOR_RESET}"; }
sanitize_filename() { sed 's/ /_/g; s/[^A-Za-z0-9._-]//g' <<< "$1"; }
_lock_acquire() {
    local _dir="${1}.lock"
    local _parent="${_dir%/*}"
    [ "$_parent" = "$_dir" ] && _parent="."
    local _n=0
    while ! mkdir "$_dir" 2>/dev/null; do
        _n=$(( _n + 1 ))
        if [ "$_n" -eq 1 ] && [ ! -w "$_parent" ]; then
            break
        fi
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
_f_level=""
_f_name=""
_f_cmd=""
_f_desc=""
split_task_line() {
    local _rest="$1"
    _f_level="${_rest%%|*}"
    if [ "$_f_level" = "$_rest" ]; then
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
is_meta_task_line() {
    local _line="$1"
    case "${_line#"${_line%%[![:space:]]*}"}" in
        \#*|TIMEOUT=*|VAR_*|THEME:*|TITLE:*) return 0 ;;
    esac
    return 1
}
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
get_files_stamp() {
    [ $# -eq 0 ] && { printf ""; return 0; }
    if [ -z "${_STAT_STAMP_CMD:-}" ]; then
        if stat -f '%m:%z' / >/dev/null 2>&1; then
            _STAT_STAMP_CMD="stat -f %m:%z"
        else
            _STAT_STAMP_CMD="stat -c %Y:%s"
        fi
    fi
    local _existing=()
    local _f
    for _f in "$@"; do
        [ -f "$_f" ] && _existing+=("$_f")
    done
    [ ${#_existing[@]} -eq 0 ] && { printf "0:0"; return 0; }
    $_STAT_STAMP_CMD "${_existing[@]}" 2>/dev/null | tr '\n' ' ' || printf "0:0"
    return 0
}
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
is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}
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
_CTX_LINE=""
_CTX_LINE_PLAIN=""
_CTX_BRANCH=""
_CTX_HOST=""
_CTX_ENV=""
_LAST_COL_WIDTH=0
_BORDER_TOP=""
_BORDER_BOT=""
HAS_TPUT=0
TPUT_CUP=""
TPUT_CIVIS=""
TPUT_CNORM=""
TPUT_ED=""
TPUT_COLS=80
TPUT_LINES=24
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
restore_term() {
    restore_terminal_state
}
check_interactive() {
    if [ -t 0 ]; then
        is_interactive=1
        save_terminal_state
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
init_context() {
    _CTX_LINE=""; _CTX_LINE_PLAIN=""; _CTX_BRANCH=""; _CTX_HOST=""; _CTX_ENV=""
    local show="${CONTEXT_SHOW:-git,hostname,env}"
    local parts=()
    local plain_parts=()
    if [[ "$show" == *"git"* ]]; then
        _CTX_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        [ -n "$_CTX_BRANCH" ] && parts+=("${COLOR_INFO}⎇ ${_CTX_BRANCH}${COLOR_RESET}")
        [ -n "$_CTX_BRANCH" ] && plain_parts+=("⎇ ${_CTX_BRANCH}")
    fi
    if [[ "$show" == *"hostname"* ]]; then
        if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
            _CTX_HOST="${HOSTNAME:-$(hostname 2>/dev/null || true)}"
            [ -n "$_CTX_HOST" ] && parts+=("${COLOR_ERR}⚡ ${_CTX_HOST}${COLOR_RESET}")
            [ -n "$_CTX_HOST" ] && plain_parts+=("⚡ ${_CTX_HOST}")
        fi
    fi
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
    local dashes="" i
    for (( i=0; i<inner; i++ )); do dashes+='─'; done
    _BORDER_TOP="┌${dashes}┐"
    _BORDER_BOT="└${dashes}┘"
    _LAST_COL_WIDTH="$col_width"
}
_U8_STR=""
_U8_POS=0
_U8_CP=0
_U8_LEN=0
_U8_WIDTH=0
DISPLAY_WIDTH=0
FIT_TEXT=""
_HINT_MID_WIDTH=0
_HINT_FULL_WIDTH=0
_HINT_WIDTHS_KEY=""
_u8_width() {
    local _cp="$1"
    _U8_WIDTH=1
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
display_width() {
    local _s="$1"
    local _w=0 _i=0 _len _lc_saved="" _lc_was_set=0
    case "$_s" in
        *[![:ascii:]]*) ;;
        *) DISPLAY_WIDTH=${#_s}; return 0 ;;
    esac
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
fit_to_width() {
    local _s="$1" _max="$2"
    local _w=0 _i=0 _len _out="" _truncated=0 _limit _pad _spaces="" _lc_saved="" _lc_was_set=0
    FIT_TEXT=""
    [ "$_max" -lt 1 ] && return 0
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
    [ -n "${LC_ALL+x}" ] && { _lc_was_set=1; _lc_saved="$LC_ALL"; }
    LC_ALL=C
    _U8_STR="$_s"
    _len=${#_U8_STR}
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
separator_line() {
    local _max="${1:-63}"
    local _width="${TPUT_COLS:-80}"
    local _len _i _out=""
    [ "$_width" -gt "$_max" ] && _width=$_max
    [ "$_width" -lt 10 ] && _width=10
    for (( _i=0; _i<_width; _i++ )); do _out+='─'; done
    printf "%s" "$_out"
}
_TPUT_INITIALIZED=0
init_terminal_capabilities() {
    [ "${_TPUT_INITIALIZED:-0}" -eq 1 ] && return
    _TPUT_INITIALIZED=1
    if command -v tput >/dev/null 2>&1; then
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
    is_uint "${TPUT_COLS:-}" && [ "${TPUT_COLS:-0}" -ge 1 ] || TPUT_COLS=80
    is_uint "${TPUT_LINES:-}" && [ "${TPUT_LINES:-0}" -ge 1 ] || TPUT_LINES=24
    trap 'TPUT_COLS=$(tput cols 2>/dev/null || echo 80); TPUT_LINES=$(tput lines 2>/dev/null || echo 24); _LAST_COL_WIDTH=0' WINCH
    init_context
}
consume_keypress() {
    stty -echo 2>/dev/null || true
    read_key >/dev/null || true
    drain_stdin
    stty echo 2>/dev/null || true
}
set_raw_mode() {
    stty -echo -icanon time 0 min 1 isig 2>/dev/null || true
}
drain_stdin() {
    [ -t 0 ] || return 0
    stty -icanon min 0 time 0 2>/dev/null || true
    head -c 4096 >/dev/null 2>&1 || true
    stty min 1 time 0 2>/dev/null || true
    return 0
}
restore_int_trap() {
    if [ "${_MENU_LOOP_ACTIVE:-0}" -eq 1 ]; then
        trap 'restore_term; cleanup_wrapper; exit 130' INT TERM
    else
        trap 'cleanup_wrapper; exit 130' INT TERM
    fi
    return 0
}
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
    if ! IFS= read -rsn1 key; then return 1; fi
    if [ "$key" = $'\x1b' ]; then
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
read_key_raw() {
    local key=""
    if ! IFS= read -rsn1 key; then return 1; fi
    if [ "$key" = $'\x1b' ]; then
        stty min 0 time 1 2>/dev/null || true
        local seq
        seq=$(dd bs=10 count=1 2>/dev/null)
        stty min 1 time 0 2>/dev/null || true
        key="${key}${seq}"
    fi
    printf "%s" "$key"
}
read_key_optional() {
    local _key=""
    local _prev_stty
    local _timeout="${1:-2}"
    _prev_stty=$(stty -g 2>/dev/null || true)
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
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r%80s\r" " "  # Clear spinner line
        if [ -n "${TPUT_CNORM:-}" ]; then echo -ne "$TPUT_CNORM"; else tput cnorm 2>/dev/null || true; fi
    fi
}
readonly CACHE_DIR="/tmp/.run_cache_$$"
mkdir -p "$CACHE_DIR" 2>/dev/null || true
RUN_CACHE_DIR="${RUN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/shell-menu-runner}"
if ! mkdir -p "$RUN_CACHE_DIR" 2>/dev/null; then
    RUN_CACHE_DIR="${TMPDIR:-/tmp}/.shell-menu-runner-${UID:-0}"
    if ! mkdir -p "$RUN_CACHE_DIR" 2>/dev/null; then
        RUN_CACHE_DIR="$CACHE_DIR"
    fi
fi
readonly RUN_CACHE_DIR
_cache_file_last_path=""
_cache_file_last_result=""
get_cache_file() {
    if [ "$config_path" = "$_cache_file_last_path" ] && [ -n "$_cache_file_last_result" ]; then
        echo "$_cache_file_last_result"
        return 0
    fi
    local config_hash
    config_hash=$(hash_string "$config_path")
    _cache_file_last_path="$config_path"
    _cache_file_last_result="$RUN_CACHE_DIR/state_${config_hash}"
    echo "$_cache_file_last_result"
}
save_state() {
    local cf
    cf=$(get_cache_file)
    mkdir -p "${cf%/*}" 2>/dev/null || true
    if ! echo "$selected_index" > "$cf" 2>/dev/null; then
        echo "WARN: failed to save state to $cf" >&2
    fi
}
load_state() {
    local c
    c=$(get_cache_file)
    if [ -f "$c" ]; then
        local _stored_index=""
        { read -r _stored_index < "$c"; } 2>/dev/null || true
        if is_uint "${_stored_index:-}" && [ "${_stored_index:-0}" -ge 0 ]; then
            selected_index="$_stored_index"
        fi
    fi
    return 0
}
cleanup_wrapper() {
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
find_local_config() {
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/$LOCAL_CONFIG" ]; then
            echo "$d/$LOCAL_CONFIG"
            return 0
        fi
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
    case "$name" in
        */*|*" "*) echo "Error: invalid profile name (no '/' or spaces)"; return 1 ;;
    esac
    local profile_file="$PWD/.tasks.$name"
    [ -f "$profile_file" ] && { echo "Profile $name already exists at $profile_file"; return 1; }
    echo "Creating profile: $name"
    local template
    template="$(cat << 'EOF'
0|Task Name|command|Description here
0|Another Task|echo "Hello"|Runs a simple command
EOF
)"
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
        level="${level%$'\r'}"
        name="${name%$'\r'}"
        cmd="${cmd%$'\r'}"
        desc="${desc%$'\r'}"
        extra="${extra%$'\r'}"
        [[ "$level" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$level" ]] && continue
        if [ -z "$name" ] || [ -z "$cmd" ]; then
            echo "  Line $line_no: Invalid format (missing fields)"
            errors=$((errors + 1))
            syntax_ok=false
        fi
        if ! is_uint "$level"; then
            echo "  Line $line_no: Invalid level '$level' (must be a number)"
            errors=$((errors + 1))
            syntax_ok=false
        fi
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
        echo "{"
        echo "  \"profiles\": ["
        local first=1
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
load_profile_config() {
    local profile_name="$1"
    local saved_mode="$active_mode"
    local saved_config_path="$config_path"
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
        if [ "$filter_active" -eq 1 ] && [ -n "$filter_pattern" ]; then
            filtered_profiles=()
            for prof in "${profiles[@]}"; do
                if [[ "$prof" == *"$filter_pattern"* ]]; then
                    filtered_profiles+=("$prof")
                fi
            done
            display_profiles=("${filtered_profiles[@]+"${filtered_profiles[@]}"}")
            display_num=${#display_profiles[@]}
        else
            display_profiles=("${profiles[@]}")
            display_num=${#display_profiles[@]}
        fi
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
SEARCH_HISTORY_FILE="$HOME/.run_search_history"
SEARCH_HISTORY_MAX=20
save_search_term() {
    local term="$1"
    [ -z "$term" ] && return
    _lock_acquire "$SEARCH_HISTORY_FILE"
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
        local tmp="${SEARCH_HISTORY_FILE}.tmp.$$"
        _grep -vxF -e "$term" -- "$SEARCH_HISTORY_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$SEARCH_HISTORY_FILE" 2>/dev/null || rm -f "$tmp"
    fi
    printf '%s\n' "$term" >> "$SEARCH_HISTORY_FILE"
    _trim_file_to_lines "$SEARCH_HISTORY_FILE" "$SEARCH_HISTORY_MAX"
    _lock_release "$SEARCH_HISTORY_FILE"
    return 0
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
EXTRACTED_TAG_LIST=()
extract_tags() {
    local desc="$1"
    EXTRACTED_TAG_LIST=()
    local rest="$desc"
    while [[ "$rest" =~ (#[a-zA-Z0-9_-]+) ]]; do
        local _tag="${BASH_REMATCH[1]}"
        EXTRACTED_TAG_LIST+=("$_tag")
        rest="${rest#*"$_tag"}"
    done
}
has_tag() {
    local desc="$1"
    local tag="$2"
    local needle="${tag#\#}"
    case "$needle" in
        ''|*[!a-zA-Z0-9_-]*) return 1 ;;
    esac
    local rest="$desc"
    while :; do
        case "$rest" in
            *"#$needle")
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
    local IFS=$' \t\n'
    while read -r _tag_line || [ -n "$_tag_line" ]; do
        _tag_line="${_tag_line%$'\r'}"
        split_task_line "$_tag_line"
        extract_tags "$_f_desc"
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
    if [ "$num_tags" -gt 9 ]; then
        echo "[1-9] [0-9+Enter] Filter [q]uit"
    else
        echo "[1-9] Filter [q]uit"
    fi
    local _buf=""
    while true; do
        key=$(read_key) || break
        case "$key" in
            "0")
                if [ -n "$_buf" ]; then
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
                if [ "$num_tags" -gt 9 ]; then
                    _buf="$key"
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
readonly RUN_FAVORITES_FILE="$HOME/.run_favorites"
is_favorite() {
    local task_name="$1"
    if [ -f "$RUN_FAVORITES_FILE" ]; then
        _grep -qxF -e "$task_name" -- "$RUN_FAVORITES_FILE" || return 1
    else
        return 1
    fi
}
toggle_favorite() {
    local task_name="$1"
    _lock_acquire "$RUN_FAVORITES_FILE"
    if is_favorite "$task_name"; then
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
            local _num="$key"
            if [ "$fav_count" -gt 9 ] && [ "$_num" != "0" ]; then
                local _second
                _second=$(read_key_optional 5)
                if [ -n "$_second" ] && [[ "$_second" =~ ^[0-9]$ ]]; then
                    _num="${_num}${_second}"
                fi
            fi
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
add_to_history() {
    local task_name="$1"
    local exit_code="$2"
    local exec_time="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local status="✔"
    [ "$exit_code" -ne 0 ] && status="✗"
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
        while IFS= read -r line; do
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
    if [ ${#lines[@]} -eq 0 ]; then
        echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
        consume_keypress
        return
    fi
    local idx=1
    local line _path _name _rest
    for line in "${lines[@]}"; do
        _rest="${line#*|}"
        _path="${_rest%%|*}"
        _rest="${_rest#*|}"
        _name="${_rest%%|*}"
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
            local _num="$key"
            if [ "$_num_entries" -gt 9 ] && [ "$_num" != "0" ]; then
                local _second
                _second=$(read_key_optional 5)
                if [ -n "$_second" ] && [[ "$_second" =~ ^[0-9]$ ]]; then
                    _num="${_num}${_second}"
                fi
            fi
            if selection_index "$_num" "$_num_entries"; then
                local sel="$SELECT_INDEX"
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
    detect_config_files
    local _rc=0
    find_task_in_menu "$name" "_execute_recent_callback" || _rc=$?
    local _found="$_TASK_FOUND"
    config_path="$prev_config"
    active_mode="$prev_mode"
    detect_config_files
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
    IFS=$'\n' read -r -d '' -a log_files < <(find "$RUN_LOG_DIR" -type f -name "*.log" 2>/dev/null | sort -r | head -9 && printf '\0') || true
    if [ ${#log_files[@]} -eq 0 ]; then
        echo -e "${COLOR_DIM}$(msg no_logs)${COLOR_RESET}"
    else
        local idx=1
        local log_file
        for log_file in "${log_files[@]}"; do
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
parse_task_deps() {
    local task_cmd="$1"
    local task_desc="${2:-}"
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
    split_by_char ',' "$deps_str"
    local -a deps=("${_SPLIT_ARR[@]}")
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    if [ "${RUN_PARALLEL_DEPS:-0}" = "1" ] && [ "${#deps[@]}" -gt 1 ]; then
        echo -e "${COLOR_DIM}  (running ${#deps[@]} dependencies in parallel)${COLOR_RESET}"
        local -a dep_pids=()
        local -a dep_names=()
        local -a dep_logs=()
        for dep in "${deps[@]}"; do
            dep=$(trim_whitespace "$dep")
            [ -z "$dep" ] && continue
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"
            local dep_log="${CACHE_DIR}/dep_${dep}_$$.log"
            dep_logs+=("$dep_log")
            dep_names+=("$dep")
            (
                find_task_in_menu "$dep" '_execute_dep_callback_quiet' 2>&1 | tee "$dep_log"
                exit "${PIPESTATUS[0]}"
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
        for log in "${dep_logs[@]+"${dep_logs[@]}"}"; do
            [ -f "$log" ] && rm -f "$log"
        done
        [ "$all_success" -eq 0 ] && return 1
        return 0
    else
        for dep in "${deps[@]}"; do
            dep=$(trim_whitespace "$dep")
            [ -z "$dep" ] && continue
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"
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
_execute_dep_callback_quiet() {
    local dep_name="$1"
    local dep_cmd="$2"
    local dep_desc="$3"
    execute_task_quiet "$dep_cmd" "$dep_name" "$dep_desc" || return 1
}
execute_multi_profile_task() {
    local task_name="$1"
    local profiles_str="$2"  # comma-separated
    split_by_char ',' "$profiles_str"
    local -a profiles=("${_SPLIT_ARR[@]}")
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
        for log in "${profile_logs[@]+"${profile_logs[@]}"}"; do
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
            /RUN_PARALLEL_DEPS=1|RUN_PARALLEL_MULTI=1/ { par++ }
            tolower($0) ~ /lint|eslint|pylint/ { lint++ }
            tolower($0) ~ /test|jest|pytest/   { tst++ }
            tolower($0) ~ /build|compile/      { bld++ }
            tolower($0) ~ /deploy|push|release/{ dpl++ }
            tolower($0) ~ /test/               { tc++ }
            END { print (tot+0),(l0+0),(l1+0),(dep+0),(par+0),(lint+0),(tst+0),(bld+0),(dpl+0),(tc+0) }
        ' "$config_file" 2>/dev/null
    ) || true
    total_tasks="${total_tasks:-0}"; level_0="${level_0:-0}"; level_1="${level_1:-0}"
    deps_count="${deps_count:-0}"; parallel_count="${parallel_count:-0}"
    has_lint="${has_lint:-0}"; has_test="${has_test:-0}"; has_build="${has_build:-0}"
    has_deploy="${has_deploy:-0}"; test_count="${test_count:-0}"
    echo -e "\n${COLOR_SEL}📊 Project Analysis${COLOR_RESET}"
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
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
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}\n"
    return 0
}
_TASK_FOUND=0
find_task_in_menu() {
    local search_name="$1"
    local callback="$2"
    local -a opts=()
    _TASK_FOUND=0
    _build_all_tasks
    opts=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    [ ${#opts[@]} -eq 0 ] && return 1
    local _rc=0
    for opt in "${opts[@]}"; do
        split_task_line "$opt"
        if [ "$_f_name" = "$search_name" ]; then
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
    if [[ "$cmd" == *'<<'* ]]; then
        echo -e "${COLOR_INFO}ℹ This task has inputs that will be prompted${COLOR_RESET}\n"
    fi
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
select_dropdown() {
    local options_str="$1"
    local -a options=()
    split_by_char ',' "$options_str"
    local _opt
    if [ ${#_SPLIT_ARR[@]} -gt 0 ]; then
        for _opt in "${_SPLIT_ARR[@]}"; do
            [ -n "$_opt" ] && options+=("$_opt")
        done
    fi
    local selected=0
    local num=${#options[@]}
    [ "$num" -eq 0 ] && return 1
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
_execute_pipeline_callback() {
    local step_name="$1"
    local step_cmd="$2"
    local step_desc="$3"
    execute_task "$step_cmd" "$step_name" "$step_desc" || return 1
}
RUN_ENV_GUARD_SCRIPT='
_run_env_guard() {
    _g_path="$PATH"
    _g_ifs_set=0
    if [ -n "${IFS+set}" ]; then _g_ifs_set=1; _g_ifs="$IFS"; fi
    if [ -f ".env" ]; then
        set -a
        . ./.env
        set +a
    fi
    PATH="$_g_path"
    if [ "$_g_ifs_set" -eq 1 ]; then IFS="$_g_ifs"; else unset IFS; fi
    unset BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT
    unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
}
'
_parallel_task_pids=()
kill_children() {
    local _pid="$1" _sig="${2:-TERM}" _child
    for _child in $(pgrep -P "$_pid" 2>/dev/null); do
        kill -"$_sig" "$_child" 2>/dev/null || true
    done
    return 0
}
_kill_parallel_tasks() {
    local _p
    [ ${#_parallel_task_pids[@]} -eq 0 ] && return 0
    for _p in "${_parallel_task_pids[@]}"; do
        kill_children "$_p" TERM
        kill -TERM "$_p" 2>/dev/null || true
    done
}
_kill_process_tree() {
    local _pid="$1" _sig="${2:-TERM}" _child
    for _child in $(pgrep -P "$_pid" 2>/dev/null); do
        _kill_process_tree "$_child" "$_sig"
    done
    kill -"$_sig" "$_pid" 2>/dev/null || true
    return 0
}
TASK_EXIT_STATUS=0
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
        ( exec "$@" ) 2>&1 | tee -a "$_log"
        TASK_EXIT_STATUS="${PIPESTATUS[0]}"
        return 0
    fi
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
    (
        trap 'exit 0' TERM
        _n=0
        while [ ! -s "$_pidfile" ] && [ "$_n" -lt 20 ]; do
            sleep 0.1
            _n=$(( _n + 1 ))
        done
        sleep "$_secs"
        _wpid=$(cat "$_pidfile" 2>/dev/null)
        if [ -n "$_wpid" ] && [ ! -f "$_donefile" ]; then
            printf '1' > "$_timeoutfile"
            _kill_process_tree "$_wpid" TERM
            sleep 1
            _kill_process_tree "$_wpid" KILL
        fi
    ) >/dev/null 2>&1 &
    local _watchdog_pid=$!
    _WATCHDOG_PID="$_watchdog_pid"
    ( sh -c 'echo $PPID' > "$_pidfile"; exec "$@" ) > "$_fifo" 2>&1
    _rc=$?
    : > "$_donefile"
    kill_children "$_watchdog_pid" TERM
    kill "$_watchdog_pid" 2>/dev/null || true
    _WATCHDOG_PID=""
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
    split_by_char ';' "$steps_str"
    local -a steps=("${_SPLIT_ARR[@]}")
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
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
    local RUN_CONFIG_DIR
    RUN_CONFIG_DIR="$(config_dir_of "$config_path")"
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
        local log_file
        create_log_file "$name"
        log_file="$LOG_FILE"
        local start_time
        start_time=$(date +%s)
        local _par_body='
            trap - INT
            trap - PIPE
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            _run_env_guard
            eval "$RUN_CMD"
        '
        local _par_script="$RUN_ENV_GUARD_SCRIPT$_par_body"
        (
            run_task_streamed "$_par_script" "$log_file" "$task_timeout" \
                env \
                RUN_MODE="$active_mode" \
                RUN_DIR="$RUN_CONFIG_DIR" \
                RUN_CMD="$cmd" \
                bash -c "$_par_script"
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
        return 1
    fi
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
    _parallel_task_pids=()
    stty sane 2>/dev/null || true
    stty -echo 2>/dev/null || true
    drain_stdin
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
    return "$_failed"
}
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
        local _ph="<<${p}${default_spec}${rest}>>"
        if [[ "$rest" == :* ]]; then
            local opts_str="${rest:1}"
            echo -e "\n${COLOR_INFO}$(msg choose_for)${COLOR_RESET} $p"
            local r=""
            if ! r=$(select_dropdown "$opts_str"); then
                echo -e "${COLOR_INFO}$(msg task_cancelled)${COLOR_RESET}"
                RESOLVED_CMD=""
                return 1
            fi
            cmd="${cmd//\<\<"$p":"$opts_str"\>\>/${r:-}}"
        else
            echo -e "\n${COLOR_INFO}$(msg input_for)${COLOR_RESET} $p"
            local r=""
            if [ -n "$default_val" ]; then
                read -r -p "[${default_val}] > " r || true
                [ -z "${r:-}" ] && r="$default_val"
            else
                read -r -p "> " r || true
            fi
            cmd="${cmd//<<${p}${default_spec}>>/${r:-}}"
        fi
        if [[ "$cmd" == *"$_ph"* ]]; then
            cmd="${cmd//"$_ph"/}"
        fi
    done
    RESOLVED_CMD="$cmd"
    return 0
}
execute_task() {
    local cmd="$1"; local name="$2"; local desc="$3"; shift 3; local args=("$@")
    local _quiet=0
    [ "${TASK_QUIET:-0}" = "1" ] && _quiet=1
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
        tput cnorm 2>/dev/null || true
    fi
    if [ "$_quiet" -eq 0 ] && [ "${cli_mode:-0}" -eq 0 ]; then
        clear
    fi
    echo -e "${COLOR_HEAD}$(msg executing)${COLOR_RESET} $name"
    if [[ "$desc" == "[!]"* ]]; then
        echo -e "\n${COLOR_WARN}⚠ $(msg warning_label): ${desc#"[!] "}${COLOR_RESET}"
        read -p "$(msg confirm_prompt) " -n 1 -r || true; echo ""
        if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
            echo -e "${COLOR_INFO}$(msg task_cancelled)${COLOR_RESET}"
            return 1
        fi
    fi
    local deps
    deps=$(parse_task_deps "$cmd" "$desc")
    if [ -n "$deps" ]; then
        execute_task_deps "$deps" || return 1
        cmd="${cmd// \[depends:[^]]*\]/}"
    fi
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
    local start_time
    start_time=$(date +%s)
    :
    local exit_status=0
    local log_file
    create_log_file "$name"
    log_file="$LOG_FILE"
    local config_dir
    config_dir="$(config_dir_of "$config_path")"
    task_timeout_for_desc "$desc"
    local _timeout="$TASK_TIMEOUT_VALUE"
    local first_token="${cmd%% *}"
    if [[ "$first_token" == *=* ]]; then
        local _rest="${cmd#* }"
        if [[ "$_rest" == *'"'* || "$_rest" == *"'"* ]]; then
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
        local _exec_body='
            trap - INT
            trap - PIPE
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            _run_env_guard
            eval "$RUN_CMD $RUN_ARGS"
        '
        local _exec_script="$RUN_ENV_GUARD_SCRIPT$_exec_body"
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
    echo -e "${COLOR_DIM}⏱ ${task_execution_time}s${COLOR_RESET}"
    add_to_history "$name" "$exit_status" "$task_execution_time"
    echo -e "${COLOR_DIM}Log: $log_file${COLOR_RESET}"
    if command -v invalidate_menu_cache >/dev/null 2>&1; then
        invalidate_menu_cache
    else
        last_config_stamp=""
        _menu_cache_key=""
    fi
    if [ "$_quiet" -eq 0 ] && [ "${cli_mode:-0}" -eq 0 ]; then
        stty sane 2>/dev/null || true
        stty -echo 2>/dev/null || true
        tput cnorm 2>/dev/null || true
        drain_stdin
        echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
    fi
    return "$exit_status"
}
execute_task_quiet() {
    local _prev_quiet="${TASK_QUIET:-0}"
    local _rc=0
    TASK_QUIET=1
    execute_task "$@" || _rc=$?
    TASK_QUIET="$_prev_quiet"
    return "$_rc"
}
_cli_matches=()   # populated by cli_match_tasks(); array of matching indices
cli_match_tasks() {
    local query="$1"
    _cli_matches=()
    if [ ${#menu_options[@]} -eq 0 ]; then
        _build_all_tasks
        menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    fi
    local total=${#menu_options[@]}
    if [[ "$query" =~ ^[0-9]+$ ]]; then
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
    for (( i=0; i<total; i++ )); do
        split_task_line "${menu_options[$i]}"
        [[ "$_f_name" == "$query" ]] && _cli_matches+=("$i")
    done
    [ "${#_cli_matches[@]}" -gt 0 ] && { [ "$_nocase_was" -eq 0 ] && shopt -u nocasematch; return 0; }
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
                [ -z "$key" ] && { echo ""; echo "Cancelled."; return 0; }
            else
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
            if [ -t 0 ] && [ "${#key}" -eq 1 ] && [ "$match_count" -gt 9 ] && [ "$key" != "0" ]; then
                local _next
                _next=$(read_key_optional 10)
                if [ -n "$_next" ] && [[ "$_next" =~ ^[0-9]$ ]]; then
                    key="${key}${_next}"
                fi
            fi
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
    echo "Tasks ($total)" 2>/dev/null || return 0
    local i
    for (( i=0; i<total; i++ )); do
        split_task_line "${menu_options[$i]}"
        local num=$(( i + 1 ))
        printf "  %2d)  %-22s  %s\n" "$num" "${_f_name:0:22}" "$_f_desc" 2>/dev/null || break
    done
    return 0
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
            case "$key" in
                PATH|CDPATH|GLOBIGNORE|IFS|\
                BASH_ENV|ENV|SHELLOPTS|BASHOPTS|PROMPT_COMMAND|PS4|\
                LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|\
                DYLD_INSERT_LIBRARIES|DYLD_LIBRARY_PATH|DYLD_FRAMEWORK_PATH)
                    continue
                    ;;
            esac
            export "$key"="$value"
        fi
    done < "$RUN_VARS_FILE"
}
load_task_vars() {
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
_LOG_SEQ=0
LOG_FILE=""
create_log_file() {
    local task_name="$1"
    mkdir -p "$RUN_LOG_DIR" 2>/dev/null || true
    local safe_name
    safe_name=$(sanitize_filename "$task_name")
    [ -z "$safe_name" ] && safe_name="task"
    _LOG_SEQ=$(( _LOG_SEQ + 1 ))
    LOG_FILE="$RUN_LOG_DIR/$(date '+%Y-%m-%d_%H-%M-%S')_$$_${_LOG_SEQ}_${safe_name}.log"
    return 0
}
TASK_TIMEOUT_VALUE=""
task_timeout_for_desc() {
    local desc="${1:-}"
    TASK_TIMEOUT_VALUE="$task_timeout"
    if [[ "$desc" =~ \[timeout:[[:space:]]*([0-9]+)\] ]]; then
        local _t="${BASH_REMATCH[1]}"
        if [ "$_t" -gt 0 ]; then
            TASK_TIMEOUT_VALUE="$_t"
        fi
    fi
    return 0
}
extract_field_from_grep() {
    local pattern="$1"
    local delimiter="$2"
    local field_idx="$3"
    if [ -f "$config_path" ]; then
        awk -F"$delimiter" -v pat="$pattern" -v idx="$field_idx" '$0 ~ pat {val=$idx; gsub(/^[ \t]+|[ \t]+$/, "", val); print val; exit}' "$config_path" 2>/dev/null || true
    fi
}
declare -a _name_field_cache=()
_name_field_cache_key=""
MENU_RESULT_ARRAY=()
_cached_menu_array=()
_HEADER_CACHE_KEY=""
_HEADER_CACHE_TEXT=""
_menu_config_stamp() {
    get_files_stamp "$config_path" "${task_config_files[@]+"${task_config_files[@]}"}"
}
invalidate_menu_cache() {
    last_config_stamp=""
    _menu_cache_key=""
    _menu_cache_config_path=""
    return 0
}
_redraw_counter=0
calculate_layout() {
    local total="$1"
    local term_width="${TPUT_COLS:-80}"
    local min_col_width="${COLS_MIN_WIDTH:-30}"
    local max_cols="${COLS_MAX:-4}"
    local min_cols="${COLS_MIN:-1}"
    local cols=$(( term_width / min_col_width ))
    if [ "$max_cols" -gt 0 ] && [ "$cols" -gt "$max_cols" ]; then
        cols="$max_cols"
    fi
    if [ "$total" -gt 0 ]; then
        local max_useful=$(( (total + 1) / 2 ))
        [ "$cols" -gt "$max_useful" ] && cols="$max_useful"
    fi
    [ "$cols" -lt "$min_cols" ] && cols="$min_cols"
    [ "$cols" -lt 1 ] && cols=1
    local rows=$(( (total + cols - 1) / cols ))
    [ "$rows" -lt 1 ] && rows=1
    _layout_rows=$rows
    _layout_cols=$cols
}
show_help_panel() {
    clear
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
_build_menu_options() {
    local current_stack_key=""
    if [ "$current_level" -gt 0 ]; then
        current_stack_key="${history_name_stack[*]}"
    fi
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
    local search_pattern=""
    local tag_pattern=""
    if [ -n "$filter_query" ]; then
        search_pattern="$filter_query"
    fi
    if [ -n "$tag_filter" ]; then
        tag_pattern="$tag_filter"
    fi
    local -a _result_arr=()
    local -a active_parents=()
    local k i
    local _haystack=""
    local _nocase_was=0
    shopt -q nocasematch && _nocase_was=1
    [ -n "$search_pattern" ] && shopt -s nocasematch
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        is_meta_task_line "$line" && continue
        split_task_line "$line"
        level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
        [ -z "$name" ] && continue
        case "$level" in
            ''|*[!0-9]*) continue ;;
        esac
        for ((k = level; k <= current_level; k++)); do
            active_parents[k]=""
        done
        if [ "$cmd" = "SUB" ]; then
            active_parents[level]="$name"
        fi
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
        if [ -n "$search_pattern" ]; then
            _haystack="$name $desc"
            [[ "$_haystack" != *"$search_pattern"* ]] && continue
        fi
        if [ -n "$tag_pattern" ]; then
            has_tag "$desc" "$tag_pattern" || continue
        fi
        _result_arr+=("${level}|${name}|${cmd}|${desc}")
    done < <(merge_configs)
    [ "$_nocase_was" -eq 0 ] && shopt -u nocasematch
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
    local mode_indicator="[${active_mode}]"
    if [ "$active_mode" = "global" ] && [ -f "$config_path" ]; then
        local _bn="${config_path##*/}"
        local _pname="${_bn##.tasks}"; _pname="${_pname#.}"
        [ -n "$_pname" ] && mode_indicator="[${_pname}]"
    fi
    local _header_text="════ Shell Menu Runner ${VERSION} ${mode_indicator} ════"
    local _header_key="${_header_text}|${term_width}"
    if [ "${_HEADER_CACHE_KEY:-}" != "$_header_key" ]; then
        fit_to_width "$_header_text" "$term_width"
        _HEADER_CACHE_TEXT="$FIT_TEXT"
        _HEADER_CACHE_KEY="$_header_key"
    fi
    FIT_TEXT="$_HEADER_CACHE_TEXT"
    echo -e "${COLOR_HEAD}${FIT_TEXT}${COLOR_RESET}${_EL}"
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
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        fit_to_width "No tasks found. Press 'e' to edit config or '?' for help." "$term_width"
        echo -e "${COLOR_DIM}${FIT_TEXT}${COLOR_RESET}${_EL}"
        [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
        return 0
    fi
    calculate_layout "$total"
    local rows=$_layout_rows cols=$_layout_cols
    local col_width=$(( term_width / cols ))
    local inner=$(( col_width - 4 ))
    [ "$inner" -lt 1 ] && inner=1
    local name_max=$(( inner - 4 ))
    [ "$name_max" -lt 1 ] && name_max=1
    if [ "$_name_field_cache_key" != "$name_max" ]; then
        _name_field_cache=()
        _name_field_cache_key="$name_max"
    fi
    if [ "$col_width" -ne "${_LAST_COL_WIDTH:-0}" ]; then
        build_border_strings "$col_width"
    fi
    local visible_rows="$rows"
    local first_row=0
    local _term_lines="${TPUT_LINES:-24}"
    is_uint "$_term_lines" && [ "$_term_lines" -ge 6 ] || _term_lines=24
    local _chrome=9
    local _max_rows=$(( (_term_lines - _chrome) / 3 ))
    [ "$_max_rows" -lt 1 ] && _max_rows=1
    if [ "$rows" -gt "$_max_rows" ]; then
        visible_rows="$_max_rows"
        local _sel_row=$(( selected_index % rows ))
        first_row=$(( _sel_row - visible_rows / 2 ))
        [ "$first_row" -lt 0 ] && first_row=0
        [ "$first_row" -gt $(( rows - visible_rows )) ] && first_row=$(( rows - visible_rows ))
    fi
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
            top_line+="${border_color}${_BORDER_TOP}${COLOR_RESET}"
            bot_line+="${border_color}${_BORDER_BOT}${COLOR_RESET}"
            split_task_line "${menu_options[$idx]}"
            _lvl="$_f_level"; _name="$_f_name"; _cmd="$_f_cmd"; _desc="$_f_desc"
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
    echo -e "${_EL}"
    local _nav_lr=""; [ "$cols" -gt 1 ] && _nav_lr=" ←→ h/l"
    local _hint_full="[↑↓${_nav_lr}] Navigate | [Enter] Execute | [/] Search | [Space] Multi | [?] Help"
    local _hint_mid="[↑↓←→] Nav | [Enter] Run | [/] Search | [?] Help"
    local _hint_min="[↑↓←→] [Enter] [/] [?]"
    if [ "$_HINT_WIDTHS_KEY" != "$_hint_full" ]; then
        display_width "$_hint_mid";  _HINT_MID_WIDTH="$DISPLAY_WIDTH"
        display_width "$_hint_full"; _HINT_FULL_WIDTH="$DISPLAY_WIDTH"
        _HINT_WIDTHS_KEY="$_hint_full"
    fi
    local _hint="$_hint_min"
    [ "$_HINT_MID_WIDTH" -le "$term_width" ] && _hint="$_hint_mid"
    [ "$_HINT_FULL_WIDTH" -le "$term_width" ] && _hint="$_hint_full"
    if [ "$visible_rows" -lt "$rows" ]; then
        local _pos=$(( first_row + 1 ))
        local _end=$(( first_row + visible_rows ))
        _hint="${_hint} | ${_pos}-${_end}/${rows}"
    fi
    echo -e "${COLOR_DIM}${_hint}${COLOR_RESET}${_EL}"
    [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
    return 0
}
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
_reload_menu() {
    _build_menu_options
    menu_options=("${MENU_RESULT_ARRAY[@]+"${MENU_RESULT_ARRAY[@]}"}")
    calculate_layout "${#menu_options[@]}"
    _name_field_cache=()
    _name_field_cache_key=""
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
    if [ "$is_interactive" -eq 1 ]; then
        _MENU_LOOP_ACTIVE=1
        save_terminal_state
        set_raw_mode
        trap 'restore_term; cleanup_wrapper; exit 130' INT TERM
    else
        _MENU_LOOP_ACTIVE=0
        print_task_list
    fi
    while true; do
        if [ "$redraw_needed" -eq 1 ] && [ "$is_interactive" -eq 1 ]; then
            draw_menu
            redraw_needed=0
        fi
        local key="" _rk_status=0 _read_failures=0
        if [ "$is_interactive" -eq 1 ]; then
            key=$(read_key_raw); _rk_status=$?
            if [ "$_rk_status" -ne 0 ]; then
                _read_failures=$(( _read_failures + 1 ))
                if [ "$_read_failures" -ge 3 ]; then
                    break
                fi
                redraw_needed=1
                continue
            fi
            _read_failures=0
        else
            read -r key || break
            [ -z "$key" ] && break
            case "$key" in
                q|Q) restore_term; exit 0 ;;
            esac
            cli_run_task "$key" || true
            continue
        fi
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
                if [[ -n "${multi_select_map[$selected_index]:-}" ]]; then
                    unset 'multi_select_map[$selected_index]'
                else
                    multi_select_map["$selected_index"]=1
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
                if [ ${#multi_select_map[@]} -gt 0 ]; then
                    set -u
                    restore_term
                    local -a multi_keys=()
                    IFS=$'\n' read -r -d '' -a multi_keys < <(printf "%s\n" "${!multi_select_map[@]}" | sort -n && printf '\0') || true
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
                invalidate_menu_cache
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "f"|"F") run_with_term_paused file_browser; redraw_needed=1;;
            "#") # Tag filter
                run_with_term_paused show_tag_menu
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "*") # Toggle favorite
                if [ "$selected_index" -lt "$num" ]; then
                    split_task_line "${menu_options[$selected_index]}"
                    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                    toggle_favorite "$name"
                fi
                redraw_needed=1;;
            "r") run_with_term_paused show_favorites; redraw_needed=1;;
            "R") run_with_term_paused show_recent; redraw_needed=1;;
            "L") run_with_term_paused show_logs; redraw_needed=1;;
            "c"|"C") # Copy the selected command to the clipboard
                if [ "$selected_index" -lt "$num" ]; then
                    split_task_line "${menu_options[$selected_index]}"
                    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                    copy_to_clipboard "$cmd"
                fi
                redraw_needed=1;;
            "q"|"Q") restore_term; clear; exit 0;;
        esac
        local cnt=${#menu_options[@]}
        [ "$selected_index" -lt 0 ] && selected_index=$((cnt-1))
        [ "$selected_index" -ge "$cnt" ] && selected_index=0
    done
    _MENU_LOOP_ACTIVE=0
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
                local tmp_file
                tmp_file="${CACHE_DIR}/edit_$$_${RANDOM}.tmp"
                if ! : > "$tmp_file" 2>/dev/null; then
                    echo -e "${COLOR_ERR}$(msg temp_file_fail)${COLOR_RESET}"
                    sleep 1
                    continue
                fi
                if [ -t 0 ]; then
                    cat > "$tmp_file"
                else
                    echo -e "${COLOR_ERR}Paste mode needs an interactive terminal${COLOR_RESET}"
                    rm -f "$tmp_file"
                    sleep 1
                    continue
                fi
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
EOF
            run_external_editor "$ALIAS_FILE"
        fi
    else
        echo -e "${COLOR_DIM}Current aliases:${COLOR_RESET}"
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
                local alias_name=""
                local task_name=""
                read -r alias_name || true
                echo -e "${COLOR_INFO}Task name:${COLOR_RESET}"
                read -r task_name || true
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
    if [ ! -f "$ALIAS_FILE" ]; then
        touch "$ALIAS_FILE"
    fi
}
resolve_alias() {
    local input="$1"
    if [ -f "$ALIAS_FILE" ]; then
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
self_update() {
    echo -e "${COLOR_HEAD}$(msg update_check)${COLOR_RESET}"
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${COLOR_ERR}$(msg curl_missing)${COLOR_RESET}"
        return 1
    fi
    local tmp_file
    tmp_file=$(mktemp /tmp/run_update.XXXXXX) || { echo -e "${COLOR_ERR}$(msg temp_file_fail)${COLOR_RESET}"; return 1; }
    if curl -fsSL "$REPO_RAW_URL" -o "$tmp_file"; then
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
            install_path=$(command -v run)
            if [ -z "$install_path" ]; then
                echo -e "${COLOR_ERR}$(msg install_path_missing)${COLOR_RESET}"
                rm -f "$tmp_file"
                return 1
            fi
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
            shift
            ;;
        --edit|-e)
            if [ -z "$config_path" ]; then
                if [ "$active_mode" = "global" ]; then
                    config_path="$GLOBAL_CONFIG"
                elif found=$(find_local_config); then
                    config_path="$found"
                else
                    config_path="$LOCAL_CONFIG"
                fi
            fi
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
set +u  # Disable nounset for array check
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
        echo -e "${COLOR_WARN}No .tasks file found.${COLOR_RESET}"
        exit 1
    fi
fi
load_global_vars
parse_config_vars
load_settings
apply_theme
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
if [ "$is_interactive" -eq 0 ] && [ "${cli_mode:-0}" -eq 0 ]; then
    cli_mode=1
fi
if [ "${cli_list_mode:-0}" -eq 1 ]; then
    _build_all_tasks
    menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    cli_list_tasks
    exit 0
fi
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
_build_menu_options
menu_options=("${MENU_RESULT_ARRAY[@]+"${MENU_RESULT_ARRAY[@]}"}")
num=${#menu_options[@]}
calculate_layout "$num"; rows=$_layout_rows; cols=$_layout_cols
redraw_needed=1
main_interactive_loop
