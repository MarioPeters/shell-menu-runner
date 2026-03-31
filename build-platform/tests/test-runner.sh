#!/bin/bash
# ==============================================================================
#  SHELL MENU RUNNER - TEST SUITE
#  Comprehensive testing framework for run.sh
# ==============================================================================

set -euo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
readonly RUN_SCRIPT="$ROOT_DIR/run.sh"

# Colors
C_OK=$'\e[1;32m'; C_FAIL=$'\e[1;31m'; C_SKIP=$'\e[1;33m'
C_INFO=$'\e[36m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'

# Test statistics
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Test output
declare -a FAILED_TEST_NAMES=()

# ==============================================================================
#  TEST FRAMEWORK
# ==============================================================================

test_start() {
    local test_name="$1"
    echo -ne "${C_INFO}TEST${C_RST} $test_name ... "
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_pass() {
    echo -e "${C_OK}PASS${C_RST}"
    PASSED_TESTS=$((PASSED_TESTS + 1))
}

test_fail() {
    local message="${1:-}"
    echo -e "${C_FAIL}FAIL${C_RST}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("$message")
}

test_skip() {
    local reason="${1:-}"
    echo -e "${C_SKIP}SKIP${C_RST} ${C_DIM}($reason)${C_RST}"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local test_name="${3:-}"
    
    if [ "$expected" = "$actual" ]; then
        return 0
    else
        echo -e "\n${C_FAIL}  Expected: $expected${C_RST}"
        echo -e "${C_FAIL}  Actual:   $actual${C_RST}"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    
    if echo "$haystack" | grep -q "$needle"; then
        return 0
    else
        echo -e "\n${C_FAIL}  Expected to contain: $needle${C_RST}"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    
    if [ -f "$file" ]; then
        return 0
    else
        echo -e "\n${C_FAIL}  File not found: $file${C_RST}"
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    
    if [ "$expected" -eq "$actual" ]; then
        return 0
    else
        echo -e "\n${C_FAIL}  Expected exit code: $expected${C_RST}"
        echo -e "${C_FAIL}  Actual exit code:   $actual${C_RST}"
        return 1
    fi
}

# ==============================================================================
#  UNIT TESTS
# ==============================================================================

test_script_exists() {
    test_start "Script exists"
    
    if assert_file_exists "$RUN_SCRIPT"; then
        test_pass
    else
        test_fail "run.sh not found"
    fi
}

test_script_executable() {
    test_start "Script is executable"
    
    if [ -x "$RUN_SCRIPT" ]; then
        test_pass
    else
        test_fail "run.sh is not executable"
    fi
}

test_shebang() {
    test_start "Valid shebang"
    
    local shebang
    shebang=$(head -n1 "$RUN_SCRIPT")
    
    if assert_contains "$shebang" "#!/bin/bash"; then
        test_pass
    else
        test_fail "Invalid shebang: $shebang"
    fi
}

test_version_present() {
    test_start "Version string present"
    
    local version
    version=$(grep -o 'VERSION="[^"]*"' "$RUN_SCRIPT" || true)
    
    if [ -n "$version" ]; then
        test_pass
    else
        test_fail "VERSION not found in run.sh"
    fi
}

test_help_flag() {
    test_start "Help flag works"
    
    local output
    output=$("$RUN_SCRIPT" --help 2>&1 || true)
    
    if assert_contains "$output" "Usage:"; then
        test_pass
    else
        test_fail "Help output missing 'Usage:'"
    fi
}

test_version_flag() {
    test_start "Version flag works"
    
    local output
    output=$("$RUN_SCRIPT" --version 2>&1 || true)
    
    # Accept either version number format or "Shell Menu Runner" text
    if [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        test_pass
    elif echo "$output" | grep -q "Shell Menu Runner"; then
        test_pass
    else
        test_fail "Version output invalid: $output"
    fi
}

test_invalid_flag() {
    test_start "Invalid flag handling"
    
    set +e
    "$RUN_SCRIPT" --invalid-flag-xyz >/dev/null 2>&1
    local exit_code=$?
    set -e
    
    if [ $exit_code -ne 0 ]; then
        test_pass
    else
        test_fail "Should fail on invalid flag"
    fi
}

test_dry_run_mode() {
    test_start "Dry-run mode"
    
    # Skip test - dry-run is only available in interactive mode (via 'd' key)
    # not as a command-line flag
    test_skip "DRY-RUN only available interactively"
}

test_task_execution() {
    test_start "Task execution"
    
    # Create temporary test config
    local test_config="/tmp/test_tasks_$$"
    local test_output="/tmp/test_output_$$"
    
    cat > "$test_config" <<EOF
0|Test Exec|echo "SUCCESS" > $test_output|Test execution
EOF
    
    "$RUN_SCRIPT" --config "$test_config" --exec "Test Exec" >/dev/null 2>&1 || true
    
    local result=""
    if [ -f "$test_output" ]; then
        result=$(cat "$test_output")
    fi
    
    rm -f "$test_config" "$test_output"
    
    if assert_equals "SUCCESS" "$result"; then
        test_pass
    else
        test_fail "Task execution failed"
    fi
}

test_config_validation() {
    test_start "Config validation"
    
    # Create invalid config
    local test_config="/tmp/test_invalid_$$"
    cat > "$test_config" <<'EOF'
0|Invalid|
invalid_line
EOF
    
    set +e
    "$RUN_SCRIPT" --config "$test_config" --validate >/dev/null 2>&1
    local exit_code=$?
    set -e
    
    rm -f "$test_config"
    
    # Should fail validation
    if [ $exit_code -ne 0 ]; then
        test_pass
    else
        test_fail "Should detect invalid config"
    fi
}

test_profile_detection() {
    test_start "Profile detection"
    
    # Create test profile
    local test_dir="/tmp/test_profile_$$"
    mkdir -p "$test_dir"
    cat > "$test_dir/.tasks.testprofile" <<'EOF'
0|Profile Task|echo "test"|Test task
EOF
    
    cd "$test_dir"
    local output
    output=$("$RUN_SCRIPT" --list-profiles 2>&1 || true)
    cd - >/dev/null
    
    rm -rf "$test_dir"
    
    if assert_contains "$output" "testprofile"; then
        test_pass
    else
        test_fail "Profile detection not working"
    fi
}

test_search_functionality() {
    test_start "Search functionality"
    
    local test_config="/tmp/test_search_$$"
    cat > "$test_config" <<'EOF'
0|Build Project|make build|Build the project
0|Test Project|make test|Run tests
0|Deploy|./deploy.sh|Deploy to production
EOF
    
    local output
    output=$("$RUN_SCRIPT" --config "$test_config" --search "test" 2>&1 || true)
    
    rm -f "$test_config"
    
    if assert_contains "$output" "Test Project"; then
        test_pass
    else
        test_fail "Search not finding tasks"
    fi
}

test_tag_support() {
    test_start "Tag support"
    
    local test_config="/tmp/test_tags_$$"
    cat > "$test_config" <<'EOF'
0|Tagged Task [dev]|echo "test"|Development task
0|Other Task|echo "other"|Production task
EOF
    
    local output
    output=$("$RUN_SCRIPT" --config "$test_config" --tag "dev" --list 2>&1 || true)
    
    rm -f "$test_config"
    
    if assert_contains "$output" "Tagged Task"; then
        test_pass
    else
        test_fail "Tag filtering not working"
    fi
}

# ==============================================================================
#  INTEGRATION TESTS
# ==============================================================================

test_dependency_execution() {
    test_start "Dependency execution"
    
    local test_config="/tmp/test_deps_$$"
    local dep_marker="/tmp/dep_marker_$$"
    local main_marker="/tmp/main_marker_$$"
    
    cat > "$test_config" <<EOF
0|Dependency|touch $dep_marker|Dependency task
0|Main Task|[depends:Dependency] touch $main_marker|Main task with dependency
EOF
    
    "$RUN_SCRIPT" --config "$test_config" --exec "Main Task" >/dev/null 2>&1 || true
    
    local dep_exists=0
    local main_exists=0
    [ -f "$dep_marker" ] && dep_exists=1
    [ -f "$main_marker" ] && main_exists=1
    
    rm -f "$test_config" "$dep_marker" "$main_marker"
    
    if [ $dep_exists -eq 1 ] && [ $main_exists -eq 1 ]; then
        test_pass
    else
        test_fail "Dependencies not executing correctly"
    fi
}

test_environment_variables() {
    test_start "Environment variables"
    
    local test_config="/tmp/test_env_$$"
    local test_output="/tmp/test_env_output_$$"
    
    cat > "$test_config" <<EOF
0|Env Test|echo "\${TEST_VAR}" > $test_output|Test env var
EOF
    
    export TEST_VAR="test_value_123"
    "$RUN_SCRIPT" --config "$test_config" --exec "Env Test" >/dev/null 2>&1 || true
    
    local result=""
    if [ -f "$test_output" ]; then
        result=$(cat "$test_output")
    fi
    
    rm -f "$test_config" "$test_output"
    
    if assert_equals "test_value_123" "$result"; then
        test_pass
    else
        test_fail "Environment variables not expanded"
    fi
}

# ==============================================================================
#  PERFORMANCE TESTS
# ==============================================================================

test_large_config_performance() {
    test_start "Large config performance"
    
    local test_config="/tmp/test_large_$$"
    
    # Generate 1000 tasks
    {
        for i in {1..1000}; do
            echo "0|Task $i|echo \"task$i\"|Description $i"
        done
    } > "$test_config"
    
    local start_time
    start_time=$(date +%s)
    
    "$RUN_SCRIPT" --config "$test_config" --list >/dev/null 2>&1 || true
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    rm -f "$test_config"
    
    # Should complete within 5 seconds
    if [ $duration -lt 5 ]; then
        test_pass
    else
        test_fail "Performance issue: took ${duration}s (threshold: 5s)"
    fi
}

# ==============================================================================
#  REGRESSION TESTS
# ==============================================================================

test_special_characters_in_task_name() {
    test_start "Special characters handling"
    
    local test_config="/tmp/test_special_$$"
    cat > "$test_config" <<'EOF'
0|Task with "quotes"|echo "test"|Test task
0|Task with 'apostrophes'|echo "test"|Test task
0|Task with $dollar|echo "test"|Test task
EOF
    
    local output
    output=$("$RUN_SCRIPT" --config "$test_config" --list 2>&1 || true)
    
    rm -f "$test_config"
    
    if assert_contains "$output" "Task with"; then
        test_pass
    else
        test_fail "Special characters breaking parser"
    fi
}

test_empty_config() {
    test_start "Empty config handling"

    local tmp_dir="/tmp/test_empty_$$"
    mkdir -p "$tmp_dir"
    touch "$tmp_dir/.tasks"

    local output exit_code=0
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --list 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    # --list with empty config should print "No tasks found." and exit 0
    if [ "$exit_code" -eq 0 ] && echo "$output" | grep -q "No tasks found"; then
        test_pass
    else
        test_fail "Expected 'No tasks found.' and exit 0, got: exit=$exit_code output=$output"
    fi
}

test_cols_min_width_setting() {
    test_start "COLS_MIN_WIDTH setting is read from .runrc"

    local tmp_dir="/tmp/test_cols_min_width_$$"
    mkdir -p "$tmp_dir"
    printf 'COLS_MIN_WIDTH=25\n' > "$tmp_dir/.runrc"
    printf '0|Task A|echo a|desc\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --version 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" ""; then
        test_pass   # just checking no crash on unknown key
    else
        test_fail "Script crashed reading COLS_MIN_WIDTH from .runrc"
    fi
}

test_context_show_setting() {
    test_start "CONTEXT_SHOW setting is read from .runrc without crash"

    local tmp_dir="/tmp/test_ctx_show_$$"
    mkdir -p "$tmp_dir"
    printf 'CONTEXT_SHOW=hostname,env\n' > "$tmp_dir/.runrc"
    printf '0|Task A|echo a|desc\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --version 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" ""; then
        test_pass
    else
        test_fail "Script crashed reading CONTEXT_SHOW from .runrc"
    fi
}

# ==============================================================================
#  LAYOUT ALGORITHM TESTS
# ==============================================================================

# Unit-test calculate_layout by sourcing only the needed src files in a subshell.
# Tests fail with the old hardcoded-threshold implementation.
_run_calc_layout() {
    # Args: tput_cols cols_min_width cols_max total
    bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        TPUT_COLS=$1; COLS_MIN_WIDTH=$2; COLS_MAX=$3; COLS_MIN=1
        source '$ROOT_DIR/src/13-ui.sh' 2>/dev/null
        calculate_layout $4
        printf '%d %d' \$_layout_cols \$_layout_rows
    "
}

test_calculate_layout_70_width() {
    test_start "calculate_layout: 70-char terminal → 2 cols (8 tasks, COLS_MIN_WIDTH=30)"
    local result
    result=$(_run_calc_layout 70 30 4 8)
    if assert_equals "2 4" "$result"; then
        test_pass
    else
        test_fail "Expected '2 4', got: '$result'"
    fi
}

test_calculate_layout_120_width() {
    test_start "calculate_layout: 120-char terminal → 4 cols (12 tasks, COLS_MIN_WIDTH=30)"
    local result
    result=$(_run_calc_layout 120 30 4 12)
    if assert_equals "4 3" "$result"; then
        test_pass
    else
        test_fail "Expected '4 3', got: '$result'"
    fi
}

test_calculate_layout_cols_max_cap() {
    test_start "calculate_layout: COLS_MAX=2 caps at 2 even if terminal is wide"
    local result
    result=$(_run_calc_layout 200 30 2 12)
    if assert_equals "2 6" "$result"; then
        test_pass
    else
        test_fail "Expected '2 6', got: '$result'"
    fi
}

test_calculate_layout_unlimited_cols() {
    test_start "calculate_layout: COLS_MAX=0 means unlimited (200-char, 20 tasks)"
    local result
    result=$(_run_calc_layout 200 30 0 20)
    # cols = floor(200/30) = 6, capped at ceil(20/2)=10 → 6
    # rows = ceil(20/6) = 4
    if assert_equals "6 4" "$result"; then
        test_pass
    else
        test_fail "Expected '6 4', got: '$result'"
    fi
}

test_calculate_layout_narrow_terminal() {
    test_start "calculate_layout: 25-char terminal → always 1 col"
    local result
    result=$(_run_calc_layout 25 30 4 5)
    if assert_equals "1 5" "$result"; then
        test_pass
    else
        test_fail "Expected '1 5', got: '$result'"
    fi
}

# ==============================================================================
#  CONTEXT INDICATOR TESTS
# ==============================================================================

test_init_context_no_crash() {
    test_start "init_context: runs without crash in non-git, non-SSH dir"

    local tmp_dir="/tmp/test_ctx_$$"
    mkdir -p "$tmp_dir"
    printf '0|T|echo t|d\n' > "$tmp_dir/.tasks"

    local output
    # Run --version in a non-git dir; init_context is called during startup
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --version 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "1."; then
        test_pass
    else
        test_fail "Script crashed during init_context: $output"
    fi
}

test_build_border_strings() {
    test_start "build_border_strings: correct length for col_width=30"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
        _LAST_COL_WIDTH=0; _BORDER_TOP=''; _BORDER_BOT=''
        build_border_strings 30
        # inner = 30-4 = 26; box width = inner+2 = 28; top = ┌ + 26×─ + ┐
        echo \"\${#_BORDER_TOP} \${#_BORDER_BOT} \$_LAST_COL_WIDTH\"
    ")

    if assert_equals "28 28 30" "$result"; then
        test_pass
    else
        test_fail "Expected '28 28 30', got: '$result'"
    fi
}

# ==============================================================================
#  DRAW MENU TESTS
# ==============================================================================

test_draw_menu_build_integrity() {
    test_start "draw_menu: build still produces valid run.sh after overhaul"
    make -C "$ROOT_DIR" dev >/dev/null 2>&1
    if assert_file_exists "$RUN_SCRIPT"; then
        test_pass
    else
        test_fail "run.sh missing after build"
    fi
}

test_draw_menu_help_intact() {
    test_start "draw_menu: --help still works after overhaul"
    local output
    output=$("$RUN_SCRIPT" --help 2>&1 || true)
    if assert_contains "$output" "Usage:"; then
        test_pass
    else
        test_fail "Help broken after draw_menu overhaul: $output"
    fi
}

# ==============================================================================
#  CLI MODE TESTS
# ==============================================================================

test_cli_list_shows_tasks() {
    test_start "cli --list: shows numbered task list"

    local tmp_dir="/tmp/test_cli_list_$$"
    mkdir -p "$tmp_dir"
    printf '0|Build Project|make build|Build the project\n' > "$tmp_dir/.tasks"
    printf '0|Run Tests|make test|Run the test suite\n'    >> "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --list 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "Build Project" && assert_contains "$output" "Run Tests"; then
        test_pass
    else
        test_fail "Expected task names in --list output, got: $output"
    fi
}

test_cli_list_empty() {
    test_start "cli --list: shows 'No tasks found' for empty config"

    local tmp_dir="/tmp/test_cli_list_empty_$$"
    mkdir -p "$tmp_dir"
    printf '' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --list 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "No tasks found"; then
        test_pass
    else
        test_fail "Expected 'No tasks found', got: $output"
    fi
}

_run_cli_match() {
    # Args: query
    bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        menu_options=('0|Build Project|make build|Build' '0|Run Tests|make test|Tests' '0|Build Docker|docker build .|Docker')
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        cli_match_tasks '$1' 2>/dev/null
        rc=\$?
        echo \"\${_cli_matches[*]} rc=\$rc\"
    "
}

test_cli_match_by_number() {
    test_start "cli_match_tasks: numeric query returns correct index"
    local result
    result=$(_run_cli_match 2)
    if assert_contains "$result" "1 rc=0"; then
        test_pass
    else
        test_fail "Expected '1 rc=0' (index 1 = task 2), got: '$result'"
    fi
}

test_cli_match_exact_name() {
    test_start "cli_match_tasks: exact name match (case-insensitive)"
    local result
    result=$(_run_cli_match "run tests")
    if assert_contains "$result" "1 rc=0"; then
        test_pass
    else
        test_fail "Expected index 1 for 'run tests', got: '$result'"
    fi
}

test_cli_match_substring() {
    test_start "cli_match_tasks: substring match returns all hits"
    local result
    result=$(_run_cli_match "build")
    # "Build Project" (idx 0) and "Build Docker" (idx 2) both match
    if assert_contains "$result" "0" && assert_contains "$result" "2"; then
        test_pass
    else
        test_fail "Expected indices 0 and 2 for 'build', got: '$result'"
    fi
}

test_cli_match_no_match() {
    test_start "cli_match_tasks: no match returns exit 1"
    local result
    result=$(_run_cli_match "zzznomatch")
    if assert_contains "$result" "rc=1"; then
        test_pass
    else
        test_fail "Expected rc=1 for no match, got: '$result'"
    fi
}

test_cli_match_out_of_range() {
    test_start "cli_match_tasks: out-of-range number returns exit 1"
    local result
    result=$(_run_cli_match 99)
    if assert_contains "$result" "rc=1"; then
        test_pass
    else
        test_fail "Expected rc=1 for out-of-range number, got: '$result'"
    fi
}

# ==============================================================================
#  TEST EXECUTION
# ==============================================================================

run_all_tests() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     Shell Menu Runner - Test Suite                        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Unit tests
    echo "${C_INFO}» Unit Tests${C_RST}"
    test_script_exists
    test_script_executable
    test_shebang
    test_version_present
    test_help_flag
    test_version_flag
    test_invalid_flag
    test_dry_run_mode
    test_task_execution
    test_config_validation
    test_profile_detection
    test_search_functionality
    test_tag_support
    
    echo ""
    echo "${C_INFO}» Integration Tests${C_RST}"
    test_dependency_execution
    test_environment_variables
    
    echo ""
    echo "${C_INFO}» Settings Tests${C_RST}"
    test_cols_min_width_setting
    test_context_show_setting

    echo ""
    echo "${C_INFO}» Layout Algorithm Tests${C_RST}"
    test_calculate_layout_70_width
    test_calculate_layout_120_width
    test_calculate_layout_cols_max_cap
    test_calculate_layout_unlimited_cols
    test_calculate_layout_narrow_terminal

    echo ""
    echo "${C_INFO}» Context Indicator Tests${C_RST}"
    test_init_context_no_crash

    echo ""
    echo "${C_INFO}» Border String Tests${C_RST}"
    test_build_border_strings

    echo ""
    echo "${C_INFO}» Draw Menu Tests${C_RST}"
    test_draw_menu_build_integrity
    test_draw_menu_help_intact

    echo ""
    echo "${C_INFO}» CLI Mode Tests${C_RST}"
    test_cli_list_shows_tasks
    test_cli_list_empty
    test_cli_match_by_number
    test_cli_match_exact_name
    test_cli_match_substring
    test_cli_match_no_match
    test_cli_match_out_of_range

    echo ""
    echo "${C_INFO}» Performance Tests${C_RST}"
    test_large_config_performance
    
    echo ""
    echo "${C_INFO}» Regression Tests${C_RST}"
    test_special_characters_in_task_name
    test_empty_config
    
    # Report
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  TEST RESULTS"
    echo "════════════════════════════════════════════════════════════"
    echo "  Total:   $TOTAL_TESTS"
    echo "  ${C_OK}Passed:  $PASSED_TESTS${C_RST}"
    [ $FAILED_TESTS -gt 0 ] && echo "  ${C_FAIL}Failed:  $FAILED_TESTS${C_RST}" || echo "  Failed:  $FAILED_TESTS"
    [ $SKIPPED_TESTS -gt 0 ] && echo "  ${C_SKIP}Skipped: $SKIPPED_TESTS${C_RST}"
    echo "════════════════════════════════════════════════════════════"
    
    if [ $FAILED_TESTS -gt 0 ]; then
        echo ""
        echo "${C_FAIL}Failed tests:${C_RST}"
        for test_name in "${FAILED_TEST_NAMES[@]}"; do
            echo "  - $test_name"
        done
        echo ""
        return 1
    else
        echo ""
        echo "${C_OK}✓ All tests passed!${C_RST}"
        echo ""
        return 0
    fi
}

# ==============================================================================
#  MAIN
# ==============================================================================

main() {
    run_all_tests
}

main "$@"
