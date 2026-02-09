#!/bin/bash
# ==============================================================================
#  Compression Benchmark - Test different compression methods
# ==============================================================================

set -euo pipefail

C_INFO=$'\e[36m'; C_OK=$'\e[1;32m'; C_RST=$'\e[0m'

INPUT="${1:-run.sh}"

echo "${C_INFO}=== Compression Benchmark ===${C_RST}"
echo "Testing: $INPUT"
echo ""

ORIG_SIZE=$(wc -c < "$INPUT")
echo "Original size: $(numfmt --to=iec $ORIG_SIZE 2>/dev/null || echo "$ORIG_SIZE bytes")"
echo ""

# Test different compression methods
test_compression() {
    local method="$1"
    local ext="$2"
    local cmd="$3"
    
    eval "$cmd" 2>/dev/null || return 1
    
    local compressed_size=$(wc -c < "${INPUT}.${ext}")
    local ratio=$(awk "BEGIN {printf \"%.1f\", (100.0 - $compressed_size * 100.0 / $ORIG_SIZE)}")
    
    printf "%-15s %10s  (%s%% smaller)\n" \
        "$method:" \
        "$(numfmt --to=iec $compressed_size 2>/dev/null || echo "$compressed_size bytes")" \
        "$ratio"
    
    rm -f "${INPUT}.${ext}"
}

echo "${C_INFO}Compression Methods:${C_RST}"

test_compression "gzip" "gz" "gzip -c '$INPUT' > '${INPUT}.gz'"
test_compression "bzip2" "bz2" "bzip2 -c '$INPUT' > '${INPUT}.bz2'"
test_compression "xz" "xz" "xz -c '$INPUT' > '${INPUT}.xz'"
test_compression "zstd" "zst" "zstd -q '$INPUT' -o '${INPUT}.zst'"

echo ""
echo "${C_INFO}Recommendation:${C_RST}"
echo "For distribution: .tar.gz (best compatibility)"
echo "For storage:      .xz (best compression)"
echo "For speed:        .zst (fast decompression)"
