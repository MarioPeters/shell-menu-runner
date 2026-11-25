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
