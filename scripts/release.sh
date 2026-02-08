#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

# Colors
C_HEAD=$'\e[1;36m'
C_OK=$'\e[1;32m'
C_WARN=$'\e[1;33m'
C_ERR=$'\e[1;31m'
C_DIM=$'\e[2m'
C_RST=$'\e[0m'

cecho() { printf "%b\n" "$*"; }
cecho_n() { printf "%b" "$*"; }

show_help() {
  cat <<EOF
${C_HEAD}Shell Menu Runner - Release Script${C_RST}

${C_DIM}Automates the release process:${C_RST}
  - Runs shellcheck (if available)
  - Updates version in run.sh, README.md badges
  - Computes SHA256 hash and updates README
  - Collects git commits since last tag
  - Adds CHANGELOG entry with auto-generated commit list
  - Opens \$EDITOR for changelog review
  - Creates git commit, tag, and pushes to remote

${C_DIM}Usage:${C_RST}
  $0              # Interactive menu
  $0 --dry-run    # Direct dry-run mode
  $0 --release    # Direct release mode
  $0 --help       # Show this help
EOF
  exit 0
}

show_menu() {
  clear
  cecho "${C_HEAD}🚀 Shell Menu Runner - Release Automation${C_RST}\n"
  cecho "${C_DIM}Select mode:${C_RST}\n"
  echo "1) Full Release (interactive)"
  echo "2) Dry-run (preview only)"
  echo "3) Help"
  echo "0) Exit"
  echo ""
  cecho_n "${C_HEAD}Choice [0-3]:${C_RST} "
  read -r choice
  case "$choice" in
    1) return 0 ;;
    2) return 1 ;;
    3) show_help ;;
    0|q) cecho "\n${C_DIM}Aborted.${C_RST}"; exit 0 ;;
    *) cecho "\n${C_ERR}Invalid choice${C_RST}"; sleep 1; show_menu ;;
  esac
}

DRY_RUN=0
INTERACTIVE=1

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1; INTERACTIVE=0 ;;
    --release|-r) DRY_RUN=0; INTERACTIVE=0 ;;
    --help|-h) show_help ;;
  esac
done

if [ "$INTERACTIVE" -eq 1 ]; then
  if show_menu; then
    DRY_RUN=0
  else
    DRY_RUN=1
  fi
fi

cecho "${C_HEAD}🚀 Shell Menu Runner - Release Automation${C_RST}\n"

if ! command -v git >/dev/null 2>&1; then
  cecho "${C_ERR}✗ git is required.${C_RST}" >&2
  exit 1
fi

if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  cecho "${C_ERR}✗ shasum or sha256sum is required.${C_RST}" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  cecho "${C_ERR}✗ python3 is required.${C_RST}" >&2
  exit 1
fi

cecho "${C_OK}✓ Prerequisites met${C_RST}"

cecho "${C_DIM}→ Running bash syntax checks...${C_RST}"
if bash -n run.sh install.sh scripts/release.sh integrations/alfred/alfred_workflow_script.sh integrations/raycast/run-project.sh integrations/zsh/run_widget.zsh; then
  cecho "${C_OK}✓ Bash syntax OK${C_RST}"
else
  cecho "${C_ERR}✗ Bash syntax check failed${C_RST}" >&2
  exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
  cecho "${C_DIM}→ Running shellcheck...${C_RST}"
  if shellcheck run.sh install.sh integrations/alfred/alfred_workflow_script.sh integrations/raycast/run-project.sh integrations/zsh/run_widget.zsh; then
    cecho "${C_OK}✓ Shellcheck passed${C_RST}"
  else
    cecho "${C_ERR}✗ Shellcheck failed${C_RST}" >&2
    exit 1
  fi
else
  cecho "${C_WARN}⚠ shellcheck not found. Skipping lint.${C_RST}"
fi

cecho "\n${C_DIM}→ Checking working tree...${C_RST}"
if ! git diff --quiet; then
  cecho "${C_ERR}✗ Working tree is not clean. Commit or stash changes first.${C_RST}" >&2
  exit 1
fi
cecho "${C_OK}✓ Working tree clean${C_RST}"

cecho_n "\n${C_HEAD}Release version (e.g. 1.3.1):${C_RST} "
read -r version
if [ -z "$version" ]; then
  cecho "${C_ERR}✗ Version is required.${C_RST}" >&2
  exit 1
fi

if grep -q "^## \[$version\]" CHANGELOG.md; then
  cecho "${C_ERR}✗ CHANGELOG already has version $version.${C_RST}" >&2
  exit 1
fi

date_str=$(date +%Y-%m-%d)

# Collect commits since last tag
cecho "\n${C_DIM}→ Collecting commits since last release...${C_RST}"
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$last_tag" ]; then
  cecho "${C_DIM}  Last tag: $last_tag${C_RST}"
  commits=$(git log "$last_tag"..HEAD --oneline --no-merges | sed 's/^[a-f0-9]* /- /')
else
  cecho "${C_DIM}  No previous tags found, using all commits${C_RST}"
  commits=$(git log --oneline --no-merges | sed 's/^[a-f0-9]* /- /')
fi

if [ -z "$commits" ]; then
  commits="- TBD"
  cecho "${C_WARN}⚠ No new commits found${C_RST}"
else
  cecho "${C_OK}✓ Found $(echo "$commits" | wc -l | xargs) commits${C_RST}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  cecho "\n${C_WARN}⚠ DRY-RUN MODE: No files will be modified${C_RST}\n"
fi

cecho "\n${C_DIM}[1/4] Updating version references...${C_RST}"
if [ "$DRY_RUN" -eq 0 ]; then
  sed -i '' -E "s/^readonly VERSION=\"[^\"]+\"/readonly VERSION=\"$version\"/" run.sh
  sed -i '' -E "s/version-[0-9.]+-blue/version-$version-blue/" README.md
  sed -i '' -E "s/Version [0-9.]+ \(/Version $version (/g" README.md
  cecho "${C_OK}✓ Version updated to $version${C_RST}"
else
  cecho "${C_DIM}  - run.sh: readonly VERSION=\"$version\"${C_RST}"
  cecho "${C_DIM}  - README.md: version badge + Version lines${C_RST}"
fi

cecho "\n${C_DIM}[2/4] Computing SHA256 hash...${C_RST}"
sha=""
if command -v sha256sum >/dev/null 2>&1; then
  sha=$(sha256sum run.sh | awk '{print $1}')
else
  sha=$(shasum -a 256 run.sh | awk '{print $1}')
fi

if [ "$DRY_RUN" -eq 0 ]; then
  sed -i '' -E "s/Recommended hash for v[0-9.]+: .*/Recommended hash for v$version: $sha/" README.md
  python3 - <<PY
from pathlib import Path
import re

path = Path("README.md")
text = path.read_text(encoding="utf-8")
pattern = r"^Empfohlener Hash f\u00fcr v[0-9.]+: .*$"
replacement = f"Empfohlener Hash f\u00fcr v$version: $sha"
text = re.sub(pattern, replacement, text, flags=re.MULTILINE)
path.write_text(text, encoding="utf-8")
PY
  cecho "${C_OK}✓ SHA256: ${C_DIM}$sha${C_RST}"
else
  cecho "${C_DIM}  - SHA256: $sha${C_RST}"
  cecho "${C_DIM}  - README.md: would update hash${C_RST}"
fi

cecho "\n${C_DIM}[3/4] Updating changelog...${C_RST}"
if [ "$DRY_RUN" -eq 0 ]; then
  python3 - <<PY
from pathlib import Path

path = Path("CHANGELOG.md")
content = path.read_text(encoding="utf-8")
lines = content.split('\n')

# Insert new version header after first line (# Changelog)
version = "$version"
date_str = "$date_str"
commits = """$commits"""

new_lines = [lines[0], "", f"## [{version}] - {date_str}", ""]
new_lines.extend(commits.strip().split('\n'))
new_lines.extend(["", ""] + lines[1:])

path.write_text('\n'.join(new_lines), encoding="utf-8")
PY
  
  # Open editor for review
  if [ -n "${EDITOR:-}" ]; then
    cecho "${C_DIM}→ Opening editor for changelog review...${C_RST}"
    ${EDITOR} CHANGELOG.md
  else
    cecho "${C_WARN}⚠ No EDITOR set. Review CHANGELOG.md manually if needed.${C_RST}"
    cecho "${C_DIM}  Press Enter to continue or Ctrl+C to abort...${C_RST}"
    read -r
  fi
  
  cecho "${C_OK}✓ CHANGELOG.md updated${C_RST}"
else
  cecho "${C_DIM}  - CHANGELOG.md: would prepend ## [$version] - $date_str${C_RST}"
  cecho "${C_DIM}  - Commits to include:${C_RST}"
  echo "$commits" | head -5 | sed 's/^/    /'
  [ "$(echo "$commits" | wc -l)" -gt 5 ] && cecho "${C_DIM}    ... and more${C_RST}"
fi

if [ "$DRY_RUN" -eq 0 ] && ! git diff --quiet; then
  cecho "\n${C_DIM}Changed files:${C_RST}"
  git status --short
fi

if [ "$DRY_RUN" -eq 1 ]; then
  cecho "\n${C_DIM}[4/4] Git operations (dry-run):${C_RST}"
  cecho "${C_DIM}  git add run.sh README.md CHANGELOG.md install.sh .github/workflows/release.yml${C_RST}"
  cecho "${C_DIM}  git commit -m \"Release $version\"${C_RST}"
  cecho "${C_DIM}  git tag v$version${C_RST}"
  cecho "${C_DIM}  git push && git push --tags${C_RST}"
  cecho "\n${C_WARN}✓ Dry-run complete. No changes made.${C_RST}"
  exit 0
fi

cecho "\n${C_DIM}[4/4] Git operations...${C_RST}"
cecho_n "${C_HEAD}Commit, tag, and push v$version? [y/N]${C_RST} "
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  cecho "${C_WARN}⚠ Aborted. Files are updated locally but not committed.${C_RST}"
  exit 0
fi

cecho "${C_DIM}→ Adding files...${C_RST}"
git add run.sh README.md CHANGELOG.md install.sh .github/workflows/release.yml
cecho "${C_DIM}→ Creating commit...${C_RST}"
git commit -m "Release $version"
cecho "${C_DIM}→ Creating tag...${C_RST}"
git tag "v$version"
cecho "${C_DIM}→ Pushing to remote...${C_RST}"
git push && git push --tags

cecho "\n${C_OK}✓ Release v$version completed successfully!${C_RST}"
