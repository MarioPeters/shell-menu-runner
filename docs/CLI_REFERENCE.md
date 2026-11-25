# CLI Reference

Quick reference for all shell-menu-runner command-line flags and options.

---

## Basic Usage

```bash
run                    # Start interactive menu (default)
run <profile>          # Load .tasks.<profile> (local or global)
run --global           # Force global mode (~/.tasks)
```

### Flag order

Options are parsed from left to right. A non-option argument is collected as
the profile and resolved after all options; therefore
`run git --run build` and `run --run build git` are equivalent. `--run`
consumes exactly one query argument — do not pass an additional bare word.

Flags that terminate the runner immediately (`--across`, `--update`,
`--init`, `--init-profile`, `--validate`, `--analyze`, `--edit`,
`--list-profiles`) end the process; anything after them is ignored.

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
run --list             # List all tasks non-interactively
run --run <query>      # Execute task non-interactively (name, substring, or number)
run --dry-run --run <query>
                       # Print the command instead of executing it
```

---

## Execution Modes

### Interactive Menu (Default)

```bash
run
run develop
run docker
```

### Multi-Profile Execution

```bash
run --across auth,api,worker deploy
```

The profiles are resolved like a profile argument: the current directory and
all parent directories are searched for `.tasks.<name>` first, `~/.tasks.<name>`
is the fallback. `--across` therefore works with local and with global
profiles.

### Non-Interactive CLI Mode

```bash
# List all available tasks (numbered)
run --list

# Execute by exact name
run --run "Build Project"

# Execute by number (from --list output)
run --run 3

# A leading zero is allowed ("08" is the 8th task)
run --run 08

# Execute by substring (disambiguates if multiple match)
run --run build
```

If a substring matches multiple tasks, a disambiguation prompt is shown.
Exit code reflects the executed task's exit code — suitable for CI/scripting.

### Non-Interactive Session (no TTY)

When stdin is not a terminal (e.g. `ssh host "run"` without `-t`, a pipe or a
cron job), the menu cannot be drawn. The task list is printed instead and the
tasks are selected by **number or name**:

```bash
# Print the task list, then run task 3
ssh host "cd project && run" <<< "3"

# Run by name
ssh host "cd project && run" <<< "Build Project"
```

In this mode tasks run in CLI mode: no preview, no "press any key" prompt.

---

## Configuration Files

```bash
.tasks                  # Default tasks in the current/parent directory
.tasks.NAME             # Local profile
.tasks.local            # Additive overlay for .tasks
.tasks.dev              # Additive overlay for .tasks
~/.tasks                # Global tasks
~/.tasks.NAME           # Global profile
~/.tasks.NAME.local     # Additive overlay for a global profile
~/.tasks.NAME.dev       # Additive overlay for a global profile
```

**Search order:** current dir -> parent dirs -> home. Profiles are resolved in
the same order; `local` and `dev` are reserved overlay suffixes and are not
listed by `--list-profiles`.

Overlays are **additive**: a task that exists in both `.tasks` and
`.tasks.local` appears twice in the menu, and `[depends: Name]` uses the first
match. Use unique task names to avoid ambiguity.

---

## Task Format

```
LEVEL|NAME|COMMAND|DESCRIPTION
```

The level must be a non-negative number (0 = main menu, 1 = first submenu, …).
A line with an invalid level is rejected by `run --validate` and ignored by the
menu. `NAME` and `COMMAND` are required; `DESCRIPTION` may be empty.

`|` is the field separator. A `|` inside a name or command cannot be
represented and shifts the remaining fields; `run --validate` warns when a line
contains more than four fields.

### Submenus

A submenu is opened by a `SUB` entry at level *N*; its children are the entries
at level *N+1* directly below it. Levels must be contiguous — a level-2 entry
without a level-1 `SUB` parent is not displayed.

| Command   | Meaning                                        |
| --------- | ---------------------------------------------- |
| `SUB`     | Opens a submenu (the task name is the title)   |
| `BACK`    | Goes back to the parent menu                   |
| `EXIT`    | Leaves the menu                                |

```bash
0|🧰 Tooling|SUB|Tools
1|📦 Build|make build|Build the project
1|⬅ Back|BACK|Back to the main menu
```

### Dependencies

The dependency annotation is read from the **command** *and* from the
**description** — both forms work:

```bash
0|Build|npm run build|Build task
0|Test|npm run test|Run tests [depends: Build]          # in the description
0|Lint|npm run lint [depends: Build]|Run tests after the build  # in the command
```

Several dependencies are separated by commas:

```bash
0|Deploy|echo deploy|Run after [depends: Build, Test]
```

The dependency is executed before the task. Dependencies are exact task names
and run sequentially unless `RUN_PARALLEL_DEPS=1` is set. If a dependency is
missing or fails, the task is not executed.

### Timeout

A timeout can be set globally in the task config file:

```
TIMEOUT=300
```

or per task in the description:

```bash
0|Long Task|./run.sh|Run with timeout [timeout: 120]
```

The per-task value wins over the global one. The default is 300 seconds; the
value must be a positive integer (seconds).

### Confirmation

A task whose description starts with `[!]` asks for a confirmation before it
is executed:

```bash
0|Deploy|./deploy.sh|[!] Deploys to production
```

### Placeholders

`<<Name>>`, `<<Name=default>>` and `<<Name:a,b>>` are replaced by the value
the user enters (or selects from the list). Cancelling the selection aborts
the task.

```bash
0|Commit|git commit -m "<<Commit message>>"|Commit with a message
0|Deploy|./deploy.sh <<Env:dev,prod>>|Deploy to an environment
```

---

## Environment Variables

```bash
RUN_PARALLEL_DEPS=1      # Parallel task dependencies (background, no terminal interaction)
RUN_PARALLEL_MULTI=1     # Parallel execution of multi-selected tasks
RUN_CACHE_PROFILES=1     # Menu cache: reuse the parsed task list (default on)
RUN_CACHE_DIR=...        # Persistent cache directory (default: ~/.cache/shell-menu-runner)
RUN_EXPECTED_SHA256=...  # Self-update integrity check
RUN_DEBUG=1              # Enable debug mode
```

### `~/.run_vars`

Variables from `~/.run_vars` are exported into the runner and into the
tasks. Dangerous names are skipped: `PATH`, `CDPATH`, `GLOBIGNORE`, `IFS`,
`BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `PROMPT_COMMAND`, `PS4`,
`LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, `DYLD_INSERT_LIBRARIES`,
`DYLD_LIBRARY_PATH` and `DYLD_FRAMEWORK_PATH`. Names that collide with one
of the runner's own readonly constants (`VERSION`, `RUN_*`, `DEFAULT_*`,
`LOCAL_CONFIG`, `GLOBAL_CONFIG`, …) are skipped the same way instead of
aborting the runner.

The same applies to the `.env` file of the project directory: it is loaded
with `set -a`, but `PATH`, `IFS`, `BASH_ENV`, `LD_*` and `DYLD_*` are
restored afterwards.

---

## Menu Shortcuts

```bash
↑ ↓ / j k    Navigate
← → / h l    Change the column
Enter        Execute the selected task
1-9          Execute the task with that number directly
Space        Mark a task (Enter runs all marked tasks)
/            Search/filter
#            Tag filter
s            Settings
e            Edit the config
f            File browser
a            Alias editor
g            Switch between the local and the global config
p            Profile menu
!            History
r            Favorites
R            Recent tasks
L            Log files
c            Copy the command of the selected task
*            Toggle the favorite of the selected task
?            Help
q            Quit
Esc          Back or quit
```

The complete list — including the keys of the submenus — is in
[KEYBOARD_SHORTCUTS.md](./KEYBOARD_SHORTCUTS.md).

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
