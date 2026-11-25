# ==============================================================================
#  PROFILE MANAGEMENT
# ==============================================================================

find_local_config() {
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/$LOCAL_CONFIG" ]; then
            echo "$d/$LOCAL_CONFIG"
            return 0
        fi
        # Bash-String-Op statt dirname-Subshell
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    return 1
}

find_named_config() {
    local name="$1"
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/.tasks.$name" ]; then
            echo "$d/.tasks.$name"
            return 0
        fi
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    return 1
}

list_available_profiles() {
    local -a names=()
    local d="$PWD"
    while [ "$d" != "/" ]; do
        for f in "$d"/.tasks.*; do
            [ -f "$f" ] || continue
            local base
            base="${f##*/}"
            base="${base#.tasks.}"
            # "local" and "dev" are reserved overlay suffixes: they are merged
            # into the default config automatically (see detect_config_files)
            # and are therefore not separate profiles.
            [ "$base" = "local" ] && continue
            [ "$base" = "dev" ] && continue
            names+=("$base")
        done
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    local f
    for f in "$HOME"/.tasks.*; do
        [ -f "$f" ] || continue
        local base
        base="${f##*/}"
        base="${base#.tasks.}"
        [ "$base" = "local" ] && continue
        [ "$base" = "dev" ] && continue
        names+=("$base")
    done
    if [ ${#names[@]} -gt 0 ]; then
        printf "%s\n" "${names[@]}" | sort -u
    fi
}

init_profile() {
    local name="$1"
    [ -z "$name" ] && { echo "Error: profile name required"; return 1; }
    # Der Name landet im Dateinamen — Pfad-Traversal und Leerzeichen sind nicht
    # erlaubt (Format des Alias-Dateiformats "name=value" bzw. ".tasks.<name>").
    case "$name" in
        */*|*" "*) echo "Error: invalid profile name (no '/' or spaces)"; return 1 ;;
    esac

    local profile_file="$PWD/.tasks.$name"
    [ -f "$profile_file" ] && { echo "Profile $name already exists at $profile_file"; return 1; }

    echo "Creating profile: $name"
    local template
    template="$(cat << 'EOF'
# Profile: {NAME}
# Auto-generated task list for {NAME}

0|Task Name|command|Description here
0|Another Task|echo "Hello"|Runs a simple command
EOF
)"
    # Bash-String-Op statt sed -i (kein Fork, kein Escaping-Problem)
    template=${template//\{NAME\}/$name}
    printf '%s\n' "$template" > "$profile_file"

    echo "Profile created: $profile_file"
    echo "Edit with: ${EDITOR:-nano} $profile_file"
}

validate_config_file() {
    local profile_file="$1"
    local display_name="$2"

    if [ ! -f "$profile_file" ]; then
        error "Profile file not found: $profile_file"
        return 1
    fi

    echo "Validating profile: $display_name ($profile_file)"
    local errors=0
    local line_no=0
    local syntax_ok=true

    while IFS='|' read -r level name cmd desc extra || [ -n "$level" ]; do
        line_no=$((line_no + 1))
        # Tolerate CRLF line endings
        level="${level%$'\r'}"
        name="${name%$'\r'}"
        cmd="${cmd%$'\r'}"
        desc="${desc%$'\r'}"
        extra="${extra%$'\r'}"

        # Skip comments and empty lines
        [[ "$level" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$level" ]] && continue

        # Validate format
        if [ -z "$name" ] || [ -z "$cmd" ]; then
            echo "  Line $line_no: Invalid format (missing fields)"
            errors=$((errors + 1))
            syntax_ok=false
        fi

        # Das Level muss eine nicht-negative Zahl sein: das Menü überspringt
        # jede Zeile mit einem nicht-numerischen Level — der Task wäre
        # unsichtbar, die Validierung meldete aber "passed".
        if ! is_uint "$level"; then
            echo "  Line $line_no: Invalid level '$level' (must be a number)"
            errors=$((errors + 1))
            syntax_ok=false
        fi

        # The format uses "|" as the field separator — a command with a pipe
        # is cut off at the first separator.  Warning, because the
        # description may legitimately contain a pipe.
        if [ -n "$extra" ]; then
            echo "  Line $line_no: Warning - more than 4 fields"
            echo "            (a '|' in the command is not supported by the format)"
        fi
    done < "$profile_file"

    if [ "$syntax_ok" = true ]; then
        success "Profile validation passed: $display_name"
        return 0
    else
        error "Profile validation failed: $display_name ($errors errors)"
        return 1
    fi
}

# Escapes a string for a JSON string literal (backslash, quote, control chars).
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

list_profiles_all() {
    local mode="${1:-text}"
    local profiles_str
    profiles_str=$(list_available_profiles)

    if [ "$mode" = "json" ]; then
        # Auch ohne Profile wird gültiges JSON geliefert — "No profiles
        # found" konnte von einem JSON-Parser nicht gelesen werden.
        echo "{"
        echo "  \"profiles\": ["
        local first=1
        # Process-Substitution statt Here-String (kein temporäres File)
        if [ -n "$profiles_str" ]; then
            while IFS= read -r prof; do
                [ "$first" -eq 0 ] && echo ","
                first=0
                echo "    { \"name\": \"$(_json_escape "$prof")\" }"
            done < <(printf '%s\n' "$profiles_str")
        fi
        echo ""
        echo "  ]"
        echo "}"
    elif [ -z "$profiles_str" ]; then
        echo "No profiles found"
        return 0
    else
        echo "Available profiles:"
        echo ""
        while IFS= read -r prof; do
            echo "  • $prof"
        done < <(printf '%s\n' "$profiles_str")
    fi
    return 0
}

# ==============================================================================
#  PROFILE LOADING & VALIDATION
# ==============================================================================

load_profile_config() {
    local profile_name="$1"

    # Temporarily change active_mode and config_path
    local saved_mode="$active_mode"
    local saved_config_path="$config_path"

    # Lokale Profile zuerst (wie beim CLI-Aufruf "run <profil>"): das Profil
    # wird im aktuellen Verzeichnis und in allen übergeordneten Verzeichnissen
    # gesucht.  Vorher wurde ausschließlich $HOME/.tasks.<name> geprüft —
    # "run --across p1,p2 task" scheiterte dadurch für lokale Profile.
    local _found=""
    _found=$(find_named_config "$profile_name") || _found=""
    if [ -n "$_found" ]; then
        active_mode="local"
        config_path="$_found"
    elif [ -f "$HOME/.tasks.$profile_name" ]; then
        active_mode="global"
        config_path="$HOME/.tasks.$profile_name"
    else
        active_mode="$saved_mode"
        config_path="$saved_config_path"
        return 1
    fi

    # The task list comes from task_config_files — it has to be rebuilt for
    # the new profile, otherwise the task would be searched in the config of
    # the previous one.
    detect_config_files

    return 0
}

validate_profile() {
    local name="$1"
    [ -z "$name" ] && { echo "Error: profile name required"; return 1; }

    local profile_file
    profile_file=$(find_named_config "$name") || profile_file="$HOME/.tasks.$name"

    validate_config_file "$profile_file" "$name"
}

select_profile_menu() {
    local -a profiles=()
    local -a filtered_profiles=()
    local -a display_profiles=()
    IFS=$'\n' read -r -d '' -a profiles < <(list_available_profiles && printf '\0') || true
    local num=${#profiles[@]}
    [ "$num" -eq 0 ] && return 1
    [ ! -t 0 ] && return 1

    local page=0
    local per_page=9
    local filter_pattern=""
    local filter_active=0
    
    while true; do
        # Apply filter if active
        if [ "$filter_active" -eq 1 ] && [ -n "$filter_pattern" ]; then
            filtered_profiles=()
            for prof in "${profiles[@]}"; do
                if [[ "$prof" == *"$filter_pattern"* ]]; then
                    filtered_profiles+=("$prof")
                fi
            done
            # "[@]+" keeps an empty array safe under `set -u` on Bash 3.2 —
            # without it a filter without a match aborted the whole runner.
            display_profiles=("${filtered_profiles[@]+"${filtered_profiles[@]}"}")
            display_num=${#display_profiles[@]}
        else
            display_profiles=("${profiles[@]}")
            display_num=${#display_profiles[@]}
        fi
        
        # Reset page if out of bounds
        local max_pages=$(( (display_num + per_page - 1) / per_page ))
        [ "$page" -ge "$max_pages" ] && page=$((max_pages - 1))
        [ "$page" -lt 0 ] && page=0
        
        clear
        echo -e "${COLOR_HEAD}Profiles${COLOR_RESET}"
        if [ "$filter_active" -eq 1 ]; then
            echo -e "${COLOR_INFO}Filter: ${filter_pattern}_${COLOR_RESET} (ESC to clear)"
        fi
        echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
        
        local start=$((page * per_page))
        local end=$((start + per_page))
        [ "$end" -gt "$display_num" ] && end="$display_num"
        
        if [ "$display_num" -eq 0 ]; then
            echo -e "${COLOR_DIM}No profiles match filter${COLOR_RESET}"
        else
            local i
            for (( i=start; i<end; i++ )); do
                local idx=$((i - start + 1))
                echo "${idx}) ${display_profiles[$i]}"
            done
        fi
        
        echo ""
        if [ "$display_num" -gt "$per_page" ]; then
            echo -e "${COLOR_DIM}Page $((page + 1))/$max_pages  "
            [ "$page" -gt 0 ] && echo -n "[p]revious " || echo -n "           "
            [ "$end" -lt "$display_num" ] && echo "[n]ext"
        fi
        echo "[/] filter  0) Cancel"
        echo ""
        choice=$(read_key) || return 1
        
        case "$choice" in
            [1-9])
                local pick=$((start + choice - 1))
                [ "$pick" -ge "$end" ] && continue
                [ "$display_num" -eq 0 ] && continue
                local profile="${display_profiles[$pick]}"
                if found=$(find_named_config "$profile"); then
                    active_mode="local"
                    config_path="$found"
                    return 0
                fi
                if [ -f "$HOME/.tasks.$profile" ]; then
                    active_mode="global"
                    config_path="$HOME/.tasks.$profile"
                    return 0
                fi
                ;;
            0) return 1 ;;
            q|Q) return 1 ;;
            # if/else instead of "&&": a false condition would return 1 from
            # the case and abort the script (set -e).
            p) if [ "$page" -gt 0 ]; then page=$((page - 1)); fi ;;
            n) if [ "$end" -lt "$display_num" ]; then page=$((page + 1)); fi ;;
            /) filter_active=1; filter_pattern=""; 
               while true; do
                   clear
                   echo -e "${COLOR_HEAD}Filter Profiles${COLOR_RESET}"
                   echo -e "${COLOR_DIM}Type to filter, Enter to apply, ESC to cancel${COLOR_RESET}"
                   echo ""
                   echo -n "Filter: ${filter_pattern}_"
                   k=$(read_key) || { filter_active=0; filter_pattern=""; break; }
                   case "$k" in
                       $'\x1b') filter_active=0; filter_pattern=""; break ;;
                       $'\x7f'|$'\b') filter_pattern="${filter_pattern%?}" ;;
                       $'\r'|$'\n'|"") break ;;
                       *) if [[ "$k" =~ [[:print:]] ]]; then filter_pattern="${filter_pattern}${k}"; fi ;;
                   esac
               done
               page=0
               ;;
            $'\x1b') 
                if [ "$filter_active" -eq 1 ]; then
                    filter_active=0
                    filter_pattern=""
                    page=0
                else
                    return 1
                fi
                ;;
        esac
    done
}
