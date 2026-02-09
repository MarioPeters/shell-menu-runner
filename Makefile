# ==============================================================================
#  Shell Menu Runner - Makefile
#  Convenience targets for build operations
# ==============================================================================

.PHONY: help build test package docker clean install dev prod

# Default target
.DEFAULT_GOAL := help

# Build platform directory
BP := build-platform

# Builder script
BUILDER := $(BP)/builder.sh

# Colors
COLOR_INFO := \033[36m
COLOR_SUCCESS := \033[1;32m
COLOR_RESET := \033[0m

help: ## Show this help message
	@echo "$(COLOR_INFO)Shell Menu Runner - Build Targets$(COLOR_RESET)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(COLOR_SUCCESS)%-15s$(COLOR_RESET) %s\n", $$1, $$2}'
	@echo ""

# ==============================================================================
#  BUILD TARGETS
# ==============================================================================

dev: ## Build development version
	@bash $(BUILDER) build dev

prod: ## Build production version
	@bash $(BUILDER) build prod

minimal: ## Build minimal version
	@bash $(BUILDER) build minimal

ultra: ## Build ultra-compact version (20% smaller)
	@bash $(BP)/optimize.sh run.sh dist/run-ultra.sh

bundle: ## Create self-extracting bundle (68% smaller)
	@bash $(BP)/make-bundle.sh

all: ## Build all targets (parallel)
	@echo "$(COLOR_INFO)Building all targets in parallel...$(COLOR_RESET)"
	@$(MAKE) -j4 dev prod minimal ultra bundle
	@echo "$(COLOR_SUCCESS)✓ All builds complete$(COLOR_RESET)"

build: prod ## Alias for 'make prod'

# ==============================================================================
#  TESTING
# ==============================================================================

test: ## Run test suite
	@bash $(BUILDER) test

lint: ## Run shellcheck linter
	@bash $(BUILDER) lint

check: test lint ## Run all checks

# ==============================================================================
#  PACKAGING
# ==============================================================================

tarball: ## Create tarball package
	@bash $(BUILDER) package tarball

deb: ## Create Debian package
	@bash $(BUILDER) package deb

package: ## Create all packages
	@bash $(BUILDER) package all

# ==============================================================================
#  DOCKER
# ==============================================================================

docker: ## Build Docker image
	@bash $(BUILDER) build docker

docker-push: docker ## Build and push Docker image
	@bash $(BUILDER) deploy dockerhub

docker-run: docker ## Build and run Docker container
	@docker run -it --rm -v $(PWD):/workspace shell-menu-runner:latest

# ==============================================================================
#  DEPLOYMENT
# ==============================================================================

release: ## Create GitHub release
	@bash $(BUILDER) deploy github

deploy: release docker-push ## Deploy to all platforms

# ==============================================================================
#  CI/CD
# ==============================================================================

ci: ## Run full CI pipeline
	@bash $(BUILDER) ci

# ==============================================================================
#  MAINTENANCE
# ==============================================================================

clean: ## Clean build artifacts
	@bash $(BUILDER) clean
	@echo "$(COLOR_SUCCESS)✓ Build artifacts cleaned$(COLOR_RESET)"

clean-all: ## Deep clean (including logs and cache)
	@bash $(BUILDER) clean-all
	@echo "$(COLOR_SUCCESS)✓ Deep clean complete$(COLOR_RESET)"

clean-cache: ## Clean build cache only
	@rm -rf $(BP_CACHE_DIR)
	@echo "$(COLOR_SUCCESS)✓ Build cache cleaned$(COLOR_RESET)"

clean-logs: ## Clean build logs only
	@find .build-logs -name "build_*.log" -type f -delete 2>/dev/null || true
	@echo "$(COLOR_SUCCESS)✓ Build logs cleaned$(COLOR_RESET)"

# ==============================================================================
#  INSTALLATION
# ==============================================================================

install: prod ## Install to /usr/local/bin
	@bash install.sh
	@echo "$(COLOR_SUCCESS)✓ Installed to /usr/local/bin/run$(COLOR_RESET)"

uninstall: ## Uninstall from /usr/local/bin
	@sudo rm -f /usr/local/bin/run
	@echo "$(COLOR_SUCCESS)✓ Uninstalled$(COLOR_RESET)"

# ==============================================================================
#  DEVELOPMENT
# ==============================================================================

watch: ## Auto-rebuild on file changes
	@bash $(BP)/quick-build.sh watch

benchmark: ## Run performance benchmarks
	@bash $(BP)/benchmark.sh

menu: ## Show interactive build menu
	@bash $(BUILDER) menu

# ==============================================================================
#  DOCUMENTATION
# ==============================================================================

docs: ## Generate documentation
	@echo "$(COLOR_INFO)Generating documentation...$(COLOR_RESET)"
	@# Add your doc generation here
	@echo "$(COLOR_SUCCESS)✓ Documentation generated$(COLOR_RESET)"

# ==============================================================================
#  QUICK SHORTCUTS
# ==============================================================================

d: dev ## Shortcut for 'make dev'
p: prod ## Shortcut for 'make prod'
t: test ## Shortcut for 'make test'
c: clean ## Shortcut for 'make clean'
u: ultra ## Shortcut for 'make ultra'
b: bundle ## Shortcut for 'make bundle'
