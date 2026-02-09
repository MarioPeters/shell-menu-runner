# ==============================================================================
#  TASK DEPENDENCIES & PARALLEL EXECUTION
# ==============================================================================

parse_task_deps() {
    local task_cmd="$1"
    # Extract [depends: task1,task2] from command
    if [[ "$task_cmd" =~ \[depends:([^\]]+)\] ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

execute_task_deps() {
    local deps_str="$1"
    local IFS=','
    local -a deps
    read -r -a deps <<< "$deps_str"
    
    echo -e "${COLOR_INFO}$(msg task_depends):${COLOR_RESET}"
    
    # Check if parallel execution is enabled
    if [ "${RUN_PARALLEL_DEPS:-0}" = "1" ] && [ "${#deps[@]}" -gt 1 ]; then
        echo -e "${COLOR_DIM}  (running ${#deps[@]} dependencies in parallel)${COLOR_RESET}"
        local -a dep_pids=()
        local -a dep_names=()
        local -a dep_logs=()
        
        for dep in "${deps[@]}"; do
            dep=$(trim_whitespace "$dep")
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"
            
            # Log in CACHE_DIR ablegen — wird bei EXIT automatisch bereinigt
            local dep_log="${CACHE_DIR}/dep_${dep}_$$.log"
            dep_logs+=("$dep_log")
            dep_names+=("$dep")
            
            # Execute in background
            (
                if ! find_task_in_menu "$dep" '_execute_dep_callback' 2>&1 | tee "$dep_log"; then
                    exit 1
                fi
            ) &
            dep_pids+=("$!")
        done
        
        # Wait for all dependencies to complete
        echo ""
        show_spinner "Waiting for ${#deps[@]} parallel dependencies..."
        
        local all_success=1
        for i in "${!dep_pids[@]}"; do
            if ! wait "${dep_pids[$i]}"; then
                stop_spinner
                echo -e "${COLOR_ERR}❌ Dependency '${dep_names[$i]}' failed${COLOR_RESET}"
                all_success=0
            fi
        done
        
        stop_spinner
        [ "$all_success" -eq 1 ] && echo -e "${COLOR_SEL}✔ All dependencies completed${COLOR_RESET}"
        
        # Cleanup log files
        for log in "${dep_logs[@]}"; do
            [ -f "$log" ] && rm -f "$log"
        done
        
        [ "$all_success" -eq 0 ] && return 1
        return 0
    else
        # Sequential execution (default)
        for dep in "${deps[@]}"; do
            dep=$(trim_whitespace "$dep")
            echo -e "  ${COLOR_DIM}→ $dep${COLOR_RESET}"
            
            # Find and execute the dependency task using helper
            if ! find_task_in_menu "$dep" '_execute_dep_callback'; then
                echo -e "${COLOR_ERR}❌ Dependency '$dep' not found in:${COLOR_RESET}"
                for cf in "${task_config_files[@]}"; do echo -e "  ${COLOR_DIM}$cf${COLOR_RESET}"; done
                return 1
            fi
        done
    fi
}

_execute_dep_callback() {
    local dep_name="$1"
    local dep_cmd="$2"
    local dep_desc="$3"
    execute_task "$dep_cmd" "$dep_name" "$dep_desc" || return 1
}

# ==============================================================================
#  MULTI-PROFILE EXECUTION
# ==============================================================================

execute_multi_profile_task() {
    local task_name="$1"
    local profiles_str="$2"  # comma-separated
    local IFS=','
    local -a profiles
    read -r -a profiles <<< "$profiles_str"
    
    echo -e "${COLOR_HEAD}Running task across ${#profiles[@]} profiles:${COLOR_RESET}"
    
    # Check if parallel execution is enabled
    if [ "${RUN_PARALLEL_MULTI:-0}" = "1" ] && [ "${#profiles[@]}" -gt 1 ]; then
        echo -e "${COLOR_DIM}  (running in parallel)${COLOR_RESET}"
        local -a profile_pids=()
        local -a profile_names=()
        local -a profile_logs=()
        
        for prof in "${profiles[@]}"; do
            prof=$(trim_whitespace "$prof")
            echo -e "  ${COLOR_DIM}→ [$prof] $task_name${COLOR_RESET}"
            
            # Log in CACHE_DIR ablegen — wird bei EXIT automatisch bereinigt
            local prof_log="${CACHE_DIR}/multi_prof_${prof}_$$.log"
            profile_logs+=("$prof_log")
            profile_names+=("$prof")
            
            # Execute in background with profile context
            (
                # Load profile configuration
                if ! load_profile_config "$prof"; then
                    echo -e "${COLOR_ERR}Failed to load profile: $prof${COLOR_RESET}" | tee "$prof_log"
                    exit 1
                fi
                
                # Find and execute the task in this profile
                if ! find_task_in_menu "$task_name" '_execute_profile_callback'; then
                    echo -e "${COLOR_ERR}Task not found in profile: $prof${COLOR_RESET}" | tee "$prof_log"
                    exit 1
                fi
            ) &
            profile_pids+=("$!")
        done
        
        # Wait for all profile executions
        echo ""
        show_spinner "Waiting for ${#profiles[@]} profile executions..."
        
        local all_success=1
        for i in "${!profile_pids[@]}"; do
            if ! wait "${profile_pids[$i]}"; then
                stop_spinner
                echo -e "${COLOR_ERR}❌ Profile '${profile_names[$i]}' failed${COLOR_RESET}"
                all_success=0
            fi
        done
        
        stop_spinner
        [ "$all_success" -eq 1 ] && echo -e "${COLOR_SEL}✔ All profiles completed${COLOR_RESET}"
        
        # Cleanup log files
        for log in "${profile_logs[@]}"; do
            [ -f "$log" ] && rm -f "$log"
        done
        
        [ "$all_success" -eq 0 ] && return 1
        return 0
    else
        # Sequential execution
        for prof in "${profiles[@]}"; do
            prof=$(trim_whitespace "$prof")
            echo -e "  ${COLOR_INFO}→ Profile: $prof${COLOR_RESET}"
            
            # Load profile configuration
            if ! load_profile_config "$prof"; then
                echo -e "${COLOR_ERR}Failed to load profile: $prof${COLOR_RESET}"
                return 1
            fi
            
            # Find and execute the task in this profile
            if ! find_task_in_menu "$task_name" '_execute_profile_callback'; then
                echo -e "${COLOR_ERR}Task not found in profile: $prof${COLOR_RESET}"
                return 1
            fi
        done
        
        echo -e "${COLOR_SEL}✔ All profiles completed${COLOR_RESET}"
    fi
}

_execute_profile_callback() {
    local task_name="$1"
    local task_cmd="$2"
    local task_desc="$3"
    execute_task "$task_cmd" "$task_name" "$task_desc" || return 1
}

# ==============================================================================
#  PROJECT ANALYSIS
# ==============================================================================

analyze_project() {
    local profile="${1:-.}"
    local config_file=".tasks"
    
    if [ "$profile" != "." ] && [ "$profile" != "" ]; then
        config_file=".tasks.$profile"
    fi
    
    if [ ! -f "$config_file" ]; then
        echo -e "${COLOR_ERR}✗ No .tasks file found${COLOR_RESET}"
        return 1
    fi
    
    # Einmaliger awk-Durchlauf statt 10 separater grep-Aufrufe
    local total_tasks level_0 level_1 deps_count parallel_count \
          has_lint has_test has_build has_deploy test_count
    read -r total_tasks level_0 level_1 deps_count parallel_count \
             has_lint has_test has_build has_deploy test_count < <(
        awk '
            /^[0-9]/                           { tot++ }
            /^0\|/                             { l0++ }
            /^1\|/                             { l1++ }
            /depends:/                         { dep++ }
            /--parallel/                       { par++ }
            tolower($0) ~ /lint|eslint|pylint/ { lint++ }
            tolower($0) ~ /test|jest|pytest/   { tst++ }
            tolower($0) ~ /build|compile/      { bld++ }
            tolower($0) ~ /deploy|push|release/{ dpl++ }
            tolower($0) ~ /test/               { tc++ }
            END { print (tot+0),(l0+0),(l1+0),(dep+0),(par+0),(lint+0),(tst+0),(bld+0),(dpl+0),(tc+0) }
        ' "$config_file" 2>/dev/null
    )

    echo -e "\n${COLOR_SEL}📊 Project Analysis${COLOR_RESET}"
    echo -e "${COLOR_DIM}─────────────────────────────────────────────────────────────${COLOR_RESET}"
    
    # 1. Basic Stats
    echo -e "${COLOR_INFO}📈 Statistics:${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Total Tasks:${COLOR_RESET} $total_tasks"
    echo -e "  ${COLOR_DIM}Main Tasks (Level 0):${COLOR_RESET} $level_0"
    [ "$level_1" -gt 0 ] && echo -e "  ${COLOR_DIM}Sub Tasks (Level 1):${COLOR_RESET} $level_1"
    echo -e "  ${COLOR_DIM}Tasks with Dependencies:${COLOR_RESET} $deps_count"
    echo -e "  ${COLOR_DIM}Parallel-ready Tasks:${COLOR_RESET} $parallel_count"
    
    echo ""
    
    # 2. Recommendations
    echo -e "${COLOR_INFO}💡 Recommendations:${COLOR_RESET}"
    
    if [ "$total_tasks" -gt 50 ]; then
        echo -e "  ${COLOR_WARN}⚠${COLOR_RESET}  ${COLOR_DIM}High task count (${total_tasks}):${COLOR_RESET}"
        echo -e "     Consider splitting into profiles:"
        echo -e "     ${COLOR_DIM}• .tasks.dev  (development)${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• .tasks.prod (production)${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• .tasks.test (testing)${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}Command: run dev / run prod / run test${COLOR_RESET}"
        echo ""
    fi
    
    if [ "$deps_count" -eq 0 ] && [ "$total_tasks" -gt 5 ]; then
        echo -e "  ${COLOR_INFO}ℹ${COLOR_RESET}  ${COLOR_DIM}No dependencies found:${COLOR_RESET}"
        echo -e "     Consider adding task chains for workflows:"
        echo -e "     ${COLOR_DIM}• 0|Build|npm run build|Build${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• 1|Test|npm run test depends:0|Test (after build)${COLOR_RESET}"
        echo -e "     ${COLOR_DIM}• 2|Deploy|npm deploy depends:1|Deploy (after test)${COLOR_RESET}"
        echo ""
    fi
    
    if [ "$parallel_count" -eq 0 ] && [ "$total_tasks" -gt 10 ]; then
        echo -e "  ${COLOR_INFO}⚡${COLOR_RESET}  ${COLOR_DIM}Parallel execution not configured:${COLOR_RESET}"
        echo -e "     Enable for faster execution:"
        echo -e "     ${COLOR_DIM}export RUN_PARALLEL_DEPS=1${COLOR_RESET}"
        if [ "$test_count" -gt 2 ]; then
            echo -e "     ${COLOR_DIM}Performance boost expected: ~2-3x faster${COLOR_RESET}"
        fi
        echo ""
    fi
    
    # (has_lint/has_test/has_build/has_deploy/test_count wurden bereits oben via awk befüllt)
    
    echo -e "${COLOR_INFO}✓ Quality Score:${COLOR_RESET}"
    [ "$has_lint" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Linting${COLOR_RESET} (code quality)" || echo -e "  ✗ ${COLOR_DIM}Linting${COLOR_RESET} (code quality) - consider adding"
    [ "$has_test" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Testing${COLOR_RESET} (test coverage)" || echo -e "  ✗ ${COLOR_DIM}Testing${COLOR_RESET} (test coverage) - consider adding"
    [ "$has_build" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Building${COLOR_RESET} (production ready)" || echo -e "  ✗ ${COLOR_DIM}Building${COLOR_RESET} (production ready) - consider adding"
    [ "$has_deploy" -gt 0 ] && echo -e "  ✓ ${COLOR_SEL}Deployment${COLOR_RESET} (automation)" || echo -e "  ✗ ${COLOR_DIM}Deployment${COLOR_RESET} (automation) - consider adding"
    
    echo ""
    
    # 3. Quick wins
    local quick_wins=0
    echo -e "${COLOR_INFO}🎯 Quick Wins:${COLOR_RESET}"
    
    if [ "$total_tasks" -lt 20 ] && [ "$deps_count" -eq 0 ]; then
        echo -e "  1. Add dependencies to create task workflows"
        quick_wins=$((quick_wins + 1))
    fi
    if [ "$parallel_count" -eq 0 ] && [ "$deps_count" -gt 0 ]; then
        quick_wins=$((quick_wins + 1))
        echo -e "  ${quick_wins}. Enable RUN_PARALLEL_DEPS=1 for speed boost"
    fi
    if [ "$total_tasks" -gt 80 ]; then
        quick_wins=$((quick_wins + 1))
        echo -e "  ${quick_wins}. Create 2-3 profiles to reduce menu clutter"
    fi
    
    if [ "$quick_wins" -eq 0 ]; then
        echo -e "  ${COLOR_SEL}✓ No immediate improvements needed - project well-structured!${COLOR_RESET}"
    fi
    
    echo ""
    
    # 4. Next steps
    echo -e "${COLOR_INFO}📚 Next Steps:${COLOR_RESET}"
    echo -e "  • Run: ${COLOR_DIM}run${COLOR_RESET}  (use interactive menu)"
    echo -e "  • Edit: ${COLOR_DIM}run --edit${COLOR_RESET}  (edit .tasks file)"
    echo -e "  • Validate: ${COLOR_DIM}run --validate${COLOR_RESET}  (check syntax)"
    echo -e "  • Documentation: ${COLOR_DIM}docs/ADVANCED_USAGE.md${COLOR_RESET}  (learn patterns)"
    
    echo -e "${COLOR_DIM}─────────────────────────────────────────────────────────────${COLOR_RESET}\n"
    
    return 0
}

# ==============================================================================
#  TASK EXECUTION HELPERS
# ==============================================================================

find_task_in_menu() {
    # Find task by name in menu_options and execute callback.
    # menu_options format: level|name|cmd|desc — skip level field with _level.
    local search_name="$1"
    local callback="$2"
    local -a opts
    IFS=$'\n' read -d '' -r -a opts < <(get_menu_options) || true
    
    for opt in "${opts[@]}"; do
        IFS='|' read -r _level opt_name opt_cmd opt_desc <<< "$opt"
        if [ "$opt_name" = "$search_name" ]; then
            # Direkter Funktionsaufruf statt eval: schneller und sicherer
            "$callback" "$opt_name" "$opt_cmd" "$opt_desc"
            return 0
        fi
    done
    return 1
}

preview_task() {
    local cmd="$1"
    local name="$2"
    local desc="$3"
    
    clear
    echo -e "${COLOR_HEAD}Preview: $name${COLOR_RESET}"
    echo -e "${COLOR_DIM}──────────────────────────────────────────────────────────────${COLOR_RESET}"
    
    echo -e "${COLOR_INFO}Description:${COLOR_RESET}"
    echo -e "  $desc\n"
    
    echo -e "${COLOR_INFO}Command to execute:${COLOR_RESET}"
    echo -e "  ${COLOR_SEL}$cmd${COLOR_RESET}\n"
    
    if [[ "$desc" == "[!]"* ]]; then
        echo -e "${COLOR_WARN}⚠ Requires confirmation${COLOR_RESET}\n"
    fi
    
    # Bash-Regex statt echo|grep-Fork
    if [[ "$cmd" == *'<<'* ]]; then
        echo -e "${COLOR_INFO}ℹ This task has inputs that will be prompted${COLOR_RESET}\n"
    fi
    
    # Check for dependencies
    local deps
    deps=$(parse_task_deps "$cmd")
    if [ -n "$deps" ]; then
        echo -e "${COLOR_INFO}Dependencies:${COLOR_RESET}"
        local IFS=','
        local -a dep_arr
        read -r -a dep_arr <<< "$deps"
        for d in "${dep_arr[@]}"; do
            echo -e "  ${COLOR_DIM}→ $d${COLOR_RESET}"
        done
        echo ""
    fi
    
    echo -e "${COLOR_DIM}$(msg press_key)${COLOR_RESET}"
    consume_keypress
}
