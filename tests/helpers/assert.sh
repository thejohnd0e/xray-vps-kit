#!/usr/bin/env bash
# Labels, never compared values/command arguments, are printed: callers may
# compare ephemeral credentials without leaking them into CI transcripts.
TEST_ASSERTIONS=0
TEST_FAILURES=0

assert_result() {
    local status=$1 label=$2
    TEST_ASSERTIONS=$((TEST_ASSERTIONS + 1))
    if (( status == 0 )); then
        printf 'ok %s - %s\n' "$TEST_ASSERTIONS" "$label"
    else
        TEST_FAILURES=$((TEST_FAILURES + 1))
        printf 'not ok %s - %s\n' "$TEST_ASSERTIONS" "$label" >&2
        return 1
    fi
}

assert_eq() {
    local status=0
    [[ $1 == "$2" ]] || status=1
    assert_result "$status" "$3"
}

assert_success() {
    local label=$1 status=0
    shift
    "$@" > /dev/null 2>&1 || status=$?
    assert_result "$status" "$label"
}

assert_failure() {
    local label=$1 status=1
    shift
    if "$@" > /dev/null 2>&1; then
        status=1
    else
        status=0
    fi
    assert_result "$status" "$label"
}

test_finish() {
    printf 'Assertions: %s; failures: %s\n' "$TEST_ASSERTIONS" "$TEST_FAILURES"
    (( TEST_ASSERTIONS > 0 && TEST_FAILURES == 0 ))
}
