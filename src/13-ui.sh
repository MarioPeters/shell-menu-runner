# ==============================================================================
#  UI RENDERING & KEYBOARD INPUT HANDLING
# ==============================================================================

calculate_layout() {
    local total="$1"
    local cols=1
    local rows="$total"
    
    # Dynamic column layout based on item count and terminal width
    local term_width
    term_width=$(tput cols 2>/dev/null || echo 80)
    
    if [ "$total" -gt 12 ] && [ "$term_width" -ge 120 ] && [ "$COLS_MAX" -ge 3 ]; then
        cols=3
        rows=$(( (total + cols - 1) / cols ))
    elif [ "$total" -gt 6 ] && [ "$term_width" -ge 100 ] && [ "$COLS_MAX" -ge 2 ]; then
        cols=2
        rows=$(( (total + cols - 1) / cols ))
    fi
    
    [ "$cols" -lt "$COLS_MIN" ] && cols="$COLS_MIN"
    [ "$cols" -gt "$COLS_MAX" ] && cols="$COLS_MAX"
    
    echo "$rows|$cols"
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
    read -r -n1 -s
}

get_menu_options() {
    # Cache check for performance
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -n "$cached_menu_options" ]; then
        if [ -f "$config_path" ]; then
            local current_mtime
            current_mtime=$(stat -f %m "$config_path" 2>/dev/null || stat -c %Y "$config_path" 2>/dev/null || echo 0)
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
        search_pattern="$(echo "$filter_query" | tr '[:upper:]' '[:lower:]')"
    fi
    
    if [ -n "$tag_filter" ]; then
        tag_pattern="$tag_filter"
    fi
    
    local all_output=""
    if [ "${#task_config_files[@]}" -gt 0 ]; then
        all_output=$(merge_configs)
    elif [ -f "$config_path" ]; then
        all_output=$(cat "$config_path")
    fi

    local result=""
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
            search_text="$(echo "$name $desc" | tr '[:upper:]' '[:lower:]')"
            [[ ! "$search_text" =~ $search_pattern ]] && continue
        fi

        # Tag filtering
        if [ -n "$tag_pattern" ]; then
            has_tag "$desc" "$tag_pattern" || continue
        fi

        # Append to result buffer (do not echo here to avoid recursion)
        result+="$level|$name|$cmd|$desc\n"
    done <<< "$all_output"

    # Cache result (store the constructed string, avoid calling get_menu_options again)
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -z "$filter_query" ] && [ -z "$tag_filter" ] && [ -f "$config_path" ]; then
        cached_menu_options="$result"
        last_config_mtime=$(stat -f %m "$config_path" 2>/dev/null || stat -c %Y "$config_path" 2>/dev/null || echo 0)
    fi

    # Emit result
    printf "%s" "$result"
}

draw_menu() {
    clear
    hide_cursor
    
    # Header
    local mode_indicator="[${active_mode}]"
    local profile_name=""
    if [ "$active_mode" = "global" ] && [ -f "$config_path" ]; then
        profile_name=$(basename "$config_path" .tasks)
        [ "$profile_name" != ".tasks" ] && mode_indicator="[${profile_name}]"
    fi
    
    echo -e "${COLOR_HEAD}════ Shell Menu Runner ${VERSION} ${mode_indicator} ════${COLOR_RESET}"
    
    if [ "$current_level" -gt 0 ]; then
        local breadcrumb=""
        for bname in "${history_name_stack[@]}"; do
            breadcrumb="${breadcrumb}${bname} > "
        done
        echo -e "${COLOR_DIM}${breadcrumb%> }${COLOR_RESET}"
    fi
    
    if [ -n "$filter_query" ]; then
        echo -e "${COLOR_INFO}📎 Filter: $filter_query${COLOR_RESET}"
    fi
    
    if [ -n "$tag_filter" ]; then
        echo -e "${COLOR_INFO}🏷  Tag: $tag_filter${COLOR_RESET}"
    fi
    
    echo ""
    
    # Menu grid
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        echo -e "${COLOR_DIM}No tasks found. Press 'e' to edit config or '?' for help.${COLOR_RESET}"
        return
    fi
    
    local rows cols
    IFS='|' read -r rows cols <<< "$(calculate_layout "$total")"
    
    for ((r=0; r<rows; r++)); do
        for ((c=0; c<cols; c++)); do
            local idx=$((r + c * rows))
            [ "$idx" -ge "$total" ] && continue
            
            IFS='|' read -r level name cmd desc <<< "${menu_options[$idx]}"
            
            local marker="  "
            local color="$COLOR_RESET"
            
            if [ "$idx" -eq "$selected_index" ]; then
                marker="► "
                color="$COLOR_SEL"
            fi
            
            if [ -n "${multi_select_map[$idx]:-}" ]; then
                marker="☑ "
            fi
            
            # Truncate long names
            local max_len=35
            if [ "${#name}" -gt "$max_len" ]; then
                name="${name:0:$((max_len-3))}..."
            fi
            
            printf "%s%s%-${max_len}s%s  " "$color" "$marker" "$name" "$COLOR_RESET"
        done
        echo ""
    done
    
    echo ""
    echo -e "${COLOR_DIM}[↑↓] Navigate | [Enter] Execute | [/] Search | [Space] Multi-Select | [?] Help${COLOR_RESET}"
}

# ==============================================================================
#  MAIN INTERACTIVE LOOP WITH KEYBOARD HANDLING
# ==============================================================================

main_interactive_loop() {
    # Initialize
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    local num=${#menu_options[@]}
    IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
    local redraw_needed=1
    local prev_selected_index=$selected_index
    
    while true; do
        # Only redraw if needed (performance optimization)
        if [ "$redraw_needed" -eq 1 ]; then
            draw_menu
            redraw_needed=0
            prev_selected_index=$selected_index
        fi
        
        # ══════════════════════════════════════════════════════════════
        #  KEYBOARD INPUT HANDLING (BUG-FIX: stty raw + dd)
        # ══════════════════════════════════════════════════════════════
        local key=""
        if [ "$is_interactive" -eq 1 ]; then
            # Save terminal state and switch to raw mode
            local old_stty
            old_stty=$(stty -g 2>/dev/null)
            stty raw -echo 2>/dev/null
            
            # Read first byte using dd (more reliable than read with timeout)
            key=$(dd bs=1 count=1 2>/dev/null)
            
            # ESC detection: Check for arrow key sequence
            if [ "$key" = $'\x1b' ]; then
                local rest
                rest=$(dd bs=1 count=2 2>/dev/null)
                key="${key}${rest}"
            fi
            
            # Restore terminal state
            stty "$old_stty" 2>/dev/null
        else
            # Non-interactive: read line (for SSH without TTY)
            read -r key || break
        fi
        
        # ══════════════════════════════════════════════════════════════
        #  KEY HANDLING
        # ══════════════════════════════════════════════════════════════
        case "$key" in
            $'\x1b[A') ((selected_index--)); redraw_needed=1;; # Arrow Up
            $'\x1b[B') ((selected_index++)); redraw_needed=1;; # Arrow Down
            $'\x1b[C') [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows)); redraw_needed=1;; # Arrow Right
            $'\x1b[D') [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows)); redraw_needed=1;; # Arrow Left
            $'\x1b') # Pure ESC key
                if [ "$current_level" -gt 0 ]; then
                    ((current_level--))
                    history_name_stack=("${history_name_stack[@]:0:${#history_name_stack[@]}-1}")
                    selected_index=0
                    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
                    num=${#menu_options[@]}
                    IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
                    redraw_needed=1
                else
                    clear; exit 0
                fi;;
            "k") ((selected_index--)); redraw_needed=1;; # Vim up
            "j") ((selected_index++)); redraw_needed=1;; # Vim down
            "h") [ "$cols" -gt 1 ] && selected_index=$((selected_index - rows)); redraw_needed=1;; # Vim left
            "l") [ "$cols" -gt 1 ] && selected_index=$((selected_index + rows)); redraw_needed=1;; # Vim right
            " ") # Space: Multi-select toggle
                if [[ -n "${multi_select_map[$selected_index]:-}" ]]; then
                    unset 'multi_select_map[$selected_index]'
                else
                    multi_select_map["$selected_index"]=1
                fi
                redraw_needed=1;;
            [1-9]) # Hotkey: direct execution by number
                local hotkey_idx=$((key - 1))
                if [ "$hotkey_idx" -lt "$num" ]; then
                    selected_index="$hotkey_idx"
                    IFS='|' read -r n cm d <<< "${menu_options[$selected_index]}"
                    [ "$cm" != "EXIT" ] && [ "$cm" != "SUB" ] && [ "$cm" != "BACK" ] && execute_task "$cm" "$n" "$d"
                    redraw_needed=1
                fi;;
            "/") # Search
                interactive_search && selected_index=0
                IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
                num=${#menu_options[@]}
                IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
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
                parse_config_vars
                load_settings
                load_state
                detect_config_files
                load_aliases
                IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
                num=${#menu_options[@]}
                IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
                redraw_needed=1;;
            "p"|"P") # Profile selection
                if select_profile_menu; then
                    selected_index=0
                    current_level=0
                    history_name_stack=("Main")
                    parse_config_vars
                    load_settings
                    load_state
                    detect_config_files
                    load_aliases
                    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
                    num=${#menu_options[@]}
                    IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
                    redraw_needed=1
                fi;;
            "s") settings_menu; redraw_needed=1;;
            "!") show_history; redraw_needed=1;;
            "a"|"A") show_alias_editor; redraw_needed=1;;
            "?") show_help_panel; redraw_needed=1;;
            $'\r'|$'\n'|"") # ENTER key (BUG-FIX: Accept both \r and \n)
                set +u
                [ ${#menu_options[@]} -eq 0 ] && { set -u; continue; }
                
                # Multi-select execution
                if [ ${#multi_select_map[@]} -gt 0 ]; then
                    set -u
                    IFS=$'\n' read -r -d '' -a multi_keys < <(printf "%s\n" "${!multi_select_map[@]}" | sort -n && printf '\0') || true
                    for mi in "${multi_keys[@]}"; do
                        IFS='|' read -r n cm d <<< "${menu_options[$mi]}"
                        [ "$cm" == "EXIT" ] && continue
                        execute_task "$cm" "$n" "$d"
                    done
                    echo -e "${COLOR_INFO}$(msg executed_marked):${COLOR_RESET} ${#multi_keys[@]} $(msg marked_label)"
                    multi_select_map=()
                    redraw_needed=1
                    continue
                fi
                set -u
                
                # Single execution
                IFS='|' read -r n cm d <<< "${menu_options[$selected_index]}"
                if [ "$cm" == "EXIT" ]; then
                    clear; exit 0
                elif [ "$cm" == "SUB" ]; then
                    ((current_level++))
                    history_name_stack+=("$n")
                    selected_index=0
                    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
                    num=${#menu_options[@]}
                    IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
                    redraw_needed=1
                elif [ "$cm" == "BACK" ] && [ "$current_level" -gt 0 ]; then
                    ((current_level--))
                    history_name_stack=("${history_name_stack[@]:0:${#history_name_stack[@]}-1}")
                    selected_index=0
                    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
                    num=${#menu_options[@]}
                    IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
                    redraw_needed=1
                else
                    execute_task "$cm" "$n" "$d"
                    redraw_needed=1
                fi;;
            "e"|"E") # Edit config
                [ -z "$config_path" ] && config_path="$LOCAL_CONFIG"
                edit_config_menu "$config_path"
                redraw_needed=1;;
            "f"|"F") file_browser; redraw_needed=1;;
            "#") # Tag filter
                show_tag_menu
                IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
                num=${#menu_options[@]}
                IFS='|' read -r rows cols <<< "$(calculate_layout "$num")"
                redraw_needed=1;;
            "*") # Toggle favorite
                if [ "$selected_index" -lt "$num" ]; then
                    IFS='|' read -r n cm d <<< "${menu_options[$selected_index]}"
                    toggle_favorite "$n"
                fi
                redraw_needed=1;;
            "r"|"R") show_favorites; redraw_needed=1;;
            "q"|"Q") clear; exit 0;;
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
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    local num=${#menu_options[@]}
    [ "$num" -eq 0 ] && return
    [ "$selected_index" -ge "$num" ] && return
    IFS='|' read -r name cmd desc <<< "${menu_options[$selected_index]}"
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
