#!/bin/bash
# ==============================================================================
#  Advanced Optimizer - Ultra-Compact Build
#  Creates highly optimized version of run.sh
# ==============================================================================

set -euo pipefail

readonly INPUT="${1:-run.sh}"
readonly OUTPUT="${2:-dist/run-ultra.sh}"

C_INFO=$'\e[36m'; C_OK=$'\e[1;32m'; C_RST=$'\e[0m'

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
' "$INPUT" > "${OUTPUT}.tmp1"

STEP1_SIZE=$(wc -c < "${OUTPUT}.tmp1")
echo "  After step 1: $(numfmt --to=iec $STEP1_SIZE 2>/dev/null || echo "$STEP1_SIZE bytes")"

echo "${C_INFO}Step 2: Remove leading/trailing whitespace${C_RST}"
sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "${OUTPUT}.tmp1" > "${OUTPUT}.tmp2"

STEP2_SIZE=$(wc -c < "${OUTPUT}.tmp2")
echo "  After step 2: $(numfmt --to=iec $STEP2_SIZE 2>/dev/null || echo "$STEP2_SIZE bytes")"

echo "${C_INFO}Step 3: Compress multi-space sequences${C_RST}"
sed 's/[[:space:]][[:space:]]*/ /g' "${OUTPUT}.tmp2" > "${OUTPUT}.tmp3"

STEP3_SIZE=$(wc -c < "${OUTPUT}.tmp3")
echo "  After step 3: $(numfmt --to=iec $STEP3_SIZE 2>/dev/null || echo "$STEP3_SIZE bytes")"

echo "${C_INFO}Step 4: String deduplication${C_RST}"
# Remove excessive spacing in strings and optimize patterns
sed 's/"[[:space:]]*\([^"]*\)[[:space:]]*"/"\1"/g' "${OUTPUT}.tmp3" > "${OUTPUT}.tmp4"

STEP4_SIZE=$(wc -c < "${OUTPUT}.tmp4")
echo "  After step 4: $(numfmt --to=iec $STEP4_SIZE 2>/dev/null || echo "$STEP4_SIZE bytes")"

# Final output
mv "${OUTPUT}.tmp4" "$OUTPUT"
chmod +x "$OUTPUT"

# Cleanup
rm -f "${OUTPUT}".tmp*

# ==============================================================================
#  RESULTS
# ==============================================================================

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
