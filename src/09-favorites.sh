# ==============================================================================
#  TASK FAVORITES
# ==============================================================================

readonly RUN_FAVORITES_FILE="$HOME/.run_favorites"

is_favorite() {
    local task_name="$1"
    if [ -f "$RUN_FAVORITES_FILE" ]; then
        # "-e <pattern> -- <file>": ein Task-Name, der mit "-" beginnt,
        # würde sonst als Option interpretiert (rg las den Dateinamen als
        # Muster und blockierte auf stdin).
        _grep -qxF -e "$task_name" -- "$RUN_FAVORITES_FILE" || return 1
    else
        return 1
    fi
}

toggle_favorite() {
    local task_name="$1"
    # Read-Modify-Write unter einer Sperre: parallel laufende Instanzen
    # überschrieben sich sonst gegenseitig (Favoriten gingen verloren).
    _lock_acquire "$RUN_FAVORITES_FILE"
    if is_favorite "$task_name"; then
        # PID im Temp-Namen: parallele run.sh-Instanzen dürfen sich nicht
        # gegenseitig die Temp-Datei wegschnappen.
        local tmp="${RUN_FAVORITES_FILE}.tmp.$$"
        if _grep -vxF -e "$task_name" -- "$RUN_FAVORITES_FILE" > "$tmp"; then
            mv "$tmp" "$RUN_FAVORITES_FILE" 2>/dev/null || rm -f "$tmp"
        else
            rm -f "$tmp"
        fi
        _lock_release "$RUN_FAVORITES_FILE"
        echo -e "${COLOR_INFO}⭐ Removed from favorites${COLOR_RESET}"
    else
        printf '%s\n' "$task_name" >> "$RUN_FAVORITES_FILE"
        _lock_release "$RUN_FAVORITES_FILE"
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
            _fline="${_fline%$'\r'}"
            [ -n "$_fline" ] && fav_list+=("$_fline")
        done < "$RUN_FAVORITES_FILE"
    fi

    local fav_count=${#fav_list[@]}
    if [ "$fav_count" -eq 0 ]; then
        echo -e "${COLOR_DIM}No favorites yet. Press [*] on a task to add it!${COLOR_RESET}"
    else
        echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
        local idx=1
        for _fav in "${fav_list[@]}"; do
            # Every entry gets a number — entries 10+ were displayed without
            # a number and could therefore not be selected.
            printf "%d) ${COLOR_SEL}%s${COLOR_RESET}\n" "$idx" "$_fav"
            idx=$((idx + 1))
        done
    fi
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
    if [ "$fav_count" -gt 9 ]; then
        echo -e "\n[1-9] [two digits] Execute [q]uit"
    else
        echo -e "\n[1-9] Execute [q]uit"
    fi

    while true; do
        key=$(read_key) || break
        if [[ "$key" =~ ^[0-9]$ ]]; then
            # Zwei-stellige Auswahl: die Einträge 10+ wurden angezeigt, waren
            # aber nicht erreichbar — es wurde nur eine Ziffer akzeptiert.
            local _num="$key"
            if [ "$fav_count" -gt 9 ] && [ "$_num" != "0" ]; then
                local _second
                # 0,5 s Zeitfenster fuer die zweite Ziffer (10+)
                _second=$(read_key_optional 5)
                if [ -n "$_second" ] && [[ "$_second" =~ ^[0-9]$ ]]; then
                    _num="${_num}${_second}"
                fi
            fi
            # "10#" erzwingt die Basis 10 (sonst wäre "08" ein Oktal-Fehler)
            if selection_index "$_num" "$fav_count"; then
                local fav_name="${fav_list[$SELECT_INDEX]}"  # Array-Index statt sed-Fork
                if [ -n "$fav_name" ]; then
                    local _rc=0
                    find_task_in_menu "$fav_name" "_execute_fav_callback" || _rc=$?
                    if [ "$_TASK_FOUND" -eq 0 ]; then
                        echo -e "${COLOR_ERR}Task not found in current profile${COLOR_RESET}"
                        sleep 1
                    elif [ "$_rc" -eq 0 ]; then
                        clear
                        return 0
                    else
                        echo -e "${COLOR_ERR}Task failed (exit $_rc)${COLOR_RESET}"
                        sleep 1
                    fi
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
