#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers/assert.sh
source "$TESTS_DIR/helpers/assert.sh"
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/release.sh
source "$PROJECT_DIR/lib/release.sh"
# shellcheck source=lib/auto-release.sh
source "$PROJECT_DIR/lib/auto-release.sh"
# shellcheck source=lib/core-update.sh
source "$PROJECT_DIR/lib/core-update.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
curl() { printf '%s\n' "$@" > "$scratch/curl-arguments"; }
xvk_auto_fetch_release "$scratch/metadata"
assert_success 'API query is fixed to the official latest release endpoint' grep -qx 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' "$scratch/curl-arguments"
assert_success 'release metadata is bounded to one MiB' grep -qx 1048576 "$scratch/curl-arguments"
xvk_https_get https://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-linux-64.zip "$scratch/archive" 134217728
assert_success 'opt-in archive download has a 128 MiB hard size limit' grep -qx 134217728 "$scratch/curl-arguments"
assert_success 'archive redirects are restricted to HTTPS' grep -qx -- '--proto-redir' "$scratch/curl-arguments"
: > "$scratch/curl-arguments"
assert_failure 'invalid download size bound is rejected before invoking curl' xvk_https_get https://github.com/XTLS/Xray-core/ "$scratch/archive" invalid
assert_eq '' "$(cat "$scratch/curl-arguments")" 'invalid bound makes no network call'
timeout() { printf '%s\n' "$@" > "$scratch/timeout-arguments"; return 124; }
assert_failure 'timed-out extraction/version command reports failure' xvk_core_extract_bounded "$scratch/lock" amd64 "$scratch/archive" "$scratch/output"
assert_success 'extraction and version inspection have a 45-second timeout' grep -qx 45 "$scratch/timeout-arguments"
assert_success 'stuck upstream processes have a hard kill deadline' grep -qx -- '--kill-after=5' "$scratch/timeout-arguments"
test_finish
