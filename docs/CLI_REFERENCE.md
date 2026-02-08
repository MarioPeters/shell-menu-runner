# CLI Reference

Quick reference for all shell-menu-runner command-line flags and options.

---

## Basic Usage

```bash
run                    # Start interactive menu (default mode)
run [profile]          # Load specific profile (.tasks.profile)
run taskname          # Execute task directly (no menu)
```

---

## Global Flags

### Help & Information

```bash
run --help            # Show all available commands
run --version         # Show version number
run --validate        # Validate .tasks syntax (all profiles)
```

### Output Control

```bash
run --no-color        # Disable colors (use MONO theme)
run --debug           # Enable debug output/verbose mode
run --quiet           # Suppress non-essential messages
```

### Environment

```bash
run --env FILE        # Load environment from FILE (instead of .env)
run --profile NAME    # Explicitly set active profile
run --list-profiles   # List all available profiles
```

---

## Execution Modes

### Interactive Menu (Default)

```bash
run                   # Shows menu, wait for input
run dev              # Show dev profile menu
run prod             # Show prod profile menu
```

### Direct Task Execution

```bash
run taskname         # Run task directly (no menu)
run build            # Execute 'build' task immediately
run deploy           # Execute 'deploy' task immediately
```

### Multi-Profile Execution

```bash
run --across profile1,profile2 taskname
                     # Execute task across multiple profiles (sequential)

run --across auth,api,worker deploy
                     # Deploy across all services

export RUN_PARALLEL_MULTI=1
run --across p1,p2 task
                     # Execute profiles in parallel
```

---

## Advanced Options

### Caching

```bash
export RUN_CACHE_PROFILES=1      # Enable profile caching
export RUN_CACHE_TTL=300         # Cache TTL in seconds (default: 60)

run                  # Uses cache if available
```

### Parallel Execution

```bash
export RUN_PARALLEL_DEPS=1       # Run independent deps in parallel
export RUN_PARALLEL_MULTI=1      # Run multi-profile tasks in parallel

run                  # Task dependencies execute in parallel
```

### Output Formatting

```bash
export RUN_NO_ANIMATION=1        # Disable animations
export RUN_DISABLE_ANIMATION=1   # Alias for above
export RUN_NO_COLORS=1           # Disable colors
```

### Themes

```bash
# Set via environment before running
export RUN_THEME=CYBER           # or DARK, LIGHT, MONO
run

# Or change in menu with 's' → Settings
```

---

## Task-Specific Flags

### Definition Format

```
LEVEL|NAME|COMMAND|DESCRIPTION
```

**Within COMMAND section:**

```bash
task depends:0,1,2   # Dependency markers (separates by comma)
task --parallel      # Flag passed to task
```

### Example Task with Flags

```bash
0|Build|npm run build|Build task
1|Test|npm run test depends:0|Run tests (after build)
2|Deploy|npm run deploy depends:1|Deploy (after test)
```

---

## Settings (Interactive Menu)

While in menu, press:

```bash
s                    # Open Settings menu
                     # - Change theme
                     # - Toggle colors
                     # - Reset options

h                    # Show History (recent tasks)
?                    # Show help panel
/                    # Search/filter tasks
↑ ↓                  # Navigate menu
1-9                  # Jump to task number
Enter                # Execute selected task
Ctrl+C               # Exit
```

---

## Configuration Files

### .tasks Files

```bash
.tasks               # Default tasks (always loaded)
.tasks.dev           # Profile-specific tasks
.tasks.prod          # Another profile
~/.tasks             # Global tasks (any project)
~/.tasks.NAME        # Global profile tasks
```

**Location search order:**

1. Current directory
2. Parent directories (up to root)
3. Home directory (`~`)
4. Global profiles (`~/.tasks*`)

### .env File

```bash
.env                 # Auto-loaded before task execution
                     # Format: KEY=value (one per line)
```

---

## Environment Variables

### Control Behavior

```bash
RUN_THEME=CYBER              # Theme: CYBER, DARK, LIGHT, MONO
RUN_CACHE_PROFILES=1         # Enable profile caching
RUN_CACHE_TTL=60             # Cache timeout (seconds)
RUN_PARALLEL_DEPS=1          # Parallel dependency execution
RUN_PARALLEL_MULTI=1         # Parallel multi-profile execution
RUN_NO_COLORS=1              # Disable colors
RUN_NO_ANIMATION=1           # Disable animations
TIMEOUT=300                  # Task timeout (seconds)
```

### Custom Variables

Any variables in `.env` available to tasks:

```bash
# .env
DATABASE_URL=postgresql://localhost/db
NODE_ENV=development
API_KEY=sk_test_xxx

# Usage in task:
run   # All variables auto-loaded before execution
```

---

## Examples

### Start Interactive Menu

```bash
run                  # Default profile menu
run dev             # Development profile menu
run prod            # Production profile menu
```

### Execute Without Menu

```bash
run build           # Run 'build' task directly
run test            # Run 'test' task directly
run deploy          # Run 'deploy' task directly
```

### Multi-Profile Operations

```bash
# Sequential execution
run --across dev,staging,prod deploy

# Parallel execution
RUN_PARALLEL_MULTI=1 run --across auth,api,worker deploy

# Explicit profile
run --profile myprofile build
```

### Enable Optimizations

```bash
# Cache profiles + parallel execution
export RUN_CACHE_PROFILES=1
export RUN_PARALLEL_DEPS=1
run                  # Faster menu + faster execution
```

### Validate & Debug

```bash
run --validate       # Check all tasks syntax
run --debug          # Verbose output
run --help          # Show all commands
```

---

## Common Patterns

### Development Workflow

```bash
run dev             # Show dev tasks
# Press 1           # Run: npm install
# Press 2           # Run: npm run dev
```

### Deployment Workflow

```bash
run --across staging,prod deploy
                    # Deploy to staging then prod (sequential)

RUN_PARALLEL_MULTI=1 run --across auth,api,worker deploy
                    # Deploy all services in parallel
```

### Testing & QA

```bash
run test            # Run all tests
run lint            # Lint code
run coverage        # Coverage report

# Or with dependencies
run qa-full         # Runs: lint → test → coverage (chained)
```

### With Environment

```bash
export DATABASE_URL="postgresql://prod/db"
run deploy          # Uses prod database

unset DATABASE_URL
run dev             # Back to local
```

---

## Exit Codes

```bash
0       Success - task completed
1       Error - task failed or validation error
2       Invalid argument or syntax error
^C      Ctrl+C - user interrupted
```

---

## Tips & Tricks

### Time Estimation

```bash
# Based on last execution
run taskname        # Shows timing info after completion
# "Completed in 2.5s"
```

### Task History

Press `h` in menu to see last 10 executed tasks

### Search/Filter

Press `/` then type:

```bash
/build     # Filter to tasks containing "build"
/deploy    # Filter to "deploy"-related tasks
```

### Direct Navigation

In menu, press number to jump:

```bash
1           # Jump to task #1
5           # Jump to task #5
9           # Jump to task #9
```

### Quick Shortcuts

```bash
Ctrl+D      # Context-dependent (fast operations)
Ctrl+L      # Clear/refresh display
Ctrl+R      # Recent tasks
```

---

## Keyboard Shortcuts Cheat

| Key            | Action        |
| -------------- | ------------- |
| `↑` / `↓`      | Navigate menu |
| `1-9`          | Jump to task  |
| `Enter`        | Execute task  |
| `/`            | Search/filter |
| `h`            | History       |
| `s`            | Settings      |
| `?`            | Help          |
| `q` / `Ctrl+C` | Quit          |

---

## See Also

- [KEYBOARD_SHORTCUTS.md](./KEYBOARD_SHORTCUTS.md) - Detailed keyboard guide
- [QUICK_START.md](./QUICK_START.md) - Getting started
- [ADVANCED_USAGE.md](./ADVANCED_USAGE.md) - Advanced patterns
- [README.md](../README.md) - Feature reference
