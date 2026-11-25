---
description: Build the project and verify with ShellCheck
---

Run the full build and lint pipeline:

1. Run `./build.sh` to rebuild `run.sh` from `src/`
2. Run `make lint` (rebuilds again and runs ShellCheck with `-x`)
3. Run `bash build-platform/tests/test-runner.sh`
4. Run `bash build-platform/tests/test-docs.sh`
5. Report any errors or warnings found

If lint fails, show the specific ShellCheck errors with file and line number.
