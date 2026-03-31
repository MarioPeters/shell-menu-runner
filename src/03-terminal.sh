# ==============================================================================
#  TERMINAL & SSH DETECTION
# ==============================================================================

# Context indicator — built once at init, read by draw_menu()
_CTX_LINE=""
_CTX_BRANCH=""
_CTX_HOST=""
_CTX_ENV=""
_LAST_COL_WIDTH=0

check_interactive() {
    # Check if stdin is a TTY (interactive session)
    if [ -t 0 ]; then
        is_interactive=1
        init_terminal_capabilities
    else
        is_interactive=0
    fi
}

check_ssh_session() {
    # Check for SSH environment
    if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
        is_ssh_session=1
    else
        is_ssh_session=0
    fi
}

init_context() {
    _CTX_LINE=""; _CTX_BRANCH=""; _CTX_HOST=""; _CTX_ENV=""
    local show="${CONTEXT_SHOW:-git,hostname,env}"
    local parts=()

    # Git branch — subprocess is acceptable at init (not in render loop)
    if [[ "$show" == *"git"* ]]; then
        _CTX_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        [ -n "$_CTX_BRANCH" ] && parts+=("${COLOR_INFO}⎇ ${_CTX_BRANCH}${COLOR_RESET}")
    fi

    # Hostname — only on SSH sessions
    if [[ "$show" == *"hostname"* ]]; then
        if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
            _CTX_HOST="${HOSTNAME:-$(hostname 2>/dev/null || true)}"
            [ -n "$_CTX_HOST" ] && parts+=("${COLOR_ERR}⚡ ${_CTX_HOST}${COLOR_RESET}")
        fi
    fi

    # Environment variable
    if [[ "$show" == *"env"* ]]; then
        _CTX_ENV="${APP_ENV:-${ENVIRONMENT:-${DEPLOY_ENV:-}}}"
        if [ -n "$_CTX_ENV" ]; then
            local env_lower env_upper env_color
            env_lower=$(tr '[:upper:]' '[:lower:]' <<< "$_CTX_ENV")
            env_upper=$(tr '[:lower:]' '[:upper:]' <<< "$_CTX_ENV")
            case "$env_lower" in
                production|prod) env_color="$COLOR_ERR"  ;;
                staging|stg)     env_color="$COLOR_WARN" ;;
                development|dev) env_color="$COLOR_SEL"  ;;
                *)               env_color="$COLOR_DIM"  ;;
            esac
            parts+=("${env_color}${env_upper}${COLOR_RESET}")
        fi
    fi

    # Join parts with " · " separator — pure Bash, no subshell
    if [ "${#parts[@]}" -gt 0 ]; then
        local line="${parts[0]}"
        local i
        for (( i=1; i<${#parts[@]}; i++ )); do
            line+="${COLOR_DIM} · ${COLOR_RESET}${parts[$i]}"
        done
        _CTX_LINE="$line"
    fi
}

# Optimized terminal capability caching
_TPUT_INITIALIZED=0
init_terminal_capabilities() {
    # Only run once — guard auf dediziertes Flag statt TPUT_COLS (könnte leer sein wenn tput cols versagt)
    [ "${_TPUT_INITIALIZED:-0}" -eq 1 ] && return
    _TPUT_INITIALIZED=1

    if command -v tput >/dev/null 2>&1; then
        TPUT_CUP="$(tput cup 0 0 2>/dev/null)"
        TPUT_CIVIS="$(tput civis 2>/dev/null)"
        TPUT_CNORM="$(tput cnorm 2>/dev/null)"
        TPUT_ED="$(tput ed 2>/dev/null)"
        TPUT_COLS="$(tput cols 2>/dev/null)"
        HAS_TPUT=1
    else
        HAS_TPUT=0
        TPUT_COLS=80
    fi
    # Update cols on resize, reset border cache
    trap 'TPUT_COLS=$(tput cols 2>/dev/null || echo 80); _LAST_COL_WIDTH=0' WINCH

    # Context indicator (git branch, hostname, env)
    init_context
}

consume_keypress() {
    # Suppress echo so arrow keys / escape sequences are not printed to the
    # terminal while waiting for the keypress (e.g. after stty sane in execute_task).
    stty -echo 2>/dev/null
    read_key >/dev/null
    # Drain any remaining bytes from multi-byte escape sequences (e.g. arrow keys
    # send \x1b[A; read_key already consumed the full sequence, but defensive
    # drain prevents leftover bytes leaking into the main loop's key handler).
    drain_stdin
    stty echo 2>/dev/null
}

# Enable raw interactive input mode for the main loop.
# Flags: no echo, no canonical buffering, pass signals, block until 1 char min.
# NOTE: icrnl is intentionally left ON so Enter (\r→\n) is stripped by $()
# to "". Spurious "" from a failed read_key_raw is blocked by the _rk_status
# guard in the main loop (13-ui.sh), not by changing icrnl.
set_raw_mode() {
    stty -echo -icanon time 0 min 1 isig 2>/dev/null
}

drain_stdin() {
    # Non-blocking drain of any pending stdin bytes (e.g. escape sequence tails
    # or task output left in the buffer). Explicitly disables icanon so this
    # works regardless of the current terminal mode (e.g. after stty sane).
    # Uses bs=128 to empty buffers with fewer fork iterations.
    # Restores blocking raw mode (min 1) afterwards.
    stty -icanon min 0 time 0 2>/dev/null
    local _d
    while true; do
        _d=$(dd bs=128 count=1 2>/dev/null)
        [ -z "$_d" ] && break
    done
    stty min 1 time 0 2>/dev/null
}

read_key() {
    local key=""
    # 1. Read first char (blocking)
    # This relies on the outer loop setting stty to blocking (min 1)
    if ! read -rsn1 key; then return 1; fi

    # 2. Check for ESC sequence
    if [ "$key" = $'\x1b' ]; then
        # Save current stty state and switch to non-blocking with 100ms window.
        # Use ONE dd call (bs=10) instead of a loop of bs=1 forks: fewer subshells,
        # no race between fork overhead and byte delivery.
        local previous_stty
        previous_stty=$(stty -g)
        stty -icanon min 0 time 1 2>/dev/null
        local seq
        seq=$(dd bs=10 count=1 2>/dev/null)
        stty "$previous_stty" 2>/dev/null
        key="${key}${seq}"
    fi
    printf "%s" "$key"
}

# Optimized version of read_key that assumes stty is already set to raw mode.
# This avoids the overhead of calling stty twice per keypress.
read_key_raw() {
    local key=""
    # 1. Read first char (blocking 1 char, min 1 time 0)
    if ! read -rsn1 key; then return 1; fi

    # 2. Check for ESC sequence
    if [ "$key" = $'\x1b' ]; then
        # Read the remainder of the escape sequence with ONE dd call (up to 10 bytes).
        # Using time 1 (100ms window) with min 0: dd returns immediately once bytes
        # are available (arrow keys deliver [A within ~1ms on local terminals), and
        # waits at most 100ms if nothing arrives (pure ESC press).
        # One fork instead of 5 serial forks avoids the race condition where
        # fork overhead (~5-20ms) caused [A to be missed at time 0.
        stty min 0 time 1 2>/dev/null
        local seq
        seq=$(dd bs=10 count=1 2>/dev/null)
        stty min 1 time 0 2>/dev/null
        key="${key}${seq}"
    fi
    printf "%s" "$key"
}

print_ssh_hint() {
    cat << 'EOF'
════════════════════════════════════════════════════════════════
  ⚠️  SSH Session Detected (No TTY)
════════════════════════════════════════════════════════════════
  For interactive mode, reconnect with: ssh -t user@host
  
  Example:
    ssh -t user@server.com "cd myproject && run"
    
  Or using an alias:
    alias ssh-run="ssh -t"
    ssh-run user@server "cd myproject && run"
════════════════════════════════════════════════════════════════
EOF
}

# ==============================================================================
#  I18N / MESSAGES
# ==============================================================================

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
                task_timeout) echo "Task timeout (killed)" ;;
                task_depends) echo "Running dependencies" ;;
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
                file_browser) echo "File browser" ;;
                favorites_label) echo "Favorites" ;;
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
                history_label) echo "History" ;;
                history_empty) echo "No history entries" ;;
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
                task_timeout) echo "Task Timeout (abgebrochen)" ;;
                task_depends) echo "Führe Abhängigkeiten aus" ;;
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
                file_browser) echo "Datei-Browser" ;;
                favorites_label) echo "Favoriten" ;;
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
                history_label) echo "Verlauf" ;;
                history_empty) echo "Kein Verlaufseintrag vorhanden" ;;
                *) echo "$key" ;;
            esac
            ;;
    esac
}
