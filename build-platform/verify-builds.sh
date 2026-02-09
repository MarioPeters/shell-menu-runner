#!/bin/bash
# ==============================================================================
#  Build Verification Script - Test all builds
# ==============================================================================

set -euo pipefail

C_HEAD=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_FAIL=$'\e[1;31m'
C_INFO=$'\e[33m'; C_RST=$'\e[0m'

echo "${C_HEAD}╔════════════════════════════════════════════════════════════╗${C_RST}"
echo "${C_HEAD}║        Build Verification & Size Comparison                ║${C_RST}"
echo "${C_HEAD}╚════════════════════════════════════════════════════════════╝${C_RST}"
echo ""

# ==============================================================================
#  BUILD ALL TARGETS
# ==============================================================================

echo "${C_INFO}▶ Building all targets...${C_RST}"
echo ""

make dev >/dev/null 2>&1 && echo "  ✓ Dev build" || echo "  ✗ Dev build failed"
make prod >/dev/null 2>&1 && echo "  ✓ Prod build" || echo "  ✗ Prod build failed"
make minimal >/dev/null 2>&1 && echo "  ✓ Minimal build" || echo "  ✗ Minimal build failed"
make ultra >/dev/null 2>&1 && echo "  ✓ Ultra build" || echo "  ✗ Ultra build failed"

echo ""

# ==============================================================================
#  SIZE COMPARISON
# ==============================================================================

echo "${C_INFO}▶ Size Comparison:${C_RST}"
echo ""

printf "%-20s %10s %10s %10s\n" "Build" "Size" "Lines" "Savings"
printf "%-20s %10s %10s %10s\n" "────────────────────" "──────────" "──────────" "──────────"

ORIG_SIZE=$(wc -c < run.sh | tr -d ' ')
ORIG_LINES=$(wc -l < run.sh | tr -d ' ')

print_stats() {
    local name="$1"
    local file="$2"
    
    if [ ! -f "$file" ]; then
        printf "%-20s %10s %10s %10s\n" "$name" "N/A" "N/A" "N/A"
        return
    fi
    
    local size=$(wc -c < "$file" | tr -d ' ')
    local lines=$(wc -l < "$file" | tr -d ' ')
    local savings=$(awk "BEGIN {printf \"%.1f%%\", (100.0 - $size * 100.0 / $ORIG_SIZE)}")
    
    local size_h=$(numfmt --to=iec $size 2>/dev/null || echo "$size")
    
    printf "%-20s %10s %10s %10s\n" "$name" "$size_h" "$lines" "$savings"
}

print_stats "Original (run.sh)" "run.sh"
print_stats "Dev Build" "dist/run-dev.sh"
print_stats "Prod Build" "dist/run-prod.sh"
print_stats "Minimal Build" "dist/run-minimal.sh"
print_stats "Ultra Build" "dist/run-ultra.sh"

echo ""

# ==============================================================================
#  FUNCTIONALITY TESTS
# ==============================================================================

echo "${C_INFO}▶ Functionality Tests:${C_RST}"
echo ""

test_build() {
    local name="$1"
    local file="$2"
    
    if [ ! -f "$file" ]; then
        printf "%-20s ${C_FAIL}✗ Not found${C_RST}\n" "$name"
        return 1
    fi
    
    # Test version
    if ! $file --version >/dev/null 2>&1; then
        printf "%-20s ${C_FAIL}✗ Version failed${C_RST}\n" "$name"
        return 1
    fi
    
    # Test help
    if ! $file --help >/dev/null 2>&1; then
        printf "%-20s ${C_FAIL}✗ Help failed${C_RST}\n" "$name"
        return 1
    fi
    
    printf "%-20s ${C_OK}✓ Working${C_RST}\n" "$name"
    return 0
}

PASS=0
FAIL=0

test_build "Original" "run.sh" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
test_build "Dev Build" "dist/run-dev.sh" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
test_build "Prod Build" "dist/run-prod.sh" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
test_build "Minimal Build" "dist/run-minimal.sh" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
test_build "Ultra Build" "dist/run-ultra.sh" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ""

# ==============================================================================
#  COMPRESSION POTENTIAL
# ==============================================================================

echo "${C_INFO}▶ Compression Potential (gzip):${C_RST}"
echo ""

printf "%-20s %10s %10s\n" "Build" "Original" "Compressed"
printf "%-20s %10s %10s\n" "────────────────────" "──────────" "──────────"

compress_test() {
    local name="$1"
    local file="$2"
    
    if [ ! -f "$file" ]; then
        printf "%-20s %10s %10s\n" "$name" "N/A" "N/A"
        return
    fi
    
    local orig=$(wc -c < "$file" | tr -d ' ')
    local orig_h=$(numfmt --to=iec $orig 2>/dev/null || echo "$orig")
    
    gzip -c "$file" > "${file}.gz" 2>/dev/null
    local comp=$(wc -c < "${file}.gz" | tr -d ' ')
    local comp_h=$(numfmt --to=iec $comp 2>/dev/null || echo "$comp")
    rm -f "${file}.gz"
    
    printf "%-20s %10s %10s\n" "$name" "$orig_h" "$comp_h"
}

compress_test "Original" "run.sh"
compress_test "Prod Build" "dist/run-prod.sh"
compress_test "Ultra Build" "dist/run-ultra.sh"

echo ""

# ==============================================================================
#  SUMMARY
# ==============================================================================

echo "${C_HEAD}═══════════════════════════════════════════════════════════${C_RST}"
echo "${C_HEAD}  SUMMARY${C_RST}"
echo "${C_HEAD}═══════════════════════════════════════════════════════════${C_RST}"
echo ""
echo "  Builds Tested:  $((PASS + FAIL))"
echo "  ${C_OK}Passed:         $PASS${C_RST}"
if [ $FAIL -gt 0 ]; then
    echo "  ${C_FAIL}Failed:         $FAIL${C_RST}"
fi
echo ""

if [ $FAIL -eq 0 ]; then
    echo "${C_OK}✓ All builds are working correctly!${C_RST}"
    exit 0
else
    echo "${C_FAIL}✗ Some builds failed!${C_RST}"
    exit 1
fi
