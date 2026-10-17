#!/usr/bin/env bash
set -euo pipefail
# Started through `curl ... | bash` (no kit checkout beside this script): fetch the kit into
# /opt/xray-vps-kit-src (or fast-forward the clone there) and continue from that copy.
if [[ ! -f ${BASH_SOURCE[0]:-} || ! -f $(dirname -- "${BASH_SOURCE[0]:-/}")/lib/common.sh ]]; then
    src=${XVK_SRC:-/opt/xray-vps-kit-src}
    cd /
    [[ -n ${XVK_SRC:-} || $EUID == 0 ]] || { printf 'error: run as root
' >&2; exit 1; }
    command -v git > /dev/null || { apt-get update -qq && apt-get install -y -qq git ca-certificates > /dev/null; }
    if [[ -d $src/.git ]]; then
        git -C "$src" pull --ff-only -q || { printf 'error: cannot fast-forward %s (local changes?)
' "$src" >&2; exit 1; }
    elif [[ -e $src ]]; then
        printf 'error: %s exists but is not a clone of the kit; move it away and run this again
' "$src" >&2; exit 1
    else
        git clone -q "${XVK_REPO:-https://github.com/thejohnd0e/xray-vps-kit.git}" "$src"
    fi
    # The script itself came through the pipe, so prompts must read the terminal.
    if [[ -t 0 ]]; then exec bash "$src/install.sh" "$@"; fi
    if { : < /dev/tty; } 2> /dev/null; then exec bash "$src/install.sh" "$@" < /dev/tty; fi
    exec bash "$src/install.sh" "$@" < /dev/null
fi
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
