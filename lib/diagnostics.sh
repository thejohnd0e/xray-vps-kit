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
    local root=${1%/} name=${2:-} output=${3:-} fp=${4:-chrome} format=${5:-uri} cfg uri
    cfg="${root%/}/etc/xray-vps-kit"
    xvk_client_require_install "$root" || return 1
    xvk_validate_name "$name" || { xvk_error 'Invalid client name'; return 1; }
    [[ -n $output ]] || { xvk_error 'Usage: xray-client export NAME --output FILE'; return 1; }
    [[ $output == /* ]] || { xvk_error 'Export path must be absolute'; return 1; }
    xvk_validate_fp "$fp" || { xvk_error 'Invalid fingerprint'; return 1; }
    xvk_no_symlink_path "$output" || { xvk_error 'Refusing unsafe export path'; return 1; }
    [[ ! -e $output && ! -L $output ]] || { xvk_error 'Refusing to overwrite an existing export'; return 1; }
    uri=$(xvk_render_profile "$cfg/state.json" "$name" "$fp" "$format") || { xvk_error 'No such client or unknown format'; return 1; }
    # Exclusive creation: noclobber plus a fresh umask means the file can never
    # be an existing target and is mode 0600 from birth.
    ( umask 077; set -C; printf '%s\n' "$uri" > "$output" ) || {
        xvk_error 'Could not create the export file'; return 1;
    }
}

# Opt-in functional check: a throwaway client built from the first stored client dials this
# server on loopback over REALITY and fetches one URL through the tunnel (default: the SNI
# site itself, any HTTP answer counts; override with XVK_PROBE_URL). Prints nothing secret.
# Exit: 0 tunnel works, 1 it does not, 2 the probe could not be set up (skipped).
xvk_client_probe_reality() (
    set -uo pipefail
    local root=${1%/} cfg bundle core port url workdir client_pid='' socks status=1
    cfg="$root/etc/xray-vps-kit"
    command -v curl > /dev/null 2>&1 && command -v timeout > /dev/null 2>&1 || exit 2
    bundle=$(jq -r .installed.bundleId "$cfg/state.json" 2> /dev/null) || exit 2
    core="$root/opt/xray-vps-kit/releases/$bundle/xray"
    [[ -x $core ]] || exit 2
    [[ $(jq '.clients|length' "$cfg/state.json" 2> /dev/null) -ge 1 ]] || exit 2
    port=$(jq -r .port "$cfg/state.json") || exit 2
    url=${XVK_PROBE_URL:-}
    [[ -n $url ]] || url="https://$(jq -r .serverName "$cfg/state.json")/"
    workdir=$(umask 077; mktemp -d) || exit 2
    trap '[[ -z $client_pid ]] || kill "$client_pid" 2> /dev/null; rm -rf -- "$workdir"' EXIT
    for _ in 1 2 3 4 5 6 7 8; do
        socks=$((20000 + RANDOM % 20000))
        ss -H -ltn "sport = :$socks" 2> /dev/null | grep -q . || break
    done
    (umask 077; jq --argjson socks "$socks" '. as $s | .clients[0] as $c | {
        log: {loglevel:"warning"},
        inbounds: [{listen:"127.0.0.1",port:$socks,protocol:"socks",settings:{auth:"noauth",udp:false}}],
        outbounds: [{protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:$s.port,
            users:[{id:$c.uuid,encryption:"none",flow:"xtls-rprx-vision"}]}]},
            streamSettings:{network:"tcp",security:"reality",realitySettings:{
                serverName:$s.serverName,fingerprint:"chrome",publicKey:$s.publicKey,
                shortId:$c.shortId,spiderX:""}}}]
    }' "$cfg/state.json" > "$workdir/client.json") || exit 2
    "$core" run -config "$workdir/client.json" > /dev/null 2>&1 &
    client_pid=$!
    for _ in $(seq 1 25); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$socks") 2> /dev/null; then break; fi
        kill -0 "$client_pid" 2> /dev/null || exit 2
        sleep 0.2
    done
    timeout 20 curl --silent --output /dev/null --max-time 15 --socks5-hostname "127.0.0.1:$socks" "$url" && status=0
    exit "$status"
)

xvk_client_doctor() {
    local root=${1%/} probe_target=false probe_reality=false cfg bundle core port report issues=0 option
    shift
    for option in "$@"; do
        case $option in
            --probe-target) probe_target=true ;;
            --probe-reality) probe_reality=true ;;
        esac
    done
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
    if [[ -e $cfg/transaction.journal || -L $cfg/transaction.journal ]]; then
        check 'no interrupted change pending (run: xray-client recover)' 1
    else check 'no interrupted change pending' 0; fi
    if xvk_client_require_install "$root" && xvk_ownership_verify "$root" "$root" 2> /dev/null; then
        check 'installed state and manifest' 0
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
    local pid='' listeners=''
    if command -v systemctl > /dev/null 2>&1; then
        pid=$(systemctl show --property=MainPID --value xray-vps-kit.service 2> /dev/null) || pid=''
    fi
    if command -v systemctl > /dev/null 2>&1 && systemctl is-active --quiet xray-vps-kit.service; then
        check 'service unit is active' 0
    else check 'service unit is active' 1; fi
    port=$(jq -r .port "$cfg/state.json" 2>/dev/null || printf '')
    listeners=$(ss -H -ltnp "sport = :$port" 2> /dev/null) || listeners=''
    # The socket must belong to this service's MainPID: any other listener on the
    # port would otherwise make a broken unit look healthy.
    if [[ $port =~ ^[0-9]+$ && $pid =~ ^[1-9][0-9]*$ && $listeners == *"pid=$pid,"* ]]; then
        check 'listening socket belongs to the service' 0
    else check 'listening socket belongs to the service' 1; fi
    # Advisories never count as failures; they only point at things worth a look.
    note() { printf '  [note] %s\n' "$1" >> "$report"; }
    local value=''
    if command -v timedatectl > /dev/null 2>&1; then
        value=$(timedatectl show -p NTPSynchronized --value 2> /dev/null) || value=''
        [[ $value != no ]] || note 'the system clock is not reported as synchronized; REALITY clients need an accurate clock'
    fi
    if command -v sysctl > /dev/null 2>&1; then
        value=$(sysctl -n net.ipv4.tcp_congestion_control 2> /dev/null) || value=''
        [[ -z $value || $value == bbr ]] || note "TCP congestion control is $value; bbr often helps on long paths"
    fi
    if [[ -f $root/var/lib/xray-vps-kit-auto-update/last-run.json ]]; then
        value=$(jq -r '"last automatic update check: \(.outcome) at \(.timestamp)"' "$root/var/lib/xray-vps-kit-auto-update/last-run.json" 2> /dev/null) || value=''
        [[ -z $value ]] || note "$value"
    fi
    if [[ $probe_target == true ]]; then
        local target sni
        target=$(jq -r .target "$cfg/state.json" 2> /dev/null) || target=''
        sni=$(jq -r .serverName "$cfg/state.json" 2> /dev/null) || sni=''
        if [[ -n $target ]] && command -v openssl > /dev/null 2>&1 && command -v timeout > /dev/null 2>&1; then
            if timeout 10 openssl s_client -connect "$target" -servername "$sni" -tls1_3 < /dev/null 2> /dev/null | grep -q 'TLSv1.3'; then
                note "REALITY target $target answers with TLS 1.3"
            else
                note "REALITY target $target did not answer with TLS 1.3 from this server; check target and SNI"
            fi
        fi
    fi
    if [[ $probe_reality == true ]]; then
        local probe_status=0
        xvk_client_probe_reality "$root" || probe_status=$?
        case $probe_status in
            0) check 'REALITY tunnel works (temporary local client reached the target)' 0 ;;
            2) note 'REALITY tunnel probe skipped (needs curl, timeout, the pinned core and one client)' ;;
            *) check 'REALITY tunnel works (temporary local client reached the target)' 1 ;;
        esac
    fi
    printf 'xray-vps-kit doctor\n'
    cat "$report"
    printf 'Checks failed: %s\n' "$issues"
    # Static advice, not a check: a server cannot see a path problem on the client side.
    printf 'Note: if a client connects only part of the time (connections stall after the first\n'
    printf 'packet), its large Chrome TLS hello may be cut on the way. Regenerate that profile with\n'
    printf '  xray-client show NAME --fp firefox\n'
    (( issues == 0 ))
}
