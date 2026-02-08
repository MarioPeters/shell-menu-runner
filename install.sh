#!/bin/bash
# MAGIC INSTALLER v1.6.0
REPO_URL="https://raw.githubusercontent.com/MarioPeters/shell-menu-runner/main/run.sh"
COMPLETION_URL="https://raw.githubusercontent.com/MarioPeters/shell-menu-runner/main/completions/_run"
SCRIPT_NAME="run"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
say() { printf "%b\n" "$*"; }

ZSHRC_MODE="auto"  # auto | skip

for arg in "$@"; do
	case "$arg" in
		--no-zshrc)
			ZSHRC_MODE="skip"
			;;
		*)
			;;
	esac
done

TARGET_DIR="/usr/local/bin"
if [ ! -w "$TARGET_DIR" ]; then
	TARGET_DIR="$HOME/.local/bin"
	mkdir -p "$TARGET_DIR"
fi

install_runner() {
	local target_dir="$1"
	if [ -w "$target_dir" ]; then
		curl -fsSL "$REPO_URL" -o "$target_dir/$SCRIPT_NAME"
		chmod +x "$target_dir/$SCRIPT_NAME"
	else
		sudo curl -fsSL "$REPO_URL" -o "$target_dir/$SCRIPT_NAME"
		sudo chmod +x "$target_dir/$SCRIPT_NAME"
	fi
}

append_block() {
	local file="$1"
	local marker="$2"
	local content="$3"

	[ -f "$file" ] || touch "$file"
	if grep -q "$marker" "$file"; then
		return 0
	fi

	printf "\n%s\n" "$content" >> "$file"
	return 1
}

say "${BLUE}=== Shell Menu Runner Installer ===${NC}"
say "Installiere nach ${BLUE}$TARGET_DIR${NC}..."
if install_runner "$TARGET_DIR"; then
	say "${GREEN}✔ Installiert.${NC} Tippe 'run'."
else
	say "${BLUE}Hinweis:${NC} Installation fehlgeschlagen."
	exit 1
fi
if [ "$TARGET_DIR" = "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$TARGET_DIR:"* ]]; then
	if [ "$ZSHRC_MODE" = "skip" ]; then
		example_cmd="echo \"export PATH=\\\"${TARGET_DIR}:\\\$PATH\\\"\" >> ~/.zshrc"
		say "${BLUE}Hinweis:${NC} Füge ${TARGET_DIR} zu deinem PATH hinzu, z.B. via '${example_cmd}'"
	else
		path_block="# shell-menu-runner PATH\nexport PATH=\"${TARGET_DIR}:\$PATH\""
		if append_block "$HOME/.zshrc" "# shell-menu-runner PATH" "$path_block"; then
			say "${BLUE}Hinweis:${NC} PATH ist bereits in ~/.zshrc gesetzt."
		else
			say "${GREEN}✔ PATH wurde in ~/.zshrc eingetragen.${NC}"
		fi
		if append_block "$HOME/.bashrc" "# shell-menu-runner PATH" "$path_block"; then
			say "${BLUE}Hinweis:${NC} PATH ist bereits in ~/.bashrc gesetzt."
		else
			say "${GREEN}✔ PATH wurde in ~/.bashrc eingetragen.${NC}"
		fi
	fi
fi

# Install Zsh completion
if command -v zsh >/dev/null 2>&1; then
	echo -e "\n${BLUE}Installing Zsh completion...${NC}"
	ZSH_COMPLETION_DIR="$HOME/.zsh/completions"
	mkdir -p "$ZSH_COMPLETION_DIR"
	if curl -fsSL "$COMPLETION_URL" -o "$ZSH_COMPLETION_DIR/_run"; then
		echo -e "${GREEN}✔ Zsh completion installed${NC}"
		echo -e "${BLUE}Hinweis:${NC} Starten Sie Zsh neu oder führen Sie 'exec zsh' aus um Autocompletion zu aktivieren"

		ZSHRC="$HOME/.zshrc"
		if [ "$ZSHRC_MODE" = "skip" ]; then
			say "${BLUE}Hinweis:${NC} ~/.zshrc Anpassung uebersprungen (--no-zshrc)."
		else
			completion_block="# shell-menu-runner completion\nfpath=(\"$HOME/.zsh/completions\" \$fpath)\nautoload -Uz compinit\ncompinit"
			if append_block "$ZSHRC" "# shell-menu-runner completion" "$completion_block"; then
				say "${BLUE}Hinweis:${NC} Zsh completion ist bereits in ~/.zshrc gesetzt."
			else
				say "${GREEN}✔ ~/.zshrc aktualisiert (Completion).${NC}"
			fi
		fi
	else
		echo -e "${BLUE}Hinweis:${NC} Zsh completion konnten nicht heruntergeladen werden (optional)"
	fi
fi

# Install default profile templates
echo -e "\n${BLUE}Installing default profile templates...${NC}"
mkdir -p "$HOME"
if [ ! -f "$HOME/.tasks.git" ]; then
	cat > "$HOME/.tasks.git" <<'EOF'
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
	echo -e "${GREEN}✔ ~/.tasks.git created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.git exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.docker" ]; then
	cat > "$HOME/.tasks.docker" <<'EOF'
# Shell Menu Runner Docker Tasks
# TITLE: DOCKER
0|🐳 Up|docker-compose up -d|Start containers
0|🐳 Down|docker-compose down|Stop containers
0|🐳 Logs|docker-compose logs -f --tail=200|Follow logs
0|🐳 Restart|docker-compose restart|Restart containers
0|🐳 Ps|docker-compose ps|Show status
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.docker created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.docker exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.k8s" ]; then
	cat > "$HOME/.tasks.k8s" <<'EOF'
# Shell Menu Runner Kubernetes Tasks
# TITLE: K8S
0|☸️  Contexts|kubectl config get-contexts|List contexts
0|☸️  Context Use|kubectl config use-context "<<Context>>"|Switch context
0|☸️  Namespaces|kubectl get ns|List namespaces
0|☸️  Pods|kubectl get pods -A|List all pods
0|☸️  Describe Pod|kubectl describe pod "<<Pod>>" -n "<<Namespace>>"|Describe pod
0|☸️  Logs|kubectl logs -f "<<Pod>>" -n "<<Namespace>>"|Follow logs
0|☸️  Services|kubectl get svc -A|List services
0|☸️  Deployments|kubectl get deploy -A|List deployments
0|☸️  Rollout Status|kubectl rollout status deploy/"<<Deployment>>" -n "<<Namespace>>"|Rollout status
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.k8s created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.k8s exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.deploy" ]; then
	cat > "$HOME/.tasks.deploy" <<'EOF'
# Shell Menu Runner Deploy Tasks
# TITLE: DEPLOY
0|🚀 Deploy|./deploy.sh "<<Environment>>"|Run deploy script
0|🧪 Smoke Test|./scripts/smoke_test.sh "<<Environment>>"|Post-deploy smoke test
0|🔁 Rollback|./scripts/rollback.sh "<<Environment>>"|Rollback deployment
0|📋 Status|./scripts/deploy_status.sh "<<Environment>>"|Deployment status
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.deploy created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.deploy exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.db" ]; then
	cat > "$HOME/.tasks.db" <<'EOF'
# Shell Menu Runner Database Tasks
# TITLE: DB
0|🗄 psql|psql "<<Connection string>>"|Connect with psql
0|🗄 mysql|mysql "<<Connection string>>"|Connect with mysql
0|🗄 sqlite|sqlite3 "<<DB file>>"|Open sqlite
0|🗄 pg dump|pg_dump "<<Connection string>>" > "<<Dump file>>"|Backup Postgres
0|🗄 mysql dump|mysqldump "<<Connection string>>" > "<<Dump file>>"|Backup MySQL
0|🧱 Migrate|./scripts/migrate.sh "<<Environment>>"|Run migrations
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.db created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.db exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.devops" ]; then
	cat > "$HOME/.tasks.devops" <<'EOF'
# Shell Menu Runner DevOps Tasks
# TITLE: DEVOPS
0|🧰 Terraform Init|terraform init|Initialize terraform
0|🧰 Terraform Plan|terraform plan|Show plan
0|🧰 Terraform Apply|terraform apply|Apply changes
0|🧰 Terraform Fmt|terraform fmt -recursive|Format code
0|🧰 Terraform Validate|terraform validate|Validate config
0|🧰 Ansible Ping|ansible all -m ping -i "<<Inventory>>"|Ping hosts
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.devops created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.devops exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.server" ]; then
	cat > "$HOME/.tasks.server" <<'EOF'
# Shell Menu Runner Server Management Tasks
# TITLE: SERVER
0|📊 System Info|uname -a|System information
0|💾 Disk Usage|df -h|Disk space overview
0|🔥 Load Average|uptime|System load
0|👥 Users|who|Connected users
0|📦 List Packages|apt list --installed|List packages
0|📦 Update|sudo apt update && sudo apt upgrade -y|Update packages [!]
0|🔌 Services|systemctl list-units --state=failed --all|Show failed services
0|🔌 Start Service|sudo systemctl start "<<Service>>"|Start service name
0|🔌 Stop Service|sudo systemctl stop "<<Service>>"|Stop service [!]
0|🔌 Restart Service|sudo systemctl restart "<<Service>>"|Restart service [!]
0|📜 Journalctl|journalctl -u "<<Service>>" -f|Follow service logs
0|🧹 Cleanup|sudo apt autoremove -y && sudo apt clean -y|Cleanup packages [!]
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.server created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.server exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.nginx" ]; then
	cat > "$HOME/.tasks.nginx" <<'EOF'
# Shell Menu Runner NGINX Tasks
# TITLE: NGINX
0|🌐 Config Test|nginx -t|Validate nginx config
0|🌐 Reload|sudo nginx -s reload|Reload without restart
0|🌐 Restart|sudo systemctl restart nginx|Restart nginx [!]
0|🌐 Status|sudo systemctl status nginx|NGINX status
0|🌐 Logs Access|tail -f /var/log/nginx/access.log|Follow access logs
0|🌐 Logs Error|tail -f /var/log/nginx/error.log|Follow error logs
0|🌐 SSL Check|openssl x509 -in "<<Cert path>>" -text -noout|Check SSL cert
0|🌐 Enable Site|sudo ln -s /etc/nginx/sites-available/"<<Site>>" /etc/nginx/sites-enabled/|Enable site [!]
0|🌐 Reload After Edit|sudo nginx -t && sudo nginx -s reload|Test & reload
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.nginx created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.nginx exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.portainer" ]; then
	cat > "$HOME/.tasks.portainer" <<'EOF'
# Shell Menu Runner Portainer Tasks
# TITLE: PORTAINER
0|🔗 API Token|curl localhost:9000/api/auth -X POST -d "username=admin&password="<<Password>>""|Get API token
0|📋 List Containers|curl -H "Authorization: Bearer <<Token>>" localhost:9000/api/containers/json|List containers
0|🐳 Container Stats|curl -H "Authorization: Bearer <<Token>>" localhost:9000/api/containers/"<<Container>>/stats"|Get container stats
0|📊 List Images|curl -H "Authorization: Bearer <<Token>>" localhost:9000/api/images/json|List images
0|🔌 Endpoint Status|curl -s http://localhost:9000/api/endpoints|Check endpoint health
0|📦 Pull Image|curl -H "Authorization: Bearer <<Token>>" -X POST localhost:9000/api/images/pull -d "image=<<Image>>""|Pull Docker image [!]
0|🧹 Prune|docker image prune -a -f|Remove unused images [!]
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.portainer created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.portainer exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.mailcow" ]; then
	cat > "$HOME/.tasks.mailcow" <<'EOF'
# Shell Menu Runner mailcow Tasks
# TITLE: MAILCOW
0|📧 API Token|curl -X POST https://<<Domain>>/api/v1/get-token -d "username=<<User>>&password=<<Pass>>"|Get API token [!]
0|📧 List Domains|curl -H "X-API-Key: <<Key>>" https://<<Domain>>/api/v1/get/domain/all|List domains
0|📧 List Users|curl -H "X-API-Key: <<Key>>" https://<<Domain>>/api/v1/get/mailbox/all|List mailboxes
0|🔐 Add User|curl -X POST -H "X-API-Key: <<Key>>" https://<<Domain>>/api/v1/add/mailbox|Add mailbox [!]
0|💾 Backup|cd /opt/mailcow && sudo ./helper-scripts/backup_mailcow.sh|Create backup [!]
0|🔄 Restart|cd /opt/mailcow && sudo docker-compose restart|Restart mailcow [!]
0|📜 Logs|cd /opt/mailcow && sudo docker-compose logs -f|Follow logs
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.mailcow created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.mailcow exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.maint" ]; then
	cat > "$HOME/.tasks.maint" <<'EOF'
# Shell Menu Runner Maintenance Tasks
# TITLE: MAINTENANCE
0|📨 Mails|sudo exim -bp|Show mail queue
0|📨 Remove Mails|sudo exim -bp | awk '{print $3}' | xargs -r sudo exim -Mrm|Clear mail queue [!]
0|💾 Clean Disk|sudo apt autoremove -y && sudo apt clean -y && docker system prune -a -f|Full cleanup [!]
0|🗑️  Logs Rotate|sudo logrotate -f /etc/logrotate.conf|Rotate logs [!]
0|🧹 Old Logs|find /var/log -name "*.log.*" -mtime +30 -delete|Delete logs >30d [!]
0|🔍 Disk Check|sudo fsck -n /dev/<<Device>>|Check filesystem [!]
0|🧪 Health Check|./scripts/health_check.sh|System health report
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.maint created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.maint exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.monitor" ]; then
	cat > "$HOME/.tasks.monitor" <<'EOF'
# Shell Menu Runner Monitoring Tasks
# TITLE: MONITORING
0|📊 Metrics|curl http://localhost:9090/api/v1/query?query=<<Metric>>|Query Prometheus
0|🎯 Targets|curl http://localhost:9090/api/v1/targets|Prometheus targets
0|🔔 Alerts|curl http://localhost:9093/api/v1/alerts|Show Alertmanager alerts
0|📈 Grafana Dash|open http://localhost:3000|Open Grafana [!]
0|❤️  Health|curl http://localhost:9090/-/healthy && curl http://localhost:9093/-/healthy|Health checks
0|🔍 Node Metrics|curl http://localhost:9100/metrics | grep node_|Node exporter metrics
0|📝 Check Alert|grep -r "<<Alert>>" /etc/prometheus/alert.rules|Search alert rule
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.monitor created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.monitor exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.ci" ]; then
	cat > "$HOME/.tasks.ci" <<'EOF'
# Shell Menu Runner CI/CD Pipeline Tasks
# TITLE: CI/CD
0|🔄 Trigger|curl -X POST https://<<API>>/trigger -H "Authorization: Bearer <<Token>>" -d "ref=<<Branch>>"|Trigger pipeline
0|📋 Status|curl https://<<API>>/jobs/"<<Job>>" -H "Authorization: Bearer <<Token>>"|Check job status
0|📜 Logs|curl https://<<API>>/jobs/"<<Job>>"/logs -H "Authorization: Bearer <<Token>>"|Fetch job logs
0|🧪 Test Run|act -j test|Run GitHub Actions locally (requires act)
0|🚀 Deploy|curl -X POST https://<<API>>/deploy -H "token: <<Token>>" -d "env=<<Env>>"|Deploy from CI
0|📊 History|curl https://<<API>>/history?limit=10 -H "Authorization: Bearer <<Token>>"|Recent runs
0|✅ Approve|curl -X POST https://<<API>>/jobs/"<<Job>>"/approve -H "token: <<Token>>"|Approve job
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.ci created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.ci exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.aws" ]; then
	cat > "$HOME/.tasks.aws" <<'EOF'
# Shell Menu Runner AWS CLI Tasks
# TITLE: AWS
0|👤 STS Identity|aws sts get-caller-identity|Check AWS identity
0|📋 EC2 List|aws ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name]' --output table|List EC2 instances
0|🚀 EC2 Start|aws ec2 start-instances --instance-ids "<<Instance ID>>"|Start instance
0|🛑 EC2 Stop|aws ec2 stop-instances --instance-ids "<<Instance ID>>"|Stop instance [!]
0|🪣 S3 List Buckets|aws s3 ls|List S3 buckets
0|📁 S3 Upload|aws s3 cp "<<Local File>>" s3://<<Bucket>>/<<Key>>|Upload to S3
0|📥 S3 Download|aws s3 cp s3://<<Bucket>>/<<Key>> "<<Local Path>>"|Download from S3
0|🗄 RDS List|aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceIdentifier,Engine,DBInstanceStatus]' --output table|List RDS instances
0|⚡ Lambda List|aws lambda list-functions --query 'Functions[*].[FunctionName,Runtime,LastModified]' --output table|List Lambda functions
0|🔑 IAM User|aws iam list-users|List IAM users
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.aws created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.aws exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.test" ]; then
	cat > "$HOME/.tasks.test" <<'EOF'
# Shell Menu Runner Testing Tasks
# TITLE: TESTING
0|🧪 Unit Tests|npm test -- <<Pattern>>|Run unit tests
0|📊 Coverage|npm test -- --coverage|Generate coverage report
0|🔄 Watch Mode|npm test -- --watch|Run tests in watch mode
0|🏃 Integration|npm run test:integration|Run integration tests
0|🧬 E2E Tests|npm run test:e2e|Run E2E tests
0|📈 Coverage Report|open ./coverage/index.html|Open coverage report [!]
0|🐛 Debug Test|node --inspect-brk node_modules/.bin/jest --runInBand "<<Test File>>"|Debug specific test
0|📋 Test List|npm test -- --listTests|List all test files
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.test created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.test exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.lint" ]; then
	cat > "$HOME/.tasks.lint" <<'EOF'
# Shell Menu Runner Linting & Code Quality Tasks
# TITLE: LINT
0|📝 ESLint|npx eslint "<<File/Pattern>>" --fix|Run ESLint
0|💅 Prettier|npx prettier --write "<<File/Pattern>>"|Format code
0|🔍 SonarQube|sonar-scanner -Dsonar.projectKey=<<Key>> -Dsonar.sources=.|SonarQube scan
0|📊 Complexity|npx jscpd "<<Directory>>"|Find code duplication
0|🧹 Stylelint|npx stylelint "<<File/Pattern>>" --fix|Lint CSS
0|🐍 Black (Python)|black "<<File/Pattern>>"|Format Python
0|🐍 Flake8 (Python)|flake8 "<<File/Pattern>>"|Python linter
0|📦 Depcheck|npx depcheck|Check unused dependencies
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.lint created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.lint exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.sec" ]; then
	cat > "$HOME/.tasks.sec" <<'EOF'
# Shell Menu Runner Security Scanning Tasks
# TITLE: SECURITY
0|🔒 Trivy Scan|trivy image "<<Image>>"|Scan Docker image for vulnerabilities
0|🔓 Snyk Test|snyk test --severity-threshold=high|Check dependencies for vulns
0|🔐 SSL Check|echo | openssl s_client -servername "<<Domain>>" -connect "<<Domain>>:443"|Check SSL certificate
0|📋 OWASP|npx npm-audit --json|OWASP dependency check
0|🔑 Vault Seal|vault operator seal|Seal Vault [!]
0|🔓 Vault Unseal|vault operator unseal "<<Key>>"|Unseal Vault
0|📝 Git Secrets|git-secrets --scan|Scan for secrets in git
0|🛡️  SCA Scan|syft "<<Image/Path>>" -o json > sbom.json|Generate SBOM
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.sec created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.sec exists (skipped)"
fi

if [ ! -f "$HOME/.tasks.build" ]; then
	cat > "$HOME/.tasks.build" <<'EOF'
# Shell Menu Runner Build & Release Tasks
# TITLE: BUILD
0|📦 Build|npm run build|Build project
0|📋 Build Info|npm run build -- --verbose|Build with verbose output
0|🐳 Docker Build|docker build -t "<<Registry>>/<<Image>>:<<Tag>>" .|Build Docker image
0|⬆️  Docker Push|docker push "<<Registry>>/<<Image>>:<<Tag>>"|Push to registry [!]
0|🔖 Version Bump|npm version "<<major|minor|patch>>"|Bump version
0|📝 Changelog|conventional-changelog -p angular -i CHANGELOG.md -s|Generate changelog
0|🏷️  Tag Release|git tag -a "v<<Version>>" -m "Release v<<Version>>"  && git push --tags|Create git tag
0|📦 Create Release|gh release create "v<<Version>>" --generate-notes|Create GitHub release [!]
0|❌ Exit|EXIT|Back
EOF
	echo -e "${GREEN}✔ ~/.tasks.build created${NC}"
else
	echo -e "${BLUE}Hinweis:${NC} ~/.tasks.build exists (skipped)"
fi

echo -e "\n${GREEN}=== Installation komplett! ===${NC}"
