#!/bin/bash
# ==============================================================================
#  DOCUMENTATION CONSISTENCY TESTS
#
#  Guards the documentation and the AI instruction files against drift:
#  helpers, keys, CLI flags and task examples must match the implementation.
#
#  Usage: bash build-platform/tests/test-docs.sh
# ==============================================================================

set -euo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
readonly SRC_DIR="$ROOT_DIR/src"
readonly RUN_SCRIPT="$ROOT_DIR/run.sh"
readonly CLAUDE_FILE="$ROOT_DIR/CLAUDE.md"
readonly ARCH_FILE="$ROOT_DIR/docs/ARCHITECTURE.md"
readonly CLI_DOC="$ROOT_DIR/docs/CLI_REFERENCE.md"
readonly KEY_DOC="$ROOT_DIR/docs/KEYBOARD_SHORTCUTS.md"
readonly COPILOT_FILE="$ROOT_DIR/.github/copilot-instructions.md"

C_OK=$'\e[1;32m'; C_FAIL=$'\e[1;31m'; C_RST=$'\e[0m'
FAILURES=0

pass() { printf '  %sok%s   %s\n' "$C_OK" "$C_RST" "$1"; }
fail() {
    printf '  %sfail%s %s\n' "$C_FAIL" "$C_RST" "$1"
    FAILURES=$((FAILURES + 1))
}

# Reads a function body from src/ (top-level functions end with "}" in column 0).
function_body() {
    local name="$1" file="$2"
    sed -n "/^${name}()/,/^}/p" "$file"
}

has_text() {
    local file="$1" text="$2"
    grep -Fq -- "$text" "$file"
}

# ------------------------------------------------------------------------------
# 1. Helper names used in the docs must exist in src/
# ------------------------------------------------------------------------------
test_documented_helpers_exist() {
    local doc missing=""
    local name
    for doc in "$CLAUDE_FILE" "$ARCH_FILE"; do
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            if ! grep -rqE "^[[:space:]]*${name}\\(\\)" "$SRC_DIR"; then
                missing="$missing $name"
            fi
        done < <(grep -oE '`[a-z_][a-z0-9_]*\(\)' "$doc" | tr -d '`()' | sort -u)
    done

    if [ -z "$missing" ]; then
        pass "every documented helper exists in src/"
    else
        fail "helpers documented but missing in src/:$missing"
    fi
}

# ------------------------------------------------------------------------------
# 2. Every function of src/ is mentioned in CLAUDE.md or ARCHITECTURE.md
# ------------------------------------------------------------------------------
test_all_helpers_documented() {
    local missing="" name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if ! grep -Fqw -- "$name" "$CLAUDE_FILE" "$ARCH_FILE"; then
            missing="$missing $name"
        fi
    done < <(grep -hoE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$SRC_DIR"/*.sh \
        | sed 's/^[[:space:]]*//; s/()$//' | sort -u)

    if [ -z "$missing" ]; then
        pass "every src/ function is documented in CLAUDE.md or ARCHITECTURE.md"
    else
        fail "src/ functions missing from the docs:$missing"
    fi
}

# ------------------------------------------------------------------------------
# 3. Documented keys exist in the matching key handler
# ------------------------------------------------------------------------------
check_key() {
    local doc="$1" function="$2" file="$3" token="$4" pattern="$5"
    local body
    body=$(function_body "$function" "$file")
    if ! grep -Fq -- "\`$token\`" "$doc"; then
        fail "key '$token' of $function missing in $doc"
        return
    fi
    if ! printf '%s' "$body" | grep -Fq -- "$pattern"; then
        fail "key '$token' documented but no handler '$pattern' in $function"
    fi
}

test_main_keys() {
    local before=$FAILURES
    local ui="$SRC_DIR/13-ui.sh"
    check_key "$KEY_DOC" main_interactive_loop "$ui" "↑" "\$'\\x1b[A'"
    check_key "$KEY_DOC" main_interactive_loop "$ui" "↓" "\$'\\x1b[B'"
    check_key "$KEY_DOC" main_interactive_loop "$ui" "←" "\$'\\x1b[D'"
    check_key "$KEY_DOC" main_interactive_loop "$ui" "→" "\$'\\x1b[C'"
    check_key "$KEY_DOC" main_interactive_loop "$ui" "Esc" "\$'\\x1b')"
    check_key "$KEY_DOC" main_interactive_loop "$ui" "k" '"k")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "j" '"j")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "h" '"h")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "l" '"l")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "Space" '" ")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "1" '[1-9])'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "/" '"/")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "Enter" "\$'\\r'"
    check_key "$KEY_DOC" main_interactive_loop "$ui" "s" '"s")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "e" '"e"|"E")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "f" '"f"|"F")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "a" '"a"|"A")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "#" '"#")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "g" '"g")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "p" '"p"|"P")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "?" '"?"'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "!" '"!")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "r" '"r")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "R" '"R")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "L" '"L")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "c" '"c"|"C")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "*" '"*")'
    check_key "$KEY_DOC" main_interactive_loop "$ui" "q" '"q"|"Q")'
    if [ "$FAILURES" -eq "$before" ]; then
        pass "main menu keys match src/13-ui.sh"
    fi
}

test_submenu_keys() {
    local before=$FAILURES
    local editor="$SRC_DIR/15-editor.sh" profiles="$SRC_DIR/06-profiles.sh"
    local tags="$SRC_DIR/08-tags.sh" browser="$SRC_DIR/14-browser.sh"

    check_key "$KEY_DOC" settings_menu "$editor" "1" '"1")'
    check_key "$KEY_DOC" settings_menu "$editor" "2" '"2")'
    check_key "$KEY_DOC" settings_menu "$editor" "3" '"3")'
    check_key "$KEY_DOC" settings_menu "$editor" "4" '"4")'
    check_key "$KEY_DOC" settings_menu "$editor" "5" '"5")'
    check_key "$KEY_DOC" settings_menu "$editor" "0" '"0"'
    check_key "$KEY_DOC" select_profile_menu "$profiles" "p" 'p) if'
    check_key "$KEY_DOC" select_profile_menu "$profiles" "n" 'n) if'
    check_key "$KEY_DOC" select_profile_menu "$profiles" "/" '/) filter_active=1'
    check_key "$KEY_DOC" select_profile_menu "$profiles" "0" '0) return 1'
    check_key "$KEY_DOC" select_profile_menu "$profiles" "q" 'q|Q) return 1'
    check_key "$KEY_DOC" show_tag_menu "$tags" "0" '"0")'
    check_key "$KEY_DOC" show_tag_menu "$tags" "q" '"q"'
    check_key "$KEY_DOC" edit_config_menu "$editor" "2" '"2")'
    check_key "$KEY_DOC" edit_config_menu "$editor" "3" '"3")'
    check_key "$KEY_DOC" edit_config_menu "$editor" "0" '"0"'
    check_key "$KEY_DOC" file_browser "$browser" "1" '"1")'
    check_key "$KEY_DOC" file_browser "$browser" "4" '"4")'
    check_key "$KEY_DOC" file_browser "$browser" "0" '"0"'
    pass "submenu keys match the handler functions"
}

test_no_phantom_keys() {
    local phantom
    for phantom in 'Page Up' 'Page Down' 'Ctrl+F' 'Ctrl+U' 'Ctrl+X' 'Ctrl+D' \
                   'Ctrl+S' 'Ctrl+P' 'Ctrl+E' 'Ctrl+,' '`A-Z`'; do
        if has_text "$KEY_DOC" "$phantom"; then
            fail "phantom key still documented: $phantom"
        fi
    done
    pass "no phantom keys in KEYBOARD_SHORTCUTS.md"
}

# ------------------------------------------------------------------------------
# 4. CLI flags: docs <-> parser <-> --help
# ------------------------------------------------------------------------------
test_cli_flags() {
    local main="$SRC_DIR/16-main.sh"
    local help_out flags flag missing=""
    flags="--help -h --version -v --debug --across --init --list-profiles \
--init-profile --validate --analyze --update --global --edit -e --run --dry-run --list"

    help_out=$("$RUN_SCRIPT" --help 2>/dev/null || true)
    for flag in $flags; do
        if ! has_text "$CLI_DOC" "$flag"; then
            missing="$missing $flag(doc)"
        fi
        if ! has_text "$main" "$flag"; then
            missing="$missing $flag(parser)"
        fi
        if ! printf '%s' "$help_out" | grep -Fq -- "$flag"; then
            missing="$missing $flag(help)"
        fi
    done

    if [ -z "$missing" ]; then
        pass "CLI flags match docs, parser and --help"
    else
        fail "CLI flag drift:$missing"
    fi
}

test_no_phantom_flags() {
    local files="$ROOT_DIR/README.md $ROOT_DIR/README.dev.md $ROOT_DIR/BUILD_PLATFORM.md"
    local doc
    for doc in "$ROOT_DIR"/docs/*.md; do files="$files $doc"; done
    if grep -nE -- '--(task|no-menu|parallel|status|profile|verbose|quiet)[[:space:]"=]' $files 2>/dev/null; then
        fail "phantom CLI flag documented (see matches above)"
    else
        pass "no phantom CLI flags in the documentation"
    fi
}

test_no_stale_helper_refs() {
    local files="$CLAUDE_FILE $COPILOT_FILE $ROOT_DIR/.claude/commands/build.md \
$ROOT_DIR/.claude/commands/check-perf.md"
    if grep -nE 'get_file_mtime|context_menu' $files 2>/dev/null; then
        fail "stale helper reference in AI instructions (see matches above)"
    else
        pass "AI instruction files contain no removed helpers"
    fi
}

# ------------------------------------------------------------------------------
# 5. Declared line count in CLAUDE.md matches run.sh
# ------------------------------------------------------------------------------
test_declared_line_count() {
    local declared actual diff
    declared=$(grep -oE '~[0-9]+ lines' "$CLAUDE_FILE" | head -n1 | tr -cd '0-9')
    actual=$(wc -l < "$RUN_SCRIPT" | tr -d ' ')
    if [ -z "$declared" ]; then
        fail "CLAUDE.md has no line-count declaration"
        return
    fi
    diff=$(( declared > actual ? declared - actual : actual - declared ))
    if [ "$diff" -le 500 ]; then
        pass "CLAUDE.md line count (~$declared) matches run.sh ($actual)"
    else
        fail "CLAUDE.md says ~$declared lines, run.sh has $actual"
    fi
}

# ------------------------------------------------------------------------------
# 6. All shipped task examples and installer templates are valid
# ------------------------------------------------------------------------------
test_examples_and_templates_validate() {
    local tmp failed="" profile
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/run-docs.XXXXXX") || {
        fail "cannot create temporary directory"
        return
    }

    for file in "$ROOT_DIR"/docs/examples/*.tasks; do
        profile="$(basename "$file" .tasks)"
        cp "$file" "$tmp/.tasks.$profile"
        if ! ( cd "$tmp" && HOME="$tmp" "$RUN_SCRIPT" --validate "$profile" >/dev/null 2>&1 ); then
            failed="$failed $file"
        fi
    done

    # Every "cat > "$HOME/.tasks.NAME" <<'EOF'" block in install.sh.
    local line_no name start
    while IFS=: read -r line_no _; do
        name=$(sed -n "${line_no}p" "$ROOT_DIR/install.sh" \
            | sed -E 's/.*\.tasks\.([A-Za-z0-9_-]+)".*/\1/')
        start=$((line_no + 1))
        sed -n "${start},/^EOF$/p" "$ROOT_DIR/install.sh" \
            | sed '$d' > "$tmp/.tasks.$name"
        if ! ( cd "$tmp" && HOME="$tmp" "$RUN_SCRIPT" --validate "$name" >/dev/null 2>&1 ); then
            failed="$failed install.sh:$name"
        fi
    done < <(grep -n 'cat > "\$HOME/\.tasks\.[A-Za-z0-9_-]*" <<' "$ROOT_DIR/install.sh")

    rm -rf "$tmp"

    if [ -z "$failed" ]; then
        pass "all docs examples and install.sh templates validate"
    else
        fail "invalid task files:$failed"
    fi
}

# ------------------------------------------------------------------------------
main() {
    echo "Documentation consistency:"
    test_documented_helpers_exist
    test_all_helpers_documented
    test_main_keys
    test_submenu_keys
    test_no_phantom_keys
    test_cli_flags
    test_no_phantom_flags
    test_no_stale_helper_refs
    test_declared_line_count
    test_examples_and_templates_validate

    echo ""
    if [ "$FAILURES" -gt 0 ]; then
        echo "${C_FAIL}$FAILURES documentation check(s) failed${C_RST}"
        return 1
    fi
    echo "${C_OK}All documentation checks passed${C_RST}"
    return 0
}

main "$@"
