#!/bin/bash

# Ensure we are running in Bash, not Zsh (if sourced or run with 'zsh script.sh')
#
# Zsh has no BASH_SOURCE, and $0 cannot distinguish "sourced" from "executed":
# in both cases $0 is the path of the script itself.  $ZSH_EVAL_CONTEXT
# (zsh >= 5.0.3) does distinguish them:
#   toplevel            -> the script was executed  -> re-exec with bash
#   cmdarg:file         -> the script was sourced    -> refuse
#   cmdarg:shfunc:file -> the script was sourced    -> refuse
if [ -n "${ZSH_VERSION:-}" ]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
        toplevel)
            # Re-execute with bash if run as 'zsh script.sh'
            exec bash "$0" "$@"
            ;;
        *)
            echo "Error: This script is not meant to be sourced directly in Zsh." >&2
            return 1
            ;;
    esac
fi

# ==============================================================================
#  SHELL MENU RUNNER v1.7.0 (Task Tags & Shell Completion)
#  GitHub: https://github.com/MarioPeters/shell-menu-runner
#  Lizenz: MIT
# ==============================================================================

readonly VERSION="2.1.3"
# HOME wird für alle Konfigurationspfade gebraucht.  Ohne HOME brach das
# Skript später mit "HOME: unbound variable" ab — die Meldung sagt dem
# Nutzer nicht, was zu tun ist.
if [ -z "${HOME:-}" ]; then
    echo "Error: HOME is not set — cannot locate the configuration files." >&2
    exit 1
fi
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


# --- PERFORMANCE FLAGS (can be set via environment) ---
RUN_PARALLEL_DEPS="${RUN_PARALLEL_DEPS:-0}"      # Enable parallel dependency execution
# Enables the menu cache (the parsed task list is reused until the config
# files change).  The name is historic — the flag no longer controls a
# profile listing cache.
RUN_CACHE_PROFILES="${RUN_CACHE_PROFILES:-1}"   # Cache the parsed menu/task list
# The minimal build has no advanced features (search, tags, favorites,
# history, logs, file browser, config editor).  Set by the builder.
RUN_MINIMAL="${RUN_MINIMAL:-0}"
# Optimierung für macOS/BSD Grep (Locale-Reset für Geschwindigkeit bei Sortierung/Regex)
# Aber UTF-8 Zeichen müssen erhalten bleiben, daher nur Collate auf C setzen.
export LC_COLLATE=C

set -euo pipefail

# SIGPIPE ignorieren: `run --list | head` soll der Shell nicht mit einem Signal
# abbrechen, sondern sauber beenden (der EXIT-Trap laeuft dann noch).
# Hinweis: die Meldung "write error: Broken pipe" stammt vom Bash-Builtin
# selbst und wird an den Ausgabestellen unterdrueckt (siehe cli_list_tasks
# in 12-execution.sh).  Tasks bekommen die Standardbehandlung zurueck
# (siehe 12-execution.sh).
trap '' PIPE 2>/dev/null || true

