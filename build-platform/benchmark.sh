#!/bin/bash
# ==============================================================================
#  Benchmark Script - Performance testing for builds
# ==============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILDER="$SCRIPT_DIR/builder.sh"

C_INFO=$'\e[36m'; C_OK=$'\e[1;32m'; C_RST=$'\e[0m'

echo "${C_INFO}=== Build Performance Benchmark ===${C_RST}"
echo ""

benchmark() {
    local name="$1"
    local cmd="$2"
    
    echo -n "Benchmarking $name ... "
    
    local start
    start=$(date +%s.%N)
    
    eval "$cmd" >/dev/null 2>&1
    
    local end
    end=$(date +%s.%N)
    
    local duration
    duration=$(echo "$end - $start" | bc)
    
    printf "${C_OK}%.2fs${C_RST}\n" "$duration"
    
    echo "$name:$duration" >> /tmp/benchmark_results.txt
}

# Clear previous results
> /tmp/benchmark_results.txt

echo "Running benchmarks..."
echo ""

# Clean first
bash "$BUILDER" clean >/dev/null 2>&1

# Benchmark builds
benchmark "Dev Build" "bash $BUILDER build dev"
benchmark "Prod Build" "bash $BUILDER build prod"
benchmark "Minimal Build" "bash $BUILDER build minimal"
benchmark "All Builds" "bash $BUILDER build all"

# Benchmark tests
benchmark "Test Suite" "bash $BUILDER test"

# Benchmark packaging
benchmark "Tarball Package" "bash $BUILDER package tarball"

echo ""
echo "${C_INFO}=== Results Summary ===${C_RST}"
echo ""

total=0
count=0

while IFS=: read -r name duration; do
    printf "  %-20s %8.2fs\n" "$name" "$duration"
    total=$(echo "$total + $duration" | bc)
    count=$((count + 1))
done < /tmp/benchmark_results.txt

average=$(echo "scale=2; $total / $count" | bc)

echo ""
echo "  Total Time:          $(printf "%.2f" "$total")s"
echo "  Average:             $(printf "%.2f" "$average")s"
echo ""

rm -f /tmp/benchmark_results.txt
