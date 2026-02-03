#!/bin/bash

# ==============================================================================
#  SHELL MENU RUNNER v1.0.0 (Gold Master)
#  GitHub: https://github.com/MarioPeters/shell-menu-runner
#  Lizenz: MIT
# ==============================================================================

readonly VERSION="1.0.0"
readonly LOCAL_CONFIG=".tasks"
readonly GLOBAL_CONFIG="$HOME/.tasks"
readonly REPO_RAW_URL="https://raw.githubusercontent.com/MarioPeters/shell-menu-runner/main/run.sh" 

# --- DEFAULT THEME ---
COLOR_HEAD=$'\e[1;34m'; COLOR_SEL=$'\e[1;32m'; COLOR_ERR=$'\e[1;31m'
COLOR_WARN=$'\e[1;33m'; COLOR_INFO=$'\e[33m';  COLOR_DIM=$'\e[2m'
COLOR_RESET=$'\e[0m'

# Global State
current_level=0
selected_index=0
history_position_stack=() 
history_name_stack=("Main") 
config_path="" 
active_mode="local"
filter_query=""  
dry_run_mode=0
declare -a menu_options
declare -A multi_select_map

# --- POLYFILLS ---
get_realpath() { command -v realpath &>/dev/null && realpath "$1" || echo "$PWD/${1#./}"; }
read_lines_into_array() { local -n arr=$1; arr=(); while IFS= read -r line; do arr+=("$line"); done < <(eval "$2"); }

# --- UTILS ---
cleanup_terminal() { tput cnorm 2>/dev/null; echo -e "${COLOR_RESET}"; }
trap cleanup_terminal EXIT INT TERM
hide_cursor() { tput civis 2>/dev/null; }

get_cache_file() {
    local t="$config_path"; local h
    if command -v md5sum &>/dev/null; then h=$(echo -n "$t" | md5sum | cut -d' ' -f1);
    else h=$(echo -n "$t" | cksum | cut -d' ' -f1); fi
    echo "/tmp/run_menu_${h}.state"
}
save_state() { echo "$selected_index" > "$(get_cache_file)"; }
load_state() { local c=$(get_cache_file); [ -f "$c" ] && selected_index=$(cat "$c"); }
clean_state() { rm -f /tmp/run_menu_*.state; echo -e "${COLOR_INFO}Cache gelöscht.${COLOR_RESET}"; exit 0; }

notify_user() {
    local t="$1"; local m="$2"
    if command -v osascript &>/dev/null; then osascript -e "display notification \"$m\" with title \"$t\""
    elif command -v notify-send &>/dev/null; then notify-send "$t" "$m"; fi
}

find_local_config() {
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/$LOCAL_CONFIG" ]; then echo "$d/$LOCAL_CONFIG"; return 0; fi
        d=$(dirname "$d")
    done
    return 1
}

# --- LOGIC ---
parse_config_vars() {
    [ ! -f "$config_path" ] && return
    local file_theme=$(grep "^# THEME:" "$config_path" | head -n 1 | cut -d: -f2 | xargs)
    case "$file_theme" in
        "CYBER") COLOR_HEAD=$'\e[1;36m'; COLOR_SEL=$'\e[1;35m'; COLOR_INFO=$'\e[1;32m' ;;
        "MONO")  COLOR_HEAD=$'\e[1;37m'; COLOR_SEL=$'\e[4;37m'; COLOR_INFO=$'\e[2m' ;;
    esac
    while IFS='=' read -r key val; do [[ $key == VAR_* ]] && export "$key"="$val"; done < <(grep "^VAR_" "$config_path")
}

get_menu_options() {
    awk -F'|' -v lvl="$current_level" -v q="$filter_query" \
        'BEGIN {IGNORECASE=1} /^[^#]/ && !/^VAR_/ && NF >= 2 && $1 == lvl && ($2 ~ q) { 
            desc = ($4 != "") ? $4 : ""; print $2"|"$3"|"desc 
        }' "$config_path"
}

execute_task() {
    local cmd="$1"; local name="$2"; local desc="$3"; shift 3; local args="$@"
    tput cnorm 2>/dev/null; clear 
    echo -e "${COLOR_HEAD}Executing:${COLOR_RESET} $name"
    
    if [[ "$desc" == "[!]"* ]]; then
        echo -e "\n${COLOR_WARN}⚠ ACHTUNG: ${desc#"[!] "}${COLOR_RESET}"
        read -p "Sicher? [y/N] " -n 1 -r; echo ""; [[ ! $REPLY =~ ^[Yy]$ ]] && return
    fi

    while [[ "$cmd" =~ \<\<([^:>]+)\>\> ]]; do
        local p="${BASH_REMATCH[1]}"; echo -e "\n${COLOR_INFO}Eingabe für:${COLOR_RESET} $p"; read -r -p "> " r; cmd="${cmd//<<$p>>/$r}"
    done
    
    # Dropdown Logic
    while [[ "$cmd" =~ \<\<Select:([^>]+)\>\> ]]; do
        local full="${BASH_REMATCH[0]}"; local opts_str="${BASH_REMATCH[1]}"
        IFS=',' read -ra opts <<< "$opts_str"; local sel=0; local key
        tput civis 2>/dev/null
        while true; do
            echo -e "\n${COLOR_INFO}Wähle:${COLOR_RESET}"
            for i in "${!opts[@]}"; do
                [ $i -eq $sel ] && echo -e "${COLOR_SEL}› ${opts[$i]}${COLOR_RESET}" || echo -e "  ${opts[$i]}"
            done
            read -rsn1 key
            [[ "$key" == $'\x1b' ]] && { read -rsn2 key; [[ "$key" == "[A" ]] && ((sel--)); [[ "$key" == "[B" ]] && ((sel++)); }
            [[ "$key" == "k" ]] && ((sel--)); [[ "$key" == "j" ]] && ((sel++)); [[ "$key" == "" ]] && { local choice="${opts[$sel]}"; cmd="${cmd//$full/$choice}"; break; }
            [ $sel -lt 0 ] && sel=$((${#opts[@]}-1)); [ $sel -ge ${#opts[@]} ] && sel=0
            local cnt=${#opts[@]}; for ((j=0; j<=cnt+1; j++)); do tput cuu1; tput el; done
        done
        tput cnorm 2>/dev/null
    done

    echo -e "${COLOR_DIM}> $cmd $args${COLOR_RESET}\n"; save_state
    local start=$(date +%s)
    if [ "$dry_run_mode" -eq 0 ]; then
        ( [ "$active_mode" == "local" ] && cd "$(dirname "$config_path")"; [ -f ".env" ] && set -a && source .env && set +a; eval "$cmd $args" )
    fi
    local dur=$(( $(date +%s) - start ))
    [ $dur -gt 10 ] && notify_user "Task Finished" "$name took ${dur}s"
    [ "$active_mode" == "local" ] && { local l="$(dirname "$config_path")/.task_history"; echo "$(date "+%Y-%m-%d %H:%M:%S") | $USER | ${dur}s | $name | $cmd" >> "$l"; }
    echo -e "\n${COLOR_DIM}Taste drücken...${COLOR_RESET}"; read -n1 -s
}

draw_menu() {
    hide_cursor; printf "\033[H\033[J"
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    local num=${#menu_options[@]}; local cols=1; [ "$num" -gt 10 ] && cols=3 || { [ "$num" -gt 5 ] && cols=2; }; local rows=$(( (num + cols - 1) / cols ))
    
    local title=$(grep "^# TITLE:" "$config_path" | head -n 1 | cut -d: -f2)
    [ -z "$title" ] && title="$(basename "$(dirname "$config_path")" | tr '[:lower:]' '[:upper:]')"
    [ "$active_mode" == "global" ] && title="SYSTEM CONTROL"
    
    echo -e "${COLOR_HEAD}${C_BOLD}${title}${COLOR_RESET}"
    local crumbs=""; for name in "${history_name_stack[@]}"; do [ -z "$crumbs" ] && crumbs="${name}" || crumbs="${crumbs} ${COLOR_DIM}>${COLOR_RESET} ${name}"; done
    echo -e "${COLOR_DIM}Path:${COLOR_RESET} $crumbs"; [ -n "$filter_query" ] && echo -e "${COLOR_INFO}Filter:${COLOR_RESET} '$filter_query'"
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"

    for (( r=0; r<rows; r++ )); do
        for (( c=0; c<cols; c++ )); do
            local idx=$(( r + c * rows ))
            if [ $idx -lt $num ]; then
                IFS='|' read -r name cmd desc <<< "${menu_options[$idx]}"
                local d_num=$((idx + 1)); local marker=" "; [[ -n "${multi_select_map[$idx]}" ]] && marker="${COLOR_WARN}✔${COLOR_RESET}"
                if [[ "$name" == "---"* ]]; then printf "  %-24s" "──────────────────"
                elif [ "$idx" -eq "$selected_index" ]; then printf "${COLOR_SEL}›${marker}%-2s %-22s${COLOR_RESET}" "$d_num" "${name:0:22}"; active_desc="$desc"
                else printf "  ${marker}%-2s %-22s" "$d_num" "${name:0:22}"; fi
            fi
        done
        echo "" 
    done
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    if [ -n "$active_desc" ]; then [[ "$active_desc" == "[!]"* ]] && echo -e "${COLOR_WARN}⚠ $active_desc${COLOR_RESET}" || echo -e "${COLOR_INFO}ℹ $active_desc${COLOR_RESET}"
    else local hint="[g] Global"; [ "$active_mode" == "global" ] && hint="[g] Local"; echo -e "${COLOR_DIM} [j/k] Move [Space] Multi $hint [e] Edit [Enter] Run${COLOR_RESET}"; fi
}

# --- MAIN ---
args=(); while [[ $# -gt 0 ]]; do case $1 in --help|-h) echo "Usage: run [--init|--global|--edit|--log|--docs|--alias|--health]"; exit 0 ;; --version|-v) echo "$VERSION"; exit 0 ;; --init) smart_init "local"; exit 0 ;; --global) active_mode="global"; config_path="$GLOBAL_CONFIG"; [ ! -f "$config_path" ] && smart_init "global" && exit 0 ;; --edit|-e) [ -z "$config_path" ] && config_path="$LOCAL_CONFIG"; ${EDITOR:-nano} "$config_path"; exit 0 ;; *) args+=("$1"); shift ;; esac; done; set -- "${args[@]}"

smart_init() {
    local target="$LOCAL_CONFIG"; [ "$1" == "global" ] && target="$GLOBAL_CONFIG"
    [ -f "$target" ] && { echo -e "${COLOR_ERR}Datei existiert.${COLOR_RESET}"; exit 1; }
    echo "# Shell Menu Runner Config" > "$target"
    if [ "$1" == "global" ]; then echo "0|🔄 Update|sudo apt update && sudo apt upgrade -y|System" >> "$target"; else echo "0|🚀 Start|echo 'Hello'" >> "$target"; fi
    echo "0|❌ Exit|EXIT" >> "$target"; echo -e "${COLOR_SEL}Config erstellt.${COLOR_RESET}"
}

if [ -z "$config_path" ]; then
    if found=$(find_local_config); then config_path="$found"
    elif [ -f "$GLOBAL_CONFIG" ]; then active_mode="global"; config_path="$GLOBAL_CONFIG"
    else echo -e "${COLOR_HEAD}Runner:${COLOR_RESET} Keine Config."; read -p "Erstellen (l) oder Global (g)? [l/g] " -n 1 -r; echo ""; if [[ $REPLY == "g" ]]; then active_mode="global"; config_path="$GLOBAL_CONFIG"; smart_init "global"; exit 0; else smart_init "local"; exit 0; fi; fi
fi

parse_config_vars; [ $current_level -eq 0 ] && load_state

while true; do
    draw_menu; read -rsn1 key
    [[ "$key" =~ [0-9] ]] && { [[ "$key" == "0" ]] && t=9 || t=$((key - 1)); if [ "$t" -lt "${#menu_options[@]}" ]; then selected_index=$t; key=""; fi; }
    case "$key" in
        $'\x1b') read -rsn2 k; num=${#menu_options[@]}; cols=1; [ "$num" -gt 10 ] && cols=3 || { [ "$num" -gt 5 ] && cols=2; }; r=$(( (num + cols - 1) / cols )); case "$k" in '[A') ((selected_index--));; '[B') ((selected_index++));; '[D') selected_index=$((selected_index-r));; '[C') selected_index=$((selected_index+r));; esac;;
        "k") ((selected_index--));; "j") ((selected_index++));; " ") if [[ -n "${multi_select_map[$selected_index]}" ]]; then unset multi_select_map[$selected_index]; else multi_select_map[$selected_index]=1; fi;;
        "/") echo -e "\n${COLOR_INFO}Search:${COLOR_RESET}\c"; tput cnorm; read -r filter_query; selected_index=0;;
        "g") if [ "$active_mode" == "local" ]; then active_mode="global"; config_path="$GLOBAL_CONFIG"; else if found=$(find_local_config); then active_mode="local"; config_path="$found"; fi; fi; selected_index=0; current_level=0; parse_config_vars; load_state;;
        "e") ${EDITOR:-nano} "$config_path";;
        "") [ ${#menu_options[@]} -eq 0 ] && continue; if [ ${#multi_select_map[@]} -gt 0 ]; then for idx in "${!multi_select_map[@]}"; do IFS='|' read -r n cm d <<< "${menu_options[$idx]}"; cm=$(echo "$cm" | xargs); [[ "$cm" != "SUB" ]] && execute_task "$cm" "$n" "$d"; done; multi_select_map=(); continue; fi; IFS='|' read -r n cm d <<< "${menu_options[$selected_index]}"; cm=$(echo "$cm" | xargs); [[ "$n" == "---"* ]] && continue; if [ "$cm" == "SUB" ]; then history_position_stack+=("$selected_index"); history_name_stack+=("$n"); ((current_level++)); selected_index=0; filter_query=""; elif [ "$cm" == "BACK" ]; then ((current_level--)); unset 'history_name_stack[-1]'; selected_index=${history_position_stack[-1]:-0}; unset 'history_position_stack[-1]'; filter_query=""; elif [ "$cm" == "EXIT" ]; then clear; exit 0; else execute_task "$cm" "$n" "$d"; fi;;
        "q") clear; exit 0;;
    esac
    cnt=${#menu_options[@]}; if [ "$cnt" -gt 0 ]; then [ "$selected_index" -lt 0 ] && selected_index=$((cnt-1)); [ "$selected_index" -ge "$cnt" ] && selected_index=0; else selected_index=0; fi
done
