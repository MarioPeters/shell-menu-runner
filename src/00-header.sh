#!/bin/bash

# ==============================================================================
#  SHELL MENU RUNNER v1.7.0 (Task Tags & Shell Completion)
#  GitHub: https://github.com/MarioPeters/shell-menu-runner
#  Lizenz: MIT
# ==============================================================================

readonly VERSION="1.7.0"
readonly LOCAL_CONFIG=".tasks"
readonly GLOBAL_CONFIG="$HOME/.tasks"
readonly LOCAL_SETTINGS=".runrc"
readonly GLOBAL_SETTINGS="$HOME/.runrc"
readonly REPO_RAW_URL="https://raw.githubusercontent.com/MarioPeters/shell-menu-runner/main/run.sh"
readonly RUN_HISTORY_FILE="$HOME/.run_history"
readonly RUN_HISTORY_MAX=100
readonly RUN_TASK_TIMEOUT=300
readonly RUN_RECENT_FILE="$HOME/.run_recent"
readonly RUN_RECENT_MAX=50
readonly RUN_LOG_DIR="$HOME/.run_logs"
readonly RUN_VARS_FILE="$HOME/.run_vars"
readonly C_BOLD=$'\e[1m'

# --- PERFORMANCE FLAGS (can be set via environment) ---
RUN_PARALLEL_DEPS="${RUN_PARALLEL_DEPS:-0}"      # Enable parallel dependency execution
RUN_CACHE_PROFILES="${RUN_CACHE_PROFILES:-1}"   # Cache profile listings (60s TTL)
RUN_FAST_GREP="${RUN_FAST_GREP:-1}"             # Use optimized grep for large configs

set -euo pipefail

# Helpful debug trap to show failing command, file and line when an error occurs.
# This is temporary for debugging; can be removed later.
trap 'echo "ERROR: command failed: \"$BASH_COMMAND\" at ${BASH_SOURCE[0]}:${LINENO}" >&2' ERR
