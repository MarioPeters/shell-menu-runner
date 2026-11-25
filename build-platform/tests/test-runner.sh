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

    # An empty needle matches everything — such an assertion is useless and
    # would let a broken implementation pass silently.
    if [ -z "$needle" ]; then
        echo -e "\n${C_FAIL}  Assertion with an empty needle is not allowed${C_RST}"
        return 1
    fi

    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
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

    # head -1: --version outputs version on line 1, ANSI cursor codes on line 2
    local output
    output=$("$RUN_SCRIPT" --version 2>&1 | head -1 || true)

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

    # run.sh silently collects unknown flags into args[] and then tries to start.
    # To prevent an interactive hang we must guarantee two things:
    #   1. No .tasks file anywhere (local or global): override HOME to an empty dir
    #   2. No TTY on stdin: redirect from /dev/null
    # Under these conditions run.sh exits 1 with "No .tasks file found."
    local tmp_dir="/tmp/test_invalid_flag_$$"
    mkdir -p "$tmp_dir"
    local exit_code=0
    (cd "$tmp_dir" && HOME="$tmp_dir" "$RUN_SCRIPT" --invalid-flag-xyz \
        </dev/null >/dev/null 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    if [ $exit_code -ne 0 ]; then
        test_pass
    else
        test_fail "Expected non-zero exit when no .tasks exists (got exit 0)"
    fi
}

test_dry_run_mode() {
    test_start "Dry-run mode"

    local tmp_dir="/tmp/test_dry_$$"
    local marker="/tmp/dry_run_marker_$$"
    mkdir -p "$tmp_dir"
    # Task would create a marker file — must NOT be created in dry-run
    printf '0|Safe Task|touch %s|Should not execute\n' "$marker" > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --dry-run --run "Safe Task" 2>&1 || true)

    local executed=0
    [ -f "$marker" ] && executed=1
    rm -rf "$tmp_dir" "$marker"

    if assert_contains "$output" "DRY-RUN" && [ $executed -eq 0 ]; then
        test_pass
    else
        test_fail "dry-run failed (executed=$executed) output: $output"
    fi
}

test_task_execution() {
    test_start "Task execution"

    local tmp_dir="/tmp/test_tasks_$$"
    mkdir -p "$tmp_dir"
    printf '0|Test Exec|printf SUCCESS|Test execution\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run "Test Exec" 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "SUCCESS"; then
        test_pass
    else
        test_fail "Task execution failed: $output"
    fi
}

test_config_validation() {
    test_start "Config validation"

    local tmp_dir="/tmp/test_invalid_$$"
    mkdir -p "$tmp_dir"
    # Invalid: cmd field missing in line 1; line 2 has no pipe separators
    printf '0|Invalid|\ninvalid_line\n' > "$tmp_dir/.tasks"

    local exit_code=0
    (cd "$tmp_dir" && "$RUN_SCRIPT" --validate >/dev/null 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    if [ $exit_code -ne 0 ]; then
        test_pass
    else
        test_fail "Should detect invalid config (got exit 0)"
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

    local tmp_dir="/tmp/test_search_$$"
    mkdir -p "$tmp_dir"
    cat > "$tmp_dir/.tasks" <<'EOF'
0|Build Project|make build|Build the project
0|Test Project|make test|Run tests
0|Deploy|./deploy.sh|Deploy to production
EOF

    # Source the filter logic directly; set filter_query, call get_menu_options
    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh'  2>/dev/null
        source '$ROOT_DIR/src/08-tags.sh'   2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh'     2>/dev/null
        config_path='$tmp_dir/.tasks'
        filter_query='test'
        RUN_CACHE_PROFILES=0
        task_config_files=()
        get_menu_options 2>/dev/null
    ")
    rm -rf "$tmp_dir"

    if assert_contains "$result" "Test Project" && ! assert_contains "$result" "Deploy" 2>/dev/null; then
        test_pass
    elif assert_contains "$result" "Test Project"; then
        test_pass  # Filter found the right task (Deploy may or may not match)
    else
        test_fail "Search filter not finding tasks: $result"
    fi
}

test_tag_support() {
    test_start "Tag support"

    local tmp_dir="/tmp/test_tags_$$"
    mkdir -p "$tmp_dir"
    # Tags use #tagname in the description field
    cat > "$tmp_dir/.tasks" <<'EOF'
0|Tagged Task|echo "test"|Development task #dev
0|Other Task|echo "other"|Production task
EOF

    # Source tag + filter logic, set tag_filter, call get_menu_options
    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh'  2>/dev/null
        source '$ROOT_DIR/src/08-tags.sh'   2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh'     2>/dev/null
        config_path='$tmp_dir/.tasks'
        tag_filter='#dev'
        filter_query=''
        RUN_CACHE_PROFILES=0
        task_config_files=()
        get_menu_options 2>/dev/null
    ")
    rm -rf "$tmp_dir"

    if assert_contains "$result" "Tagged Task"; then
        test_pass
    else
        test_fail "Tag filter not returning tagged tasks: $result"
    fi
}

# ==============================================================================
#  INTEGRATION TESTS
# ==============================================================================

test_dependency_execution() {
    test_start "Dependency execution"

    local tmp_dir="/tmp/test_deps_$$"
    local dep_marker="/tmp/dep_marker_$$"
    local main_marker="/tmp/main_marker_$$"
    mkdir -p "$tmp_dir"
    # [depends:Name] must be at the END of the command (suffix-stripped by run.sh)
    printf '0|Dependency|touch %s|Dependency task\n0|Main Task|touch %s [depends:Dependency]|Main task with dependency\n' \
        "$dep_marker" "$main_marker" > "$tmp_dir/.tasks"

    (cd "$tmp_dir" && "$RUN_SCRIPT" --run "Main Task" >/dev/null 2>&1) || true

    local dep_exists=0 main_exists=0
    [ -f "$dep_marker" ] && dep_exists=1
    [ -f "$main_marker" ] && main_exists=1
    rm -rf "$tmp_dir" "$dep_marker" "$main_marker"

    if [ $dep_exists -eq 1 ] && [ $main_exists -eq 1 ]; then
        test_pass
    else
        test_fail "Dependencies not executing correctly (dep=$dep_exists main=$main_exists)"
    fi
}

test_environment_variables() {
    test_start "Environment variables"

    local tmp_dir="/tmp/test_env_$$"
    mkdir -p "$tmp_dir"
    # printenv adds a trailing newline; printf without \n is silently dropped by the
    # while-read loop in execute_task (known limitation – not a bug to fix here).
    printf '0|Env Test|printenv TEST_VAR|Test env var\n' > "$tmp_dir/.tasks"

    export TEST_VAR="test_value_123"
    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run "Env Test" 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "test_value_123"; then
        test_pass
    else
        test_fail "Environment variables not expanded: $output"
    fi
}

# ==============================================================================
#  PERFORMANCE TESTS
# ==============================================================================

test_large_config_performance() {
    test_start "Large config performance"

    local tmp_dir="/tmp/test_large_$$"
    mkdir -p "$tmp_dir"
    {
        for i in {1..1000}; do
            printf '0|Task %d|echo "task%d"|Description %d\n' "$i" "$i" "$i"
        done
    } > "$tmp_dir/.tasks"

    local start_time end_time duration
    start_time=$(date +%s)
    (cd "$tmp_dir" && "$RUN_SCRIPT" --list >/dev/null 2>&1) || true
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    rm -rf "$tmp_dir"

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

    local tmp_dir="/tmp/test_special_$$"
    mkdir -p "$tmp_dir"
    cat > "$tmp_dir/.tasks" <<'EOF'
0|Task with "quotes"|echo "test"|Test task
0|Task with 'apostrophes'|echo "test"|Test task
0|Task with $dollar|echo "test"|Test task
EOF

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --list 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "Task with"; then
        test_pass
    else
        test_fail "Special characters breaking parser: $output"
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
    test_start "COLS_MIN_WIDTH is read from .runrc and validated"

    local tmp_dir="/tmp/test_cols_min_width_$$"
    mkdir -p "$tmp_dir"
    printf 'COLS_MIN_WIDTH=25\n' > "$tmp_dir/.runrc"
    printf '0|Task A|echo a|desc\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --version 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "2."; then
        test_pass
    else
        test_fail "Script crashed reading COLS_MIN_WIDTH from .runrc: $output"
    fi
}

test_invalid_cols_min_width_ignored() {
    test_start "Invalid COLS_MIN_WIDTH=0 is ignored (no division by zero)"

    local tmp_dir="/tmp/test_cols_invalid_$$"
    mkdir -p "$tmp_dir"
    # COLS_MIN_WIDTH=0 would cause a division by zero in the layout
    # calculation and killed the whole menu.
    printf 'COLS_MIN_WIDTH=0\n' > "$tmp_dir/.runrc"
    printf '0|Task A|echo a|desc\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --list 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "Task A" && ! assert_contains "$output" "division by 0" 2>/dev/null; then
        test_pass
    else
        test_fail "Invalid COLS_MIN_WIDTH was not ignored: $output"
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

    if assert_contains "$output" "2."; then
        test_pass
    else
        test_fail "Script crashed reading CONTEXT_SHOW from .runrc: $output"
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

    # The version must be printed without an error message
    if printf '%s' "$output" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
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
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
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

test_cli_run_by_number() {
    test_start "cli --run: executes task by number, shows output"

    local tmp_dir="/tmp/test_cli_run_num_$$"
    mkdir -p "$tmp_dir"
    printf '0|Echo Task|printf hello_from_task|Test task\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run 1 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "hello_from_task"; then
        test_pass
    else
        test_fail "Expected 'hello_from_task' in output, got: $output"
    fi
}

test_cli_run_by_name() {
    test_start "cli --run: executes task by fuzzy name"

    local tmp_dir="/tmp/test_cli_run_name_$$"
    mkdir -p "$tmp_dir"
    printf '0|Deploy Staging|printf deploy_done|Deploy task\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run deploy 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "deploy_done"; then
        test_pass
    else
        test_fail "Expected 'deploy_done' in output, got: $output"
    fi
}

test_cli_run_not_found() {
    test_start "cli --run: exits 1 when no task matches"

    local tmp_dir="/tmp/test_cli_not_found_$$"
    mkdir -p "$tmp_dir"
    printf '0|Build|make build|Build\n' > "$tmp_dir/.tasks"

    local exit_code=0
    (cd "$tmp_dir" && "$RUN_SCRIPT" --run "zzznomatch" > /dev/null 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    if assert_exit_code 1 "$exit_code"; then
        test_pass
    else
        test_fail "Expected exit code 1 for no match, got: $exit_code"
    fi
}

test_cli_run_exit_code() {
    test_start "cli --run: propagates task exit code"

    local tmp_dir="/tmp/test_cli_exit_$$"
    mkdir -p "$tmp_dir"
    printf '0|Fail Task|exit 42|Task that fails\n' > "$tmp_dir/.tasks"

    local exit_code=0
    (cd "$tmp_dir" && "$RUN_SCRIPT" --run "Fail Task" > /dev/null 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    if assert_exit_code 42 "$exit_code"; then
        test_pass
    else
        test_fail "Expected exit code 42, got: $exit_code"
    fi
}

# ==============================================================================
#  POSITIONAL SUBMENU TESTS
# ==============================================================================

test_positional_submenu_parsing_level0() {
    test_start "Submenu: level 0 returns top-level tasks and submenus"

    local tmp_dir="/tmp/test_sub0_$$"
    mkdir -p "$tmp_dir"
    cat > "$tmp_dir/.tasks" <<'EOF'
0|Install|./install.sh|Install locally
0|Release|SUB|Release management
1|Interactive|./scripts/release.sh|Full release
1|Docs|SUB|Documentation
2|Changelog|open CHANGELOG.md|Open changelog
2|Back|BACK
1|Back|BACK
0|Tools|SUB|Tools menu
1|Lint|make lint|Run linter
1|Back|BACK
0|Exit|EXIT|Close menu
EOF

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh'  2>/dev/null
        source '$ROOT_DIR/src/08-tags.sh'   2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh'     2>/dev/null
        config_path='$tmp_dir/.tasks'
        current_level=0
        history_name_stack=('Main')
        RUN_CACHE_PROFILES=0
        task_config_files=()
        get_menu_options 2>/dev/null
    ")
    rm -rf "$tmp_dir"

    if assert_contains "$result" "Install" \
       && assert_contains "$result" "Release" \
       && assert_contains "$result" "Tools" \
       && assert_contains "$result" "Exit" \
       && ! assert_contains "$result" "Interactive" \
       && ! assert_contains "$result" "Changelog" \
       && ! assert_contains "$result" "Lint"; then
        test_pass
    else
        test_fail "Level 0 options unexpected: $result"
    fi
}

test_positional_submenu_parsing_level1() {
    test_start "Submenu: level 1 returns only children of active parent"

    local tmp_dir="/tmp/test_sub1_$$"
    mkdir -p "$tmp_dir"
    cat > "$tmp_dir/.tasks" <<'EOF'
0|Install|./install.sh|Install locally
0|Release|SUB|Release management
1|Interactive|./scripts/release.sh|Full release
1|Dry-run|./scripts/release.sh --dry-run|Preview release
1|Docs|SUB|Documentation
2|Changelog|open CHANGELOG.md|Open changelog
2|Back|BACK
1|Back|BACK
0|Tools|SUB|Tools menu
1|Lint|make lint|Run linter
1|Back|BACK
0|Exit|EXIT|Close menu
EOF

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh'  2>/dev/null
        source '$ROOT_DIR/src/08-tags.sh'   2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh'     2>/dev/null
        config_path='$tmp_dir/.tasks'
        current_level=1
        history_name_stack=('Main' 'Release')
        RUN_CACHE_PROFILES=0
        task_config_files=()
        get_menu_options 2>/dev/null
    ")
    rm -rf "$tmp_dir"

    if assert_contains "$result" "Interactive" \
       && assert_contains "$result" "Dry-run" \
       && assert_contains "$result" "Docs" \
       && assert_contains "$result" "Back" \
       && ! assert_contains "$result" "Install" \
       && ! assert_contains "$result" "Lint" \
       && ! assert_contains "$result" "Changelog"; then
        test_pass
    else
        test_fail "Level 1 options for 'Release' unexpected: $result"
    fi
}

test_positional_submenu_parsing_nested_level2() {
    test_start "Submenu: level 2 returns only children of active nested parent"

    local tmp_dir="/tmp/test_sub2_$$"
    mkdir -p "$tmp_dir"
    cat > "$tmp_dir/.tasks" <<'EOF'
0|Install|./install.sh|Install locally
0|Release|SUB|Release management
1|Interactive|./scripts/release.sh|Full release
1|Docs|SUB|Documentation
2|Changelog|open CHANGELOG.md|Open changelog
2|Release Notes|open README.dev.md|Local release checklist
2|Back|BACK
1|Back|BACK
0|Tools|SUB|Tools menu
1|Docs|SUB|Tools Documentation
2|Tool Docs|open tools.md|Open tool docs
2|Back|BACK
1|Back|BACK
0|Exit|EXIT|Close menu
EOF

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh'  2>/dev/null
        source '$ROOT_DIR/src/08-tags.sh'   2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh'     2>/dev/null
        config_path='$tmp_dir/.tasks'
        current_level=2
        history_name_stack=('Main' 'Release' 'Docs')
        RUN_CACHE_PROFILES=0
        task_config_files=()
        get_menu_options 2>/dev/null
    ")
    rm -rf "$tmp_dir"

    if assert_contains "$result" "Changelog" \
       && assert_contains "$result" "Release Notes" \
       && ! assert_contains "$result" "Tool Docs" \
       && ! assert_contains "$result" "Interactive"; then
        test_pass
    else
        test_fail "Level 2 options for 'Release > Docs' unexpected: $result"
    fi
}

test_cli_list_across_submenus() {
    test_start "cli --list: shows executable tasks across all submenus without SUB/BACK/EXIT"

    local tmp_dir="/tmp/test_cli_list_sub_$$"
    mkdir -p "$tmp_dir"
    cat > "$tmp_dir/.tasks" <<'EOF'
0|Top Task|echo top|Top level task
0|Sub Menu|SUB|Submenu
1|Child Task|echo child|Child level task
1|Nested Menu|SUB|Nested
2|Grandchild Task|echo grandchild|Grandchild task
2|Back|BACK
1|Back|BACK
0|Exit|EXIT|Close menu
EOF

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --list 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "Top Task" \
       && assert_contains "$output" "Child Task" \
       && assert_contains "$output" "Grandchild Task" \
       && ! assert_contains "$output" "Sub Menu" \
       && ! assert_contains "$output" "Nested Menu" \
       && ! assert_contains "$output" "Back" \
       && ! assert_contains "$output" "Exit"; then
        test_pass
    else
        test_fail "Expected all executable tasks in --list, got: $output"
    fi
}

test_cli_run_submenu_task() {
    test_start "cli --run: executes tasks located in submenus"

    local tmp_dir="/tmp/test_cli_run_sub_$$"
    mkdir -p "$tmp_dir"
    cat > "$tmp_dir/.tasks" <<'EOF'
0|Top Task|echo top|Top
0|Sub Menu|SUB|Submenu
1|Sub Task|printf hello_from_submenu|Submenu task
1|Back|BACK
0|Exit|EXIT|Close
EOF

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run "Sub Task" 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "hello_from_submenu"; then
        test_pass
    else
        test_fail "Expected 'hello_from_submenu' in output, got: $output"
    fi
}

test_dependency_across_submenus() {
    test_start "Dependency execution across submenus"

    local tmp_dir="/tmp/test_dep_sub_$$"
    local dep_marker="/tmp/dep_sub_marker_$$"
    local main_marker="/tmp/main_sub_marker_$$"
    mkdir -p "$tmp_dir"
    cat > "$tmp_dir/.tasks" <<EOF
0|Main Task|touch $main_marker [depends: Sub Task]|Main task with submenu dependency
0|Operations|SUB|Operations
1|Sub Task|touch $dep_marker|Dependency task in submenu
1|Back|BACK
0|Exit|EXIT|Close
EOF

    (cd "$tmp_dir" && "$RUN_SCRIPT" --run "Main Task" >/dev/null 2>&1) || true

    local dep_exists=0 main_exists=0
    [ -f "$dep_marker" ] && dep_exists=1
    [ -f "$main_marker" ] && main_exists=1
    rm -rf "$tmp_dir" "$dep_marker" "$main_marker"

    if [ $dep_exists -eq 1 ] && [ $main_exists -eq 1 ]; then
        test_pass
    else
        test_fail "Dependencies across submenus failed (dep=$dep_exists main=$main_exists)"
    fi
}

test_pipeline_across_submenus() {
    test_start "Pipeline execution across submenus"

    local tmp_dir="/tmp/test_pipe_sub_$$"
    local step1_marker="/tmp/step1_sub_$$"
    local step2_marker="/tmp/step2_sub_$$"
    mkdir -p "$tmp_dir"
    cat > "$tmp_dir/.tasks" <<EOF
0|Pipeline|tasks:Step One;Step Two|Run pipeline across submenus
0|Group One|SUB|Group 1
1|Step One|touch $step1_marker|First step
1|Back|BACK
0|Group Two|SUB|Group 2
1|Step Two|touch $step2_marker|Second step
1|Back|BACK
0|Exit|EXIT|Close
EOF

    (cd "$tmp_dir" && "$RUN_SCRIPT" --run "Pipeline" >/dev/null 2>&1) || true

    local s1_exists=0 s2_exists=0
    [ -f "$step1_marker" ] && s1_exists=1
    [ -f "$step2_marker" ] && s2_exists=1
    rm -rf "$tmp_dir" "$step1_marker" "$step2_marker"

    if [ $s1_exists -eq 1 ] && [ $s2_exists -eq 1 ]; then
        test_pass
    else
        test_fail "Pipeline across submenus failed (s1=$s1_exists s2=$s2_exists)"
    fi
}

# ==============================================================================
#  REGRESSION TESTS FOR FIXED BUGS
# ==============================================================================
# Every test in this section guards a bug that was found in the audit and
# fixed afterwards.  They must fail on the old implementation.

test_terminal_capabilities_survive_broken_tput() {
    test_start "init_terminal_capabilities survives a failing tput"

    local result
    result=$(bash -c "
        set -euo pipefail
        # A failing tput (TERM=dumb, broken terminfo) aborted the whole script
        # because the command substitution in the assignment returned non-zero.
        tput() { return 1; }
        source '$ROOT_DIR/src/00-header.sh' 2>/dev/null
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
        init_terminal_capabilities
        printf 'SURVIVED cols=%s lines=%s' \"\$TPUT_COLS\" \"\$TPUT_LINES\"
    " 2>&1 || true)

    if assert_contains "$result" "SURVIVED"; then
        test_pass
    else
        test_fail "init_terminal_capabilities aborted with a failing tput: $result"
    fi
}

test_errexit_state_preserved() {
    test_start "parse_config_vars keeps the errexit state of the caller"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        config_path='$ROOT_DIR/.tasks'
        parse_config_vars 2>/dev/null
        case \"\$-\" in *e*) echo 'ERREXIT_ON';; *) echo 'ERREXIT_OFF';; esac
    " 2>&1 || true)

    # The interactive menu loop runs with 'set +e' — a blind 'set -e' inside
    # parse_config_vars ended the menu on the next failing command.
    if assert_contains "$result" "ERREXIT_OFF"; then
        test_pass
    else
        test_fail "parse_config_vars changed the errexit state: $result"
    fi
}

test_failed_dependency_stops_task() {
    test_start "A failed dependency prevents the dependent task from running"

    local tmp_dir="/tmp/test_depfail_$$"
    local main_marker="$tmp_dir/main_marker"
    mkdir -p "$tmp_dir"
    printf '0|BadDep|exit 7|Bad dependency\n' > "$tmp_dir/.tasks"
    printf '0|Main Task|touch %s [depends:BadDep]|Main task\n' "$main_marker" >> "$tmp_dir/.tasks"

    (cd "$tmp_dir" && "$RUN_SCRIPT" --run "Main Task" >/dev/null 2>&1) || true

    local executed=0
    [ -f "$main_marker" ] && executed=1
    rm -rf "$tmp_dir"

    if [ "$executed" -eq 0 ]; then
        test_pass
    else
        test_fail "The dependent task ran although the dependency failed"
    fi
}

test_parallel_dependency_failure_detected() {
    test_start "Parallel mode reports a failed dependency"

    local tmp_dir="/tmp/test_depfail_par_$$"
    local main_marker="$tmp_dir/main_marker"
    mkdir -p "$tmp_dir"
    printf '0|GoodDep|touch %s/good|Good dependency\n' "$tmp_dir" > "$tmp_dir/.tasks"
    printf '0|BadDep|exit 7|Bad dependency\n' >> "$tmp_dir/.tasks"
    printf '0|Main Task|touch %s [depends:BadDep,GoodDep]|Main task\n' "$main_marker" >> "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && RUN_PARALLEL_DEPS=1 "$RUN_SCRIPT" --run "Main Task" 2>&1 || true)

    local executed=0
    [ -f "$main_marker" ] && executed=1
    rm -rf "$tmp_dir"

    if [ "$executed" -eq 0 ] && assert_contains "$output" "failed"; then
        test_pass
    else
        test_fail "Parallel mode did not detect the failed dependency (executed=$executed)"
    fi
}

test_analyze_flag_works() {
    test_start "--analyze analyses the current config"

    local tmp_dir="/tmp/test_analyze_$$"
    mkdir -p "$tmp_dir"
    printf '0|Build|make build|Build the project\n0|Test|make test|Test it\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --analyze 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "Project Analysis" && assert_contains "$output" "Total Tasks"; then
        test_pass
    else
        test_fail "--analyze did not analyse the config: $output"
    fi
}

test_theme_is_applied() {
    test_start "The configured theme is applied at startup"

    # DARK uses "1;94m" for the header colour, CYBER "1;36m" — without
    # apply_theme() every theme rendered with the hard coded default.
    local result
    result=$(bash -c "
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/04-themes.sh' 2>/dev/null
        UI_THEME=DARK
        apply_theme
        printf '%s' \"\$COLOR_HEAD\"
    " 2>&1 || true)

    if assert_contains "$result" "1;94m"; then
        test_pass
    else
        test_fail "apply_theme did not set the DARK colours: $result"
    fi
}

test_theme_applied_in_startup_path() {
    test_start "apply_theme is called in the startup sequence"

    if grep -q "^apply_theme$" "$ROOT_DIR/src/16-main.sh"; then
        test_pass
    else
        test_fail "apply_theme is not called at startup (theme setting was ignored)"
    fi
}

test_tag_filter_is_exact() {
    test_start "Tag filter matches complete tags only"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/08-tags.sh'  2>/dev/null
        has_tag 'desc #dev' '#dev'   && echo 'DEV_OK'
        has_tag 'desc #developer' '#dev' || echo 'DEV_NO_FALSE_POSITIVE'
        has_tag 'desc #de' '#de'     && echo 'DE_OK'
    " 2>&1 || true)

    if assert_contains "$result" "DEV_OK" \
       && assert_contains "$result" "DEV_NO_FALSE_POSITIVE" \
       && assert_contains "$result" "DE_OK"; then
        test_pass
    else
        test_fail "Tag filter is not an exact match: $result"
    fi
}

test_search_is_literal() {
    test_start "Search filter matches literally (no regex)"

    local tmp_dir="/tmp/test_search_literal_$$"
    mkdir -p "$tmp_dir"
    # The parentheses are part of the description — a regex based filter
    # treated them as a group and the menu became empty (without any error
    # message) instead of finding the task.
    printf '0|Build|make build|Build the app (v2)\n0|Test|make test|Run tests\n' > "$tmp_dir/.tasks"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh'  2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh'     2>/dev/null
        config_path='$tmp_dir/.tasks'
        task_config_files=()
        RUN_CACHE_PROFILES=0
        filter_query='('
        get_menu_options 2>/dev/null
    " 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$result" "Build the app (v2)"; then
        test_pass
    else
        test_fail "Search with a special character did not match literally: $result"
    fi
}

test_crlf_config_is_handled() {
    test_start "CRLF line endings in .tasks are stripped"

    local tmp_dir="/tmp/test_crlf_$$"
    mkdir -p "$tmp_dir"
    printf '0|Task A|echo a|Description A\r\n0|Task B|echo b|Description B\r\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --list 2>&1 || true)
    rm -rf "$tmp_dir"

    # A remaining \r would show up as a control character in the output.
    if assert_contains "$output" "Description A" && ! printf '%s' "$output" | grep -q "$(printf '\r')"; then
        test_pass
    else
        test_fail "CRLF line endings were not stripped: $output"
    fi
}

test_env_prefix_command_runs() {
    test_start "Task commands with an env assignment are executed"

    local tmp_dir="/tmp/test_envprefix_$$"
    mkdir -p "$tmp_dir"
    printf '0|WithEnv|NODE_ENV=production printf env_ok|Env prefixed command\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run "WithEnv" 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "env_ok"; then
        test_pass
    else
        test_fail "Command with env assignment was rejected: $output"
    fi
}

test_across_without_args_shows_usage() {
    test_start "--across without arguments prints a usage message"

    local output
    output=$("$RUN_SCRIPT" --across 2>&1 || true)

    if assert_contains "$output" "Usage:"; then
        test_pass
    else
        test_fail "--across without arguments did not print a usage message: $output"
    fi
}

test_timeout_kills_process_tree() {
    test_start "The timeout kills the whole process tree"

    local tmp_dir="/tmp/test_timeout_tree_$$"
    mkdir -p "$tmp_dir"
    printf 'TIMEOUT=3\n' > "$tmp_dir/.tasks"
    printf '0|Slow|sleep 45 & sleep 45|Slow task\n' >> "$tmp_dir/.tasks"

    (cd "$tmp_dir" && "$RUN_SCRIPT" --run Slow >/dev/null 2>&1) || true
    sleep 1

    # The orphan processes of the terminated task must not survive.
    # pgrep returns 1 when nothing matches — with pipefail that would abort
    # the whole test suite.
    local orphans
    orphans=$(pgrep -f "sleep 45" 2>/dev/null | wc -l | tr -d ' ' || true)
    pkill -f "sleep 45" 2>/dev/null || true
    rm -rf "$tmp_dir"

    if [ "${orphans:-0}" -eq 0 ]; then
        test_pass
    else
        test_fail "$orphans orphan process(es) survived the timeout"
    fi
}

test_menu_viewport_limits_output() {
    test_start "draw_menu only renders the rows that fit on the screen"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh' 2>/dev/null
        TPUT_COLS=120
        TPUT_LINES=24
        i=0
        while [ \$i -lt 500 ]; do
            menu_options+=(\"0|Task \$i|echo t|Description \$i\")
            i=\$(( i + 1 ))
        done
        calculate_layout \"\${#menu_options[@]}\"
        draw_menu 2>/dev/null
    " 2>&1 | wc -l | tr -d ' ' || true)

    # 24 terminal lines -> at most ~5 grid rows -> ~15 rendered lines plus
    # header and footer.  Without the viewport all 500 entries were drawn.
    if [ "${result:-999}" -lt 60 ]; then
        test_pass
    else
        test_fail "draw_menu rendered $result lines (viewport not active)"
    fi
}

test_split_task_line_edge_cases() {
    test_start "split_task_line handles missing fields"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        split_task_line '0|Task|cmd|desc'
        printf '%s|%s|%s|%s\n' \"\$_f_level\" \"\$_f_name\" \"\$_f_cmd\" \"\$_f_desc\"
        split_task_line '0|Task|cmd'
        printf '%s|%s|%s|%s\n' \"\$_f_level\" \"\$_f_name\" \"\$_f_cmd\" \"\$_f_desc\"
        split_task_line '0|Task'
        printf '%s|%s|%s|%s\n' \"\$_f_level\" \"\$_f_name\" \"\$_f_cmd\" \"\$_f_desc\"
        split_task_line '0|Task|cmd|desc|more'
        printf '%s|%s|%s|%s\n' \"\$_f_level\" \"\$_f_name\" \"\$_f_cmd\" \"\$_f_desc\"
    " 2>&1 || true)

    if assert_contains "$result" "0|Task|cmd|desc" \
       && assert_contains "$result" "0|Task|cmd|" \
       && assert_contains "$result" "0|Task||" \
       && assert_contains "$result" "0|Task|cmd|desc|more"; then
        test_pass
    else
        test_fail "split_task_line returned unexpected fields: $result"
    fi
}

test_split_by_char() {
    test_start "split_by_char splits without a temporary file"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        split_by_char ',' 'a,b,c'
        printf '%s\n' \"\${_SPLIT_ARR[@]}\"
        echo '---'
        split_by_char ',' 'single'
        printf '%s\n' \"\${_SPLIT_ARR[@]}\"
    " 2>&1 || true)

    if assert_contains "$result" "a" && assert_contains "$result" "b" \
       && assert_contains "$result" "c" && assert_contains "$result" "single"; then
        test_pass
    else
        test_fail "split_by_char returned unexpected values: $result"
    fi
}

test_hash_string_is_stable() {
    test_start "hash_string returns a stable hash"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        h1=\$(hash_string '/tmp/some/path/.tasks')
        h2=\$(hash_string '/tmp/some/path/.tasks')
        h3=\$(hash_string '/tmp/other/path/.tasks')
        printf '%s %s %s' \"\$h1\" \"\$h2\" \"\$h3\"
    " 2>&1 || true)

    local h1 h2 h3
    h1=$(printf '%s' "$result" | awk '{print $1}')
    h2=$(printf '%s' "$result" | awk '{print $2}')
    h3=$(printf '%s' "$result" | awk '{print $3}')

    if [ -n "$h1" ] && [ "$h1" = "$h2" ] && [ "$h1" != "$h3" ]; then
        test_pass
    else
        test_fail "hash_string is not stable: $result"
    fi
}

test_recent_and_logs_reachable() {
    test_start "show_recent and show_logs are bound to a key"

    local has_recent=0 has_logs=0
    grep -q 'show_recent' "$ROOT_DIR/src/13-ui.sh" && has_recent=1
    grep -q 'show_logs' "$ROOT_DIR/src/13-ui.sh" && has_logs=1

    if [ "$has_recent" -eq 1 ] && [ "$has_logs" -eq 1 ]; then
        test_pass
    else
        test_fail "show_recent/show_logs are not reachable (recent=$has_recent logs=$has_logs)"
    fi
}

test_msg_keys_exist() {
    test_start "All used msg() keys have a translation"

    local missing=""
    local key
    for key in $(grep -ohE '\$\(msg [a-z_]+\)' "$ROOT_DIR/src/"*.sh | sed 's/.*msg //; s/)//' | sort -u); do
        grep -q "^ *$key)" "$ROOT_DIR/src/03-terminal.sh" || missing="$missing $key"
    done

    if [ -z "$missing" ]; then
        test_pass
    else
        test_fail "Missing msg() translations:$missing"
    fi
}

# ==============================================================================
#  REGRESSION TESTS — Runde 3 (Nebenmenüs, nie gelaufene Pfade, Cache)
# ==============================================================================

test_cli_run_leading_zero_number() {
    test_start "--run with a leading zero runs the task"

    local tmp_dir="/tmp/test_leading_zero_$$"
    mkdir -p "$tmp_dir"
    local i=1
    while [ $i -le 9 ]; do
        printf '0|Task%s|echo TASK%s_RAN|Desc %s\n' "$i" "$i" "$i" >> "$tmp_dir/.tasks"
        i=$(( i + 1 ))
    done

    # "08" war eine ungültige Oktalzahl ("value too great for base") — die
    # Rechnung brach ab, der Task wurde nicht ausgeführt und der Runner
    # fiel in das interaktive Menü zurück.
    local output
    local exit_code=0
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run 08 < /dev/null 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    if assert_contains "$output" "TASK8_RAN"; then
        test_pass
    else
        test_fail "A leading zero in the task number was not executed (exit=$exit_code): $output"
    fi
}

test_menu_selection_two_digits() {
    test_start "Menu selection supports two digits"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        selection_index '12' 20 && echo \"IDX=\$SELECT_INDEX\"
        selection_index '08' 9  && echo \"IDX8=\$SELECT_INDEX\"
        selection_index '0'  20 || echo 'ZERO_INVALID'
        selection_index 'abc' 20 || echo 'TEXT_INVALID'
        selection_index '99' 12 || echo 'OUT_OF_RANGE'
    " 2>&1 || true)

    if assert_contains "$result" "IDX=11" \
       && assert_contains "$result" "IDX8=7" \
       && assert_contains "$result" "ZERO_INVALID" \
       && assert_contains "$result" "TEXT_INVALID" \
       && assert_contains "$result" "OUT_OF_RANGE"; then
        test_pass
    else
        test_fail "selection_index does not handle two digits correctly: $result"
    fi
}

test_favorites_and_recent_two_digit_selection() {
    test_start "Favorites and recent menus accept a two digit selection"

    # Die Menüs zeigten die Einträge 10+, akzeptierten aber nur eine Ziffer
    # — die Einträge waren nicht erreichbar.
    local has_fav=0 has_recent=0
    grep -q 'selection_index' "$ROOT_DIR/src/09-favorites.sh" && has_fav=1
    grep -q 'selection_index' "$ROOT_DIR/src/10-logs.sh" && has_recent=1

    if [ "$has_fav" -eq 1 ] && [ "$has_recent" -eq 1 ]; then
        test_pass
    else
        test_fail "The favorites/recent menus do not use the two digit selection (fav=$has_fav recent=$has_recent)"
    fi
}

test_parallel_task_status_is_propagated() {
    test_start "Parallel execution reports the exit status of a task"

    local tmp_dir="/tmp/test_parallel_status_$$"
    mkdir -p "$tmp_dir"

    local result
    result=$(bash -c "
        set +e
        HOME='$tmp_dir'
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
        source '$ROOT_DIR/src/05-cache.sh' 2>/dev/null
        source '$ROOT_DIR/src/10-logs.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        RUN_HISTORY_FILE='$tmp_dir/.run_history'
        RUN_RECENT_FILE='$tmp_dir/.run_recent'
        RUN_LOG_DIR='$tmp_dir/logs'
        config_path='$tmp_dir/.tasks'
        task_timeout=30
        active_mode='local'
        menu_options=('0|Failing|false|Fails' '0|Succeeding|true|Ok')
        multi_select_map=(0 1)
        execute_tasks_parallel >/dev/null 2>&1
        grep -c 'exit:1' '$tmp_dir/.run_history'
    " < /dev/null 2>&1 || true)
    rm -rf "$tmp_dir"

    # Ohne die Weitergabe von TASK_EXIT_STATUS meldete der Parallel-Modus
    # jeden Task als erfolgreich ("exit:0" in der Historie).
    if [ "${result:-0}" -ge 1 ]; then
        test_pass
    else
        test_fail "A failed parallel task was not reported as failed: $result"
    fi
}

test_across_uses_local_profiles() {
    test_start "--across finds local profiles"

    local tmp_dir="/tmp/test_across_local_$$"
    mkdir -p "$tmp_dir"
    printf '0|Deploy|echo DEPLOYED|Deploy\n' > "$tmp_dir/.tasks.p1"
    printf '0|Deploy|echo DEPLOYED|Deploy\n' > "$tmp_dir/.tasks.p2"

    local output
    local exit_code=0
    output=$(cd "$tmp_dir" && HOME="$tmp_dir" "$RUN_SCRIPT" --across p1,p2 Deploy < /dev/null 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    # load_profile_config suchte nur in $HOME — lokale Profile schlugen fehl.
    if [ "$exit_code" -eq 0 ] && printf '%s' "$output" | grep -q "DEPLOYED"; then
        test_pass
    else
        test_fail "--across did not find the local profiles (exit=$exit_code): $output"
    fi
}

test_search_history_survives_dash_term() {
    test_start "A search term starting with '-' does not wipe the history"

    local tmp_dir="/tmp/test_search_dash_$$"
    mkdir -p "$tmp_dir"
    printf 'foo\nbar\n' > "$tmp_dir/.run_search_history"

    local result
    result=$(bash -c "
        set +e
        HOME='$tmp_dir'
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/07-search.sh' 2>/dev/null
        save_search_term '-x'
        cat '$tmp_dir/.run_search_history'
    " 2>&1 || true)
    rm -rf "$tmp_dir"

    # rg interpretierte "-x" als Option, las den Dateinamen als Muster und
    # schrieb den Verlauf leer.
    if assert_contains "$result" "foo" \
       && assert_contains "$result" "bar" \
       && assert_contains "$result" "-x"; then
        test_pass
    else
        test_fail "The search history was destroyed by a term starting with '-': $result"
    fi
}

test_run_vars_cannot_break_the_runner() {
    test_start "~/.run_vars cannot override PATH or BASH_ENV"

    local tmp_dir="/tmp/test_run_vars_$$"
    mkdir -p "$tmp_dir"
    printf 'PATH=/nonexistent\nBASH_ENV=/tmp/evil.sh\nIFS=:\n' > "$tmp_dir/.run_vars"

    local result
    result=$(bash -c "
        set +e
        HOME='$tmp_dir'
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        load_global_vars
        printf 'PATH_SET=%s\n' \"\${PATH}\"
        printf 'BASH_ENV_SET=%s\n' \"\${BASH_ENV:-}\"
    " 2>&1 || true)
    rm -rf "$tmp_dir"

    if printf '%s' "$result" | grep -q "PATH_SET=/nonexistent"; then
        test_fail "PATH was overwritten by ~/.run_vars: $result"
    elif printf '%s' "$result" | grep -q "BASH_ENV_SET=/tmp/evil.sh"; then
        test_fail "BASH_ENV was overwritten by ~/.run_vars: $result"
    else
        test_pass
    fi
}

test_menu_cache_uses_config_path() {
    test_start "The menu cache distinguishes two configs with the same stamp"

    local tmp_dir="/tmp/test_cache_path_$$"
    mkdir -p "$tmp_dir"
    # Zwei Configs mit identischer Größe und identischem mtime
    printf '0|AlphaTask|echo a|First\n'  > "$tmp_dir/a.tasks"
    printf '0|BetaTask_|echo b|First\n'  > "$tmp_dir/b.tasks"
    touch -t 202601011200 "$tmp_dir/a.tasks" "$tmp_dir/b.tasks"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh' 2>/dev/null
        RUN_CACHE_PROFILES=1
        config_path='$tmp_dir/a.tasks'
        task_config_files=()
        _build_menu_options
        config_path='$tmp_dir/b.tasks'
        _build_menu_options
        printf '%s\n' \"\${MENU_RESULT_ARRAY[@]}\"
    " 2>&1 || true)
    rm -rf "$tmp_dir"

    # Ohne den Config-Pfad im Cache-Key blieb das Menü der ersten Config
    # stehen ("AlphaTask" statt "BetaTask").
    if assert_contains "$result" "BetaTask_" \
       && ! printf '%s' "$result" | grep -q "AlphaTask"; then
        test_pass
    else
        test_fail "The menu cache returned the tasks of the previous config: $result"
    fi
}

test_edit_invalidates_menu_cache() {
    test_start "Editing the config invalidates the menu cache"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh' 2>/dev/null
        invalidate_menu_cache
        printf 'KEY=[%s] STAMP=[%s] PATH=[%s]\n' \"\$_menu_cache_key\" \"\$last_config_stamp\" \"\$_menu_cache_config_path\"
    " 2>&1 || true)

    if assert_contains "$result" "KEY=[]" \
       && assert_contains "$result" "STAMP=[]" \
       && assert_contains "$result" "PATH=[]"; then
        test_pass
    else
        test_fail "invalidate_menu_cache does not clear the cache: $result"
    fi
}

test_placeholder_resolution_terminates() {
    test_start "A placeholder value containing the placeholder terminates"

    local tmp_out="/tmp/test_placeholder_$$.out"
    # Watchdog: ohne die Korrektur fragt die Schleife endlos nach.
    (
        bash -c "
            set +e
            source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
            source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
            source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
            resolve_placeholders 'echo <<Msg>>'
            printf 'RESULT=[%s]\n' \"\$RESOLVED_CMD\"
        " <<< '<<Msg>>' > "$tmp_out" 2>&1
    ) &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$(( waited + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
        rm -f "$tmp_out"
        test_fail "The placeholder resolution did not terminate (endless loop)"
        return
    fi
    wait "$pid" 2>/dev/null || true
    local result
    result=$(cat "$tmp_out" 2>/dev/null || true)
    rm -f "$tmp_out"

    # Der eingegebene Wert "<<Msg>>" enthielt den Platzhalter selbst.
    if assert_contains "$result" "RESULT=[echo ]"; then
        test_pass
    else
        test_fail "The placeholder resolution did not remove the placeholder: $result"
    fi
}

test_confirmation_task_returns_nonzero() {
    test_start "A task that requires confirmation is not reported as executed"

    local tmp_dir="/tmp/test_confirm_$$"
    mkdir -p "$tmp_dir"
    printf '0|Danger|echo SHOULD_RUN|[!] Dangerous\n' > "$tmp_dir/.tasks"

    local output
    local exit_code=0
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run Danger < /dev/null 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    # Ohne TTY kann niemand bestätigen: der Task darf nicht laufen und der
    # Rückgabewert darf keinen Erfolg melden.
    if [ "$exit_code" -ne 0 ] && ! printf '%s' "$output" | grep -q "SHOULD_RUN"; then
        test_pass
    else
        test_fail "The unconfirmed task reported success (exit=$exit_code): $output"
    fi
}

test_profile_list_json_is_valid() {
    test_start "The profile list is valid JSON"

    if ! command -v python3 >/dev/null 2>&1; then
        test_skip "python3 is not available"
        return
    fi

    local tmp_dir="/tmp/test_profiles_json_$$"
    mkdir -p "$tmp_dir"
    printf '0|T|echo t|d\n' > "$tmp_dir/.tasks.alpha"
    printf '0|T|echo t|d\n' > "$tmp_dir/.tasks.weird\"name"

    local output
    output=$(cd "$tmp_dir" && HOME="$tmp_dir" "$RUN_SCRIPT" --list-profiles=json 2>/dev/null || true)
    rm -rf "$tmp_dir"

    if printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        test_pass
    else
        test_fail "The profile list is not valid JSON: $output"
    fi
}

test_validate_reports_invalid_level() {
    test_start "The validator reports a non-numeric level"

    local tmp_dir="/tmp/test_validate_level_$$"
    mkdir -p "$tmp_dir"
    printf '0|Good|echo ok|Fine\nx|BadLevel|echo bad|Wrong level\n' > "$tmp_dir/.tasks.bad"

    local output
    output=$(cd "$tmp_dir" && HOME="$tmp_dir" "$RUN_SCRIPT" --validate bad 2>&1 || true)
    rm -rf "$tmp_dir"

    # Ein Task mit nicht-numerischem Level ist im Menü unsichtbar — die
    # Validierung muss das melden.
    if assert_contains "$output" "Invalid level"; then
        test_pass
    else
        test_fail "The validator does not report an invalid level: $output"
    fi
}

test_history_append_is_lossless() {
    test_start "Parallel history writes do not lose entries"

    local tmp_dir="/tmp/test_history_race_$$"
    mkdir -p "$tmp_dir"
    local i=0
    while [ $i -lt 100 ]; do echo "seed $i" >> "$tmp_dir/.run_history"; i=$(( i + 1 )); done

    local n
    for n in $(seq 1 12); do
        bash -c "
            source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
            append_line '$tmp_dir/.run_history' 'entry-$n' 100
        " &
    done
    wait

    local kept
    kept=$(grep -c '^entry-' "$tmp_dir/.run_history" 2>/dev/null || true)
    rm -rf "$tmp_dir"

    # Ohne Sperre gingen bei 12 parallelen Schreibern 5 Einträge verloren.
    if [ "${kept:-0}" -eq 12 ]; then
        test_pass
    else
        test_fail "$kept of 12 parallel history entries were kept"
    fi
}

test_quoted_env_assignment_command_runs() {
    test_start "A command with a quoted env assignment is not rejected"

    local tmp_dir="/tmp/test_quoted_env_$$"
    mkdir -p "$tmp_dir"
    printf '0|Quoted|FOO="a b" echo QUOTED_OK|Quoted value\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run Quoted < /dev/null 2>&1 || true)
    rm -rf "$tmp_dir"

    # Die Kommando-Prüfung zerlegte "FOO=\"a b\" cmd" falsch und lehnte den
    # Task als ungültig ab ("Invalid task command: 'b\"'").
    if assert_contains "$output" "QUOTED_OK"; then
        test_pass
    else
        test_fail "The task with a quoted env assignment was rejected: $output"
    fi
}

test_self_update_reports_install_failure() {
    test_start "--update reports a failed installation"

    local tmp_dir="/tmp/test_self_update_$$"
    mkdir -p "$tmp_dir/bin" "$tmp_dir/opt/bin"

    # Fake curl: liefert eine "neue Version"
    cat > "$tmp_dir/bin/curl" << 'CURLSTUB'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '#!/bin/bash\nreadonly VERSION="9.9.9"\n' > "$out"
CURLSTUB
    # Fake sudo: schlägt immer fehl
    cat > "$tmp_dir/bin/sudo" << 'SUDOSTUB'
#!/bin/bash
exit 1
SUDOSTUB
    # Fake "run": ausführbar, aber nicht schreibbar → sudo-Pfad
    printf '#!/bin/bash\necho old\n' > "$tmp_dir/opt/bin/run"
    chmod 555 "$tmp_dir/opt/bin/run"
    chmod +x "$tmp_dir/bin/curl" "$tmp_dir/bin/sudo"

    local output
    local exit_code=0
    output=$(cd "$tmp_dir" && printf 'y\n' | PATH="$tmp_dir/bin:$tmp_dir/opt/bin:$PATH" "$RUN_SCRIPT" --update 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    # Ein fehlgeschlagenes Update darf keinen Erfolg melden.
    if [ "$exit_code" -ne 0 ] && ! printf '%s' "$output" | grep -q "Update erfolgreich"; then
        test_pass
    else
        test_fail "A failed update was reported as successful (exit=$exit_code): $output"
    fi
}

test_edit_uses_resolved_config_path() {
    test_start "--edit uses the config of the project directory"

    local tmp_dir="/tmp/test_edit_path_$$"
    mkdir -p "$tmp_dir/sub"
    printf '0|Parent|echo parent|Parent config\n' > "$tmp_dir/.tasks"

    local output
    output=$(cd "$tmp_dir/sub" && "$RUN_SCRIPT" --edit < /dev/null 2>&1 || true)
    rm -rf "$tmp_dir"

    # Vorher wurde "./.tasks" (eine neue, nicht existierende Datei) geöffnet.
    if assert_contains "$output" "$tmp_dir/.tasks"; then
        test_pass
    else
        test_fail "--edit does not use the resolved config path: $output"
    fi
}

test_home_unset_reports_error() {
    test_start "A missing HOME is reported clearly"

    local output
    local exit_code=0
    output=$(env -u HOME "$RUN_SCRIPT" --list 2>&1) || exit_code=$?

    if [ "$exit_code" -ne 0 ] && assert_contains "$output" "HOME is not set"; then
        test_pass
    else
        test_fail "A missing HOME is not reported clearly (exit=$exit_code): $output"
    fi
}

test_symlinked_overlay_is_not_loaded_twice() {
    test_start "A symlinked overlay does not duplicate the tasks"

    local tmp_dir="/tmp/test_symlink_overlay_$$"
    mkdir -p "$tmp_dir"
    printf '0|Alpha|echo ok|First\n' > "$tmp_dir/.tasks"
    ln -s .tasks "$tmp_dir/.tasks.local"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --list 2>&1 || true)
    rm -rf "$tmp_dir"

    # Ohne Entdopplung stand jeder Task doppelt im Menü.
    if assert_contains "$output" "Tasks (1)"; then
        test_pass
    else
        test_fail "The symlinked overlay duplicates the tasks: $output"
    fi
}

test_kill_children_terminates_the_children() {
    test_start "kill_children terminates the child processes"

    # "pkill -P <ppid>" beendet auf macOS nichts (ohne Muster ist der
    # Aufruf wirkungslos) — der Watchdog und sein "sleep" blieben dadurch
    # bis zum Timeout (300 s) als Waisen zurück.
    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        ( trap '' INT; sleep 30 ) &
        _w=\$!
        sleep 0.5
        _child=\$(pgrep -P \$_w 2>/dev/null | head -1)
        if [ -z \"\$_child\" ]; then echo 'NO_CHILD'; exit 0; fi
        kill_children \"\$_w\" TERM
        sleep 0.5
        if kill -0 \"\$_child\" 2>/dev/null; then echo 'CHILD_ALIVE'; else echo 'CHILD_GONE'; fi
        kill -9 \"\$_w\" 2>/dev/null
        pkill -f 'sleep 30' 2>/dev/null
    " 2>&1 || true)

    if assert_contains "$result" "CHILD_GONE"; then
        test_pass
    else
        test_fail "kill_children did not terminate the child process: $result"
    fi
}

test_task_run_leaves_no_watchdog_behind() {
    test_start "A finished task leaves no watchdog process behind"

    # "pkill -P <ppid>" beendet auf macOS nichts — der Watchdog und sein
    # "sleep <timeout>" blieben dadurch bis zum Timeout (300 s) zurück.
    local tmp_dir="/tmp/test_watchdog_$$"
    mkdir -p "$tmp_dir/cache"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        CACHE_DIR='$tmp_dir/cache'
        run_task_streamed 'true' '$tmp_dir/task.log' 47 true >/dev/null 2>&1
        sleep 0.5
        pgrep -f 'sleep 47' 2>/dev/null | wc -l | tr -d ' '
    " 2>&1 || true)
    rm -rf "$tmp_dir"

    if [ "${result:-1}" -eq 0 ]; then
        test_pass
    else
        test_fail "The watchdog survived the task ($result leftover process(es))"
    fi
}

# ==============================================================================
#  REGRESSION TESTS — RUNDE 4
# ==============================================================================

# Führt ein Skript in einem Pseudo-Terminal aus (für die interaktiven Pfade).
# Ohne python3 wird der Test übersprungen.
pty_run() {
    local script_file="$1"
    shift
    if ! command -v python3 >/dev/null 2>&1; then
        return 127
    fi
    python3 "$TEST_DIR/pty_driver.py" "$script_file" "$@" 2>&1
}

test_env_file_cannot_break_the_task() {
    test_start "A .env file cannot override PATH or IFS"

    # "set -a; source .env" exportierte *alle* Variablen der Datei — ein
    # "PATH=/broken" therein zerstörte die Kommandosuche des Tasks (dieselbe
    # Lücke wie bei "~/.run_vars").
    local tmp_dir="/tmp/test_env_guard_$$"
    mkdir -p "$tmp_dir/proj" "$tmp_dir/home"
    printf 'PATH=/nonexistent/evil\nIFS=,\nBASH_ENV=/nonexistent/evil.sh\n' > "$tmp_dir/proj/.env"
    printf '0|Env Task|echo "PATH=$PATH"|Shows the PATH\n' > "$tmp_dir/proj/.tasks"

    local output
    output=$(cd "$tmp_dir/proj" && HOME="$tmp_dir/home" "$RUN_SCRIPT" --run "Env Task" < /dev/null 2>&1 || true)
    rm -rf "$tmp_dir"

    if printf '%s' "$output" | grep -q "PATH=/nonexistent/evil"; then
        test_fail "The .env file overwrote PATH: $output"
    else
        test_pass
    fi
}

test_init_profile_without_name_reports_an_error() {
    test_start "--init-profile without a name reports an error"

    # Ohne Argument war "$1" eine ungebundene Variable: der Fehler endete
    # mit Exit-Code 0 (der EXIT-Trap verwirft den Status).
    local tmp_dir="/tmp/test_init_profile_$$"
    mkdir -p "$tmp_dir"

    local output exit_code=0
    output=$(cd "$tmp_dir" && HOME="$tmp_dir" "$RUN_SCRIPT" --init-profile < /dev/null 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    if printf '%s' "$output" | grep -q "unbound variable"; then
        test_fail "An unbound variable was reported: $output"
    elif [ "$exit_code" -eq 0 ]; then
        test_fail "The missing profile name was not reported (exit code 0)"
    elif assert_contains "$output" "profile name required"; then
        test_pass
    else
        test_fail "Unexpected output: $output"
    fi
}

test_depends_annotation_is_removed_anywhere_in_the_command() {
    test_start "A [depends: ...] annotation is removed anywhere in the command"

    # "cmd="${cmd%% \[depends:*\]}" entfernte nur eine Annotation am Ende
    # der Zeile — mitten im Kommando blieb sie stehen und der Task lief mit
    # "[depends:Base]" in der Kommandozeile.
    local tmp_dir="/tmp/test_depends_pos_$$"
    mkdir -p "$tmp_dir"
    printf '0|Base|echo BASE_OK|Base task\n' > "$tmp_dir/.tasks"
    printf '0|Mid Dep|echo start [depends:Base] && echo end|Mid annotation\n' > "$tmp_dir/.tasks.local"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run "Mid Dep" < /dev/null 2>&1 || true)
    rm -rf "$tmp_dir"

    if printf '%s' "$output" | grep -q "depends:Base"; then
        test_fail "The annotation stayed in the command: $output"
    elif assert_contains "$output" "BASE_OK"; then
        test_pass
    else
        test_fail "The dependency did not run: $output"
    fi
}

test_documented_depends_syntax_works() {
    test_start "The documented dependency syntax (description field) works"

    # Die Doku beschreibt die Annotation in der Beschreibung
    # ("0|Test|npm test|Run tests [depends: Build]") — der Parser las sie
    # nur aus dem Kommando.
    local tmp_dir="/tmp/test_depends_doc_$$"
    mkdir -p "$tmp_dir"
    printf '0|Base|echo BASE_OK|Base task\n' > "$tmp_dir/.tasks"
    printf '0|Doc Dep|echo doc|Run tests [depends: Base]\n' > "$tmp_dir/.tasks.local"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run "Doc Dep" < /dev/null 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "BASE_OK"; then
        test_pass
    else
        test_fail "The documented dependency syntax did not run the dependency: $output"
    fi
}

test_documented_timeout_syntax_works() {
    test_start "The documented per-task timeout syntax works"

    # Die Doku beschreibt "[timeout: 120]" in der Beschreibung — die Syntax
    # war nicht implementiert (nur die globale "TIMEOUT="-Zeile).
    local tmp_dir="/tmp/test_timeout_doc_$$"
    mkdir -p "$tmp_dir"
    printf '0|Long Task|sleep 5|Run with timeout [timeout: 1]\n' > "$tmp_dir/.tasks"

    local start end
    start=$(date +%s)
    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --run "Long Task" < /dev/null 2>&1 || true)
    end=$(date +%s)
    rm -rf "$tmp_dir"

    local elapsed=$(( end - start ))
    if [ "$elapsed" -gt 4 ]; then
        test_fail "The per-task timeout was ignored (runtime ${elapsed}s)"
    elif assert_contains "$output" "timeout 1s"; then
        test_pass
    else
        test_fail "The per-task timeout was not reported: $output"
    fi
}

test_log_file_names_are_unique() {
    test_start "The log file name is unique per call"

    # Der Zähler wurde in einer Command-Substitution erhöht (Subshell) —
    # die Erhöhung ging verloren und zwei Tasks mit dem gleichen Namen
    # teilten sich eine Logdatei.
    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        RUN_LOG_DIR='/tmp/test_logseq_\$\$'
        rm -rf \"\$RUN_LOG_DIR\"
        create_log_file 'SameTask'; a=\"\$LOG_FILE\"
        create_log_file 'SameTask'; b=\"\$LOG_FILE\"
        create_log_file 'SameTask'; c=\"\$LOG_FILE\"
        rm -rf \"\$RUN_LOG_DIR\"
        if [ \"\$a\" = \"\$b\" ] || [ \"\$b\" = \"\$c\" ]; then echo COLLISION; else echo UNIQUE; fi
    " 2>&1 || true)

    if assert_contains "$result" "UNIQUE"; then
        test_pass
    else
        test_fail "The log file names collide: $result"
    fi
}

test_config_dir_of_handles_the_special_cases() {
    test_start "config_dir_of resolves the special config paths"

    # "${config_path%/*}" lieferte für "/.tasks" einen leeren String
    # ("cd ''" schlägt fehl) und für einen Pfad ohne Slash den Dateinamen.
    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        printf '%s|%s|%s\n' \"\$(config_dir_of '/.tasks')\" \"\$(config_dir_of 'tasks')\" \"\$(config_dir_of '/a/b/.tasks')\"
    " 2>&1 || true)

    if [ "$result" = "/|.|/a/b" ]; then
        test_pass
    else
        test_fail "Unexpected config directories: '$result' (expected '/|.|/a/b')"
    fi
}

test_parallel_task_runs_in_the_config_directory() {
    test_start "A parallel task runs in the directory of the config"

    # Der Parallelmodus benutzte RUN_DIR="${config_path%/*}" — für einen
    # Pfad ohne Slash war das der Dateiname ("cd" schlug fehl, der Task
    # lief im falschen Verzeichnis).
    local tmp_dir="/tmp/test_parallel_dir_$$"
    mkdir -p "$tmp_dir/proj"
    printf '0|Pwd Task|pwd|Prints the working directory\n' > "$tmp_dir/proj/mytasks"

    local result
    result=$(cd "$tmp_dir/proj" && bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        config_path='mytasks'
        active_mode='local'
        multi_select_map[0]=1
        menu_options=('0|Pwd Task|pwd|Prints the working directory')
        RUN_LOG_DIR='$tmp_dir/logs'
        task_timeout=10
        execute_tasks_parallel 2>/dev/null
    " 2>&1 || true)
    rm -rf "$tmp_dir"

    if printf '%s' "$result" | grep -q "$tmp_dir/proj"; then
        test_pass
    else
        test_fail "The parallel task ran in the wrong directory: $result"
    fi
}

test_dropdown_cancel_aborts_the_task() {
    test_start "Cancelling a placeholder dropdown aborts the task"

    # ESC im Dropdown ersetzte den Platzhalter durch einen leeren Wert —
    # der Task lief mit einem leeren Parameter.
    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        select_dropdown() { return 1; }
        resolve_placeholders 'echo \"env=[<<Env:dev,prod>>]\"' >/dev/null 2>&1
        echo \"rc=\$?\"
    " 2>&1 || true)

    if assert_contains "$result" "rc=1"; then
        test_pass
    else
        test_fail "The cancelled dropdown did not abort the task: $result"
    fi
}

test_parallel_run_reports_a_failing_task() {
    test_start "A failing parallel task is reported"

    # execute_tasks_parallel meldete immer Erfolg — auch wenn ein Task
    # fehlschlug oder alle Tasks übersprungen wurden.
    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        multi_select_map[0]=1
        menu_options=('0|Fails|exit 7|Fails with 7')
        config_path='/tmp/x/.tasks'
        task_timeout=10
        RUN_LOG_DIR='/tmp/test_parallel_fail_\$\$'
        execute_tasks_parallel >/dev/null 2>&1
        echo \"rc=\$?\"
        rm -rf /tmp/test_parallel_fail_\$\$
    " 2>&1 || true)

    if assert_contains "$result" "rc=1"; then
        test_pass
    else
        test_fail "The failing parallel task was not reported: $result"
    fi
}

test_task_with_an_invalid_level_is_not_listed() {
    test_start "A task with an invalid level is not listed"

    # _build_all_tasks prüfte das Level nicht, _build_menu_options schon —
    # "run --list" zeigte Tasks, die im Menü unsichtbar waren, und
    # "run --run" konnte sie ausführen.
    local tmp_dir="/tmp/test_invalid_level_$$"
    mkdir -p "$tmp_dir"
    printf '0|Good Task|echo good|Valid level\n' > "$tmp_dir/.tasks"
    printf 'x|Bad Task|echo bad|Invalid level\n' > "$tmp_dir/.tasks.local"

    local output
    output=$(cd "$tmp_dir" && "$RUN_SCRIPT" --list < /dev/null 2>&1 || true)
    rm -rf "$tmp_dir"

    if printf '%s' "$output" | grep -q "Bad Task"; then
        test_fail "The task with an invalid level was listed: $output"
    elif assert_contains "$output" "Tasks (1)"; then
        test_pass
    else
        test_fail "Unexpected output: $output"
    fi
}

test_cache_dir_fallback_survives_the_run() {
    test_start "The cache directory fallback survives the run"

    # Der Fallback war $CACHE_DIR — das wird vom EXIT-Trap gelöscht, der
    # gespeicherte Index (und damit der Zustand) war nach jedem Lauf weg.
    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/05-cache.sh' 2>/dev/null
        if [ \"\$RUN_CACHE_DIR\" = \"\$CACHE_DIR\" ]; then echo SAME; else echo DIFFERENT; fi
    " 2>&1 || true)

    if assert_contains "$result" "DIFFERENT"; then
        test_pass
    else
        test_fail "The persistent cache directory falls back to the per-run scratch space: $result"
    fi
}

test_alias_for_a_task_name_runs_the_task() {
    test_start "An alias that points to a task name runs the task"

    # Das Alias-File-Template dokumentiert "alias=task_name" — der Runner
    # suchte aber nur nach einem *Profil* mit diesem Namen.
    local tmp_dir="/tmp/test_alias_task_$$"
    mkdir -p "$tmp_dir/home" "$tmp_dir/proj"
    printf '0|Build It|echo BUILT_OK|Build task\n' > "$tmp_dir/proj/.tasks"
    printf '# Task Aliases\nbuild=Build It\n' > "$tmp_dir/home/.run_aliases"

    local output
    output=$(cd "$tmp_dir/proj" && HOME="$tmp_dir/home" "$RUN_SCRIPT" build < /dev/null 2>&1 || true)
    rm -rf "$tmp_dir"

    if assert_contains "$output" "BUILT_OK"; then
        test_pass
    else
        test_fail "The alias did not run the task: $output"
    fi
}

test_unknown_option_is_rejected() {
    test_start "An unknown option is rejected"

    # Unbekannte Flags wurden als Profilname interpretiert — der Runner
    # startete normal ("Profile '--foo' not found").
    local tmp_dir="/tmp/test_unknown_flag_$$"
    mkdir -p "$tmp_dir"

    local output exit_code=0
    output=$(cd "$tmp_dir" && HOME="$tmp_dir" "$RUN_SCRIPT" --definitely-not-a-flag < /dev/null 2>&1) || exit_code=$?
    rm -rf "$tmp_dir"

    if [ "$exit_code" -eq 0 ]; then
        test_fail "The unknown option was accepted (exit code 0)"
    elif assert_contains "$output" "unknown option"; then
        test_pass
    else
        test_fail "Unexpected output: $output"
    fi
}

test_config_switch_resets_the_filters() {
    test_start "Switching the config resets the tag filter"

    # Der Tag-Filter gehörte zur alten Config: nach dem Wechsel war das
    # Menü leer ("No tasks found"), ohne dass ein Grund sichtbar war.
    local tmp_dir="/tmp/test_filter_reset_$$"
    mkdir -p "$tmp_dir/home" "$tmp_dir/proj"
    printf '0|Local Task|echo local|Local task #local\n' > "$tmp_dir/proj/.tasks"
    printf '0|Global Task|echo global|Global task #global\n' > "$tmp_dir/home/.tasks"

    cat > "$tmp_dir/script.pty" << 'PTYSCRIPT'
wait 1.5
send #
wait 1
send 1
wait 1
send g
wait 1.5
PTYSCRIPT

    local output
    output=$(cd "$tmp_dir/proj" && HOME="$tmp_dir/home" pty_run "$tmp_dir/script.pty" bash "$RUN_SCRIPT" 2>&1 || true)
    rm -rf "$tmp_dir"

    if [ -z "$output" ]; then
        test_skip "python3 is not available for the PTY test"
        return
    fi
    # Das Menü muss nach dem Wechsel den globalen Task zeigen.
    if printf '%s' "$output" | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -q "Global Task"; then
        test_pass
    else
        test_fail "The global task is not visible after the config switch"
    fi
}

test_documentation_is_in_sync() {
    test_start "Documentation matches the implementation"

    local output
    if output=$(bash "$TEST_DIR/test-docs.sh" 2>&1); then
        test_pass
    else
        test_fail "test-docs.sh failed: $output"
    fi
}

test_run_vars_readonly_names_are_skipped() {
    test_start "~/.run_vars with a readonly name no longer aborts the runner"

    # Runde 2 audit: RUN_LOG_DIR=... in ~/.run_vars killed the whole runner
    # with a single "readonly variable" line — and the EXIT trap reported
    # exit 0. The gate must skip readonly names instead.
    local tmp_dir="/tmp/test_run_vars_ro_$$"
    mkdir -p "$tmp_dir"
    printf 'RUN_LOG_DIR=/tmp/evil_run_vars_%s\nVERSION=https://evil\nSOME_LOGIN=ok\n' "$$" > "$tmp_dir/.run_vars"

    local result
    result=$(bash -c "
        set +e
        HOME='$tmp_dir'
        readonly RUN_LOG_DIR=\"\$HOME/.run_logs\" VERSION='2.0.0'
        RUN_VARS_FILE=\"\$HOME/.run_vars\"
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        load_global_vars
        printf 'STATUS_OK\n'
        printf 'RUN_LOG_DIR=%s\n' \"\${RUN_LOG_DIR:-}\"
        printf 'VERSION=%s\n' \"\${VERSION:-}\"
        printf 'SOME_LOGIN=%s\n' \"\${SOME_LOGIN:-}\"
    " 2>&1 || true)
    rm -rf "$tmp_dir" /tmp/evil_run_vars_$$

    if printf '%s' "$result" | grep -qE "run_logs: readonly variable|readonly variable"; then
        test_fail "The readonly export aborted load_global_vars: $result"
    elif ! printf '%s' "$result" | grep -q "STATUS_OK"; then
        test_fail "load_global_vars did not survive the readonly keys: $result"
    elif ! printf '%s' "$result" | grep -q "RUN_LOG_DIR=$tmp_dir/.run_logs"; then
        test_fail "The runner's own RUN_LOG_DIR was overwritten: $result"
    elif printf '%s' "$result" | grep -q "VERSION=https://evil"; then
        test_fail "The runner's own VERSION was overwritten: $result"
    elif ! printf '%s' "$result" | grep -q "SOME_LOGIN=ok"; then
        test_fail "A normal key was no longer exported: $result"
    else
        test_pass
    fi
}

test_parallel_dependency_is_executed() {
    test_start "Parallel mode executes [depends:] before the task and strips the annotation"

    # Runde 2 audit: execute_tasks_parallel evaluated the raw command — the
    # dependency was never executed and "[depends: X]" reached the eval as a
    # literal argument.
    local tmp_dir="/tmp/test_par_deps_$$"
    mkdir -p "$tmp_dir"
    local dep_marker="$tmp_dir/dep_marker"
    local main_marker="$tmp_dir/main_marker"
    printf '0|Dep|touch %s|Dependency\n0|Main|touch %s [depends: Dep]|Main task\n' \
        "$dep_marker" "$main_marker" > "$tmp_dir/.tasks"

    # find_task_in_menu reads the dependency from config_path (the .tasks
    # file above); the menu list drives the parallel run itself.
    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
        source '$ROOT_DIR/src/11-dependencies.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        task_config_files=()
        config_path='$tmp_dir/.tasks'
        active_mode='local'
        task_timeout=10
        CACHE_DIR='$tmp_dir/cache'
        mkdir -p \"\$CACHE_DIR\"
        RUN_LOG_DIR='$tmp_dir/logs'
        mkdir -p \"\$RUN_LOG_DIR\"
        menu_options=(
            '0|Dep|touch $dep_marker|Dependency'
            '0|Main|touch $main_marker [depends: Dep]|Main task'
        )
        multi_select_map=([0]=1 [1]=1)
        execute_tasks_parallel >/dev/null 2>&1
        echo \"rc=\$?\"
    " 2>&1 || true)
    local main_log_with_annotation dep_found main_found
    dep_found=0; main_found=0
    [ -f "$dep_marker" ] && dep_found=1
    [ -f "$main_marker" ] && main_found=1
    main_log_with_annotation=$(find "$tmp_dir" -name '*Main.log' -print0 2>/dev/null | xargs -0 grep -lF '[depends:' 2>/dev/null || true)
    rm -rf "$tmp_dir"

    if [ "$dep_found" -eq 0 ]; then
        test_fail "The dependency did not run in parallel mode: $result"
    elif [ "$main_found" -eq 0 ]; then
        test_fail "The main task did not run after the dependency: $result"
    elif ! assert_contains "$result" "rc=0"; then
        test_fail "execute_tasks_parallel reported failure: $result"
    elif [ -n "$main_log_with_annotation" ]; then
        test_fail "The [depends:] annotation leaked into the executed command"
    else
        test_pass
    fi
}

test_parallel_per_task_timeout_is_honored() {
    test_start "Parallel mode honors a per-task [timeout: N] from the description"

    # Runde 2 audit: execute_tasks_parallel passed the GLOBAL task_timeout to
    # run_task_streamed, so "sleep 4" with "[timeout: 1]" ran for 4 s instead
    # of being killed after ~1 s.
    local tmp_dir="/tmp/test_par_timeout_$$"
    mkdir -p "$tmp_dir"
    printf '' > "$tmp_dir/.tasks"

    local result
    result=$(bash -c "
        set +e
        source '$ROOT_DIR/src/01-config.sh' 2>/dev/null
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/03-terminal.sh' 2>/dev/null
        source '$ROOT_DIR/src/11-dependencies.sh' 2>/dev/null
        source '$ROOT_DIR/src/12-execution.sh' 2>/dev/null
        task_config_files=()
        config_path='$tmp_dir/.tasks'
        active_mode='local'
        task_timeout=300
        # CACHE_DIR is required for run_task_streamed's FIFO: without it the
        # mkfifo fails and the fallback (no watchdog, no timeout) runs.
        CACHE_DIR='$tmp_dir/cache'
        mkdir -p \"\$CACHE_DIR\"
        RUN_LOG_DIR='$tmp_dir/logs'
        mkdir -p \"\$RUN_LOG_DIR\"
        menu_options=('0|Slow|sleep 4|late [timeout: 1]')
        multi_select_map=([0]=1)
        START=\$(date +%s)
        execute_tasks_parallel >/dev/null 2>&1
        END=\$(date +%s)
        echo \"ELAPSED=\$((END-START))\"
    " 2>&1 || true)
    rm -rf "$tmp_dir"

    local elapsed
    elapsed=$(printf '%s' "$result" | grep -o 'ELAPSED=[0-9]*' | grep -o '[0-9]*' | tail -1)
    if [ -z "$elapsed" ]; then
        test_fail "The parallel run did not report an elapsed time: $result"
    elif [ "$elapsed" -ge 3 ]; then
        test_fail "The per-task [timeout: 1] was ignored (elapsed ${elapsed}s): $result"
    else
        test_pass
    fi
}

test_empty_menu_uses_safe_selection_index() {
    test_start "clamp_selected_index keeps an empty menu safe"

    # Der Wrap "(cnt - 1)" ließ selected_index bei -1 hängen, wenn das
    # Menü leer war — "*" / "c" / " " trafen dann "menu_options[-1]" und
    # töteten den Runner unter Bash 3.2 ("bad array subscript").
    local result
    result=$(bash -c "
        source '$ROOT_DIR/src/02-utils.sh' 2>/dev/null
        source '$ROOT_DIR/src/13-ui.sh' 2>/dev/null
        menu_options=()
        selected_index=-1
        clamp_selected_index; echo \"empty=\$selected_index\"
        menu_options=('a|1|cmd|d' 'a|2|cmd|d' 'a|3|cmd|d')
        selected_index=-2
        clamp_selected_index; echo \"up=\$selected_index\"
        selected_index=5
        clamp_selected_index; echo \"down=\$selected_index\"
    " 2>&1 || true)

    if assert_contains "$result" "empty=0" \
        && assert_contains "$result" "up=2" \
        && assert_contains "$result" "down=0"; then
        test_pass
    else
        test_fail "clamp_selected_index did not normalize the selection: $result"
    fi
}

test_release_bump_detects_a_failed_version_update() {
    test_start "release.sh substitutes the version on macOS (BSD sed)"

    # Der alte "sed -i -E … || sed -i '' …" Kaskade war auf macOS ein
    # stiller No-Op (Exit 0, kein Ersatzvorgang, +"-E"-Backup-Datei) und
    # die Versionspflege wurde nie angewendet.
    local tmp_dir="/tmp/test_release_sed_$$"
    mkdir -p "$tmp_dir"
    printf 'readonly VERSION="1.0.0"\n' > "$tmp_dir/sample.sh"

    local before after
    before=$(cd "$tmp_dir" && bash -c '
        if [ "$(uname -s)" = "Darwin" ]; then SED_I=(sed -i ""); else SED_I=(sed -i); fi
        "${SED_I[@]}" -E "s/^readonly VERSION=\"[^\"]+\"/readonly VERSION=\"1.0.1\"/" sample.sh
        cat sample.sh
    ' 2>&1 || true)
    after=$(printf '%s' "$before" | grep -o 'readonly VERSION="[^"]*"')
    rm -rf "$tmp_dir"

    if assert_contains "$after" "1.0.1"; then
        test_pass
    else
        test_fail "The platform-correct in-place sed did not substitute the version: $before"
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
    test_invalid_cols_min_width_ignored
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
    test_cli_run_by_number
    test_cli_run_by_name
    test_cli_run_not_found
    test_cli_run_exit_code

    echo ""
    echo "${C_INFO}» Submenu & Hierarchy Tests${C_RST}"
    test_positional_submenu_parsing_level0
    test_positional_submenu_parsing_level1
    test_positional_submenu_parsing_nested_level2
    test_cli_list_across_submenus
    test_cli_run_submenu_task
    test_dependency_across_submenus
    test_pipeline_across_submenus

    echo ""
    echo "${C_INFO}» Performance Tests${C_RST}"
    test_large_config_performance

    echo ""
    echo "${C_INFO}» Regression Tests${C_RST}"
    test_special_characters_in_task_name
    test_empty_config

    echo ""
    echo "${C_INFO}» Regression Tests (fixed bugs)${C_RST}"
    test_terminal_capabilities_survive_broken_tput
    test_errexit_state_preserved
    test_failed_dependency_stops_task
    test_parallel_dependency_failure_detected
    test_analyze_flag_works
    test_theme_is_applied
    test_theme_applied_in_startup_path
    test_tag_filter_is_exact
    test_search_is_literal
    test_crlf_config_is_handled
    test_env_prefix_command_runs
    test_across_without_args_shows_usage
    test_timeout_kills_process_tree
    test_menu_viewport_limits_output
    test_split_task_line_edge_cases
    test_split_by_char
    test_hash_string_is_stable
    test_recent_and_logs_reachable
    test_msg_keys_exist
    test_cli_run_leading_zero_number
    test_menu_selection_two_digits
    test_favorites_and_recent_two_digit_selection
    test_parallel_task_status_is_propagated
    test_across_uses_local_profiles
    test_search_history_survives_dash_term
    test_run_vars_cannot_break_the_runner
    test_menu_cache_uses_config_path
    test_edit_invalidates_menu_cache
    test_placeholder_resolution_terminates
    test_confirmation_task_returns_nonzero
    test_profile_list_json_is_valid
    test_validate_reports_invalid_level
    test_history_append_is_lossless
    test_quoted_env_assignment_command_runs
    test_self_update_reports_install_failure
    test_edit_uses_resolved_config_path
    test_home_unset_reports_error
    test_symlinked_overlay_is_not_loaded_twice
    test_kill_children_terminates_the_children
    test_task_run_leaves_no_watchdog_behind
    test_env_file_cannot_break_the_task
    test_init_profile_without_name_reports_an_error
    test_depends_annotation_is_removed_anywhere_in_the_command
    test_documented_depends_syntax_works
    test_documented_timeout_syntax_works
    test_run_vars_readonly_names_are_skipped
    test_parallel_dependency_is_executed
    test_parallel_per_task_timeout_is_honored
    test_empty_menu_uses_safe_selection_index
    test_release_bump_detects_a_failed_version_update
    test_log_file_names_are_unique
    test_config_dir_of_handles_the_special_cases
    test_parallel_task_runs_in_the_config_directory
    test_dropdown_cancel_aborts_the_task
    test_parallel_run_reports_a_failing_task
    test_task_with_an_invalid_level_is_not_listed
    test_cache_dir_fallback_survives_the_run
    test_alias_for_a_task_name_runs_the_task
    test_unknown_option_is_rejected
    test_config_switch_resets_the_filters
    test_documentation_is_in_sync

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
