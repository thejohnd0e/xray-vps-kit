#!/usr/bin/env bash

xvk_detect_platform() {
    local os version
    # Read literal values, not executable shell assignments from os-release.
    os=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"') || return 1
    version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"') || return 1
    xvk_platform "$os" "$version" "$(uname -m)"
}

xvk_port_free() {
    local listeners
    listeners=$(ss -H -ltn "sport = :$1") || return 1
    [[ -z $listeners ]]
}

xvk_probe_target() (
    local target=$1 sni=$2 output
    output=$(mktemp) || exit 1
    trap 'rm -f -- "$output"' EXIT
    if ! timeout 12 openssl s_client -connect "$target" -servername "$sni" \
        -verify_hostname "$sni" -verify_return_error -tls1_3 -alpn h2 \
        < /dev/null > "$output" 2>&1; then
        xvk_error 'Target TLS/certificate probe failed'; exit 1
    fi
    if ! grep -q 'TLSv1.3' "$output" || ! grep -q 'ALPN protocol: h2' "$output" ||
        ! grep -q 'Verify return code: 0 (ok)' "$output"; then
        xvk_error 'Target must support verified TLS1.3 and h2'; exit 1
    fi
)

xvk_install_preflight() {
    local project=$1 value preserved
    : "${XVK_ROOT:?installer options must be parsed first}"
    if ! xvk_require_commands curl openssl ss timeout jq realpath; then
        xvk_error 'Bootstrap preflight dependencies: sudo apt-get update && sudo apt-get install curl ca-certificates openssl iproute2 coreutils jq'
        return 1
    fi
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || { xvk_error 'Missing CA trust: sudo apt-get install ca-certificates'; return 1; }
    XVK_ARCH=$(xvk_detect_platform) || return 1
    export XVK_ARCH
    if [[ -n $XVK_ARCHIVE ]]; then
        XVK_ARCHIVE=$(realpath -ms -- "$XVK_ARCHIVE") || return 1
        if ! xvk_release_validate_lock "$project/releases/xray.lock.json" ||
            ! xvk_verify_sha256 "$XVK_ARCHIVE" "$(jq -r --arg arch "$XVK_ARCH" '.assets[$arch].sha256' "$project/releases/xray.lock.json")"; then
            xvk_error 'Local archive does not match the pinned architecture checksum'; return 1
        fi
    fi
    if [[ $XVK_SANDBOX != true && $EUID != 0 ]]; then xvk_error 'Production installation requires root'; return 1; fi
    if [[ $XVK_RESTORE == true ]]; then
        preserved="${XVK_ROOT%/}/etc/xray-vps-kit/state.json"
        xvk_state_validate "$preserved" || return 1
        XVK_PORT=$(jq -r .port "$preserved")
        XVK_SNI=$(jq -r .serverName "$preserved")
        XVK_TARGET=$(jq -r .target "$preserved")
        XVK_ENDPOINT=$(jq -r .endpoint "$preserved")
    else
        if [[ $XVK_SANDBOX == true ]]; then
            xvk_require_empty_test_root "$XVK_ROOT" || { xvk_error 'Testing root is not empty'; return 1; }
        fi
        while :; do
            if [[ $XVK_AUTOMATION != true && $XVK_PORT_SET != true ]]; then
                XVK_PORT=$(xvk_prompt_value 'Xray TCP port' "$XVK_PORT") || return 1
            fi
            if xvk_validate_port "$XVK_PORT" && xvk_port_free "$((10#$XVK_PORT))"; then break; fi
            xvk_error 'Invalid or occupied TCP port'
            [[ $XVK_AUTOMATION != true && $XVK_PORT_SET != true ]] || return 1
        done
        XVK_PORT=$((10#$XVK_PORT))
        while :; do
            if [[ $XVK_AUTOMATION != true && $XVK_SNI_SET != true ]]; then
                XVK_SNI=$(xvk_prompt_value 'REALITY SNI' "$XVK_SNI") || return 1
            fi
            [[ $XVK_TARGET_SET == true ]] || XVK_TARGET="$XVK_SNI:443"
            if xvk_validate_host "$XVK_SNI" && xvk_validate_target "$XVK_TARGET" && xvk_probe_target "$XVK_TARGET" "$XVK_SNI"; then break; fi
            xvk_error 'Invalid SNI or unsuitable verified target'
            [[ $XVK_AUTOMATION != true && $XVK_SNI_SET != true ]] || return 1
        done
        if [[ $XVK_NO_FIRST != true ]]; then
            while :; do
                if [[ $XVK_AUTOMATION != true && $XVK_FIRST_SET != true ]]; then
                    XVK_FIRST=$(xvk_prompt_value 'First client name' "$XVK_FIRST") || return 1
                fi
                xvk_validate_name "$XVK_FIRST" && break
                xvk_error 'Invalid first client name'
                [[ $XVK_AUTOMATION != true && $XVK_FIRST_SET != true ]] || return 1
            done
        fi
        if [[ -z $XVK_ENDPOINT ]]; then
            XVK_ENDPOINT=$(curl --fail --silent --show-error --proto '=https' --connect-timeout 5 --max-time 10 --max-filesize 64 https://api.ipify.org) || return 1
            [[ $XVK_ENDPOINT =~ ^[0-9.]+$ ]] || { xvk_error 'IPv4 discovery did not return IPv4'; return 1; }
        fi
    fi
    xvk_validate_host "$XVK_ENDPOINT" && xvk_validate_target "$XVK_TARGET" && xvk_port_free "$XVK_PORT" || return 1
    if [[ $XVK_RESTORE == true ]]; then xvk_probe_target "$XVK_TARGET" "$XVK_SNI" || return 1; fi
    if [[ $XVK_SANDBOX != true ]]; then
        [[ ! -e /usr/local/bin/xray-client && ! -L /usr/local/bin/xray-client && ! -e /etc/systemd/system/xray-vps-kit.service && ! -L /etc/systemd/system/xray-vps-kit.service ]] || { xvk_error 'Runtime resources already exist'; return 1; }
        [[ $XVK_RESTORE == true || ! -e /etc/xray-vps-kit ]] || { xvk_error 'State already exists; explicit --restore is required'; return 1; }
        [[ ! -e /usr/local/bin/xray && ! -e /usr/local/etc/xray && ! -e /etc/xray && ! -e /usr/local/x-ui && ! -e /etc/x-ui ]] || { xvk_error 'Foreign Xray installation found'; return 1; }
        xvk_service_account_check || return 1
        xvk_firewall_preflight "$XVK_PORT" || return 1
    fi
    value=$XVK_FIRST
    [[ $XVK_NO_FIRST != true ]] || value=none
    [[ $XVK_RESTORE != true ]] || value='preserved identities'
    printf 'Endpoint: %s:%s\nTransport: VLESS/TCP/REALITY/Vision\nSNI: %s\nTarget: %s\nFirst client: %s\n' "$XVK_ENDPOINT" "$XVK_PORT" "$XVK_SNI" "$XVK_TARGET" "$value"
}
