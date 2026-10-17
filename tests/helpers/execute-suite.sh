#!/usr/bin/env bash
set -euo pipefail
if (( $# != 2 )) || [[ ! -f $1 || -L $1 ]]; then
    printf 'Expected a regular suite file and case name\n' >&2
    exit 1
fi
suite_file=$1
selected_case=$2
if LC_ALL=C grep -q $'\r' "$suite_file"; then
    printf 'Refusing CRLF suite\n' >&2
    exit 1
fi
TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PROJECT_DIR=$(cd -- "$TESTS_DIR/.." && pwd -P)
export TESTS_DIR PROJECT_DIR
# shellcheck source=tests/helpers/assert.sh
source "$TESTS_DIR/helpers/assert.sh"
# A suite is sourced only here, at top level. Running source inside an if/!
# condition would disable errexit inside the entire suite.
# shellcheck source=/dev/null
source "$suite_file" "$selected_case"
test_finish
