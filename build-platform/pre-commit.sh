#!/bin/bash
# ==============================================================================
#  Pre-commit Hook - Runs before each commit
#  Install: cp build-platform/pre-commit.sh .git/hooks/pre-commit
# ==============================================================================

set -e

# Colors
C_OK=$'\e[1;32m'
C_WARN=$'\e[1;33m'
C_ERR=$'\e[1;31m'
C_INFO=$'\e[36m'
C_DIM=$'\e[2m'
C_RST=$'\e[0m'

echo "${C_INFO}🔍 Running pre-commit checks...${C_RST}"
echo ""

FAILED=0

# ==============================================================================
#  SYNTAX CHECK
# ==============================================================================
echo "${C_INFO}[1/5] Syntax validation${C_RST}"
if bash -n run.sh 2>&1 | grep -q "syntax error"; then
    echo "${C_ERR}✗ Syntax error in run.sh${C_RST}"
    bash -n run.sh
    FAILED=1
else
    echo "${C_OK}✓ Syntax valid${C_RST}"
fi
echo ""

# ==============================================================================
#  SHELLCHECK
# ==============================================================================
echo "${C_INFO}[2/5] ShellCheck linting${C_RST}"
if command -v shellcheck &>/dev/null; then
    if shellcheck -x run.sh 2>&1 | grep -E "^(run.sh:|In )"; then
        echo "${C_WARN}⚠ ShellCheck warnings found${C_RST}"
        echo "${C_DIM}  (Non-blocking - review recommended)${C_RST}"
    else
        echo "${C_OK}✓ ShellCheck passed${C_RST}"
    fi
else
    echo "${C_DIM}  → ShellCheck not installed, skipping${C_RST}"
fi
echo ""

# ==============================================================================
#  BUILD VERIFICATION
# ==============================================================================
echo "${C_INFO}[3/5] Build verification${C_RST}"
if [ -f "build-platform/builder.sh" ]; then
    chmod +x build-platform/builder.sh 2>/dev/null || true
    
    if bash build-platform/builder.sh build dev >/dev/null 2>&1; then
        echo "${C_OK}✓ Dev build successful${C_RST}"
    else
        echo "${C_ERR}✗ Dev build failed${C_RST}"
        FAILED=1
    fi
else
    echo "${C_DIM}  → Build platform not found, skipping${C_RST}"
fi
echo ""

# ==============================================================================
#  QUICK SMOKE TESTS
# ==============================================================================
echo "${C_INFO}[4/5] Quick smoke tests${C_RST}"
if [ -f "run.sh" ]; then
    # Test help
    if ./run.sh --help >/dev/null 2>&1; then
        echo "${C_OK}✓ Help command works${C_RST}"
    else
        echo "${C_WARN}⚠ Help command failed${C_RST}"
    fi
    
    # Test version
    if ./run.sh --version >/dev/null 2>&1; then
        echo "${C_OK}✓ Version command works${C_RST}"
    else
        echo "${C_WARN}⚠ Version command failed${C_RST}"
    fi
fi
echo ""

# ==============================================================================
#  VERSION CONSISTENCY
# ==============================================================================
echo "${C_INFO}[5/5] Version consistency${C_RST}"
VERSION=$(grep -o 'VERSION="[^"]*"' run.sh | cut -d'"' -f2 || echo "unknown")
if [ "$VERSION" != "unknown" ]; then
    if grep -q "\\[$VERSION\\]" CHANGELOG.md 2>/dev/null; then
        echo "${C_OK}✓ Version $VERSION documented in CHANGELOG${C_RST}"
    else
        echo "${C_WARN}⚠ Version $VERSION not in CHANGELOG${C_RST}"
        echo "${C_DIM}  (Consider updating CHANGELOG.md)${C_RST}"
    fi
else
    echo "${C_DIM}  → Version not found${C_RST}"
fi
echo ""

# ==============================================================================
#  SUMMARY
# ==============================================================================
if [ $FAILED -eq 1 ]; then
    echo "${C_ERR}╔════════════════════════════════════════╗${C_RST}"
    echo "${C_ERR}║   ✗ PRE-COMMIT CHECKS FAILED          ║${C_RST}"
    echo "${C_ERR}╚════════════════════════════════════════╝${C_RST}"
    echo ""
    read -p "Commit anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "${C_ERR}Commit aborted${C_RST}"
        exit 1
    fi
    echo "${C_WARN}Proceeding with commit despite failures...${C_RST}"
fi

echo "${C_OK}✓ All pre-commit checks passed${C_RST}"
echo ""
exit 0
