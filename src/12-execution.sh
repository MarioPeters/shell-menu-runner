# ==============================================================================
#  TASK EXECUTION ENGINE
# ==============================================================================

select_dropdown() {
    local options_str="$1"
    local IFS=','
    local -a options=()
    if mapfile -t options < <(echo "$options_str" | tr ',' '\n'); then
        :
    fi
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
                read -rsn2 -t 1 k
                case "$k" in 
                    '[A') selected=$((selected - 1));; 
                    '[B') selected=$((selected + 1));;
                    '') return 1;; # Pure Escape = cancel
                esac;;
            "k") selected=$((selected - 1));; "j") selected=$((selected + 1));;
            "") echo "${options[$selected]}"; return 0;;
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
                timeout "$task_timeout" bash -c "[ \"$active_mode\" == \"local\" ] && cd \"$(dirname \"$config_path\")\"; [ -f \".env\" ] && set -a && source .env && set +a; eval \"$cmd\"" 2>&1 | tee "$log_file"
                exit "${PIPESTATUS[0]}"
            else
                bash -c "[ \"$active_mode\" == \"local\" ] && cd \"$(dirname \"$config_path\")\"; [ -f \".env\" ] && set -a && source .env && set +a; eval \"$cmd\"" 2>&1 | tee "$log_file"
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
    
    set +u; echo -e "${COLOR_DIM}> $cmd ${args[*]:-}${COLOR_RESET}\n"; set -u
    save_state
    
    if [ "$dry_run_mode" -eq 1 ]; then
        echo -e "${COLOR_INFO}🔍 DRY-RUN: Command would execute as above${COLOR_RESET}"
        echo -e "${COLOR_DIM}(No actual execution)${COLOR_RESET}\n"
        echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; read -r -n1 -s
        return 0
    fi
    
    # Measure execution time
    local start_time
    # Record terminal state before running task
    start_time=$(date +%s)
    {
        echo "PRE $(date +%s) TTY=$(tty 2>/dev/null || echo none) STTY=$(stty -g 2>/dev/null || echo '')"
    } >> /tmp/tty_state.log 2>&1 || true
    
    # Execute with timeout
    local exit_status=0
    local log_file
    log_file=$(create_log_file "$name")
    local temp_output
    temp_output=$(mktemp)
    trap 'rm -f "$temp_output"' RETURN
    
    if command -v timeout >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        # Defensive check: ensure the command's first token is a valid executable
        local first_token
        first_token=${cmd%% *}
        if [ -n "$first_token" ] && ! command -v "$first_token" >/dev/null 2>&1 && [[ "$first_token" != */* ]]; then
            echo -e "\n${COLOR_ERR}Invalid task command: '$first_token' — skipping execution.${COLOR_RESET}"
            exit_status=127
        else
        if timeout "$task_timeout" bash -c "[ \"$active_mode\" == \"local\" ] && cd \"$(dirname \"$config_path\")\"; [ -f \".env\" ] && set -a && source .env && set +a; eval \"$cmd ${args[*]:-}\"" > "$temp_output" 2>&1; then
            exit_status=0
        else
            exit_status=$?
        fi
        fi
        if [ "$exit_status" -eq 124 ]; then
            echo -e "\n${COLOR_ERR}$(msg task_timeout) (${task_timeout}s).${COLOR_RESET}"
        fi
    else
        # Fallback without timeout
        # shellcheck disable=SC1091
        # Defensive check for fallback execution as well
        local first_token_fallback
        first_token_fallback=${cmd%% *}
        if [ -n "$first_token_fallback" ] && ! command -v "$first_token_fallback" >/dev/null 2>&1 && [[ "$first_token_fallback" != */* ]]; then
            echo -e "\n${COLOR_ERR}Invalid task command: '$first_token_fallback' — skipping execution.${COLOR_RESET}"
            exit_status=127
        else
        if ( [ "$active_mode" == "local" ] && cd "$(dirname "$config_path")"; [ -f ".env" ] && set -a && source .env && set +a; eval "$cmd ${args[*]:-}" ) > "$temp_output" 2>&1; then
            exit_status=0
        else
            exit_status=$?
        fi
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
    
    # Reset terminal state to clean state after task execution
    # This prevents issues with arrow keys and terminal modes
    stty sane 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    {
        echo "POST $(date +%s) TTY=$(tty 2>/dev/null || echo none) STTY=$(stty -g 2>/dev/null || echo '')"
    } >> /tmp/tty_state.log 2>&1 || true
    
    # Invalidate menu cache after task execution (config may have changed)
    last_config_mtime=0
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; read -r -n1 -s
}

# ==============================================================================
#  UTILITY HELPERS
# ==============================================================================

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
            export "$key"="$value"
        fi
    done < "$RUN_VARS_FILE"
}

load_task_vars() {
    set +e +o pipefail  # Disable errexit and pipefail for regex operations
    if [ ! -f "$config_path" ]; then
        set -e -o pipefail
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^VAR_[A-Za-z0-9_]+= ]] || continue
        local key="${line%%=*}"
        local value="${line#*=}"
        export "$key"="$value" 2>/dev/null || true
    done < "$config_path"
    set -e -o pipefail  # Re-enable errexit and pipefail
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
    mkdir -p "$RUN_LOG_DIR" 2>/dev/null || true
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

extract_field_from_grep() {
    # Extract field from grep result
    # Usage: extract_field_from_grep "^TIMEOUT=" "=" 2
    local pattern="$1"
    local delimiter="$2"
    local field_idx="$3"
    if [ -f "$config_path" ]; then
        grep -m1 "$pattern" "$config_path" 2>/dev/null | cut -d"$delimiter" -f"$field_idx" 2>/dev/null | xargs || true
    fi
}
