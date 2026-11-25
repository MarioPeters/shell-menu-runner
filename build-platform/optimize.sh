#!/bin/bash
# ==============================================================================
#  Advanced Optimizer - Ultra-Compact Build
#  Creates highly optimized version of run.sh
# ==============================================================================

set -euo pipefail

readonly INPUT="${1:-run.sh}"
readonly OUTPUT="${2:-dist/run-ultra.sh}"

C_INFO=$'\e[36m'; C_OK=$'\e[1;32m'; C_ERR=$'\e[1;31m'; C_RST=$'\e[0m'

echo "${C_INFO}=== Advanced Optimizer ===${C_RST}"
echo "Input:  $INPUT"
echo "Output: $OUTPUT"
echo ""

# Get original size
ORIG_SIZE=$(wc -c < "$INPUT")
ORIG_LINES=$(wc -l < "$INPUT")

echo "Original: $(numfmt --to=iec $ORIG_SIZE 2>/dev/null || echo "$ORIG_SIZE bytes"), $ORIG_LINES lines"
echo ""

# Create output directory
mkdir -p "$(dirname "$OUTPUT")"

# ==============================================================================
#  OPTIMIZATION PIPELINE
# ==============================================================================
# Previous steps 2-4 (whitespace collapsing in-place, string rewriting) were
# CONTENT-ALTERING: they rewrote quotes and case patterns and even broke the
# quoting structure of "[[ ... == *'"'* ]]" — the produced "run-ultra.sh"
# failed with "conditional binary operator expected" and "bash -n".  The only
# safe size win is comment/blank removal (step 1).  A failing "bash -n" gate
# below now keeps a broken artifact from ever being distributed as a build.

echo "${C_INFO}Step 1: Remove comments & empty lines${C_RST}"
awk '
    BEGIN { in_header = 1 }
    /^#!/ { print; next }
    /^# ===.*===/ {
        if (in_header) { print; next }
        in_header = 0
    }
    in_header { print; next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { print }
' "$INPUT" > "$OUTPUT"

STEP1_SIZE=$(wc -c < "$OUTPUT")
echo "  After step 1: $(numfmt --to=iec "$STEP1_SIZE" 2>/dev/null || echo "$STEP1_SIZE bytes")"

chmod +x "$OUTPUT"

# ==============================================================================
#  RESULTS
# ==============================================================================
# Syntax gate: the rewritten artifact must still be valid bash.  Without this
# check a hostile "optimization" step silently shipped a broken run-ultra.sh.
if ! bash -n "$OUTPUT"; then
    echo "${C_ERR}✗ ERROR: $OUTPUT is not valid bash — the optimizer is broken; build discarded${C_RST}" >&2
    rm -f "$OUTPUT"
    exit 1
fi

FINAL_SIZE=$(wc -c < "$OUTPUT")
FINAL_LINES=$(wc -l < "$OUTPUT")

SAVED_SIZE=$((ORIG_SIZE - FINAL_SIZE))
SAVED_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($SAVED_SIZE * 100.0 / $ORIG_SIZE)}")

echo ""
echo "${C_OK}=== Optimization Results ===${C_RST}"
echo "Original:  $(numfmt --to=iec $ORIG_SIZE 2>/dev/null || echo "$ORIG_SIZE bytes"), $ORIG_LINES lines"
echo "Optimized: $(numfmt --to=iec $FINAL_SIZE 2>/dev/null || echo "$FINAL_SIZE bytes"), $FINAL_LINES lines"
echo ""
echo "Saved:     $(numfmt --to=iec $SAVED_SIZE 2>/dev/null || echo "$SAVED_SIZE bytes") ($SAVED_PERCENT%)"
echo ""
echo "${C_OK}✓ Ultra-compact build created: $OUTPUT${C_RST}"
