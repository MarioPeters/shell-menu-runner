#!/bin/bash
# ==============================================================================
#  Quick Build Script - Shortcut for common build operations
# ==============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILDER="$SCRIPT_DIR/builder.sh"

# Make builder executable if needed
[ -x "$BUILDER" ] || chmod +x "$BUILDER"

# Quick commands
case "${1:-help}" in
    dev)
        bash "$BUILDER" build dev
        echo ""
        echo "✓ Dev build ready: dist/run-dev.sh"
        ;;
    
    prod)
        bash "$BUILDER" build prod
        echo ""
        echo "✓ Production build ready: dist/run-prod.sh"
        ;;
    
    test)
        bash "$BUILDER" test
        ;;
    
    all)
        bash "$BUILDER" build all
        echo ""
        echo "✓ All builds ready in dist/"
        ;;
    
    package)
        bash "$BUILDER" package all
        echo ""
        echo "✓ Packages created in dist/"
        ;;
    
    docker)
        bash "$BUILDER" build docker
        echo ""
        echo "✓ Docker image: shell-menu-runner:latest"
        ;;
    
    ci)
        bash "$BUILDER" ci
        echo ""
        echo "✓ CI pipeline complete"
        ;;
    
    clean)
        bash "$BUILDER" clean
        echo ""
        echo "✓ Build artifacts cleaned"
        ;;
    
    watch)
        # "$SCRIPT_DIR/../src" resolves relative to the project layout, not to
        # the caller's cwd — "../../src/*" pointed one directory too high
        # (<parent-of-repo>/src, which does not exist) and the glob was
        # silently unexpanded, so no real change was ever detected.
        SRC_DIR="$SCRIPT_DIR/../src"
        if [ ! -d "$SRC_DIR" ]; then
            echo "watch: $SRC_DIR not found — run this script from the repository layout"
            exit 1
        fi
        if ! command -v fswatch >/dev/null 2>&1 && ! command -v inotifywait >/dev/null 2>&1; then
            echo "watch: neither fswatch nor inotifywait is available"
            echo "Install one first (e.g. 'brew install fswatch'), otherwise every watcher falls"
            echo "through to 'sleep 2' and this loop rebuilds forever regardless of changes."
            exit 1
        fi
        echo "Watching for changes..."
        while true; do
            inotifywait -q -e modify "$SRC_DIR"/*.sh 2>/dev/null || \
            fswatch -1 "$SRC_DIR"/*.sh 2>/dev/null || \
            sleep 2
            
            echo ""
            echo "Detected change, rebuilding..."
            bash "$BUILDER" build dev
            echo "✓ Build complete at $(date '+%H:%M:%S')"
        done
        ;;
    
    help|--help|-h)
        cat <<EOF
Quick Build Script

USAGE:
  $0 <command>

COMMANDS:
  dev       Build development version
  prod      Build production version
  test      Run test suite
  all       Build all targets
  package   Create all packages
  docker    Build Docker image
  ci        Run full CI pipeline
  clean     Clean build artifacts
  watch     Auto-rebuild on file changes
  help      Show this help

EXAMPLES:
  $0 dev       # Quick dev build
  $0 test      # Run tests
  $0 ci        # Full CI pipeline
  $0 watch     # Auto-rebuild
EOF
        ;;
    
    *)
        echo "Unknown command: $1"
        echo "Run '$0 help' for usage"
        exit 1
        ;;
esac
