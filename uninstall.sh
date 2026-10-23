#!/usr/bin/env bash
set -euo pipefail
# Started through `curl ... | bash` (no kit checkout beside this script): fetch the kit into
# /opt/xray-vps-kit-src (or fast-forward the clone there) and continue from that copy.
if [[ ! -f ${BASH_SOURCE[0]:-} || ! -f $(dirname -- "${BASH_SOURCE[0]:-/}")/lib/common.sh ]]; then
    src=${XVK_SRC:-/opt/xray-vps-kit-src}
    cd /
    [[ -n ${XVK_SRC:-} || $EUID == 0 ]] || { printf 'error: run as root
' >&2; exit 1; }
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
        git -C "$src" pull --ff-only -q || { printf 'error: cannot fast-forward %s (local changes?)
' "$src" >&2; exit 1; }
    elif [[ -e $src ]]; then
        printf 'error: %s exists but is not a clone of the kit; move it away and run this again
' "$src" >&2; exit 1
    else
        git clone -q "${XVK_REPO:-https://github.com/thejohnd0e/xray-vps-kit.git}" "$src"
    fi
    # The script itself came through the pipe, so prompts must read the terminal.
    if [[ -t 0 ]]; then exec bash "$src/uninstall.sh" "$@"; fi
    if { : < /dev/tty; } 2> /dev/null; then exec bash "$src/uninstall.sh" "$@" < /dev/tty; fi
    exec bash "$src/uninstall.sh" "$@" < /dev/null
fi
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
