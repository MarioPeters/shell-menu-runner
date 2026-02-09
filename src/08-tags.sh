# ==============================================================================
#  TAG SYSTEM
# ==============================================================================

extract_tags() {
    local desc="$1"
    echo "$desc" | grep -o '#[a-zA-Z0-9_-]*' | tr '\n' ' '
}

has_tag() {
    local desc="$1"
    local tag="$2"
    [[ "$desc" =~ $tag ]]
}

get_all_tags() {
    local all_output=""
    if [ "${#task_config_files[@]}" -gt 0 ]; then
        all_output=$(merge_configs)
    elif [ -f "$config_path" ]; then
        all_output=$(cat "$config_path")
    fi
    
    local -a tags=()
    while IFS='|' read -r level name cmd desc; do
        local task_tags
        task_tags=$(extract_tags "$desc")
        for tag in $task_tags; do
            tags+=("$tag")
        done
    done <<< "$all_output"
    
    # Unique sort
    printf "%s\n" "${tags[@]}" | sort -u
}

show_tag_menu() {
    local -a all_tags=()
    IFS=$'\n' read -r -d '' -a all_tags < <(get_all_tags && printf '\0') || true
    local num_tags=${#all_tags[@]}
    
    if [ "$num_tags" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tags found. Add tags with #tagname in task descriptions.${COLOR_RESET}"
        sleep 1
        return
    fi
    
    clear
    echo -e "${COLOR_HEAD}🏷  Filter by Tag${COLOR_RESET}"
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    
    echo "0) ${COLOR_SEL}[All Tasks]${COLOR_RESET}"
    for (( i=0; i<num_tags; i++ )); do
        if [ "$tag_filter" == "${all_tags[$i]}" ]; then
            printf "%d) ${COLOR_SEL}✓ %s${COLOR_RESET}\n" "$((i+1))" "${all_tags[$i]}"
        else
            printf "%d) %s\n" "$((i+1))" "${all_tags[$i]}"
        fi
    done
    
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo "[1-9] Filter [q]uit"
    
    while true; do
        read -rsn1 key
        case "$key" in
            "0")
                tag_filter=""
                echo -e "${COLOR_SEL}✔ Showing all tasks${COLOR_RESET}"
                sleep 0.5
                break
                ;;
            [1-9])
                local idx=$((key - 1))
                if [ "$idx" -lt "$num_tags" ]; then
                    tag_filter="${all_tags[$idx]}"
                    echo -e "${COLOR_SEL}✔ Filtering by ${tag_filter}${COLOR_RESET}"
                    sleep 0.5
                    break
                fi
                ;;
            "q"|"Q"|$'\x1b')
                break
                ;;
        esac
    done
    selected_index=0
}
