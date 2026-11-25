# ⚡ Advanced Usage Guide

Power-user recipes, patterns, and best practices. Everything in this guide is
implemented by the current runner; for the exact flags see
[CLI_REFERENCE.md](CLI_REFERENCE.md).

---

## Table of Contents

1. [Task Organization Patterns](#task-organization-patterns)
2. [Advanced Task Dependencies](#advanced-task-dependencies)
3. [Multi-Profile Workflows](#multi-profile-workflows)
4. [Progress Monitoring](#progress-monitoring)
5. [Environment & Secrets](#environment--secrets)
6. [Performance Optimization](#performance-optimization)
7. [CI/CD Integration](#cicd-integration)
8. [Custom Scripts & Automation](#custom-scripts--automation)

---

## Task Organization Patterns

### Pattern 1: Profiles and overlays

```
Project Root/
├── .tasks           # Core/shared tasks
├── .tasks.local     # Additive local overlay
├── .tasks.dev       # Additive development overlay
├── .tasks.deploy    # Deploy profile
├── .tasks.test      # Test profile
└── .tasks.ops       # Operations profile
```

```bash
run                  # .tasks + .tasks.local + .tasks.dev
run deploy           # .tasks.deploy + its .local/.dev overlays
run --global         # ~/.tasks
```

Overlays are additive, not overriding. If the same task name exists in two
files, both entries are shown; dependency lookup uses the first match. Keep
task names unique across overlays.

### Pattern 2: Submenus

A submenu exists when a `SUB` entry at level *N* is followed by entries at
level *N+1*. A level-2 entry without a level-1 `SUB` parent is invisible.

```bash
0|Database|SUB|Database operations
1|Backup|pg_dump "$DB" > backup.sql|Create a backup
1|Restore|psql "$DB" < backup.sql|[!] Overwrite the database
1|⬅ Back|BACK|Back to the main menu

0|Deploy|SUB|Deployment
1|Staging|./deploy.sh staging|[!] Deploy to staging
1|Production|./deploy.sh production|[!] Deploy to production
```

`BACK` and `EXIT` are menu commands; they are never executed as shell
commands.

### Pattern 3: Aliases

Aliases live in `~/.run_aliases` (`name=value` per line) and expand a profile
or task argument:

```text
d=develop
b=Build
prod=deploy
```

```bash
run d          # same as: run develop
run b          # executes the task "Build" when it exists
```

---

## Advanced Task Dependencies

Dependencies use the exact task name. The annotation may appear in the command
or in the description:

```bash
0|Build|npm run build|Build the project
0|Test|npm test|Run tests [depends: Build]
0|Lint|npm run lint [depends: Build]|Static checks
0|Deploy|./deploy.sh|[!] Deploy [depends: Build, Test, Lint]
```

Semantics:

- Dependencies run before the task, in the order listed.
- If a dependency fails, the task is not executed.
- A missing dependency is an error and aborts the task.
- Dependencies are resolved in the current menu (including submenus).
- With `RUN_PARALLEL_DEPS=1`, independent dependencies run in the background.
  Their output is logged, not streamed to the terminal. Interactive features
  (placeholders, `[!]` confirmation, pipelines) are not used for parallel
  dependencies.

### Dependency chains

```bash
0|Install|npm ci|Install dependencies
0|Build|npm run build|Build [depends: Install]
0|Test|npm test|Test [depends: Build]
0|Package|npm pack|Create tarball [depends: Test]
```

There is no automatic rollback. A failure stops the current chain; earlier
steps stay applied. Put a cleanup command in the task or use a wrapper script
if you need transactional behavior.

---

## Multi-Profile Workflows

### Run one task across profiles

```bash
run --across dev,staging,prod deploy
```

Profiles are resolved like a normal profile argument: current directory and
parents first, then `~/.tasks.<name>`. Execution is sequential by default. Set
`RUN_PARALLEL_MULTI=1` to run the profiles concurrently:

```bash
RUN_PARALLEL_MULTI=1 run --across dev,staging,prod deploy
```

The exit status is non-zero when at least one profile fails or the task is
missing in a profile.

### Compare profiles

```bash
run --list-profiles
run --list-profiles=json
run develop --list
run prod --list
```

`--list-profiles=json` emits a JSON object with a `profiles` array, suitable
for scripts.

### Profiles with different task sets

```bash
.tasks             # shared: build, test, lint
.tasks.develop     # adds: dev-server, watch
.tasks.prod        # adds: deploy, rollback
```

Run `run develop` for the development view and `run prod` for deployment. Avoid
duplicating a task name across profiles and overlays.

---

## Progress Monitoring

Tasks can print progress markers; the runner renders a bar and suppresses the
marker line:

```bash
# Percentage form
for i in $(seq 1 10); do
    echo "Step $i"
    echo "[progress:$((i * 10))%]"
    sleep 1
done
```

```bash
# Current/total form
total=20
for i in $(seq 1 "$total"); do
    echo "[progress:$i/$total]"
    sleep 0.5
done
```

The bar uses the configured terminal width. Output still goes to the log file;
the marker itself is not written to the log (the rendered bar is).

### Timeouts and cancellation

```bash
0|Integration Tests|./run-tests.sh|Long test [timeout: 900]
```

- The default timeout is 300 seconds.
- A task timeout is reported with exit code `124`.
- `Ctrl+C` stops the running task and returns to the menu.
- In CLI mode (`--run`) the task exit code is returned to the caller.

---

## Environment & Secrets

### `.env`

A `.env` file in the config directory is sourced before the task command runs.
Values are exported for the task:

```bash
# .env
DATABASE_URL=postgres://localhost/myapp
API_TOKEN=secret
```

The runner protects itself against a `.env` that would break command
resolution: `PATH` and `IFS` are restored, and `BASH_ENV`, `ENV`, `LD_*` and
`DYLD_*` are unset after sourcing. Do not rely on `.env` to change the
runner's own environment.

There is one `.env` per config directory, not one per profile. If you need
profile-specific values, put them in the profile's task commands or use
separate directories.

### `~/.run_vars`

```bash
# ~/.run_vars
API_BASE=https://api.example.com
DEPLOY_USER=deploy
```

These variables are exported into the runner and into tasks. Dangerous names
are skipped: `PATH`, `CDPATH`, `GLOBIGNORE`, `IFS`, `BASH_ENV`, `ENV`,
`SHELLOPTS`, `BASHOPTS`, `PROMPT_COMMAND`, `PS4`, `LD_PRELOAD`,
`LD_LIBRARY_PATH`, `LD_AUDIT`, `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`
and `DYLD_FRAMEWORK_PATH`. Names that collide with one of the runner's own
readonly constants (`VERSION`, `RUN_*`, `DEFAULT_*`, `LOCAL_CONFIG`,
`GLOBAL_CONFIG`, …) are skipped as well — an attempt to export them would
otherwise abort the whole runner under `set -e`.

### Task-local variables

`VAR_*` lines at the top of a task config are exported before tasks run:

```bash
VAR_PORT=8080
VAR_ENV=development

0|Serve|python -m http.server "$VAR_PORT"|Local server
```

The full name is exported: `VAR_PORT` is available as `$VAR_PORT`, not as
`$PORT`.

### Secrets

- Keep `.env` and `~/.run_vars` out of version control.
- Prefer an external secret manager or the shell environment for credentials.
- Logs contain the task output; never print secrets in a task.
- `--dry-run` prints the command, so it can expose literal secrets in commands.

---

## Performance Optimization

### Menu cache

```bash
RUN_CACHE_PROFILES=1 run     # default: reuse the parsed task list
RUN_CACHE_PROFILES=0 run     # disable the cache (debugging)
```

The cache key includes config path, change stamp, level, breadcrumb and active
filters. Editing the config through `e` invalidates it explicitly.

### Large task files

- Prefer many small profiles over one huge file.
- Use tags (`#tag`) and search instead of deep submenus with thousands of
  entries.
- Avoid `$(...)` and here-strings in commands that run once per line.
- The renderer only draws visible rows; the whole file is still parsed once
  per cache miss.

### Minimal build

`run.min.sh` (built with `./build.sh --min`) removes the advanced features
(search, tags, favorites, history, logs, alias editor, file browser, config
editor) and is useful for constrained systems. The mini build keeps
navigation, profiles, execution and settings.

---

## CI/CD Integration

### Run one task and propagate the exit code

```bash
run --run build
```

`--run` accepts an exact name, a unique substring or the number from
`--list`. If a substring matches several tasks, the runner asks for a more
specific query. The exit code is the task's exit code.

```bash
run --dry-run --run build    # print the command, do not execute it
```

### Validate task files

```bash
run --validate ci
run --list
```

`--validate` checks level and required fields. It does not detect unused
dependencies.

### Non-TTY sessions

```bash
ssh host "cd project && run --run build"
ssh host "cd project && run" <<< "3"
```

Without a TTY the task list is printed and input is read as a number or name.
No preview and no "press any key" prompt is shown.

### GitHub Actions example

```yaml
- name: Build
  run: ./run.sh --run build

- name: Test
  run: ./run.sh --run test
  env:
    CI: "true"
    RUN_CACHE_PROFILES: "0"
```

### Cron example

```bash
# Run the backup task every day at 02:00
0 2 * * * cd /srv/app && /usr/local/bin/run --run backup >> /var/log/app-backup.log 2>&1
```

Use absolute paths in cron; the runner's profile search starts at the current
directory.

---

## Custom Scripts & Automation

### Inspect tasks from scripts

```bash
run --list
run --list-profiles=json
```

Parse `--list` output by task number or name. For stable automation prefer
exact task names, not numbers, because the numbering changes when tasks are
added.

### Use the runner as a dispatcher

```bash
#!/bin/bash
set -euo pipefail

case "${1:-}" in
    deploy)  run --run deploy ;;
    test)    run --run test ;;
    *)       run --list; exit 1 ;;
esac
```

### Combine profiles and tasks

```bash
run develop --run build
run prod --run deploy
```

The profile is loaded first, then the task query is resolved in that profile.

### Aliases in scripts

Aliases in `~/.run_aliases` are expanded for the profile/task argument. They
are a convenience for interactive use; scripts should use the real profile or
task name.

### Editor integration

```bash
run --edit             # config editor for the active config
run --validate dev     # check before committing
```

The editor menu can also open a file browser and create a new file. The file
browser offers `.tasks`, `.env`, `README.md`, `package.json` and
`docker-compose.yml` first.

---

## See Also

- [CLI_REFERENCE.md](CLI_REFERENCE.md) — flags, task format, annotations
- [KEYBOARD_SHORTCUTS.md](KEYBOARD_SHORTCUTS.md) — every key and submenu
- [ARCHITECTURE.md](ARCHITECTURE.md) — internals and helper index
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — common failures
