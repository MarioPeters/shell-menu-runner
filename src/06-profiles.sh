# ==============================================================================
#  PROFILE MANAGEMENT
# ==============================================================================

find_local_config() {
    set +e
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/$LOCAL_CONFIG" ]; then
            echo "$d/$LOCAL_CONFIG"
            set -e
            return 0
        fi
        # Bash-String-Op statt dirname-Subshell
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    set -e
    return 1
}

find_named_config() {
    local name="$1"
    set +e
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/.tasks.$name" ]; then
            echo "$d/.tasks.$name"
            set -e
            return 0
        fi
        d="${d%/*}"
        [ -z "$d" ] && d="/"
    done
    set -e
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
        names+=("${base#.tasks.}")
    done
    if [ ${#names[@]} -gt 0 ]; then
        printf "%s\n" "${names[@]}" | sort -u
    fi
}

init_profile() {
    local name="$1"
    [ -z "$name" ] && { echo "Error: profile name required"; return 1; }
    
    local profile_file="$PWD/.tasks.$name"
    [ -f "$profile_file" ] && { echo "Profile $name already exists at $profile_file"; return 1; }
    
    echo "Creating profile: $name"
    cat > "$profile_file" << 'EOF'
# Profile: {NAME}
# Auto-generated task list for {NAME}

0|Task Name|command|Description here
0|Another Task|echo "Hello"|Runs a simple command
EOF
    
    sed -i '' "s/{NAME}/$name/g" "$profile_file" 2>/dev/null || sed -i "s/{NAME}/$name/g" "$profile_file"
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

    while IFS='|' read -r level name cmd desc || [ -n "$level" ]; do
        line_no=$((line_no + 1))
        
        # Skip comments and empty lines
        [[ "$level" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$level" ]] && continue
        
        # Validate format
        if [ -z "$name" ] || [ -z "$cmd" ]; then
            echo "  Line $line_no: Invalid format (missing fields)"
            errors=$((errors + 1))
            syntax_ok=false
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

list_profiles_all() {
    local mode="${1:-text}"
    local profiles_str
    profiles_str=$(list_available_profiles)
    
    if [ -z "$profiles_str" ]; then
        echo "No profiles found"
        return 0
    fi
    
    if [ "$mode" = "json" ]; then
        echo "{"
        echo "  \"profiles\": ["
        local first=1
        while IFS= read -r prof; do
            [ "$first" -eq 0 ] && echo ","
            first=0
            echo "    { \"name\": \"$prof\" }"
        done <<< "$profiles_str"
        echo ""
        echo "  ]"
        echo "}"
    else
        echo "Available profiles:"
        echo ""
        while IFS= read -r prof; do
            echo "  • $prof"
        done <<< "$profiles_str"
    fi
}

# ==============================================================================
#  PROFILE LOADING & VALIDATION
# ==============================================================================

load_profile_config() {
    local profile_name="$1"
    
    # Temporarily change active_mode and config_path
    local saved_mode="$active_mode"
    local saved_config_path="$config_path"
    
    active_mode="global"
    config_path="$HOME/.tasks.$profile_name"
    
    if [ ! -f "$config_path" ]; then
        active_mode="$saved_mode"
        config_path="$saved_config_path"
        return 1
    fi
    
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
            local display_profiles=("${filtered_profiles[@]}")
            local display_num=${#display_profiles[@]}
        else
            local display_profiles=("${profiles[@]}")
            local display_num=${#display_profiles[@]}
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
        echo -e "${COLOR_DIM}───────────────────────────────────────────────────────────────${COLOR_RESET}"
        
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
            p) [ "$page" -gt 0 ] && page=$((page - 1)) ;;
            n) [ "$end" -lt "$display_num" ] && page=$((page + 1)) ;;
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
                       *) [[ "$k" =~ [[:print:]] ]] && filter_pattern="${filter_pattern}${k}" ;;
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
