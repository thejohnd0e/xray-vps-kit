#!/usr/bin/env bash
case "${1:-all}" in
    all|sandbox-ownership) selected=${1:-all} ;;
    *) printf 'Unknown coexistence case\n' >&2; exit 1 ;;
esac
# Sandbox ownership fixture: AWG-named files sit beside a kit installation while the kit is
# installed, changed, updated, rolled back and removed. A real UDP echo keeps answering
# throughout. This proves file-level non-interference only; nft/sysctl/UFW and systemd
# behavior are covered by tests/run-vm.sh in a disposable guest, and no AWG handshake is claimed.
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
scratch=$(mktemp -d)
echo_pid='' monitor_pid=''
cleanup() {
    local pid
    for pid in "$echo_pid" "$monitor_pid"; do
        [[ -z $pid ]] || { kill "$pid" 2> /dev/null || true; wait "$pid" 2> /dev/null || true; }
    done
    rm -rf -- "$scratch"
}
trap cleanup EXIT
xvk_test_probe_path "$scratch"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)

cat > "$scratch/echo.py" <<'PY'
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 0))
open(sys.argv[1], "w").write(str(sock.getsockname()[1]))
while True:
    data, peer = sock.recvfrom(2048)
    sock.sendto(data, peer)
PY
cat > "$scratch/monitor.py" <<'PY'
import signal, socket, sys, time
port, out = int(sys.argv[1]), sys.argv[2]
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
    sock.sendto(b"p%d" % sent, ("127.0.0.1", port))
    try:
        if sock.recvfrom(64)[0] == b"p%d" % sent:
            received += 1
    except OSError:
        pass
    time.sleep(0.05)
open(out, "w").write(f"{sent} {received}\n")
PY

fixture_view() {
    (cd -- "$1" && find etc/amnezia etc/sysctl.d etc/systemd/system/awg-quick@awg0.service usr/local/bin/awg-client \
        -type f -printf '%p %m\n' -exec sha256sum {} + | LC_ALL=C sort)
}

if [[ $selected == all || $selected == sandbox-ownership ]]; then
    root=$(mktemp -d "$scratch/root.XXXXXXXX")
    mkdir -p "$root/etc/amnezia/amneziawg" "$root/etc/sysctl.d" "$root/etc/systemd/system" "$root/usr/local/bin"
    printf '[Interface]\n# fixture, not a key\nListenPort = 443\n' > "$root/etc/amnezia/amneziawg/awg0.conf"
    printf 'net.ipv4.ip_forward = 1\n' > "$root/etc/sysctl.d/99-awg-fixture.conf"
    printf '[Unit]\nDescription=AWG-named fixture\n' > "$root/etc/systemd/system/awg-quick@awg0.service"
    printf '#!/bin/sh\necho awg fixture\n' > "$root/usr/local/bin/awg-client"
    chmod 755 "$root/usr/local/bin/awg-client"
    before=$(fixture_view "$root")

    python3 "$scratch/echo.py" "$scratch/port" &
    echo_pid=$!
    for _ in $(seq 1 50); do [[ -s $scratch/port ]] && break; sleep 0.1; done
    port=$(cat "$scratch/port")
    python3 "$scratch/monitor.py" "$port" "$scratch/udp-result" &
    monitor_pid=$!
    sleep 1

    # The installer wants an empty root, so the fixture is laid down after the install.
    kit_root=$(mktemp -d "$scratch/kit.XXXXXXXX")
    xvk_test_install "$kit_root" "$archive" > /dev/null
    cp -a "$root/." "$kit_root/"
    fixture_before=$(fixture_view "$kit_root")
    assert_eq "$before" "$fixture_before" 'fixture is byte-identical beside the installed kit'
    manager="$kit_root/usr/local/bin/xray-client"
    assert_success 'client add beside the fixture' bash "$manager" add other-user
    assert_success 'client remove beside the fixture' bash "$manager" remove other-user

    kit="$scratch/kit-0.2.0"
    mkdir -p "$kit"
    cp "$PROJECT_DIR/xray-client" "$PROJECT_DIR/update.sh" "$kit/"
    cp -a "$PROJECT_DIR/lib" "$PROJECT_DIR/releases" "$PROJECT_DIR/templates" "$kit/"
    printf '0.2.0\n' > "$kit/VERSION"
    assert_success 'update beside the fixture' bash "$kit/update.sh" --root "$kit_root" --archive "$archive"
    assert_success 'rollback beside the fixture' bash "$kit/update.sh" --rollback --root "$kit_root"
    assert_success 'uninstall --keep-config beside the fixture' bash "$PROJECT_DIR/uninstall.sh" --root "$kit_root" --yes --keep-config
    assert_success 'restore beside the fixture' \
        bash "$PROJECT_DIR/install.sh" --restore --non-interactive --no-service --root "$kit_root" --archive "$archive"
    assert_success 'full uninstall beside the fixture' bash "$PROJECT_DIR/uninstall.sh" --root "$kit_root" --yes
    assert_eq "$before" "$(fixture_view "$kit_root")" 'fixture files and modes are unchanged after the whole lifecycle'
    leftovers=$(cd "$kit_root" && find . -mindepth 1 -type f | grep -c 'xray-vps-kit' | tr -d ' ')
    assert_eq 1 "$leftovers" 'only the mutation lock file still carries the kit name'

    kill -TERM "$monitor_pid"
    wait "$monitor_pid" 2> /dev/null || true
    monitor_pid=''
    read -r sent received < "$scratch/udp-result"
    assert_success "UDP echo answered throughout (sent $sent, received $received)" test "$sent" -gt 20 -a "$received" -ge "$((sent - 1))"
fi
