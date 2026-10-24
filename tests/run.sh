#!/usr/bin/env bash
set -euo pipefail
tests_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
suite=all
selected_case=all
suite_seen=false
case_seen=false
usage() {
    printf 'Usage: bash tests/run.sh [--suite NAME] [--case NAME]\n'
}
while (( $# )); do
    case $1 in
        --suite|--case)
            if (( $# < 2 )) || [[ -z $2 || $2 == --* ]]; then
                usage >&2; exit 1
            fi
            if [[ $1 == --suite ]]; then
                [[ $suite_seen == false ]] || { usage >&2; exit 1; }
                suite=$2; suite_seen=true
            else
                [[ $case_seen == false ]] || { usage >&2; exit 1; }
                selected_case=$2; case_seen=true
            fi
            shift 2 ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
required=(harness validation release render transaction install clients export-doctor update uninstall e2e coexistence packaging docs auto-update)
if [[ $suite == all ]]; then
    [[ $case_seen == false ]] || { printf 'A case requires an explicit suite\n' >&2; exit 1; }
    suites=("${required[@]}")
else
    found=false
    for candidate in "${required[@]}"; do
        [[ $candidate != "$suite" ]] || found=true
    done
    [[ $found == true ]] || { printf 'Unknown suite\n' >&2; exit 1; }
    suites=("$suite")
fi
# Check the whole selection first: unfinished required suites cannot silently
# turn --suite all into a misleading green partial run.
for name in "${suites[@]}"; do
    [[ -f $tests_dir/test-$name.sh ]] || { printf 'Missing required suite: %s\n' "$name" >&2; exit 1; }
done
for name in "${suites[@]}"; do
    printf 'Suite: %s; case: %s\n' "$name" "$selected_case"
    bash "$tests_dir/helpers/execute-suite.sh" "$tests_dir/test-$name.sh" "$selected_case"
done
