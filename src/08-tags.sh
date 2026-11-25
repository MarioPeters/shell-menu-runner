# ==============================================================================
#  TAG SYSTEM
# ==============================================================================

# Extracts all #tags from a description.
# Result: EXTRACTED_TAG_LIST (array).
#
# An array instead of a space separated string: the string variant needed word
# splitting, and word splitting depends on the current IFS — a prefix
# assignment like `IFS=$'\n' read ... < <(get_all_tags)` leaks into the
# process substitution subshell and turned all tags into a single one.
EXTRACTED_TAG_LIST=()
extract_tags() {
    local desc="$1"
    EXTRACTED_TAG_LIST=()
    # Bash-Regex statt echo|grep|tr (3 externe Prozesse gespart)
    local rest="$desc"
    while [[ "$rest" =~ (#[a-zA-Z0-9_-]+) ]]; do
        local _tag="${BASH_REMATCH[1]}"
        EXTRACTED_TAG_LIST+=("$_tag")
        # SC2295: BASH_REMATCH in ${#} als Pattern muss über Variable referenziert werden
        rest="${rest#*"$_tag"}"
    done
}

has_tag() {
    local desc="$1"
    local tag="$2"
    # Exact token match: "#dev" must not match "#developer" and "#de" must not
    # match "#dev".  The tag is matched literally (it may only contain
    # [a-zA-Z0-9_-]), surrounded by non-tag characters or string boundaries.
    local needle="${tag#\#}"
    case "$needle" in
        ''|*[!a-zA-Z0-9_-]*) return 1 ;;
    esac
    local rest="$desc"
    while :; do
        case "$rest" in
            *"#$needle")
                # The match must not be followed by another tag character
                local after="${rest#*\#"$needle"}"
                case "$after" in
                    [a-zA-Z0-9_-]*) ;;
                    *) return 0 ;;
                esac
                rest="$after"
                ;;
            *) return 1 ;;
        esac
    done
}

get_all_tags() {
    local -a tags=()
    local tag _tag_line
    # Default-IFS hart setzen: die Funktion läuft in einem
    # Process-Substitution-Subshell, in den der IFS des Aufrufers leakt.
    local IFS=$' \t\n'
    # Process-Substitution: kein all_output-String im Speicher
    # `|| [ -n "$_tag_line" ]` → die letzte Zeile ohne Newline wird mit gelesen
    while read -r _tag_line || [ -n "$_tag_line" ]; do
        # Tolerate CRLF line endings
        _tag_line="${_tag_line%$'\r'}"
        split_task_line "$_tag_line"
        extract_tags "$_f_desc"
        # Leeres Array nicht expandieren (Bash 3.2 + set -u → unbound variable)
        if [ ${#EXTRACTED_TAG_LIST[@]} -gt 0 ]; then
            for tag in "${EXTRACTED_TAG_LIST[@]}"; do
                tags+=("$tag")
            done
        fi
    done < <(
        if [ "${#task_config_files[@]}" -gt 0 ]; then
            cat "${task_config_files[@]}" 2>/dev/null || true
        elif [ -f "$config_path" ]; then
            cat "$config_path"
        fi
    )
    # Unique sort — leeres Array würde in Bash 3.2 "unbound variable" werfen
    [ ${#tags[@]} -eq 0 ] && return 0
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
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
    
    echo "0) ${COLOR_SEL}[All Tasks]${COLOR_RESET}"
    local i
    for (( i=0; i<num_tags; i++ )); do
        if [ "$tag_filter" == "${all_tags[$i]}" ]; then
            printf "%d) ${COLOR_SEL}✓ %s${COLOR_RESET}\n" "$((i+1))" "${all_tags[$i]}"
        else
            printf "%d) %s\n" "$((i+1))" "${all_tags[$i]}"
        fi
    done
    
    echo -e "${COLOR_DIM}$(separator_line)${COLOR_RESET}"
    # Two digit selection: with more than nine tags the single digit keys
    # could not reach the entries 10+ — they were displayed but not selectable.
    if [ "$num_tags" -gt 9 ]; then
        echo "[1-9] [0-9+Enter] Filter [q]uit"
    else
        echo "[1-9] Filter [q]uit"
    fi
    
    # Buffered numeric input: a single digit selects immediately, a second
    # digit extends the number (10+), Enter confirms.
    local _buf=""
    while true; do
        key=$(read_key) || break
        case "$key" in
            "0")
                if [ -n "$_buf" ]; then
                    # "0" as the first digit is not a valid entry (0 = All)
                    _buf=""
                    continue
                fi
                tag_filter=""
                echo -e "${COLOR_SEL}✔ Showing all tasks${COLOR_RESET}"
                sleep 0.5
                break
                ;;
            [1-9])
                if [ -n "$_buf" ]; then
                    # Second digit: 10..99
                    local _idx=$(( _buf * 10 + key - 1 ))
                    _buf=""
                    if [ "$_idx" -lt "$num_tags" ]; then
                        tag_filter="${all_tags[$_idx]}"
                        echo -e "${COLOR_SEL}✔ Filtering by ${tag_filter}${COLOR_RESET}"
                        sleep 0.5
                        break
                    fi
                    continue
                fi
                # First digit: could be 1..9 or the start of a two digit number
                if [ "$num_tags" -gt 9 ]; then
                    _buf="$key"
                    # A short timeout collects the second digit
                    # 0,5 s Zeitfenster fuer die zweite Ziffer (10+)
                    _second=$(read_key_optional 5)
                    if [ -n "$_second" ] && [[ "$_second" =~ ^[0-9]$ ]]; then
                        local _idx2=$(( key * 10 + _second - 1 ))
                        if [ "$_idx2" -lt "$num_tags" ]; then
                            tag_filter="${all_tags[$_idx2]}"
                            echo -e "${COLOR_SEL}✔ Filtering by ${tag_filter}${COLOR_RESET}"
                            sleep 0.5
                            break
                        fi
                        _buf=""
                        continue
                    fi
                    _buf=""
                fi
                local _idx=$(( key - 1 ))
                if [ "$_idx" -lt "$num_tags" ]; then
                    tag_filter="${all_tags[$_idx]}"
                    echo -e "${COLOR_SEL}✔ Filtering by ${tag_filter}${COLOR_RESET}"
                    sleep 0.5
                    break
                fi
                ;;
            $'\r'|$'\n')
                [ -n "$_buf" ] || continue
                local _idx3=$(( _buf - 1 ))
                _buf=""
                if [ "$_idx3" -lt "$num_tags" ]; then
                    tag_filter="${all_tags[$_idx3]}"
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
