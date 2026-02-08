# Examples Collection

Practical task file examples for different project types.

## Quick Start

1. Find your project type below
2. Copy the corresponding `.tasks` file to your project root
3. Customize commands to match your setup
4. Run `run` to start using tasks

---

## Available Examples

### 1. Node.js Project (`node-project.tasks`)

**Best for:** React, Vue, Svelte, Express, NestJS, Next.js apps

**Includes:**

- Install & setup tasks
- Dev server startup
- Code formatting & linting
- TypeScript type checking
- Unit & E2E testing
- Production build
- Deployment tasks

**Customize:**

```bash
# Replace npm with pnpm if needed
npm run build → pnpm build

# Or yarn
npm install → yarn install
```

---

### 2. Python Project (`python-project.tasks`)

**Best for:** Django, Flask, FastAPI, data science projects

**Includes:**

- Virtual environment setup
- Dependency management
- Code quality (pylint, black, mypy)
- Unit testing with pytest
- Coverage reporting
- Database migrations
- Documentation building
- PyPI deployment

**Customize:**

```bash
# Replace with your package manager
pip → poetry
pytest → unittest
```

---

### 3. DevOps/Kubernetes (`devops-k8s.tasks`)

**Best for:** Kubernetes clusters, container orchestration teams

**Includes:**

- Local Docker Compose development
- Docker image build & push
- Kubernetes deployment to dev/staging/prod
- Monitoring stack (Prometheus, Grafana)
- Cluster management
- Database backups
- Security scanning
- Cleanup tasks

**Customize:**

```bash
# Replace namespace
-n dev → -n production

# Replace registry
registry.example.com → your-registry.com

# Update manifests path
k8s/dev/ → your-k8s-path/
```

---

### 4. Microservices Architecture

#### A. Root Tasks (`microservices-root.tasks`)

**Purpose:** Orchestrate all microservices from one place

**Key features:**

- Build all services in parallel
- Deploy to all services simultaneously
- Cross-service testing
- Unified status & logging
- Rollback all services at once

**Usage:**

```bash
run
# Run "Deploy Prod" → deploys auth + api + worker in parallel
```

#### B. Individual Service (`microservice-service.tasks`)

**Purpose:** Service-specific tasks (copy as `.tasks.<service>`)

**Examples:**

```bash
# Copy as .tasks.auth for auth service
cp microservice-service.tasks .tasks.auth

# Load auth service tasks
run auth

# Or from root
run --across auth,api worker build
```

**Services to create:**

- `.tasks.auth` - Authentication
- `.tasks.api` - Main API
- `.tasks.worker` - Background jobs
- `.tasks.db` - Database

---

### 5. Web Project (`web-project.tasks`)

**Best for:** Full-stack web apps (frontend + backend)

**Includes:**

- Frontend & backend setup
- Separate dev environments
- Code quality for both
- Database management
- Docker Compose setup
- Multi-stage deployment

**Customize:**

```bash
# Adjust paths to your structure
cd frontend → cd packages/frontend
cd backend → cd apps/backend

# Update with your tooling
npm → pnpm / yarn
```

---

## How to Use These Examples

### Step 1: Copy the File

```bash
# For Node.js project
cp docs/examples/node-project.tasks .tasks

# For custom service
cp docs/examples/microservice-service.tasks .tasks.myservice
```

### Step 2: Customize Commands

Edit `.tasks` and update paths/commands:

```bash
# Before
0|Install|npm install|Install dependencies

# After (if using yarn)
0|Install|yarn install|Install dependencies
```

### Step 3: Create Profiles for Complex Projects

```bash
# Copy generic examples and customize
cp docs/examples/microservice-service.tasks .tasks.auth
cp docs/examples/microservice-service.tasks .tasks.api
cp docs/examples/microservices-root.tasks .tasks

# Now you have segregated tasks!
run          # Root orchestration
run auth     # Auth service only
run api      # API service only
```

### Step 4: Test & Validate

```bash
run --validate          # Check syntax
run --help             # List all tasks
run task-name          # Run single task
```

---

## Composition Patterns

### Pattern 1: Start Simple

```bash
# Begin with basic tasks
0|Install|npm install
1|Dev|npm run dev
2|Test|npm run test

# Add more as needed
3|Build|npm run build
4|Deploy|npm run deploy
```

### Pattern 2: Grow with Profiles

```bash
.tasks           # Shared core tasks
.tasks.dev       # Development tasks
.tasks.prod      # Production tasks
.tasks.test      # Testing tasks
```

### Pattern 3: Scale with Microservices

```
.tasks                    # Root orchestration
.tasks.auth              # Auth service
.tasks.api               # API service
.tasks.worker            # Worker service
.tasks.db                # Database service
```

---

## Common Customizations

### Change From npm to pnpm

```bash
# Find & replace
sed -i 's/npm/pnpm/g' .tasks

# Or manually in editor
npm install → pnpm install
```

### Use Different Python Version

```bash
# Change python command
python → python3
python -m pytest → pytest
```

### Update Docker Registry

```bash
registry.example.com → gcr.io/myproject
docker push app:latest → gcr.io/myproject/app:latest
```

### Connect to Different Cluster

```bash
# Update kubectl context
kubectl --context=dev
kubectl --context=prod
```

---

## Profile-Specific Examples

### Development Profile

```bash
# .tasks.dev
0|Install|npm install --save-dev@latest
1|Dev|npm run dev
2|Debug|npm run debug
3|Hot Reload|npm run dev:watch
```

### Deployment Profile

```bash
# .tasks.deploy
0|Build|npm run build
1|Test|npm run test:ci
2|Deploy|./scripts/deploy.sh
3|Verify|./scripts/verify.sh
```

---

## Integration Examples

### GitHub Actions

```yaml
- name: Run tests
  run: run test
```

### Pre-commit Hook

```bash
#!/bin/bash
run lint && run type-check
```

### Cron Job

```bash
0 2 * * * run --across prod backup
```

---

## Troubleshooting Examples

**Q: Commands not found?**

- Check your PATH
- Use full paths: `/usr/local/bin/npm` instead of `npm`

**Q: Profiles not loading?**

- Verify files named `.tasks.name` (not `.tasks_name`)
- Place in project root or home directory

**Q: Tasks too slow?**

- Enable parallel execution
- Split into smaller profiles
- Use caching

**Q: Syntax validation fails?**

- Check pipe characters (`|`) in commands
- Quote arguments properly
- Run `run --validate` for details

---

## Contributing Examples

Want to add more examples? Create a new file:

```bash
# Format: name-type.tasks
git-workflow.tasks
docker-publishing.tasks
database-migration.tasks
```

---

## Related Documentation

- [QUICK_START.md](../QUICK_START.md) - Get started in 5 minutes
- [ADVANCED_USAGE.md](../ADVANCED_USAGE.md) - Power-user patterns
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) - Debug & fix issues
- [README.md](../../README.md) - Full feature reference
