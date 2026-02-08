# Changelog

## [Unreleased]

## [1.7.0] - 2026-02-08

### Code Quality

- **CRITICAL:** Fixed 4 shellcheck errors (SC2168: local outside functions) ✅
- **CRITICAL:** Fixed all 25 shellcheck warnings → now 0 warnings ✅
  - 4x SC2168 (local keyword errors)
  - 9x SC2155 (declare/assign separately)
  - 2x SC2206 (word splitting in arrays)
  - 5x SC2076 (regex quote handling)
  - 2x SC2034 (unused variables)
  - 3x SC2004 (array index style)
- Added color output helper functions: info(), warn(), error(), success(), dim()
- Improved variable handling and error checking
- **Result:** Shellcheck clean with 0 errors, 0 warnings (4 info-level items only)
- All changes maintain 100% backward compatibility

### Features

- Added profile menus via `run <name>` (e.g. `run git`, `run docker`) with local/global lookup.
- Added profile config merging for `.tasks.<name>`, `.local`, `.dev` variants.
- Added profile name completion in Zsh (including aliases).
- Added Zsh completion for tasks within selected profiles.
- Refined default profile templates for k8s/db/devops.
- Show active profile in menu header for .tasks.<name> configs.
- Added startup prompt to select profiles even when a default config exists.
- Profile menu pagination: Shows up to 9 profiles per page with `[n]`/`[p]` navigation.
- Added profile management CLI commands:
  - `run --list-profiles` - List all available profiles with locations
  - `run --list-profiles=json` - JSON output for CI/scripting integration
  - `run --init-profile <name>` - Create new profile with template
  - `run --validate <name>` - Validate profile syntax and show task count
- Expanded Smart Init detection (Go, Rust, Java, PHP, Ruby, Makefile, Poetry, Pipenv, pnpm, bun, Terraform).
- Auto-create `.tasks.git` and `.tasks.docker` in Git/Docker repos on init.
- Installer creates global templates `~/.tasks.git`, `~/.tasks.docker`, `~/.tasks.k8s`, `~/.tasks.deploy`, `~/.tasks.db`, `~/.tasks.devops` if missing.
- Added 6 new server management profile templates:
  - `.tasks.server` - Linux/Ubuntu system management (apt, systemd, users, services, logs, cleanup)
  - `.tasks.nginx` - NGINX configuration & management (config test, reload, logs, SSL checks, site enablement)
  - `.tasks.portainer` - Portainer Docker API integration (list containers/images, stats, pull images, prune)
  - `.tasks.mailcow` - mailcow email server management (domains, users, API access, backup, logs)
  - `.tasks.maint` - System maintenance tasks (disk cleanup, log rotation, mail queue, health checks)
  - `.tasks.monitor` - Monitoring & observability (Prometheus queries, Grafana, Alertmanager, health checks)
- Added 6 new developer & DevOps profile templates:
  - `.tasks.ci` - CI/CD pipelines (GitHub Actions, GitLab CI, Jenkins - trigger, status, logs, approvals)
  - `.tasks.aws` - AWS CLI operations (EC2, S3, RDS, Lambda, IAM management)
  - `.tasks.test` - Testing framework integration (unit tests, E2E, coverage, watch mode, debugging)
  - `.tasks.lint` - Code quality tools (ESLint, Prettier, SonarQube, Stylelint, Black, Flake8)
  - `.tasks.sec` - Security scanning (Trivy, Snyk, SSL checks, OWASP, Vault, SBOM generation)
  - `.tasks.build` - Build & release automation (Docker build/push, version bumping, changelog, GitHub releases)
- UX improvements:
  - Profile filter: Live-filter profiles in selection menu with `/` key (supports substring matching)
  - Search history: Previous search terms saved and accessible with ↑ ↓ arrows (~/.run_search_history)
  - Help panel: Press `?` to show comprehensive keyboard shortcuts reference
  - Enhanced filter experience with backspace support and ESC to cancel
- Performance optimizations:
  - Parallel dependency execution: Set `RUN_PARALLEL_DEPS=1` to run independent dependencies concurrently
  - Profile list caching: 60-second TTL cache for profile listings (configurable via `RUN_CACHE_PROFILES`)
  - Enhanced config caching: Improved mtime-based cache invalidation for large config files
  - Session-scoped cache directory with automatic cleanup on exit
- UI/Visuals enhancements:
  - Added DARK theme: Bright colors on dark backgrounds (bright blue/green/cyan)
  - Added LIGHT theme: Softer colors for light terminal backgrounds (blue/green/cyan)
  - Theme selection expanded: CYBER, MONO, DARK, LIGHT available via settings menu ([s] key)
  - Loading indicator: Animated spinner (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) during parallel dependency execution
  - Status bar: Top bar displays time, mode (local/global), active profile, and filters

## [1.3.0] - 2026-02-05

- **Sub-Menus:** Full SUB/BACK navigation with breadcrumb history (LEVEL|NAME|SUB|DESC format).
- **Dropdown-Selects:** New `<<Select:Option1,Option2>>` syntax for interactive dropdown menus instead of free text.
- UI improvements: Breadcrumb path display, multi-level task organization.

## [1.2.0] - 2026-02-05

- Added strict-mode hardening and safer self-update (hash prompt when missing, version readability guard, tput failures ignored).
- Multi-select now executes all marked tasks with summary; footer shows marked count; filter uses substring match.
- Release automation via GitHub Actions (ShellCheck, SHA computation, release with run.sh asset).
- Documentation updates: recommended SHA, security notes, installer version sync.

## [1.1.2] - 2026-02-04

- Added multi-select execution flow, exit-code feedback, and optional SHA check for self-update.
- Improved UI: bold title constant, active_desc init, PATH hint in installer, multi-select info in README.

## [1.1.1] - 2026-01-XX

- Initial public release with smart init (Node/Docker/Python), global/local tasks, inputs via placeholders, themes, and integrations.
