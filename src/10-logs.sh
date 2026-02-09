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
    echo "$timestamp | $status | $task_name | exit:$exit_code | time:${exec_time}s" >> "$RUN_HISTORY_FILE"
    
    # Keep history file size manageable
    if [ -f "$RUN_HISTORY_FILE" ]; then
        local lines
        lines=$(wc -l < "$RUN_HISTORY_FILE" || echo 0)
        if [ "$lines" -gt "$RUN_HISTORY_MAX" ]; then
            if tail -n "$RUN_HISTORY_MAX" "$RUN_HISTORY_FILE" > "${RUN_HISTORY_FILE}.tmp"; then
                mv "${RUN_HISTORY_FILE}.tmp" "$RUN_HISTORY_FILE"
            fi
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
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    read -r -n1 -s
}

add_to_recent() {
    local task_name="$1"
    local exec_time="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Format: timestamp|config_path|task_name|exec_time
    echo "$timestamp|$config_path|$task_name|${exec_time}s" >> "$RUN_RECENT_FILE"
    
    # Keep only latest entries
    if [ -f "$RUN_RECENT_FILE" ]; then
        local lines
        lines=$(wc -l < "$RUN_RECENT_FILE" || echo 0)
        if [ "$lines" -gt "$RUN_RECENT_MAX" ]; then
            if tail -n "$RUN_RECENT_MAX" "$RUN_RECENT_FILE" > "${RUN_RECENT_FILE}.tmp"; then
                mv "${RUN_RECENT_FILE}.tmp" "$RUN_RECENT_FILE"
            fi
        fi
    fi
}

show_recent() {
    clear
    echo -e "${COLOR_HEAD}$(msg recent_tasks)${COLOR_RESET}"
    
    if [ ! -f "$RUN_RECENT_FILE" ] || [ ! -s "$RUN_RECENT_FILE" ]; then
        echo -e "${COLOR_DIM}No recent tasks yet.${COLOR_RESET}"
        echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
        read -r -n1 -s
        return
    fi
    
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    local -a lines=()
    IFS=$'\n' read -r -d '' -a lines < <(tail -n 20 "$RUN_RECENT_FILE" 2>/dev/null && printf '\0') || true
    
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
            local filename
            filename=$(basename "$log_file")
            echo "$idx) ${filename}"
            idx=$((idx + 1))
        done
        echo ""
        echo "[1-9] View [q]uit"
        
        while true; do
            read -rsn1 key
            if [[ "$key" =~ [1-9] ]]; then
                local sel=$((key - 1))
                if [ "$sel" -lt "${#log_files[@]}" ]; then
                    clear
                    echo -e "${COLOR_HEAD}Log: $(basename "${log_files[$sel]}")${COLOR_RESET}"
                    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                    cat "${log_files[$sel]}"
                    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
                    read -n1 -rs
                    return
                fi
            elif [[ "$key" == "q" ]] || [[ "$key" == "Q" ]] || [[ "$key" == $'\x1b' ]]; then
                break
            fi
        done
    fi
    
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    read -n1 -rs
}
