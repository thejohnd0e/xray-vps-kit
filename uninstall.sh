#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for module in common state release render ownership transaction bundle snapshot firewall uninstall-options uninstall-lifecycle; do
    # shellcheck source=/dev/null
    source "$project/lib/$module.sh"
done

if [[ ${1:-} == --help && $# == 1 ]]; then
    xvk_uninstall_help
    exit 0
fi
xvk_uninstall_options "$@"
xvk_uninstall_run
