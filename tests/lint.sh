#!/usr/bin/env bash
# Syntax check and ShellCheck over every shell file the project ships or tests with.
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$project"
command -v shellcheck > /dev/null || { printf 'ShellCheck is required for linting\n' >&2; exit 1; }
files=(install.sh uninstall.sh update.sh auto-update.sh xray-client lib/*.sh tests/*.sh tests/helpers/*.sh tests/fixtures/harness/*.sh tests/vm/*.sh)
for file in "${files[@]}"; do
    bash -n "$file" || { printf 'Syntax error: %s\n' "$file" >&2; exit 1; }
done
shellcheck -x "${files[@]}"
printf 'Lint passed: %d files\n' "${#files[@]}"
