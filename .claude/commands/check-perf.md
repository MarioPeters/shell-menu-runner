---
description: Check for performance anti-patterns in src/ files
---

Scan all files in `src/` for the performance anti-patterns defined in CLAUDE.md.

Check for:
1. **Fork anti-patterns**: `echo "$var" | grep`, `echo "$var" | tr`, `echo "$var" | cut`, `$(basename`, `$(dirname`, `$(printf`, `var=$(cat `, `grep -v.*| grep -v`
2. **Direct tput calls**: `tput ` outside of `init_terminal_capabilities()` in `03-terminal.sh`
3. **eval for dispatch**: `eval "$` pattern for function calls
4. **Hardcoded /tmp/**: temp files in `/tmp/` instead of `$CACHE_DIR`
5. **Re-fetching global**: `get_menu_options` called inside functions in `13-ui.sh` (not in `_reload_menu`)

For each finding: show file, line number, the problematic code, and the correct alternative.
