#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for module in common state release render ownership transaction bundle service firewall clients diagnostics install-options preflight install-cleanup install-lifecycle; do
    # shellcheck source=/dev/null
    source "$project/lib/$module.sh"
done
if [[ ${1:-} == --help && $# == 1 ]]; then xvk_install_help; exit 0; fi
xvk_install_options "$@"
xvk_install_preflight "$project"
root=${XVK_ROOT%/}
mkdir -p "$root/run/lock"
xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_install_locked "$project"
