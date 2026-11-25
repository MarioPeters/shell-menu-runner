# GitHub Copilot Instructions for Shell Menu Runner

This project is a modular Bash-based task runner and interactive menu system.

## Environment Requirements & Optimization

- **OS**: macOS (Apple Silicon / ARM64) is the primary target; Linux must work too.
- **Shell**: The script itself is `bash` (3.2+), but it must be fully usable from a
  `zsh` interactive session as is standard on macOS.
- **Performance**: On macOS/ARM, prefer built-ins over external binaries (BSD
  `grep`/`sed` behave differently than GNU). Avoid unnecessary subshells in loops.
- **Input Handling**: On macOS (Bash 3.2), `read -t < 1` is invalid. Use
  `read_key` / `read_key_raw` / `read_key_optional` from `src/03-terminal.sh`.

## Project Structure

- **Source Code**: `src/` contains the modular source files (`00-header.sh` …
  `16-main.sh`). **Never edit generated files** (`run.sh`, `run.min.sh`,
  `dist/*`) — edit `src/` and rebuild.
- **Build**: `build.sh` concatenates `src/` into `run.sh`; `build-platform/`
  and the `Makefile` create the dist targets.
- **Tests**: `build-platform/tests/test-runner.sh` (behavior) and
  `build-platform/tests/test-docs.sh` (documentation consistency).
- **Docs**: `docs/ARCHITECTURE.md` has the full function index;
  `docs/CLI_REFERENCE.md` and `docs/KEYBOARD_SHORTCUTS.md` are the user-facing
  references.

## Build & Test Commands

```bash
./build.sh                  # regenerate run.sh from src/
make dev                    # build dist/run-dev.sh
make all                    # build all dist targets
make test                   # run the behavior suite
make lint                   # rebuild + ShellCheck
make check                  # test + lint
bash build-platform/tests/test-docs.sh
```

## Coding Rules

- Strict mode is enabled in the header: use `${VAR:-}`, quote expansions and
  append `|| true` to commands that may legitimately fail.
- Bash 3.2 compatible: no associative arrays, no `${var,,}`, no `mapfile`.
- Use `[[ ]]` for conditionals and `printf` for data output.
- Functions are `snake_case`; globals are `UPPER_CASE`.
- Source files are concatenated in numeric order; a syntax error in one file
  breaks the whole script.
- Never dispatch via `eval`; call the callback function directly.
- Use `config_dir_of()` instead of `${config_path%/*}` (handles bare file names
  and `/.tasks`).
- Use `save_shell_opts()` / `restore_shell_opts()` when temporarily changing
  `set -e` or `pipefail` inside menu code.
- Use `parse_task_deps()` for `[depends: ...]` (command **or** description) and
  `task_timeout_for_desc()` for `[timeout: N]`.
- Use `_grep -e <pattern> -- <file>` for user-provided patterns; otherwise a
  leading `-` is parsed as an option and `rg` may block on stdin.
- `.env` is loaded inside the task child through `_run_env_guard`; it must not
  be sourced in the runner process.
- Temp files belong in `$CACHE_DIR`; persistent state belongs in
  `$RUN_CACHE_DIR`.
- The zsh files (`completions/_run`, `integrations/zsh/run_widget.zsh`) are not
  valid Bash. Check them with `zsh -n`, never with ShellCheck.

## Key Invariants

- `menu_options` is kept current by `_reload_menu`; do not re-fetch it inside
  the main loop.
- `_build_menu_options` / `_build_all_tasks` cache parsed arrays and must be
  called in-process (not in a subshell).
- Invalid config levels are ignored by the menu and reported by `--validate`.
- Unknown `-*` CLI arguments are errors, not profile names.
- Ctrl+C must stop the task while the menu survives (`trap ':' INT`, run the
  task in the foreground).
- Background tasks (parallel dependencies) run via `execute_task_quiet` and
  must not touch the terminal.
- Overlays (`.tasks.local`, `.tasks.dev`) are additive; duplicate task names
  appear twice and dependency lookup uses the first match.
- Documentation, keys and flags are enforced by `test-docs.sh`; update the docs
  in the same change.

## Verification

```bash
./build.sh
shellcheck -x run.sh build.sh install.sh
bash build-platform/tests/test-runner.sh
bash build-platform/tests/test-docs.sh
```
