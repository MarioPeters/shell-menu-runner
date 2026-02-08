# Contributing to Shell Menu Runner

Thank you for your interest in contributing! This document provides guidelines and instructions.

## How to Contribute

### Reporting Bugs

1. Check if the issue already exists in GitHub Issues
2. Include OS, Bash version, and steps to reproduce
3. Provide expected vs actual behavior
4. Include relevant error messages or logs

### Suggesting Features

1. Describe the use case and expected behavior
2. Explain why this feature is valuable
3. Provide examples if applicable
4. Check compatibility with existing features

### Submitting Code

#### Prerequisites

- Bash 3.2+ compatibility
- Zero external dependencies (no curl/wget for core features)
- Full backward compatibility with existing .tasks files

#### Before You Start

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/short-name`
3. Make your changes
4. Test thoroughly

#### Code Quality Checklist

```bash
# Syntax validation (MUST PASS)
bash -n run.sh

# Linting (MUST have 0 errors, 0 warnings)
shellcheck -x run.sh

# Functionality test
./run.sh --help
./run.sh --validate demo

# No breaking changes
# Does your change affect existing .tasks files?
# Can users upgrade without updating their profiles?
```

#### Coding Standards

- Follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- Use `"${var}"` not `$var` (prevent word splitting)
- Quote command substitutions: `"$(command)"`
- Use `[[ ]]` for conditionals, `[ ]` only in POSIX mode
- Comment non-obvious logic
- Keep functions small and focused
- Use meaningful variable names

#### Commit Style

```
feat: Add progress bar for long-running tasks
fix: Correct profile cache invalidation
refactor: Extract color helpers to function
docs: Update README with examples
test: Add validation for special characters
```

#### Writing Tests

Test your changes with:

- Different profile sizes (empty, large)
- Special characters in task names/commands
- Deep nesting (multiple submenu levels)
- Long lines (>100 chars)
- Edge cases (no .tasks file, read-only config)

#### Documentation

- Update README.md if behavior changes
- Add examples for new features
- Document environment variables
- Update CHANGELOG.md with your change

### Pull Request Process

1. **Create PR with clear description**

   ```
   Title: feat: Add progress bar for tasks

   Description:
   - Adds visual % progress during execution
   - Parses [progress:x%] markers in output
   - Works with all task types

   Fixes: #123
   ```

2. **Pass all checks**
   - Syntax: `bash -n run.sh` ✅
   - Linting: `shellcheck -x run.sh` (0 errors) ✅
   - Functionality: `./run.sh --help` ✅
   - Tests: Manual verification ✅

3. **Link related issues**
   - Use `Fixes #123` to auto-close on merge
   - Reference discussions with `See #456`

4. **Be responsive**
   - Address review feedback promptly
   - Explain decisions and tradeoffs
   - Update based on suggestions

## Development Tips

### Local Testing

```bash
# Test with a demo profile
cd /tmp
echo "0|Echo|echo 'Hello'|Test" > .tasks.demo
/path/to/run.sh --validate demo

# Test with real .tasks file
cd your-project
/path/to/run.sh --init  # Creates .tasks
/path/to/run.sh         # Run interactively
```

### Debugging

```bash
# Enable debug mode
RUN_DEBUG=1 ./run.sh
set -x  # For bash tracing

# Check cache
ls -la /tmp/run_cache_$$

# Validate syntax before running
bash -n run.sh
```

### Performance Profiling

```bash
# Measure startup time
time ./run.sh --list-profiles

# Test with many tasks (create large .tasks)
python3 -c "for i in range(1000): print(f'0|Task {i}|echo {i}|Test')" > .tasks.large
time ./run.sh --validate large
```

## Release Process

**Maintainers only:**

```bash
./scripts/release.sh              # Interactive menu
./scripts/release.sh --help       # Show options
./scripts/release.sh --release    # Automated release
```

The script handles:

- Version bumping (patch, minor, major)
- SHA256 checksum calculation
- Git tagging
- CHANGELOG generation from commits
- GitHub release creation

## Questions?

- Check README.md for documentation
- Search GitHub Issues for similar questions
- Review CHANGELOG.md for recent changes
- See ai-prompt.txt for project context

## License

By contributing, you agree your work is licensed under MIT (same as project).

---

**Thank you for making Shell Menu Runner better! 🚀**
