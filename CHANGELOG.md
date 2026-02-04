# Changelog

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
