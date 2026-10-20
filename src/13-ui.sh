# ==============================================================================
#  UI RENDERING & KEYBOARD INPUT HANDLING
# ==============================================================================

# Terminal capabilities are initialized in 03-terminal.sh via init_terminal_capabilities

# Cache for the padded name fields of the menu (index → padded text).
# Measuring the display width of every entry is expensive, and the fields
# only change when the menu or the terminal width changes.
declare -a _name_field_cache=()
_name_field_cache_key=""

# Redraw counter — used to poll the terminal width (not every SSH client
# sends SIGWINCH when the window is resized).
_redraw_counter=0

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
    # Box width adapts to the terminal — a fixed 64 column frame wraps on
    # narrow terminals and breaks the layout.
    local _w=$(( ${TPUT_COLS:-80} - 2 ))
    [ "$_w" -gt 64 ] && _w=64
    [ "$_w" -lt 30 ] && _w=30

    local _bar="" _i
    for (( _i=0; _i<_w; _i++ )); do _bar+='═'; done

    local _title="SHELL MENU RUNNER v${VERSION}"
    local _inner=$(( _w - 2 ))
    local _tpad=$(( (_inner - ${#_title}) / 2 ))
    [ "$_tpad" -lt 0 ] && _tpad=0
    local _lead="" _trail=""
    printf -v _lead '%*s' "$_tpad" ''
    printf -v _trail '%*s' "$(( _inner - ${#_title} - _tpad ))" ''

    echo -e "${COLOR_HEAD}${_bar}${COLOR_RESET}"
    echo -e "${COLOR_HEAD}║${_lead}${_title}${_trail}║${COLOR_RESET}"
    echo -e "${COLOR_HEAD}${_bar}${COLOR_RESET}"
    echo ""

    # The help lines are cut to the terminal width so they cannot wrap.
    # Section headers (no indent, own line) are printed coloured, the
    # indented entries are cut to the available width.
    local _line
    while IFS= read -r _line; do
        if [ -z "$_line" ]; then
            echo ""
        elif [ "${_line%%:*}" != "$_line" ] && [ "${_line:0:2}" != "  " ]; then
            echo -e "${COLOR_SEL}${_line}${COLOR_RESET}"
        else
            fit_to_width "$_line" "$_w"
            echo "${FIT_TEXT}"
        fi
    done << EOF
Navigation:
  ↑/↓ or j/k      Navigate tasks
  ←/→ or h/l      Multi-column navigation
  [Enter]         Execute selected task
  [1-9]           Quick execute (hotkey)
  [Space]         Multi-select (execute multiple)
  [ESC] or q      Exit / Go back

Features:
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

Profiles:
  run [profile]   Load specific profile
  run --list      List all profiles
  run --init      Initialize new .tasks config
EOF

    echo ""
    echo -e "${COLOR_DIM}Press any key to continue...${COLOR_RESET}"
    consume_keypress
}

get_menu_options() {
    local current_stack_key=""
    if [ "$current_level" -gt 0 ]; then
        current_stack_key="${history_name_stack[*]}"
    fi

    # Cache check for performance
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -n "$cached_menu_options" ]; then
        if [ -f "$config_path" ]; then
            local current_mtime
            current_mtime=$(get_file_mtime "$config_path")
            if [ "$current_mtime" -eq "$last_config_mtime" ] \
               && [ "$current_level" -eq "${last_config_level:-0}" ] \
               && [ "$current_stack_key" = "${last_config_stack:-}" ] \
               && [ -z "$filter_query" ] && [ -z "$tag_filter" ]; then
                printf "%s" "$cached_menu_options"
                return 0
            fi
        fi
    fi

    # Build menu options
    local search_pattern=""
    local tag_pattern=""

    if [ -n "$filter_query" ]; then
        # tr mit here-string: kein echo-Subshell-Pipe
        search_pattern=$(tr '[:upper:]' '[:lower:]' <<< "$filter_query")
    fi

    if [ -n "$tag_filter" ]; then
        tag_pattern="$tag_filter"
    fi

    local result=""
    local -a active_parents=()
    local k i

    # nocasematch makes the filter regex case-insensitive — that replaces a
    # `tr` fork per config line.  The previous shell option is restored below.
    local _nocase_was=0
    shopt -q nocasematch && _nocase_was=1
    [ -n "$search_pattern" ] && shopt -s nocasematch

    # Process substitution: Config-Inhalt direkt streamen — kein all_output-String-Kopie im Speicher
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^TIMEOUT= ]] && continue
        [[ "$line" =~ ^VAR_ ]] && continue
        [[ "$line" =~ ^THEME: ]] && continue
        [[ "$line" =~ ^TITLE: ]] && continue

        split_task_line "$line"
        level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
        [ -z "$name" ] && continue
        [[ "$level" =~ ^[0-9]+$ ]] || continue

        # Update active_parents tracker for positional submenus
        for ((k = level; k < 20; k++)); do
            active_parents[k]=""
        done
        if [ "$cmd" = "SUB" ]; then
            active_parents[level]="$name"
        fi

        # Level filtering
        if [ "$level" -ne "$current_level" ]; then
            continue
        fi

        if [ "$current_level" -gt 0 ]; then
            local parent_match=1
            for ((i = 0; i < current_level; i++)); do
                if [ "${active_parents[i]:-}" != "${history_name_stack[$((i + 1))]:-}" ]; then
                    parent_match=0
                    break
                fi
            done
            [ "$parent_match" -eq 0 ] && continue
        fi

        # Search filtering — nocasematch makes the regex case-insensitive, so
        # no per-line `tr` fork (and no here-string) is needed.
        if [ -n "$search_pattern" ]; then
            [[ ! "$name $desc" =~ $search_pattern ]] && continue
        fi

        # Tag filtering
        if [ -n "$tag_pattern" ]; then
            has_tag "$desc" "$tag_pattern" || continue
        fi

        # Append to result buffer (do not echo here to avoid recursion)
        result+="${level}|${name}|${cmd}|${desc}"$'\n'
    done < <(merge_configs)

    # Restore the previous nocasematch state
    [ "$_nocase_was" -eq 0 ] && shopt -u nocasematch

    # Cache result (store the constructed string, avoid calling get_menu_options again)
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -z "$filter_query" ] && [ -z "$tag_filter" ] && [ -f "$config_path" ]; then
        cached_menu_options="$result"
        last_config_mtime=$(get_file_mtime "$config_path")
        last_config_level="$current_level"
        last_config_stack="$current_stack_key"
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
    local term_width="${TPUT_COLS:-80}"

    # Not every SSH client delivers SIGWINCH on a resize — poll the width from
    # time to time so the menu still adapts (one fork every 20 redraws).
    _redraw_counter=$(( _redraw_counter + 1 ))
    if [ "$_redraw_counter" -ge 20 ]; then
        _redraw_counter=0
        local _new_cols
        _new_cols=$(tput cols 2>/dev/null || true)
        if [ -n "$_new_cols" ] && [ "$_new_cols" != "$TPUT_COLS" ]; then
            TPUT_COLS="$_new_cols"
            _LAST_COL_WIDTH=0
        fi
        term_width="${TPUT_COLS:-80}"
    fi

    # ── Header ───────────────────────────────────────────────────────
    local mode_indicator="[${active_mode}]"
    if [ "$active_mode" = "global" ] && [ -f "$config_path" ]; then
        local _bn="${config_path##*/}"
        local _pname="${_bn##.tasks}"; _pname="${_pname#.}"
        [ -n "$_pname" ] && mode_indicator="[${_pname}]"
    fi
    fit_to_width "════ Shell Menu Runner ${VERSION} ${mode_indicator} ════" "$term_width"
    echo -e "${COLOR_HEAD}${FIT_TEXT}${COLOR_RESET}${_EL}"

    # Context line (git branch, hostname, env) — empty string = no line
    if [ -n "${_CTX_LINE:-}" ]; then
        display_width "${_CTX_LINE_PLAIN:-$_CTX_LINE}"
        if [ "$DISPLAY_WIDTH" -le "$term_width" ]; then
            echo -e "${_CTX_LINE}${_EL}"
        else
            fit_to_width "${_CTX_LINE_PLAIN:-$_CTX_LINE}" "$term_width"
            echo -e "${COLOR_DIM}${FIT_TEXT}${COLOR_RESET}${_EL}"
        fi
    fi

    if [ "$current_level" -gt 0 ]; then
        local _bc=""
        for _bname in "${history_name_stack[@]}"; do _bc="${_bc}${_bname} > "; done
        fit_to_width "${_bc%> }" "$term_width"
        echo -e "${COLOR_DIM}${FIT_TEXT}${COLOR_RESET}${_EL}"
    fi
    if [ -n "$filter_query" ]; then
        fit_to_width "📎 Filter: $filter_query" "$term_width"
        echo -e "${COLOR_INFO}${FIT_TEXT}${COLOR_RESET}${_EL}"
    fi
    if [ -n "$tag_filter" ]; then
        fit_to_width "🏷  Tag: $tag_filter" "$term_width"
        echo -e "${COLOR_INFO}${FIT_TEXT}${COLOR_RESET}${_EL}"
    fi
    echo -e "${_EL}"

    # ── Empty state ──────────────────────────────────────────────────
    local total=${#menu_options[@]}
    if [ "$total" -eq 0 ]; then
        fit_to_width "No tasks found. Press 'e' to edit config or '?' for help." "$term_width"
        echo -e "${COLOR_DIM}${FIT_TEXT}${COLOR_RESET}${_EL}"
        [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
        return
    fi

    # ── Layout ───────────────────────────────────────────────────────
    calculate_layout "$total"
    local rows=$_layout_rows cols=$_layout_cols
    local col_width=$(( term_width / cols ))
    local inner=$(( col_width - 4 ))
    [ "$inner" -lt 1 ] && inner=1
    local name_max=$(( inner - 4 ))
    [ "$name_max" -lt 1 ] && name_max=1

    # The cached name fields are only valid for the current column width
    if [ "$_name_field_cache_key" != "$name_max" ]; then
        _name_field_cache=()
        _name_field_cache_key="$name_max"
    fi

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
            split_task_line "${menu_options[$idx]}"
            _lvl="$_f_level"; _name="$_f_name"; _cmd="$_f_cmd"; _desc="$_f_desc"

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

            # Name field: exactly $name_max terminal columns.
            # fit_to_width counts wide characters (CJK/emoji = 2 columns) and
            # truncates without splitting a UTF-8 character — otherwise the
            # content line overflows the box border and the terminal wraps.
            #
            # The result is cached per menu index: the field only changes when
            # the menu or the terminal width changes, and measuring the width
            # of every entry on every redraw is far too slow.
            local _padded
            if [ -n "${_name_field_cache[idx]:+set}" ]; then
                _padded="${_name_field_cache[idx]}"
            else
                fit_to_width "$_name" "$name_max"
                _padded="$FIT_TEXT"
                _name_field_cache[idx]="$FIT_TEXT"
            fi

            content_line+="${border_color}│${COLOR_RESET}${_hotkey_pfx}${text_color}${marker}${_padded}${COLOR_RESET} ${border_color}│${COLOR_RESET}"
        done

        echo -e "${top_line}${_EL}"
        echo -e "${content_line}${_EL}"
        echo -e "${bot_line}${_EL}"
    done

    # ── Footer hints (width-adaptive to prevent wrapping) ───────────
    echo -e "${_EL}"
    local _nav_lr=""; [ "$cols" -gt 1 ] && _nav_lr=" ←→ h/l"
    local _hint_full="[↑↓${_nav_lr}] Navigate | [Enter] Execute | [/] Search | [Space] Multi | [?] Help"
    local _hint_mid="[↑↓←→] Nav | [Enter] Run | [/] Search | [?] Help"
    local _hint_min="[↑↓←→] [Enter] [/] [?]"
    # Pick the most detailed hint that still fits into the terminal width.
    local _hint="$_hint_min"
    display_width "$_hint_mid"
    [ "$DISPLAY_WIDTH" -le "$term_width" ] && _hint="$_hint_mid"
    display_width "$_hint_full"
    [ "$DISPLAY_WIDTH" -le "$term_width" ] && _hint="$_hint_full"
    echo -e "${COLOR_DIM}${_hint}${COLOR_RESET}${_EL}"

    [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
}

# ==============================================================================
#  MAIN INTERACTIVE LOOP WITH KEYBOARD HANDLING
# ==============================================================================

# Prints the task list — used in the non-interactive mode (no TTY) where no
# menu can be drawn, e.g. `ssh host "run"`.
print_task_list() {
    local total=${#menu_options[@]}
    echo ""
    echo -e "${COLOR_HEAD}Tasks ($total)${COLOR_RESET}"
    local i
    for (( i=0; i<total; i++ )); do
        split_task_line "${menu_options[$i]}"
        printf "  %2d)  %-24s  %s\n" "$(( i + 1 ))" "$_f_name" "$_f_desc"
    done
    echo ""
    echo -e "${COLOR_DIM}Type a task number or name to execute it (q = quit):${COLOR_RESET}"
    echo ""
}

# Lädt menu_options neu und aktualisiert calculate_layout.
_reload_menu() {
    IFS=$'\n' read -d '' -r -a menu_options < <(get_menu_options) || true
    calculate_layout "${#menu_options[@]}"
    # Die gepufferten Namensfelder gehören zum alten Menü → verwerfen
    _name_field_cache=()
    _name_field_cache_key=""
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
    # The terminal settings live in a global snapshot (03-terminal.sh) so the
    # submenus (file browser, config editor) can restore them after an editor
    # has run.
    restore_term() {
        restore_terminal_state
    }

    if [ "$is_interactive" -eq 1 ]; then
        _MENU_LOOP_ACTIVE=1
        save_terminal_state
        set_raw_mode
        trap 'restore_term; cleanup_wrapper; exit 130' INT TERM
    else
        _MENU_LOOP_ACTIVE=0
        # No TTY (SSH without -t, pipe): there is no menu to draw, so the task
        # list is printed once and the tasks are selected by number or name.
        print_task_list
    fi

    while true; do
        # Only redraw if needed (performance optimization).
        # Without a TTY the task list is printed instead of the menu.
        if [ "$redraw_needed" -eq 1 ] && [ "$is_interactive" -eq 1 ]; then
            draw_menu
            redraw_needed=0
        fi

        # ══════════════════════════════════════════════════════════════
        #  KEYBOARD INPUT HANDLING
        # ══════════════════════════════════════════════════════════════
        local key="" _rk_status=0 _read_failures=0
        if [ "$is_interactive" -eq 1 ]; then
            # Capture exit status separately: command substitution strips trailing \n,
            # so a real Enter (\n) correctly becomes "".  But if read_key_raw fails
            # (e.g. EINTR from a signal), we must NOT treat the empty result as Enter.
            key=$(read_key_raw); _rk_status=$?
            if [ "$_rk_status" -ne 0 ]; then
                # A single failed read is normal (terminal resize interrupts the
                # read) — but a permanently closed stdin would spin the loop at
                # 100% CPU and freeze the menu.  Give up after a few attempts.
                _read_failures=$(( _read_failures + 1 ))
                if [ "$_read_failures" -ge 3 ]; then
                    break
                fi
                redraw_needed=1
                continue
            fi
            _read_failures=0
        else
            # Non-interactive (SSH without -t, pipe, cron): the input is a
            # task number or a task name and is executed directly.
            read -r key || break
            [ -z "$key" ] && break
            case "$key" in
                q|Q) restore_term; exit 0 ;;
            esac
            cli_run_task "$key" || true
            continue
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
                    split_task_line "${menu_options[$selected_index]}"
                    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
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
                        split_task_line "${menu_options[$mi]}"
                        level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
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
                split_task_line "${menu_options[$selected_index]}"
                level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
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
                    split_task_line "${menu_options[$selected_index]}"
                    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
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

    # The menu-specific Ctrl+C handler is no longer the active one
    _MENU_LOOP_ACTIVE=0
}

# ==============================================================================
#  CONTEXT MENU
# ==============================================================================

context_menu() {
    # menu_options ist global stets aktuell — kein erneuter get_menu_options-Aufruf nötig
    local num=${#menu_options[@]}
    [ "$num" -eq 0 ] && return
    [ "$selected_index" -ge "$num" ] && return
    split_task_line "${menu_options[$selected_index]}"
    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
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
