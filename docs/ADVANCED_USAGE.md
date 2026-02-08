# ⚡ Advanced Usage Guide

Power-user recipes, patterns, and best practices.

---

## Table of Contents

1. [Task Organization Patterns](#task-organization-patterns)
2. [Advanced Task Dependencies](#advanced-task-dependencies)
3. [Multi-Profile Workflows](#multi-profile-workflows)
4. [Progress Monitoring](#progress-monitoring)
5. [Environment & Secrets](#environment--secrets)
6. [Performance Optimization](#performance-optimization)
7. [CI/CD Integration](#cicd-integration)
8. [Custom Scripts & Automation](#custom-scripts--automation)

---

## Task Organization Patterns

### Pattern 1: Hierarchical Projects

Split large projects into profile-based views:

```
Project Root/
├── .tasks           # Core/shared tasks
├── .tasks.dev       # Development tasks
├── .tasks.deploy    # Deployment tasks
├── .tasks.test      # Testing tasks
└── .tasks.ops       # Operations tasks
```

**Usage:**

```bash
run dev      # Development mode
run deploy   # Deployment mode
run test     # Testing mode
```

**Benefits:**

- Cleaner menu with fewer tasks
- Role-based access control (ops team uses .tasks.ops only)
- Easier onboarding for new team members
- Faster menu load time

---

### Pattern 2: Environment-Based Profiles

Create profiles per environment:

```bash
# .tasks.prod
0|DB Backup|pg_dump production_db > backup.sql|Backup production DB
1|Deploy Web|docker push app:prod && kubectl apply -f prod.yaml|Deploy to prod
2|Health Check|curl -f https://app.prod.com/health|Check prod health

# .tasks.staging
0|DB Backup|pg_dump staging_db > backup.sql|Backup staging DB
1|Deploy Web|docker push app:staging && kubectl apply -f staging.yaml|Deploy to staging
2|Health Check|curl -f https://app.staging.com/health|Check staging health
```

**Usage:**

```bash
run prod      # Production environment
run staging   # Staging environment
```

---

### Pattern 3: Service-Based Profiles

Organize by service/component:

```
.tasks.auth     # Authentication service
.tasks.api      # Main API service
.tasks.worker   # Background worker service
.tasks.frontend # Frontend service
```

**Cross-service coordination:**

```bash
# .tasks (root - coordinates all services)
0|Deploy All|run --across auth,api,worker deploy|Deploy all services
1|Test All|run --across auth,api,worker test|Test all services
2|Status|run --across auth,api,worker status|Check all services
```

**Usage:**

```bash
run              # See all services
run auth         # Deploy only auth
run --across auth,api deploy   # Deploy auth+api
```

---

## Advanced Task Dependencies

### Pattern: Dependency Chains

Create task chains with auto-execution:

```bash
# .tasks.deploy
0|Build|npm run build|Build application
1|Test|npm run test depends:0|Run tests (after build)
2|Push|docker push app:v1 depends:1|Push image (after tests)
3|Deploy|kubectl apply -f app.yaml depends:2|Deploy (after push)
```

**Result:** Running task #3 auto-runs #0→#1→#2→#3 in sequence

---

### Pattern: Parallel Dependencies

Run independent tasks in parallel:

```bash
# .tasks.test
0|Lint|npm run lint|Lint code
1|Unit Tests|npm run test:unit|Unit tests
2|Type Check|npm run type-check|Check types
3|Full Suite|npm run test:coverage depends:0,1,2 --parallel|Run all (parallel)
```

**Execution:**

```bash
export RUN_PARALLEL_DEPS=1   # Enable parallel mode
run
# Select task #3 → runs #0, #1, #2 simultaneously
```

**Benefits:**

- 50% faster test suite (if I/O bound)
- Better resource utilization
- Automatic rollback on failure

---

### Pattern: Composite Tasks

Group related tasks:

```bash
# .tasks
0|Setup|npm install && npm run build|Initial setup
1|Local Dev|npm run dev|Start local dev server
2|Test & Build|npm run test && npm run build|Test + Build (with deps)
3|Deploy Full|./scripts/deploy.sh depends:2|Deploy after test+build
```

---

## Multi-Profile Workflows

### Pattern 1: Across-Profile Deployment

Deploy to multiple environments in one command:

```bash
run --across staging,prod deploy

# Equivalent to:
# - Load .tasks.staging and run 'deploy'
# - Load .tasks.prod and run 'deploy'
# - Show results for both
```

**Use Case:** Canary deployments

```bash
# .tasks.canary
0|Deploy|docker push app:v1 && kubectl apply -f canary.yaml|Deploy 5% traffic

# Then later:
run --across canary,prod deploy  # Deploy canary, then full prod
```

---

### Pattern 2: Parallel Multi-Profile

Execute across profiles in parallel:

```bash
# Set parallel flag
export RUN_PARALLEL_MULTI=1

# Deploy to 3 backends simultaneously
run --across backend1,backend2,backend3 deploy

# Shows status: ✓ backend1 ✓ backend2 ✓ backend3
```

**Configuration in .runrc:**

```bash
# Default: sequential execution
# Set to parallel:
RUN_PARALLEL_MULTI=1
```

---

### Pattern 3: Cascading Profiles

Chain profiles together:

```bash
# .tasks.main (orchestrator)
0|Build All|run dev build && run prod build|Build dev+prod
1|Test Dev|run dev test|Test dev
2|Deploy Dev|run dev deploy depends:1|Deploy dev (after test)
3|Deploy Prod|run prod deploy depends:2|Deploy prod (after dev)
```

**Result:** Single `run` → full deployment pipeline

---

## Progress Monitoring

### Pattern 1: Progress Markers in Script

Add visual feedback for long-running tasks:

```bash
# .tasks
0|Long Process|./scripts/long_process.sh|Process 1000 items

# scripts/long_process.sh:
#!/bin/bash
total=1000
for i in $(seq 1 $total); do
    # Do work...
    if (( i % 100 == 0 )); then
        echo "[progress:$i/$total]"  # Update progress
    fi
done
echo "[progress:$total/$total]"      # Final update
echo "Done!"
```

**Result:**

```
[========--------] 50%  [progress output]
[==============--] 90%  [progress output]
[================] 100% [progress output]
Done!
```

---

### Pattern 2: Multi-Stage Progress

Track multiple stages:

```bash
# scripts/multi_stage.sh
#!/bin/bash

echo "Stage 1: Downloading..."
for i in {1..30}; do
    ((i % 10 == 0)) && echo "[progress:$((i * 3))%]"
    # Download work
done

echo "Stage 2: Processing..."
for i in {1..40}; do
    ((i % 10 == 0)) && echo "[progress:$((30 + i * 2))%]"
    # Process work
done

echo "Stage 3: Uploading..."
for i in {1..30}; do
    ((i % 10 == 0)) && echo "[progress:$((70 + i))%]"
    # Upload work
done

echo "[progress:100%]"
echo "All done!"
```

---

### Pattern 3: Conditional Progress

Update only for long tasks:

```bash
# .tasks
0|Quick Task|echo "Done"|Fast (no progress)
1|Slow Task|./scripts/monitor.sh 60|Slow (with progress)

# scripts/monitor.sh:
#!/bin/bash
duration=${1:-60}
for i in $(seq 0 $duration); do
    echo "[progress:$((i*100/duration))%]"
    sleep 1
done
echo "[progress:100%]"
```

---

## Environment & Secrets

### Pattern 1: .env File Management

Auto-load environment variables:

```bash
# Create .env in project root
DATABASE_URL=postgresql://localhost/mydb
API_KEY=sk_test_xxx
NODE_ENV=development
```

**Features:**

- Auto-loaded before task execution
- Not committed to git (add to .gitignore)
- Override via shell: `export API_KEY=...`

### Pattern 2: Profile-Specific Env

Different .env per profile:

```bash
# .env.prod (production)
DATABASE_URL=postgresql://prod.example.com/db
API_KEY=sk_prod_xxx
LOG_LEVEL=info

# .env.dev (development)
DATABASE_URL=postgresql://localhost/db
API_KEY=sk_test_xxx
LOG_LEVEL=debug
```

**Loading:**

```bash
# .tasks uses global .env
# .tasks.prod uses .env.prod (if exists)
# .tasks.dev uses .env.dev (if exists)
```

### Pattern 3: Secrets from External Source

Load secrets safely:

```bash
# .tasks.prod
0|Deploy|source <(aws secretsmanager get-secret-value --secret-id prod/vars) && deploy.sh|Deploy prod

# Or use pass/1password:
0|Deploy|source <(pass show work/prod/env) && deploy.sh|Deploy prod
```

---

## Performance Optimization

### Optimization 1: Caching

Enable profile caching for repeated loads:

```bash
# Add to .runrc or shell config
export RUN_CACHE_PROFILES=1
export RUN_CACHE_TTL=300        # 5 minutes

run       # Loads from cache (if fresh)
```

**When to use:**

- Profiles with many tasks (50+)
- Slow storage (network mounts)
- Rapid repeated menu loads

---

### Optimization 2: Profile Preloading

Pre-compile profiles on startup:

```bash
# Add to ~/.bashrc
run --validate &    # Background validation on shell start
```

**Benefit:** First menu open is faster

---

### Optimization 3: Parallel Task Execution

Enable parallel deps by default:

```bash
# Add to ~/.runrc
RUN_PARALLEL_DEPS=1
RUN_PARALLEL_MULTI=1

# Now all dependencies run in parallel automatically
```

**Performance gains:**

- Independent tasks: 2-3x faster
- I/O bound tasks: 10-50x faster
- CPU bound tasks: 1-2x faster (depends on cores)

---

### Optimization 4: Reduce Menu Complexity

Large .tasks → multiple profiles:

```bash
# Before: 200 tasks in .tasks (slow)
# After:
#   - .tasks: 20 core tasks
#   - .tasks.dev: 60 dev tasks
#   - .tasks.ops: 60 ops tasks
#   - .tasks.test: 60 test tasks

# Load only needed profile
run dev      # ~60 tasks, fast load
```

---

## CI/CD Integration

### Pattern 1: GitHub Actions Integration

Use in CI/CD pipelines:

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2

      - name: Setup shell-menu-runner
        run: bash install.sh

      - name: Run tests
        run: run test

      - name: Deploy
        run: run deploy
```

---

### Pattern 2: Non-Interactive Pipeline

Use for automation:

```bash
# Directly call tasks without menu
source .env
bash run.sh --task "Build" --no-menu

# Or use environment:
RUN_PROFILE=ci run build test deploy
```

**Use case:** Headless deployments, CI/CD, cron jobs

---

### Pattern 3: Exit Code Propagation

Ensure CI/CD sees failures:

```bash
# .tasks
0|Build|npm run build|Build (fails on error)
1|Deploy|npm run deploy depends:0|Deploy (skipped if build fails)

# CI sees exit codes:
# - Build fails → exit 1 (build stops)
# - Deploy skipped → exit 0 (respects dependency)
```

---

## Custom Scripts & Automation

### Pattern 1: Wrapper Scripts

Create helper scripts:

```bash
# scripts/task_wrapper.sh
#!/bin/bash
# Wrapper to add logging, error handling, notifications

TASK=$1
START=$(date +%s)

echo "🚀 Starting: $TASK at $(date)"

# Run actual task
if run "$TASK"; then
    DURATION=$(($(date +%s) - START))
    echo "✅ Completed: $TASK in ${DURATION}s"
    notify-send "Task succeeded: $TASK"
else
    DURATION=$(($(date +%s) - START))
    echo "❌ Failed: $TASK after ${DURATION}s"
    notify-send "Task failed: $TASK"
    exit 1
fi
```

**Usage:**

```bash
./scripts/task_wrapper.sh deploy    # Runs with logging
```

---

### Pattern 2: Monitoring Dashboards

Create status dashboard:

```bash
# .tasks.dashboard
0|Show Status|./scripts/status_dashboard.sh|Show live status
1|Alert Log|tail -f /var/log/app.log|Live alerts
2|Redis Monitor|redis-cli monitor|Monitor Redis
3|DB Connections|psql -c "SELECT count(*) FROM pg_stat_activity"|DB connections
```

---

### Pattern 3: Scheduled Tasks

Use cron + shell-menu-runner:

```bash
# Crontab entry
0 2 * * * /usr/local/bin/run --across prod,staging nightly-backup --no-menu

# Or shell function:
schedule_task() {
    local hour=$1
    local minute=$2
    local profile=$3
    local task=$4

    (crontab -l; echo "$minute $hour * * * run --across $profile $task --no-menu") | crontab -
}

schedule_task 2 0 prod nightly-backup
```

---

### Pattern 4: Notification Integration

Add notifications:

```bash
# .tasks
0|Deploy|./scripts/notify_deploy.sh|Deploy with notifications

# scripts/notify_deploy.sh:
#!/bin/bash
echo "[progress:10%]"

if npm run build; then
    notify_slack "✅ Build passed"
    echo "[progress:50%]"
else
    notify_slack "❌ Build failed"
    exit 1
fi

if npm run deploy; then
    notify_slack "✅ Deploy successful"
    echo "[progress:100%]"
else
    notify_slack "❌ Deploy failed"
    exit 1
fi
```

---

## Pro Tips

### Tip 1: Use Hotkeys for Speed

```bash
run              # Shows menu with hotkeys
# Press 1, 2, 3... to execute tasks instantly
# No typing needed!
```

### Tip 2: Task Search/Filter

```bash
run
# Press '/' to search
# Type 'deploy' → filters to deploy-related tasks
# Press Enter → executes
```

### Tip 3: Recently Used Tasks

```bash
run
# Press 'h' for history
# See last 10 executed tasks
# Quick re-run of common tasks
```

### Tip 4: Validate Before Committing

```bash
run --validate      # Check all tasks syntax-valid
# Use in pre-commit hook
```

### Tip 5: Create Task Aliases

```bash
# In .bashrc or .zshrc
alias dbuild='run --across dev,prod build'
alias deploy='run deploy'
alias tests='run test'

# Now use: dbuild, deploy, tests
```

### Tip 6: Combine with Other Tools

```bash
# With fzf for fuzzy search
run | fzf | xargs -I {} run {}

# With watch for continuous monitoring
watch -n 1 'run --status'

# With parallel for batch execution
echo -e "task1\ntask2\ntask3" | parallel run {}
```

---

## Real-World Examples

### Example 1: Microservices Deployment

```bash
# .tasks (coordinator)
0|Deploy All|run --across auth,api,worker deploy --parallel|Deploy all services
1|Health Check|run --across auth,api,worker health|Check all services
2|Rollback|run --across auth,api,worker rollback|Rollback all services

# .tasks.auth (auth service)
0|Build|docker build -t auth:v1 .
1|Test|npm run test
2|Deploy|docker push auth:v1 && kubectl apply -f auth.yaml depends:1
3|Health|curl http://auth:3000/health
4|Rollback|kubectl rollout undo deployment/auth

# .tasks.api (api service)
0|Build|docker build -t api:v1 .
1|Test|npm run test
2|Deploy|docker push api:v1 && kubectl apply -f api.yaml depends:1
3|Health|curl http://api:3000/health
4|Rollback|kubectl rollout undo deployment/api
```

---

### Example 2: DevOps Workflows

```bash
# .tasks.ops
0|Backup DB|pg_dump prod_db > backup_$(date +%Y%m%d).sql|Daily backup
1|Update Packages|sudo apt update && sudo apt upgrade -y|System update
2|Clear Logs|find /var/log -type f -mtime +30 -delete|Cleanup old logs
3|Monitor CPU|top -b -n 1 | head -20|CPU monitoring
4|Check Disk|df -h|Disk usage
5|Full Maintenance|run --across db,app,infra maintenance|Full maintenance
```

---

### Example 3: Frontend Development

```bash
# .tasks.dev
0|Install|npm install|Install dependencies
1|Dev Server|npm run dev|Start dev server
2|Format|npm run format|Format code
3|Lint|npm run lint|Lint code
4|Type Check|npm run type-check|Type checking
5|Unit Tests|npm run test:unit|Unit tests
6|E2E Tests|npm run test:e2e|E2E tests
7|Full Check|npm run format && npm run lint && npm run type-check && npm run test depends:2,3,4,5,6|Full QA

# .tasks (main)
0|Build|npm run build|Production build
1|Preview|npm run preview|Preview production build
2|Deploy|npm run deploy|Deploy to production
```

---

## Best Practices

✅ **Do:**

- Keep .tasks focused (one per profile)
- Use meaningful descriptions
- Set up dependencies for complex workflows
- Enable parallel execution for I/O tasks
- Version control .tasks files
- Test new tasks before committing

❌ **Don't:**

- Put huge scripts inline (use external files)
- Ignore dependency cycles
- Commit .env files with secrets
- Use relative paths (use pwd or $(cd ...))
- Mix multiple profiles in one task
- Forget to quote variables ($1 → "$1")

---

**Next:** See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for debugging guides
