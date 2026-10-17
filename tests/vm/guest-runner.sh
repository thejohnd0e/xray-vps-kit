#!/usr/bin/env bash
# Runs INSIDE a disposable guest as root (started by tests/run-vm.sh):
#   guest-runner.sh CASE PHASE      env: XVK_ARCHIVE=/path/to/pinned-core.zip
# It installs, updates, rolls back and removes the real kit with real systemd and
# UFW while an AWG-named UDP/forwarding fixture runs next to it. A veth peer in a
# separate network namespace plays the "other host": its packets traverse the
# guest's real INPUT/UFW path (loopback traffic would bypass it).
#
# The fixture is not an AWG handshake; it proves the kit does not disturb the
# files, unit, nft table, sysctl and UFW rules an AWG install would own.
# uninstall_kit takes optional flags in some calls only.
# shellcheck disable=SC2119,SC2120
set -uo pipefail
# One ordered stream: assertion lines and the command output that explains them.
exec 2>&1
# Assertions discard command output; failures are echoed to the saved stdout.
exec 9>&1
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TESTS_DIR=$(cd -- "$here/.." && pwd -P)
PROJECT_DIR=$(cd -- "$TESTS_DIR/.." && pwd -P)
# shellcheck source=tests/helpers/assert.sh
source "$TESTS_DIR/helpers/assert.sh"

case_name=${1:-}
phase=${2:-run}
: "${XVK_ARCHIVE:?pinned core archive path required}"
(( EUID == 0 )) || { printf 'guest runner must run as root in a disposable guest\n' >&2; exit 1; }

peer_ns=xvk-peer
guest_ip=10.99.0.1
peer_ip=10.99.0.2
qa_dir=/var/lib/xvk-qa
mkdir -p "$qa_dir" /usr/local/lib/xvk-qa

say() { printf '# %s\n' "$*"; }

# ---------------------------------------------------------------- fixtures --

peer_up() {
    ip netns list | grep -q "^$peer_ns" && return 0
    ip netns add "$peer_ns"
    ip link add xvk-veth0 type veth peer name xvk-veth1
    ip link set xvk-veth1 netns "$peer_ns"
    ip addr add "$guest_ip/24" dev xvk-veth0
    ip link set xvk-veth0 up
    ip netns exec "$peer_ns" ip addr add "$peer_ip/24" dev xvk-veth1
    ip netns exec "$peer_ns" ip link set xvk-veth1 up
    ip netns exec "$peer_ns" ip link set lo up
}

peer_down() {
    ip netns delete "$peer_ns" 2> /dev/null || true
    ip link delete xvk-veth0 2> /dev/null || true
}

# peer_tcp PORT: succeeds only if the peer can complete a TCP handshake to the guest.
peer_tcp() {
    # shellcheck disable=SC2016
    ip netns exec "$peer_ns" timeout 4 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$guest_ip" "$1"
}

cat > /usr/local/lib/xvk-qa/udp-echo.py <<'PY'
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("0.0.0.0", int(sys.argv[1])))
while True:
    data, peer = sock.recvfrom(2048)
    sock.sendto(data, peer)
PY
cat > /usr/local/lib/xvk-qa/udp-monitor.py <<'PY'
import signal, socket, sys, time
target, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sent = received = 0
running = True
def stop(*_):
    global running
    running = False
signal.signal(signal.SIGTERM, stop)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(0.5)
while running:
    sent += 1
    sock.sendto(b"probe-%d" % sent, (target, port))
    try:
        if sock.recvfrom(64)[0] == b"probe-%d" % sent:
            received += 1
    except OSError:
        pass
    time.sleep(0.1)
open(out, "w").write(f"{sent} {received}\n")
PY
cat > /usr/local/lib/xvk-qa/tcp-listener.py <<'PY'
import socket, sys
server = socket.create_server(("0.0.0.0", int(sys.argv[1])))
while True:
    connection, _ = server.accept()
    connection.close()
PY

awg_up() {
    mkdir -p /etc/amnezia/amneziawg
    [[ -f /etc/amnezia/amneziawg/awg0.conf ]] ||
        printf '[Interface]\n# xvk fixture, not a real key\nListenPort = 443\n' > /etc/amnezia/amneziawg/awg0.conf
    cat > /etc/systemd/system/awg-fixture-echo.service <<'UNIT'
[Unit]
Description=AWG-named UDP443 echo fixture (not a tunnel)
[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/xvk-qa/udp-echo.py 443
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
    printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-awg-fixture.conf
    sysctl -q -w net.ipv4.ip_forward=1
    nft list table ip awg_nat > /dev/null 2>&1 || nft -f - <<'NFT'
table ip awg_nat {
    chain post {
        type nat hook postrouting priority 100; policy accept;
        oifname "xvk-nonexistent" masquerade
    }
}
NFT
    systemctl daemon-reload
    systemctl enable --now awg-fixture-echo.service > /dev/null 2>&1
}

# ufw_baseline MODE [PORT]: none | deny | earlier-deny | identical-deny | preexisting
ufw_baseline() {
    local mode=$1 port=${2:-443}
    ufw --force reset > /dev/null
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null
    ufw allow 22/tcp comment ssh-access > /dev/null
    ufw allow 443/udp comment awg-fixture-udp > /dev/null
    ufw route allow in on awg0 out on eth0 comment awg-fixture-route > /dev/null
    case $mode in
        earlier-deny) ufw insert 1 deny proto tcp from "$peer_ip/32" to any port "$port" comment foreign-deny > /dev/null ;;
        identical-deny) ufw insert 1 deny proto tcp from any to any port "$port" comment foreign-deny > /dev/null ;;
        preexisting) ufw allow "$port/tcp" comment foreign-allow > /dev/null ;;
    esac
    if [[ $mode == none ]]; then
        ufw --force disable > /dev/null
        # ufw leaves empty-chain jumps in INPUT after disable, which a host that never
        # enabled UFW does not have. Remove the jumps AND the chains so a later
        # `ufw enable` recreates both; removing only the jumps would leave INPUT with
        # policy DROP and no way back in.
        local chain name
        for chain in before-logging-input before-input after-input after-logging-input reject-input track-input; do
            iptables -D INPUT -j "ufw-$chain" 2> /dev/null || true
            ip6tables -D INPUT -j "ufw6-$chain" 2> /dev/null || true
        done
        for name in $(iptables -S | awk '/^-N ufw-/ {print $2}'); do iptables -F "$name"; done
        for name in $(iptables -S | awk '/^-N ufw-/ {print $2}'); do iptables -X "$name" 2> /dev/null || true; done
        for name in $(ip6tables -S | awk '/^-N ufw6-/ {print $2}'); do ip6tables -F "$name"; done
        for name in $(ip6tables -S | awk '/^-N ufw6-/ {print $2}'); do ip6tables -X "$name" 2> /dev/null || true; done
        iptables -P INPUT ACCEPT
        ip6tables -P INPUT ACCEPT
    else
        ufw --force enable > /dev/null
    fi
}

# Everything an AWG install owns, as a deterministic text view. Owned kit rows are
# filtered out of the UFW listing; their absence/presence is asserted separately.
awg_view() {
    sha256sum /etc/amnezia/amneziawg/awg0.conf /etc/systemd/system/awg-fixture-echo.service \
        /etc/sysctl.d/99-awg-fixture.conf /usr/local/lib/xvk-qa/udp-echo.py
    nft -a list table ip awg_nat
    sysctl -n net.ipv4.ip_forward
    ufw show added | grep -v 'xray-vps-kit-' || true
    grep -E '^DEFAULT_(INPUT|FORWARD)_POLICY' /etc/default/ufw
    systemctl is-active awg-fixture-echo.service
}

udp_monitor_start() {
    rm -f "$qa_dir/udp-result"
    ip netns exec "$peer_ns" python3 /usr/local/lib/xvk-qa/udp-monitor.py "$guest_ip" 443 "$qa_dir/udp-result" &
    monitor_pid=$!
    sleep 2
}

udp_monitor_stop() {
    kill -TERM "$monitor_pid" 2> /dev/null
    wait "$monitor_pid" 2> /dev/null
    local sent received
    read -r sent received < "$qa_dir/udp-result"
    say "UDP fixture exchange: sent=$sent received=$received"
    # One datagram may be in flight at the instant the monitor stops.
    (( sent > 20 && received >= sent - 1 ))
}

foreign_listener_start() {
    python3 /usr/local/lib/xvk-qa/tcp-listener.py "$1" &
    listener_pid=$!
    sleep 1
}

foreign_listener_stop() {
    kill "$listener_pid" 2> /dev/null
    wait "$listener_pid" 2> /dev/null
}

# ---------------------------------------------------------------- kit ops ---

logged() {
    local output status=0
    output=$("$@" 2>&1) || status=$?
    (( status == 0 )) || printf '%s
' "command exited $status: $*" "$output" | sed 's/^/# | /' >&9
    return "$status"
}
install_kit() { logged bash "$PROJECT_DIR/install.sh" --non-interactive --endpoint 203.0.113.7 --archive "$XVK_ARCHIVE" "$@"; }
restore_kit() { logged bash "$PROJECT_DIR/install.sh" --restore --non-interactive --archive "$XVK_ARCHIVE"; }
uninstall_kit() { logged bash "$PROJECT_DIR/uninstall.sh" --yes "$@"; }
kit_update() { local kit=$1; shift; logged bash "$kit/update.sh" "$@"; }
manager() { /usr/local/bin/xray-client "$@"; }
bundle() { readlink /opt/xray-vps-kit/current; }
marker_rows() { ufw show added | grep -c 'xray-vps-kit-' || true; }

make_kit() {
    local destination=$1 version=$2
    rm -rf "$destination"
    mkdir -p "$destination"
    cp "$PROJECT_DIR/xray-client" "$PROJECT_DIR/update.sh" "$destination/"
    cp -a "$PROJECT_DIR/lib" "$PROJECT_DIR/releases" "$PROJECT_DIR/templates" "$destination/"
    printf '%s\n' "$version" > "$destination/VERSION"
}

service_checks() {
    local label=$1 pid port=${2:-443}
    assert_success "$label: service is active" systemctl is-active --quiet xray-vps-kit.service
    assert_eq 'root:xray-vps-kit 640' "$(stat -c '%U:%G %a' /etc/xray-vps-kit/config.json)" "$label: config stays readable through the service group"
    assert_eq xray-vps-kit "$(systemctl show -p User --value xray-vps-kit.service)" "$label: runs as the dedicated user"
    pid=$(systemctl show -p MainPID --value xray-vps-kit.service)
    assert_eq 0000000000000400 "$(awk '/^CapEff:/ {print $2}' "/proc/$pid/status")" "$label: only CAP_NET_BIND_SERVICE is effective"
    assert_eq 0000000000000400 "$(awk '/^CapBnd:/ {print $2}' "/proc/$pid/status")" "$label: bounding set is only CAP_NET_BIND_SERVICE"
    assert_success "$label: real TCP listener owned by xray" bash -c "ss -H -ltnp 'sport = :$port' | grep -q 'pid=$pid,'"
    assert_success "$label: peer completes a TCP handshake" peer_tcp "$port"
}

removed_checks() {
    local label=$1
    assert_failure "$label: service is not active" systemctl is-active --quiet xray-vps-kit.service
    assert_failure "$label: unit file is gone" test -e /etc/systemd/system/xray-vps-kit.service
    assert_failure "$label: launcher is gone" test -e /usr/local/bin/xray-client
    assert_failure "$label: bundles are gone" test -e /opt/xray-vps-kit
    assert_eq 0 "$(marker_rows)" "$label: no owned firewall rule remains"
}

fixture_unchanged() {
    local label=$1 before=$2
    assert_eq "$before" "$(awg_view)" "$label: AWG fixture files, nft table, sysctl and UFW rules unchanged"
}

prepare() {
    # Leftovers of an interrupted earlier run must not leak into this one.
    pkill -f tcp-listener.py 2> /dev/null || true
    pkill -f udp-monitor.py 2> /dev/null || true
    if [[ ${1:-} != keep-kit ]] && [[ -e /etc/systemd/system/xray-vps-kit.service || -d /etc/xray-vps-kit ]]; then
        say 'removing a previous kit installation before the run'
        uninstall_kit > /dev/null 2>&1 || true
    fi
    peer_up
    awg_up
}

# --------------------------------------------------------------- scenarios --

platform_report() {
    say "guest: $(. /etc/os-release && printf '%s' "$PRETTY_NAME"); kernel $(uname -r); $(systemctl --version | head -1)"
    assert_eq systemd "$(ps -p 1 -o comm=)" 'guest runs systemd as PID 1'
    ufw version | head -1 | sed 's/^/# /'
}

phase_lifecycle_a() {
    local before bundle0 bundle1 unit_before fixture
    platform_report
    prepare
    ufw_baseline deny
    before=$(awg_view)
    udp_monitor_start

    foreign_listener_start 443
    assert_failure 'before install: default-deny UFW blocks the peer from TCP443' peer_tcp 443
    foreign_listener_stop

    assert_success 'install succeeds on the real guest' install_kit
    service_checks install
    assert_eq 1 "$(marker_rows)" 'exactly one owned UFW rule was inserted'
    assert_success 'doctor passes with real systemd' manager doctor
    fixture_unchanged install "$before"

    assert_success 'client add restarts the real service' logged manager add qa-two
    service_checks 'after client add'
    assert_success 'client remove restarts the real service' logged manager remove qa-two
    service_checks 'after client remove'

    bundle0=$(bundle)
    unit_before=$(sha256sum /etc/systemd/system/xray-vps-kit.service)
    fixture=/root/xvk-kit-0.2.0
    make_kit "$fixture" 0.2.0
    assert_success 'coherent update succeeds' kit_update "$fixture" --archive "$XVK_ARCHIVE"
    bundle1=$(bundle)
    assert_failure 'update selected a new bundle' test "$bundle1" = "$bundle0"
    service_checks 'after update'
    assert_eq 1 "$(marker_rows)" 'update keeps exactly one owned UFW rule'
    fixture_unchanged update "$before"

    make_kit /root/xvk-kit-0.3.0 0.3.0
    sed -i 's|^ExecStartPre=/opt/xray-vps-kit/current/xray run -test.*|ExecStartPre=/bin/false|' /root/xvk-kit-0.3.0/templates/xray-vps-kit.service
    assert_failure 'update whose service cannot start is refused' kit_update /root/xvk-kit-0.3.0 --archive "$XVK_ARCHIVE"
    assert_eq "$bundle1" "$(bundle)" 'failed activation restores the previous bundle selection'
    service_checks 'after failed activation'
    assert_eq 1 "$(marker_rows)" 'failed activation leaves one owned UFW rule'

    assert_success 'guarded rollback succeeds' kit_update "$fixture" --rollback
    assert_eq "$bundle0" "$(bundle)" 'rollback restores the original bundle'
    assert_eq "$unit_before" "$(sha256sum /etc/systemd/system/xray-vps-kit.service)" 'rollback restores the original unit bytes'
    service_checks 'after rollback'
    fixture_unchanged rollback "$before"
    assert_success 'UDP fixture exchange was uninterrupted through install, client changes, update and rollback' udp_monitor_stop
    fixture_unchanged 'end of phase a' "$before"
}

phase_lifecycle_b() {
    local before state_before identity_before
    prepare keep-kit
    assert_success 'service recovered after the guest reboot' systemctl is-active --quiet xray-vps-kit.service
    assert_success 'service is enabled' systemctl is-enabled --quiet xray-vps-kit.service
    service_checks 'after reboot'
    assert_eq 1 "$(marker_rows)" 'owned UFW rule persisted across the reboot'
    assert_success 'AWG echo fixture unit recovered after the reboot' systemctl is-active --quiet awg-fixture-echo.service
    before=$(awg_view)
    udp_monitor_start

    identity_before=$(jq -c 'del(.generation,.installed,.lastSuccessfulSnapshot)' /etc/xray-vps-kit/state.json)
    state_before=$(sha256sum /etc/xray-vps-kit/config.json)
    assert_success 'uninstall --keep-config succeeds' uninstall_kit --keep-config
    removed_checks 'after uninstall --keep-config'
    assert_success 'state is kept for restore' test -f /etc/xray-vps-kit/state.json
    foreign_listener_start 443
    assert_failure 'after uninstall the blocked state is effective again' peer_tcp 443
    foreign_listener_stop
    fixture_unchanged 'keep-config uninstall' "$before"
    assert_success 'service account is retained' getent passwd xray-vps-kit

    assert_success 'install --restore recreates the service' restore_kit
    service_checks restore
    assert_eq "$identity_before" "$(jq -c 'del(.generation,.installed,.lastSuccessfulSnapshot)' /etc/xray-vps-kit/state.json)" 'restore keeps keys, endpoint and clients'
    assert_eq "$state_before" "$(sha256sum /etc/xray-vps-kit/config.json)" 'restore regenerates the identical config'
    assert_eq 1 "$(marker_rows)" 'restore opens exactly one owned rule'

    assert_success 'full uninstall succeeds' uninstall_kit
    removed_checks 'after full uninstall'
    assert_failure 'kit state is removed' test -e /etc/xray-vps-kit
    assert_success 'UDP fixture exchange was uninterrupted through uninstall, restore and removal' udp_monitor_stop
    fixture_unchanged 'full uninstall' "$before"
    assert_success 'service account is still retained' getent passwd xray-vps-kit
}

# firewall_scenario NAME MODE PORT EXPECTED_ROWS
firewall_scenario() {
    local name=$1 mode=$2 port=$3 rows=$4 before
    say "scenario: $name"
    ufw_baseline "$mode" "$port"
    before=$(awg_view)
    if [[ $mode != none ]]; then
        foreign_listener_start "$port"
        if [[ $mode == preexisting ]]; then
            assert_success "$name: an existing effective allow already admits the peer" peer_tcp "$port"
        else
            assert_failure "$name: the peer is blocked before the kit installs" peer_tcp "$port"
        fi
        foreign_listener_stop
    fi
    assert_success "$name: install on TCP$port succeeds" install_kit --port "$port"
    service_checks "$name" "$port"
    assert_eq "$rows" "$(marker_rows)" "$name: owned rule count"
    fixture_unchanged "$name install" "$before"
    assert_success "$name: uninstall succeeds" uninstall_kit
    removed_checks "$name"
    fixture_unchanged "$name uninstall" "$before"
    case $mode in
        deny|earlier-deny)
            foreign_listener_start "$port"
            assert_failure "$name: the foreign block is effective again after uninstall" peer_tcp "$port"
            foreign_listener_stop ;;
        preexisting)
            foreign_listener_start "$port"
            assert_success "$name: the preexisting allow still admits the peer" peer_tcp "$port"
            foreign_listener_stop ;;
    esac
    if [[ $mode == earlier-deny ]]; then
        assert_success "$name: the foreign deny rule survived" bash -c "ufw show added | grep -q 'deny.*port $port'"
    fi
}

# An identical foreign deny cannot be preceded by a CLI-inserted allow (ufw treats it as
# the same rule), so the kit must refuse cleanly instead of claiming the port is open.
shadowed_scenario() {
    local before
    say 'scenario: identical foreign deny shadows the owned allow'
    ufw_baseline identical-deny 18443
    before=$(awg_view)
    assert_failure 'shadowed port: install refuses' install_kit --port 18443
    assert_failure 'shadowed port: no kit state remains' test -e /etc/xray-vps-kit
    assert_failure 'shadowed port: no unit remains' test -e /etc/systemd/system/xray-vps-kit.service
    assert_failure 'shadowed port: no bundle remains' test -e /opt/xray-vps-kit
    assert_eq 0 "$(marker_rows)" 'shadowed port: no owned rule remains'
    assert_success 'shadowed port: the foreign deny is intact' bash -c "ufw show added | grep -q 'deny.*18443'"
    fixture_unchanged 'shadowed port' "$before"
}

case_selected_tcp_port_opened() {
    platform_report
    prepare
    firewall_scenario 'default deny' deny 443 1
    firewall_scenario 'explicit earlier TCP deny (peer-specific) on alternate port' earlier-deny 18443 1
    firewall_scenario 'preexisting effective allow' preexisting 443 0
    firewall_scenario 'inactive firewall' none 443 0
    shadowed_scenario
    # A reboot-persistence check lives in lifecycle-coexistence phase b.
}

case_occupied_port_and_rollback() {
    local before bundle1 unit_before
    platform_report
    prepare
    ufw_baseline deny
    before=$(awg_view)
    udp_monitor_start

    foreign_listener_start 443
    assert_failure 'a foreign TCP443 listener blocks the install' install_kit
    assert_failure 'refused install created no state' test -e /etc/xray-vps-kit
    assert_failure 'refused install created no unit' test -e /etc/systemd/system/xray-vps-kit.service
    assert_eq 0 "$(marker_rows)" 'refused install opened no firewall rule'
    assert_success 'the foreign listener is untouched' kill -0 "$listener_pid"
    foreign_listener_stop
    fixture_unchanged 'refused install' "$before"

    assert_success 'install succeeds once the port is free' install_kit
    service_checks install
    bundle1=$(bundle)
    unit_before=$(sha256sum /etc/systemd/system/xray-vps-kit.service)
    make_kit /root/xvk-kit-bad 0.2.0
    sed -i 's|^ExecStartPre=/opt/xray-vps-kit/current/xray run -test.*|ExecStartPre=/bin/false|' /root/xvk-kit-bad/templates/xray-vps-kit.service
    assert_failure 'bad activation update is refused' kit_update /root/xvk-kit-bad --archive "$XVK_ARCHIVE"
    assert_eq "$bundle1" "$(bundle)" 'bad activation restores the old bundle'
    assert_eq "$unit_before" "$(sha256sum /etc/systemd/system/xray-vps-kit.service)" 'bad activation restores the old unit'
    service_checks 'after bad activation'

    assert_success 'uninstall succeeds' uninstall_kit
    removed_checks uninstall
    fixture_unchanged 'rollback case uninstall' "$before"
    assert_success 'UDP fixture exchange survived the whole sequence' udp_monitor_stop

    # An unmanaged INPUT rule with UFW inactive is an unsupported firewall: refuse truthfully.
    ufw --force disable > /dev/null
    iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
    assert_failure 'an unmanaged iptables INPUT rule is an unsupported firewall' install_kit
    assert_failure 'unsupported firewall refusal created no state' test -e /etc/xray-vps-kit
    iptables -D INPUT -p tcp --dport 22 -j ACCEPT
    ufw_baseline deny
}

# Leave the guest reachable: never end a run with an enabled firewall that lacks the SSH rule
# or a DROP policy without UFW's jumps. Phase a keeps UFW on because the reboot check needs it.
leave_reachable() {
    pkill -f tcp-listener.py 2> /dev/null || true
    pkill -f udp-monitor.py 2> /dev/null || true
    ufw --force disable > /dev/null 2>&1 || true
    iptables -P INPUT ACCEPT 2> /dev/null || true
    ip6tables -P INPUT ACCEPT 2> /dev/null || true
}
[[ $case_name:$phase == lifecycle-coexistence:a ]] || trap leave_reachable EXIT

case "$case_name:$phase" in
    lifecycle-coexistence:a) phase_lifecycle_a ;;
    lifecycle-coexistence:b) phase_lifecycle_b ;;
    selected-tcp-port-opened:run) case_selected_tcp_port_opened ;;
    occupied-port-and-rollback:run) case_occupied_port_and_rollback ;;
    *) printf 'Unknown guest case/phase\n' >&2; exit 1 ;;
esac
test_finish
