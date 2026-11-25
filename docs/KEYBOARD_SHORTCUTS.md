# Keyboard Shortcuts Cheat Sheet

Quick reference for all keyboard shortcuts in the interactive menu.

Every shortcut listed here is implemented in the key handler of
`src/13-ui.sh`. The test suite (`build-platform/tests/test-docs.sh`) verifies
that this document and the implementation stay in sync — a key that is
documented but not implemented (or the other way round) fails the build.

---

## Navigation

| Shortcut | Action                                             |
| -------- | -------------------------------------------------- |
| `↑`      | Move up in the menu                                |
| `↓`      | Move down in the menu                              |
| `←`      | Move one column to the left (multi-column menus)   |
| `→`      | Move one column to the right (multi-column menus)  |
| `k`      | Move up (Vim-style)                                |
| `j`      | Move down (Vim-style)                              |
| `h`      | Move one column to the left (Vim-style)            |
| `l`      | Move one column to the right (Vim-style)           |
| `Esc`    | Leave the current submenu — at the top level: quit |

The selection wraps around at the end of the list.

---

## Quick Selection

| Shortcut | Action                                                           |
| -------- | ---------------------------------------------------------------- |
| `1`–`9`  | Execute the task with that number **directly** (no confirmation) |
| `/`      | Open the search/filter mode                                      |
| `Enter`  | Execute the selected task (after the preview)                    |

> The numbers are **column-first**: the number shown at the top border of
> each menu box is the hotkey of that entry. Only entries 1–9 get a hotkey;
> with more than nine tasks the remaining ones are reached with the arrow
> keys or the search.

### Examples

```bash
# In the menu:
1               # Execute task #1
5               # Execute task #5

/build          # Show only tasks whose name or description contains "build"
/deploy         # Filter to deployment tasks
```

---

## Search & Filter

### Activate Search

| Shortcut | Action            |
| -------- | ----------------- |
| `/`      | Enter search mode |

### In Search Mode

| Shortcut    | Action                                   |
| ----------- | ---------------------------------------- |
| Type        | Filter the tasks by name and description |
| `Enter`     | Apply the filter and return to the menu  |
| `Esc`       | Cancel the search and return to the menu |
| `Backspace` | Delete the last character                |
| `↑` / `↓`   | Recall a previous search term            |

The search is a literal, case-insensitive substring match — special
characters such as `(` or `.` have no special meaning.

The active filter is shown in the header (`📎 Filter: …`). It stays active
until it is cleared with `Esc` in the search mode or the config is switched
(`g` / `p` — a filter always resets with a config change).

---

## Execution

| Shortcut | Action                                                                  |
| -------- | ----------------------------------------------------------------------- |
| `Enter`  | Execute the selected task (a preview is shown first)                    |
| `Space`  | Mark the selected task for multi-select (`Enter` runs all marked tasks) |
| `*`      | Toggle the selected task in the favorites                               |

A task whose description starts with `[!]` asks for a confirmation before it
is executed.

---

## Menu Control

| Shortcut | Action           |
| -------- | ---------------- |
| `q`      | Quit the menu    |
| `Ctrl+C` | Stop the running task; at the menu, abort the runner |

---

## Information & Help

| Shortcut | Action                                |
| -------- | ------------------------------------- |
| `?`      | Show the help panel                   |
| `!`      | Show the task history                 |
| `R`      | Show the recently executed tasks      |
| `L`      | Show the log files                    |
| `r`      | Show the favorite tasks               |
| `c`      | Copy the command of the selected task |

> **Two-digit selection:** the favorites (`r`), recent tasks (`R`) and tag
> (`#`) menus list up to 20 entries. With more than nine entries, type both
> digits (e.g. `12`) — the second digit is collected within 0.5 s. A single
> digit still selects the entry 1–9 immediately.

### Examples

```bash
# In the menu, press ?
# Shows: Navigation help and the list of the available shortcuts

# Press !
# Shows: The last 20 executed tasks with exit code and duration
#       (the history file itself keeps the last 100 entries)

# Press R
# Shows: The last 20 executed tasks — select one to run it again

# Press c
# Copies the command of the selected task to the clipboard
```

---

## Configuration & Files

| Shortcut | Action                                         |
| -------- | ---------------------------------------------- |
| `s`      | Open the settings menu                         |
| `e`      | Edit the config file (external editor)         |
| `f`      | Open the file browser                          |
| `a`      | Open the alias editor                          |
| `#`      | Filter by tag                                  |
| `g`      | Switch between the local and the global config |
| `p`      | Switch the profile                             |

### Settings Menu (`s`)

| Key         | Action                         |
| ----------- | ------------------------------ |
| `1`         | Change the theme               |
| `2`         | Change the language (EN / DE)  |
| `3`         | Change the column layout (1–4) |
| `4`         | Save the settings globally     |
| `5`         | Save the settings locally      |
| `0` / `Esc` | Back (without saving)          |

### Profile Menu (`p`)

| Key         | Action                                 |
| ----------- | -------------------------------------- |
| `1`–`9`     | Select the profile on the current page |
| `p`         | Previous page                          |
| `n`         | Next page                              |
| `/`         | Filter the profile list                |
| `0`         | Cancel                                 |
| `q` / `Esc` | Cancel                                 |

### Tag Menu (`#`)

| Key         | Action                                  |
| ----------- | --------------------------------------- |
| `1`–`9`     | Filter by that tag (two digits for 10+) |
| `0`         | Show all tasks again                    |
| `q` / `Esc` | Back                                    |

### Alias Editor (`a`)

| Key         | Action                            |
| ----------- | --------------------------------- |
| `1`         | Edit the alias file in the editor |
| `2`         | Add a new alias (task or profile) |
| `0` / `Esc` | Back                              |

### Config Editor (`e`)

| Key         | Action                                 |
| ----------- | -------------------------------------- |
| `1`         | Open the file in the editor            |
| `2`         | Replace the whole content (paste mode) |
| `3`         | Show the current content               |
| `0` / `Esc` | Back                                   |

### File Browser (`f`)

| Key         | Action                            |
| ----------- | --------------------------------- |
| `1`         | Create a new file                 |
| `2`         | Edit the `.tasks` file            |
| `3`         | Edit the `.env` file              |
| `4`         | Browse all files of the directory |
| `0` / `Esc` | Back                              |

---

## Practical Workflow Examples

### Scenario 1: Run a "Deploy" Task

```
Menu shown:
  1. Build
  2. Test
  3. Deploy ← target
  4. Rollback

Shortcuts:
  3           # Execute task #3 (Deploy) directly
```

### Scenario 2: Find a "Setup" Task in a Long List

```
Menu has 50+ tasks. Find "Setup":

/             # Enter search
setup         # Type "setup"
Enter         # Apply the filter
```

### Scenario 3: Run a Recent Task Again

```
R             # Show the recent tasks
1             # Select the first entry
```

### Scenario 4: Check a Task Before Running It

```
↑ / ↓         # Navigate to the task
Enter         # Show the preview (command, dependencies), then run
```

### Scenario 5: Switch Profiles

```
p             # Show the profiles
2             # Select profile #2 (.tasks.prod) — selects immediately
```

---

## Troubleshooting Shortcuts

If the shortcuts do not work:

1. **Check the TERM type:**

   ```bash
   echo $TERM
   # Should be: xterm, xterm-256color, linux, etc.
   ```

2. **Enable the keyboard input:**

   ```bash
   stty -echo    # Should echo the input
   ```

3. **Check whether the runner is in interactive mode:**

   ```bash
   run           # Interactive ✅ (the shortcuts work)
   run --list    # Non-interactive ❌ (no menu)
   ```

4. **SSH without a TTY:**

   ```bash
   ssh -t host "cd project && run"   # the -t allocates a terminal
   ```

---

## See Also

- [CLI_REFERENCE.md](./CLI_REFERENCE.md) — Command-line flags
- [QUICK_START.md](./QUICK_START.md) — Getting started
- [ADVANCED_USAGE.md](./ADVANCED_USAGE.md) — Advanced patterns
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) — Debug help
