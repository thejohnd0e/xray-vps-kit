#!/usr/bin/env bash
# The curl-pipe bootstrap block must be identical in every entry script (tests/test-packaging.sh
# checks it). tools/bootstrap.block.in is the single source; this rewrites the block in
# install.sh, update.sh, uninstall.sh and auto-update.sh, or with --check only reports drift.
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
template=$project/tools/bootstrap.block.in
check=false
[[ ${1:-} != --check ]] || check=true
status=0
for script in install.sh update.sh uninstall.sh auto-update.sh; do
    file=$project/$script
    start=$(grep -n -m 1 '^# Started through `curl' "$file" | cut -d: -f1)
    end=$(awk -v start="$start" 'NR > start && /^fi$/ {print NR; exit}' "$file")
    [[ -n $start && -n $end ]] || { printf 'no bootstrap block in %s\n' "$script" >&2; exit 1; }
    output=$(mktemp)
    {
        head -n $((start - 1)) "$file"
        sed "s/@SCRIPT@/$script/g" "$template"
        tail -n +$((end + 1)) "$file"
    } > "$output"
    if cmp -s "$output" "$file"; then
        rm -f "$output"
    elif [[ $check == true ]]; then
        printf 'bootstrap block out of date: %s\n' "$script" >&2; status=1; rm -f "$output"
    else
        cat "$output" > "$file"; rm -f "$output"; printf 'updated %s\n' "$script"
    fi
done
exit "$status"
