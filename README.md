# 🚀 Shell Menu Runner

![Version](https://img.shields.io/badge/version-1.0.0-blue.svg?style=flat-square) ![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square) ![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?style=flat-square)

[English](#english) | [Deutsch](#deutsch)

<a name="english"></a>

## 🇺🇸 English

**The Ultimate Task Runner for the Terminal.**
Version 1.0.0 (Gold Master). Zero config, Zero dependencies. Runs on Linux and macOS.

### ✨ Features

- **🌍 Global & Local:** Switch between project tasks (`.tasks`) and system commands (`~/.tasks`) by pressing `g`.
- **🧙‍♂️ Smart Init:** Auto-detects Node.js, Python, Docker, Terraform, and SSH Configs.
- **⚡ Automation:** Batch run tasks (Multi-Select with Space), Audit Logging, and Cron Job generation.
- **🛡 Safety:** `[!]` requires confirmation. `<<Prompts>>` allow input. `<<Select:A,B>>` creates dropdowns.
- **🖥️ Cross-Platform:** Works on Linux (Bash) and macOS (zsh/bash 3.2+).

### 📦 Installation

**The Magic One-Liner:**
Installs the runner and sets up Zsh autocomplete & Raycast scripts automatically.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MarioPeters/shell-menu-runner/main/install.sh)"
```

### ⚙️ Configuration (.tasks)

Format: `LEVEL|NAME|CMD|DESC`

```text
# THEME: CYBER
# TITLE: Backend API
VAR_PORT=8080

0|🚀 Deploy|./deploy.sh --port $VAR_PORT|Deploy App
0|📝 Commit|git commit -m "<<Commit Message>>"|Interactive Input
0|🧹 Clean|rm -rf ./tmp|[!] Requires Confirmation
0|🐳 Docker|SUB|Submenu
1|Logs|docker logs -f|View Logs
1|Back|BACK
```

### 🔌 Integrations

#### VS Code

Add a task in `.vscode/tasks.json` to run via `Cmd+Shift+B`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Run Menu",
      "type": "shell",
      "command": "run",
      "group": { "kind": "build", "isDefault": true },
      "presentation": { "focus": true, "panel": "dedicated" }
    }
  ]
}
```

#### Raycast & Alfred

Use the included scripts in `integrations/` to launch the runner in the current Finder folder. The installer sets this up for Raycast automatically.

#### Zsh Widget

Press `Ctrl+O` to open the menu instantly (setup by installer).

### 🗑️ Uninstall

```bash
rm /usr/local/bin/run
```

---

<a name="deutsch"></a>

## 🇩🇪 Deutsch

**Die Kommandozentrale für dein Terminal.**
Version 1.0.0 (Gold Master). Vereint Entwicklung, DevOps und System-Administration.

### ✨ Hauptfunktionen

- **🌍 Global & Lokal:** Wechsle mit `g` zwischen Projekt-Tasks und System-Befehlen.
- **🧙‍♂️ Smart Init:** Erkennt automatisch Node.js, Python, Terraform, Docker und SSH Hosts.
- **⚡ Automation:** Markiere mehrere Tasks mit `Leertaste` für Batch-Ausführung. Erstelle Cronjobs per Tastendruck.
- **🛡 Sicherheit:** `[!]` in der Beschreibung erzwingt Bestätigung. Eingaben via `<<Platzhalter>>`.
- **🖥️ Cross-Platform:** Läuft auf Linux und macOS (auch alte Bash Versionen).

### 📦 Installation

**Der magische One-Liner:**
Installiert das Tool und richtet Zsh Autocomplete sowie Raycast Skripte automatisch ein.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MarioPeters/shell-menu-runner/main/install.sh)"
```

### ⚙️ Konfiguration

```text
# THEME: CYBER
# TITLE: Backend API
VAR_PORT=8080

0|🚀 Deploy|./deploy.sh --port $VAR_PORT|Deploy App
0|📝 Commit|git commit -m "<<Nachricht>>"|Interaktive Eingabe
0|🧹 Clean|rm -rf ./tmp|[!] Erfordert Bestätigung
```

### 🤝 Mitmachen

Pull Requests sind willkommen! Bitte nutze `shellcheck` vor dem Einreichen.

## 📝 Lizenz

MIT
