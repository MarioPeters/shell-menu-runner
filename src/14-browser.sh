# ==============================================================================
#  FILE BROWSER
# ==============================================================================

file_browser() {
    while true; do
        clear
        echo -e "${COLOR_HEAD}File Browser${COLOR_RESET}"
        echo -e "${COLOR_DIM}Current directory: $PWD${COLOR_RESET}"
        echo ""
        
        # Priority files
        local -a priority_files=(".tasks" ".env" "README.md" "package.json" "docker-compose.yml")
        local found_priority=0
        
        echo -e "${COLOR_INFO}Priority Files:${COLOR_RESET}"
        for pf in "${priority_files[@]}"; do
            if [ -f "$pf" ]; then
                echo "  - $pf"
                found_priority=1
            fi
        done
        
        [ "$found_priority" -eq 0 ] && echo -e "${COLOR_DIM}  (none)${COLOR_RESET}"
        
        echo ""
        echo "1) Create new file"
        echo "2) Edit .tasks"
        echo "3) Edit .env"
        echo "4) Browse all files"
        echo "0) Back"
        echo ""
        choice=$(read_key) || break
        
        case "$choice" in
            "1")
                clear
                echo -e "${COLOR_HEAD}Create New File${COLOR_RESET}"
                echo -e "${COLOR_INFO}Enter filename:${COLOR_RESET}"
                read -r filename
                
                if [ -z "$filename" ]; then
                    echo -e "${COLOR_ERR}Filename cannot be empty!${COLOR_RESET}"
                    sleep 1
                    continue
                fi
                
                if ! validate_filename "$filename"; then
                    echo -e "${COLOR_ERR}Invalid filename!${COLOR_RESET}"
                    sleep 1
                    continue
                fi
                
                local filepath="$PWD/$filename"
                if [ -f "$filepath" ]; then
                    echo -e "${COLOR_ERR}File already exists!${COLOR_RESET}"
                    sleep 2
                    continue
                fi
                
                echo -e "${COLOR_INFO}Choose creation method:${COLOR_RESET}"
                echo "1) Open in editor"
                echo "2) Paste content"
                method=$(read_key) || continue
                
                case "$method" in
                    "1")
                        ${EDITOR:-nano} "$filepath"
                        stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin
                        ;;
                    "2")
                        echo -e "${COLOR_INFO}Paste content (Ctrl+D to save):${COLOR_RESET}"
                        cat > "$filepath"
                        echo -e "${COLOR_SEL}✔ File created: $filename${COLOR_RESET}"
                        sleep 1
                        ;;
                esac
                ;;
            "2")
                [ -f ".tasks" ] && ${EDITOR:-nano} ".tasks" || echo -e "${COLOR_ERR}.tasks not found${COLOR_RESET}"
                stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin
                ;;
            "3")
                if [ -f ".env" ]; then
                    ${EDITOR:-nano} ".env"                    stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin                else
                    echo -e "\n${COLOR_INFO}Create .env? [y/N]${COLOR_RESET} "
                    read -n 1 -r REPLY
                    echo ""
                    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                        touch ".env"
                        ${EDITOR:-nano} ".env"
                    fi
                fi
                ;;
            "4")
                local -a all_files=()
                IFS=$'\n' read -r -d '' -a all_files < <(find . -maxdepth 2 -type f ! -path '*/\.*' 2>/dev/null && printf '\0') || true
                if [ ${#all_files[@]} -eq 0 ]; then
                    echo -e "${COLOR_DIM}No files found${COLOR_RESET}"
                    sleep 1
                else
                    clear
                    echo -e "${COLOR_HEAD}Files:${COLOR_RESET}"
                    local idx=1
                    for f in "${all_files[@]}"; do
                        [ "$idx" -le 9 ] && echo "$idx) $f"
                        idx=$((idx + 1))
                    done
                    echo -e "\n[1-9] Edit [q]uit"
                    fkey=$(read_key) || break
                    if [[ "$fkey" =~ [1-9] ]]; then
                        local fsel=$((fkey - 1))
                        if [ "$fsel" -lt "${#all_files[@]}" ]; then
                            ${EDITOR:-nano} "${all_files[$fsel]}"
                            stty sane 2>/dev/null || true; stty -echo 2>/dev/null || true; drain_stdin
                        fi
                    fi
                fi
                ;;
            "0"|$'\x1b')
                break
                ;;
        esac
    done
}
