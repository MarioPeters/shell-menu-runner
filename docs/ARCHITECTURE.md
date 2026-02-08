# Architecture & Code Structure

In-depth guide to the codebase for developers and contributors.

---

## Table of Contents

1. [Overview](#overview)
2. [File Structure](#file-structure)
3. [Core Components](#core-components)
4. [Execution Flow](#execution-flow)
5. [Feature Deep Dives](#feature-deep-dives)
6. [Contributing Guide](#contributing-guide)
7. [Development Workflow](#development-workflow)

---

## Overview

**shell-menu-runner** is a Bash-based task automation framework built with these principles:

- **Single file:** Entire codebase in `run.sh` (~2850 lines) - no external dependencies, universal distribution
- **Zero dependencies:** Works with only Bash 3.2+, runs anywhere
- **Function-based:** 95+ named functions organized by feature category
- **Profile system:** Load different task sets via profiles
- **POSIX-compatible:** Strict mode (`set -euo pipefail`) for reliability

---

## File Structure

```
.
├── run.sh              # Main application (2850+ lines, 95+ functions)
├── install.sh          # Installation script (369 lines, generates 18 profiles)
├── docs/
│   ├── QUICK_START.md  # 5-minute beginner guide
│   ├── ADVANCED_USAGE.md # Power-user recipes & patterns
│   ├── TROUBLESHOOTING.md # Common issues & solutions
│   ├── examples/       # Real-world .tasks templates
│   │   ├── README.md
│   │   ├── node-project.tasks
│   │   ├── python-project.tasks
│   │   ├── devops-k8s.tasks
│   │   ├── microservices-root.tasks
│   │   ├── microservice-service.tasks
│   │   └── web-project.tasks
│   └── screenshot.svg  # UI mockup
├── integrations/       # Third-party integrations
│   ├── alfred/
│   ├── raycast/
│   └── zsh/
├── scripts/
│   └── release.sh      # Release automation
├── completions/
│   └── _run            # Zsh completions
└── README.md           # Feature reference
```

---

## Core Components

### 1. Main Loop & Menu System

**Lines:** ~500-1000

```bash
# Core entry point
main()
    ↓
load_profiles()           # Load .tasks files ($HOME + parent dirs)
    ↓
render_menu()             # Display interactive menu
    ↓
handle_input()            # Process keyboard input
    ↓
execute_task()            # Execute selected task
```

**Key functions:**

- `main()` - Entry point, initialization
- `load_profiles()` - Discover & load .tasks files
- `render_menu()` - Display task list with formatting
- `handle_input()` - Process keyboard input, filtering, navigation
- `execute_task()` - Run selected task with error handling

---

### 2. Profile System

**Lines:** 1200-1350

**Purpose:** Load different task sets based on context

```bash
# Profile loading hierarchy
1. Local profiles (.tasks, .tasks.NAME in project dir)
2. Global profiles (~/.tasks, ~/.tasks.NAME)
3. Built-in defaults

# Profile locations
.tasks              # Default: loaded always
.tasks.dev          # Feature-specific: loaded via `run dev`
.tasks.prod         # Environment-specific: loaded via `run prod`
~/.tasks.gitproj    # Global: available across projects
```

**Key functions:**

- `load_profile_config()` - Load profile into memory
- `setup_profile_defaults()` - Set default variables per profile
- `resolve_profile_location()` - Find profile file
- `parse_env_file()` - Load .env variables

---

### 3. Task Parsing & Validation

**Lines:** 1500-1700

**Task format:** `LEVEL|NAME|COMMAND|DESCRIPTION`

```bash
# Example task line
0|Build|npm run build|Build production bundle

# Components parsed
LEVEL=0              # Menu depth (for sub-menus)
NAME="Build"         # Display name
COMMAND="npm run build"  # Shell command to execute
DESCRIPTION="Build..."   # Help text
```

**Parsing functions:**

- `parse_task_line()` - Parse single task line
- `validate_task_syntax()` - Check format validity
- `extract_dependencies()` - Find `depends:0,1,2` markers
- `process_progress_output()` - Detect `[progress:X%]` markers

---

### 4. Dependency Resolution

**Lines:** 1800-2000

**Features:**

- Sequential execution (default)
- Parallel execution (when `RUN_PARALLEL_DEPS=1`)
- Cycle detection
- Dependency aggregation

```bash
# Task with dependencies
0|Test|npm run test
1|Build|npm run build depends:0   # Runs test first, then build
2|Deploy|npm run deploy depends:1 # Runs build first, then deploy

# Parallel execution
export RUN_PARALLEL_DEPS=1
# Now tasks 0,1,2 execute as:
# 0 → 1 (depends on 0) → 2 (depends on 1)
# But multiple non-dependent tasks run in parallel
```

**Key functions:**

- `resolve_dependencies()` - Build dependency graph
- `execute_with_deps()` - Run task chain
- `execute_parallel()` - Parallel execution handler
- `detect_cycles()` - Find circular dependencies

---

### 5. Output & Display

**Lines:** 100-300

**Features:**

- Color theming (CYBER, MONO, DARK, LIGHT)
- Progress bar rendering
- Progress marker detection
- Formatted output with alignment

**Color functions:**

```bash
color_setup()         # Initialize color variables
render_progress_bar() # Display [========------] 50%
process_progress_output() # Detect [progress:50%] markers
format_table()        # Align columnar output
```

**Themes:**

- CYBER: Neon colors (high contrast)
- MONO: Black & white
- DARK: Dark theme
- LIGHT: Light theme

---

### 6. Caching System

**Lines:** 2400-2500

**Purpose:** Speed up repeated menu loads

```bash
# Cache behavior
1. Load profile from cache if fresh (TTL configurable)
2. On task change: invalidate cache
3. TTL default: 60 seconds

# Environment control
export RUN_CACHE_PROFILES=1    # Enable caching
export RUN_CACHE_TTL=300       # 5 minutes
```

**Key functions:**

- `cache_profile()` - Save to cache
- `load_from_cache()` - Load cached profile
- `check_cache_validity()` - Check if cache is stale
- `invalidate_cache()` - Clear cache

---

### 7. Multi-Profile Execution

**Lines:** 1317-1420 (Feature 2)

**Purpose:** Run same task across multiple profiles simultaneously

```bash
# Usage
run --across profile1,profile2,profile3 taskname

# Execution modes
Sequential (default):
  1. Load profile1, run taskname
  2. Load profile2, run taskname
  3. Load profile3, run taskname

Parallel (RUN_PARALLEL_MULTI=1):
  1. Load all profiles simultaneously
  2. Run taskname in each profile in parallel
  3. Aggregate results
```

**Key functions:**

- `execute_multi_profile_task()` - Orchestrate multi-profile execution
- `_execute_profile_callback()` - Single profile executor
- `aggregate_results()` - Combine results

---

## Execution Flow

### Diagram: User Input to Task Execution

```
┌─────────────────────────────────────────┐
│ User runs: run profile filter           │
└──────────────────┬──────────────────────┘
                   ↓
        ┌──────────────────────┐
        │  Parse CLI arguments │
        └──────────────┬───────┘
                       ↓
        ┌──────────────────────────────────┐
        │ Load profile (.tasks or .tasks.X) │
        └──────────────┬───────────────────┘
                       ↓
        ┌──────────────────────────┐
        │  Parse task lines        │
        │  (LEVEL|NAME|CMD|DESC)   │
        └──────────────┬───────────┘
                       ↓
        ┌──────────────────────────────┐
        │  Apply filtering/search       │
        └──────────────┬───────────────┘
                       ↓
        ┌──────────────────────────────────┐
        │  Render interactive menu         │
        │  (Display task list with colors) │
        └──────────────┬───────────────────┘
                       ↓
        ┌──────────────────────────────────┐
        │  Wait for user input             │
        │  (Arrow keys, number, search)    │
        └──────────────┬───────────────────┘
                       ↓
        ┌──────────────────────────────────┐
        │  Resolve dependencies            │
        │  (If task has depends:X,Y,Z)     │
        └──────────────┬───────────────────┘
                       ↓
        ┌──────────────────────────────────┐
        │  Execute task(s)                 │
        │  (Direct bash execution)         │
        └──────────────┬───────────────────┘
                       ↓
        ┌──────────────────────────────────┐
        │  Detect progress markers         │
        │  ([progress:X%] or [progress:X/Y])│
        │  Render progress bar if found    │
        └──────────────┬───────────────────┘
                       ↓
        ┌──────────────────────────────────┐
        │  Capture output & errors         │
        │  Display to user                 │
        └──────────────┬───────────────────┘
                       ↓
        ┌──────────────────────────────────┐
        │  Report status & timing          │
        │  Ask for next action             │
        └──────────────────────────────────┘
```

### Key Function Sequence

```bash
main()
  setup_signal_handlers()        # Ctrl+C handling
  initialize_environment()       # Color, paths, etc
  load_profiles()                # Find & load .tasks files

  while true; do
    render_menu()                # Display menu
    handle_input()               # Get user choice

    if [[ task_selected ]]; then
      resolve_dependencies()     # Build execution chain
      execute_task()             # Run task + dependents
      wait_for_completion()      # Show results
    fi
  done
```

---

## Feature Deep Dives

### Feature 1: Progress Bar

**Implementation:** Lines 87-136, 2197-2220

**Detection Mechanism:**

```bash
# Task outputs this
echo "[progress:50%]"        # 50%
echo "[progress:25/100]"     # 25 out of 100

# run.sh detects via regex
if [[ "$line" =~ \[progress:([0-9]+)%\] ]]; then
    local percent="${BASH_REMATCH[1]}"
    render_progress_bar "$percent"
fi
```

**Rendering:**

```bash
render_progress_bar() {
    local percent=$1
    local width=${2:-30}
    local filled=$((percent * width / 100))
    local empty=$((width - filled))

    printf "%s[" "$COLOR_SEL"           # Open bracket
    printf "%0.s=" $(seq 1 "$filled")   # Filled portion
    printf "%0.s-" $(seq 1 "$empty")    # Empty portion
    printf "] %3d%%${COLOR_RESET}" "$percent"
}
```

**Output:**

```
[============================------] 50%
```

---

### Feature 2: Multi-Profile Parallel

**Implementation:** Lines 1317-1420, CLI parser 2619-2630

**Execution Modes:**

```bash
# Sequential (safe)
export RUN_PARALLEL_MULTI=0
run --across auth,api,worker deploy
# Result:
# - Deploy auth (finish)
# - Deploy api (finish)
# - Deploy worker (finish)

# Parallel (fast)
export RUN_PARALLEL_MULTI=1
run --across auth,api,worker deploy
# Result:
# - Deploy auth (background)
# - Deploy api (background)
# - Deploy worker (background)
# - Wait for all to complete
# - Show aggregated results
```

**Implementation Detail:**

```bash
execute_multi_profile_task() {
    local task_name="$1"
    local profiles_str="$2"  # "auth,api,worker"

    if [[ "$RUN_PARALLEL_MULTI" == "1" ]]; then
        # Parallel execution
        _execute_profile_callback "$profile" "$task_name" &
        # ...repeat for each...
        wait    # Wait all background jobs
    else
        # Sequential
        _execute_profile_callback "$profile" "$task_name"
        # ...repeat for each...
    fi
}
```

---

## Contributing Guide

### Setting Up Development Environment

```bash
# Clone repo
git clone https://github.com/yourusername/shell-menu-runner
cd shell-menu-runner

# Verify setup
bash run.sh --help
shellcheck -x run.sh   # Should be 0 errors, 0 warnings
bash -n run.sh         # Syntax check

# Create test profile
echo "0|Test|echo hello|Test task" > .tasks
run                    # Should load menu
```

### Code Style

**Bash Style Guide:** Google Shell Style Guide

**Key rules:**

- Use `local` for function variables
- Quote variables: `"$var"` not `$var`
- Use `[[` for conditionals, not `[`
- Use `printf` not `echo` for portability
- Function names: `snake_case`
- Variable names: `UPPER_CASE` for globals, `lower_case` for locals

**Example:**

```bash
# ✅ Good
my_function() {
    local user_input="$1"
    local output

    if [[ -n "$user_input" ]]; then
        output=$(process "$user_input")
        printf "%s\n" "$output"
    fi
}

# ❌ Bad
my_function() {
    user_input=$1              # Missing quotes, local
    echo $(process $user_input) # Should use printf, quote
}
```

---

### Adding New Features

**Step 1: Create feature branch**

```bash
git checkout -b feature/my-feature
```

**Step 2: Implement in run.sh**

```bash
# Add helper function
my_feature_helper() {
    local arg=$1
    # Implementation
}

# Integrate with main flow
# (Add calls in appropriate existing functions)
```

**Step 3: Add CLI flag if needed**

```bash
# In CLI parser section (around line 2500)
--my-flag)
    my_feature_helper "$1"
    shift
    ;;
```

**Step 4: Testing**

```bash
bash -n run.sh           # Syntax check
shellcheck -x run.sh     # Linting
run --help               # Verify help text
run --validate           # Validate tasks
```

**Step 5: Documentation**

```bash
# Update README.md with feature description
# Update ADVANCED_USAGE.md with usage examples
# Create example in docs/examples/ if applicable
```

**Step 6: Submit PR**

```bash
git add run.sh README.md docs/
git commit -m "feat: add my feature"
git push origin feature/my-feature
# Submit PR on GitHub
```

---

### Function Organization

**Categories in run.sh:**

```bash
# 1. Initialization (100-150 lines)
main()
setup_signal_handlers()
initialize_environment()

# 2. Display/Colors (100-200 lines)
color_setup()
render_menu()
format_output()
render_progress_bar()

# 3. Profile Management (200-300 lines)
load_profiles()
load_profile_config()
resolve_profile_location()

# 4. Task Parsing (200-250 lines)
parse_task_line()
validate_task_syntax()
extract_dependencies()

# 5. Execution (300-400 lines)
execute_task()
execute_with_deps()
execute_parallel()

# 6. Utilities (100-150 lines)
find_project_root()
cache_profile()
check_command_exists()

# 7. CLI Handling (100-150 lines)
parse_cli_args()
show_help()
show_version()
```

---

## Development Workflow

### Adding a Bug Fix

1. **Identify the problem** (use `run --debug` for help)
2. **Create test case** (in .tasks file)
3. **Fix in run.sh** (smallest change possible)
4. **Verify fix** (bash -n, shellcheck, manual test)
5. **Commit** with clear message

### Adding a Feature

1. **Design** (discuss in issue)
2. **Implement** (add helper functions)
3. **Test** (create examples)
4. **Document** (README + examples)
5. **Submit PR** with tests

### Performance Optimization

1. **Profile** (identify slow section)
2. **Optimize** (reduce operations)
3. **Benchmark** (time before/after)
4. **Document** (update ADVANCED_USAGE)

---

### Debugging Tips

```bash
# Enable verbose output
bash -x run.sh

# Trace specific function
bash -x run.sh --validate

# Debug variable contents
set -x
my_function
set +x

# Check function definition
declare -f function_name

# List all functions
declare -F | awk '{print $3}'
```

---

## Performance Considerations

### Optimization Strategies

1. **Cache profiles** (avoid re-parsing)
2. **Parallel deps** (run independent tasks together)
3. **Parallel multi-profile** (execute across profiles)
4. **Split profiles** (reduce menu size)
5. **Use lazy-loading** (load on demand)

### Benchmark Results

```bash
# Load time with caching
Without cache: 0.8s
With cache:    0.1s → 8x faster

# Dependency execution (10 tasks, 3 levels)
Sequential: 10s
Parallel:   3s → 3x faster

# Multi-profile (3 profiles)
Sequential: 15s
Parallel:   5s → 3x faster
```

---

## Testing Checklist

Before submitting PR:

```bash
✅ Syntax valid:        bash -n run.sh
✅ No lint warnings:    shellcheck -x run.sh
✅ Help works:          run --help
✅ Validation works:    run --validate .tasks
✅ Menu renders:        run (manual test)
✅ Tasks execute:       run task-name
✅ Dependencies work:   Create .tasks with depends:
✅ Profiles load:       Create .tasks.test, run test
✅ Parallel works:      RUN_PARALLEL_DEPS=1 run
✅ Multi-profile works: run --across profile1,profile2 task
✅ No regressions:      All existing features still work
```

---

## Release Process

See [scripts/release.sh](../../scripts/release.sh)

```bash
./scripts/release.sh v1.x.0
# - Bumps version
# - Updates CHANGELOG.md
# - Creates git tag
# - Publishes GitHub release
```

---

## Key Metrics

| Metric                | Value                |
| --------------------- | -------------------- |
| Lines of code         | 2850+                |
| Functions             | 95+                  |
| Features              | 30+                  |
| Profiles              | 18 templates         |
| Shellcheck score      | 0 errors, 0 warnings |
| Minimum Bash version  | 3.2+                 |
| External dependencies | 0                    |
| Installation size     | ~40KB                |

---

## Related Documentation

- [QUICK_START.md](QUICK_START.md) - 5-minute beginner guide
- [ADVANCED_USAGE.md](ADVANCED_USAGE.md) - Power-user patterns
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Debug guide
- [README.md](../../README.md) - Feature reference

---

**Questions?** Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md#debug-mode) for debug mode tips.
