# ==============================================================================
#  TASK FAVORITES
# ==============================================================================

readonly RUN_FAVORITES_FILE="$HOME/.run_favorites"

is_favorite() {
    local task_name="$1"
    if [ -f "$RUN_FAVORITES_FILE" ]; then
        grep -qxF "$task_name" "$RUN_FAVORITES_FILE" || return 1
    else
        return 1
    fi
}

toggle_favorite() {
    local task_name="$1"
    if is_favorite "$task_name"; then
        if grep -vxF "$task_name" "$RUN_FAVORITES_FILE" > "${RUN_FAVORITES_FILE}.tmp"; then
            mv "${RUN_FAVORITES_FILE}.tmp" "$RUN_FAVORITES_FILE"
        fi
        echo -e "${COLOR_INFO}⭐ Removed from favorites${COLOR_RESET}"
    else
        echo "$task_name" >> "$RUN_FAVORITES_FILE"
        echo -e "${COLOR_SEL}⭐ Added to favorites!${COLOR_RESET}"
    fi
    sleep 0.5
}

show_favorites() {
    clear
    echo -e "${COLOR_HEAD}⭐ Favorite Tasks${COLOR_RESET}"

    # Datei einmalig in Array lesen — kein sed-Fork pro Tastendruck
    local -a fav_list=()
    if [ -f "$RUN_FAVORITES_FILE" ] && [ -s "$RUN_FAVORITES_FILE" ]; then
        while IFS= read -r _fline || [ -n "$_fline" ]; do
            [ -n "$_fline" ] && fav_list+=("$_fline")
        done < "$RUN_FAVORITES_FILE"
    fi

    if [ "${#fav_list[@]}" -eq 0 ]; then
        echo -e "${COLOR_DIM}No favorites yet. Press [*] on a task to add it!${COLOR_RESET}"
    else
        echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
        local idx=1
        for _fav in "${fav_list[@]}"; do
            if [ "$idx" -le 9 ]; then
                printf "%d) ${COLOR_SEL}%s${COLOR_RESET}\n" "$idx" "$_fav"
            else
                printf "  ${COLOR_DIM}%s${COLOR_RESET}\n" "$_fav"
            fi
            idx=$((idx + 1))
        done
    fi
    echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "\n[1-9] Execute [q]uit"

    while true; do
        key=$(read_key) || break
        if [[ "$key" =~ [1-9] ]]; then
            local sel=$((key - 1))
            local fav_name="${fav_list[$sel]:-}"  # Array-Index statt sed-Fork
            if [ -n "$fav_name" ]; then
                if find_task_in_menu "$fav_name" "_execute_fav_callback"; then
                    clear
                    return 0
                else
                    echo -e "${COLOR_ERR}Task not found in current profile${COLOR_RESET}"
                    sleep 1
                fi
            fi
        elif [[ "$key" == "q" ]] || [[ "$key" == "Q" ]] || [[ "$key" == $'\x1b' ]]; then
            break
        fi
    done
    clear
}

_execute_fav_callback() {
    local name="$1"
    local cmd="$2"
    local desc="$3"
    execute_task "$cmd" "$name" "$desc"
}
