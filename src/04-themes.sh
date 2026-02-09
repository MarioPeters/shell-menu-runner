# ==============================================================================
#  THEME SYSTEM & VISUAL EFFECTS
# ==============================================================================

apply_theme() {
    case "$UI_THEME" in
        "CYBER") 
            COLOR_HEAD=$'\e[1;36m'   # Cyan
            COLOR_SEL=$'\e[1;35m'    # Magenta
            COLOR_INFO=$'\e[1;32m'   # Bright Green
            COLOR_WARN=$'\e[1;33m'   # Bright Yellow
            COLOR_ERR=$'\e[1;31m'    # Bright Red
            COLOR_DIM=$'\e[2m'       # Dim
            ;;
        "MONO")
            COLOR_HEAD=$'\e[1;37m'   # Bright White
            COLOR_SEL=$'\e[4;37m'    # Underline White
            COLOR_INFO=$'\e[2m'      # Dim
            COLOR_WARN=$'\e[1;37m'   # Bright White
            COLOR_ERR=$'\e[1;37m'    # Bright White
            COLOR_DIM=$'\e[2m'       # Dim
            ;;
        "DARK")
            COLOR_HEAD=$'\e[1;94m'   # Bright Blue
            COLOR_SEL=$'\e[1;92m'    # Bright Green
            COLOR_INFO=$'\e[96m'     # Bright Cyan
            COLOR_WARN=$'\e[93m'     # Bright Yellow
            COLOR_ERR=$'\e[91m'      # Bright Red
            COLOR_DIM=$'\e[38;5;240m' # Gray
            ;;
        "LIGHT")
            COLOR_HEAD=$'\e[34m'     # Blue
            COLOR_SEL=$'\e[32m'      # Green
            COLOR_INFO=$'\e[36m'     # Cyan
            COLOR_WARN=$'\e[33m'     # Yellow
            COLOR_ERR=$'\e[31m'      # Red
            COLOR_DIM=$'\e[90m'      # Dark Gray
            ;;
    esac
}

# Spinner for long-running tasks
SPINNER_PID=""
SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

show_spinner() {
    local message="$1"
    local delay=0.1
    # Gecachte tput-Variable nutzen statt direktem tput-Aufruf zur Laufzeit
    if [ -n "${TPUT_CIVIS:-}" ]; then echo -ne "$TPUT_CIVIS"; else tput civis 2>/dev/null; fi
    (
        local i=0
        while true; do
            local char="${SPINNER_CHARS:$i:1}"
            printf "\r${COLOR_INFO}%s${COLOR_RESET} %s" "$char" "$message"
            i=$(( (i + 1) % ${#SPINNER_CHARS} ))
            sleep "$delay"
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        # wait returns the killed process's exit code (128+signal) which is non-zero.
        # || true prevents set -e from aborting when stop_spinner is called at the
        # top level (e.g. --across mode) where set -e is still active.
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r%80s\r" " "  # Clear spinner line
        # Gecachte tput-Variable nutzen
        if [ -n "${TPUT_CNORM:-}" ]; then echo -ne "$TPUT_CNORM"; else tput cnorm 2>/dev/null; fi
    fi
}

render_status_bar() {
    local text="$1"
    local bar_width=60
    local padding=$(( (bar_width - ${#text}) / 2 ))
    local left_pad right_pad
    # printf -v vermeidet Subshell-Overhead gegenüber $(printf ...)
    printf -v left_pad  '%*s' "$padding" ''
    printf -v right_pad '%*s' "$((bar_width - ${#text} - padding))" ''
    # Rahmen-String einmalig berechnen und global cachen (Lazy Init)
    : "${_STATUS_BAR_BORDER:=$(printf '═%.0s' {1..60})}"
    echo -e "${COLOR_DIM}╔${_STATUS_BAR_BORDER}╗${COLOR_RESET}"
    echo -e "${COLOR_DIM}║${left_pad}${COLOR_RESET}${text}${COLOR_DIM}${right_pad}║${COLOR_RESET}"
    echo -e "${COLOR_DIM}╚${_STATUS_BAR_BORDER}╝${COLOR_RESET}"
}
