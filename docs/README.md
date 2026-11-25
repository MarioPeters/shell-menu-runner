# 📚 Documentation

Complete guide to shell-menu-runner — from first run to advanced automation.

---

## 🚀 Quick Navigator

**First time?** Start with [QUICK_START.md](QUICK_START.md) (5 minutes).

**Looking for a specific flag?** [CLI_REFERENCE.md](CLI_REFERENCE.md).

**Need a key?** [KEYBOARD_SHORTCUTS.md](KEYBOARD_SHORTCUTS.md).

**Something broken?** [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**Want a ready-made task file?** [examples/](examples/).

**Working on the code?** [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 📋 Documentation Guide

### [🟢 QUICK_START.md](QUICK_START.md)

Five-minute beginner guide:

- install the runner
- create a `.tasks` file
- run the first task
- navigate the menu
- next steps

### [📋 CLI_REFERENCE.md](CLI_REFERENCE.md)

Every command-line flag and the task-file syntax:

- `run`, `--list`, `--run`, `--dry-run`, `--across`
- profiles, overlays, validation
- `[depends: ...]`, `[timeout: ...]`, `[!]`, placeholders
- environment variables and `.env` handling
- menu shortcuts

### [⌨️ KEYBOARD_SHORTCUTS.md](KEYBOARD_SHORTCUTS.md)

Complete key reference:

- main menu navigation and execution
- search, tags, favorites, history
- profile menu, tag menu, settings, editor, file browser
- documented against the key handler in `src/13-ui.sh`

### [⚡ ADVANCED_USAGE.md](ADVANCED_USAGE.md)

Power-user recipes:

- profiles, overlays and submenus
- dependency chains and parallel dependencies
- multi-profile execution
- progress markers, timeouts and cancellation
- `.env`, `~/.run_vars` and task-local variables
- CI/CD and cron integration

### [🔧 TROUBLESHOOTING.md](TROUBLESHOOTING.md)

Solutions for common problems:

- installation and PATH issues
- "No tasks found" and configuration errors
- misaligned boxes with CJK/emoji
- tasks that hang or time out
- SSH sessions without a TTY
- debug mode and diagnostics

### [📖 ARCHITECTURE.md](ARCHITECTURE.md)

Code structure for contributors:

- module layout and build process
- startup and execution flow
- configuration and overlay semantics
- execution guarantees
- complete function index
- development workflow, performance notes and test checklist

### [💡 examples/](examples/)

Copy-paste task files:

1. `node-project.tasks` — React, Express, NestJS, Next.js
2. `python-project.tasks` — Django, Flask, FastAPI
3. `devops-k8s.tasks` — Kubernetes and container orchestration
4. `microservices-root.tasks` — multi-service orchestration
5. `microservice-service.tasks` — tasks for one service
6. `web-project.tasks` — full-stack frontend + backend

```bash
cp docs/examples/node-project.tasks .tasks
run
```

---

## 🎯 By Use Case

### "I just installed, now what?"

1. Read [QUICK_START.md](QUICK_START.md).
2. Copy a template from [examples/](examples/) or run `run --init`.
3. Start with `run`.

### "I have an error"

1. Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
2. Run `run --validate` to check the task file.
3. Run `DEBUG_MODE=1 run --list` for a trace.

### "I want more power"

1. Read [ADVANCED_USAGE.md](ADVANCED_USAGE.md).
2. Try profiles and overlays.
3. Use `--across` and `RUN_PARALLEL_MULTI=1` for multi-profile runs.
4. Add `[depends: ...]` and `[timeout: ...]` annotations.

### "I want to contribute"

1. Read [ARCHITECTURE.md](ARCHITECTURE.md).
2. Edit `src/`, never `run.sh`.
3. Add a regression test in `build-platform/tests/test-runner.sh`.
4. Run the full check (see below).

---

## 💬 One-Minute Overview

**What is shell-menu-runner?**

An interactive task menu for shell commands (npm, docker, kubectl, …) with
profiles, dependencies, history and a zero-dependency Bash implementation.

**Key features:**

- Interactive menu with keyboard and Vim navigation
- Task dependencies and per-task timeouts
- Profiles (`.tasks.<name>`) and additive overlays (`.local`, `.dev`)
- Multi-profile execution with `--across`
- Search, tags, favorites, history, logs
- Progress bars via `[progress: ...]` markers
- Themes and Unicode-safe layout
- Bash 3.2+, no runtime dependencies

**Typical workflow:**

```
1. run
2. Select a task with arrows/j/k or a number
3. Press Enter
4. Read the output and timing
5. Press any key to return to the menu
```

---

## 🎓 Learning Path

### Beginner (Day 1)

- [ ] Read [QUICK_START.md](QUICK_START.md)
- [ ] Create `.tasks` with 3–5 tasks
- [ ] Run `run` and execute a task
- [ ] Try arrows, `j`/`k`, `/`, `?`

### Intermediate (Week 1)

- [ ] Read [ADVANCED_USAGE.md](ADVANCED_USAGE.md)
- [ ] Split tasks into profiles or overlays
- [ ] Add `[depends: Name]`
- [ ] Copy and adapt a template from [examples/](examples/)

### Advanced (Week 2+)

- [ ] Use `--across` and `--run` in scripts
- [ ] Enable `RUN_PARALLEL_DEPS=1` / `RUN_PARALLEL_MULTI=1`
- [ ] Add progress markers and per-task timeouts
- [ ] Integrate with CI/CD

### Contributor

- [ ] Read [ARCHITECTURE.md](ARCHITECTURE.md)
- [ ] Follow the build and test workflow
- [ ] Add tests for behavior changes
- [ ] Submit a pull request

---

## ❓ FAQ

**Q: Where do I put `.tasks` files?**

A: In the project root (`.tasks`), in `~/.tasks` for global tasks, or as
`.tasks.<name>` for a profile. The runner searches the current directory and
its parents before falling back to `$HOME`.

**Q: Can I use another shell inside tasks?**

A: Yes. Tasks are executed by Bash, but the command can invoke any interpreter
(`python`, `node`, `zsh`, …).

**Q: How do I run without the menu?**

A: Use `run --run "Task Name"`, `run --run 3`, or `run --list` to see the
numbering. In a non-TTY session the menu is replaced by a numeric list.

**Q: How do I create a profile?**

A: `run --init-profile <name>` creates `.tasks.<name>` in the current
directory. `run <name>` loads it.

**Q: Are overlays merged or overriding?**

A: Additive. `.tasks.local` and `.tasks.dev` are appended to `.tasks`; duplicate
task names appear twice and dependency lookup uses the first match. Use unique
names.

**Q: How do I run a task across profiles?**

A: `run --across dev,staging,prod deploy` (sequential) or with
`RUN_PARALLEL_MULTI=1` in parallel.

**Q: How do I see all keys?**

A: Press `?` in the menu or read [KEYBOARD_SHORTCUTS.md](KEYBOARD_SHORTCUTS.md).

**Q: Is there a test for documentation drift?**

A: Yes: `bash build-platform/tests/test-docs.sh` checks documented helpers,
keys, flags, examples and installer templates against the implementation.

---

## 🛠 Documentation Maintenance

The documentation is part of the test suite:

```bash
bash build-platform/tests/test-docs.sh
```

The check verifies:

- every helper documented in `CLAUDE.md` / `ARCHITECTURE.md` exists
- every function in `src/` is mentioned in the AI/dev docs
- documented keys exist in the matching key handler
- documented CLI flags exist in the parser and `--help`
- no phantom keys or flags are documented
- declared line counts stay in sync
- all `docs/examples/*.tasks` and `install.sh` templates validate

When you change behavior, update the matching document in the same commit.

---

## 🔗 External Links

- [GitHub Repository](https://github.com/MarioPeters/shell-menu-runner)
- [Main README](../README.md)
- [Changelog](../CHANGELOG.md)
- [Contributing Guidelines](../CONTRIBUTING.md)
- [Build Platform](../BUILD_PLATFORM.md)

---

## 🚀 Next Steps

1. **First time?** → [QUICK_START.md](QUICK_START.md)
2. **Hit a problem?** → [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
3. **Want more power?** → [ADVANCED_USAGE.md](ADVANCED_USAGE.md)
4. **Want to contribute?** → [ARCHITECTURE.md](ARCHITECTURE.md)
5. **Need a template?** → [examples/](examples/)
