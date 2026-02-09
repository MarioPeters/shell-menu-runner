# CLI Reference

Quick reference for all shell-menu-runner command-line flags and options.

---

## Basic Usage

```bash
run                    # Start interactive menu (default)
run <profile>          # Load .tasks.<profile> (local or global)
run --global           # Force global mode (~/.tasks)
```

---

## Global Flags

```bash
run --help, -h         # Show help
run --version, -v      # Show version
run --debug            # Enable debug mode (set -x)
run --update           # Self-update to latest version
run --analyze [name]   # Analyze current or named profile
run --init             # Create .tasks in current dir (smart init)
run --init-profile <n> # Create .tasks.<n> template
run --list-profiles    # List profiles
run --list-profiles=json
run --validate [name]  # Validate profile syntax
run --edit, -e         # Open config editor
run --across p1,p2 task
                       # Execute task across multiple profiles
```

---

## Execution Modes

### Interactive Menu (Default)

```bash
run
run dev
run docker
```

### Multi-Profile Execution

```bash
run --across auth,api,worker deploy
```

---

## Configuration Files

```bash
.tasks               # Default tasks
.tasks.dev           # Local profile tasks
~/.tasks             # Global tasks
~/.tasks.NAME        # Global profile tasks
```

**Search order:** current dir -> parent dirs -> home.

---

## Task Format

```
LEVEL|NAME|COMMAND|DESCRIPTION
```

**Dependencies (in description):**

```bash
0|Build|npm run build|Build task
0|Test|npm run test|Run tests [depends: Build]
```

**Timeout (in description):**

```bash
0|Long Task|./run.sh|Run with timeout [timeout: 120]
```

---

## Environment Variables

```bash
RUN_PARALLEL_DEPS=1      # Parallel task dependencies
RUN_PARALLEL_MULTI=1     # Parallel multi-profile execution
RUN_CACHE_PROFILES=1     # Profile caching (default on)
RUN_FAST_GREP=1          # Optimized grep for large configs
RUN_EXPECTED_SHA256=...  # Self-update integrity check
RUN_DEBUG=1              # Enable debug mode
```

---

## Menu Shortcuts

```bash
s       # Settings
/       # Search/filter
#       # Tag filter
p       # Profile menu
f       # File browser
e       # Edit config
!       # History
r       # Favorites
?       # Help
q       # Quit
Esc     # Back or quit
```

---

## Examples

```bash
run --list-profiles
run --validate docker
run --across dev,staging,prod deploy
```

---

## See Also

- [KEYBOARD_SHORTCUTS.md](./KEYBOARD_SHORTCUTS.md)
- [QUICK_START.md](./QUICK_START.md)
- [ADVANCED_USAGE.md](./ADVANCED_USAGE.md)
- [README.md](../README.md)
