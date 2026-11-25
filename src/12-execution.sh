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
    # IFS-Split ohne Here-String (kein temporäres File, kein Fork)
    split_by_char ',' "$options_str"
    local _opt
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    if [ ${#_SPLIT_ARR[@]} -gt 0 ]; then
        for _opt in "${_SPLIT_ARR[@]}"; do
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

# Quelltext des Env-Guards.
#
# Das Task-Skript läuft in einem Kind-Bash ("bash -c") — dort sind die
# Funktionen des Runners nicht verfügbar.  Der Guard wird deshalb als
# Quelltext in das Task-Skript eingebettet.
#
# Aufgabe: die ".env" des Projektverzeichnisses laden, ohne dass sie den
# Runner oder den Task beschädigen kann.  "set -a; source .env" exportiert
# *alle* Variablen der Datei — ein "PATH=/broken" therein zerstörte die
# Kommandosuche des Tasks, ein "BASH_ENV=..." wurde in jedem Kind-Bash
# ausgeführt.  Dieselbe Lücke wie bei "~/.run_vars" (siehe
# load_global_vars), deshalb werden die gefährlichen Namen nach dem Sourcing
# wiederhergestellt.
# shellcheck disable=SC2016
RUN_ENV_GUARD_SCRIPT='
_run_env_guard() {
    _g_path="$PATH"
    _g_ifs_set=0
    if [ -n "${IFS+set}" ]; then _g_ifs_set=1; _g_ifs="$IFS"; fi
    if [ -f ".env" ]; then
        set -a
        # "./.env" und nicht "source .env": "source" sucht den Dateinamen
        # im PATH, wenn er keinen Slash enthält — ein .env aus dem PATH
        # würde sonst geladen.
        . ./.env
        set +a
    fi
    PATH="$_g_path"
    if [ "$_g_ifs_set" -eq 1 ]; then IFS="$_g_ifs"; else unset IFS; fi
    unset BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT
    unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
}
'

# PIDs of the running parallel tasks — used by the Ctrl+C handler.
_parallel_task_pids=()

# Beendet alle direkten Kinder eines Prozesses.
#
# "pkill -P <ppid>" beendet auf macOS nichts: ohne Muster ist der Aufruf
# wirkungslos (der Kindprozess lebt weiter) — die Kinder werden deshalb über
# "pgrep -P" gesucht und einzeln beendet.
#
# Usage: kill_children <pid> [SIGNAL]
kill_children() {
    local _pid="$1" _sig="${2:-TERM}" _child
    for _child in $(pgrep -P "$_pid" 2>/dev/null); do
        kill -"$_sig" "$_child" 2>/dev/null || true
    done
    return 0
}

# Stops all running parallel tasks (task command + wrapper).
_kill_parallel_tasks() {
    local _p
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    [ ${#_parallel_task_pids[@]} -eq 0 ] && return 0
    for _p in "${_parallel_task_pids[@]}"; do
        kill_children "$_p" TERM
        kill -TERM "$_p" 2>/dev/null || true
    done
}

# Kills a process and all of its descendants.
#
# Killing only the direct child left the grandchildren (npm, docker, dev
# servers) running as orphans — after a timeout two "sleep 60" processes were
# still alive.  pgrep -P lists the children; the recursion covers the whole
# tree.  Systems without pgrep fall back to killing the single process.
#
# Usage: _kill_process_tree <pid> [SIGNAL]
_kill_process_tree() {
    local _pid="$1" _sig="${2:-TERM}" _child
    for _child in $(pgrep -P "$_pid" 2>/dev/null); do
        _kill_process_tree "$_child" "$_sig"
    done
    kill -"$_sig" "$_pid" 2>/dev/null || true
    return 0
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
# ignored on macOS.  The watchdog kills the whole process tree, not just the
# direct child.
#
# Usage: run_task_streamed <script> <log-file> <timeout> [command args...]
# Exit status of the last run_task_streamed() call.
# The output has to reach the terminal, so the status cannot be returned
# via a command substitution.
TASK_EXIT_STATUS=0

# PID of the running timeout watchdog — the EXIT trap terminates it (a
# watchdog that outlives the runner would run until the timeout expires).
_WATCHDOG_PID=""
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
    # The log file is opened once (fd 3) — one open/close per line was a
    # noticeable syscall overhead for output-heavy tasks.
    (
        exec 3>>"$_log" 2>/dev/null || exit 0
        while IFS= read -r _line || [ -n "$_line" ]; do
            process_progress_output "$_line"
            printf '%s\n' "$_line" >&3
            _line=""
        done < "$_fifo"
        exec 3>&-
        : > "$_reader_done"
    ) &
    local _reader_pid=$!

    # Watchdog: stops the command when the timeout expires.
    # Its output goes to /dev/null — a background job that keeps stdout open
    # would block `run --list | command` until the timeout expired.
    # The TERM trap makes the watchdog exit cleanly: a job that is killed
    # by a signal is reported by bash ("Terminated: 15 (…)" plus the whole
    # command text) and that garbage ended up in the user's terminal.
    (
        trap 'exit 0' TERM
        # Wait for the command PID (max ~2 s) so the timeout is not lost
        # because the watchdog woke up before the PID was published.
        _n=0
        while [ ! -s "$_pidfile" ] && [ "$_n" -lt 20 ]; do
            sleep 0.1
            _n=$(( _n + 1 ))
        done
        sleep "$_secs"
        _wpid=$(cat "$_pidfile" 2>/dev/null)
        if [ -n "$_wpid" ] && [ ! -f "$_donefile" ]; then
            printf '1' > "$_timeoutfile"
            # Kill the whole tree, not only the direct child — otherwise
            # grandchildren keep running as orphans.
            _kill_process_tree "$_wpid" TERM
            sleep 1
            _kill_process_tree "$_wpid" KILL
        fi
    ) >/dev/null 2>&1 &
    local _watchdog_pid=$!
    # Der Watchdog wird im EXIT-Trap beendet: bricht der Runner ab (SIGTERM,
    # SIGHUP), blieb er sonst als Waise zurück und lief bis zum Timeout
    # (300 s) weiter.
    _WATCHDOG_PID="$_watchdog_pid"

    # Command (foreground): `sh -c 'echo $PPID'` publishes the PID of this
    # subshell for the watchdog, `exec` replaces it with the command itself.
    ( sh -c 'echo $PPID' > "$_pidfile"; exec "$@" ) > "$_fifo" 2>&1
    _rc=$?

    : > "$_donefile"
    # Stop the watchdog and its sleep before it is killed itself — otherwise
    # the sleep would survive as an orphan (and the watchdog would stay alive
    # until the timeout expires).
    kill_children "$_watchdog_pid" TERM
    kill "$_watchdog_pid" 2>/dev/null || true
    _WATCHDOG_PID=""

    # Let the reader flush the remaining output, then stop it.
    # The wait is bounded: a task that leaves a background process behind
    # keeps the FIFO open forever and the reader would never see EOF.
    _n=0
    while [ ! -f "$_reader_done" ] && [ "$_n" -lt 40 ]; do
        sleep 0.05 2>/dev/null || sleep 1
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
    # IFS-Split ohne Here-String (kein temporäres File)
    split_by_char ';' "$steps_str"
    local -a steps=("${_SPLIT_ARR[@]}")
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
    [ ${#steps[@]} -eq 0 ] && return 0
    for step in "${steps[@]}"; do
        step=$(trim_whitespace "$step")
        [ -z "$step" ] && continue
        echo -e "  ${COLOR_DIM}→ $step${COLOR_RESET}"
        if ! find_task_in_menu "$step" '_execute_pipeline_callback'; then
            echo -e "${COLOR_ERR}❌ Task '$step' failed or not found in:${COLOR_RESET}"
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
    local started=0
    # Das Arbeitsverzeichnis der Tasks — config_dir_of() löst auch die
    # Sonderfälle auf (Pfad ohne Slash -> ".", Pfad in "/" -> "/").
    # "${config_path%/*}" lieferte für einen Pfad ohne Slash den Dateinamen
    # (das "cd" schlug fehl, der Task lief im falschen Verzeichnis) und für
    # einen Pfad in "/" einen leeren String ("cd ''" schlug fehl).
    local RUN_CONFIG_DIR
    RUN_CONFIG_DIR="$(config_dir_of "$config_path")"
    local _timeout="$task_timeout"
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
        # Dependenz-Annotationen im Parallel-Modus behandeln wie im
        # sequentiellen: Dependencies laufen sequentiell VOR dem Task,
        # und die Annotation wird aus dem Kommando entfernt (sieht man
        # vorher als Literal-Argument im eval).
        local deps
        deps=$(parse_task_deps "$cmd" "$desc")
        if [ -n "$deps" ]; then
            if ! execute_task_deps "$deps"; then
                echo -e "${COLOR_ERR}✗ $name (dependencies failed)${COLOR_RESET}"
                continue
            fi
            cmd="${cmd// \[depends:[^]]*\]/}"
        fi
        # Der Timeout kann pro Task in der Beschreibung stehen ("[timeout: 120]")
        # — sonst gilt der globale Wert.  Die pro-Task-Regel galt vormals nur
        # im sequentiellen Modus, der Parallel-Modus nahm blind den globalen.
        task_timeout_for_desc "$desc"
        _timeout="$TASK_TIMEOUT_VALUE"
        local log_file
        create_log_file "$name"
        log_file="$LOG_FILE"
        local start_time
        start_time=$(date +%s)
        # shellcheck disable=SC2016
        local _par_body='
            trap - INT
            trap - PIPE
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            _run_env_guard
            eval "$RUN_CMD"
        '
        local _par_script="$RUN_ENV_GUARD_SCRIPT$_par_body"
        (
            run_task_streamed "$_par_script" "$log_file" "$_timeout" \
                env \
                RUN_MODE="$active_mode" \
                RUN_DIR="$RUN_CONFIG_DIR" \
                RUN_CMD="$cmd" \
                bash -c "$_par_script"
            # run_task_streamed liefert den echten Status in TASK_EXIT_STATUS
            # und gibt immer 0 zurück — ohne das explizite exit meldete der
            # Parallel-Modus jeden Task als "erfolgreich" (auch einen, der
            # mit exit 1 endete), und die Historie zeichnete "exit:0" auf.
            exit "${TASK_EXIT_STATUS:-0}"
        ) &
        pids+=("$!")
        _parallel_task_pids+=("$!")
        names+=("$name")
        starts+=("$start_time")
        started=$((started + 1))
    done
    if [ "$started" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tasks eligible for parallel run.${COLOR_RESET}"
        sleep 1
        # Nichts wurde ausgeführt — der Aufrufer muss das unterscheiden
        # können (vorher meldete die Funktion hier Erfolg).
        return 1
    fi
    # Ctrl+C stops all running parallel tasks.  Bash sets SIGINT to "ignore"
    # for background jobs, so the tasks themselves cannot be interrupted —
    # the menu kills them (and their children) instead.
    trap '_kill_parallel_tasks' INT
    local _failed=0
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
            _failed=1
        fi
    done
    trap 'restore_term; cleanup_wrapper; exit 130' INT
    # The PID list is only valid for this run — an old entry would kill an
    # unrelated process on the next Ctrl+C.
    _parallel_task_pids=()
    # Parallel tasks may have altered terminal state — restore and suppress echo
    # before the "press key" prompt so no garbage appears on screen.
    stty sane 2>/dev/null || true
    stty -echo 2>/dev/null || true
    drain_stdin
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"; consume_keypress
    # Der Exit-Code meldet, ob alle Tasks erfolgreich waren — vorher
    # meldete die Funktion immer Erfolg, auch wenn ein Task fehlschlug.
    return "$_failed"
}

# Resolves the placeholders of a task command ("<<Name>>", "<<Name=a>>",
# "<<Name:a,b>>") and asks the user for the values.
#
# Result: RESOLVED_CMD (the command with the replaced placeholders).
#
# Endlosschleife: enthielt der eingegebene Wert den Platzhalter selbst
# ("<<Name>>"), blieb dieser im Kommando stehen und die while-Schleife fragte
# endlos nach.  Der verbliebene Platzhalter wird deshalb entfernt; zusätzlich
# begrenzt ein Zähler die Iterationen.
RESOLVED_CMD=""
resolve_placeholders() {
    local cmd="$1"
    local _iterations=0
    while [[ "$cmd" =~ \<\<([^:=>]+)(=[^:>]*)?(:[^>]*)?\>\> ]]; do
        _iterations=$(( _iterations + 1 ))
        if [ "$_iterations" -gt 20 ]; then
            echo -e "${COLOR_ERR}Zu viele Eingabefelder — der Task wird abgebrochen.${COLOR_RESET}"
            RESOLVED_CMD=""
            return 1
        fi
        local p="${BASH_REMATCH[1]}"
        local default_spec="${BASH_REMATCH[2]}"  # "=value" or ""
        local default_val="${default_spec#=}"     # strip leading "="
        local rest="${BASH_REMATCH[3]}"
        # Der vollständige Platzhalter-Text (für die Erkennung im Ergebnis)
        local _ph="<<${p}${default_spec}${rest}>>"
        if [[ "$rest" == :* ]]; then
            local opts_str="${rest:1}"
            echo -e "\n${COLOR_INFO}$(msg choose_for)${COLOR_RESET} $p"
            local r=""
            # Ein Abbruch (ESC) muss den Task abbrechen: vorher ersetzte der
            # leere Wert den Platzhalter und der Task lief mit einem
            # leeren Parameter ("--env ").
            if ! r=$(select_dropdown "$opts_str"); then
                echo -e "${COLOR_INFO}$(msg task_cancelled)${COLOR_RESET}"
                RESOLVED_CMD=""
                return 1
            fi
            cmd="${cmd//\<\<"$p":"$opts_str"\>\>/${r:-}}"
        else
            echo -e "\n${COLOR_INFO}$(msg input_for)${COLOR_RESET} $p"
            # "r" vorbelegen: bei EOF (Pipe ohne Eingabe) setzt "read" die
            # Variable auf "unset" — unter "set -u" wäre die Ersetzung dann
            # ein Abbruch.
            local r=""
            if [ -n "$default_val" ]; then
                read -r -p "[${default_val}] > " r || true
                [ -z "${r:-}" ] && r="$default_val"
            else
                read -r -p "> " r || true
            fi
            cmd="${cmd//<<${p}${default_spec}>>/${r:-}}"
        fi
        # Der Wert enthält den Platzhalter selbst → er wird entfernt,
        # damit die Schleife endet.
        if [[ "$cmd" == *"$_ph"* ]]; then
            cmd="${cmd//"$_ph"/}"
        fi
    done
    RESOLVED_CMD="$cmd"
    return 0
}

execute_task() {
    local cmd="$1"; local name="$2"; local desc="$3"; shift 3; local args=("$@")
    # dry_run_mode is set externally (--dry-run flag or future interactive 'd' key).
    # Do NOT reset here — it is consumed and cleared inside the dry-run block below.
    #
    # Quiet mode: the task runs in the background (parallel dependencies).
    # A background process must not touch the terminal of the menu — no
    # preview, no screen clear, no terminal reset and no key prompt.
    local _quiet=0
    [ "${TASK_QUIET:-0}" = "1" ] && _quiet=1
    # Show preview if interactive and not in CLI mode
    if [ "$_quiet" -eq 0 ] && [ "$is_interactive" -eq 1 ] && [ "${cli_mode:-0}" -eq 0 ]; then
        if ! preview_task "$cmd" "$name" "$desc"; then
            return  # User cancelled
        fi
    fi

    if [[ "$cmd" == tasks:* ]]; then
        execute_task_pipeline "$cmd"
        return $?
    fi

    if [ "$_quiet" -eq 0 ] && [ "$is_interactive" -eq 1 ]; then
        # "|| true": a failing tput (TERM=dumb, broken terminfo) must not
        # abort the script — the cursor restore is cosmetic.
        tput cnorm 2>/dev/null || true
    fi
    if [ "$_quiet" -eq 0 ] && [ "${cli_mode:-0}" -eq 0 ]; then
        clear
    fi
    echo -e "${COLOR_HEAD}$(msg executing)${COLOR_RESET} $name"

    if [[ "$desc" == "[!]"* ]]; then
        echo -e "\n${COLOR_WARN}⚠ $(msg warning_label): ${desc#"[!] "}${COLOR_RESET}"
        # "|| true": ohne TTY (SSH ohne -t, Pipe, cron) liefert read sofort
        # EOF — ohne das würde das Skript unter "set -e" abbrechen.
        read -p "$(msg confirm_prompt) " -n 1 -r || true; echo ""
        if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
            # Abgelehnt (oder gar keine Bestätigung möglich): der Task wurde
            # NICHT ausgeführt.  Der Rückgabewert muss das widerspiegeln —
            # sonst meldete "run --run <task>" Erfolg, obwohl nichts lief.
            echo -e "${COLOR_INFO}$(msg task_cancelled)${COLOR_RESET}"
            return 1
        fi
    fi

    # Handle task dependencies
    # Die Annotation wird im Kommando *und* in der Beschreibung gesucht:
    # die Doku beschreibt beide Formen ("cmd [depends: X]" und
    # "desc [depends: X]").
    local deps
    deps=$(parse_task_deps "$cmd" "$desc")
    if [ -n "$deps" ]; then
        execute_task_deps "$deps" || return 1
        # Remove dependency annotation from command — alle Vorkommen, nicht
        # nur das letzte: "%" hätte bei einer Annotation mitten im Kommando
        # nichts entfernt (das Muster muss am Ende stehen) und der Task
        # wäre mit "[depends: X]" in der Kommandozeile gescheitert.
        cmd="${cmd// \[depends:[^]]*\]/}"
    fi

    # Platzhalter-Eingaben ("<<Name>>", "<<Name=a>>", "<<Name:a,b>>")
    if ! resolve_placeholders "$cmd"; then
        return 1
    fi
    cmd="$RESOLVED_CMD"

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
    create_log_file "$name"
    log_file="$LOG_FILE"

    # Bash string-op instead of $(dirname) subshell (called on every task execution)
    # config_dir_of() löst die Sonderfälle auf (Pfad ohne Slash -> ".",
    # Pfad in "/" -> "/").  "${config_path%/*}" lieferte für "/.tasks" einen
    # leeren String — ein "cd ''" schlägt fehl und der Task lief im
    # falschen Verzeichnis.
    local config_dir
    config_dir="$(config_dir_of "$config_path")"
    # Der Timeout kann pro Task in der Beschreibung stehen ("[timeout: 120]"),
    # sonst gilt der globale Wert aus der "TIMEOUT="-Zeile.
    task_timeout_for_desc "$desc"
    local _timeout="$TASK_TIMEOUT_VALUE"
    # Ersten Token prüfen (Schutz vor kaputten Kommandos).
    # Env-Zuweisungen ("FOO=bar cmd") sind gültig — der geprüfte Token ist dann
    # das Kommando, nicht die Zuweisung.  Variablen ("$CMD") sind ebenfalls
    # gültig: der Wert wird erst zur Laufzeit aufgelöst, `command -v` kann
    # ihn nicht kennen.
    local first_token="${cmd%% *}"
    if [[ "$first_token" == *=* ]]; then
        # "FOO=bar cmd ..." → skip the assignment and check the command
        local _rest="${cmd#* }"
        if [[ "$_rest" == *'"'* || "$_rest" == *"'"* ]]; then
            # Der Wert der Zuweisung darf Leerzeichen und Anführungszeichen
            # enthalten ("FOO=\"a b\" cmd") — dann ist das Kommando nicht
            # zuverlässig zerlegbar und wird nicht geprüft (sonst wurde der
            # Task fälschlich als "Invalid task command" abgelehnt).
            first_token=""
        else
            first_token="${_rest%% *}"
        fi
    fi
    if [ -n "$first_token" ] && [[ "$first_token" != */* ]] && [[ "$first_token" != \$* ]] \
       && ! command -v "$first_token" >/dev/null 2>&1; then
        echo -e "\n${COLOR_ERR}Invalid task command: '$first_token' — skipping execution.${COLOR_RESET}"
        exit_status=127
    else
        # Script-String einmal definieren – shared zwischen timeout- und fallback-Pfad
        # shellcheck disable=SC2016
        local _exec_body='
            trap - INT
            trap - PIPE
            [ "$RUN_MODE" == "local" ] && cd "$RUN_DIR"
            _run_env_guard
            eval "$RUN_CMD $RUN_ARGS"
        '
        local _exec_script="$RUN_ENV_GUARD_SCRIPT$_exec_body"
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
        run_task_streamed "$_exec_script" "$log_file" "$_timeout" \
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
        echo -e "\n${COLOR_ERR}$(msg task_failed) (timeout ${_timeout}s).${COLOR_RESET}"
    else
        echo -e "\n${COLOR_ERR}$(msg task_failed) (exit $exit_status).${COLOR_RESET}"
    fi

    # Show execution time
    echo -e "${COLOR_DIM}⏱ ${task_execution_time}s${COLOR_RESET}"

    # Log to history
    add_to_history "$name" "$exit_status" "$task_execution_time"

    echo -e "${COLOR_DIM}Log: $log_file${COLOR_RESET}"

    # Invalidate menu cache after task execution (config may have changed)
    if command -v invalidate_menu_cache >/dev/null 2>&1; then
        invalidate_menu_cache
    else
        last_config_stamp=""
        _menu_cache_key=""
    fi

    # Interactive cleanup and keypress prompt — skipped in CLI mode and in
    # quiet mode (a background process must not reset the terminal).
    if [ "$_quiet" -eq 0 ] && [ "${cli_mode:-0}" -eq 0 ]; then
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

# Runs a task without any terminal interaction: no preview, no screen clear,
# no terminal reset and no "press any key" prompt.
#
# Used for tasks that run in the background (parallel dependencies) — a
# background process must not touch the terminal of the menu.  The prompt
# alone deadlocked the menu: the dependency waited for a key that the
# parent process was waiting for.
execute_task_quiet() {
    local _prev_quiet="${TASK_QUIET:-0}"
    local _rc=0
    TASK_QUIET=1
    execute_task "$@" || _rc=$?
    TASK_QUIET="$_prev_quiet"
    return "$_rc"
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
        _build_all_tasks
        menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    fi
    local total=${#menu_options[@]}

    # Numeric query: direct 1-based index lookup
    if [[ "$query" =~ ^[0-9]+$ ]]; then
        # "10#" erzwingt die Basis 10: "08" ist sonst eine ungültige
        # Oktalzahl ("value too great for base") — die Rechnung bricht ab
        # und der Task wird nicht ausgeführt.
        local idx=$(( 10#$query - 1 ))
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
        _build_all_tasks
        menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
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
        # Disambiguation: print matches, read the selection.
        # Two-digit selection: the prompt promises "Select [1-N]" — with
        # only single digits accepted the entries 10+ were unreachable and
        # the loop spun forever on an invalid key.
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
            key="${key%$'\r'}"
            case "$key" in
                q|Q|$'\x1b')
                    echo ""
                    echo "Cancelled."
                    return 0
                    ;;
                ''|*[!0-9]*)
                    echo "Invalid selection. Try again."
                    continue
                    ;;
            esac
            # Two-digit selection: with more than nine matches the entries
            # 10+ were displayed but could not be selected.
            if [ -t 0 ] && [ "${#key}" -eq 1 ] && [ "$match_count" -gt 9 ] && [ "$key" != "0" ]; then
                local _next
                # 1 s — long enough to type a second digit
                _next=$(read_key_optional 10)
                if [ -n "$_next" ] && [[ "$_next" =~ ^[0-9]$ ]]; then
                    key="${key}${_next}"
                fi
            fi
            # "10#" forces the decimal base (a leading zero would be octal)
            local _sel=$(( 10#$key - 1 ))
            if [ "$_sel" -ge 0 ] && [ "$_sel" -lt "$match_count" ]; then
                echo "$key"
                chosen_idx="${_cli_matches[$_sel]}"
                break
            fi
            echo "Invalid selection. Try again."
        done
    fi

    local _lvl _name _cmd _desc
    split_task_line "${menu_options[$chosen_idx]}"
    execute_task "$_f_cmd" "$_f_name" "$_f_desc"
    return $?
}

cli_list_tasks() {
    if [ ${#menu_options[@]} -eq 0 ]; then
        _build_all_tasks
        menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
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
            # Sicherheits-Gate: einige Variablen dürfen nicht gesetzt werden.
            #   PATH/CDPATH  — zerstören die Kommandosuche (der Runner fand
            #                   danach keine Tasks mehr: "No tasks found")
            #   IFS          — ändern die Wortzerlegung im Runner selbst
            #   BASH_ENV/ENV — führen zu Codeausführung in jedem Kind-Bash
            #   LD_*/DYLD_*  — injizieren Code in die Task-Prozesse
            #   SHELLOPTS/…  — sind in bash readonly (ein "export" wäre ein
            #                   Fehler und würde das Skript abbrechen)
            case "$key" in
                PATH|CDPATH|GLOBIGNORE|IFS|\
                BASH_ENV|ENV|SHELLOPTS|BASHOPTS|PROMPT_COMMAND|PS4|\
                LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|\
                DYLD_INSERT_LIBRARIES|DYLD_LIBRARY_PATH|DYLD_FRAMEWORK_PATH)
                    continue
                    ;;
            esac
            # Der Runner deklariert eigene readonly-Konstanten (VERSION,
            # RUN_LOG_DIR, RUN_TASK_TIMEOUT, …).  Ein "export" auf einen der
            # readonly-Namen bricht unter "set -e" das GESAMTE Skript ab
            # (einzelne "readonly variable"-Zeile, kein Menü) — und der
            # EXIT-Trap maskierte diesen Abbruch sogar als Erfolg (Exit 0).
            # Readonly-Namen werden deshalb übersprungen.
            if declare -p "$key" 2>/dev/null | grep -qE 'declare -[A-Za-z]*r' ; then
                continue
            fi
            export "$key"="$value"
        fi
    done < "$RUN_VARS_FILE"
}

load_task_vars() {
    # The errexit/pipefail state is saved and restored instead of being
    # forced on: the interactive menu loop runs with "set +e" and a blind
    # "set -e" at the end of this function would end the whole menu.
    save_shell_opts
    set +e +o pipefail  # Disable errexit and pipefail for regex operations
    if [ ! -f "$config_path" ]; then
        restore_shell_opts
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^VAR_[A-Za-z0-9_]+= ]] || continue
        local key="${line%%=*}"
        local value="${line#*=}"
        export "$key"="$value" 2>/dev/null || true
    done < "$config_path"
    restore_shell_opts  # Restore errexit and pipefail
}

# Counter for the log file names — makes the name unique per task.
_LOG_SEQ=0

# Path of the log file created by the last create_log_file() call.
#
# The function sets a global instead of printing the path: the counter is
# incremented inside the function, and a command substitution would run the
# function in a subshell — the increment was lost and every log file got the
# same sequence number.  Two tasks with the same name (or the same task
# twice in the same second) then shared one log file and their output was
# interleaved.
LOG_FILE=""

create_log_file() {
    local task_name="$1"
    mkdir -p "$RUN_LOG_DIR" 2>/dev/null || true
    local safe_name
    safe_name=$(sanitize_filename "$task_name")
    [ -z "$safe_name" ] && safe_name="task"
    # The timestamp has a resolution of one second: two tasks with the same
    # name (parallel execution) would share one log file and their output
    # would interleave.  The PID and the counter make the name unique.
    _LOG_SEQ=$(( _LOG_SEQ + 1 ))
    LOG_FILE="$RUN_LOG_DIR/$(date '+%Y-%m-%d_%H-%M-%S')_$$_${_LOG_SEQ}_${safe_name}.log"
    return 0
}

# Determines the timeout of a task.
#
# A task can carry its own timeout in the description ("[timeout: 120]");
# otherwise the global value from the "TIMEOUT=" line applies.  An invalid
# value falls back to the global one.
#
# Result: TASK_TIMEOUT_VALUE
TASK_TIMEOUT_VALUE=""
task_timeout_for_desc() {
    local desc="${1:-}"
    TASK_TIMEOUT_VALUE="$task_timeout"
    # "[:space:]*": die Doku schreibt "[timeout: 120]" mit einem Leerzeichen
    # nach dem Doppelpunkt.
    if [[ "$desc" =~ \[timeout:[[:space:]]*([0-9]+)\] ]]; then
        local _t="${BASH_REMATCH[1]}"
        if [ "$_t" -gt 0 ]; then
            TASK_TIMEOUT_VALUE="$_t"
        fi
    fi
    return 0
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
