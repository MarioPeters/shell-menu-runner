# ==============================================================================
#  UI RENDERING & KEYBOARD INPUT HANDLING
# ==============================================================================

# Terminal capabilities are initialized in 03-terminal.sh via init_terminal_capabilities

# Cache for the padded name fields of the menu (index → padded text).
# Measuring the display width of every entry is expensive, and the fields
# only change when the menu or the terminal width changes.
declare -a _name_field_cache=()
_name_field_cache_key=""

# Result of the last _build_menu_options() call and its cache copy.
#
# Both are arrays: the cache only works when the menu is built in the
# current shell — a process substitution would discard the cache variables
# when the subshell exits.
MENU_RESULT_ARRAY=()
_cached_menu_array=()

# Cached header line (see draw_menu)
_HEADER_CACHE_KEY=""
_HEADER_CACHE_TEXT=""

# Change stamp of the whole config set (config + overlays).
#
# The overlays (.tasks.local, .tasks.dev, .tasks.<profile>.local) are part
# of the menu — a change in one of them must invalidate the cache, otherwise
# new tasks stay invisible until the next restart.
_menu_config_stamp() {
    get_files_stamp "$config_path" "${task_config_files[@]+"${task_config_files[@]}"}"
}

# Verwirft den Menü-Cache.
#
# Nötig, wenn sich die Config geändert hat, ohne dass der Änderungs-Stempel
# (mtime:size) das erkennen kann: eine Bearbeitung mit gleicher Größe in
# derselben Sekunde blieb sonst unsichtbar.
invalidate_menu_cache() {
    last_config_stamp=""
    _menu_cache_key=""
    _menu_cache_config_path=""
    return 0
}

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
EOF
    if [ "${RUN_MINIMAL:-0}" != "1" ]; then
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

Features:
  /               Search/filter tasks
  #               Filter by tags
  g               Toggle local/global config
  p               Switch profile
  s               Settings menu
  e               Edit config
  f               File browser
  *               Toggle favorite
  c               Copy command to clipboard
  r               Show favorite tasks
  R               Show recent tasks
  L               Show log files
  !               Show history
  a               Alias editor
  ?               This help

Profiles:
  run [profile]   Load specific profile
  run --list      List all tasks
  run --run <q>   Execute a task non-interactively
  run --init      Initialize new .tasks config
EOF
    else
        # Der Minimal-Build schaltet die erweiterten Tasten ab — die
        # verbleibenden werden hier trotzdem aufgelistet, damit die Hilfe
        # nicht mehr Tasten verschweigt als es gibt.
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

Features (minimal build):
  g               Toggle local/global config
  p               Switch profile
  s               Settings menu
  c               Copy command to clipboard
  ?               This help

Profiles:
  run [profile]   Load specific profile
  run --list      List all tasks
  run --run <q>   Execute a task non-interactively
  run --init      Initialize new .tasks config
EOF
    fi

    echo ""
    echo -e "${COLOR_DIM}Press any key to continue...${COLOR_RESET}"
    consume_keypress
}

get_menu_options() {
    _build_menu_options
    if [ ${#MENU_RESULT_ARRAY[@]} -gt 0 ]; then
        printf "%s\n" "${MENU_RESULT_ARRAY[@]}"
    fi
    return 0
}

# Normalizes selected_index after every key press: the selection must stay
# inside the current menu grid.
#
# An empty menu (cnt == 0) must reset to 0 — the wrap formula "(cnt - 1)"
# would otherwise leave the index stuck at -1, and the next "*" / "c" / " "
# key would hit "menu_options[-1]": on Bash 3.2 (macOS default) that is a
# fatal "bad array subscript" that killed the whole runner.
clamp_selected_index() {
    local _cnt=${#menu_options[@]}
    if [ "$_cnt" -eq 0 ]; then
        selected_index=0
    elif [ "$selected_index" -lt 0 ]; then
        selected_index=$((_cnt - 1))
    elif [ "$selected_index" -ge "$_cnt" ]; then
        selected_index=0
    fi
    return 0
}

# Builds the menu list for the current level/filters and stores it in
# MENU_RESULT_ARRAY.
#
# The result is returned in a global array instead of on stdout: a caller
# that reads the result via a process substitution runs in a subshell, and
# every cache variable set there is lost when it exits — the cache never hit
# and the whole config was re-read and re-parsed for every menu rebuild.
_build_menu_options() {
    local current_stack_key=""
    if [ "$current_level" -gt 0 ]; then
        current_stack_key="${history_name_stack[*]}"
    fi

    # Cache check for performance.  The key contains every input the result
    # depends on (level, breadcrumb, filters) — the change stamp of the
    # config files detects modifications.  The config path is checked
    # separately: two configs with the same stamp (mtime:size) would
    # otherwise be indistinguishable and the menu would keep showing the
    # tasks of the previous config after a switch ("g" / "p").
    local _cache_key="${current_level}|${current_stack_key}|${filter_query}|${tag_filter}"
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ ${#_cached_menu_array[@]} -gt 0 ] \
       && [ "$_cache_key" = "$_menu_cache_key" ] \
       && [ "$config_path" = "$_menu_cache_config_path" ]; then
        local _stamp
        _stamp=$(_menu_config_stamp)
        if [ "$_stamp" = "$last_config_stamp" ]; then
            MENU_RESULT_ARRAY=("${_cached_menu_array[@]}")
            return 0
        fi
    fi

    # Build menu options
    local search_pattern=""
    local tag_pattern=""

    if [ -n "$filter_query" ]; then
        # Kein tr-Fork: die Gross-/Kleinschreibung wird unten über
        # "shopt -s nocasematch" erledigt (der Vergleich selbst ist literal).
        search_pattern="$filter_query"
    fi

    if [ -n "$tag_filter" ]; then
        tag_pattern="$tag_filter"
    fi

    local -a _result_arr=()
    local -a active_parents=()
    local k i
    local _haystack=""

    # nocasematch makes the filter comparison case-insensitive — that replaces
    # a `tr` fork per config line.  The previous shell option is restored below.
    local _nocase_was=0
    shopt -q nocasematch && _nocase_was=1
    [ -n "$search_pattern" ] && shopt -s nocasematch

    # Process substitution: Config-Inhalt direkt streamen — kein all_output-String-Kopie im Speicher
    while IFS= read -r line || [ -n "$line" ]; do
        # Tolerate CRLF line endings — a trailing \r corrupts the box layout
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        is_meta_task_line "$line" && continue

        split_task_line "$line"
        level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
        [ -z "$name" ] && continue
        # The level must be a number (a case pattern is much cheaper than a
        # regex match)
        case "$level" in
            ''|*[!0-9]*) continue ;;
        esac

        # Update active_parents tracker for positional submenus.
        # Only the levels up to current_level are relevant — resetting all 20
        # levels per config line cost 40,000 assignments for 2000 tasks.
        for ((k = level; k <= current_level; k++)); do
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

        # Search filtering — literal, case-insensitive substring match.
        # A regex would break on characters like "(" (the menu would silently
        # become empty) and "Build." would match "BuildX".
        if [ -n "$search_pattern" ]; then
            _haystack="$name $desc"
            [[ "$_haystack" != *"$search_pattern"* ]] && continue
        fi

        # Tag filtering
        if [ -n "$tag_pattern" ]; then
            has_tag "$desc" "$tag_pattern" || continue
        fi

        # Append to result buffer (do not echo here to avoid recursion)
        _result_arr+=("${level}|${name}|${cmd}|${desc}")
    done < <(merge_configs)

    # Restore the previous nocasematch state
    [ "$_nocase_was" -eq 0 ] && shopt -u nocasematch

    # Cache result (store the parsed list, avoid re-parsing the config)
    if [ "$RUN_CACHE_PROFILES" -eq 1 ] && [ -f "$config_path" ]; then
        _cached_menu_array=("${_result_arr[@]+"${_result_arr[@]}"}")
        _menu_cache_key="$_cache_key"
        _menu_cache_config_path="$config_path"
        last_config_stamp=$(_menu_config_stamp)
    fi

    MENU_RESULT_ARRAY=("${_result_arr[@]+"${_result_arr[@]}"}")
    return 0
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
        _detect_term_size
        if [ "$_TERM_COLS" -ge 1 ] && [ "$_TERM_COLS" != "$TPUT_COLS" ]; then
            TPUT_COLS="$_TERM_COLS"
            _LAST_COL_WIDTH=0
        fi
        if [ "$_TERM_LINES" -ge 1 ]; then TPUT_LINES="$_TERM_LINES"; fi
        term_width="${TPUT_COLS:-80}"
    fi

    # ── Header ───────────────────────────────────────────────────────
    local mode_indicator="[${active_mode}]"
    if [ "$active_mode" = "global" ] && [ -f "$config_path" ]; then
        local _bn="${config_path##*/}"
        local _pname="${_bn##.tasks}"; _pname="${_pname#.}"
        [ -n "$_pname" ] && mode_indicator="[${_pname}]"
    fi
    # The header text only changes with the version, the mode and the
    # terminal width — the fitted result is cached (the UTF-8 decoder
    # needs ~4 ms for the box-drawing characters).
    local _header_text="════ Shell Menu Runner ${VERSION} ${mode_indicator} ════"
    local _header_key="${_header_text}|${term_width}"
    if [ "${_HEADER_CACHE_KEY:-}" != "$_header_key" ]; then
        fit_to_width "$_header_text" "$term_width"
        _HEADER_CACHE_TEXT="$FIT_TEXT"
        _HEADER_CACHE_KEY="$_header_key"
    fi
    FIT_TEXT="$_HEADER_CACHE_TEXT"
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
        return 0
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

    # ── Viewport ─────────────────────────────────────────────────────
    # Only the rows that fit on the screen are drawn.  Without the viewport a
    # config with 2000 tasks produced 3000 lines / 326 KB per redraw — the
    # menu flooded the terminal and every keypress cost ~200 ms.
    # The grid index (idx = r + c * rows) is unchanged, so the navigation
    # (up/down = ±1, left/right = ±rows) keeps working.
    local visible_rows="$rows"
    local first_row=0
    local _term_lines="${TPUT_LINES:-24}"
    is_uint "$_term_lines" && [ "$_term_lines" -ge 6 ] || _term_lines=24
    # Overhead: title + context + breadcrumb + filter + blank + footer
    local _chrome=9
    local _max_rows=$(( (_term_lines - _chrome) / 3 ))
    [ "$_max_rows" -lt 1 ] && _max_rows=1
    if [ "$rows" -gt "$_max_rows" ]; then
        visible_rows="$_max_rows"
        # Keep the selected entry visible: the row of an entry is idx % rows
        local _sel_row=$(( selected_index % rows ))
        first_row=$(( _sel_row - visible_rows / 2 ))
        [ "$first_row" -lt 0 ] && first_row=0
        [ "$first_row" -gt $(( rows - visible_rows )) ] && first_row=$(( rows - visible_rows ))
    fi

    # ── Grid rendering (3 lines per item, separate boxes) ───────────
    local r c idx
    local gap="  "   # 2-space gap between columns; added BEFORE column (not after)

    for (( r=first_row; r<first_row + visible_rows; r++ )); do
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
    # The hint texts are constant (two variants, depending on the column
    # count) — their column width is measured once and then cached.
    if [ "$_HINT_WIDTHS_KEY" != "$_hint_full" ]; then
        display_width "$_hint_mid";  _HINT_MID_WIDTH="$DISPLAY_WIDTH"
        display_width "$_hint_full"; _HINT_FULL_WIDTH="$DISPLAY_WIDTH"
        _HINT_WIDTHS_KEY="$_hint_full"
    fi
    local _hint="$_hint_min"
    [ "$_HINT_MID_WIDTH" -le "$term_width" ] && _hint="$_hint_mid"
    [ "$_HINT_FULL_WIDTH" -le "$term_width" ] && _hint="$_hint_full"
    # Scroll indicator — only shown when the viewport is active
    if [ "$visible_rows" -lt "$rows" ]; then
        local _pos=$(( first_row + 1 ))
        local _end=$(( first_row + visible_rows ))
        _hint="${_hint} | ${_pos}-${_end}/${rows}"
    fi
    echo -e "${COLOR_DIM}${_hint}${COLOR_RESET}${_EL}"

    [ "$HAS_TPUT" -eq 1 ] && [ -n "$TPUT_ED" ] && echo -ne "$TPUT_ED"
    return 0
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
    # In-process: the cache of _build_menu_options() only survives when the
    # function runs in the current shell.
    _build_menu_options
    menu_options=("${MENU_RESULT_ARRAY[@]+"${MENU_RESULT_ARRAY[@]}"}")
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
    # has run.  restore_term() is defined on module level (03-terminal.sh) —
    # the INT trap of execute_task also runs outside the interactive loop.

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
        # The minimal build has no advanced features (search, tags,
        # favorites, history, logs, alias editor, browser, config editor).
        local _key="$key"
        if [ "${RUN_MINIMAL:-0}" = "1" ]; then
            case "$key" in
                "/" | "#" | "*" | "r" | "R" | "L" | "!" | "a" | "A" | "e" | "E" | "f" | "F")
                    _key="__disabled__"
                    ;;
            esac
        fi
        case "$_key" in
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
                # Guard auch für selected_index == -1 (leeres Menü + "↑"
                # lässt den Index bei -1 hängen): ohne Guard wäre
                # "multi_select_map[-1]" unter Bash 3.2 ein fataler
                # "bad array subscript".
                if [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "${#menu_options[@]}" ]; then
                    if [[ -n "${multi_select_map[$selected_index]:-}" ]]; then
                        unset 'multi_select_map[$selected_index]'
                    else
                        multi_select_map["$selected_index"]=1
                    fi
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
                # Die Filter gehören zur bisherigen Config: ohne das Reset
                # blieb der Tag-Filter aktiv und das neue Menü war leer
                # ("No tasks found"), ohne einen sichtbaren Grund.
                filter_query=""
                tag_filter=""
                _reinit_menu
                num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "p"|"P") # Profile selection
                restore_term
                if select_profile_menu; then
                    selected_index=0
                    current_level=0
                    history_name_stack=("Main")
                    # Siehe Taste "g": der Filter gilt der alten Config.
                    filter_query=""
                    tag_filter=""
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
                    local -a multi_keys=()
                    IFS=$'\n' read -r -d '' -a multi_keys < <(printf "%s\n" "${!multi_select_map[@]}" | sort -n && printf '\0') || true
                    # Parallel execution of the marked tasks (opt-in via
                    # RUN_PARALLEL_MULTI=1) — otherwise sequential.
                    if [ "${RUN_PARALLEL_MULTI:-0}" = "1" ] && [ "${#multi_keys[@]}" -gt 1 ]; then
                        execute_tasks_parallel
                    else
                        for mi in "${multi_keys[@]}"; do
                            split_task_line "${menu_options[$mi]}"
                            level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                            [ "$cmd" == "EXIT" ] && continue
                            [ "$cmd" == "SUB" ] && continue
                            [ "$cmd" == "BACK" ] && continue
                            execute_task "$cmd" "$name" "$desc"
                        done
                    fi
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
                # The config file may have changed — reload the menu, otherwise
                # new or edited tasks only appear after a restart.
                # The cache is invalidated explicitly: the change stamp
                # (mtime:size) only detects an edit when mtime or size
                # change — an edit of the same size within the same second
                # stayed invisible.
                invalidate_menu_cache
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "f"|"F") run_with_term_paused file_browser; redraw_needed=1;;
            "#") # Tag filter
                run_with_term_paused show_tag_menu
                _reload_menu; num=${#menu_options[@]}; rows=$_layout_rows; cols=$_layout_cols
                redraw_needed=1;;
            "*") # Toggle favorite
                # Internal operation, no restore needed
                # "-ge 0": siehe Space-Handler — ein leeres Menü mit "↑"
                # ließ selected_index bei -1 hängen und "menu_options[-1]"
                # brach unter Bash 3.2 den ganzen Runner ab.
                if [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "$num" ]; then
                    split_task_line "${menu_options[$selected_index]}"
                    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                    toggle_favorite "$name"
                fi
                redraw_needed=1;;
            "r") run_with_term_paused show_favorites; redraw_needed=1;;
            "R") run_with_term_paused show_recent; redraw_needed=1;;
            "L") run_with_term_paused show_logs; redraw_needed=1;;
            "c"|"C") # Copy the selected command to the clipboard
                if [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "$num" ]; then
                    split_task_line "${menu_options[$selected_index]}"
                    level="$_f_level"; name="$_f_name"; cmd="$_f_cmd"; desc="$_f_desc"
                    copy_to_clipboard "$cmd"
                fi
                redraw_needed=1;;
            "q"|"Q") restore_term; clear; exit 0;;
        esac

        # Wrap around selection index (also resets on an empty menu — an
        # index of -1 would kill the runner with a "bad array subscript"
        # on Bash 3.2, see comment on clamp_selected_index)
        clamp_selected_index
    done

    # The menu-specific Ctrl+C handler is no longer the active one
    _MENU_LOOP_ACTIVE=0
}
