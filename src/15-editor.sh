# ==============================================================================
#  CONFIG EDITOR
# ==============================================================================

edit_config_menu() {
    local file="${1:-$config_path}"
    
    while true; do
        clear
        echo -e "${COLOR_HEAD}Config Editor${COLOR_RESET}"
        echo -e "${COLOR_DIM}File: $file${COLOR_RESET}"
        echo ""
        echo "1) Open in Editor (${EDITOR:-nano})"
        echo "2) Replace entire content (paste mode)"
        echo "3) View file"
        echo "0) Back"
        echo ""
        read -rsn1 choice
        
        case "$choice" in
            "1")
                ${EDITOR:-nano} "$file"
                ;;
            "2")
                clear
                echo -e "${COLOR_HEAD}Replace File Content${COLOR_RESET}"
                echo -e "${COLOR_INFO}Paste your content below, then press Ctrl+D (or Ctrl+Z on Windows)${COLOR_RESET}"
                echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                
                # Create temp file
                local tmp_file
                tmp_file=$(mktemp)
                cat > "$tmp_file"
                
                # Show preview
                echo ""
                echo -e "${COLOR_WARN}Preview (first 10 lines):${COLOR_RESET}"
                head -10 "$tmp_file"
                echo ""
                read -p "Replace $file with this content? [y/N] " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    mv "$tmp_file" "$file"
                    echo -e "${COLOR_SEL}✔ File updated!${COLOR_RESET}"
                else
                    rm "$tmp_file"
                    echo -e "${COLOR_INFO}Cancelled.${COLOR_RESET}"
                fi
                sleep 1
                ;;
            "3")
                clear
                echo -e "${COLOR_HEAD}Current content:${COLOR_RESET}"
                echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                cat "$file"
                echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
                echo ""
                echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
                read -n1 -rs
                ;;
            "0"|$'\x1b')
                break
                ;;
        esac
    done
}

show_alias_editor() {
    clear
    echo -e "${COLOR_HEAD}Alias Manager${COLOR_RESET}"
    
    if [ ! -f "$ALIAS_FILE" ] || [ ! -s "$ALIAS_FILE" ]; then
        echo -e "${COLOR_DIM}No aliases defined yet.${COLOR_RESET}"
        echo -e "${COLOR_INFO}Create alias file? [y/N]${COLOR_RESET}"
        read -n1 -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cat > "$ALIAS_FILE" << 'EOF'
# Task Aliases
# Format: alias_name=actual_task_name
# Example:
# build=npm run build
# test=npm test
EOF
            ${EDITOR:-nano} "$ALIAS_FILE"
        fi
    else
        echo -e "${COLOR_DIM}Current aliases:${COLOR_RESET}"
        grep -v "^#" "$ALIAS_FILE" | grep -v "^$"
        echo ""
        echo "1) Edit aliases"
        echo "2) Add new alias"
        echo "0) Back"
        read -rsn1 choice
        
        case "$choice" in
            "1")
                ${EDITOR:-nano} "$ALIAS_FILE"
                ;;
            "2")
                echo -e "\n${COLOR_INFO}Alias name:${COLOR_RESET}"
                read -r alias_name
                echo -e "${COLOR_INFO}Task name:${COLOR_RESET}"
                read -r task_name
                echo "${alias_name}=${task_name}" >> "$ALIAS_FILE"
                echo -e "${COLOR_SEL}✔ Alias added!${COLOR_RESET}"
                sleep 1
                ;;
        esac
    fi
    
    echo -e "\n${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    read -n1 -rs
}

load_aliases() {
    # Create alias file if not exists
    if [ ! -f "$ALIAS_FILE" ]; then
        touch "$ALIAS_FILE"
    fi
}

resolve_alias() {
    local input="$1"
    if [ -f "$ALIAS_FILE" ]; then
        local resolved
        resolved=$(grep "^${input}=" "$ALIAS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$resolved" ]; then
            echo "$resolved"
            return 0
        fi
    fi
    echo "$input"
}

settings_menu() {
    while true; do
        clear
        echo -e "${COLOR_HEAD}Settings${COLOR_RESET}"
        echo ""
        echo "Current Settings:"
        echo -e "  Theme:       ${COLOR_SEL}$UI_THEME${COLOR_RESET}"
        echo -e "  Language:    ${COLOR_SEL}$UI_LANG${COLOR_RESET}"
        echo -e "  Columns:     ${COLOR_SEL}$COLS_MIN-$COLS_MAX${COLOR_RESET}"
        echo ""
        echo "1) Change Theme"
        echo "2) Change Language"
        echo "3) Change Column Layout"
        echo "4) Save Globally"
        echo "5) Save Locally"
        echo "0) Back"
        echo ""
        read -rsn1 choice
        
        case "$choice" in
            "1")
                echo -e "\n${COLOR_INFO}Select Theme:${COLOR_RESET}"
                echo "1) CYBER"
                echo "2) MONO"
                echo "3) DARK"
                echo "4) LIGHT"
                read -rsn1 theme_choice
                case "$theme_choice" in
                    "1") UI_THEME="CYBER";;
                    "2") UI_THEME="MONO";;
                    "3") UI_THEME="DARK";;
                    "4") UI_THEME="LIGHT";;
                esac
                apply_theme
                ;;
            "2")
                echo -e "\n${COLOR_INFO}Select Language:${COLOR_RESET}"
                echo "1) EN (English)"
                echo "2) DE (Deutsch)"
                read -rsn1 lang_choice
                case "$lang_choice" in
                    "1") UI_LANG="EN";;
                    "2") UI_LANG="DE";;
                esac
                ;;
            "3")
                echo -e "\n${COLOR_INFO}Column Layout (1-4):${COLOR_RESET}"
                read -n1 col_val
                if [[ "$col_val" =~ [1-4] ]]; then
                    COLS_MIN="$col_val"
                    COLS_MAX="$col_val"
                fi
                ;;
            "4")
                save_settings "global"
                echo -e "\n${COLOR_SEL}✔ Saved globally${COLOR_RESET}"
                sleep 1
                ;;
            "5")
                save_settings "local"
                echo -e "\n${COLOR_SEL}✔ Saved locally${COLOR_RESET}"
                sleep 1
                ;;
            "0"|$'\x1b')
                break
                ;;
        esac
    done
}
