#!/bin/bash

# ==============================================================================
#  SHELL MENU RUNNER v1.3.0 (Sub-Menus + Dropdown-Selects)
#  GitHub: https://github.com/MarioPeters/shell-menu-runner
#  Lizenz: MIT
# ==============================================================================

readonly VERSION="1.3.0"
readonly LOCAL_CONFIG=".tasks"
readonly GLOBAL_CONFIG="$HOME/.tasks"
readonly LOCAL_SETTINGS=".runrc"
readonly GLOBAL_SETTINGS="$HOME/.runrc"
readonly REPO_RAW_URL="https://raw.githubusercontent.com/MarioPeters/shell-menu-runner/main/run.sh"
readonly C_BOLD=$'\e[1m'

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
dry_run_mode=0
declare -a menu_options
declare -a multi_select_map

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
trap cleanup_terminal EXIT INT TERM
hide_cursor() { tput civis 2>/dev/null || true; }

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
        "CYBER") COLOR_HEAD=$'\e[1;36m'; COLOR_SEL=$'\e[1;35m'; COLOR_INFO=$'\e[1;32m' ;;
        "MONO")  COLOR_HEAD=$'\e[1;37m'; COLOR_SEL=$'\e[4;37m'; COLOR_INFO=$'\e[2m' ;;
    esac
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

get_cache_file() {
    local t="$config_path"; local h
    if command -v md5sum &>/dev/null; then h=$(echo -n "$t" | md5sum | cut -d' ' -f1);
    else h=$(echo -n "$t" | cksum | cut -d' ' -f1); fi
    echo "/tmp/run_menu_${h}.state"
}
save_state() { echo "$selected_index" > "$(get_cache_file)"; }
load_state() { local c; c=$(get_cache_file); [ -f "$c" ] && selected_index=$(cat "$c"); }

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
        # 1. Node.js / React Detection
        if [ -f "package.json" ]; then
            echo -e "${COLOR_INFO}→ $(msg node_detected)${COLOR_RESET}"
            local scripts
            scripts=$(sed -n '/"scripts": {/,/}/p' package.json | grep ":" | sed 's/^[[:space:]]*"//; s/":.*//')
            for s in $scripts; do
                echo "0|📦 npm $s|npm run $s|Aus package.json" >> "$target"
            done
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

parse_config_vars() {
    [ ! -f "$config_path" ] && return
    TASK_THEME=$(grep "^# THEME:" "$config_path" | head -n 1 | cut -d: -f2 | xargs)
}

get_menu_options() {
    awk -F'|' -v lvl="$current_level" -v q="$filter_query" \
        'BEGIN {IGNORECASE=1} /^[^#]/ && !/^VAR_/ && NF >= 2 && $1 == lvl { \
            if (q != "" && index(tolower($2), tolower(q)) == 0) next; \
            desc = ($4 != "") ? $4 : ""; print $2"|"$3"|"desc \
        }' "$config_path" || true
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
            $'\x1b') read -rsn2 k; case "$k" in '[A') ((selected--));; '[B') ((selected++));; esac;;
            "k") ((selected--));; "j") ((selected++));;
            "") echo "${options[$selected]}"; return 0;;
        esac
        [ "$selected" -lt 0 ] && selected=$((num-1))
        [ "$selected" -ge "$num" ] && selected=0
    done
}

execute_task() {
    local cmd="$1"; local name="$2"; local desc="$3"; shift 3; local args=("$@")
    tput cnorm 2>/dev/null; clear 
    echo -e "${COLOR_HEAD}$(msg executing)${COLOR_RESET} $name"
    
    if [[ "$desc" == "[!]"* ]]; then
        echo -e "\n${COLOR_WARN}⚠ $(msg warning_label): ${desc#"[!] "}${COLOR_RESET}"
        read -p "$(msg confirm_prompt) " -n 1 -r; echo ""; [[ ! $REPLY =~ ^[Yy]$ ]] && return
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
    if [ "$dry_run_mode" -eq 0 ]; then
        # shellcheck disable=SC1091
        ( [ "$active_mode" == "local" ] && cd "$(dirname "$config_path")"; [ -f ".env" ] && set -a && source .env && set +a; eval "$cmd ${args[*]}" )
        local status=$?
        if [ $status -ne 0 ]; then
            echo -e "\n${COLOR_ERR}$(msg task_failed) (exit $status).${COLOR_RESET}"
        else
            echo -e "\n${COLOR_SEL}✔ $(msg task_success)${COLOR_RESET}"
        fi
    fi
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
            "1") UI_THEME=$(select_dropdown "CYBER,MONO"); apply_theme ;;
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

draw_menu() {
    hide_cursor; printf "\033[H\033[J"
    local active_desc=""
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    local num=${#menu_options[@]}; local cols=1
    if [ "$num" -gt 10 ]; then cols=3; elif [ "$num" -gt 5 ]; then cols=2; fi
    [ "$cols" -lt "$COLS_MIN" ] && cols="$COLS_MIN"
    [ "$cols" -gt "$COLS_MAX" ] && cols="$COLS_MAX"
    [ "$num" -gt 0 ] && [ "$cols" -gt "$num" ] && cols="$num"
    local rows=$(( (num + cols - 1) / cols ))
    
    local title
    title=$(grep "^# TITLE:" "$config_path" | head -n 1 | cut -d: -f2)
    [ -z "$title" ] && title="$(basename "$(dirname "$config_path")" | tr '[:lower:]' '[:upper:]')"
    [ "$active_mode" == "global" ] && title="$(msg system_control)"
    
    echo -e "${COLOR_HEAD}${C_BOLD}${title}${COLOR_RESET}"
    local crumbs=""; for name in "${history_name_stack[@]}"; do [ -z "$crumbs" ] && crumbs="${name}" || crumbs="${crumbs} ${COLOR_DIM}>${COLOR_RESET} ${name}"; done
    echo -e "${COLOR_DIM}$(msg path_label)${COLOR_RESET} $crumbs"; [ -n "$filter_query" ] && echo -e "${COLOR_INFO}$(msg filter_label)${COLOR_RESET} '$filter_query'"
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"

    for (( r=0; r<rows; r++ )); do
        for (( c=0; c<cols; c++ )); do
            local idx=$(( r + c * rows ))
            if [ "$idx" -lt "$num" ]; then
                IFS='|' read -r name cmd desc <<< "${menu_options[$idx]}"
                local d_num=$((idx + 1)); local marker=" "; [[ -n "${multi_select_map[$idx]}" ]] && marker="${COLOR_WARN}✔${COLOR_RESET}"
                if [ "$idx" -eq "$selected_index" ]; then printf "${COLOR_SEL}›${marker}%-2s %-22s${COLOR_RESET}" "$d_num" "${name:0:22}"; active_desc="$desc"
                else printf "  ${marker}%-2s %-22s" "$d_num" "${name:0:22}"; fi
            fi
        done
        echo "" 
    done
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    if [ -n "$active_desc" ]; then echo -e "${COLOR_INFO}ℹ $active_desc${COLOR_RESET}"
    else
        local hint="$(msg hint_global)"; [ "$active_mode" == "global" ] && hint="$(msg hint_local)"
        local multi_hint=""; local marked=${#multi_select_map[@]}
        [ "$marked" -gt 0 ] && multi_hint=" [$marked $(msg marked_label)]"
        echo -e "${COLOR_DIM} $(msg hint_nav)$multi_hint $hint [s] $(msg settings_title) [e] $(msg edit_label) [Enter] $(msg hint_run)${COLOR_RESET}"
    fi
}

# --- MAIN LOOP ---
args=(); while [[ $# -gt 0 ]]; do case $1 in --help|-h) echo "Usage: run [--init|--global|--edit|--update]"; exit 0 ;; --version|-v) echo "$VERSION"; exit 0 ;; --init) smart_init "local"; exit 0 ;; --update) self_update; exit 0 ;; --global) active_mode="global"; config_path="$GLOBAL_CONFIG"; [ ! -f "$config_path" ] && smart_init "global" && exit 0 ;; --edit|-e) [ -z "$config_path" ] && config_path="$LOCAL_CONFIG"; ${EDITOR:-nano} "$config_path"; exit 0 ;; *) args+=("$1"); shift ;; esac; done; set -- "${args[@]}"

if [ -z "$config_path" ]; then
    if found=$(find_local_config); then config_path="$found"
    elif [ -f "$GLOBAL_CONFIG" ]; then active_mode="global"; config_path="$GLOBAL_CONFIG"
    else smart_init "local"; exit 0; fi
fi

parse_config_vars; load_settings; load_state

while true; do
    draw_menu; read -rsn1 key
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    local num=${#menu_options[@]}; local cols=1
    if [ "$num" -gt 10 ]; then cols=3; elif [ "$num" -gt 5 ]; then cols=2; fi
    [ "$cols" -lt "$COLS_MIN" ] && cols="$COLS_MIN"
    [ "$cols" -gt "$COLS_MAX" ] && cols="$COLS_MAX"
    [ "$num" -gt 0 ] && [ "$cols" -gt "$num" ] && cols="$num"
    local rows=$(( (num + cols - 1) / cols ))
    
    case "$key" in
        $'\x1b') read -rsn2 k; case "$k" in 
            '[A') ((selected_index--));; 
            '[B') ((selected_index++));; 
            '[C') [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows));; 
            '[D') [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows));; 
        esac;;
        "k") ((selected_index--));; "j") ((selected_index++));;
        "h") [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows));;
        "l") [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows));;
        " ") if [[ -n "${multi_select_map[$selected_index]}" ]]; then unset 'multi_select_map[$selected_index]'; else multi_select_map["$selected_index"]=1; fi;;
        "/") echo -e "\n${COLOR_INFO}$(msg search_label)${COLOR_RESET}\c"; tput cnorm; read -r filter_query; selected_index=0;;
        "g") if [ "$active_mode" == "local" ]; then active_mode="global"; config_path="$GLOBAL_CONFIG"; elif found=$(find_local_config); then active_mode="local"; config_path="$found"; fi; selected_index=0; current_level=0; parse_config_vars; load_settings; load_state;;
        "s") settings_menu;;
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
        "q") clear; exit 0;;
    esac
    cnt=${#menu_options[@]}; [ "$selected_index" -lt 0 ] && selected_index=$((cnt-1)); [ "$selected_index" -ge "$cnt" ] && selected_index=0
done