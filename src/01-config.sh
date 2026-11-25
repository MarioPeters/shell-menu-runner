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
DEBUG_MODE=0
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
