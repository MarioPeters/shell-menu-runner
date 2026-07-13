# ==============================================================================
#  UI RENDERING & KEYBOARD INPUT HANDLING
# ==============================================================================

# Terminal capabilities are initialized in 03-terminal.sh via init_terminal_capabilities

# Setzt _layout_rows/_layout_cols direkt — kein Subshell-Overhead bei jedem Redraw
calculate_layout() {
    local total="$1"
    local term_width="${TPUT_COLS:-80}"
    local min_col_width="${COLS_MIN_WIDTH:-30}"
    local max_cols="${COLS_MAX:-4}"
    local min_cols="${COLS_MIN:-1}"

    # Derive column count from terminal width
    local cols=$(( term_width / min_col_width ))

    # Apply COLS_MAX (0 = unlimited)
    if [ "$max_cols" -gt 0 ] && [ "$cols" -gt "$max_cols" ]; then
        cols="$max_cols"
    fi

    # Don't use more columns than makes sense (at least 2 items per column)
    if [ "$total" -gt 0 ]; then
        local max_useful=$(( (total + 1) / 2 ))
        [ "$cols" -gt "$max_useful" ] && cols="$max_useful"
    fi

    # Apply minimum column count
    [ "$cols" -lt "$min_cols" ] && cols="$min_cols"
    [ "$cols" -lt 1 ] && cols=1

    local rows=$(( (total + cols - 1) / cols ))
    [ "$rows" -lt 1 ] && rows=1

    _layout_rows=$rows
    _layout_cols=$cols
}

show_help_panel() {
    clear
    cat << EOF
${COLOR_HEAD}════════════════════════════════════════════════════════════════${COLOR_RESET}
${COLOR_HEAD}║                    SHELL MENU RUNNER v${VERSION}                 ║${COLOR_RESET}
${COLOR_HEAD}════════════════════════════════════════════════════════════════${COLOR_RESET}

${COLOR_SEL}Navigation:${COLOR_RESET}
  ↑/↓ or j/k      Navigate tasks
  ←/→ or h/l      Multi-column navigation
  [Enter]         Execute selected task
  [1-9]           Quick execute (hotkey)
  [Space]         Multi-select (execute multiple)
  [ESC] or q      Exit / Go back

${COLOR_SEL}Features:${COLOR_RESET}
  /               Search/filter tasks
  #               Filter by tags
  g               Toggle local/global config
  p               Switch profile
  s               Settings menu
  e               Edit config
  f               File browser
  *               Toggle favorite
  r               Show recent tasks
  !               Show history
  a               Alias editor
  ?               This help

${COLOR_SEL}Profiles:${COLOR_RESET}
  run [profile]   Load specific profile
  run --list      List all profiles
  run --init      Initialize new .tasks config

${COLOR_DIM}Press any key to continue...${COLOR_RESET}
EOF
    consume_keypress
}

get_menu_options() {
    # Cache check for performance
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -n "$cached_menu_options" ]; then
        if [ -f "$config_path" ]; then
            local current_mtime
            current_mtime=$(get_file_mtime "$config_path")
            if [ "$current_mtime" -eq "$last_config_mtime" ] && [ -z "$filter_query" ] && [ -z "$tag_filter" ]; then
                echo "$cached_menu_options"
                return 0
            fi
        fi
    fi

    # Build menu options
    local level_str=""
    local search_pattern=""
    local tag_pattern=""

    if [ "$current_level" -gt 0 ]; then
        level_str="${history_name_stack[$current_level]}"
    fi

    if [ -n "$filter_query" ]; then
        # tr mit here-string: kein echo-Subshell-Pipe
        search_pattern=$(tr '[:upper:]' '[:lower:]' <<< "$filter_query")
    fi

    if [ -n "$tag_filter" ]; then
        tag_pattern="$tag_filter"
    fi

    local result=""
    # Process substitution: Config-Inhalt direkt streamen — kein all_output-String-Kopie im Speicher
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^TIMEOUT= ]] && continue
        [[ "$line" =~ ^VAR_ ]] && continue
        [[ "$line" =~ ^THEME: ]] && continue
        [[ "$line" =~ ^TITLE: ]] && continue

        IFS='|' read -r level name cmd desc <<< "$line"
        [ -z "$name" ] && continue

        # Level filtering
        if [ "$current_level" -eq 0 ]; then
            [ "$level" != "0" ] && continue
        else
            [ "$level" != "$((current_level))" ] && continue
            if [ -n "$level_str" ] && [[ ! "$name" =~ ^$level_str\. ]]; then
                continue
            fi
        fi

        # Search filtering
        if [ -n "$search_pattern" ]; then
            local search_text
            # here-string statt echo|tr: spart einen Subshell-Pipe-Prozess pro Zeile
            search_text=$(tr '[:upper:]' '[:lower:]' <<< "$name $desc")
            [[ ! "$search_text" =~ $search_pattern ]] && continue
        fi

        # Tag filtering
        if [ -n "$tag_pattern" ]; then
            has_tag "$desc" "$tag_pattern" || continue
        fi

        # Append to result buffer (do not echo here to avoid recursion)
        result+="${level}|${name}|${cmd}|${desc}"$'\n'
    done < <(
        if [ "${#task_config_files[@]}" -gt 0 ]; then
            cat "${task_config_files[@]}" 2>/dev/null || true
        elif [ -f "$config_path" ]; then
            cat "$config_path"
        fi
    )

    # Cache result (store the constructed string, avoid calling get_menu_options again)
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -z "$filter_query" ] && [ -z "$tag_filter" ] && [ -f "$config_path" ]; then
        cached_menu_options="$result"
        last_config_mtime=$(get_file_mtime "$config_path")
    fi

    # Emit result
    printf "%s" "$result"
}

draw_menu() {
    if [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_CUP" ]; then
        echo -ne "$TPUT_CUP"
    else
        clear
    fi
    hide_cursor
    local _EL='\033[K'   # erase-to-EOL — prevents ghost text from shorter redraws

    # ── Header ───────────────────────────────────────────────────────
    local mode_indicator="[${active_mode}]"
    if [ "$active_mode" = "global" ] && [ -f "$config_path" ]; then
        local _bn="${config_path##*/}"
        local _pname="${_bn##.tasks}"; _pname="${_pname#.}"
        [ -n "$_pname" ] && mode_indicator="[${_pname}]"
    fi
    echo -e "${COLOR_HEAD}════ Shell Menu Runner ${VERSION} ${mode_indicator} ════${COLOR_RESET}${_EL}"

    # Context line (git branch, hostname, env) — empty string = no line
    [ -n "${_CTX_LINE:-}" ] && echo -e "${_CTX_LINE}${_EL}"

    if [ "$current_level" -gt 0 ]; then
        local _bc=""
        for _bname in "${history_name_stack[@]}"; do _bc="${_bc}${_bname} > "; done
        echo -e "${COLOR_DIM}${_bc%> }${COLOR_RESET}${_EL}"
    fi
    [ -n "$filter_query" ] && echo -e "${COLOR_INFO}📎 Filter: $filter_query${COLOR_RESET}${_EL}"
    [ -n "$tag_filter"   ] && echo -e "${COLOR_INFO}🏷  Tag: $tag_filter${COLOR_RESET}${_EL}"
    echo -e "${_EL}"

    # ── Empty state ──────────────────────────────────────────────────
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tasks found. Press 'e' to edit config or '?' for help.${COLOR_RESET}${_EL}"
        [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
        return
    fi

    # ── Layout ───────────────────────────────────────────────────────
    calculate_layout "$total"
    local rows=$_layout_rows cols=$_layout_cols
    local term_width="${TPUT_COLS:-80}"
    local col_width=$(( term_width / cols ))
    local inner=$(( col_width - 4 ))
    [ "$inner" -lt 1 ] && inner=1
    local name_max=$(( inner - 4 ))
    [ "$name_max" -lt 1 ] && name_max=1

    # Rebuild border strings when col_width changed (e.g. terminal resize)
    if [ "$col_width" -ne "${_LAST_COL_WIDTH:-0}" ]; then
        build_border_strings "$col_width"
    fi

    # ── Grid rendering (3 lines per item, separate boxes) ───────────
    local r c idx
    local gap="  "   # 2-space gap between columns; added BEFORE column (not after)

    for (( r=0; r<rows; r++ )); do
        local top_line="" content_line="" bot_line=""
        local first_in_row=1

        for (( c=0; c<cols; c++ )); do
            idx=$(( r + c * rows ))
            [ "$idx" -ge "$total" ] && continue

            local border_color="$COLOR_DIM"
            [ "$idx" -eq "$selected_index" ] && border_color="$COLOR_SEL"

            if [ "$first_in_row" -eq 0 ]; then
                top_line+="$gap"
                content_line+="$gap"
                bot_line+="$gap"
            fi
            first_in_row=0

            # Hotkey number (column-first, left side) — revert to top border only
            top_line+="${border_color}${_BORDER_TOP}${COLOR_RESET}"
            bot_line+="${border_color}${_BORDER_BOT}${COLOR_RESET}"

            # Content
            # shellcheck disable=SC2034
            IFS='|' read -r _lvl _name _cmd _desc <<< "${menu_options[$idx]}"

            # Hotkey prefix (2 chars) + marker (1 char) = 3 chars, same total as before.
            # Keeping them separate avoids "1►" overlap: shows "1 ►" instead.
            local _item_num=$(( idx + 1 ))
            local _hotkey_pfx="  "
            [ "$_item_num" -le 9 ] && _hotkey_pfx="${COLOR_DIM}${_item_num}${COLOR_RESET} "

            local marker=" "
            local text_color="$COLOR_DIM"
            if [ "$idx" -eq "$selected_index" ]; then
                marker="►"; text_color="$COLOR_BOLD"
            fi
            if [ -n "${multi_select_map[$idx]:-}" ]; then
                marker="☑"; text_color="$COLOR_INFO"
            fi

            # Wide-char visual-width correction.
            # IMPORTANT: do NOT use printf "%-*s" for padding — bash 3.2 counts
            # bytes (not visual columns) in the field-width, so emoji names come
            # out 1-3 cols too narrow.  Instead we calculate the exact number of
            # spaces needed and append them as plain ASCII.
            local _nc=${#_name} _nb _lc_was_set=0 _lc_saved=""
            [ -n "${LC_ALL+x}" ] && _lc_was_set=1 && _lc_saved="$LC_ALL"
            LC_ALL=C; _nb=${#_name}
            if [ "$_lc_was_set" -eq 1 ]; then LC_ALL="$_lc_saved"; else unset LC_ALL; fi
            local _wc_extra=$(( (_nb - _nc) / 3 ))   # extra terminal cols from wide chars

            # Truncate to fit (check visual width)
            if [ $(( _nc + _wc_extra )) -gt "$name_max" ]; then
                local _trunc=$(( name_max - 3 - _wc_extra ))
                [ "$_trunc" -lt 1 ] && _trunc=1
                _name="${_name:0:$_trunc}..."
                # Recalculate after truncation
                _nc=${#_name}
                local _nb2; LC_ALL=C; _nb2=${#_name}
                if [ "$_lc_was_set" -eq 1 ]; then LC_ALL="$_lc_saved"; else unset LC_ALL; fi
                _wc_extra=$(( (_nb2 - _nc) / 3 ))
            fi
            # Pad with explicit spaces — visual width guaranteed regardless of locale
            local _vis=$(( _nc + _wc_extra ))
            local _nspaces=$(( name_max - _vis ))
            [ "$_nspaces" -lt 0 ] && _nspaces=0
            local _spaces=""
            [ "$_nspaces" -gt 0 ] && printf -v _spaces '%*s' "$_nspaces" ''
            local _padded="${_name}${_spaces}"

            content_line+="${border_color}│${COLOR_RESET}${_hotkey_pfx}${text_color}${marker}${_padded}${COLOR_RESET} ${border_color}│${COLOR_RESET}"
        done

        echo -e "${top_line}${_EL}"
        echo -e "${content_line}${_EL}"
        echo -e "${bot_line}${_EL}"
    done

    # ── Footer hints (width-adaptive to prevent wrapping) ───────────
    echo -e "${_EL}"
    if [ "$term_width" -ge 80 ]; then
        local _nav_lr=""; [ "$cols" -gt 1 ] && _nav_lr=" ←→ h/l"
        echo -e "${COLOR_DIM}[↑↓${_nav_lr}] Navigate | [Enter] Execute | [/] Search | [Space] Multi | [?] Help${COLOR_RESET}${_EL}"
    elif [ "$term_width" -ge 46 ]; then
        echo -e "${COLOR_DIM}[↑↓←→] Nav | [Enter] Run | [/] Search | [?] Help${COLOR_RESET}${_EL}"
    else
        echo -e "${COLOR_DIM}[↑↓←→]  [Enter]  [/]  [?]${COLOR_RESET}${_EL}"
    fi

    [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
}

# ==============================================================================
#  MAIN INTERACTIVE LOOP WITH KEYBOARD HANDLING
# ==============================================================================

# Lädt menu_options neu und aktualisiert calculate_layout.
_reload_menu() {
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    calculate_layout "${#menu_options[@]}"
}

# Lädt Konfiguration + Menü neu — ersetzt das 5-Funktionen-Pattern
# parse_config_vars+load_settings+load_state+detect_config_files+load_aliases.
_reinit_menu() {
    parse_config_vars
    load_settings
    load_state
    detect_config_files
    load_aliases
    _reload_menu
}

# Führt "$@" mit wiederhergestellten Terminal-Einstellungen aus und schaltet
# danach wieder in den Raw-Mode. Ersetzt das 15× vorhandene
# restore_term; <call>; [ is_interactive ] && stty ... -Pattern.
run_with_term_paused() {
    restore_term
    "$@"
    if [ "${is_interactive:-0}" -eq 1 ]; then
        set_raw_mode
        drain_stdin  # flush any escape sequence tails from the secondary screen
    fi
}

main_interactive_loop() {
    # Disable strict error checking for the interactive loop to prevent
    # accidental exits during navigation (arithmetic 0 results, etc.)
    set +e

    # Initialize
    _reload_menu
    local num=${#menu_options[@]}
    local rows=$_layout_rows cols=$_layout_cols
    local redraw_needed=1

    # OPTIMIZATION: Set raw mode once to avoid stty overhead
    local old_stty=""
    restore_term() {
        [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null
    }

    if [ "$is_interactive" -eq 1 ]; then
        old_stty=$(stty -g 2>/dev/null)
        set_raw_mode
        trap 'restore_term; cleanup_wrapper; exit 130' INT TERM
    fi

    while true; do
        # Only redraw if needed (performance optimization)
        if [ "$redraw_needed" -eq 1 ]; then
            draw_menu
            redraw_needed=0
        fi

        # ══════════════════════════════════════════════════════════════
        #  KEYBOARD INPUT HANDLING
        # ══════════════════════════════════════════════════════════════
        local key="" _rk_status=0
        if [ "$is_interactive" -eq 1 ]; then
            # Capture exit status separately: command substitution strips trailing \n,
            # so a real Enter (\n) correctly becomes "".  But if read_key_raw fails
            # (e.g. EINTR from a signal), we must NOT treat the empty result as Enter.
            key=$(read_key_raw); _rk_status=$?
            [ "$_rk_status" -ne 0 ] && continue
        else
            # Non-interactive: read line (for SSH without TTY)
            read -r key || break
        fi

        # ══════════════════════════════════════════════════════════════
        #  KEY HANDLING
        # ══════════════════════════════════════════════════════════════
        case "$key" in
            $'\x1b[A'|$'\x1bOA') selected_index=$((selected_index - 1)); redraw_needed=1;; # Arrow Up
            $'\x1b[B'|$'\x1bOB') selected_index=$((selected_index + 1)); redraw_needed=1;; # Arrow Down
            $'\x1b[C'|$'\x1bOC') [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows)); redraw_needed=1;; # Arrow Right
            $'\x1b[D'|$'\x1bOD') [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows)); redraw_needed=1;; # Arrow Left
            $'\x1b') # Pure ESC key
                if [ "$current_level" -gt 0 ]; then
                    current_level=$((current_level - 1))
                    history_name_stack=("${history_name_stack[@]:0:${#history_name_stack[@]}-1}")
                    selected_index=0
                    _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                    redraw_needed=1
                else
                    restore_term; clear; exit 0
                fi;;
            "k") selected_index=$((selected_index - 1)); redraw_needed=1;; # Vim up
            "j") selected_index=$((selected_index + 1)); redraw_needed=1;; # Vim down
            "h") [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows)); redraw_needed=1;; # Vim left
            "l") [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows)); redraw_needed=1;; # Vim right
            " ") # Space: Multi-select toggle
                if [[ -n "${multi_select_map[$selected_index]:-}" ]]; then
                    unset 'multi_select_map[$selected_index]'
                else
                    multi_select_map["$selected_index"]=1
                fi
                redraw_needed=1;;
            [1-9]) # Hotkey: direct execution by column-first index (matches displayed number)
                local hotkey_idx=$((key - 1))
                if [ "$hotkey_idx" -lt "$num" ]; then
                    selected_index="$hotkey_idx"
                    IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
                    if [ "$cmd" != "EXIT" ] && [ "$cmd" != "SUB" ] && [ "$cmd" != "BACK" ]; then
                        run_with_term_paused execute_task "$cmd" "$name" "$desc"
                    fi
                    redraw_needed=1
                fi;;
            "/") # Search
                restore_term
                interactive_search && selected_index=0
                if [ "${is_interactive:-0}" -eq 1 ]; then
                    set_raw_mode
                    drain_stdin
                fi
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "g") # Toggle local/global
                if [ "$active_mode" == "local" ]; then
                    active_mode="global"
                    config_path="$GLOBAL_CONFIG"
                elif found=$(find_local_config); then
                    active_mode="local"
                    config_path="$found"
                fi
                selected_index=0
                current_level=0
                _reinit_menu
                num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "p"|"P") # Profile selection
                restore_term
                if select_profile_menu; then
                    selected_index=0
                    current_level=0
                    history_name_stack=("Main")
                    _reinit_menu
                    num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                fi
                clear  # remove profile-menu artefacts before redraw
                if [ "${is_interactive:-0}" -eq 1 ]; then
                    set_raw_mode
                    drain_stdin
                fi
                redraw_needed=1;;
            "s") run_with_term_paused settings_menu; redraw_needed=1;;
            "!") run_with_term_paused show_history; redraw_needed=1;;
            "a"|"A") run_with_term_paused show_alias_editor; redraw_needed=1;;
            "?") run_with_term_paused show_help_panel; redraw_needed=1;;
            $'\r'|$'\n'|"") # ENTER: \r = raw CR, \n = LF, "" = \n stripped by $()
                set +u
                [ ${#menu_options[@]} -eq 0 ] && { set -u; continue; }

                # Multi-select execution
                if [ ${#multi_select_map[@]} -gt 0 ]; then
                    set -u
                    restore_term
                    IFS=$'\n' read -r -d '' -a multi_keys < <(printf "%s\n" "${!multi_select_map[@]}" | sort -n && printf '\0') || true
                    for mi in "${multi_keys[@]}"; do
                        IFS='|' read -r level name cmd desc <<< "${menu_options[$mi]}"
                        [ "$cmd" == "EXIT" ] && continue
                        execute_task "$cmd" "$name" "$desc"
                    done
                    if [ "$is_interactive" -eq 1 ]; then
                        set_raw_mode
                        drain_stdin
                    fi
                    echo -e "${COLOR_INFO}$(msg executed_marked):${COLOR_RESET} ${#multi_keys[@]} $(msg marked_label)"
                    multi_select_map=()
                    redraw_needed=1
                    continue
                fi
                set -u

                # Single execution
                IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
                if [ "$cmd" == "EXIT" ]; then
                    restore_term; clear; exit 0
                elif [ "$cmd" == "SUB" ]; then
                    current_level=$((current_level + 1))
                    history_name_stack+=("$name")
                    selected_index=0
                    _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                    redraw_needed=1
                elif [ "$cmd" == "BACK" ] && [ "$current_level" -gt 0 ]; then
                    current_level=$((current_level - 1))
                    history_name_stack=("${history_name_stack[@]:0:${#history_name_stack[@]}-1}")
                    selected_index=0
                    _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                    redraw_needed=1
                else
                    run_with_term_paused execute_task "$cmd" "$name" "$desc"
                    redraw_needed=1
                fi;;
            "e"|"E") # Edit config
                [ -z "$config_path" ] && config_path="$LOCAL_CONFIG"
                run_with_term_paused edit_config_menu "$config_path"
                redraw_needed=1;;
            "f"|"F") run_with_term_paused file_browser; redraw_needed=1;;
            "#") # Tag filter
                run_with_term_paused show_tag_menu
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "*") # Toggle favorite
                # Internal operation, no restore needed
                if [ "$selected_index" -lt "$num" ]; then
                    IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
                    toggle_favorite "$name"
                fi
                redraw_needed=1;;
            "r"|"R") run_with_term_paused show_favorites; redraw_needed=1;;
            "q"|"Q") restore_term; clear; exit 0;;
        esac

        # Wrap around selection index
        local cnt=${#menu_options[@]}
        [ "$selected_index" -lt 0 ] && selected_index=$((cnt-1))
        [ "$selected_index" -ge "$cnt" ] && selected_index=0
    done
}

# ==============================================================================
#  CONTEXT MENU
# ==============================================================================

context_menu() {
    # menu_options ist global stets aktuell — kein erneuter get_menu_options-Aufruf nötig
    local num=${#menu_options[@]}
    [ "$num" -eq 0 ] && return
    [ "$selected_index" -ge "$num" ] && return
    IFS='|' read -r level name cmd desc <<< "${menu_options[$selected_index]}"
    if [ "$cmd" = "SUB" ] || [ "$cmd" = "BACK" ] || [ "$cmd" = "EXIT" ]; then
        echo -e "${COLOR_WARN}No context actions for this entry.${COLOR_RESET}"
        sleep 1
        return
    fi

    # Show context menu with available actions
    clear
    echo -e "${COLOR_HEAD}Context Menu: ${name}${COLOR_RESET}"
    echo -e "${COLOR_DIM}${desc}${COLOR_RESET}"
    echo ""
    echo "1) Copy name to clipboard"
    echo "2) Copy command to clipboard"
    echo "3) Copy description to clipboard"
    echo "0) Cancel"
    echo ""
    read -rsn1 choice

    case "$choice" in
        1) copy_to_clipboard "$name" ;;
        2) copy_to_clipboard "$cmd" ;;
        3) copy_to_clipboard "$desc" ;;
    esac
}
