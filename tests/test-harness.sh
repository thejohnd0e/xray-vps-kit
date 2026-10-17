#!/usr/bin/env bash
# Detects swallowed child failures, empty suites and permissive dispatch.
case "${1:-all}" in
    all|runner-contract) ;;
    *) printf 'Unknown harness case\n' >&2; exit 1 ;;
esac

assert_success 'passing child suite succeeds' \
    bash "$TESTS_DIR/helpers/execute-suite.sh" "$TESTS_DIR/fixtures/harness/pass.sh" all
assert_failure 'intentional assertion failure reaches caller' \
    bash "$TESTS_DIR/helpers/execute-suite.sh" "$TESTS_DIR/fixtures/harness/fail.sh" all
assert_failure 'zero assertions cannot pass' \
    bash "$TESTS_DIR/helpers/execute-suite.sh" "$TESTS_DIR/fixtures/harness/empty.sh" all
assert_failure 'unhandled subprocess failure reaches caller' \
    bash "$TESTS_DIR/helpers/execute-suite.sh" "$TESTS_DIR/fixtures/harness/subprocess.sh" all
assert_failure 'pipeline failure reaches caller' \
    bash "$TESTS_DIR/helpers/execute-suite.sh" "$TESTS_DIR/fixtures/harness/pipeline.sh" all
assert_failure 'unknown suite fails' bash "$TESTS_DIR/run.sh" --suite does-not-exist
assert_failure 'missing suite value fails' bash "$TESTS_DIR/run.sh" --suite
assert_failure 'unknown argument fails' bash "$TESTS_DIR/run.sh" --wat
assert_failure 'unknown case fails' bash "$TESTS_DIR/run.sh" --suite harness --case absent
assert_failure 'missing case value fails' bash "$TESTS_DIR/run.sh" --case
assert_failure 'all does not accept a case filter' bash "$TESTS_DIR/run.sh" --suite all --case anything

# Create a CRLF script only in an ephemeral directory. The suite executor must
# reject it before even its first command can execute.
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
# The child, not this parent, must expand the marker variable.
# shellcheck disable=SC2016
printf 'touch -- "$CRLF_MARKER"\r\nassert_eq yes yes marker\r\n' > "$scratch/crlf.sh"
export CRLF_MARKER="$scratch/executed"
assert_failure 'CRLF child is rejected before execution' \
    bash "$TESTS_DIR/helpers/execute-suite.sh" "$scratch/crlf.sh" all
assert_failure 'CRLF fixture executed no commands' test -e "$CRLF_MARKER"
assert_eq 'a b' 'a b' 'assertions preserve whitespace'
