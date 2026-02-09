# Build Platform Documentation

## Overview

The Shell Menu Runner Build Platform provides a comprehensive build, test, and deployment system for the project.

## Structure

```
build-platform/
├── builder.sh              # Main build orchestrator
├── tests/
│   └── test-runner.sh     # Test suite
├── Dockerfile             # Standard Docker image
├── Dockerfile.multistage  # Optimized multi-stage build
└── docker-compose.yml     # Development environment
```

## Quick Start

### Interactive Menu

```bash
bash build-platform/builder.sh
```

### Command Line

```bash
# Build specific target
bash build-platform/builder.sh build prod

# Run tests
bash build-platform/builder.sh test

# Create packages
bash build-platform/builder.sh package all

# Full CI pipeline
bash build-platform/builder.sh ci
```

## Build Targets

### Development Build

```bash
bash build-platform/builder.sh build dev
```

- Includes debug symbols
- Extended logging enabled
- Source maps preserved
- Output: `dist/run-dev.sh`

### Production Build

```bash
bash build-platform/builder.sh build prod
```

- Optimized and minified
- Comments stripped
- Performance optimized
- Output: `dist/run-prod.sh`

### Minimal Build

```bash
bash build-platform/builder.sh build minimal
```

- Core features only
- Smallest size
- Essential modules
- Output: `dist/run-minimal.sh`

### Docker Build

```bash
bash build-platform/builder.sh build docker
```

- Creates Docker image
- Multi-arch support
- Minimal Alpine base
- Image: `shell-menu-runner:latest`

## Testing

### Run All Tests

```bash
bash build-platform/builder.sh test
```

### Test Categories

- **Unit Tests**: Core functionality
- **Integration Tests**: Component interaction
- **Performance Tests**: Speed benchmarks
- **Regression Tests**: Bug prevention

### Linting

```bash
bash build-platform/builder.sh lint
```

Runs shellcheck on all scripts.

## Packaging

### Create Tarball

```bash
bash build-platform/builder.sh package tarball
```

Creates: `dist/shell-menu-runner-<version>.tar.gz`

### Create Debian Package

```bash
bash build-platform/builder.sh package deb
```

Creates: `dist/shell-menu-runner_<version>_all.deb`

### Create All Packages

```bash
bash build-platform/builder.sh package all
```

## Deployment

### GitHub Releases

```bash
bash build-platform/builder.sh deploy github
```

Prerequisites:

- GitHub CLI (`gh`) installed
- Authenticated with GitHub
- Write access to repository

### Docker Hub

```bash
bash build-platform/builder.sh deploy dockerhub
```

Prerequisites:

- Docker installed
- Logged in to Docker Hub
- Push permissions

## CI/CD Integration

### Full CI Pipeline

```bash
bash build-platform/builder.sh ci
```

Steps:

1. Lint code
2. Run tests
3. Build all targets
4. Create packages
5. Generate checksums

### GitHub Actions

The project includes automated CI/CD workflows:

```yaml
.github/workflows/ci-cd.yml
```

Triggered on:

- Push to `main` or `develop`
- Pull requests
- Release creation

Workflow jobs:

- **lint**: Code quality checks
- **test**: Automated testing
- **build**: Multi-target builds
- **package**: Package creation
- **docker**: Container builds
- **release**: GitHub release creation
- **security**: Vulnerability scanning
- **quality**: Code quality metrics

## Docker Usage

### Build Image

```bash
docker build -t shell-menu-runner:latest -f build-platform/Dockerfile .
```

### Run Container

```bash
docker run -it --rm \
  -v $(pwd):/workspace \
  shell-menu-runner:latest
```

### Development with Docker Compose

```bash
cd build-platform
docker-compose up runner
```

Services:

- `runner`: Interactive development
- `test`: Test execution
- `builder`: Build automation

## Environment Variables

### Build Control

```bash
export BP_SKIP_TESTS=1        # Skip tests during build
export BP_VERBOSE=1           # Enable verbose logging
export BP_NO_COLOR=1          # Disable colored output
```

### Runner Configuration

```bash
export RUN_PARALLEL_DEPS=1    # Enable parallel dependencies
export RUN_CACHE_PROFILES=1   # Cache profile listings
export RUN_FAST_GREP=1        # Optimized grep
export RUN_DEBUG=1            # Debug mode
```

## Advanced Usage

### Custom Build Pipeline

```bash
#!/bin/bash
# custom-build.sh

source build-platform/builder.sh

# Your custom build logic
build_target_prod
run_tests
package_tarball
```

### Continuous Integration

Example `.gitlab-ci.yml`:

```yaml
stages:
  - lint
  - test
  - build
  - deploy

lint:
  stage: lint
  script:
    - bash build-platform/builder.sh lint

test:
  stage: test
  script:
    - bash build-platform/builder.sh test

build:
  stage: build
  script:
    - bash build-platform/builder.sh build all
  artifacts:
    paths:
      - dist/

deploy:
  stage: deploy
  script:
    - bash build-platform/builder.sh deploy github
  only:
    - tags
```

## Troubleshooting

### Build Failures

**Issue**: Build fails with "Permission denied"

```bash
chmod +x build-platform/builder.sh
```

**Issue**: Tests timeout

```bash
export BP_SKIP_TESTS=1
bash build-platform/builder.sh build prod
```

### Docker Issues

**Issue**: Docker build fails

```bash
# Build production first
bash build-platform/builder.sh build prod

# Then build Docker
docker build -f build-platform/Dockerfile .
```

**Issue**: Container permission errors

```bash
# Use root user
docker run --user root -it shell-menu-runner:latest
```

### Package Creation

**Issue**: .deb creation fails

```bash
# Install dpkg-deb
sudo apt-get install dpkg-dev
```

**Issue**: Checksums missing

```bash
bash build-platform/builder.sh ci
```

## Performance Optimization

### Build Cache

The builder uses caching to speed up repeated builds:

- Cache location: `.build-cache/`
- Clear cache: `bash build-platform/builder.sh clean-all`

### Parallel Builds

```bash
# Enable parallel processing
export BP_PARALLEL=4
bash build-platform/builder.sh build all
```

### Incremental Builds

The builder detects changes and rebuilds only modified components.

## Contributing

When adding new build targets:

1. Add function to `builder.sh`:

   ```bash
   build_target_custom() {
       log_step "Building custom target..."
       # Your build logic
       log_success "Custom build complete"
   }
   ```

2. Update menu in `show_menu()`

3. Add to `main()` command handling

4. Document in this README

## Best Practices

### Version Management

- Update VERSION in `run.sh`
- Update CHANGELOG.md
- Create git tag
- Use `scripts/release.sh` for automated releases

### Testing

- Write tests for new features
- Run full test suite before release
- Check performance impact

### Documentation

- Update README.md
- Add examples
- Document breaking changes

## Support

- Issues: https://github.com/MarioPeters/shell-menu-runner/issues
- Discussions: https://github.com/MarioPeters/shell-menu-runner/discussions
- Wiki: https://github.com/MarioPeters/shell-menu-runner/wiki
