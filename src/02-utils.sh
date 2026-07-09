# ==============================================================================
#  POLYFILLS & UTILS
# ==============================================================================

# Use ripgrep (rg) when available — same flags, faster on large inputs.
# Falls back to system grep transparently.
if command -v rg >/dev/null 2>&1; then
    _grep() { rg "$@"; }
else
    _grep() { grep "$@"; }
fi

get_realpath() {
    if command -v realpath &>/dev/null; then
        realpath "$1"
    elif [[ "$1" = /* ]]; then
        # Absoluter Pfad: direkt zurückgeben (macOS ohne GNU-coreutils hat kein realpath)
        echo "$1"
    else
        echo "$PWD/${1#./}"
    fi
}
cleanup_terminal() {
    if [ -n "${TPUT_CNORM:-}" ]; then
        echo -ne "$TPUT_CNORM"
    else
        tput cnorm 2>/dev/null || true
    fi
    echo -e "${COLOR_RESET}";
}
handle_interrupt() { cleanup_terminal; clear; exit 130; }
trap cleanup_terminal EXIT
trap handle_interrupt INT TERM
hide_cursor() {
    if [ -n "${TPUT_CIVIS:-}" ]; then
        echo -ne "$TPUT_CIVIS"
    else
        tput civis 2>/dev/null || true
    fi
}

# Color output helpers
info() { echo -e "${COLOR_INFO}$*${COLOR_RESET}"; }
warn() { echo -e "${COLOR_WARN}$*${COLOR_RESET}"; }
error() { echo -e "${COLOR_ERR}$*${COLOR_RESET}"; }
success() { echo -e "${COLOR_SEL}✔ $*${COLOR_RESET}"; }
dim() { echo -e "${COLOR_DIM}$*${COLOR_RESET}"; }

sanitize_filename() { sed 's/ /_/g; s/[^A-Za-z0-9._-]//g' <<< "$1"; }

# Kürzt eine Datei auf maximal $2 Zeilen (via tail).
# Wird von add_to_history, add_to_recent und save_search_term genutzt.
trim_file_to_lines() {
    local file="$1" max="$2"
    [ -f "$file" ] || return 0
    local lines
    lines=$(wc -l < "$file" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$max" ]; then
        tail -n "$max" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file" || true
    fi
}

trim_whitespace() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf "%s" "$s"
}

# Cross-platform file mtime (optimization: check method once)
get_file_mtime() {
    local file="$1"
    if [ -z "${_STAT_CMD:-}" ]; then
        if stat -f %m "$0" >/dev/null 2>&1; then
            _STAT_CMD="stat -f %m"
        else
            _STAT_CMD="stat -c %Y"
        fi
    fi
    $_STAT_CMD "$file" 2>/dev/null || echo 0
}

copy_to_clipboard() {
    local text="$1"
    if command -v pbcopy &>/dev/null; then
        echo -n "$text" | pbcopy && success "Copied to clipboard (pbcopy)"
    elif command -v xclip &>/dev/null; then
        echo -n "$text" | xclip -selection clipboard && success "Copied to clipboard (xclip)"
    elif command -v xsel &>/dev/null; then
        echo -n "$text" | xsel --clipboard && success "Copied to clipboard (xsel)"
    elif command -v wl-copy &>/dev/null; then
        echo -n "$text" | wl-copy && success "Copied to clipboard (wl-copy)"
    else
        warn "No clipboard tool available (pbcopy/xclip/xsel)"
    fi
}

validate_filename() {
    local fn="$1"

    # Reject empty names
    [ -z "$fn" ] && return 1

    # Reject dangerous paths
    [[ "$fn" =~ \.\. ]] && return 1      # Parent directory
    [[ "$fn" = *'/'* ]] && return 1      # Absolute/relative paths
    [[ "$fn" = *"\${"* ]] && return 1    # Variable expansion
    [[ "$fn" = *'`'* ]] && return 1      # Command substitution
    [[ "$fn" = *'|'* ]] && return 1      # Pipes
    [[ "$fn" = *';'* ]] && return 1      # Command separators
    [[ "$fn" = *'&'* ]] && return 1      # Background operators
    [[ "$fn" = *'>'* ]] && return 1      # Redirection
    [[ "$fn" = *'<'* ]] && return 1      # Redirection

    # Allow: alphanumeric, dots, dashes, underscores, plus common extensions
    [[ "$fn" =~ ^[a-zA-Z0-9._-]+$ ]] && return 0

    return 1
}
