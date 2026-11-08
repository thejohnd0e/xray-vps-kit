#!/usr/bin/env bash
set -euo pipefail
# An installed/scheduled worker must never repair itself by fetching kit code or
# installing packages after removal or damage. Relative invocation from its own
# directory, and invocation through a symlink, must be recognised as well, so the
# script path is resolved before deciding whether this is the installed worker.
script_path=${BASH_SOURCE[0]:-}
resolved_path=''
if [[ -n $script_path && -f $script_path ]]; then
    resolved_target=$script_path
    hops=0
    while [[ -L $resolved_target && $hops -lt 40 ]]; do
        hops=$((hops + 1))
        link_target=$(readlink -- "$resolved_target" 2> /dev/null) || { resolved_target=''; break; }
        case $link_target in
            /*) resolved_target=$link_target ;;
            *) resolved_target=$(dirname -- "$resolved_target")/$link_target ;;
        esac
    done
    if [[ -n $resolved_target && -f $resolved_target ]]; then
        resolved_dir=$(cd -- "$(dirname -- "$resolved_target")" && pwd -P) || resolved_dir=''
        [[ -z $resolved_dir ]] || resolved_path="$resolved_dir/${resolved_target##*/}"
    fi
fi
if [[ ${1:-} == scheduled || $resolved_path == */opt/xray-vps-kit-auto-update/auto-update.sh ]]; then
    if [[ ! -f $resolved_path || ! -f ${resolved_path%/*}/lib/common.sh ]]; then
        printf 'error: installed automatic-update worker is incomplete; refusing bootstrap\n' >&2; exit 1
    fi
fi
# Invoked through a symlink: continue from the real path so the shared bootstrap
# check and module resolution see the directory the worker actually lives in.
if [[ -n $resolved_path && -L $script_path && $resolved_path != "$script_path" ]]; then
    exec bash "$resolved_path" "$@"
fi
# Started through `curl ... | bash` (no kit checkout beside this script): fetch the kit into
# /opt/xray-vps-kit-src (or fast-forward the clone there) and continue from that copy.
if [[ ! -f ${BASH_SOURCE[0]:-} || ! -f $(dirname -- "${BASH_SOURCE[0]:-/}")/lib/common.sh ]]; then
    src=${XVK_SRC:-/opt/xray-vps-kit-src}
    cd /
    [[ -n ${XVK_SRC:-} || $EUID == 0 ]] || { printf 'error: run as root\n' >&2; exit 1; }
    bootstrap_packages=()
    command -v git > /dev/null 2>&1 || bootstrap_packages+=(git)
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || bootstrap_packages+=(ca-certificates)
    if (( ${#bootstrap_packages[@]} )); then
        for bootstrap_arg in "$@"; do
            if [[ $bootstrap_arg == --no-service || $bootstrap_arg == --root ]]; then
                printf 'error: sandbox cannot install bootstrap dependencies: %s\n' "${bootstrap_packages[*]}" >&2; exit 1
            fi
        done
        bootstrap_os='' bootstrap_version=''
        while IFS='=' read -r bootstrap_key bootstrap_value; do
            bootstrap_value=${bootstrap_value//\"/}
            case $bootstrap_key in ID) bootstrap_os=$bootstrap_value ;; VERSION_ID) bootstrap_version=$bootstrap_value ;; esac
        done < /etc/os-release
        case "$bootstrap_os:$bootstrap_version" in
            debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
            *) printf 'error: unsupported bootstrap operating system\n' >&2; exit 1 ;;
        esac
        case $(uname -m) in
            x86_64|amd64|aarch64|arm64) ;;
            *) printf 'error: unsupported bootstrap architecture\n' >&2; exit 1 ;;
        esac
        [[ $EUID == 0 ]] || { printf 'error: bootstrap package installation requires root\n' >&2; exit 1; }
        printf '[Bootstrap] Installing missing dependencies: %s\n' "${bootstrap_packages[*]}" >&2
        if ! apt-get update < /dev/null >&2 || ! DEBIAN_FRONTEND=noninteractive apt-get -y --no-remove \
            -o Dpkg::Progress-Fancy=1 -o APT::Color=0 install "${bootstrap_packages[@]}" < /dev/null >&2; then
            printf 'error: bootstrap dependency installation failed\n' >&2; exit 1
        fi
        hash -r
        if ! command -v git > /dev/null 2>&1 || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
            printf 'error: git or CA certificates still unavailable after APT\n' >&2; exit 1
        fi
    fi
    if [[ -d $src/.git ]]; then
        git -C "$src" pull --ff-only -q || { printf 'error: cannot fast-forward %s (local changes?)\n' "$src" >&2; exit 1; }
    elif [[ -e $src ]]; then
        printf 'error: %s exists but is not a clone of the kit; move it away and run this again\n' "$src" >&2; exit 1
    else
        git clone -q "${XVK_REPO:-https://github.com/thejohnd0e/xray-vps-kit.git}" "$src"
    fi
    # The script itself came through the pipe, so prompts must read the terminal.
    if [[ -t 0 ]]; then exec bash "$src/auto-update.sh" "$@"; fi
    if { : < /dev/tty; } 2> /dev/null; then exec bash "$src/auto-update.sh" "$@" < /dev/tty; fi
    exec bash "$src/auto-update.sh" "$@" < /dev/null
fi
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for module in common state release render ownership transaction snapshot bundle service firewall dependencies preflight update-lifecycle auto-owned auto-release core-update auto-lifecycle auto-run; do
    # shellcheck source=/dev/null
    source "$project/lib/$module.sh"
done
if (( $# == 0 )) || [[ ${1:-} == --help && $# == 1 ]]; then xvk_auto_help; exit 0; fi
xvk_auto_options "$@"
root=${XVK_ROOT%/}
case $XVK_AUTO_ACTION in
    enable) xvk_auto_enable "$project" "$root" ;;
    disable) xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_auto_disable_locked "$root" ;;
    status)
        if xvk_auto_present "$root"; then xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_auto_status "$root"
        else xvk_auto_status "$root"; fi ;;
    run|scheduled) xvk_auto_run "$project" "$root" "$XVK_AUTO_ACTION" ;;
esac
