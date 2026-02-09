#!/bin/bash

# Minimal working Docker runner for debugging
# This reproduces the core functionality without complex features

set -euo pipefail

# Colors
COLOR_HEAD=$'\e[1;34m'
COLOR_SEL=$'\e[1;32m'
COLOR_ERR=$'\e[1;31m'
COLOR_WARN=$'\e[1;33m'
COLOR_INFO=$'\e[33m'
COLOR_DIM=$'\e[2m'
COLOR_RESET=$'\e[0m'

config_path="$HOME/.tasks.docker"

if [ ! -f "$config_path" ]; then
    echo -e "${COLOR_ERR}Docker profile not found: $config_path${COLOR_RESET}"
    exit 1
fi

echo -e "${COLOR_HEAD}🐳 DOCKER TASKS${COLOR_RESET}"
echo -e "${COLOR_DIM}Profile: $config_path${COLOR_RESET}\n"

# Read tasks from config file
declare -a tasks=()
declare -a commands=()
declare -a descriptions=()
counter=1

while IFS='|' read -r level name cmd desc; do
    # Skip comments and empty lines
    if [[ "$level" =~ ^[[:space:]]*# ]] || [[ -z "$level" ]]; then
        continue
    fi
    
    # Only show level 0 tasks
    if [ "$level" = "0" ]; then
        tasks+=("$counter. $name")
        commands+=("$cmd")
        descriptions+=("$desc")
        echo -e "${COLOR_SEL}$counter.${COLOR_RESET} $name ${COLOR_DIM}($desc)${COLOR_RESET}"
        ((counter++))
    fi
done < "$config_path"

echo ""
read -p "Select task [1-${#tasks[@]}]: " choice

# Validate input
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tasks[@]}" ]; then
    echo -e "${COLOR_ERR}Invalid selection${COLOR_RESET}"
    exit 1
fi

# Execute selected command
selected_cmd="${commands[$((choice-1))]}"

if [ "$selected_cmd" = "EXIT" ]; then
    echo -e "${COLOR_INFO}Exiting...${COLOR_RESET}"
    exit 0
fi

echo -e "${COLOR_INFO}Executing: ${selected_cmd}${COLOR_RESET}"
echo ""

# Execute command
eval "$selected_cmd"