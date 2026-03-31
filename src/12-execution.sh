# ==============================================================================
#  TASK EXECUTION ENGINE
# ==============================================================================

select_dropdown() {
    local options_str="$1"
    local -a options=()
    # IFS-Split statt printf|tr-Pipeline: kein Fork, Bash 3.2-kompatibel
    local -a _raw_opts
    IFS=',' read -r -a _raw_opts <<< "$options_str"
    local _opt
    for _opt in "${_raw_opts[@]}"; do
        [ -n "$_opt" ] && options+=("$_opt")
    done
    local selected=0
    local num=${#options[@]}
    
    while true; do
        # Cursor zurück auf 0,0 statt clear → kein Flicker (wie Hauptmenü)
        if [ "${HAS_TPUT:-0}" -eq 1 ] && [ -n "${TPUT_CUP:-}" ]; then
            echo -ne "$TPUT_CUP"
        else
            clear
        fi
        echo -e "${COLOR_HEAD}$(msg select_option)${COLOR_RESET}"
        for (( i=0; i<num; i++ )); do
            if [ "$i" -eq "$selected" ]; then
                echo -e "${COLOR_SEL}›${COLOR_RESET} ${options[$i]}"
            else
                echo "  ${options[$i]}"
            fi
        done
        echo -e "\n${COLOR_DIM}$(msg dropdown_hint)${COLOR_RESET}"
        # Rest der Zeilen löschen damit alte Einträge nicht stehen bleiben
        [ "${HAS_TPUT:-0}" -eq 1 ] && [ -n "${TPUT_ED:-}" ] && echo -ne "$TPUT_ED"
        
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
    # printf -v mit Padding baut den Balken in einem einzigen Aufruf (bash 3.1+, kein Loop)
    printf -v bar_filled '%*s' "$filled" ''
    printf -v bar_empty  '%*s' "$empty"  ''
    printf "%s[%s%s] %3d%%${COLOR_RESET}" \
        "$COLOR_SEL" "${bar_filled// /=}" "${bar_empty// /-}" "$percent"
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
    return 0  # 0 statt 1: stabiler bei set -e, semantisch korrekt (kein Fehler)
}

execute_task_pipeline() {
    local task_cmd="$1"
    local steps_str="${task_cmd#tasks:}"
    local IFS=';'
    local -a steps
    read -r -a steps <<< "$steps_str"
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    for step in "${steps[@]}"; do
        step=$(trim_whitespace "$step")
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
        IFS='|' read -r level name cmd desc <<< "${menu_options[$idx]}"
        if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
            continue
        fi
        if [[ "$desc" == "[!]"* ]] || [[ "$cmd" == *"<<"* ]] || [[ "$cmd" == tasks:* ]]; then
            echo -e "${COLOR_WARN}Skipping '$name' (interactive or pipeline).${COLOR_RESET}"
            continue
        fi
        local log_file
        log_file=$(create_log_file "$name")
        local start_time
        start_time=$(date +%s)
        (
            if command -v timeout >/dev/null 2>&1; then
                # shellcheck disable=SC2016
                timeout "$task_timeout" env \
                    RUN_MODE="$active_mode" \
                    RUN_DIR="$(dirname "$config_path")" \
                    RUN_CMD="$cmd" \
                    bash -c '
                        [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
                        [ -f ".env" ] && set -a && source .env && set +a
                        eval "$RUN_CMD"
                    ' 2>&1 | tee "$log_file"
                exit "${PIPESTATUS[0]}"
            else
                # shellcheck disable=SC2016
                env \
                    RUN_MODE="$active_mode" \
                    RUN_DIR="$(dirname "$config_path")" \
                    RUN_CMD="$cmd" \
                    bash -c '
                        [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
                        [ -f ".env" ] && set -a && source .env && set +a
                        eval "$RUN_CMD"
                    ' 2>&1 | tee "$log_file"
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
    # Parallel tasks may have altered terminal state — restore and suppress echo
    # before the "press key" prompt so no garbage appears on screen.
    stty sane 2>/dev/null || true
    stty -echo 2>/dev/null || true
    drain_stdin
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
}

execute_task() {
    local cmd="$1"; local name="$2"; local desc="$3"; shift 3; local args=("$@")
    dry_run_mode=0  # Reset dry-run flag
    
    # Show preview if interactive and not in CLI mode
    if [ "$is_interactive" -eq 1 ] && [ "${cli_mode:-0}" -eq 0 ]; then
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
    if [ "${cli_mode:-0}" -eq 0 ]; then
        clear
    fi 
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
        echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
        return 0
    fi
    
    # Measure execution time
    local start_time
    # Record terminal state before running task
    start_time=$(date +%s)
    :
    
    # Execute with timeout
    local exit_status=0
    local log_file
    log_file=$(create_log_file "$name")
    local temp_output=""
    temp_output=$(mktemp) || { echo -e "${COLOR_ERR}Cannot create temp file${COLOR_RESET}"; return 1; }
    trap '[[ -n "${temp_output:-}" ]] && rm -f "$temp_output"' RETURN

    # Bash string-op instead of $(dirname) subshell (called on every task execution)
    local config_dir="${config_path%/*}"
    [ "$config_dir" = "$config_path" ] && config_dir="."
    # Ersten Token prüfen (Schutz vor kaputten Kommandos)
    local first_token="${cmd%% *}"
    if [ -n "$first_token" ] && ! command -v "$first_token" >/dev/null 2>&1 && [[ "$first_token" != */* ]]; then
        echo -e "\n${COLOR_ERR}Invalid task command: '$first_token' — skipping execution.${COLOR_RESET}"
        exit_status=127
    else
        # Script-String einmal definieren – shared zwischen timeout- und fallback-Pfad
        # shellcheck disable=SC2016
        local _exec_script='
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            [ -f ".env" ] && set -a && source .env && set +a
            eval "$RUN_CMD $RUN_ARGS"
        '
        if command -v timeout >/dev/null 2>&1; then
            timeout "$task_timeout" env \
                RUN_MODE="$active_mode" \
                RUN_DIR="$config_dir" \
                RUN_CMD="$cmd" \
                RUN_ARGS="${args[*]:-}" \
                bash -c "$_exec_script" > "$temp_output" 2>&1
            exit_status=$?
            [ "$exit_status" -eq 124 ] && \
                echo -e "\n${COLOR_ERR}$(msg task_timeout) (${task_timeout}s).${COLOR_RESET}"
        else
            env \
                RUN_MODE="$active_mode" \
                RUN_DIR="$config_dir" \
                RUN_CMD="$cmd" \
                RUN_ARGS="${args[*]:-}" \
                bash -c "$_exec_script" > "$temp_output" 2>&1
            exit_status=$?
        fi
    fi
    
    # Ausgabe verarbeiten: Log-FD einmal öffnen statt pro Zeile open/write/close
    exec 3>>"$log_file"
    while IFS= read -r line; do
        process_progress_output "$line"
        printf '%s\n' "$line" >&3
    done < "$temp_output"
    exec 3>&-
    
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
    
    # Invalidate menu cache after task execution (config may have changed)
    last_config_mtime=0

    # Interactive cleanup and keypress prompt — skipped in CLI mode
    if [ "${cli_mode:-0}" -eq 0 ]; then
        # Reset terminal state to clean state after task execution
        # This prevents issues with arrow keys and terminal modes.
        # Immediately re-disable echo after sane so arrow keys pressed between the
        # log line and "Taste drücken..." are not echoed as [A / [B garbage.
        stty sane 2>/dev/null || true
        stty -echo 2>/dev/null || true
        tput cnorm 2>/dev/null || true
        # Drain any bytes the task may have left in stdin (e.g. arrow-key sequences
        # typed during/after task execution) before the "press key" prompt.
        drain_stdin
        echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
    fi
    return "$exit_status"
}

# ==============================================================================
#  CLI MODE (non-interactive --list / --run)
# ==============================================================================

# shellcheck disable=SC2034
_cli_matches=()   # populated by cli_match_tasks(); array of matching indices

cli_match_tasks() {
    local query="$1"
    _cli_matches=()
    local total=${#menu_options[@]}

    # Numeric query: direct 1-based index lookup
    if [[ "$query" =~ ^[0-9]+$ ]]; then
        local idx=$(( query - 1 ))
        if [ "$idx" -lt 0 ] || [ "$idx" -ge "$total" ]; then
            echo "Task number $query out of range (1–$total)" >&2
            return 1
        fi
        _cli_matches=("$idx")
        return 0
    fi

    local query_lower i _lvl _name _cmd _desc name_lower
    query_lower=$(tr '[:upper:]' '[:lower:]' <<< "$query")

    # Pass 1: exact name match (case-insensitive full string)
    for (( i=0; i<total; i++ )); do
        IFS='|' read -r _lvl _name _cmd _desc <<< "${menu_options[$i]}"
        name_lower=$(tr '[:upper:]' '[:lower:]' <<< "$_name")
        [ "$name_lower" = "$query_lower" ] && _cli_matches+=("$i")
    done
    [ "${#_cli_matches[@]}" -gt 0 ] && return 0

    # Pass 2: substring match (case-insensitive)
    for (( i=0; i<total; i++ )); do
        IFS='|' read -r _lvl _name _cmd _desc <<< "${menu_options[$i]}"
        name_lower=$(tr '[:upper:]' '[:lower:]' <<< "$_name")
        [[ "$name_lower" == *"$query_lower"* ]] && _cli_matches+=("$i")
    done

    if [ "${#_cli_matches[@]}" -eq 0 ]; then
        echo "No task found matching '$query'" >&2
        return 1
    fi
    return 0
}

cli_run_task() {
    local query="$1"
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
        # Disambiguation: print matches, read single keypress
        echo "Multiple matches for \"$query\":"
        local j _lvl _name _cmd _desc
        for (( j=0; j<match_count; j++ )); do
            IFS='|' read -r _lvl _name _cmd _desc <<< "${menu_options[${_cli_matches[$j]}]}"
            printf "  %d)  %s\n" "$(( j + 1 ))" "$_name"
        done
        echo ""
        printf "Select [1-%d] or q to cancel: " "$match_count"

        local key
        while true; do
            stty -icanon min 1 time 0 2>/dev/null
            key=$(dd bs=1 count=1 2>/dev/null)
            stty sane 2>/dev/null || true
            case "$key" in
                q|Q|$'\x1b')
                    echo ""
                    echo "Cancelled."
                    return 0
                    ;;
                [1-9])
                    local sel
                    sel=$(( key - 1 ))
                    if [ "$sel" -lt "$match_count" ]; then
                        echo "$key"
                        chosen_idx="${_cli_matches[$sel]}"
                        break
                    fi
                    ;;
            esac
        done
    fi

    local _lvl _name _cmd _desc
    IFS='|' read -r _lvl _name _cmd _desc <<< "${menu_options[$chosen_idx]}"
    execute_task "$_cmd" "$_name" "$_desc"
    return $?
}

cli_list_tasks() {
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        echo "No tasks found."
        return 0
    fi
    echo "Tasks ($total)"
    local i _lvl _name _cmd _desc
    for (( i=0; i<total; i++ )); do
        IFS='|' read -r _lvl _name _cmd _desc <<< "${menu_options[$i]}"
        local num=$(( i + 1 ))
        printf "  %2d)  %-22s  %s\n" "$num" "${_name:0:22}" "$_desc"
    done
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
    # printf statt echo: sicher gegen Werte die mit -e/-n beginnen (z.B. "-n" als Env-Var)
    printf '%s\n' "$out"
}


create_log_file() {
    local task_name="$1"
    mkdir -p "$RUN_LOG_DIR" 2>/dev/null || true
    local safe_name
    safe_name=$(sanitize_filename "$task_name")
    [ -z "$safe_name" ] && safe_name="task"
    echo "$RUN_LOG_DIR/$(date '+%Y-%m-%d_%H-%M-%S')_${safe_name}.log"
}


extract_field_from_grep() {
    # Extract field from grep result
    # Usage: extract_field_from_grep "^TIMEOUT=" "=" 2
    local pattern="$1"
    local delimiter="$2"
    local field_idx="$3"
    if [ -f "$config_path" ]; then
        awk -F"$delimiter" -v pat="$pattern" -v idx="$field_idx" '$0 ~ pat {val=$idx; gsub(/^[ \t]+|[ \t]+$/, "", val); print val; exit}' "$config_path" 2>/dev/null || true
    fi
}
