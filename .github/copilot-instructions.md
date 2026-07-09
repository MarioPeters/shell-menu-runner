# GitHub Copilot Instructions for Shell Menu Runner

This project is a modular Bash-based task runner and menu system.

## Environment Requirements & Optimization

- **OS**: macOS (Apple Silicon / ARM64) is the primary target.
- **Shell**: The script itself is `bash`, but it must be fully compatible when called from `zsh` interactive sessions as is standard on macOS.
- **Performance**: On macOS/ARM, prefer built-ins over external binaries (BSD `grep`/`sed` can be slower or behave differently than GNU). Avoid excessive subshells `$(...)` in loops.
- **Tools**: Ensure compatibility with BSD coreutils (default on macOS) vs GNU coreutils.
- **Input Handling**: On macOS (Bash 3.2), `read -t < 1` is invalid. To read escape sequences without blocking:
  1. Detect SSH session (`SSH_CONNECTION` etc).
  2. Use `stty -icanon min 0 time 0` for local (instant) or `time 1` for SSH (safe).
  3. Use `dd bs=1 count=1` to read characters (Bash `read` ignores timeout).

## Project Structure

- **Source Code**: `src/` contains the modular source files (e.g., `00-header.sh`, `16-main.sh`). DO NOT edit `run.sh` directly.
- **Build System**: `build.sh` concatenates files from `src/` into `run.sh`.
- **Docs**: `docs/` contains detailed documentation.

## Development Workflow

1.  **Edit**: proper files in `src/`.
2.  **Build**: Run `./build.sh` to regenerate `run.sh`, then `make dev` for the dev distribution.
3.  **Test**: Run `make test` (full test suite) or `bash -x ./run.sh` for interactive debugging.

## Coding Guidelines (Bash)

- **Strict Mode**: The script runs with `set -euo pipefail`. Ensure all variables are checked for existence (`${VAR:-}`) and commands that might fail are handled (`cmd || true`).
- **ShellCheck**: All code must pass ShellCheck.
- **Modularity**: Keep functions small and grouped by responsibility (e.g., `13-ui.sh` for UI logic).
- **Architecture**: See `docs/ARCHITECTURE.md` for detailed design principles.

## Performance & Optimization Rules

These patterns MUST always be applied when writing or modifying code in this project.

### No unnecessary forks / subshells

- **NEVER** use `echo "$var" | grep`, `echo "$var" | tr`, `echo "$var" | cut` inside loops or frequently called functions. Use Bash built-ins instead:
  - String test: `[[ "$cmd" == *'<<'* ]]` instead of `echo "$cmd" | grep -q '<<'`
  - Lowercase: `tr '[:upper:]' '[:lower:]' <<< "$var"` (here-string, no `echo` fork)
  - Trimming: pure Bash string ops `${s#"${s%%[![:space:]]*}"}` instead of `sed`
  - Newline-to-space: `${var//$'\n'/ }` instead of `echo "$var" | tr '\n' ' '`
  - CSV-split: `IFS=',' read -r -a arr <<< "$csv"` instead of `printf '%s\n' "$csv" | tr ',' '\n'`
- **NEVER** use `$(basename ...)` or `$(dirname ...)` in loops – use Bash string ops: `${path##*/}` / `${path%/*}`
- **NEVER** call `$(printf ...)` where `printf -v varname ...` works (no subshell).
- **NEVER** use `var=$(cat single_line_file)` — use `read -r var < file` (no fork).
- **NEVER** chain `grep -v 'a' | grep -v 'b'` — use a single `grep -Ev 'a|b'` call.
- **NEVER** use `echo "$path" | sed ...` or `echo "$path" | grep ...` — use `sed ... <<< "$path"` with here-strings.
- When an external `grep` call on a **file** is unavoidable, use `_grep()` from `02-utils.sh` — it prefers `rg` (ripgrep) when available and falls back to `grep` transparently.

### macOS / BSD compatibility

- **`tac` does not exist on macOS** (GNU coreutils only). Always use `tail -r` first, fall back to `tac`: `tail -r "$f" 2>/dev/null || tac "$f" 2>/dev/null || true`
- **`sed -i` requires an extension argument on macOS BSD sed**: use `sed -i ''` for macOS, or branch with `sed -i "s/..." "$f" 2>/dev/null || sed -i '' "s/..." "$f"`.
- **`realpath` may not be installed** on stock macOS (requires `brew install coreutils`). Use the `get_realpath()` helper in `02-utils.sh` which handles absolute paths and falls back gracefully.
- **`sleep` fractional seconds** (`sleep 0.1`) work on macOS 10.1+ native sleep — acceptable.
- **BSD `stat`** uses `-f %m` for mtime; GNU `stat` uses `-c %Y`. Always use `get_file_mtime()` from `02-utils.sh` which auto-detects the correct form.

### Avoid repeated external process calls

- **DO NOT** run the same external command (e.g., `grep`, `stat`, `md5`) multiple times on the same file within one function. Consolidate into a single pass:
  - Multiple `grep -c` calls on the same file → single `awk` pass computing all counters.
  - `wc -l` + `tail` + `mv` for file trimming → use the shared `trim_file_to_lines()` helper in `02-utils.sh`.
- **Memoize** results of expensive lookups (hashes, stat) that don't change within a session using module-level variables (e.g., `_cache_file_last_path` / `_cache_file_last_result` pattern in `05-cache.sh`).

### Cache terminal capabilities

- Terminal strings (`tput civis`, `tput cnorm`, `tput cup`, `tput cols`) are initialized ONCE in `init_terminal_capabilities()` (`03-terminal.sh`) and stored in `TPUT_*` variables. **Never** call `tput` directly at runtime; always use the cached variables.
- The one-time guard uses a dedicated `_TPUT_INITIALIZED` flag (not `[ -n "${TPUT_COLS:-}" ]`) because `tput cols` can return an empty string when there is no TTY, which would cause the guard to fail on every call.
- Static decoration strings (e.g., the 60-char `═` border) must be built ONCE with lazy init: `: "${_VAR:=$(...)}"` – never rebuilt on every render call.
- Temp/parallel log files must be placed in `$CACHE_DIR` (not `/tmp/...`) so they are cleaned up automatically by the `cleanup_wrapper` EXIT trap.

### DRY – eliminate duplicate code patterns

- **`trim_file_to_lines <file> <max>`** (`02-utils.sh`): use it everywhere a file is capped to N lines. Do NOT re-implement `wc -l / tail / mv` inline.
- **`_grep [flags] pattern file`** (`02-utils.sh`): use it for all external grep-on-file calls — uses `rg` if installed, falls back to `grep`.
- **`_reload_menu`** (`13-ui.sh`): call it instead of the 3-line `IFS read < <(get_menu_options) + calculate_layout` pattern.
- **`_reinit_menu`** (`13-ui.sh`): call it instead of the 5-function sequence `parse_config_vars + load_settings + load_state + detect_config_files + load_aliases + _reload_menu`.
- **`run_with_term_paused <fn> [args]`** (`13-ui.sh`): wrap every `restore_term; <function>; [ is_interactive ] && stty raw` triplet with this helper.

### Safe function dispatch

- **NEVER** use `eval "$callback \"$arg1\" \"$arg2\""` to call a function by name. Use direct dispatch: `"$callback" "$arg1" "$arg2"`. This is faster, safer (no injection risk), and ShellCheck-clean.

### Global state is the source of truth

- `menu_options` is a global array always kept current by `_reload_menu`. Do NOT re-fetch it (`get_menu_options`) inside helper functions (e.g., `context_menu`) that are called from within the main loop – use the global directly.

## Key Components

- **Config**: `src/01-config.sh` handles loading `.tasks` files.
- **UI**: `src/13-ui.sh` contains the main interactive loop and key handling.
- **Execution**: `src/12-execution.sh` handles running selected tasks. Supports `--dry-run` (shows command without executing) and `--run <name|number>` CLI mode.
- **Utils**: `src/02-utils.sh` contains shared helpers incl. `trim_file_to_lines()`, `_grep()` (rg/grep fallback), `get_realpath()`, `get_file_mtime()`.
- **Cache**: `src/05-cache.sh` handles state persistence and memoization.

## Troubleshooting

- If the script exits unexpectedly, check for unhandled errors due to `set -e`.
- Use `bash -x ./run.sh` to trace execution flow.
