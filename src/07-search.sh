# ==============================================================================
#  SEARCH & FILTER SYSTEM
# ==============================================================================

SEARCH_HISTORY_FILE="$HOME/.run_search_history"
SEARCH_HISTORY_MAX=20

save_search_term() {
    local term="$1"
    [ -z "$term" ] && return
    
    # Remove duplicates (fixed-string match, safe with regex special chars)
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
        grep -vxF "$term" "$SEARCH_HISTORY_FILE" > "${SEARCH_HISTORY_FILE}.tmp" 2>/dev/null || true
        mv "${SEARCH_HISTORY_FILE}.tmp" "$SEARCH_HISTORY_FILE" || true
    fi
    
    echo "$term" >> "$SEARCH_HISTORY_FILE"
    
    # Keep only last N entries
    trim_file_to_lines "$SEARCH_HISTORY_FILE" "$SEARCH_HISTORY_MAX"
}

get_search_history() {
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
        # tail -r ist auf macOS/BSD nativ verfügbar; tac nur mit GNU coreutils.
        # Reihenfolge: macOS-first, kein nutzloser fork für 'tac: command not found'.
        tail -r "$SEARCH_HISTORY_FILE" 2>/dev/null || tac "$SEARCH_HISTORY_FILE" 2>/dev/null || true
    fi
}

interactive_search() {
    local current_query=""
    local -a history_items=()
    IFS=$'\n' read -r -d '' -a history_items < <(get_search_history && printf '\0') || true
    local history_pos=-1
    
    clear
    echo -e "${COLOR_HEAD}Search Tasks${COLOR_RESET}"
    echo -e "${COLOR_INFO}Type to search (ESC to cancel, Enter to apply):${COLOR_RESET}"
    if [ ${#history_items[@]} -gt 0 ]; then
        echo -e "${COLOR_DIM}Recent: ${history_items[0]}${COLOR_RESET}"
    fi
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -n "Search: "
    
    while true; do
        char=$(read_key) || return 1
        case "$char" in
            $'\x7f'|$'\x08')  # Backspace
                if [ -n "$current_query" ]; then
                    current_query="${current_query%?}"
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                fi
                ;;
            $'\x1b')  # Pure ESC
                filter_query=""
                return 1
                ;;
            $'\x1b[A'|$'\x1bOA')
                if [ ${#history_items[@]} -gt 0 ]; then
                    # Arrow Up - previous history
                    history_pos=$((history_pos + 1))
                    [ "$history_pos" -ge ${#history_items[@]} ] && history_pos=$((${#history_items[@]} - 1))
                    current_query="${history_items[$history_pos]}"
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                fi
                ;;
            $'\x1b[B'|$'\x1bOB')
                if [ "$history_pos" -gt 0 ]; then
                    # Arrow Down - next history
                    history_pos=$((history_pos - 1))
                    if [ "$history_pos" -lt 0 ]; then
                        history_pos=-1
                        current_query=""
                    else
                        current_query="${history_items[$history_pos]}"
                    fi
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                fi
                ;;
            "")  # Enter
                filter_query="$current_query"
                [ -n "$filter_query" ] && save_search_term "$filter_query"
                return 0
                ;;
            *)
                if [[ "$char" =~ [[:print:]] ]]; then
                    current_query="${current_query}${char}"
                    history_pos=-1
                    echo -n "${char}"
                fi
                ;;
        esac
    done
}
