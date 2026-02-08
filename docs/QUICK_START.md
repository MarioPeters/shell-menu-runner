# ⚡ Quick Start Guide (5 Minutes)

Get up and running with Shell Menu Runner in less than 5 minutes.

## Step 1: Install (30 seconds)

**Option A: One-liner (Recommended)**

```bash
bash <(curl -s https://raw.githubusercontent.com/yourusername/shell-menu-runner/main/install.sh)
# or local installation
cd /path/to/shell-menu-runner && bash install.sh
```

**Option B: Manual**

```bash
# Copy run.sh to PATH
sudo cp run.sh /usr/local/bin/run
chmod +x /usr/local/bin/run
```

✅ Test it works:

```bash
run --help
```

---

## Step 2: Create Your First Task File (1 minute)

Create a `.tasks` file in your project:

```bash
cd ~/my-project
cat > .tasks << 'EOF'
# My Project Tasks
0|Build|npm run build|Build the project
0|Test|npm test|Run tests
0|Deploy|npm run deploy|Deploy to production
EOF
```

**Format explanation:**

```
LEVEL | NAME | COMMAND | DESCRIPTION
  0   | Build| npm ... | What it does
```

---

## Step 3: Launch & Navigate (2 minutes)

Start the menu:

```bash
run
```

### Basic Navigation

| Key              | Action                         |
| ---------------- | ------------------------------ |
| **↑ ↓**          | Move up/down (_or_ `j`/`k`)    |
| **← →**          | Move left/right (_or_ `h`/`l`) |
| **Enter**        | Execute selected task          |
| **Space**        | Mark multiple tasks            |
| **/**, then type | Filter by name                 |
| **g**            | Switch global/local mode       |
| **p**            | Switch profiles                |
| **s**            | Settings (theme, language)     |
| **?**            | Help panel                     |
| **q**            | Quit                           |

### First Commands to Try

```bash
# Run task #1 without menu
run 1

# List all profiles
run --list-profiles

# Validate your .tasks file
run --validate
```

---

## Step 4: Next Steps (1 minute)

### Add Profiles

Create a profile for different contexts:

```bash
# Create .tasks.dev for development tasks
cat > .tasks.dev << 'EOF'
0|Dev Server|npm run dev|Start dev server
0|Watch Tests|npm test -- --watch|Watch mode tests
EOF

# Switch to profile
run dev
```

### Use Environment Variables

```bash
# Your .tasks file can use <<NAME>> for prompts:
0|Deploy|deploy.sh <<ENV>>|Deploy to [STAGING|PROD]

# At runtime, you'll be prompted: "Deploy to [STAGING|PROD]"
```

### Enable Parallel Dependencies

For faster task execution:

```bash
# Temporary (this session only)
export RUN_PARALLEL_DEPS=1
run

# Permanent (add to ~/.bashrc or ~/.zshrc)
echo 'export RUN_PARALLEL_DEPS=1' >> ~/.bashrc
```

---

## Keyboard Cheat Sheet

```
EXECUTION          NAVIGATION           SPECIAL
─────────          ──────────           ───────
[Enter] Execute    [j/k] Up/Down       [/] Filter
[1-9]  Quick-run   [h/l] Left/Right    [g] Global/Local
[Space] Multi      [↑ ↓ ← →] Arrows    [p] Profiles
[*] Favorite       [n/p] Pages         [?] Help
[R] Recents        [Esc] Back          [q] Quit

SETTINGS
────────
[s] Settings (theme, language)
[e] Edit current .tasks file
[f] File browser
[#] Filter by tags
[!] Show history
```

---

## Real-World Examples

### Node.js Project

```bash
cat > .tasks << 'EOF'
0|Install|npm install|Install dependencies
0|Dev|npm run dev|Start dev server
0|Test|npm test|Run unit tests
0|Build|npm run build|Build for production
0|Deploy|npm run build && npm run deploy|Full deploy
EOF
```

### Docker Project

```bash
cat > .tasks << 'EOF'
0|Build|docker build -t myapp .|Build Docker image
0|Run|docker run -it myapp|Start container
0|Logs|docker logs -f myapp|Show container logs
0|Stop|docker stop myapp|Stop container
EOF
```

### Database Migrations

```bash
cat > .tasks << 'EOF'
0|Migrate|npm run migrate|Run pending migrations
0|Undo|npm run migrate:undo|Undo last migration
0|Seed|npm run seed|Seed database with test data
0|Reset|npm run migrate:reset|Reset DB (dev only!)
EOF
```

---

## Troubleshooting

### "run: command not found"

```bash
# Check if it's in PATH
which run

# If not, verify installation succeeded
/usr/local/bin/run --help

# Add to PATH if needed
export PATH="/usr/local/bin:$PATH"
```

### "No tasks found"

```bash
# Check if .tasks file exists
ls -la .tasks

# Check file format (should be LEVEL|NAME|CMD|DESC)
cat .tasks

# Validate syntax
run --validate
```

### "Terminal looks weird" (colors/display)

```bash
# Set your terminal correctly
export TERM=xterm-256color

# Or disable colors via settings
run  # press 's' for settings, choose MONO theme
```

---

## What's Next?

1. **Read the full README** for advanced features
2. **Explore profiles** - `run --list-profiles`
3. **Add profiles** - `run --init-profile myname`
4. **Enable performance** - `export RUN_PARALLEL_DEPS=1`
5. **Join the community** - GitHub discussions & issues

---

## Common Tasks by Category

### Data & Infrastructure

```bash
run docker       # Docker management
run k8s          # Kubernetes tasks
run db           # Database operations
run server       # System administration
```

### Development

```bash
run test         # Testing & coverage
run lint         # Code quality
run build        # Build & compile
```

### CI/CD & Deployment

```bash
run ci           # CI/CD pipelines
run deploy       # Deployment tasks
run aws          # AWS cloud operations
```

---

## Pro Tips 🎯

✅ **Use hotkeys for speed**

```bash
# Press 1-9 to run tasks without menu
run && press 1  # Runs first task
```

✅ **Organize with sub-menus**

```bash
# LEVEL > 0 creates sub-menus
1|Database|SUB|Database operations
2|Migrate|./migrate.sh|Run migrations
2|Seed|./seed.sh|Seed test data
```

✅ **Add confirmation for dangerous tasks**

```bash
# Description starting with [!] requires confirmation
0|Reset DB|rm -rf db/|[!] WARNING: Cannot undo
```

✅ **Mark favorites for quick access**

```bash
# In menu: press [*] on any task to favorite
# Then press [r] to open favorites menu
```

---

**Happy task running! 🚀**

For questions → Check README.md or run `run --help`
