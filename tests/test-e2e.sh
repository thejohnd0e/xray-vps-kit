#!/usr/bin/env bash
case "${1:-all}" in
    all|connect-and-survive-update|invalid-revoked-and-private) selected=${1:-all} ;;
    *) printf 'Unknown e2e case\n' >&2; exit 1 ;;
esac
# Real transport proof: privileged because it needs a network namespace, so it
# belongs in a disposable guest, never the everyday WSL distro.
if (( EUID != 0 )) || ! command -v ip > /dev/null || ! command -v curl > /dev/null || ! command -v python3 > /dev/null; then
    printf 'e2e needs root, ip, curl and python3 in a disposable Linux guest\n' >&2
    exit 1
fi
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
scratch=$(mktemp -d)
namespace="xvk-e2e-$$"
pids=()
cleanup() {
    local pid
    for pid in "${pids[@]}"; do kill "$pid" 2> /dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2> /dev/null || true; done
    # Clients started inside command substitutions are not tracked in pids.
    ip netns pids "$namespace" 2> /dev/null | xargs -r kill 2> /dev/null || true
    ip netns delete "$namespace" 2> /dev/null || true
    rm -rf -- "$scratch"
}
trap cleanup EXIT
xvk_test_probe_path "$scratch"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
token=$(openssl rand -hex 8)
endpoint=198.18.0.1
target=198.18.0.2
origin=93.184.216.34

in_ns() { ip netns exec "$namespace" "$@"; }

wait_for_port() {
    local address=$1 port=$2
    for _ in $(seq 1 50); do
        # Positional parameters are expanded by the inner shell, not this one.
        # shellcheck disable=SC2016
        if in_ns bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$address" "$port" 2> /dev/null; then return 0; fi
        # Bounded readiness poll of an external process.
        sleep 0.2
    done
    return 1
}

start_background() {
    local log=$1
    shift
    # Run ip directly (not through the in_ns function): ip netns exec replaces itself
    # with the command, so $! is the real process and kill reaches it.
    ip netns exec "$namespace" "$@" > "$log" 2>&1 &
    pids+=("$!")
    started_pid=$!
}

stop_background() {
    local pid=$1 index
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
    for index in "${!pids[@]}"; do
        [[ ${pids[index]} != "$pid" ]] || unset 'pids[index]'
    done
}

setup_namespace() {
    ip netns add "$namespace"
    in_ns ip link set lo up
    for address in "$endpoint" "$target" "$origin" 10.77.0.1 169.254.169.254; do
        in_ns ip addr add "$address/32" dev lo
    done
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
        -subj /CN=e2e-target.test -keyout "$scratch/target.key" -out "$scratch/target.crt" 2> /dev/null
    start_background "$scratch/fixtures.log" python3 "$TESTS_DIR/helpers/e2e-fixtures.py" \
        "$scratch/target.crt" "$scratch/target.key" "$token" "$scratch/ready"
    for _ in $(seq 1 50); do [[ -s $scratch/ready ]] && break; sleep 0.2; done
    [[ -s $scratch/ready ]] || { cat "$scratch/fixtures.log" >&2; return 1; }
}

install_kit() {
    root=$(mktemp -d "$scratch/root.XXXXXXXX")
    xvk_test_install "$root" "$archive" --endpoint "$endpoint" --server-name e2e-target.test \
        --target "$target:8444" > /dev/null
    manager="$root/usr/local/bin/xray-client"
    cfg="$root/etc/xray-vps-kit"
}

start_server() {
    local log="$scratch/server-$RANDOM.log"
    start_background "$log" "$root/opt/xray-vps-kit/current/xray" run -config "$cfg/config.json"
    server_pid=$started_pid
    wait_for_port "$endpoint" 443 || { printf 'server did not listen; core log:\n' >&2; cat "$log" >&2; return 1; }
}

restart_server() {
    stop_background "$server_pid"
    start_server
}

# fetch_via URI LABEL URL [uri-client overrides...]: prints the body, returns curl's status.
fetch_via() {
    local uri=$1 label=$2 url=$3 port=$((20000 + RANDOM % 20000)) status=0 client_pid
    shift 3
    python3 "$TESTS_DIR/helpers/uri-client.py" "$uri" "$port" "$@" > "$scratch/client-$label.json" || return 99
    start_background "$scratch/client-$label.log" "$root/opt/xray-vps-kit/current/xray" run -config "$scratch/client-$label.json"
    client_pid=$started_pid
    if wait_for_port 127.0.0.1 "$port"; then
        in_ns curl --silent --show-error --max-time 6 --socks5-hostname "127.0.0.1:$port" "$url" 2> /dev/null || status=$?
    else
        status=98
    fi
    stop_background "$client_pid"
    return "$status"
}

uri_of() { bash "$manager" show "$1" | grep '^vless://'; }
expect_body() { printf '%s-%s\n' "$1" "$token"; }

setup_namespace
install_kit
start_server

if [[ $selected == all || $selected == connect-and-survive-update ]]; then
    main_uri=$(uri_of main-user)
    body=$(fetch_via "$main_uri" initial "http://$origin:8080/" || true)
    assert_eq "$(expect_body origin)" "$body" 'exported URI fetches the origin body through REALITY'

    restart_server
    body=$(fetch_via "$main_uri" restarted "http://$origin:8080/" || true)
    assert_eq "$(expect_body origin)" "$body" 'a freshly started server accepts the same profile'

    bundle_before=$(readlink "$root/opt/xray-vps-kit/current")
    config_before=$(sha256sum "$cfg/config.json")
    fixture="$scratch/bad-kit"
    mkdir "$fixture"
    cp "$PROJECT_DIR/VERSION" "$PROJECT_DIR/xray-client" "$PROJECT_DIR/update.sh" "$fixture/"
    cp -a "$PROJECT_DIR/lib" "$PROJECT_DIR/releases" "$PROJECT_DIR/templates" "$fixture/"
    printf '0.2.0\n' > "$fixture/VERSION"
    printf 'if then invalid shell syntax\n' > "$fixture/xray-client"
    assert_failure 'a broken candidate update is refused' bash "$fixture/update.sh" --root "$root" --archive "$archive"
    assert_eq "$bundle_before" "$(readlink "$root/opt/xray-vps-kit/current")" 'refused update keeps the running bundle selected'
    assert_eq "$config_before" "$(sha256sum "$cfg/config.json")" 'refused update keeps the config byte-identical'
    body=$(fetch_via "$main_uri" after-failed-update "http://$origin:8080/" || true)
    assert_eq "$(expect_body origin)" "$body" 'traffic continues after the failed update without a restart'

    cp "$PROJECT_DIR/xray-client" "$fixture/xray-client"
    assert_success 'a coherent update commits' bash "$fixture/update.sh" --root "$root" --archive "$archive"
    assert_failure 'update selected a new bundle' test "$(readlink "$root/opt/xray-vps-kit/current")" = "$bundle_before"
    restart_server
    body=$(fetch_via "$(uri_of main-user)" after-update "http://$origin:8080/" || true)
    assert_eq "$(expect_body origin)" "$body" 'the updated core serves the preserved profile'
    assert_eq "$main_uri" "$(uri_of main-user)" 'update leaves the exported URI byte-identical'
fi

if [[ $selected == all || $selected == invalid-revoked-and-private ]]; then
    main_uri=$(uri_of main-user)
    origin_url="http://$origin:8080/"
    # Positive control first: the negative results below only mean something while the path works.
    body=$(fetch_via "$main_uri" control "$origin_url" || true)
    assert_eq "$(expect_body origin)" "$body" 'healthy control fetches the origin body'

    wrong_uuid=$(python3 -c 'import uuid; print(uuid.uuid4())')
    wrong_short_id=$(openssl rand -hex 8)
    wrong_key=$("$root/opt/xray-vps-kit/current/xray" x25519 | sed -n 's/^Password (PublicKey): //p')
    status=0; body=$(fetch_via "$main_uri" bad-uuid "$origin_url" --uuid "$wrong_uuid") || status=$?
    assert_failure 'wrong UUID cannot fetch' test "$status" -eq 0
    assert_eq '' "$body" 'wrong UUID receives no origin body'
    status=0; body=$(fetch_via "$main_uri" bad-sid "$origin_url" --short-id "$wrong_short_id") || status=$?
    assert_failure 'wrong shortId cannot fetch' test "$status" -eq 0
    assert_eq '' "$body" 'wrong shortId receives no origin body'
    status=0; body=$(fetch_via "$main_uri" bad-key "$origin_url" --public-key "$wrong_key") || status=$?
    assert_failure 'wrong public key cannot fetch' test "$status" -eq 0
    assert_eq '' "$body" 'wrong public key receives no origin body'

    bash "$manager" add second-user > /dev/null
    restart_server
    second_uri=$(uri_of second-user)
    body=$(fetch_via "$main_uri" both-main "$origin_url" || true)
    assert_eq "$(expect_body origin)" "$body" 'first client connects after a second is added'
    body=$(fetch_via "$second_uri" both-second "$origin_url" || true)
    assert_eq "$(expect_body origin)" "$body" 'second client connects after the server re-reads its config'

    bash "$manager" remove main-user > /dev/null
    restart_server
    status=0; body=$(fetch_via "$main_uri" revoked "$origin_url") || status=$?
    assert_failure 'revoked client cannot fetch' test "$status" -eq 0
    assert_eq '' "$body" 'revoked client receives no origin body'
    body=$(fetch_via "$second_uri" survivor "$origin_url" || true)
    assert_eq "$(expect_body origin)" "$body" 'surviving client still connects after revocation'

    # Each blocked origin is reachable directly, so only the server policy can explain a refusal.
    for private in "10.77.0.1:8080 private" "127.0.0.1:8081 loopback" "169.254.169.254:8080 metadata"; do
        body=$(in_ns curl --silent --max-time 5 "http://${private% *}/" || true)
        assert_eq "$(expect_body "${private#* }")" "$body" "${private#* } origin is reachable without the proxy"
    done
    for private in "10.77.0.1:8080 private" "127.0.0.1:8081 loopback" "169.254.169.254:8080 metadata"; do
        status=0; body=$(fetch_via "$second_uri" "blocked-${private#* }" "http://${private% *}/") || status=$?
        assert_failure "authenticated request to ${private#* } destination is refused" test "$status" -eq 0
        assert_eq '' "$body" "${private#* } origin body is never returned"
    done
    body=$(fetch_via "$second_uri" control-after "$origin_url" || true)
    assert_eq "$(expect_body origin)" "$body" 'the same client still reaches the public origin after the blocked attempts'
fi
