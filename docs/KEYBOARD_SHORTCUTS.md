chmal # Keyboard Shortcuts Cheat Sheet

Quick reference for all keyboard shortcuts in the interactive menu.

---

## Navigation

| Shortcut    | Action               | Example                       |
| ----------- | -------------------- | ----------------------------- |
| `↑`         | Move up in menu      | Navigate to previous task     |
| `↓`         | Move down in menu    | Navigate to next task         |
| `Page Up`   | Jump 10 tasks up     | Fast navigation in long lists |
| `Page Down` | Jump 10 tasks down   | Fast navigation in long lists |
| `Home`      | Go to top of menu    | Jump to first task            |
| `End`       | Go to bottom of menu | Jump to last task             |

---

## Quick Selection

| Shortcut | Action                            |
| -------- | --------------------------------- |
| `1-9`    | Jump directly to task #1-9        |
| `A-Z`    | Jump to task starting with letter |
| `/`      | Open search/filter mode           |

### Examples

```bash
# In menu:
1               # Jump to task #1 (if exists)
5               # Jump to task #5
9               # Jump to task #9

b               # Jump to first task starting with 'B'
d               # Jump to first task starting with 'D'

/build          # Search for "build" tasks
/deploy         # Filter to deployment tasks
/test           # Show test-related tasks
```

---

## Search & Filter

### Activate Search

| Shortcut | Action               |
| -------- | -------------------- |
| `/`      | Enter search mode    |
| `Ctrl+F` | Find (alias for `/`) |

### In Search Mode

| Shortcut    | Action                       |
| ----------- | ---------------------------- |
| Type        | Filter tasks by name         |
| `Enter`     | Execute first filtered task  |
| `Esc`       | Clear search, back to menu   |
| `Backspace` | Delete character from search |
| `Ctrl+U`    | Clear entire search          |
| `↑` / `↓`   | Select from filtered results |

### Examples

```bash
# Press: /
# Type: test
# Result: Menu shows only tasks containing "test"
#         (Test Unit, Test E2E, Test Coverage, etc.)

# Press: Enter
# Result: Executes first result (usually "Test Unit")

# Press: Ctrl+U to clear and try again
# Type: deploy
# Result: Shows deployment-related tasks
```

---

## Execution

| Shortcut | Action                                           |
| -------- | ------------------------------------------------ |
| `Enter`  | Execute selected task                            |
| `Space`  | Alternative execution method (context-dependent) |
| `Ctrl+X` | Execute with confirmation                        |

---

## Menu Control

| Shortcut | Action                  |
| -------- | ----------------------- |
| `q`      | Quit / Exit menu        |
| `Ctrl+C` | Force quit              |
| `Ctrl+L` | Clear display / Refresh |
| `Ctrl+R` | Reload profiles         |

---

## Information & Help

| Shortcut | Action                   |
| -------- | ------------------------ |
| `?`      | Show help panel          |
| `h`      | Show recent task history |
| `i`      | Info about selected task |
| `Ctrl+H` | Help (extended)          |

### Examples

```bash
# In menu, press ?
# Shows: Navigation help, available shortcuts, tips

# Press h
# Shows: Last 10 executed tasks, timestamps
# Useful for quick re-running previous tasks

# Select a task, press i
# Shows: Full task details, description, dependencies
```

---

## Settings & Preferences

| Shortcut | Action                         |
| -------- | ------------------------------ |
| `s`      | Open Settings menu             |
| `t`      | Change theme (if in settings)  |
| `c`      | Toggle colors (if in settings) |
| `Ctrl+,` | Open settings (alias)          |

### In Settings Menu

```bash
# After pressing 's':

↑ / ↓       Navigate settings options
↔ / Space   Toggle option (on/off)
c           Toggle color theme
t           Cycle through themes (CYBER, DARK, LIGHT, MONO)
Enter       Apply and close settings
q / Esc     Close without saving
```

---

## Advanced Operations

| Shortcut | Action                           |
| -------- | -------------------------------- |
| `Ctrl+D` | Duplicate last execution         |
| `Ctrl+S` | Save configuration               |
| `Ctrl+P` | Print current task (debug)       |
| `Ctrl+E` | Edit current task (if supported) |

---

## Profile Switching

| Shortcut | Action                  |
| -------- | ----------------------- |
| `p`      | Show available profiles |
| `Ctrl+P` | Switch profile menu     |
| `1-9`    | Select profile #1-9     |

### Examples

```bash
# In main menu, press p
# Shows: List of available profiles
#        .tasks (current)
#        .tasks.dev
#        .tasks.prod
#        .tasks.test

# Press 1, 2, 3...
# Switches to that profile's tasks
```

---

## Context-Dependent Shortcuts

### In Task Details View (after selecting task)

| Shortcut | Action            |
| -------- | ----------------- |
| `e`      | Show full command |
| `d`      | Show dependencies |
| `r`      | Run task          |
| `Esc`    | Back to menu      |

---

## Function Keys (if supported)

| Key  | Action         |
| ---- | -------------- |
| `F1` | Help           |
| `F2` | Settings       |
| `F3` | Search         |
| `F4` | History        |
| `F5` | Refresh/Reload |

---

## Vim Mode Keybindings (Optional)

If vi/vim mode enabled in shell:

| Shortcut | Action                  |
| -------- | ----------------------- |
| `j`      | Move down               |
| `k`      | Move up                 |
| `g`      | Go to top               |
| `G`      | Go to bottom            |
| `/`      | Search (same as normal) |
| `n`      | Next search result      |
| `N`      | Previous search result  |

---

## Emacs Mode Keybindings (Optional)

If emacs mode enabled:

| Shortcut | Action          |
| -------- | --------------- |
| `Ctrl+N` | Move down       |
| `Ctrl+P` | Move up         |
| `Ctrl+A` | Go to start     |
| `Ctrl+E` | Go to end       |
| `Ctrl+S` | Search forward  |
| `Ctrl+R` | Search backward |

---

## Practical Workflow Examples

### Scenario 1: Run "Deploy" Task

```
Menu shown:
  1. Build
  2. Test
  3. Deploy ← target
  4. Rollback

Shortcuts:
  3           # Jump to task #3 (Deploy)
  Enter       # Execute it
```

### Scenario 2: Find "Setup" Task in Long List

```
Menu has 50+ tasks. Find "Setup":

/             # Enter search
setup         # Type "setup"
Enter         # Execute first result
```

### Scenario 3: Run Recent Task Again

```
h             # Show history
↓ ↓           # Select previous task
Enter         # Re-execute
```

### Scenario 4: Check Task Before Running

```
↑ / ↓         # Navigate to task
i             # Show details/info
e             # Show full command
r             # Run when ready (or Enter)
```

### Scenario 5: Switch Profiles

```
p             # Show profiles
2             # Select profile #2 (.tasks.prod)
↑ / ↓         # Navigate tasks in new profile
Enter         # Execute
```

---

## Common Mistakes & Solutions

### Problem: Nothing happens after pressing key

**Solution:** Some shortcuts require Enter after:

```bash
1 Enter       # Jump to task 1 AND execute (if only digit needed)
/ text Enter  # Search AND execute first result
```

### Problem: Search doesn't find task

**Solution:** Search is case-insensitive, checks task name:

```bash
/build        # Finds: "build", "Build", "BUILD", "Rebuild"
/test         # Finds: "test", "Test Unit", "Integration Test"
```

### Problem: Settings won't apply

**Solution:** Some changes require reload:

```bash
s             # Open settings
t             # Change theme
Enter         # Apply (may need refresh)
Ctrl+R        # Reload if changes not visible
```

---

## Pro Tips

### Tip 1: Use Number Shortcuts

```bash
# Instead of navigating with arrows:
↓ ↓ ↓ ↓ ↓     # 5 key presses

# Just:
5 Enter       # 2 key presses (60% faster!)
```

### Tip 2: Search + Execute in One Go

```bash
/              # Open search
deploy         # Type what you're looking for
Enter          # Execute first result
# Faster than navigating manually
```

### Tip 3: History for Speed

```bash
h              # Show recent tasks
↓              # Select previous task
Enter          # Re-run
# Perfect for repeated tasks (deploy, build, test)
```

### Tip 4: Info Before Execute

```bash
↑ / ↓          # Navigate to task
i              # Check details/dependencies
e              # See full command
r or Enter     # Execute when confident
```

### Tip 5: Quick Theme Change

```bash
s              # Settings
t              # Cycle theme
Enter          # Apply
# Switch CYBER → DARK → LIGHT → MONO on the fly
```

---

## Accessibility

### For Slow Typers

```bash
/              # Search (one char at a time)
buil           # Type slowly, filter updates
Enter          # Execute when ready
# No rush - filter updates as you type
```

### For One-Handed Use

```bash
Numbers (1-9)  # Single hand navigation
/              # Single hand search
Enter          # Execute
# Can be done with single hand on keyboard
```

### Screen Readers

If using screen reader with shell:

```bash
?              # Detailed help text
h              # History with descriptions
i              # Full info about tasks
# Provides context for screen readers
```

---

## Troubleshooting Shortcuts

If shortcuts don't work:

1. **Check TERM type:**

   ```bash
   echo $TERM
   # Should be: xterm, xterm-256color, linux, etc.
   ```

2. **Enable keyboard input:**

   ```bash
   stty -echo    # Should echo input
   ```

3. **Check if in interactive mode:**
   ```bash
   run           # Interactive ✅ (shortcuts work)
   run build     # Direct execution ❌ (no menu)
   ```

---

## Reference Card (Printable)

```
NAVIGATION         SELECTION          CONTROL
↑ ↓ Up/Down       1-9 Jump to task    Enter Execute
PgUp/Down Big      / Search            q Quit
Home/End Edges     h History           ? Help
                   s Settings          Ctrl+C Force quit

USEFUL
i Info       Ctrl+R Reload
e Execute    Ctrl+L Clear
p Profiles   Ctrl+S Save
```

---

## See Also

- [CLI_REFERENCE.md](./CLI_REFERENCE.md) - Command-line flags
- [QUICK_START.md](./QUICK_START.md) - Getting started
- [ADVANCED_USAGE.md](./ADVANCED_USAGE.md) - Advanced patterns
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) - Debug help
