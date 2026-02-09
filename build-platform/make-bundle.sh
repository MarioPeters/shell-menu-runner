#!/bin/bash
# ==============================================================================
#  Create Self-Extracting Bundle
#  Bundles run.sh (or any build variant) into a single self-extracting script
# ==============================================================================

set -euo pipefail

# Colors
C_OK=$'\e[1;32m'
C_INFO=$'\e[36m'
C_WARN=$'\e[1;33m'
C_ERR=$'\e[1;31m'
C_DIM=$'\e[2m'
C_RST=$'\e[0m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/bundle-template.sh"
DEFAULT_INPUT="$ROOT_DIR/run.sh"
DEFAULT_OUTPUT="$ROOT_DIR/dist/run-bundle.sh"

# ==============================================================================
#  FUNCTIONS
# ==============================================================================

show_help() {
    cat <<EOF
${C_INFO}Create Self-Extracting Bundle${C_RST}

${C_OK}Usage:${C_RST}
  $0 [INPUT] [OUTPUT]

${C_OK}Arguments:${C_RST}
  INPUT        Source script to bundle (default: run.sh)
  OUTPUT       Output bundle path (default: dist/run-bundle.sh)

${C_OK}Examples:${C_RST}
  $0                                    # Bundle run.sh
  $0 dist/run-prod.sh                   # Bundle production build
  $0 dist/run-ultra.sh dist/bundle.sh   # Custom input/output

${C_OK}What it does:${C_RST}
  1. Compresses input with gzip
  2. Encodes with base64
  3. Embeds into self-extracting template
  4. Result: Single-file bundle (~30-35KB)

${C_OK}Using the bundle:${C_RST}
  ./dist/run-bundle.sh                  # Run temporarily
  ./dist/run-bundle.sh --install        # Install to /usr/local/bin/run
  ./dist/run-bundle.sh --extract path   # Extract to custom path

EOF
}

create_bundle() {
    local input="$1"
    local output="$2"
    
    # Validate input
    if [ ! -f "$input" ]; then
        echo "${C_ERR}Error: Input file not found: $input${C_RST}"
        exit 1
    fi
    
    # Check template
    if [ ! -f "$TEMPLATE" ]; then
        echo "${C_ERR}Error: Template not found: $TEMPLATE${C_RST}"
        exit 1
    fi
    
    echo "${C_INFO}Creating self-extracting bundle...${C_RST}"
    echo ""
    echo "${C_DIM}Input:  $input${C_RST}"
    echo "${C_DIM}Output: $output${C_RST}"
    echo ""
    
    # Get version from input
    local version
    version=$(grep -m1 'VERSION=' "$input" | cut -d'"' -f2 || echo "unknown")
    
    # Create output directory
    mkdir -p "$(dirname "$output")"
    
    # Calculate payload line (count lines in template before __PAYLOAD__)
    local payload_line
    payload_line=$(grep -n "^__PAYLOAD__$" "$TEMPLATE" | cut -d: -f1)
    
    if [ -z "$payload_line" ]; then
        echo "${C_ERR}Error: __PAYLOAD__ marker not found in template${C_RST}"
        exit 1
    fi
    
    # Create bundle
    echo "${C_DIM}[1/4] Reading template...${C_RST}"
    
    # Replace placeholders in template
    sed "s/__VERSION__/$version/g; s/__PAYLOAD_LINE__/$payload_line/g" "$TEMPLATE" | \
        grep -v "^__PAYLOAD__$" > "$output"
    
    echo "${C_DIM}[2/4] Compressing input (gzip)...${C_RST}"
    local compressed_size
    compressed_size=$(gzip -c "$input" | wc -c | tr -d ' ')
    local compressed_kb=$((compressed_size / 1024))
    echo "${C_DIM}      Compressed: ${compressed_kb}K${C_RST}"
    
    echo "${C_DIM}[3/4] Encoding (base64)...${C_RST}"
    gzip -c "$input" | base64 >> "$output"
    
    echo "${C_DIM}[4/4] Finalizing bundle...${C_RST}"
    chmod +x "$output"
    
    # Show results
    local input_size
    local output_size
    input_size=$(wc -c < "$input" | tr -d ' ')
    output_size=$(wc -c < "$output" | tr -d ' ')
    
    local input_kb=$((input_size / 1024))
    local output_kb=$((output_size / 1024))
    local savings=$((100 - (output_size * 100 / input_size)))
    
    echo ""
    echo "${C_OK}✓ Bundle created successfully!${C_RST}"
    echo ""
    echo "Size comparison:"
    printf "  Original:  %6s  (%dK)\n" "${input_size}B" "$input_kb"
    printf "  Bundle:    %6s  (%dK)  ${C_DIM}[%d%% reduction]${C_RST}\n" "${output_size}B" "$output_kb" "$savings"
    echo ""
    echo "Usage:"
    echo "  ${C_INFO}$output${C_RST}                  # Run once"
    echo "  ${C_INFO}$output --install${C_RST}        # Install permanently"
    echo "  ${C_INFO}$output --help${C_RST}           # Show help"
}

# ==============================================================================
#  MAIN
# ==============================================================================

# Parse arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
esac

INPUT="${1:-$DEFAULT_INPUT}"
OUTPUT="${2:-$DEFAULT_OUTPUT}"

create_bundle "$INPUT" "$OUTPUT"
