#!/bin/bash

# ==============================================================================
#  SHELL MENU RUNNER v1.3.0 (Sub-Menus + Dropdown-Selects)
#  GitHub: https://github.com/MarioPeters/shell-menu-runner
#  Lizenz: MIT
# ==============================================================================

readonly VERSION="1.3.0"
readonly LOCAL_CONFIG=".tasks"
readonly GLOBAL_CONFIG="$HOME/.tasks"
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

# ==============================================================================
#  POLYFILLS & UTILS
# ==============================================================================

get_realpath() { command -v realpath &>/dev/null && realpath "$1" || echo "$PWD/${1#./}"; }
cleanup_terminal() { tput cnorm 2>/dev/null || true; echo -e "${COLOR_RESET}"; }
trap cleanup_terminal EXIT INT TERM
hide_cursor() { tput civis 2>/dev/null || true; }

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
    echo -e "${COLOR_HEAD}Suche nach Updates...${COLOR_RESET}"
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${COLOR_ERR}curl nicht gefunden. Bitte installieren und erneut versuchen.${COLOR_RESET}"
        return 1
    fi
    local tmp_file
    tmp_file=$(mktemp /tmp/run_update.XXXXXX) || { echo -e "${COLOR_ERR}Konnte temporäre Datei nicht anlegen.${COLOR_RESET}"; return 1; }
    if curl -fsSL "$REPO_RAW_URL" -o "$tmp_file"; then
        if [ -n "$RUN_EXPECTED_SHA256" ]; then
            local dl_hash=""
            dl_hash=$(file_sha256 "$tmp_file") || echo -e "${COLOR_WARN}Warnung: sha256sum/shasum nicht gefunden. Integritätscheck übersprungen.${COLOR_RESET}"
            if [ -n "$dl_hash" ] && [ "$dl_hash" != "$RUN_EXPECTED_SHA256" ]; then
                echo -e "${COLOR_ERR}Integritätscheck fehlgeschlagen. Erwartet $RUN_EXPECTED_SHA256, erhalten $dl_hash.${COLOR_RESET}"
                rm -f "$tmp_file"
                return 1
            fi
        else
            echo -e "${COLOR_WARN}Kein RUN_EXPECTED_SHA256 gesetzt. Update ohne Hash-Prüfung.${COLOR_RESET}"
            read -p "Fortfahren? [y/N] " -n 1 -r; echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                rm -f "$tmp_file"
                return 1
            fi
        fi
        local new_ver=""
        new_ver=$(grep -m1 "readonly VERSION=" "$tmp_file" | cut -d'"' -f2 || true)
        if [ -z "$new_ver" ]; then
            echo -e "${COLOR_ERR}Konnte Versionsinfo im Update nicht lesen.${COLOR_RESET}"
            rm -f "$tmp_file"
            return 1
        fi
        if [ "$new_ver" == "$VERSION" ]; then
            echo -e "${COLOR_SEL}Du nutzt bereits die neueste Version ($VERSION).${COLOR_RESET}"
            rm -f "$tmp_file"
        else
            echo -e "${COLOR_WARN}Update gefunden: $VERSION -> $new_ver${COLOR_RESET}"
            local install_path
            install_path=$(command -v run)
            if [ -z "$install_path" ]; then
                echo -e "${COLOR_ERR}Konnte Installationspfad nicht bestimmen (run nicht im PATH).${COLOR_RESET}"
                rm -f "$tmp_file"
                return 1
            fi
            if [ -w "$install_path" ]; then
                mv "$tmp_file" "$install_path" && chmod +x "$install_path"
            else
                sudo mv "$tmp_file" "$install_path" && sudo chmod +x "$install_path"
            fi
            echo -e "${COLOR_SEL}✔ Update auf $new_ver erfolgreich!${COLOR_RESET}"
            command -v run >/dev/null 2>&1 && echo -e "${COLOR_INFO}Aktuelle Version:${COLOR_RESET} $(run --version 2>/dev/null)"
        fi
    else
        echo -e "${COLOR_ERR}Fehler beim Herunterladen des Updates.${COLOR_RESET}"
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
        echo -e "${COLOR_WARN}Datei '$target' existiert bereits.${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_HEAD}Initialisiere Shell Menu Runner...${COLOR_RESET}"
    echo "# Shell Menu Runner Configuration" > "$target"
    echo "# THEME: CYBER" >> "$target"
    echo "" >> "$target"

    if [ "$mode" == "global" ]; then
        echo "0|🔄 System Update|sudo apt update && sudo apt upgrade -y|Systempflege" >> "$target"
        echo "0|🧹 Cache Cleanup|rm -rf /tmp/*|Temporäre Dateien löschen" >> "$target"
    else
        # 1. Node.js / React Detection
        if [ -f "package.json" ]; then
            echo -e "${COLOR_INFO}→ package.json erkannt. Importiere Scripts...${COLOR_RESET}"
            local scripts
            scripts=$(sed -n '/"scripts": {/,/}/p' package.json | grep ":" | sed 's/^[[:space:]]*"//; s/":.*//')
            for s in $scripts; do
                echo "0|📦 npm $s|npm run $s|Aus package.json" >> "$target"
            done
        fi

        # 2. Docker Detection
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            echo -e "${COLOR_INFO}→ Docker Compose erkannt.${COLOR_RESET}"
            echo "0|🐳 Docker Up|docker-compose up -d|Container starten" >> "$target"
            echo "0|🐳 Docker Down|docker-compose down|Container stoppen" >> "$target"
        fi

        # 3. Python Detection
        if [ -f "requirements.txt" ] || [ -f "main.py" ] || [ -f "manage.py" ]; then
            echo -e "${COLOR_INFO}→ Python Projekt erkannt.${COLOR_RESET}"
            [ -f "manage.py" ] && echo "0|🐍 Django Run|python3 manage.py runserver|Django Dev Server" >> "$target"
            [ -f "main.py" ] && echo "0|🐍 Run Main|python3 main.py|Python Script starten" >> "$target"
        fi

        # Fallback falls nichts gefunden wurde
        if [ "$(wc -l < "$target")" -lt 4 ]; then
            echo "0|🚀 Hello World|echo 'Edit .tasks to add commands'|Beispiel Task" >> "$target"
        fi
    fi

    echo "0|❌ Exit|EXIT|Menü beenden" >> "$target"
    echo -e "${COLOR_SEL}✔ Konfiguration '$target' wurde mit Auto-Detection erstellt!${COLOR_RESET}"
}

# ==============================================================================
#  CORE LOGIC & UI
# ==============================================================================

parse_config_vars() {
    [ ! -f "$config_path" ] && return
    local file_theme
    file_theme=$(grep "^# THEME:" "$config_path" | head -n 1 | cut -d: -f2 | xargs)
    case "$file_theme" in
        "CYBER") COLOR_HEAD=$'\e[1;36m'; COLOR_SEL=$'\e[1;35m'; COLOR_INFO=$'\e[1;32m' ;;
        "MONO")  COLOR_HEAD=$'\e[1;37m'; COLOR_SEL=$'\e[4;37m'; COLOR_INFO=$'\e[2m' ;;
    esac
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
        echo -e "${COLOR_HEAD}Select Option:${COLOR_RESET}"
        for (( i=0; i<num; i++ )); do
            if [ "$i" -eq "$selected" ]; then
                echo -e "${COLOR_SEL}›${COLOR_RESET} ${options[$i]}"
            else
                echo "  ${options[$i]}"
            fi
        done
        echo -e "\n${COLOR_DIM}[up/down] Navigate | [Enter] Select${COLOR_RESET}"
        
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
    echo -e "${COLOR_HEAD}Executing:${COLOR_RESET} $name"
    
    if [[ "$desc" == "[!]"* ]]; then
        echo -e "\n${COLOR_WARN}⚠ ACHTUNG: ${desc#"[!] "}${COLOR_RESET}"
        read -p "Sicher? [y/N] " -n 1 -r; echo ""; [[ ! $REPLY =~ ^[Yy]$ ]] && return
    fi

    while [[ "$cmd" =~ \<\<([^:>]+)(:[^>]*)?\>\> ]]; do
        local p="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}" 
        if [[ "$rest" == :* ]]; then
            local opts_str="${rest:1}"
            echo -e "\n${COLOR_INFO}Wähle für:${COLOR_RESET} $p"
            local r
            r=$(select_dropdown "$opts_str")
            cmd="${cmd//\<\<"$p":"$opts_str"\>\>/$r}"
        else
            echo -e "\n${COLOR_INFO}Eingabe für:${COLOR_RESET} $p"; read -r -p "> " r; cmd="${cmd//<<$p>>/$r}"
        fi
    done
    
    echo -e "${COLOR_DIM}> $cmd ${args[*]}${COLOR_RESET}\n"; save_state
    if [ "$dry_run_mode" -eq 0 ]; then
        # shellcheck disable=SC1091
        ( [ "$active_mode" == "local" ] && cd "$(dirname "$config_path")"; [ -f ".env" ] && set -a && source .env && set +a; eval "$cmd ${args[*]}" )
        local status=$?
        if [ $status -ne 0 ]; then
            echo -e "\n${COLOR_ERR}Task fehlgeschlagen (exit $status).${COLOR_RESET}"
        else
            echo -e "\n${COLOR_SEL}✔ Task erfolgreich.${COLOR_RESET}"
        fi
    fi
    echo -e "\n${COLOR_DIM}Taste drücken...${COLOR_RESET}"; read -r -n1 -s
}

draw_menu() {
    hide_cursor; printf "\033[H\033[J"
    local active_desc=""
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    local num=${#menu_options[@]}; local cols=1
    if [ "$num" -gt 10 ]; then cols=3; elif [ "$num" -gt 5 ]; then cols=2; fi
    local rows=$(( (num + cols - 1) / cols ))
    
    local title
    title=$(grep "^# TITLE:" "$config_path" | head -n 1 | cut -d: -f2)
    [ -z "$title" ] && title="$(basename "$(dirname "$config_path")" | tr '[:lower:]' '[:upper:]')"
    [ "$active_mode" == "global" ] && title="SYSTEM CONTROL"
    
    echo -e "${COLOR_HEAD}${C_BOLD}${title}${COLOR_RESET}"
    local crumbs=""; for name in "${history_name_stack[@]}"; do [ -z "$crumbs" ] && crumbs="${name}" || crumbs="${crumbs} ${COLOR_DIM}>${COLOR_RESET} ${name}"; done
    echo -e "${COLOR_DIM}Path:${COLOR_RESET} $crumbs"; [ -n "$filter_query" ] && echo -e "${COLOR_INFO}Filter:${COLOR_RESET} '$filter_query'"
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
        local hint="[g] Global"; [ "$active_mode" == "global" ] && hint="[g] Local"
        local multi_hint=""; local marked=${#multi_select_map[@]}
        [ "$marked" -gt 0 ] && multi_hint=" [$marked marked]"
        echo -e "${COLOR_DIM} [j/k] Move [Space] Multi$multi_hint $hint [e] Edit [Enter] Run${COLOR_RESET}"
    fi
}

# --- MAIN LOOP ---
args=(); while [[ $# -gt 0 ]]; do case $1 in --help|-h) echo "Usage: run [--init|--global|--edit|--update]"; exit 0 ;; --version|-v) echo "$VERSION"; exit 0 ;; --init) smart_init "local"; exit 0 ;; --update) self_update; exit 0 ;; --global) active_mode="global"; config_path="$GLOBAL_CONFIG"; [ ! -f "$config_path" ] && smart_init "global" && exit 0 ;; --edit|-e) [ -z "$config_path" ] && config_path="$LOCAL_CONFIG"; ${EDITOR:-nano} "$config_path"; exit 0 ;; *) args+=("$1"); shift ;; esac; done; set -- "${args[@]}"

if [ -z "$config_path" ]; then
    if found=$(find_local_config); then config_path="$found"
    elif [ -f "$GLOBAL_CONFIG" ]; then active_mode="global"; config_path="$GLOBAL_CONFIG"
    else smart_init "local"; exit 0; fi
fi

parse_config_vars; load_state

while true; do
    draw_menu; read -rsn1 key
    case "$key" in
        $'\x1b') read -rsn2 k; case "$k" in '[A') ((selected_index--));; '[B') ((selected_index++));; esac;;
        "k") ((selected_index--));; "j") ((selected_index++));;
        " ") if [[ -n "${multi_select_map[$selected_index]}" ]]; then unset 'multi_select_map[$selected_index]'; else multi_select_map["$selected_index"]=1; fi;;
        "/") echo -e "\n${COLOR_INFO}Search:${COLOR_RESET}\c"; tput cnorm; read -r filter_query; selected_index=0;;
        "g") if [ "$active_mode" == "local" ]; then active_mode="global"; config_path="$GLOBAL_CONFIG"; elif found=$(find_local_config); then active_mode="local"; config_path="$found"; fi; selected_index=0; current_level=0; parse_config_vars; load_state;;
        "") [ ${#menu_options[@]} -eq 0 ] && continue
            if [ ${#multi_select_map[@]} -gt 0 ]; then
                IFS=$'\n' read -r -d '' -a multi_keys < <(printf "%s\n" "${!multi_select_map[@]}" | sort -n && printf '\0') || true
                for mi in "${multi_keys[@]}"; do
                    IFS='|' read -r n cm d <<< "${menu_options[$mi]}"
                    [ "$cm" == "EXIT" ] && continue
                    execute_task "$cm" "$n" "$d"
                done
                echo -e "${COLOR_INFO}Ausgeführt:${COLOR_RESET} ${#multi_keys[@]} markierte Tasks"
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