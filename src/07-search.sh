# ==============================================================================
#  SEARCH & FILTER SYSTEM
# ==============================================================================

SEARCH_HISTORY_FILE="$HOME/.run_search_history"
SEARCH_HISTORY_MAX=20

save_search_term() {
    local term="$1"
    [ -z "$term" ] && return
    
    # Remove duplicates and add to top
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
        grep -v "^${term}$" "$SEARCH_HISTORY_FILE" > "${SEARCH_HISTORY_FILE}.tmp" 2>/dev/null || true
        mv "${SEARCH_HISTORY_FILE}.tmp" "$SEARCH_HISTORY_FILE" || true
    fi
    
    echo "$term" >> "$SEARCH_HISTORY_FILE"
    
    # Keep only last N entries
    if tail -n "$SEARCH_HISTORY_MAX" "$SEARCH_HISTORY_FILE" > "${SEARCH_HISTORY_FILE}.tmp"; then
        mv "${SEARCH_HISTORY_FILE}.tmp" "$SEARCH_HISTORY_FILE"
    fi
}

get_search_history() {
    if [ -f "$SEARCH_HISTORY_FILE" ]; then
        tac "$SEARCH_HISTORY_FILE" 2>/dev/null || tail -r "$SEARCH_HISTORY_FILE" 2>/dev/null || true
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
        read -rsn1 char
        case "$char" in
            $'\x7f'|$'\x08')  # Backspace
                if [ -n "$current_query" ]; then
                    current_query="${current_query%?}"
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                fi
                ;;
            $'\x1b')  # ESC or Arrow keys
                read -rsn2 -t 0.1 arrow 2>/dev/null || arrow=""
                if [ -z "$arrow" ]; then
                    # Pure ESC - cancel
                    filter_query=""
                    return 1
                elif [ "$arrow" = "[A" ] && [ ${#history_items[@]} -gt 0 ]; then
                    # Arrow Up - previous history
                    ((history_pos++))
                    [ "$history_pos" -ge ${#history_items[@]} ] && history_pos=$((${#history_items[@]} - 1))
                    current_query="${history_items[$history_pos]}"
                    echo -ne "\r\033[K"
                    echo -n "Search: ${current_query}"
                elif [ "$arrow" = "[B" ] && [ "$history_pos" -gt 0 ]; then
                    # Arrow Down - next history
                    ((history_pos--))
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
