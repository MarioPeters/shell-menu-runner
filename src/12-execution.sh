# ==============================================================================
#  TASK EXECUTION ENGINE
# ==============================================================================

# Lets the user pick one of several values for a task parameter.
#
# The caller captures the result with `r=$(select_dropdown ...)`, so the
# selection goes to stdout while the whole UI goes to stderr — otherwise the
# option list would end up inside the variable and the picked value would be
# lost.
select_dropdown() {
    local options_str="$1"
    local -a options=()
    # IFS-Split statt printf|tr-Pipeline: kein Fork, Bash 3.2-kompatibel
    local -a _raw_opts=()
    IFS=',' read -r -a _raw_opts <<< "$options_str"
    local _opt
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    if [ ${#_raw_opts[@]} -gt 0 ]; then
        for _opt in "${_raw_opts[@]}"; do
            [ -n "$_opt" ] && options+=("$_opt")
        done
    fi
    local selected=0
    local num=${#options[@]}
    [ "$num" -eq 0 ] && return 1

    # Without a TTY (pipe, SSH without -t) the options are chosen by number
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
        # Cursor zurück auf 0,0 statt clear → kein Flicker (wie Hauptmenü)
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
        # Rest der Zeilen löschen damit alte Einträge nicht stehen bleiben
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

_execute_pipeline_callback() {
    local step_name="$1"
    local step_cmd="$2"
    local step_desc="$3"
    execute_task "$step_cmd" "$step_name" "$step_desc" || return 1
}

# ==============================================================================
#  COMMAND RUNNER — TIMEOUT, INTERRUPT AND OUTPUT STREAMING
# ==============================================================================

# PIDs of the running parallel tasks — used by the Ctrl+C handler.
_parallel_task_pids=()

# Stops all running parallel tasks (task command + wrapper).
_kill_parallel_tasks() {
    local _p
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    [ ${#_parallel_task_pids[@]} -eq 0 ] && return 0
    for _p in "${_parallel_task_pids[@]}"; do
        pkill -P "$_p" 2>/dev/null || true
        kill -TERM "$_p" 2>/dev/null || true
    done
}

# Runs a task command and streams its output to the terminal and the log file.
#
# Two details make the difference between "the menu comes back" and "the
# terminal has to be closed":
#
#  * The command runs in the *foreground*.  Bash sets SIGINT/SIGQUIT to
#    "ignore" for background jobs, so a task started with `&` could never be
#    stopped with Ctrl+C.  Foreground + `trap ':' INT` in the menu keeps the
#    default disposition in the child — Ctrl+C kills the task, the menu lives.
#
#  * The menu waits for the *command*, never for the end of the output pipe.
#    A task that leaves a background process behind (release script, dev
#    server, `cmd &`) keeps the pipe open forever — waiting for EOF froze the
#    menu until the terminal was closed.
#
# A watchdog enforces the timeout because macOS ships no `timeout` binary
# (only GNU coreutils provides it), so the configured TIMEOUT was silently
# ignored on macOS.
#
# Usage: run_task_streamed <script> <log-file> <timeout> [command args...]
# The exit status is returned in TASK_EXIT_STATUS (the output has to reach the
# terminal, so this must not run inside a command substitution).
TASK_EXIT_STATUS=0
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
        # No FIFO available → run without live streaming
        ( exec "$@" ) 2>&1 | tee -a "$_log"
        TASK_EXIT_STATUS="${PIPESTATUS[0]}"
        return 0
    fi

    # Reader: forwards the FIFO content to the terminal and the log file.
    # `|| [ -n "$_line" ]` keeps the last line when the task output has no
    # trailing newline (e.g. `printf SUCCESS`).
    (
        while IFS= read -r _line || [ -n "$_line" ]; do
            process_progress_output "$_line"
            printf '%s\n' "$_line" >> "$_log"
            _line=""
        done < "$_fifo"
        : > "$_reader_done"
    ) &
    local _reader_pid=$!

    # Watchdog: stops the command when the timeout expires.
    # Its output goes to /dev/null — a background job that keeps stdout open
    # would block `run --task | command` until the timeout expired.
    (
        sleep "$_secs"
        _wpid=$(cat "$_pidfile" 2>/dev/null)
        if [ -n "$_wpid" ] && [ ! -f "$_donefile" ]; then
            printf '1' > "$_timeoutfile"
            kill -TERM "$_wpid" 2>/dev/null
            sleep 1
            kill -KILL "$_wpid" 2>/dev/null
        fi
    ) >/dev/null 2>&1 &
    local _watchdog_pid=$!

    # Command (foreground): `sh -c 'echo $PPID'` publishes the PID of this
    # subshell for the watchdog, `exec` replaces it with the command itself.
    ( sh -c 'echo $PPID' > "$_pidfile"; exec "$@" ) > "$_fifo" 2>&1
    _rc=$?

    : > "$_donefile"
    # Stop the watchdog and its sleep before it is killed itself — otherwise
    # the sleep would survive as an orphan.
    pkill -P "$_watchdog_pid" 2>/dev/null || true
    kill "$_watchdog_pid" 2>/dev/null || true

    # Let the reader flush the remaining output, then stop it
    while [ ! -f "$_reader_done" ] && [ "$_n" -lt 10 ]; do
        sleep 0.1 2>/dev/null || sleep 1
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
    local IFS=';'
    local -a steps=()
    read -r -a steps <<< "$steps_str"
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    [ ${#steps[@]} -eq 0 ] && return 0
    for step in "${steps[@]}"; do
        step=$(trim_whitespace "$step")
        [ -z "$step" ] && continue
        echo -e "  ${COLOR_DIM}→ $step${COLOR_RESET}"
        if ! find_task_in_menu "$step" '_execute_pipeline_callback'; then
            echo -e "${COLOR_ERR}❌ Task '$step' not found in:${COLOR_RESET}"
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
    local -a logs=()
    local started=0
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
        log_file=$(create_log_file "$name")
        local start_time
        start_time=$(date +%s)
        # shellcheck disable=SC2016
        local _par_script='
            trap - INT
            trap - PIPE
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            [ -f ".env" ] && set -a && source .env && set +a
            eval "$RUN_CMD"
        '
        (
            run_task_streamed "$_par_script" "$log_file" "$task_timeout" \
                env \
                RUN_MODE="$active_mode" \
                RUN_DIR="${config_path%/*}" \
                RUN_CMD="$cmd" \
                bash -c "$_par_script"
        ) &
        pids+=("$!")
        _parallel_task_pids+=("$!")
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
    # Ctrl+C stops all running parallel tasks.  Bash sets SIGINT to "ignore"
    # for background jobs, so the tasks themselves cannot be interrupted —
    # the menu kills them (and their children) instead.
    trap '_kill_parallel_tasks' INT
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
    trap 'restore_term; cleanup_wrapper; exit 130' INT
    # Parallel tasks may have altered terminal state — restore and suppress echo
    # before the "press key" prompt so no garbage appears on screen.
    stty sane 2>/dev/null || true
    stty -echo 2>/dev/null || true
    drain_stdin
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
}

execute_task() {
    local cmd="$1"; local name="$2"; local desc="$3"; shift 3; local args=("$@")
    # dry_run_mode is set externally (--dry-run flag or future interactive 'd' key).
    # Do NOT reset here — it is consumed and cleared inside the dry-run block below.

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

    while [[ "$cmd" =~ \<\<([^:=>]+)(=[^:>]*)?(:[^>]*)?\>\> ]]; do
        local p="${BASH_REMATCH[1]}"
        local default_spec="${BASH_REMATCH[2]}"  # "=value" or ""
        local default_val="${default_spec#=}"     # strip leading "="
        local rest="${BASH_REMATCH[3]}"
        if [[ "$rest" == :* ]]; then
            local opts_str="${rest:1}"
            echo -e "\n${COLOR_INFO}$(msg choose_for)${COLOR_RESET} $p"
            local r
            r=$(select_dropdown "$opts_str")
            cmd="${cmd//\<\<"$p":"$opts_str"\>\>/$r}"
        else
            echo -e "\n${COLOR_INFO}$(msg input_for)${COLOR_RESET} $p"
            local r
            if [ -n "$default_val" ]; then
                read -r -p "[${default_val}] > " r
                [ -z "$r" ] && r="$default_val"
            else
                read -r -p "> " r
            fi
            cmd="${cmd//<<${p}${default_spec}>>/$r}"
        fi
    done

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

    # Measure execution time
    local start_time
    # Record terminal state before running task
    start_time=$(date +%s)
    :

    # Execute with timeout
    local exit_status=0
    local log_file
    log_file=$(create_log_file "$name")

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
            trap - INT
            trap - PIPE
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            [ -f ".env" ] && set -a && source .env && set +a
            eval "$RUN_CMD $RUN_ARGS"
        '
        # `trap ':' INT` keeps the menu alive while Ctrl+C reaches the task:
        # a *trapped* signal is reset to its default disposition in the child,
        # while `trap '' INT` (ignore) would be inherited by the task and make
        # it impossible to stop — the terminal had to be closed instead.
        # The errexit state is restored afterwards — the interactive loop runs
        # with `set +e` and must not be switched to strict mode by a task.
        local _errexit_was=0
        case "$-" in *e*) _errexit_was=1 ;; esac
        set +e
        trap ':' INT
        run_task_streamed "$_exec_script" "$log_file" "$task_timeout" \
            env \
            RUN_MODE="$active_mode" \
            RUN_DIR="$config_dir" \
            RUN_CMD="$cmd" \
            RUN_ARGS="${args[*]:-}" \
            bash -c "$_exec_script"
        exit_status="$TASK_EXIT_STATUS"
        [ "$_errexit_was" -eq 1 ] && set -e
        # Restore the menu's Ctrl+C handler now that the child has finished
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
        echo -e "\n${COLOR_ERR}$(msg task_failed) (timeout ${task_timeout}s).${COLOR_RESET}"
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
    if [ ${#menu_options[@]} -eq 0 ]; then
        IFS=$'\n' read -d '' -r -a menu_options < <(get_all_tasks) || true
    fi
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

    local i _lvl _name _cmd _desc
    local _nocase_was=0
    shopt -q nocasematch && _nocase_was=1
    shopt -s nocasematch

    # Pass 1: exact name match (case-insensitive full string)
    for (( i=0; i<total; i++ )); do
        split_task_line "${menu_options[$i]}"
        [[ "$_f_name" == "$query" ]] && _cli_matches+=("$i")
    done
    [ "${#_cli_matches[@]}" -gt 0 ] && { [ "$_nocase_was" -eq 0 ] && shopt -u nocasematch; return 0; }

    # Pass 2: substring match (case-insensitive)
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
        IFS=$'\n' read -d '' -r -a menu_options < <(get_all_tasks) || true
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
        # Disambiguation: print matches, read single keypress
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
                # A closed stdin would spin this loop forever
                [ -z "$key" ] && { echo ""; echo "Cancelled."; return 0; }
            else
                # No TTY (pipe/SSH): read a whole line
                IFS= read -r key || { echo ""; echo "Cancelled."; return 0; }
            fi
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
    split_task_line "${menu_options[$chosen_idx]}"
    execute_task "$_f_cmd" "$_f_name" "$_f_desc"
    return $?
}

cli_list_tasks() {
    if [ ${#menu_options[@]} -eq 0 ]; then
        IFS=$'\n' read -d '' -r -a menu_options < <(get_all_tasks) || true
    fi
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        echo "No tasks found."
        return 0
    fi
    # 2>/dev/null: a closed stdout (`run --list | head`) must not produce a
    # "write error: Broken pipe" message from the bash builtin.
    echo "Tasks ($total)" 2>/dev/null || return 0
    local i
    for (( i=0; i<total; i++ )); do
        split_task_line "${menu_options[$i]}"
        local num=$(( i + 1 ))
        printf "  %2d)  %-22s  %s\n" "$num" "${_f_name:0:22}" "$_f_desc" 2>/dev/null || break
    done
    return 0
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
