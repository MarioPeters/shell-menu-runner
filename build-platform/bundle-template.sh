#!/bin/bash
# ==============================================================================
#  SHELL MENU RUNNER - Self-Extracting Bundle
#  This is a self-contained, single-file version that extracts and runs
#  automatically. No installation required!
# ==============================================================================

set -euo pipefail

# Colors
C_OK=$'\e[1;32m'
C_INFO=$'\e[36m'
C_WARN=$'\e[1;33m'
C_ERR=$'\e[1;31m'
C_DIM=$'\e[2m'
C_RST=$'\e[0m'

BUNDLE_VERSION="__VERSION__"
PAYLOAD_LINE=__PAYLOAD_LINE__

# ==============================================================================
#  MAIN LOGIC
# ==============================================================================

show_help() {
    cat <<EOF
${C_INFO}Shell Menu Runner Bundle v${BUNDLE_VERSION}${C_RST}

${C_OK}Usage:${C_RST}
  $0 [OPTIONS]              Run interactively (extracts temporarily)
  $0 --install [PATH]       Install permanently to PATH (default: /usr/local/bin/run)
  $0 --extract PATH         Extract run.sh to specific path
  $0 --help                 Show this help
  $0 --version              Show version

${C_OK}Examples:${C_RST}
  $0                        # Run once (temporary extraction)
  $0 --install              # Install to /usr/local/bin/run
  $0 --install ~/bin/run    # Install to custom location
  $0 --extract ./run.sh     # Extract script only

${C_DIM}Bundle Size: $(wc -c < "$0" | awk '{printf "%.1fK", $1/1024}')
Extracted Size: ~118K${C_RST}

EOF
}

# Extract the embedded run.sh
extract_script() {
    local output="$1"
    
    # Extract payload (everything after PAYLOAD_LINE)
    tail -n "+${PAYLOAD_LINE}" "$0" | base64 -d | gunzip > "$output"
    chmod +x "$output"
}

# Install permanently
install_permanent() {
    local install_path="${1:-/usr/local/bin/run}"
    local install_dir
    install_dir="$(dirname "$install_path")"
    
    echo "${C_INFO}Installing Shell Menu Runner...${C_RST}"
    echo "${C_DIM}Target: $install_path${C_RST}"
    echo ""
    
    # Check if directory exists
    if [ ! -d "$install_dir" ]; then
        echo "${C_ERR}Error: Directory $install_dir does not exist${C_RST}"
        exit 1
    fi
    
    # Check write permissions
    if [ ! -w "$install_dir" ]; then
        echo "${C_WARN}Need sudo for $install_dir${C_RST}"
        sudo extract_script "$install_path"
    else
        extract_script "$install_path"
    fi
    
    echo ""
    echo "${C_OK}✓ Installed successfully!${C_RST}"
    echo ""
    echo "Try it:"
    echo "  ${C_INFO}$install_path --help${C_RST}"
    echo "  ${C_INFO}$install_path --version${C_RST}"
}

# Run temporarily
run_temporary() {
    # Create temp file
    local tmp_run
    tmp_run="$(mktemp /tmp/run.XXXXXX.sh)"
    
    # Ensure cleanup on exit
    trap "rm -f '$tmp_run'" EXIT INT TERM
    
    # Extract
    extract_script "$tmp_run"
    
    # Execute with all arguments
    exec "$tmp_run" "$@"
}

# ==============================================================================
#  ARGUMENT PARSING
# ==============================================================================

case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --version|-v)
        echo "Shell Menu Runner Bundle v${BUNDLE_VERSION}"
        exit 0
        ;;
    --install)
        install_permanent "${2:-}"
        exit 0
        ;;
    --extract)
        if [ -z "${2:-}" ]; then
            echo "${C_ERR}Error: --extract requires output path${C_RST}"
            exit 1
        fi
        extract_script "$2"
        echo "${C_OK}✓ Extracted to: $2${C_RST}"
        exit 0
        ;;
    *)
        # Run temporarily with all args
        run_temporary "$@"
        ;;
esac

# ==============================================================================
#  EMBEDDED PAYLOAD (base64-encoded gzipped run.sh follows)
# ==============================================================================
__PAYLOAD__
