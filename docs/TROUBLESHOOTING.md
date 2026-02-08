# 🔧 Troubleshooting Guide

Solutions for common problems and how to diagnose issues.

---

## Installation Issues

### Problem: "bash: run: command not found"

**Diagnosis:**

```bash
which run              # Should show /usr/local/bin/run
ls -la /usr/local/bin/run   # Check file exists & executable
```

**Solutions:**

1. **Verify installation succeeded**

   ```bash
   bash ./install.sh   # Run installer again
   echo $?             # Should be 0 (success)
   ```

2. **Check PATH**

   ```bash
   echo $PATH
   # If /usr/local/bin missing, add it:
   export PATH="/usr/local/bin:$PATH"
   ```

3. **Manual install**

   ```bash
   sudo cp run.sh /usr/local/bin/run
   sudo chmod +x /usr/local/bin/run
   run --help
   ```

4. **Using without PATH**
   ```bash
   ./run.sh              # Run from project directory
   ```

---

### Problem: "Permission denied"

**Solution:**

```bash
# Make run.sh executable
chmod +x run.sh

# Or make installed version executable
chmod +x /usr/local/bin/run
```

---

### Problem: Installation fails with "curl: (22) HTTP error"

**Diagnosis:**

```bash
# Check network
ping github.com

# Try manual download
curl -o run.sh https://raw.githubusercontent.com/.../run.sh
```

**Solutions:**

1. **Check network connection**

   ```bash
   curl -I https://github.com   # Should return HTTP 200
   ```

2. **Use local installation**

   ```bash
   git clone https://github.com/yourusername/shell-menu-runner
   cd shell-menu-runner
   bash install.sh
   ```

3. **Behind firewall?**
   ```bash
   # Try with proxy
   curl --proxy [protocol://]proxyhost[:port] ...
   ```

---

## Configuration Issues

### Problem: "No tasks found" or empty menu

**Diagnosis:**

```bash
# Check if .tasks file exists
ls -la .tasks           # Should exist in current or parent dir

# Check file format
cat .tasks              # Should have LEVEL|NAME|CMD|DESC format

# Validate syntax
run --validate
```

**Solutions:**

1. **Create .tasks file manually**

   ```bash
   cat > .tasks << 'EOF'
   0|Test|echo "Hello"|Test task
   EOF
   ```

2. **Copy from template**

   ```bash
   run --init-profile test   # Creates template
   ```

3. **Check file permissions**

   ```bash
   chmod 644 .tasks       # Make readable
   ```

4. **Watch for special characters**

   ```bash
   # Bad: Contains pipes or special chars in unescaped values
   0|Task|echo "text|with|pipes"|Desc

   # Good: Quote strings with pipes
   0|Task|echo "text with pipes"|Desc
   ```

---

### Problem: Profile not found

**Diagnosis:**

```bash
# List available profiles
run --list-profiles

# Check if profile file exists
ls ~/.tasks.profilename      # Global profile
ls ~/.tasks.profilename      # Local profile
```

**Solutions:**

1. **Create missing profile**

   ```bash
   run --init-profile myprofile
   ```

2. **Use correct profile name**

   ```bash
   run git      # Loads .tasks.git (not .tasks_git, not .tasksgit)
   ```

3. **Check file location**

   ```bash
   # Local profile (current directory or parent)
   find . -name ".tasks.*"

   # Global profile (home directory)
   ls ~/.tasks.*
   ```

---

## Display Issues

### Problem: Colors not showing correctly

**Diagnosis:**

```bash
echo $TERM              # Check terminal type
which tput             # Check if color support available
```

**Solutions:**

1. **Set correct TERM**

   ```bash
   export TERM=xterm-256color    # For modern terminals
   export TERM=xterm             # For older systems
   ```

2. **Disable colors (use MONO theme)**

   ```bash
   run
   # Press 's' for settings
   # Select MONO theme
   ```

3. **Add to shell config**
   ```bash
   # ~/.bashrc or ~/.zshrc
   export TERM=xterm-256color
   ```

---

### Problem: Text alignment/display broken

**Diagnosis:**

```bash
echo "Test line" | cat       # Check if formatting works
stty size                    # Check terminal size
```

**Solutions:**

1. **Resize terminal**

   ```bash
   # Try making window larger or smaller
   # Minimum recommended: 80x24
   stty size    # Shows current size
   ```

2. **Disable animation**

   ```bash
   export RUN_DISABLE_ANIMATION=1
   run
   ```

3. **Use different theme**
   ```bash
   run
   # Press 's' → Select DARK or LIGHT theme
   ```

---

### Problem: SSH/Remote terminal looks broken

**Solution:**

```bash
# Force non-interactive mode
run --help | head -10

# Or disable terminal override
export TERM=xterm
run
```

---

## Performance Issues

### Problem: Menu is slow with many tasks

**Diagnosis:**

```bash
time run            # Measure load time
wc -l .tasks        # Check task count
```

**Solutions:**

1. **Enable caching**

   ```bash
   export RUN_CACHE_PROFILES=1
   run
   ```

2. **Enable parallel dep execution**

   ```bash
   export RUN_PARALLEL_DEPS=1
   run
   ```

3. **Split into profiles**

   ```bash
   # Instead of 100 tasks in .tasks
   # Create .tasks.dev, .tasks.deploy, .tasks.test
   run dev      # Loads only development tasks
   ```

4. **Reduce filter search scope**
   ```bash
   # Use specific hotkeys instead of searching
   run && press 1  # Faster than menu + filter
   ```

---

### Problem: Task execution is slow

**Diagnosis:**

```bash
# Check task execution time (shown after task completes)
time your-task           # Manual timing

# Check if dependencies are blocking
cat .tasks | grep depends
```

**Solutions:**

1. **Run dependencies in parallel**

   ```bash
   export RUN_PARALLEL_DEPS=1
   run
   ```

2. **Optimize task command**

   ```bash
   # Before: Slow (spawns many processes)
   for i in {1..10}; do curl ...; done

   # After: Fast (batched)
   curl ... | parallel  # Use parallel for many tasks
   ```

3. **Remove unnecessary dependencies**
   ```bash
   # Identify unused dependencies
   run --validate
   ```

---

## Task Execution Issues

### Problem: Task returns "command not found"

**Diagnosis:**

```bash
# Check command in terminal first
which your-command
your-command --help

# Check if it's in task format correctly
cat .tasks | grep your-command
```

**Solutions:**

1. **Use full path**

   ```bash
   # Bad: npm build
   # Good: /usr/local/bin/npm build  (or use which npm)
   which npm  # Find full path
   ```

2. **Environment variables not loaded**

   ```bash
   # Create .env file in project
   cat > .env << 'EOF'
   NODE_ENV=production
   EOF

   # .env is auto-loaded before task execution
   ```

3. **Shell not found**

   ```bash
   # Make sure bash interpreter exists
   which bash

   # Try different shell
   #!/bin/sh (more portable)
   ```

---

### Problem: Task runs but fails with wrong args

**Diagnosis:**

```bash
# Test command manually first
echo "npm run deploy staging" | bash

# Check task format
cat .tasks | grep -A1 deploy
```

**Solutions:**

1. **Quote arguments properly**

   ```bash
   # Bad (splits on spaces):
   0|Deploy|npm run deploy myenv|Deploy

   # Good (preserved):
   0|Deploy|npm run deploy -- myenv|Deploy
   ```

2. **Use placeholders for user input**

   ```bash
   0|Deploy|npm run deploy <<ENV>>|Deploy (pick env)

   # When running, you'll be prompted for ENV
   ```

3. **Escape special characters**

   ```bash
   # Bad:
   0|Task|echo $HOME|Echo home

   # Good:
   0|Task|echo \$HOME|Echo home (escape $)
   # Or:
   0|Task|'echo "$HOME"'|Echo home (quotes)
   ```

---

### Problem: Task times out

**Diagnosis:**

```bash
# Check timeout setting
grep TIMEOUT ~/.runrc
# Default: 300 seconds (5 min)

# Test command duration
time your-command
```

**Solutions:**

1. **Increase timeout**

   ```bash
   # In .runrc
   TIMEOUT=600    # 10 minutes
   ```

2. **Run task outside menu**

   ```bash
   # Direct execution (no timeout)
   /path/to/command
   ```

3. **Optimize task speed**
   ```bash
   # Identify slow steps
   time command_step_1
   time command_step_2
   # Fix slowest step
   ```

---

## Git & Version Issues

### Problem: Update fails

**Diagnosis:**

```bash
run --version          # Check current version
run --update           # Try update manually
```

**Solutions:**

1. **Manual update**

   ```bash
   # Download latest
   curl -o run.new https://raw.githubusercontent.com/.../run.sh

   # Backup current
   cp /usr/local/bin/run /usr/local/bin/run.bak

   # Install new
   mv run.new /usr/local/bin/run
   chmod +x /usr/local/bin/run
   ```

2. **Via git (if using repo)**
   ```bash
   cd ~/shell-menu-runner
   git pull origin main
   bash install.sh
   ```

---

## Debug Mode

### Enable debug output

```bash
# Run with debug flag
run --debug

# Verbose environment check
bash -x run.sh 2>&1 | head -50
```

### Generate debug report

```bash
# Create diagnostic file
cat > run_debug.txt << 'EOF'
System: $(uname -a)
Bash version: $(bash --version | head -1)
PATH: $PATH
TERM: $TERM
run location: $(which run)
run version: $(run --version)
.tasks files: $(find . -name ".tasks*" 2>/dev/null)
EOF

# Attach to bug report
cat run_debug.txt
```

---

## Getting Help

### If problem persists:

1. **Check README.md** for feature descriptions
2. **Run `run --help`** for available commands
3. **Check help panel** with `run` then press `?`
4. **Enable debug mode** → `run --debug`
5. **Post to GitHub Issues** with:
   - System info (OS, bash version)
   - Steps to reproduce
   - Error message / debug output
   - Your `.tasks` file (if not sensitive)

### Useful diagnostic commands:

```bash
bash --version
echo $SHELL
uname -a
run --version
run --validate
run --list-profiles
```

---

**Still stuck?** → Refer to [QUICK_START.md](QUICK_START.md) or [README.md](../README.md)
