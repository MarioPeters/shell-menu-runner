# ==============================================================================
#  SELF-UPDATE
# ==============================================================================

self_update() {
    echo -e "${COLOR_HEAD}$(msg update_check)${COLOR_RESET}"
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${COLOR_ERR}$(msg curl_missing)${COLOR_RESET}"
        return 1
    fi
    local tmp_file
    tmp_file=$(mktemp /tmp/run_update.XXXXXX) || { echo -e "${COLOR_ERR}$(msg temp_file_fail)${COLOR_RESET}"; return 1; }
    if curl -fsSL "$REPO_RAW_URL" -o "$tmp_file"; then
        # Version check first — no hash prompt needed when already up to date
        local new_ver=""
        new_ver=$(_grep -m1 "readonly VERSION=" "$tmp_file" 2>/dev/null | cut -d'"' -f2 2>/dev/null || true)
        if [ -z "$new_ver" ]; then
            echo -e "${COLOR_ERR}$(msg download_error)${COLOR_RESET}"
            rm -f "$tmp_file"
            return 1
        fi
        if [ "$new_ver" == "$VERSION" ]; then
            echo -e "${COLOR_SEL}$(msg update_same) ($VERSION).${COLOR_RESET}"
            rm -f "$tmp_file"
        else
            echo -e "${COLOR_WARN}$(msg update_found) $VERSION -> $new_ver${COLOR_RESET}"
            # Hash verification only when an actual update is about to be installed
            if [ -n "${RUN_EXPECTED_SHA256:-}" ]; then
                local dl_hash=""
                dl_hash=$(file_sha256 "$tmp_file") || echo -e "${COLOR_WARN}$(msg hash_skipped)${COLOR_RESET}"
                if [ -n "$dl_hash" ] && [ "$dl_hash" != "${RUN_EXPECTED_SHA256:-}" ]; then
                    echo -e "${COLOR_ERR}$(msg hash_mismatch) ${RUN_EXPECTED_SHA256:-} != $dl_hash${COLOR_RESET}"
                    rm -f "$tmp_file"
                    return 1
                fi
            else
                echo -e "${COLOR_WARN}$(msg no_hash)${COLOR_RESET}"
                read -p "$(msg continue_prompt) " -n 1 -r || true; echo ""
                if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
                    rm -f "$tmp_file"
                    return 1
                fi
            fi
            local install_path
            # "|| install_path=''": eine fehlgeschlagene Zuweisung (fehlendes
            # "run" auf dem PATH) bricht unter "set -e" sonst das Skript ab,
            # BEVOR die darunter stehende Fehlermeldung eine Chance hat —
            # der Update-Flow endete dann stumm ohne jeden Hinweis.
            install_path=$(command -v run 2>/dev/null) || install_path=""
            if [ -z "$install_path" ]; then
                echo -e "${COLOR_ERR}$(msg install_path_missing)${COLOR_RESET}"
                rm -f "$tmp_file"
                return 1
            fi
            # "command -v" liefert bei einer Shell-Funktion oder einem Alias
            # nur den Namen ("run") — das wäre ein relatives Ziel im
            # aktuellen Verzeichnis.  Nur ein absoluter Pfad ist gültig.
            case "$install_path" in
                /*) ;;
                *)
                    echo -e "${COLOR_ERR}$(msg install_path_missing)${COLOR_RESET}"
                    rm -f "$tmp_file"
                    return 1
                    ;;
            esac
            local _install_failed=0
            if [ -w "$install_path" ]; then
                mv "$tmp_file" "$install_path" && chmod +x "$install_path" || _install_failed=1
            else
                sudo mv "$tmp_file" "$install_path" && sudo chmod +x "$install_path" || _install_failed=1
            fi
            # Ein fehlgeschlagener Installationsschritt darf NICHT als Erfolg
            # gemeldet werden (vorher stand hier "✔ Update erfolgreich", auch
            # wenn das sudo fehlschlug).
            if [ "$_install_failed" -ne 0 ]; then
                echo -e "${COLOR_ERR}$(msg update_failed)${COLOR_RESET}"
                rm -f "$tmp_file"
                return 1
            fi
            echo -e "${COLOR_SEL}✔ $(msg update_success) $new_ver${COLOR_RESET}"
            command -v run >/dev/null 2>&1 && echo -e "${COLOR_INFO}Aktuelle Version:${COLOR_RESET} $(run --version 2>/dev/null)"
            return 0
        fi
    else
        echo -e "${COLOR_ERR}$(msg download_error)${COLOR_RESET}"
        rm -f "$tmp_file"
        return 1
    fi
}

# ==============================================================================
#  SMART INIT (AUTO-DETECTION)
# ==============================================================================

# Extracts the script names from a package.json.
#
# jq is used when available; the awk fallback counts the key lines of the
# "scripts" object.  The previous implementation ("sed -n '/"scripts": {/,/}/p'")
# picked up the container key itself ("npm scripts") and stopped at the first
# "}" — a script value containing a brace truncated the whole list.
_package_json_scripts() {
    local file="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '(.scripts // {}) | keys[]' "$file" 2>/dev/null
        return 0
    fi
    awk '
        /"scripts"[[:space:]]*:[[:space:]]*\{/ { in_scripts = 1; next }
        in_scripts && /^[[:space:]]*\}/ { in_scripts = 0; next }
        in_scripts && match($0, /^[[:space:]]*"[^"]+"[[:space:]]*:/) {
            key = substr($0, RSTART, RLENGTH)
            sub(/^[[:space:]]*"/, "", key)
            sub(/".*/, "", key)
            print key
        }
    ' "$file" 2>/dev/null
}

smart_init() {
    local mode="$1"
    local target="$LOCAL_CONFIG"; [ "$mode" == "global" ] && target="$GLOBAL_CONFIG"

    if [ -f "$target" ]; then
        echo -e "${COLOR_WARN}$(msg config_exists) '$target'.${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_HEAD}$(msg init_header)${COLOR_RESET}"
    echo "# Shell Menu Runner Configuration" > "$target"
    echo "# THEME: CYBER" >> "$target"
    echo "" >> "$target"

    if [ "$mode" == "global" ]; then
        echo "0|🔄 System Update|sudo apt update && sudo apt upgrade -y|Systempflege" >> "$target"
        echo "0|🧹 Cache Cleanup|rm -rf /tmp/*|Temporäre Dateien löschen" >> "$target"
    else
        local target_dir
        target_dir="$(dirname "$target")"

        # Git profile tasks (separate menu via: run git)
        if [ -d "$target_dir/.git" ]; then
            local git_tasks_file="$target_dir/.tasks.git"
            if [ ! -f "$git_tasks_file" ]; then
                echo -e "${COLOR_INFO}→ Git repo detected. Creating .tasks.git...${COLOR_RESET}"
                cat > "$git_tasks_file" <<'EOF'
# Shell Menu Runner Git Tasks
# TITLE: GIT
0|📌 Status|git status -sb|Working tree status
0|🧭 Branches|git branch -a|List branches
0|🧾 Log (short)|git log --oneline --decorate -n 20|Recent commits
0|🧩 Diff|git diff|Show unstaged diff
0|✅ Add All|git add -A|Stage all changes
0|📝 Commit|git commit -m "<<Commit message>>"|Create commit
0|⬇ Pull|git pull --rebase|Pull with rebase
0|⬆ Push|git push|Push current branch
0|📦 Stash|git stash push -m "<<Stash message>>"|Stash changes
0|📦 Stash Pop|git stash pop|Apply latest stash
0|❌ Exit|EXIT|Back
EOF
            fi
        fi

        # Docker profile tasks (separate menu via: run docker)
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            local docker_tasks_file="$target_dir/.tasks.docker"
            if [ ! -f "$docker_tasks_file" ]; then
                echo -e "${COLOR_INFO}→ Docker Compose detected. Creating .tasks.docker...${COLOR_RESET}"
                cat > "$docker_tasks_file" <<'EOF'
# Shell Menu Runner Docker Tasks
# TITLE: DOCKER
0|🐳 Up|docker compose up -d|Start containers
0|🐳 Down|docker compose down|Stop containers
0|🐳 Logs|docker compose logs -f --tail=200|Follow logs
0|🐳 Restart|docker compose restart|Restart containers
0|🐳 Ps|docker compose ps|Show status
0|❌ Exit|EXIT|Back
EOF
            fi
        fi

        # 1. Node.js / React Detection
        if [ -f "package.json" ]; then
            echo -e "${COLOR_INFO}→ $(msg node_detected)${COLOR_RESET}"
            local scripts
            scripts=$(_package_json_scripts "package.json")
            for s in $scripts; do
                echo "0|📦 npm $s|npm run $s|Aus package.json" >> "$target"
            done

            if [ -f "pnpm-lock.yaml" ]; then
                echo "0|📦 pnpm install|pnpm install|Install dependencies" >> "$target"
            fi
            if [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then
                echo "0|📦 bun install|bun install|Install dependencies" >> "$target"
            fi
        fi

        # 2. Docker Detection
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            echo -e "${COLOR_INFO}→ $(msg docker_detected)${COLOR_RESET}"
            echo "0|🐳 Docker Up|docker compose up -d|Container starten" >> "$target"
            echo "0|🐳 Docker Down|docker compose down|Container stoppen" >> "$target"
        fi

        # 3. Python Detection
        if [ -f "requirements.txt" ] || [ -f "main.py" ] || [ -f "manage.py" ]; then
            echo -e "${COLOR_INFO}→ $(msg python_detected)${COLOR_RESET}"
            [ -f "manage.py" ] && echo "0|🐍 Django Run|python3 manage.py runserver|Django Dev Server" >> "$target"
            [ -f "main.py" ] && echo "0|🐍 Run Main|python3 main.py|Python Script starten" >> "$target"
        fi

        if [ -f "pyproject.toml" ] || [ -f "poetry.lock" ]; then
            echo "0|🐍 Poetry Install|poetry install|Install dependencies" >> "$target"
            echo "0|🐍 Poetry Shell|poetry shell|Enter virtualenv" >> "$target"
        fi
        if [ -f "Pipfile" ]; then
            echo "0|🐍 Pipenv Install|pipenv install|Install dependencies" >> "$target"
            echo "0|🐍 Pipenv Shell|pipenv shell|Enter virtualenv" >> "$target"
        fi

        # 4. Makefile Detection
        if [ -f "Makefile" ] || [ -f "makefile" ]; then
            echo "0|🛠 Make|make|Default target" >> "$target"
            echo "0|🛠 Make Test|make test|Run tests" >> "$target"
        fi

        # 5. Go Detection
        if [ -f "go.mod" ]; then
            {
                echo "0|🐹 Go Build|go build ./...|Build modules"
                echo "0|🐹 Go Test|go test ./...|Run tests"
                echo "0|🐹 Go Run|go run .|Run module"
            } >> "$target"
        fi

        # 6. Rust Detection
        if [ -f "Cargo.toml" ]; then
            {
                echo "0|🦀 Cargo Build|cargo build|Build project"
                echo "0|🦀 Cargo Test|cargo test|Run tests"
                echo "0|🦀 Cargo Run|cargo run|Run project"
            } >> "$target"
        fi

        # 7. Java Detection
        if [ -f "pom.xml" ]; then
            echo "0|☕ Maven Test|mvn test|Run tests" >> "$target"
            echo "0|☕ Maven Package|mvn package|Build package" >> "$target"
        fi
        if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
            echo "0|☕ Gradle Test|./gradlew test|Run tests" >> "$target"
            echo "0|☕ Gradle Build|./gradlew build|Build project" >> "$target"
        fi

        # 8. PHP Detection
        if [ -f "composer.json" ]; then
            echo "0|🐘 Composer Install|composer install|Install dependencies" >> "$target"
            echo "0|🐘 PHP Server|php -S localhost:8000 -t public|Dev server" >> "$target"
        fi

        # 9. Ruby Detection
        if [ -f "Gemfile" ]; then
            echo "0|💎 Bundle Install|bundle install|Install gems" >> "$target"
            echo "0|💎 Rake Test|bundle exec rake test|Run tests" >> "$target"
        fi

        # 10. Terraform Detection
        if compgen -G "*.tf" >/dev/null; then
            echo "0|🌍 Terraform Init|terraform init|Initialize" >> "$target"
            echo "0|🌍 Terraform Plan|terraform plan|Show plan" >> "$target"
        fi

        # Fallback falls nichts gefunden wurde
        if [ "$(wc -l < "$target")" -lt 4 ]; then
            echo "0|🚀 Hello World|echo 'Edit .tasks to add commands'|Beispiel Task" >> "$target"
        fi
    fi

    echo "0|❌ Exit|EXIT|Menü beenden" >> "$target"
    echo -e "${COLOR_SEL}✔ $(msg init_done) '$target'.${COLOR_RESET}"
}

# ==============================================================================
#  MAIN ENTRY POINT
# ==============================================================================

# Parse CLI arguments
args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            # 2>/dev/null: a closed stdout (`run --help | head`) must not
            # produce a "write error: Broken pipe" message from the builtin.
            {
                echo "Usage: run [options] [profile]"
                echo ""
                echo "CLI Mode (no menu):"
                echo "  run --list              List all tasks for current profile"
                echo "  run --run <name|num>    Execute task by name (substring) or number"
                echo "  run --dry-run --run <n> Preview command without executing"
                echo "  run git --run build     Profile + task combined"
                echo ""
                echo "Profiles:"
                echo "  run <name>              Load profile .tasks.<name>"
                echo "  run --list-profiles     List all available profiles"
                echo "  run --list-profiles=json  List profiles in JSON format"
                echo "  run --init-profile <name>  Create new profile"
                echo "  run --validate <name>   Validate profile syntax"
                echo ""
                echo "Multi-Profile Execution:"
                echo "  run --across p1,p2,p3 task  Execute task across multiple profiles"
                echo ""
                echo "Analysis & Recommendations:"
                echo "  run --analyze [profile]  Show analysis & improvement suggestions"
                echo ""
                echo "Other:"
                echo "  run --help, -h          Show this help"
                echo "  run --version, -v       Show version"
                echo "  run --init              Initialize .tasks in current dir"
                echo "  run --global            Switch to global mode"
                echo "  run --edit, -e          Edit config file"
                echo "  run --update            Update script to latest version"
                echo "  run --debug             Enable debug mode"
            } 2>/dev/null || true
            exit 0
            ;;
        --version|-v)
            echo "$VERSION"
            exit 0
            ;;
        --debug)
            DEBUG_MODE=1
            shift
            ;;
        --across)
            shift
            if [ $# -lt 2 ]; then
                echo "Usage: run --across <profile1,profile2> <task>" >&2
                exit 1
            fi
            multi_profiles="$1"
            shift
            multi_task="$1"
            shift
            execute_multi_profile_task "$multi_task" "$multi_profiles"
            exit $?
            ;;
        --init)
            smart_init "local"
            exit 0
            ;;
        --list-profiles*)
            format="${1#*=}"
            [ "$format" = "--list-profiles" ] && format="text"
            list_profiles_all "$format"
            exit 0
            ;;
        --init-profile)
            shift
            # "${1:-}": ohne Argument wäre "$1" eine ungebundene Variable —
            # der Fehler endete mit Exit-Code 0 (der EXIT-Trap verwirft den
            # Status) und die Meldung war für den Nutzer unverständlich.
            init_profile "${1:-}"
            exit $?
            ;;
        --validate)
            shift
            if [ -n "${1:-}" ]; then
                validate_profile "$1"
            else
                if found=$(find_local_config); then
                    validate_config_file "$found" "local"
                elif [ -f "$GLOBAL_CONFIG" ]; then
                    validate_config_file "$GLOBAL_CONFIG" "global"
                else
                    echo "Error: profile name required"
                    exit 1
                fi
            fi
            exit $?
            ;;
        --analyze)
            shift
            analyze_project "$@"
            exit 0
            ;;
        --update)
            # Der Rückgabewert von self_update wird durchgereicht — ein
            # fehlgeschlagenes Update darf nicht mit Exit 0 enden.
            self_update
            exit $?
            ;;
        --global)
            active_mode="global"
            config_path="$GLOBAL_CONFIG"
            if [ ! -f "$config_path" ]; then
                if smart_init "global"; then
                    exit 0
                fi
            fi
            # The flag is consumed in any case — otherwise it would end up in
            # the profile list and be treated as a profile name.
            shift
            ;;
        --edit|-e)
            # Der Config-Pfad wird erst nach der Argument-Auswertung
            # aufgelöst — hier muss derselbe Pfad wie im Menü verwendet
            # werden.  Sonst öffnete der Editor in einem Unterverzeichnis
            # eine neue (nicht existierende) ".tasks" statt der Config,
            # die der Runner tatsächlich verwendet.
            if [ -z "$config_path" ]; then
                if [ "$active_mode" = "global" ]; then
                    config_path="$GLOBAL_CONFIG"
                elif found=$(find_local_config); then
                    config_path="$found"
                else
                    config_path="$LOCAL_CONFIG"
                fi
            fi
            # Terminal-Snapshot, damit der Editor-Zustand danach wiederhergestellt
            # werden kann (läuft vor check_interactive)
            save_terminal_state
            edit_config_menu "$config_path"
            exit 0
            ;;
        --run)
            shift
            cli_run_query="${1:-}"
            if [ -z "$cli_run_query" ]; then
                echo "Usage: --run <name-or-number>" >&2
                exit 1
            fi
            cli_mode=1
            shift
            ;;
        --dry-run)
            dry_run_mode=1
            shift
            ;;
        --list)
            cli_list_mode=1
            shift
            ;;
        *)
            # Ein unbekanntes Flag ist ein Tippfehler, kein Profilname —
            # ein Profilname darf nicht mit einem Bindestrich beginnen.
            # Vorher wurde "--foo" als Profilname interpretiert und der
            # Runner startete normal ("Profile '--foo' not found").
            case "$1" in
                -*)
                    echo "Error: unknown option '$1'" >&2
                    echo "Run 'run --help' for the list of options." >&2
                    exit 1
                    ;;
            esac
            args+=("$1")
            shift
            ;;
    esac
done
set +u  # Disable nounset for array check
if [ "${#args[@]}" -gt 0 ]; then
    set -- "${args[@]}"
else
    set --
fi
set -u  # Re-enable nounset

if [ "${RUN_DEBUG:-0}" = "1" ]; then
    DEBUG_MODE=1
fi

if [ "$DEBUG_MODE" -eq 1 ]; then
    set -x
fi

# Profile selection on startup was removed — use [p] in the menu instead.

set +u  # Disable nounset for array check
# Name des Alias-Ziels, das ein Task sein könnte (siehe _alias_task).
_alias_task=""
if [ "${#args[@]}" -gt 0 ]; then
    set -u  # Re-enable nounset
    load_aliases
    profile_input="${args[0]}"
    profile="$(resolve_alias "$profile_input")"

    if found=$(find_named_config "$profile"); then
        active_mode="local"
        config_path="$found"
    elif [ -f "$HOME/.tasks.$profile" ]; then
        active_mode="global"
        config_path="$HOME/.tasks.$profile"
    elif [ "$profile" != "$profile_input" ]; then
        # Der Alias zeigt nicht auf ein Profil, sondern auf einen Task-Namen
        # (das Alias-File-Template dokumentiert "alias=task_name").  Der
        # Task wird später aus der Standard-Config ausgeführt.
        _alias_task="$profile"
    else
        echo -e "${COLOR_WARN}Profile '$profile' not found. Using default config.${COLOR_RESET}"
        profiles_list=$(list_available_profiles)
        if [ -n "$profiles_list" ]; then
            echo -e "${COLOR_INFO}Available profiles:${COLOR_RESET} ${profiles_list//$'\n'/ }"
        fi
    fi
else
    set -u  # Re-enable nounset if condition was false
fi

if [ -z "$config_path" ]; then
    if found=$(find_local_config); then
        config_path="$found"
    elif [ -f "$GLOBAL_CONFIG" ]; then
        active_mode="global"
        config_path="$GLOBAL_CONFIG"
    else
        # Fallback: Load default global profile or show error
        echo -e "${COLOR_WARN}No .tasks file found.${COLOR_RESET}"
        exit 1
    fi
fi

# Global variables from ~/.run_vars are loaded before the config so that the
# VAR_* entries of the config can overwrite them.
load_global_vars

parse_config_vars
load_settings
# The theme from .runrc / the config file was never applied before — the
# colours were only changed when the settings menu was opened.
apply_theme
load_state
# Ensure selected_index is initialized
selected_index="${selected_index:-0}"
detect_config_files
load_aliases
check_interactive
check_ssh_session

# If not interactive and SSH, show hint (only once)
if [ "$is_interactive" -eq 0 ] && [ "$is_ssh_session" -eq 1 ] && [ "$ssh_hint_shown" -eq 0 ]; then
    echo ""
    print_ssh_hint
    echo ""
    echo "Proceeding in non-interactive mode. Type task number to execute:"
    echo ""
    ssh_hint_shown=1
fi

# Without a TTY there is nobody to answer the interactive prompts (preview,
# "press any key") — the tasks run in CLI mode instead.
if [ "$is_interactive" -eq 0 ] && [ "${cli_mode:-0}" -eq 0 ]; then
    cli_mode=1
fi

# CLI mode dispatch
if [ "${cli_list_mode:-0}" -eq 1 ]; then
    _build_all_tasks
    menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    cli_list_tasks
    exit 0
fi
# An alias that points to a task name (not to a profile) executes the task
# from the current config — the alias file template documents exactly that
# ("alias_name=actual_task_name").
if [ -n "$_alias_task" ]; then
    _build_all_tasks
    menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    cli_run_task "$_alias_task"
    exit $?
fi
if [ -n "${cli_run_query:-}" ]; then
    _build_all_tasks
    menu_options=("${ALL_TASKS_ARRAY[@]+"${ALL_TASKS_ARRAY[@]}"}")
    cli_run_task "$cli_run_query"
    exit $?
fi

# Load menu options once before loop
_build_menu_options
menu_options=("${MENU_RESULT_ARRAY[@]+"${MENU_RESULT_ARRAY[@]}"}")
num=${#menu_options[@]}
calculate_layout "$num"; rows=$_layout_rows; cols=$_layout_cols
redraw_needed=1

# Main interactive loop is in 13-ui.sh
main_interactive_loop
