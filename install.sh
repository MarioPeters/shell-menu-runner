#!/bin/bash
# MAGIC INSTALLER v1.0.0
REPO_URL="https://raw.githubusercontent.com/MarioPeters/shell-menu-runner/main/run.sh"
SCRIPT_NAME="run"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
echo -e "${BLUE}=== Shell Menu Runner Installer ===${NC}"
TARGET_DIR="/usr/local/bin"
if [ ! -w "$TARGET_DIR" ]; then TARGET_DIR="$HOME/.local/bin"; mkdir -p "$TARGET_DIR"; fi
echo -e "Installiere nach ${BLUE}$TARGET_DIR${NC}..."
if [ -w "$TARGET_DIR" ]; then curl -fsSL "$REPO_URL" -o "$TARGET_DIR/$SCRIPT_NAME" && chmod +x "$TARGET_DIR/$SCRIPT_NAME"; else sudo curl -fsSL "$REPO_URL" -o "$TARGET_DIR/$SCRIPT_NAME" && sudo chmod +x "$TARGET_DIR/$SCRIPT_NAME"; fi
echo -e "${GREEN}✔ Installiert.${NC} Tippe 'run'."
