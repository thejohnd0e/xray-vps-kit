#!/usr/bin/env bash

# Discover commands rather than assuming a previously installed package still
# provides them. Output each missing package once, including shared providers.
xvk_missing_dependency_packages() {
    local entry tool package
    local -a packages=() providers=(
        curl:curl jq:jq unzip:unzip zipinfo:unzip openssl:openssl
        qrencode:qrencode ss:iproute2 flock:util-linux
        timeout:coreutils realpath:coreutils sha256sum:coreutils
        find:findutils tar:tar
    )
    if [[ $XVK_SANDBOX != true ]]; then
        providers+=(systemctl:systemd getent:libc-bin useradd:passwd)
        if command -v ufw > /dev/null 2>&1; then
            providers+=(iptables:iptables iptables-save:iptables)
        elif ! command -v nft > /dev/null 2>&1; then
            providers+=(iptables-save:iptables)
        fi
    fi
    for entry in "${providers[@]}"; do
        tool=${entry%%:*} package=${entry#*:}
        command -v "$tool" > /dev/null 2>&1 && continue
        [[ " ${packages[*]} " != *" $package "* ]] || continue
        packages+=("$package")
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    (( ${#packages[@]} == 0 )) || printf '%s\n' "${packages[@]}"
    return 0
}

# Production callers must validate root and platform before reaching this point.
# All APT output goes to stderr so command substitutions cannot swallow progress.
xvk_install_dependencies() {
    local missing
    local -a packages
    printf '[Dependencies] Checking required tools and CA certificates...\n' >&2
    missing=$(xvk_missing_dependency_packages) || return 1
    if [[ -z $missing ]]; then
        printf '[Dependencies] All required dependencies are already available.\n' >&2
        return 0
    fi
    mapfile -t packages <<< "$missing"
    printf '[Dependencies] Missing packages: %s\n' "${packages[*]}" >&2
    if [[ $XVK_SANDBOX == true ]]; then
        xvk_error 'Sandbox does not install host packages; install the missing dependencies manually'
        return 1
    fi
    xvk_require_commands apt-get || return 1
    printf '[Dependencies 1/3] Updating package lists...\n' >&2
    if ! apt-get update < /dev/null >&2; then
        xvk_error 'Dependency package-list update failed; installation stopped'; return 1
    fi
    printf '[Dependencies 2/3] Installing missing packages (APT progress below)...\n' >&2
    if ! DEBIAN_FRONTEND=noninteractive apt-get -y --no-remove \
        -o Dpkg::Progress-Fancy=1 -o APT::Color=0 install "${packages[@]}" < /dev/null >&2; then
        xvk_error 'Dependency installation failed; packages may remain installed'; return 1
    fi
    hash -r
    printf '[Dependencies 3/3] Verifying installed dependencies...\n' >&2
    missing=$(xvk_missing_dependency_packages) || return 1
    if [[ -n $missing ]]; then
        xvk_error "Dependencies still unavailable after APT: $missing"; return 1
    fi
    printf '[Dependencies] Ready.\n' >&2
}
