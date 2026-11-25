# ==============================================================================
#  TERMINAL & SSH DETECTION
# ==============================================================================

# Context indicator — built once at init, read by draw_menu()
_CTX_LINE=""
_CTX_LINE_PLAIN=""
_CTX_BRANCH=""
_CTX_HOST=""
_CTX_ENV=""
_LAST_COL_WIDTH=0

# Border string cache — rebuilt when col_width changes (WINCH trap resets _LAST_COL_WIDTH)
# shellcheck disable=SC2034
_BORDER_TOP=""
# shellcheck disable=SC2034
_BORDER_BOT=""

# Terminal capabilities — defaults for the non-interactive path (SSH without
# -t, pipes, cron).  init_terminal_capabilities() overwrites them when a real
# terminal is available; without these defaults the script would abort with
# "unbound variable" as soon as set -u is active.
HAS_TPUT=0
TPUT_CUP=""
TPUT_CIVIS=""
TPUT_CNORM=""
TPUT_ED=""
TPUT_COLS=80
TPUT_LINES=24

# ==============================================================================
#  TERMINAL STATE SNAPSHOT
# ==============================================================================
# The current terminal settings (stty -g) are captured once before the menu
# switches to raw mode and restored after external programs (editors) have run.
# `stty sane` would override the user's own settings and the combination
# `stty sane; stty -echo; drain_stdin` left the shell in `-icanon` mode
# without echo — every following `read` was blind and without line editing.
_SAVED_STTY=""

save_terminal_state() {
    [ -n "$_SAVED_STTY" ] && return 0
    _SAVED_STTY=$(stty -g 2>/dev/null || true)
    return 0
}

restore_terminal_state() {
    if [ -n "$_SAVED_STTY" ]; then
        stty "$_SAVED_STTY" 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi
    return 0
}

# Restores the terminal settings of the menu.
#
# Module level (not inside main_interactive_loop): the INT trap installed by
# execute_task also runs in CLI mode (--run), where the interactive loop was
# never entered — a locally defined function would not exist there and the
# trap would fail with "restore_term: command not found".
restore_term() {
    restore_terminal_state
}

check_interactive() {
    # Check if stdin is a TTY (interactive session)
    if [ -t 0 ]; then
        is_interactive=1
        # Snapshot the user's terminal settings before anything changes them
        save_terminal_state
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
    _CTX_LINE=""; _CTX_LINE_PLAIN=""; _CTX_BRANCH=""; _CTX_HOST=""; _CTX_ENV=""
    local show="${CONTEXT_SHOW:-git,hostname,env}"
    local parts=()
    local plain_parts=()

    # Git branch — subprocess is acceptable at init (not in render loop)
    if [[ "$show" == *"git"* ]]; then
        _CTX_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        [ -n "$_CTX_BRANCH" ] && parts+=("${COLOR_INFO}⎇ ${_CTX_BRANCH}${COLOR_RESET}")
        [ -n "$_CTX_BRANCH" ] && plain_parts+=("⎇ ${_CTX_BRANCH}")
    fi

    # Hostname — only on SSH sessions
    if [[ "$show" == *"hostname"* ]]; then
        if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
            _CTX_HOST="${HOSTNAME:-$(hostname 2>/dev/null || true)}"
            [ -n "$_CTX_HOST" ] && parts+=("${COLOR_ERR}⚡ ${_CTX_HOST}${COLOR_RESET}")
            [ -n "$_CTX_HOST" ] && plain_parts+=("⚡ ${_CTX_HOST}")
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
                development|dev) env_color="$COLOR_INFO" ;;
                *)               env_color="$COLOR_DIM"  ;;
            esac
            parts+=("${env_color}${env_upper}${COLOR_RESET}")
            plain_parts+=("${env_upper}")
        fi
    fi

    # Join parts with " · " separator — pure Bash, no subshell
    if [ "${#parts[@]}" -gt 0 ]; then
        local line="${parts[0]}"
        local plain="${plain_parts[0]}"
        local i
        for (( i=1; i<${#parts[@]}; i++ )); do
            line+="${COLOR_DIM} · ${COLOR_RESET}${parts[$i]}"
            plain+=" · ${plain_parts[$i]}"
        done
        _CTX_LINE="$line"
        _CTX_LINE_PLAIN="$plain"
    fi
}

build_border_strings() {
    local col_width="$1"
    local inner=$(( col_width - 4 ))
    [ "$inner" -lt 1 ] && inner=1

    # Build dash string with pure Bash loop — no subshell, no seq
    local dashes="" i
    for (( i=0; i<inner; i++ )); do dashes+='─'; done

    _BORDER_TOP="┌${dashes}┐"
    _BORDER_BOT="└${dashes}┘"
    _LAST_COL_WIDTH="$col_width"
}

# ==============================================================================
#  UTF-8 DISPLAY WIDTH
# ==============================================================================
# Terminals count columns, not bytes or characters: CJK glyphs and emoji occupy
# two columns, combining marks none.  The helpers below decode UTF-8 byte-wise
# (locale independent, Bash 3.2 compatible) and return the real column count.
# Without this the menu boxes wrap or misalign as soon as a task name contains
# non-ASCII text.

# Decoder state — shared via globals (Bash 3.2 has no namerefs).
_U8_STR=""
_U8_POS=0
_U8_CP=0
_U8_LEN=0
_U8_WIDTH=0

# Result variables of the public helpers
DISPLAY_WIDTH=0
FIT_TEXT=""

# Cached column widths of the constant menu footer hints.
#
# The UTF-8 decoder needs ~4 ms for a non-ASCII string (one printf per
# byte) — measuring the same constant text again and again was the single
# biggest cost of a menu redraw.  Both variants are cached together: a
# cache with only one slot would miss on every call, because the two texts
# are measured alternately.
_HINT_MID_WIDTH=0
_HINT_FULL_WIDTH=0
_HINT_WIDTHS_KEY=""

# Sets _U8_WIDTH to the number of terminal columns used by a code point.
_u8_width() {
    local _cp="$1"
    _U8_WIDTH=1

    # ── Zero width: control characters and combining marks ─────────
    if [ "$_cp" -lt 32 ] \
       || { [ "$_cp" -ge 127 ] && [ "$_cp" -lt 160 ]; } \
       || { [ "$_cp" -ge 768 ] && [ "$_cp" -le 879 ]; } \
       || { [ "$_cp" -ge 1425 ] && [ "$_cp" -le 1479 ]; } \
       || { [ "$_cp" -ge 1536 ] && [ "$_cp" -le 1791 ]; } \
       || { [ "$_cp" -ge 1872 ] && [ "$_cp" -le 1919 ]; } \
       || { [ "$_cp" -ge 8202 ] && [ "$_cp" -le 8207 ]; } \
       || { [ "$_cp" -ge 8208 ] && [ "$_cp" -le 8231 ]; } \
       || { [ "$_cp" -ge 8240 ] && [ "$_cp" -le 8247 ]; } \
       || { [ "$_cp" -ge 8288 ] && [ "$_cp" -le 8299 ]; } \
       || { [ "$_cp" -ge 8400 ] && [ "$_cp" -le 8432 ]; } \
       || { [ "$_cp" -ge 8450 ] && [ "$_cp" -le 8531 ]; } \
       || { [ "$_cp" -ge 65024 ] && [ "$_cp" -le 65039 ]; } \
       || [ "$_cp" -eq 65279 ]; then
        _U8_WIDTH=0
        return 0
    fi

    # ── Wide: CJK, fullwidth forms and emoji ──────────────────────
    if { [ "$_cp" -ge 4352 ] && [ "$_cp" -le 4447 ]; } \
       || { [ "$_cp" -ge 11904 ] && [ "$_cp" -le 12350 ]; } \
       || { [ "$_cp" -ge 12352 ] && [ "$_cp" -le 13311 ]; } \
       || { [ "$_cp" -ge 13312 ] && [ "$_cp" -le 19903 ]; } \
       || { [ "$_cp" -ge 19968 ] && [ "$_cp" -le 40959 ]; } \
       || { [ "$_cp" -ge 40960 ] && [ "$_cp" -le 42191 ]; } \
       || { [ "$_cp" -ge 43360 ] && [ "$_cp" -le 43455 ]; } \
       || { [ "$_cp" -ge 44032 ] && [ "$_cp" -le 55203 ]; } \
       || { [ "$_cp" -ge 63744 ] && [ "$_cp" -le 64255 ]; } \
       || { [ "$_cp" -ge 65008 ] && [ "$_cp" -le 65023 ]; } \
       || { [ "$_cp" -ge 65040 ] && [ "$_cp" -le 65135 ]; } \
       || { [ "$_cp" -ge 65280 ] && [ "$_cp" -le 65376 ]; } \
       || { [ "$_cp" -ge 65504 ] && [ "$_cp" -le 65510 ]; } \
       || { [ "$_cp" -ge 127744 ] && [ "$_cp" -le 128591 ]; } \
       || { [ "$_cp" -ge 128640 ] && [ "$_cp" -le 128711 ]; } \
       || { [ "$_cp" -ge 128768 ] && [ "$_cp" -le 130303 ]; } \
       || { [ "$_cp" -ge 128992 ] && [ "$_cp" -le 129003 ]; } \
       || { [ "$_cp" -ge 131072 ] && [ "$_cp" -le 262143 ]; }; then
        _U8_WIDTH=2
        return 0
    fi

    return 0
}

# Decodes the UTF-8 sequence at byte position _U8_POS of _U8_STR.
# Result: _U8_CP (code point), _U8_LEN (bytes), _U8_WIDTH (columns).
_u8_decode() {
    local _b1 _b2 _b3 _b4 _v _rest

    printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
    _b1=$_v
    [ "$_b1" -lt 0 ] && _b1=$(( _b1 + 256 ))

    if [ "$_b1" -lt 128 ]; then
        _U8_CP=$_b1
        _U8_LEN=1
    elif [ "$_b1" -lt 224 ]; then
        _rest=$(( ${#_U8_STR} - _U8_POS ))
        if [ "$_rest" -lt 2 ]; then _U8_CP=$_b1; _U8_LEN=1; _u8_width "$_U8_CP"; return 0; fi
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b2=$_v; [ "$_b2" -lt 0 ] && _b2=$(( _b2 + 256 ))
        _U8_CP=$(( ((_b1 & 31) << 6) | (_b2 & 63) ))
        _U8_LEN=2
    elif [ "$_b1" -lt 240 ]; then
        _rest=$(( ${#_U8_STR} - _U8_POS ))
        if [ "$_rest" -lt 3 ]; then _U8_CP=$_b1; _U8_LEN=1; _u8_width "$_U8_CP"; return 0; fi
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b2=$_v; [ "$_b2" -lt 0 ] && _b2=$(( _b2 + 256 ))
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b3=$_v; [ "$_b3" -lt 0 ] && _b3=$(( _b3 + 256 ))
        _U8_CP=$(( ((_b1 & 15) << 12) | ((_b2 & 63) << 6) | (_b3 & 63) ))
        _U8_LEN=3
    else
        _rest=$(( ${#_U8_STR} - _U8_POS ))
        if [ "$_rest" -lt 4 ]; then _U8_CP=$_b1; _U8_LEN=1; _u8_width "$_U8_CP"; return 0; fi
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b2=$_v; [ "$_b2" -lt 0 ] && _b2=$(( _b2 + 256 ))
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b3=$_v; [ "$_b3" -lt 0 ] && _b3=$(( _b3 + 256 ))
        _U8_POS=$(( _U8_POS + 1 ))
        printf -v _v '%d' "'${_U8_STR:_U8_POS:1}"
        _b4=$_v; [ "$_b4" -lt 0 ] && _b4=$(( _b4 + 256 ))
        _U8_CP=$(( ((_b1 & 7) << 18) | ((_b2 & 63) << 12) | ((_b3 & 63) << 6) | (_b4 & 63) ))
        _U8_LEN=4
    fi

    _u8_width "$_U8_CP"
    return 0
}

# Sets DISPLAY_WIDTH to the number of terminal columns of the given string.
display_width() {
    local _s="$1"
    local _w=0 _i=0 _len _lc_saved="" _lc_was_set=0

    # Fast path: pure ASCII → one column per character
    case "$_s" in
        *[![:ascii:]]*) ;;
        *) DISPLAY_WIDTH=${#_s}; return 0 ;;
    esac

    # Byte-wise decoding: LC_ALL=C makes ${#str} and ${str:i:n} byte based
    [ -n "${LC_ALL+x}" ] && { _lc_was_set=1; _lc_saved="$LC_ALL"; }
    LC_ALL=C

    _U8_STR="$_s"
    _len=${#_U8_STR}
    while [ "$_i" -lt "$_len" ]; do
        _U8_POS=$_i
        _u8_decode
        _w=$(( _w + _U8_WIDTH ))
        _i=$(( _i + _U8_LEN ))
    done

    if [ "$_lc_was_set" -eq 1 ]; then LC_ALL="$_lc_saved"; else unset LC_ALL; fi

    DISPLAY_WIDTH=$_w
    return 0
}

# Pads or truncates a string to exactly the given number of terminal columns.
# Result: FIT_TEXT.  Truncation never splits a UTF-8 character and appends
# an ellipsis so the column width stays stable.
fit_to_width() {
    local _s="$1" _max="$2"
    local _w=0 _i=0 _len _out="" _truncated=0 _limit _pad _spaces="" _lc_saved="" _lc_was_set=0

    FIT_TEXT=""
    [ "$_max" -lt 1 ] && return 0

    # Fast path: pure ASCII
    case "$_s" in
        *[![:ascii:]]*) ;;
        *)
            if [ "${#_s}" -le "$_max" ]; then
                printf -v _spaces '%*s' "$(( _max - ${#_s} ))" ''
                FIT_TEXT="${_s}${_spaces}"
            else
                printf -v FIT_TEXT '%s...' "${_s:0:$(( _max > 3 ? _max - 3 : 1 ))}"
            fi
            return 0
            ;;
    esac

    # Byte-wise decoding: LC_ALL=C makes ${#str} and ${str:i:n} byte based
    [ -n "${LC_ALL+x}" ] && { _lc_was_set=1; _lc_saved="$LC_ALL"; }
    LC_ALL=C

    _U8_STR="$_s"
    _len=${#_U8_STR}

    # First pass: does the text fit?
    while [ "$_i" -lt "$_len" ]; do
        _U8_POS=$_i
        _u8_decode
        if [ $(( _w + _U8_WIDTH )) -gt "$_max" ]; then
            _truncated=1
            break
        fi
        _w=$(( _w + _U8_WIDTH ))
        _i=$(( _i + _U8_LEN ))
    done

    if [ "$_truncated" -eq 0 ]; then
        _pad=$(( _max - _w ))
        [ "$_pad" -gt 0 ] && printf -v _spaces '%*s' "$_pad" ''
        if [ "$_lc_was_set" -eq 1 ]; then LC_ALL="$_lc_saved"; else unset LC_ALL; fi
        FIT_TEXT="${_s}${_spaces}"
        return 0
    fi

    # Second pass: cut at the column limit, reserve 3 columns for the ellipsis
    _limit=$(( _max - 3 ))
    [ "$_limit" -lt 1 ] && _limit=1
    _w=0
    _i=0
    _out=""
    while [ "$_i" -lt "$_len" ]; do
        local _start=$_i
        _U8_POS=$_i
        _u8_decode
        if [ $(( _w + _U8_WIDTH )) -gt "$_limit" ]; then
            break
        fi
        # _U8_POS was advanced by the decoder — cut at the original offset
        _out="${_out}${_U8_STR:_start:_U8_LEN}"
        _w=$(( _w + _U8_WIDTH ))
        _i=$(( _i + _U8_LEN ))
    done

    _out="${_out}..."
    _w=$(( _w + 3 ))
    _pad=$(( _max - _w ))
    [ "$_pad" -gt 0 ] && printf -v _spaces '%*s' "$_pad" ''
    if [ "$_lc_was_set" -eq 1 ]; then LC_ALL="$_lc_saved"; else unset LC_ALL; fi
    FIT_TEXT="${_out}${_spaces}"
    return 0
}

# Horizontal rule that always fits into the current terminal width.
# Usage: separator_line [max_width]
separator_line() {
    local _max="${1:-63}"
    local _width="${TPUT_COLS:-80}"
    local _len _i _out=""

    [ "$_width" -gt "$_max" ] && _width=$_max
    [ "$_width" -lt 10 ] && _width=10

    # ── characters ────────────────────────────────────────────────
    for (( _i=0; _i<_width; _i++ )); do _out+='─'; done
    printf "%s" "$_out"
}

# Optimized terminal capability caching
_TPUT_INITIALIZED=0
init_terminal_capabilities() {
    # Only run once — guard auf dediziertes Flag statt TPUT_COLS (könnte leer sein wenn tput cols versagt)
    [ "${_TPUT_INITIALIZED:-0}" -eq 1 ] && return
    _TPUT_INITIALIZED=1

    if command -v tput >/dev/null 2>&1; then
        # Every tput call must tolerate a failure: with "set -e" an assignment
        # whose command substitution fails aborts the whole script.  This
        # happens with TERM=dumb, an unknown TERM or a broken terminfo
        # database — the tool was completely unusable in those cases.
        TPUT_CUP="$(tput cup 0 0 2>/dev/null || true)"
        TPUT_CIVIS="$(tput civis 2>/dev/null || true)"
        TPUT_CNORM="$(tput cnorm 2>/dev/null || true)"
        TPUT_ED="$(tput ed 2>/dev/null || true)"
        TPUT_COLS="$(tput cols 2>/dev/null || true)"
        TPUT_LINES="$(tput lines 2>/dev/null || true)"
        HAS_TPUT=1
    else
        HAS_TPUT=0
        TPUT_COLS=80
        TPUT_LINES=24
    fi
    # Fallbacks for terminfo entries that do not exist (dumb terminals)
    is_uint "${TPUT_COLS:-}" && [ "${TPUT_COLS:-0}" -ge 1 ] || TPUT_COLS=80
    is_uint "${TPUT_LINES:-}" && [ "${TPUT_LINES:-0}" -ge 1 ] || TPUT_LINES=24

    # Update cols/lines on resize, reset border cache
    trap 'TPUT_COLS=$(tput cols 2>/dev/null || echo 80); TPUT_LINES=$(tput lines 2>/dev/null || echo 24); _LAST_COL_WIDTH=0' WINCH

    # Context indicator (git branch, hostname, env)
    init_context
}

consume_keypress() {
    # Suppress echo so arrow keys / escape sequences are not printed to the
    # terminal while waiting for the keypress (e.g. after stty sane in execute_task).
    # Every stty call tolerates a missing TTY — otherwise `set -e` would abort
    # the script in a pipe/SSH-without-TTY session.
    stty -echo 2>/dev/null || true
    read_key >/dev/null || true
    # Drain any remaining bytes from multi-byte escape sequences (e.g. arrow keys
    # send \x1b[A; read_key already consumed the full sequence, but defensive
    # drain prevents leftover bytes leaking into the main loop's key handler).
    drain_stdin
    stty echo 2>/dev/null || true
}

# Enable raw interactive input mode for the main loop.
# Flags: no echo, no canonical buffering, pass signals, block until 1 char min.
# NOTE: icrnl is intentionally left ON so Enter (\r→\n) is stripped by $()
# to "". Spurious "" from a failed read_key_raw is blocked by the _rk_status
# guard in the main loop (13-ui.sh), not by changing icrnl.
set_raw_mode() {
    stty -echo -icanon time 0 min 1 isig 2>/dev/null || true
}

drain_stdin() {
    # Only a terminal can have buffered bytes — on a pipe head would block
    # until the writer closes the pipe (hang).
    [ -t 0 ] || return 0
    # Non-blocking drain of any pending stdin bytes (e.g. escape sequence tails
    # or task output left in the buffer). Explicitly disables icanon so this
    # works regardless of the current terminal mode (e.g. after stty sane).
    # head -c reads everything that is available with a single fork instead of
    # one dd fork per 128 byte block.
    stty -icanon min 0 time 0 2>/dev/null || true
    head -c 4096 >/dev/null 2>&1 || true
    stty min 1 time 0 2>/dev/null || true
    return 0
}

# Re-installs the Ctrl+C handler that fits the current context: the menu loop
# needs the terminal restore, every other code path does not.
restore_int_trap() {
    if [ "${_MENU_LOOP_ACTIVE:-0}" -eq 1 ]; then
        trap 'restore_term; cleanup_wrapper; exit 130' INT TERM
    else
        trap 'cleanup_wrapper; exit 130' INT TERM
    fi
    return 0
}

# Runs an external editor on the given file and restores the terminal state.
#
# * `trap ':' INT` (handler, not ignore): bash resets a *trapped* signal to its
#   default disposition in the child process, so Ctrl+C terminates the editor
#   while the menu survives.  `trap '' INT` would be inherited by the child and
#   the editor could never be stopped.
# * The terminal settings are restored from the snapshot instead of
#   `stty sane; stty -echo` — that left the shell in `-icanon` mode without
#   echo, so the following `read` calls were blind.
run_external_editor() {
    local file="${1:-}"
    if [ -z "$file" ]; then
        error "No file to edit"
        return 0
    fi

    trap ':' INT
    ${EDITOR:-nano} "$file" || true
    restore_int_trap
    drain_stdin
    restore_terminal_state
    return 0
}

read_key() {
    local key=""
    # 1. Read first char (blocking)
    # This relies on the outer loop setting stty to blocking (min 1)
    # "IFS=" is mandatory: bash's `read` strips leading/trailing IFS
    # whitespace, so a space would arrive as an empty string and be
    # mistaken for Enter (the multi-select toggle was unreachable).
    if ! IFS= read -rsn1 key; then return 1; fi

    # 2. Check for ESC sequence
    if [ "$key" = $'\x1b' ]; then
        # Save current stty state and switch to non-blocking with 100ms window.
        # Use ONE dd call (bs=10) instead of a loop of bs=1 forks: fewer subshells,
        # no race between fork overhead and byte delivery.
        local previous_stty
        previous_stty=$(stty -g 2>/dev/null || true)
        stty -icanon min 0 time 1 2>/dev/null || true
        local seq
        seq=$(dd bs=10 count=1 2>/dev/null)
        if [ -n "$previous_stty" ]; then
            stty "$previous_stty" 2>/dev/null || true
        fi
        key="${key}${seq}"
    fi
    printf "%s" "$key"
}

# Optimized version of read_key that assumes stty is already set to raw mode.
# This avoids the overhead of calling stty twice per keypress.
read_key_raw() {
    local key=""
    # 1. Read first char (blocking 1 char, min 1 time 0)
    # "IFS=" keeps a space intact — see read_key().
    if ! IFS= read -rsn1 key; then return 1; fi

    # 2. Check for ESC sequence
    if [ "$key" = $'\x1b' ]; then
        # Read the remainder of the escape sequence with ONE dd call (up to 10 bytes).
        # Using time 1 (100ms window) with min 0: dd returns immediately once bytes
        # are available (arrow keys deliver [A within ~1ms on local terminals), and
        # waits at most 100ms if nothing arrives (pure ESC press).
        # One fork instead of 5 serial forks avoids the race condition where
        # fork overhead (~5-20ms) caused [A to be missed at time 0.
        stty min 0 time 1 2>/dev/null || true
        local seq
        seq=$(dd bs=10 count=1 2>/dev/null)
        stty min 1 time 0 2>/dev/null || true
        key="${key}${seq}"
    fi
    printf "%s" "$key"
}

# Reads a single key with a short timeout.
#
# Returns an empty string when no key arrives within the timeout.  Used by the
# tag and favorites menus for the two digit selection: a single digit selects
# immediately, a second digit (typed quickly) extends the number to 10+.
#
# Usage: read_key_optional [timeout-in-tenths-of-a-second]
read_key_optional() {
    local _key=""
    local _prev_stty
    local _timeout="${1:-2}"
    _prev_stty=$(stty -g 2>/dev/null || true)
    # -icanon is required: in canonical mode the read would block until a
    # whole line is available and the timeout would never trigger.
    stty -icanon min 0 time "$_timeout" 2>/dev/null || true
    _key=$(dd bs=1 count=1 2>/dev/null)
    if [ -n "$_prev_stty" ]; then
        stty "$_prev_stty" 2>/dev/null || true
    fi
    printf "%s" "$_key"
    return 0
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
                hash_mismatch) echo "Integrity check mismatch:" ;;
                hash_skipped) echo "Warning: sha256sum/shasum not found. Skipping check." ;;
                update_same) echo "You already have the latest version" ;;
                update_found) echo "Update found:" ;;
                install_path_missing) echo "Could not determine install path (run not in PATH)." ;;
                update_success) echo "Update successful!" ;;
                update_failed) echo "The update could not be installed." ;;
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
                task_cancelled) echo "Cancelled — the task was not executed." ;;
                task_depends) echo "Running dependencies" ;;
                press_key) echo "Press any key..." ;;
                executed_marked) echo "Executed" ;;
                marked_label) echo "marked" ;;
                recent_tasks) echo "Recent Tasks" ;;
                logs_title) echo "Recent Logs" ;;
                no_logs) echo "No log files found." ;;
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
                hash_mismatch) echo "Integritaetscheck ungueltig:" ;;
                hash_skipped) echo "Warnung: sha256sum/shasum nicht gefunden. Pruefung uebersprungen." ;;
                update_same) echo "Du nutzt bereits die neueste Version" ;;
                update_found) echo "Update gefunden:" ;;
                install_path_missing) echo "Konnte Installationspfad nicht bestimmen (run nicht im PATH)." ;;
                update_success) echo "Update erfolgreich!" ;;
                update_failed) echo "Das Update konnte nicht installiert werden." ;;
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
                task_cancelled) echo "Abgebrochen — der Task wurde nicht ausgeführt." ;;
                task_depends) echo "Führe Abhängigkeiten aus" ;;
                press_key) echo "Taste druecken..." ;;
                executed_marked) echo "Ausgefuehrt" ;;
                marked_label) echo "markiert" ;;
                recent_tasks) echo "Zuletzt ausgeführt" ;;
                logs_title) echo "Letzte Logs" ;;
                no_logs) echo "Keine Log-Dateien gefunden." ;;
                history_label) echo "Verlauf" ;;
                history_empty) echo "Kein Verlaufseintrag vorhanden" ;;
                *) echo "$key" ;;
            esac
            ;;
    esac
}
