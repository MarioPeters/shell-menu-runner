---
description: Check for performance anti-patterns in src/ files
---

Scan all files in `src/` for the performance anti-patterns defined in CLAUDE.md.

Check for:
1. **Fork anti-patterns**: `echo "$var" | grep`, `echo "$var" | tr`, `echo "$var" | cut`, `$(basename`, `$(dirname`, `$(printf`, `var=$(cat `, `grep -v.*| grep -v`
2. **Here-strings in loops**: `IFS='|' read -r ... <<< "$line"` inside a `for`/`while` loop — a here-string creates a temp file in Bash 3.2 (~130 µs per call). Use `split_task_line` (`02-utils.sh`) instead. One-off calls outside loops are fine.
3. **`tr` per line**: `tr '[:upper:]' '[:lower:]' <<< "$var"` inside a loop — use `shopt -s nocasematch` around the comparison
4. **Direct tput calls**: `tput ` outside of `init_terminal_capabilities()` in `03-terminal.sh` (the periodic width poll in `draw_menu` is the only allowed exception)
5. **eval for dispatch**: `eval "$` pattern for function calls
6. **Hardcoded /tmp/**: temp files in `/tmp/` instead of `$CACHE_DIR`
7. **Re-fetching global**: `get_menu_options` called inside functions in `13-ui.sh` (not in `_reload_menu`)
8. **Byte-based width math**: `${#var}` or `$(( (bytes - chars) / 3 ))` used to measure a display width — use `display_width` / `fit_to_width` (`03-terminal.sh`)

Additionally verify the stability rules:

9. **Unprotected `stty`/`tput`**: every call must end with `|| true` (without a TTY the call fails and `set -e` aborts the script)
10. **`trap '' INT`**: the "ignore" disposition is inherited by child processes, so a task could never be stopped with Ctrl+C — use `trap ':' INT`
11. **Background task commands**: Bash sets SIGINT to "ignore" for background jobs — task commands must run in the foreground
12. **Waiting for pipe EOF**: code that waits for the end of a task's output pipe hangs if the task leaves a background process behind — wait for the process instead

For each finding: show file, line number, the problematic code, and the correct alternative.
