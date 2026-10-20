# 📚 Documentation

Complete guide to shell-menu-runner — from first run to advanced optimization.

---

## 🚀 Quick Navigator

**First time?** Start here:

    ⌨️ **[KEYBOARD_SHORTCUTS.md](./KEYBOARD_SHORTCUTS.md)** — All hotkeys in 2 min

**Ready to dive deeper?**

**Quick References?**

- 📋 **[CLI_REFERENCE.md](./CLI_REFERENCE.md)** — All CLI flags & options
- ⌨️ **[KEYBOARD_SHORTCUTS.md](./KEYBOARD_SHORTCUTS.md)** — Keyboard hotkeys cheat

**Need examples?**

- 💡 **[examples/](./examples/)** — Real-world task file templates

---

## 📋 Documentation Guide

### [🟢 QUICK_START.md](./QUICK_START.md)

**5-minute beginner guide**

Perfect for:

Sections:

---

### [🔧 TROUBLESHOOTING.md](./TROUBLESHOOTING.md)

**Solutions for common problems**

Perfect for:

- Installation issues
- Configuration problems
- Misaligned boxes with CJK/emoji names
- Tasks that hang or cannot be stopped with Ctrl+C
- Remote/SSH sessions without a TTY
- Debug techniques

Sections:
**Power-user recipes & optimization patterns**

Perfect for:

- Organizing large projects
- Setting up complex workflows
- Parallel task execution
- Multi-profile coordination
- Performance optimization
- CI/CD integration

Sections:

- Task organization patterns (hierarchical, environment-based, service-based)
- Advanced dependency resolution
- Multi-profile workflows
- Progress monitoring
- Environment & secrets management
- Performance optimization
- CI/CD integration
- Custom scripts & automation

**Real-world examples:**

- Microservices deployment
- DevOps workflows
- Frontend development

**Read time:** 20-30 minutes

---

### [📖 ARCHITECTURE.md](./ARCHITECTURE.md)

**Code structure & development guide**

Perfect for:

- Understanding the codebase
- Contributing to the project
- Adding new features
- Optimizing performance
- Debugging the core

Sections:

- Architecture overview
- File structure
- Core components (8 major)
- Execution flow diagram
- Feature deep dives (Progress Bar, Multi-Profile)
- Contributing guide
- Development workflow
- Testing checklist
- Performance considerations

**Code metrics:**

- 2850+ lines
- 95+ functions
- 30+ features
- 0 external dependencies

**Read time:** 30-45 minutes (reference document)

---

### [💡 examples/](./examples/)

**Real-world task file templates**

Perfect for:

- Copy-paste starting template
- Learning patterns
- Project-specific setup

**Available templates:**

1. **node-project.tasks** — React, Express, NestJS, Next.js
2. **python-project.tasks** — Django, Flask, FastAPI
3. **devops-k8s.tasks** — Kubernetes, container orchestration
4. **microservices-root.tasks** — Multi-service orchestration
5. **microservice-service.tasks** — Individual service tasks
6. **web-project.tasks** — Full-stack (frontend + backend)

**How to use:**

```bash
# Copy template for your project type
cp docs/examples/node-project.tasks .tasks

# Customize to your project
# Edit paths, commands as needed

# Start using
run
```

**Read time:** 2-5 minutes per template

---

## 📊 Documentation Map

```
Getting Started
    ↓
QUICK_START.md (5 min)
    ↓
├─→ Works? Great! → Check examples/
│
└─→ Issues? → TROUBLESHOOTING.md
    ↓
Ready to optimize?
    ↓
ADVANCED_USAGE.md (20 min)
    ↓
Want to contribute?
    ↓
ARCHITECTURE.md (30 min)
```

---

## 🎯 By Use Case

### "I just installed, now what?"

1. Read [QUICK_START.md](./QUICK_START.md) (5 min)
2. Check [examples/](./examples/) for your project type
3. Start using: `run`

### "I have an error"

1. Check [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
2. Find your error type
3. Follow the solution

### "Want to power up?"

1. Read [ADVANCED_USAGE.md](./ADVANCED_USAGE.md)
2. Try patterns in your project
3. Use multi-profile execution

### "Want to contribute?"

1. Read [ARCHITECTURE.md](./ARCHITECTURE.md)
2. Understand the codebase
3. Follow contributing guide
4. Submit PR

---

## 🔍 Search by Topic

### Installation & Setup

- [QUICK_START - Installation](./QUICK_START.md#2-installation)
- [TROUBLESHOOTING - Installation Issues](./TROUBLESHOOTING.md#installation-issues)

### Command Line & Flags

- [CLI_REFERENCE - All flags](./CLI_REFERENCE.md)
- [QUICK_START - First run](./QUICK_START.md#1-installation)

### First Use

- [QUICK_START - First .tasks File](./QUICK_START.md#3-create-your-first-tasks-file)
- [examples/ - Copy a template](./examples/)

### Keyboard Shortcuts

- [QUICK_START - Navigation & Shortcuts](./QUICK_START.md#4-navigation--keyboard-shortcuts)
- [KEYBOARD_SHORTCUTS - Complete guide](./KEYBOARD_SHORTCUTS.md)
- [KEYBOARD_SHORTCUTS - Cheat sheet](./KEYBOARD_SHORTCUTS.md#keyboard-shortcuts-cheat-sheet)

### Task Creation

- [ADVANCED_USAGE - Task Patterns](./ADVANCED_USAGE.md#task-organization-patterns)
- [examples/ - Real-world samples](./examples/)

### Analysis & Recommendations

- [run --analyze feature](./CLI_REFERENCE.md#execution-modes) - Project suggestions
- [ADVANCED_USAGE - Best Practices](./ADVANCED_USAGE.md#best-practices)

### Dependencies

- [ADVANCED_USAGE - Dependency Resolution](./ADVANCED_USAGE.md#advanced-task-dependencies)
- [ARCHITECTURE - Dependency System](./ARCHITECTURE.md#4-dependency-resolution)

### Parallel Execution

- [ADVANCED_USAGE - Parallel Optimization](./ADVANCED_USAGE.md#optimization-2-parallel-task-execution)
- [ADVANCED_USAGE - Multi-Profile Parallel](./ADVANCED_USAGE.md#pattern-2-parallel-multi-profile)

### Profiles & Organization

- [ADVANCED_USAGE - Organizational Patterns](./ADVANCED_USAGE.md#task-organization-patterns)
- [examples/ - Multi-profile setup](./examples/README.md)

### CI/CD Integration

- [ADVANCED_USAGE - CI/CD Integration](./ADVANCED_USAGE.md#cicd-integration)
- [ARCHITECTURE &- Development Workflow](./ARCHITECTURE.md#development-workflow)

### Debugging

- [TROUBLESHOOTING - Debug Mode](./TROUBLESHOOTING.md#debug-mode)
- [ARCHITECTURE - Debugging Tips](./ARCHITECTURE.md#debugging-tips)

---

## 💬 One-Minute Overview

**What is shell-menu-runner?**
Interactive task automation framework for managing shell commands (npm, docker, kubectl, etc.) in a single menu interface.

**Key features:**

- ✅ Interactive task menu with keyboard navigation
- ✅ Task dependencies (auto chain)
- ✅ Multiple profiles (.tasks files)
- ✅ Multi-profile execution (`--across`)
- ✅ Progress tracking with visual bar
- ✅ Theme customization (CYBER, DARK, LIGHT, MONO)
- ✅ Caching for speed
- ✅ Zero external dependencies

**Typical workflow:**

```
1. Run: run
2. See task menu
3. Press number or ↑↓ to select
4. Press Enter to execute
5. See output + timing
6. Repeat
```

---

## 🎓 Learning Path

### Beginner (Day 1)

- [ ] Read [QUICK_START.md](./QUICK_START.md)
- [ ] Create `.tasks` file with 3-5 tasks
- [ ] Run `run` and execute first task
- [ ] Try keyboard shortcuts (arrow keys, numbers, filter)

### Intermediate (Week 1)

- [ ] Read [ADVANCED_USAGE.md](./ADVANCED_USAGE.md) - Task Organization
- [ ] Split into `.tasks.dev` + `.tasks.prod`
- [ ] Try dependencies: `depends:0,1`
- [ ] Copy/customize template from [examples/](./examples/)

### Advanced (Week 2+)

- [ ] Read rest of [ADVANCED_USAGE.md](./ADVANCED_USAGE.md)
- [ ] Set up multi-profile workflows
- [ ] Enable parallel execution
- [ ] Integrate with CI/CD

### Contributor (Ongoing)

- [ ] Read [ARCHITECTURE.md](./ARCHITECTURE.md)
- [ ] Study run.sh core sections
- [ ] Fix a bug or add small feature
- [ ] Submit PR

---

## ❓ FAQ

**Q: Where do I put .tasks files?**
A: Project root (`.tasks`) or home directory (`~/.tasks`) or subdirectories (`.tasks.NAME`)

**Q: Can I use other shells?**
A: Uses bash, but scripts inside tasks can use any shell

**Q: How to run without menu?**
A: `run taskname` or `bash run.sh --task "name"`

**Q: Multiple projects?**
A: Each project gets its own `.tasks` file in its root

**Q: Import tasks from other projects?**
A: Copy relevant .tasks files or use profiles: `run --across proj1,proj2 task`

**For more:** Check [TROUBLESHOOTING.md - FAQ](./TROUBLESHOOTING.md#getting-help)

---

## 🔗 External Links

- [GitHub Repository](https://github.com/yourusername/shell-menu-runner)
- [Main README](../README.md)
- [Changelog](../CHANGELOG.md)
- [Contributing Guidelines](../CONTRIBUTING.md)

---

## 📈 Documentation Statistics

| Document                                         | Lines     | Content                | Read Time      |
| ------------------------------------------------ | --------- | ---------------------- | -------------- |
| [QUICK_START.md](./QUICK_START.md)               | 260+      | Beginner guide         | 5-10 min       |
| [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)       | 400+      | Problem solutions      | As needed      |
| [ADVANCED_USAGE.md](./ADVANCED_USAGE.md)         | 500+      | Power-user patterns    | 20-30 min      |
| [ARCHITECTURE.md](./ARCHITECTURE.md)             | 600+      | Code structure         | 30-45 min      |
| [examples/](./examples/)                         | 200+/file | Task templates         | 2-5 min each   |
| [CLI_REFERENCE.md](./CLI_REFERENCE.md)           | 250+      | CLI flags & options    | 3-5 min        |
| [KEYBOARD_SHORTCUTS.md](./KEYBOARD_SHORTCUTS.md) | 300+      | Keyboard hotkeys       | 5-10 min       |
| [examples/](./examples/)                         | 200+/file | Task templates         | 2-5 min each   |
| **Total**                                        | **2800+** | **Complete reference** | **90-120 min** |

---

## ✨ Highlights

### QUICK_START.md

```bash
# What you'll learn in 5 minutes
✓ Installation
✓ Create first task file
✓ Run your first task
✓ Use keyboard shortcuts
✓ Next steps
```

### TROUBLESHOOTING.md

```bash
# Covers issues like:
✓ "bash: run: command not found"
✓ "No tasks found"
✓ Slow menu performance
✓ Task execution errors
✓ Debug techniques
```

### ADVANCED_USAGE.md

```bash
# Real patterns for:
✓ Microservices deployment
✓ DevOps workflows
✓ Multi-profile coordination
✓ Performance optimization
✓ CI/CD integration
```

### ARCHITECTURE.md

```bash
# Deep dive into:
✓ Code structure (95+ functions)
✓ Core components
✓ Contributing guide
✓ Development workflow
✓ Testing checklist
```

### examples/

```bash
# Ready-to-use templates for:
✓ Node.js projects
✓ Python projects
✓ Kubernetes/DevOps
✓ Microservices
✓ Full-stack web apps
```

---

## 🚀 Next Steps

1. **First time?** → [QUICK_START.md](./QUICK_START.md)
2. **Hit a problem?** → [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
3. **Want more power?** → [ADVANCED_USAGE.md](./ADVANCED_USAGE.md)
4. **Want to contribute?** → [ARCHITECTURE.md](./ARCHITECTURE.md)
5. **Need a template?** → [examples/](./examples/)

---

**Happy automating!** 🎉

Last updated: 2024
