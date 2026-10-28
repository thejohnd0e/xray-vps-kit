#!/usr/bin/env bash
# Portable export and redacted diagnostics. Export writes the exact same URI
# bytes that `show` prints; QR is generated locally. Doctor reports
# labeled check results only and never prints a URI, private key or UUID.

xvk_client_show_qr() {
    local root=${1%/} name=${2:-} fp=${3:-chrome} cfg uri
    cfg="${root%/}/etc/xray-vps-kit"
    xvk_client_require_install "$root" || return 1
    xvk_validate_name "$name" || { xvk_error 'Invalid client name'; return 1; }
    xvk_validate_fp "$fp" || { xvk_error 'Invalid fingerprint'; return 1; }
    uri=$(xvk_render_uri "$cfg/state.json" "$name" "$fp") || { xvk_error 'No such client'; return 1; }
    xvk_require_commands qrencode || return 1
    # Pipe the bare URI without a trailing newline so the encoded payload and
    # the URI line of `show` are the same bytes apart from that newline.
    printf '%s' "$uri" | qrencode -t ANSIUTF8
}

# Prints the URI and its QR code, the profile a person imports into a client app.
xvk_client_print_profile() {
    local root=${1%/} name=${2:-} fp=${3:-chrome} cfg uri
    cfg="${root%/}/etc/xray-vps-kit"
    xvk_client_require_install "$root" || return 1
    xvk_validate_name "$name" || { xvk_error 'Invalid client name'; return 1; }
    xvk_validate_fp "$fp" || { xvk_error 'Invalid fingerprint'; return 1; }
    uri=$(xvk_render_uri "$cfg/state.json" "$name" "$fp") || { xvk_error 'No such client'; return 1; }
    printf 'Client %s
URI:
%s

QR code:
' "$name" "$uri"
    xvk_client_show_qr "$root" "$name" "$fp"
}

xvk_client_export() {
    local root=${1%/} name=${2:-} output=${3:-} fp=${4:-chrome} cfg uri
    cfg="${root%/}/etc/xray-vps-kit"
    xvk_client_require_install "$root" || return 1
    xvk_validate_name "$name" || { xvk_error 'Invalid client name'; return 1; }
    [[ -n $output ]] || { xvk_error 'Usage: xray-client export NAME --output FILE'; return 1; }
    [[ $output == /* ]] || { xvk_error 'Export path must be absolute'; return 1; }
    xvk_validate_fp "$fp" || { xvk_error 'Invalid fingerprint'; return 1; }
    xvk_no_symlink_path "$output" || { xvk_error 'Refusing unsafe export path'; return 1; }
    [[ ! -e $output && ! -L $output ]] || { xvk_error 'Refusing to overwrite an existing export'; return 1; }
    uri=$(xvk_render_uri "$cfg/state.json" "$name" "$fp") || { xvk_error 'No such client'; return 1; }
    # Exclusive creation: noclobber plus a fresh umask means the file can never
    # be an existing target and is mode 0600 from birth.
    ( umask 077; set -C; printf '%s\n' "$uri" > "$output" ) || {
        xvk_error 'Could not create the export file'; return 1;
    }
}

xvk_client_doctor() {
    local root=${1%/} cfg bundle core port report issues=0
    cfg="${root%/}/etc/xray-vps-kit"
    report=$(mktemp) || return 1
    # shellcheck disable=SC2064
    trap "rm -f -- '$report'" RETURN
    check() {
        if (( $2 == 0 )); then printf '  [ok]   %s\n' "$1" >> "$report"
        else printf '  [FAIL] %s\n' "$1" >> "$report"; issues=$((issues + 1)); fi
    }
    # Every probe runs inside a condition so a failed mandatory check records a
    # diagnostic instead of aborting the report under errexit/pipefail.
    if xvk_client_require_install "$root"; then check 'installed state and manifest' 0
    else check 'installed state and manifest' 1; fi
    if xvk_render_server "$cfg/state.json" 2>/dev/null | cmp -s - "$cfg/config.json"; then
        check 'configuration matches installed state' 0
    else check 'configuration matches installed state' 1; fi
    bundle=$(jq -r .installed.bundleId "$cfg/state.json" 2>/dev/null || printf '')
    core="${root%/}/opt/xray-vps-kit/releases/$bundle/xray"
    if [[ -x $core ]] && "$core" run -test -config "$cfg/config.json" > /dev/null 2>&1; then
        check 'pinned core accepts configuration' 0
    else check 'pinned core accepts configuration' 1; fi
    if [[ -f $root/etc/systemd/system/xray-vps-kit.service ]]; then
        check 'service unit is installed' 0
    else check 'service unit is installed' 1; fi
    if command -v systemctl > /dev/null 2>&1 && systemctl is-active --quiet xray-vps-kit.service; then
        check 'service unit is active' 0
    else check 'service unit is active' 1; fi
    port=$(jq -r .port "$cfg/state.json" 2>/dev/null || printf '')
    if [[ $port =~ ^[0-9]+$ ]] && [[ -n $(ss -H -ltn "sport = :$port" 2>/dev/null) ]]; then
        check 'listening socket on selected port' 0
    else check 'listening socket on selected port' 1; fi
    printf 'xray-vps-kit doctor\n'
    cat "$report"
    printf 'Checks failed: %s\n' "$issues"
    # Static advice, not a check: a server cannot see a path problem on the client side.
    printf 'Note: if a client connects only part of the time (connections stall after the first\n'
    printf 'packet), its large Chrome TLS hello may be cut on the way. Regenerate that profile with\n'
    printf '  xray-client show NAME --fp firefox\n'
    (( issues == 0 ))
}
