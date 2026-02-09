# ==============================================================================
#  CONFIGURATION & SETTINGS
# ==============================================================================

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
# Shell Menu Runner Settings
THEME=$UI_THEME
LANG=$UI_LANG
COLS_MIN=$COLS_MIN
COLS_MAX=$COLS_MAX
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
