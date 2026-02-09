#!/bin/bash
# ==============================================================================
#  SHELL MENU RUNNER BUILD SCRIPT
#  Combines modular source files into single deployable run.sh
# ==============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR="$SCRIPT_DIR/src"
readonly OUTPUT_FILE="$SCRIPT_DIR/run.sh"
readonly TEMP_FILE="/tmp/run-build-$$.sh"

# Color output
COLOR_INFO=$'\e[33m'
COLOR_SUCCESS=$'\e[1;32m'
COLOR_ERROR=$'\e[1;31m'
COLOR_RESET=$'\e[0m'

info() { echo -e "${COLOR_INFO}$*${COLOR_RESET}"; }
success() { echo -e "${COLOR_SUCCESS}✔ $*${COLOR_RESET}"; }
error() { echo -e "${COLOR_ERROR}✘ $*${COLOR_RESET}"; exit 1; }

# ==============================================================================
#  BUILD CONFIGURATION
# ==============================================================================

# Module order (numeric prefix ensures correct order)
MODULES=(
    "00-header.sh"
    "01-config.sh"
    "02-utils.sh"
    "03-terminal.sh"
    "04-themes.sh"
    "05-cache.sh"
    "06-profiles.sh"
    "07-search.sh"
    "08-tags.sh"
    "09-favorites.sh"
    "10-logs.sh"
    "11-dependencies.sh"
    "12-execution.sh"
    "13-ui.sh"
    "14-browser.sh"
    "15-editor.sh"
    "16-main.sh"
)

# ==============================================================================
#  BUILD FUNCTIONS
# ==============================================================================

check_modules() {
    info "Checking source modules..."
    local missing=0
    
    for module in "${MODULES[@]}"; do
        if [ ! -f "$SRC_DIR/$module" ]; then
            error "Missing module: $module"
            missing=1
        fi
    done
    
    [ "$missing" -eq 0 ] && success "All modules found"
}

build_full() {
    info "Building full version..."
    
    # Start with empty temp file
    > "$TEMP_FILE"
    
    # Combine all modules
    for module in "${MODULES[@]}"; do
        info "  + $module"
        
        # Skip shebang in non-header modules
        if [ "$module" != "00-header.sh" ]; then
            grep -v '^#!/bin/bash' "$SRC_DIR/$module" >> "$TEMP_FILE" || true
        else
            cat "$SRC_DIR/$module" >> "$TEMP_FILE"
        fi
        
        # Add separator comment
        echo "" >> "$TEMP_FILE"
    done
    
    # Move to output
    mv "$TEMP_FILE" "$OUTPUT_FILE"
    chmod +x "$OUTPUT_FILE"
    
    success "Built: $OUTPUT_FILE"
}

build_minified() {
    info "Building minified version..."
    
    # Build full version first
    build_full
    
    # Create minified version (remove comments, empty lines)
    local min_file="$SCRIPT_DIR/run.min.sh"
    
    grep -v '^[[:space:]]*#' "$OUTPUT_FILE" | \
    grep -v '^[[:space:]]*$' > "$min_file"
    
    chmod +x "$min_file"
    
    success "Built: $min_file"
}

calculate_stats() {
    info "Build statistics:"
    
    local total_lines=0
    local total_size=0
    
    for module in "${MODULES[@]}"; do
        local file="$SRC_DIR/$module"
        local lines=$(wc -l < "$file" | tr -d ' ')
        local size=$(wc -c < "$file" | tr -d ' ')
        
        total_lines=$((total_lines + lines))
        total_size=$((total_size + size))
        
        printf "  %-20s %5d lines  %6d bytes\n" "$module" "$lines" "$size"
    done
    
    echo ""
    printf "  %-20s %5d lines  %6d bytes\n" "TOTAL" "$total_lines" "$total_size"
    
    if [ -f "$OUTPUT_FILE" ]; then
        local output_lines=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
        local output_size=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
        printf "  %-20s %5d lines  %6d bytes\n" "run.sh" "$output_lines" "$output_size"
        
        # Calculate SHA256
        if command -v shasum &>/dev/null; then
            local sha=$(shasum -a 256 "$OUTPUT_FILE" | cut -d' ' -f1)
            echo ""
            info "SHA256: $sha"
        fi
    fi
}

validate_syntax() {
    info "Validating syntax..."
    
    if bash -n "$OUTPUT_FILE"; then
        success "Syntax valid"
    else
        error "Syntax errors found"
    fi
}

run_shellcheck() {
    if command -v shellcheck &>/dev/null; then
        info "Running shellcheck..."
        if shellcheck -x "$OUTPUT_FILE"; then
            success "ShellCheck passed"
        else
            error "ShellCheck found issues"
        fi
    else
        info "ShellCheck not available (skipping)"
    fi
}

show_help() {
    cat << 'EOF'
Shell Menu Runner Build Script

Usage:
  ./build.sh [OPTIONS]

Options:
  -h, --help      Show this help
  -f, --full      Build full version (default)
  -m, --min       Build minified version
  -s, --stats     Show build statistics
  -v, --validate  Validate syntax
  -c, --check     Run shellcheck
  -a, --all       Run all: build, validate, check, stats

Examples:
  ./build.sh              # Build full version
  ./build.sh --all        # Build and run all checks
  ./build.sh --min        # Build minified version
EOF
}

# ==============================================================================
#  MAIN
# ==============================================================================

main() {
    local mode="full"
    local run_stats=0
    local run_validate=0
    local run_shellcheck=0
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -f|--full)
                mode="full"
                shift
                ;;
            -m|--min)
                mode="min"
                shift
                ;;
            -s|--stats)
                run_stats=1
                shift
                ;;
            -v|--validate)
                run_validate=1
                shift
                ;;
            -c|--check)
                run_shellcheck=1
                shift
                ;;
            -a|--all)
                run_stats=1
                run_validate=1
                run_shellcheck=1
                shift
                ;;
            *)
                error "Unknown option: $1 (use --help)"
                ;;
        esac
    done
    
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║  Shell Menu Runner Build System                          ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    
    check_modules
    
    case "$mode" in
        full)
            build_full
            ;;
        min)
            build_minified
            ;;
    esac
    
    [ "$run_validate" -eq 1 ] && validate_syntax
    [ "$run_shellcheck" -eq 1 ] && run_shellcheck
    [ "$run_stats" -eq 1 ] && calculate_stats
    
    echo ""
    success "Build complete!"
}

main "$@"
