#!/bin/bash
# ==============================================================================
#  SHELL MENU RUNNER - BUILD PLATFORM
#  Multi-target build orchestrator with testing, packaging & deployment
# ==============================================================================

set -euo pipefail

readonly BP_VERSION="1.0.0"
readonly BP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BP_BUILD_DIR="$BP_ROOT/build-platform"
readonly BP_OUTPUT_DIR="$BP_ROOT/dist"
readonly BP_CACHE_DIR="$BP_ROOT/.build-cache"
readonly BP_LOG_DIR="$BP_ROOT/.build-logs"

# Colors
C_HEAD=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'
C_ERR=$'\e[1;31m'; C_DIM=$'\e[2m'; C_INFO=$'\e[33m'
C_RST=$'\e[0m'; C_BOLD=$'\e[1m'

# Logging
log_info() { echo -e "${C_INFO}ℹ $*${C_RST}"; }
log_success() { echo -e "${C_OK}✔ $*${C_RST}"; }
log_warn() { echo -e "${C_WARN}⚠ $*${C_RST}"; }
log_error() { echo -e "${C_ERR}✘ $*${C_RST}" >&2; }
log_step() { echo -e "${C_HEAD}▶ $*${C_RST}"; }
log_dim() { echo -e "${C_DIM}$*${C_RST}"; }

# Progress tracking
TOTAL_STEPS=0
CURRENT_STEP=0

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    log_step "[$CURRENT_STEP/$TOTAL_STEPS] $*"
}

# Initialize directories
init_build_env() {
    mkdir -p "$BP_OUTPUT_DIR" "$BP_CACHE_DIR" "$BP_LOG_DIR"
    
    # Create build log with timestamp
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    export BP_LOG_FILE="$BP_LOG_DIR/build_${timestamp}.log"
    
    log_info "Build Platform v$BP_VERSION"
    log_dim "Root: $BP_ROOT"
    log_dim "Output: $BP_OUTPUT_DIR"
    log_dim "Log: $BP_LOG_FILE"
    echo ""
    
    # Auto-cleanup old logs (keep last 10)
    cleanup_old_logs
}

# ==============================================================================
#  BUILD CACHE & OPTIMIZATION
# ==============================================================================

# Get hash of source file for cache checking
get_source_hash() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" 2>/dev/null | cut -d' ' -f1
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1
    else
        # Fallback: use file modification time + size
        stat -f "%m-%z" "$file" 2>/dev/null || stat -c "%Y-%s" "$file" 2>/dev/null
    fi
}

# Check if build is needed (incremental build)
needs_rebuild() {
    local source="$1"
    local target="$2"
    
    # If target doesn't exist, rebuild
    [ ! -f "$target" ] && return 0
    
    # If source is newer than target, rebuild
    [ "$source" -nt "$target" ] && return 0
    
    # No rebuild needed
    return 1
}

# Check build cache
check_build_cache() {
    local target="$1"
    local source="${2:-$BP_ROOT/run.sh}"
    
    local source_hash
    source_hash=$(get_source_hash "$source")
    
    local cache_file="$BP_CACHE_DIR/${target}_${source_hash}.sh"
    
    # Check if cached build exists
    if [ -f "$cache_file" ]; then
        log_dim "  ✓ Cache hit for $target"
        return 0
    fi
    
    log_dim "  ⚡ Cache miss - building $target"
    return 1
}

# Save build to cache
save_build_cache() {
    local target="$1"
    local output="$2"
    local source="${3:-$BP_ROOT/run.sh}"
    
    local source_hash
    source_hash=$(get_source_hash "$source")
    
    local cache_file="$BP_CACHE_DIR/${target}_${source_hash}.sh"
    
    if [ -f "$output" ]; then
        cp "$output" "$cache_file"
        log_dim "  💾 Cached build: $target"
    fi
}

# Cleanup old build logs
cleanup_old_logs() {
    local keep_count=10
    
    if [ -d "$BP_LOG_DIR" ]; then
        local log_count
        log_count=$(find "$BP_LOG_DIR" -name "build_*.log" 2>/dev/null | wc -l | tr -d ' ')
        
        if [ "$log_count" -gt "$keep_count" ]; then
            log_dim "  🧹 Cleaning up old logs (keeping last $keep_count)..."
            find "$BP_LOG_DIR" -name "build_*.log" -type f | \
                sort -r | \
                tail -n +$((keep_count + 1)) | \
                xargs rm -f 2>/dev/null || true
        fi
    fi
}

# Cleanup old cache entries
cleanup_old_cache() {
    local max_age_days=7
    
    if [ -d "$BP_CACHE_DIR" ]; then
        log_dim "  🧹 Cleaning cache older than $max_age_days days..."
        find "$BP_CACHE_DIR" -type f -mtime "+$max_age_days" -delete 2>/dev/null || true
    fi
}

# Save build metrics
save_build_metrics() {
    local target="$1"
    local output="$2"
    local duration="$3"
    
    local metrics_file="$BP_LOG_DIR/metrics.csv"
    
    # Create header if file doesn't exist
    if [ ! -f "$metrics_file" ]; then
        echo "timestamp,target,size_bytes,lines,duration_sec" > "$metrics_file"
    fi
    
    # Collect metrics
    local timestamp
    timestamp=$(date +%s)
    local size_bytes=0
    local lines=0
    
    if [ -f "$output" ]; then
        size_bytes=$(wc -c < "$output" | tr -d ' ')
        lines=$(wc -l < "$output" | tr -d ' ')
    fi
    
    # Append metrics
    echo "$timestamp,$target,$size_bytes,$lines,$duration" >> "$metrics_file"
    
    log_dim "  📊 Metrics saved: ${size_bytes} bytes, ${lines} lines, ${duration}s"
}

# ==============================================================================
#  BUILD TARGETS
# ==============================================================================

build_target_dev() {
    log_step "Building DEV target..."
    
    local dev_output="$BP_OUTPUT_DIR/run-dev.sh"
    local start_time=$SECONDS
    
    # Check if incremental build possible
    if ! needs_rebuild "$BP_ROOT/run.sh" "$dev_output"; then
        log_success "Dev build up-to-date: $dev_output"
        return 0
    fi
    
    # Check cache
    local source_hash
    source_hash=$(get_source_hash "$BP_ROOT/run.sh")
    local cache_file="$BP_CACHE_DIR/dev_${source_hash}.sh"
    
    if [ -f "$cache_file" ]; then
        log_dim "  ✓ Using cached dev build"
        cp "$cache_file" "$dev_output"
        chmod +x "$dev_output"
        log_success "Dev build restored from cache: $dev_output"
        return 0
    fi
    
    # Check if modular build is available
    if [ -f "$BP_ROOT/src/16-main.sh" ]; then
        # Modular build with build.sh
        "$BP_ROOT/build.sh"
    else
        # Monolithic build - just use existing run.sh
        log_dim "  Using monolithic run.sh (modular build not available)"
    fi
    
    # Add dev-specific features
    cp "$BP_ROOT/run.sh" "$dev_output"
    
    # Enable debug mode by default in dev build
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/DEBUG_MODE=0/DEBUG_MODE=1/' "$dev_output"
    else
        sed -i 's/DEBUG_MODE=0/DEBUG_MODE=1/' "$dev_output"
    fi
    
    chmod +x "$dev_output"
    
    # Save to cache
    save_build_cache "dev" "$dev_output"
    
    # Save metrics
    local duration=$((SECONDS - start_time))
    save_build_metrics "dev" "$dev_output" "$duration"
    
    log_success "Dev build created: $dev_output"
}

build_target_prod() {
    log_step "Building PROD target..."
    
    local prod_output="$BP_OUTPUT_DIR/run-prod.sh"
    local start_time=$SECONDS
    
    # Check if incremental build possible
    if ! needs_rebuild "$BP_ROOT/run.sh" "$prod_output"; then
        log_success "Production build up-to-date: $prod_output"
        return 0
    fi
    
    # Check cache
    local source_hash
    source_hash=$(get_source_hash "$BP_ROOT/run.sh")
    local cache_file="$BP_CACHE_DIR/prod_${source_hash}.sh"
    
    if [ -f "$cache_file" ]; then
        log_dim "  ✓ Using cached production build"
        cp "$cache_file" "$prod_output"
        chmod +x "$prod_output"
        log_success "Production build restored from cache: $prod_output"
        return 0
    fi
    
    # Check if modular build is available
    if [ -f "$BP_ROOT/src/16-main.sh" ]; then
        # Modular build with build.sh
        "$BP_ROOT/build.sh"
    else
        # Monolithic build - just use existing run.sh
        log_dim "  Using monolithic run.sh (modular build not available)"
    fi
    
    # Minify and optimize
    cp "$BP_ROOT/run.sh" "$prod_output"
    
    # Strip comments and compress (preserving shebang and critical comments)
    awk '
        BEGIN { in_header = 1 }
        /^#!/ { print; next }
        /^# ===/ { in_header = 0 }
        in_header { print; next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { print }
    ' "$prod_output" > "${prod_output}.tmp"
    mv "${prod_output}.tmp" "$prod_output"
    
    chmod +x "$prod_output"
    
    # Save to cache
    save_build_cache "prod" "$prod_output"
    
    # Save metrics
    local duration=$((SECONDS - start_time))
    save_build_metrics "prod" "$prod_output" "$duration"
    
    log_success "Production build created: $prod_output"
}

build_target_minimal() {
    log_step "Building MINIMAL target..."
    
    # Build minimal version with only core features
    local minimal_output="$BP_OUTPUT_DIR/run-minimal.sh"
    
    # Check if modular source available
    if [ -f "$BP_ROOT/src/16-main.sh" ]; then
        # Copy essential modules only
        {
            cat "$BP_ROOT/src/00-header.sh"
            cat "$BP_ROOT/src/01-config.sh"
            cat "$BP_ROOT/src/02-utils.sh"
            cat "$BP_ROOT/src/13-ui.sh"
            cat "$BP_ROOT/src/16-main.sh"
        } > "$minimal_output"
    else
        # Create minimal from monolithic by removing advanced features
        log_dim "  Creating minimal from monolithic run.sh"
        cp "$BP_ROOT/run.sh" "$minimal_output"
    fi
    
    chmod +x "$minimal_output"
    log_success "Minimal build created: $minimal_output (core features only)"
}

build_target_docker() {
    log_step "Building DOCKER image..."
    
    # Create Dockerfile if it doesn't exist
    if [ ! -f "$BP_BUILD_DIR/Dockerfile" ]; then
        log_warn "Dockerfile not found, creating default..."
        cat > "$BP_BUILD_DIR/Dockerfile" <<'EOF'
FROM alpine:latest

RUN apk add --no-cache bash curl git

COPY dist/run-prod.sh /usr/local/bin/run
RUN chmod +x /usr/local/bin/run

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/run"]
EOF
    fi
    
    # Build first if needed
    if [ ! -f "$BP_OUTPUT_DIR/run-prod.sh" ]; then
        build_target_prod
    fi
    
    # Build Docker image
    docker build -t shell-menu-runner:latest -f "$BP_BUILD_DIR/Dockerfile" "$BP_ROOT"
    
    log_success "Docker image built: shell-menu-runner:latest"
}

build_target_all() {
    log_step "Building ALL targets..."
    TOTAL_STEPS=4
    
    step "Dev build"
    build_target_dev
    
    step "Production build"
    build_target_prod
    
    step "Minimal build"
    build_target_minimal
    
    step "Docker image"
    build_target_docker
    
    log_success "All targets built successfully"
}

# ==============================================================================
#  TESTING
# ==============================================================================

run_tests() {
    log_step "Running tests..."
    
    if [ ! -f "$BP_BUILD_DIR/tests/test-runner.sh" ]; then
        log_warn "Test runner not found, skipping tests"
        return 0
    fi
    
    bash "$BP_BUILD_DIR/tests/test-runner.sh"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log_success "All tests passed"
    else
        log_error "Tests failed with exit code $exit_code"
        return $exit_code
    fi
}

run_linter() {
    log_step "Running shellcheck..."
    
    if ! command -v shellcheck &>/dev/null; then
        log_warn "shellcheck not installed, skipping lint"
        return 0
    fi
    
    local files_to_check=(
        "$BP_ROOT/run.sh"
        "$BP_ROOT/build.sh"
        "$BP_ROOT/install.sh"
    )
    
    local errors=0
    for file in "${files_to_check[@]}"; do
        if [ -f "$file" ]; then
            log_dim "  Checking $file..."
            if shellcheck -x "$file"; then
                log_success "  ✓ $file"
            else
                log_error "  ✗ $file"
                errors=$((errors + 1))
            fi
        fi
    done
    
    if [ $errors -eq 0 ]; then
        log_success "Linting passed"
    else
        log_error "Linting failed ($errors errors)"
        return 1
    fi
}

# ==============================================================================
#  PACKAGING
# ==============================================================================

package_deb() {
    log_step "Building .deb package..."
    
    local version
    version=$(grep -o 'VERSION="[^"]*"' "$BP_ROOT/run.sh" | cut -d'"' -f2)
    local pkg_dir="$BP_OUTPUT_DIR/shell-menu-runner_${version}_all"
    
    mkdir -p "$pkg_dir/DEBIAN"
    mkdir -p "$pkg_dir/usr/local/bin"
    mkdir -p "$pkg_dir/usr/share/doc/shell-menu-runner"
    mkdir -p "$pkg_dir/usr/share/zsh/site-functions"
    
    # Control file
    cat > "$pkg_dir/DEBIAN/control" <<EOF
Package: shell-menu-runner
Version: $version
Section: utils
Priority: optional
Architecture: all
Maintainer: Mario Peters <mail@example.com>
Description: Interactive task menu runner for shell
 Shell Menu Runner provides an interactive, colorful menu system
 for managing and executing project tasks defined in .tasks files.
EOF
    
    # Copy files
    cp "$BP_OUTPUT_DIR/run-prod.sh" "$pkg_dir/usr/local/bin/run"
    cp "$BP_ROOT/README.md" "$pkg_dir/usr/share/doc/shell-menu-runner/"
    cp "$BP_ROOT/completions/_run" "$pkg_dir/usr/share/zsh/site-functions/" 2>/dev/null || true
    
    # Build package
    dpkg-deb --build "$pkg_dir"
    
    log_success "Debian package created: ${pkg_dir}.deb"
}

package_rpm() {
    log_step "Building .rpm package..."
    log_warn "RPM packaging not yet implemented"
}

package_tarball() {
    log_step "Building tarball..."
    
    local version
    version=$(grep -o 'VERSION="[^"]*"' "$BP_ROOT/run.sh" | cut -d'"' -f2)
    local tarball="$BP_OUTPUT_DIR/shell-menu-runner-${version}.tar.gz"
    
    tar -czf "$tarball" \
        -C "$BP_ROOT" \
        --exclude='.git' \
        --exclude='dist' \
        --exclude='.build-cache' \
        --exclude='.build-logs' \
        run.sh install.sh README.md LICENSE completions/
    
    log_success "Tarball created: $tarball"
}

package_all() {
    log_step "Creating all packages..."
    
    package_tarball
    
    if command -v dpkg-deb &>/dev/null; then
        package_deb
    else
        log_warn "dpkg-deb not available, skipping .deb"
    fi
    
    if command -v rpmbuild &>/dev/null; then
        package_rpm
    else
        log_warn "rpmbuild not available, skipping .rpm"
    fi
    
    log_success "Packaging complete"
}

# ==============================================================================
#  DEPLOYMENT
# ==============================================================================

deploy_github_release() {
    log_step "Deploying to GitHub Releases..."
    
    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) not installed"
        return 1
    fi
    
    local version
    version=$(grep -o 'VERSION="[^"]*"' "$BP_ROOT/run.sh" | cut -d'"' -f2)
    
    log_info "Creating release v$version..."
    
    # Create release with all artifacts
    gh release create "v$version" \
        "$BP_OUTPUT_DIR"/shell-menu-runner-*.tar.gz \
        "$BP_OUTPUT_DIR"/*.deb \
        --title "v$version" \
        --notes "Automated release v$version"
    
    log_success "GitHub release created"
}

deploy_dockerhub() {
    log_step "Pushing to Docker Hub..."
    
    if ! command -v docker &>/dev/null; then
        log_error "Docker not installed"
        return 1
    fi
    
    local version
    version=$(grep -o 'VERSION="[^"]*"' "$BP_ROOT/run.sh" | cut -d'"' -f2)
    
    docker tag shell-menu-runner:latest "mariopeters/shell-menu-runner:$version"
    docker tag shell-menu-runner:latest mariopeters/shell-menu-runner:latest
    
    docker push "mariopeters/shell-menu-runner:$version"
    docker push mariopeters/shell-menu-runner:latest
    
    log_success "Docker images pushed"
}

# ==============================================================================
#  CI/CD HELPERS
# ==============================================================================

ci_build() {
    log_step "CI Build Pipeline..."
    
    TOTAL_STEPS=5
    CURRENT_STEP=0
    
    step "Linting"
    run_linter || return 1
    
    step "Testing"
    run_tests || return 1
    
    step "Building"
    build_target_all || return 1
    
    step "Packaging"
    package_all || return 1
    
    step "Generating checksums"
    generate_checksums
    
    log_success "CI build completed successfully"
}

generate_checksums() {
    log_step "Generating checksums..."
    
    local checksum_file="$BP_OUTPUT_DIR/SHA256SUMS"
    > "$checksum_file"
    
    cd "$BP_OUTPUT_DIR" || return 1
    
    shopt -s nullglob
    for file in *.tar.gz *.deb *.rpm run-*.sh; do
        if [ -f "$file" ]; then
            sha256sum "$file" >> "$checksum_file"
            log_dim "  ✓ $file"
        fi
    done
    shopt -u nullglob
    
    cd "$BP_ROOT" || return 1
    
    log_success "Checksums written to $checksum_file"
}

# ==============================================================================
#  CLEANUP
# ==============================================================================

clean_build() {
    log_step "Cleaning build artifacts..."
    
    rm -rf "$BP_OUTPUT_DIR"
    
    log_success "Build artifacts cleaned"
}

clean_cache() {
    log_step "Cleaning build cache..."
    
    rm -rf "$BP_CACHE_DIR"
    mkdir -p "$BP_CACHE_DIR"
    
    log_success "Build cache cleaned"
}

clean_logs() {
    log_step "Cleaning build logs..."
    
    if [ -d "$BP_LOG_DIR" ]; then
        find "$BP_LOG_DIR" -name "build_*.log" -type f -delete 2>/dev/null || true
    fi
    
    log_success "Build logs cleaned"
}

clean_all() {
    log_step "Deep cleaning..."
    
    clean_build
    clean_cache
    rm -rf "$BP_LOG_DIR"
    
    log_success "All build files cleaned"
}

# ==============================================================================
#  INTERACTIVE MENU
# ==============================================================================

show_menu() {
    clear
    cat <<EOF
${C_HEAD}╔════════════════════════════════════════════════════════════╗
║        Shell Menu Runner - Build Platform v$BP_VERSION        ║
╚════════════════════════════════════════════════════════════╝${C_RST}

${C_BOLD}Build Targets:${C_RST}
  ${C_INFO}1${C_RST}) Dev Build       ${C_DIM}(debug enabled)${C_RST}
  ${C_INFO}2${C_RST}) Production      ${C_DIM}(optimized)${C_RST}
  ${C_INFO}3${C_RST}) Minimal         ${C_DIM}(core features only)${C_RST}
  ${C_INFO}4${C_RST}) Docker Image    ${C_DIM}(containerized)${C_RST}
  ${C_INFO}5${C_RST}) All Targets     ${C_DIM}(build everything)${C_RST}

${C_BOLD}Quality & Testing:${C_RST}
  ${C_INFO}6${C_RST}) Run Tests       ${C_DIM}(test suite)${C_RST}
  ${C_INFO}7${C_RST}) Run Linter      ${C_DIM}(shellcheck)${C_RST}

${C_BOLD}Packaging:${C_RST}
  ${C_INFO}8${C_RST}) Create .deb     ${C_DIM}(Debian/Ubuntu)${C_RST}
  ${C_INFO}9${C_RST}) Create .tar.gz  ${C_DIM}(universal)${C_RST}
  ${C_INFO}10${C_RST}) Package All     ${C_DIM}(all formats)${C_RST}

${C_BOLD}Deployment:${C_RST}
  ${C_INFO}11${C_RST}) GitHub Release  ${C_DIM}(create release)${C_RST}
  ${C_INFO}12${C_RST}) Docker Hub      ${C_DIM}(push images)${C_RST}

${C_BOLD}CI/CD:${C_RST}
  ${C_INFO}13${C_RST}) Full CI Build   ${C_DIM}(lint + test + build + package)${C_RST}

${C_BOLD}Maintenance:${C_RST}
  ${C_INFO}14${C_RST}) Clean Build     ${C_DIM}(remove artifacts)${C_RST}
  ${C_INFO}15${C_RST}) Clean All       ${C_DIM}(deep clean)${C_RST}

  ${C_INFO}0${C_RST}) Exit

${C_DIM}────────────────────────────────────────────────────────────${C_RST}
EOF
    echo -ne "${C_HEAD}Select option [0-15]: ${C_RST}"
}

interactive_mode() {
    init_build_env
    
    while true; do
        show_menu
        read -r choice
        echo ""
        
        case "$choice" in
            1) build_target_dev ;;
            2) build_target_prod ;;
            3) build_target_minimal ;;
            4) build_target_docker ;;
            5) build_target_all ;;
            6) run_tests ;;
            7) run_linter ;;
            8) package_deb ;;
            9) package_tarball ;;
            10) package_all ;;
            11) deploy_github_release ;;
            12) deploy_dockerhub ;;
            13) ci_build ;;
            14) clean_build ;;
            15) clean_all ;;
            0) 
                echo ""
                log_info "Goodbye!"
                exit 0
                ;;
            *)
                log_error "Invalid option: $choice"
                ;;
        esac
        
        echo ""
        log_dim "Press Enter to continue..."
        read -r
    done
}

# ==============================================================================
#  HELP
# ==============================================================================

show_help() {
    cat <<EOF
${C_HEAD}Shell Menu Runner - Build Platform v$BP_VERSION${C_RST}

${C_BOLD}USAGE:${C_RST}
  $0 [COMMAND] [OPTIONS]

${C_BOLD}COMMANDS:${C_RST}
  ${C_INFO}build <target>${C_RST}     Build specific target
                       Targets: dev, prod, minimal, docker, all
  
  ${C_INFO}test${C_RST}               Run test suite
  ${C_INFO}lint${C_RST}               Run shellcheck linter
  
  ${C_INFO}package <format>${C_RST}   Create package
                       Formats: deb, rpm, tarball, all
  
  ${C_INFO}deploy <target>${C_RST}    Deploy to platform
                       Targets: github, dockerhub
  
  ${C_INFO}ci${C_RST}                 Run full CI pipeline
  ${C_INFO}clean${C_RST}              Clean build artifacts
  ${C_INFO}clean-all${C_RST}          Deep clean (including logs & cache)
  ${C_INFO}clean-cache${C_RST}        Clean build cache only
  ${C_INFO}clean-logs${C_RST}         Clean build logs only
  
  ${C_INFO}menu${C_RST}               Show interactive menu (default)
  ${C_INFO}help${C_RST}               Show this help

${C_BOLD}EXAMPLES:${C_RST}
  $0                    # Interactive menu
  $0 build prod         # Build production version
  $0 test               # Run tests
  $0 ci                 # Full CI pipeline
  $0 package all        # Create all packages
  $0 deploy github      # Deploy to GitHub Releases

${C_BOLD}ENVIRONMENT VARIABLES:${C_RST}
  BP_SKIP_TESTS=1       Skip tests during build
  BP_VERBOSE=1          Enable verbose logging
  BP_NO_COLOR=1         Disable colored output

EOF
}

# ==============================================================================
#  MAIN
# ==============================================================================

main() {
    # Handle environment variables
    [ "${BP_NO_COLOR:-0}" = "1" ] && {
        C_HEAD=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_INFO=''; C_RST=''; C_BOLD=''
    }
    
    # Parse command
    local command="${1:-menu}"
    
    case "$command" in
        build)
            init_build_env
            local target="${2:-all}"
            case "$target" in
                dev) build_target_dev ;;
                prod) build_target_prod ;;
                minimal) build_target_minimal ;;
                docker) build_target_docker ;;
                all) build_target_all ;;
                *) log_error "Unknown build target: $target"; exit 1 ;;
            esac
            ;;
        
        test)
            init_build_env
            run_tests
            ;;
        
        lint)
            init_build_env
            run_linter
            ;;
        
        package)
            init_build_env
            local format="${2:-all}"
            case "$format" in
                deb) package_deb ;;
                rpm) package_rpm ;;
                tarball) package_tarball ;;
                all) package_all ;;
                *) log_error "Unknown package format: $format"; exit 1 ;;
            esac
            ;;
        
        deploy)
            init_build_env
            local target="${2:-}"
            case "$target" in
                github) deploy_github_release ;;
                dockerhub) deploy_dockerhub ;;
                *) log_error "Unknown deploy target: $target"; exit 1 ;;
            esac
            ;;
        
        ci)
            init_build_env
            ci_build
            ;;
        
        clean)
            clean_build
            ;;
        
        clean-all)
            clean_all
            ;;
        
        clean-cache)
            clean_cache
            ;;
        
        clean-logs)
            clean_logs
            ;;
        
        menu)
            interactive_mode
            ;;
        
        help|--help|-h)
            show_help
            ;;
        
        *)
            log_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
