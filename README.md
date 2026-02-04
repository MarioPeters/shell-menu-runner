# 🚀 Shell Menu Runner

![Version](https://img.shields.io/badge/version-1.1.1-blue.svg?style=flat-square) ![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square) ![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?style=flat-square)

[English](#english) | [Deutsch](#deutsch)

<a name="english"></a>

## 🇺🇸 English

**The Ultimate Task Runner for the Terminal.**
Version 1.1.1 (Gold Master). Zero config, Zero dependencies. Runs on Linux and macOS.

### ✨ Feature Summary (v1.1.1)

**1) 🧠 Smart Project Detection (Smart Init)**

- **Node.js / React:** Scans `package.json` and imports scripts as tasks.
- **Docker:** Detects `docker-compose.yml` and offers `up` / `down` tasks.
- **Python:** Detects `manage.py` (Django) or `main.py` and creates run tasks.

**2) 🌍 Global & Local Mode**

- **Project Tasks:** Uses a local `.tasks` file per project.
- **System Tasks:** Switch with `g` to the global `~/.tasks` menu.
- **Auto Search:** Walks upwards to find the nearest `.tasks` file.

**3) 🛠 Dynamic Interaction & Inputs**

- **Text Inputs:** Use `<<Name>>` placeholders and get prompted at runtime.
- **Environment Files:** Loads a local `.env` before executing a task.

**4) 🛡 Safety & Control**

- **Confirmation:** `[!]` in the description forces an explicit confirmation.
- **Multi-Select (UI):** Mark items with Space (execution remains single-item).

**5) 🎨 UI & UX**

- **Themes:** CYBER / MONO via `# THEME:`.
- **Live Filter:** Press `/` to filter by name.
- **Navigation:** Arrow keys and `j`/`k`; multi-select with Space, execution runs all marked tasks in order on Enter.

**6) 🔌 Integrations**

- **Zsh Widget:** Open the menu with `Ctrl+O`.
- **Raycast & Alfred:** macOS integrations via scripts in `integrations/`.

**7) 🔄 Maintenance & Installation**

- **Self-Update:** `run --update` downloads the latest version.
- **Magic Installer:** One-liner installer via `install.sh`.
- **Integrity Check (optional):** Set `RUN_EXPECTED_SHA256=<hash>` before `run --update` to verify the downloaded script.

**Planned / Roadmap**

- Terraform detection, dropdown selects (`<<Select:A,B>>`), batch execution of multi-select,
  sub-menus (`SUB`/`BACK`), shell completions, Homebrew tap, and CI checks.

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
Version 1.1.1 (Gold Master). Vereint Entwicklung, DevOps und System-Administration.

### ✨ Feature-Zusammenfassung (v1.1.1)

**1) 🧠 Intelligente Projekt-Erkennung (Smart Init)**

- **Node.js / React:** Scannt die `package.json` und importiert Scripts als Tasks.
- **Docker:** Erkennt `docker-compose.yml` und bietet `up` / `down` Tasks an.
- **Python:** Erkennt `manage.py` (Django) oder `main.py` und erstellt Start-Tasks.

**2) 🌍 Globaler & Lokaler Modus**

- **Projekt-Tasks:** Nutzt eine lokale `.tasks` pro Projekt.
- **System-Tasks:** Wechsel mit `g` ins globale Menü `~/.tasks`.
- **Auto-Suche:** Sucht beim Start nach oben die nächste `.tasks`.

**3) 🛠 Dynamische Interaktion & Eingaben**

- **Text-Eingaben:** `<<Name>>` wird zur Laufzeit abgefragt.
- **Umgebungsdatei:** Lädt eine lokale `.env` vor der Ausführung.

**4) 🛡 Sicherheit & Kontrolle**

- **Bestätigung:** `[!]` in der Beschreibung erzwingt eine Bestätigung.
- **Multi-Select (UI):** Markieren per Leertaste (Ausführung bleibt einzeln).

**5) 🎨 UI & UX**

- **Themes:** CYBER / MONO via `# THEME:`.
- **Echtzeit-Filter:** `/` filtert nach Namen.
- **Navigation:** Pfeiltasten sowie `j`/`k`.

**6) 🔌 Integrationen**

- **Zsh Widget:** Menü per `Ctrl+O` öffnen.
- **Raycast & Alfred:** macOS-Integrationen über Skripte in `integrations/`.

**7) 🔄 Wartung & Installation**

- **Self-Update:** `run --update` lädt die neueste Version.
- **Magic Installer:** Einzeiler über `install.sh`.

**Geplant / Roadmap**

- Terraform-Erkennung, Dropdown-Selects (`<<Select:A,B>>`), Batch-Ausführung für Multi-Select,
  Sub-Menüs (`SUB`/`BACK`), Shell-Completion, Homebrew-Tap und CI-Checks.

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
