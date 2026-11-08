#!/usr/bin/env bash
# block-ping with stubbed id, ip, nft and systemctl: no firewall or service is touched.
case "${1:-all}" in
    all|on-and-redetect|explicit-interfaces|refusals-and-off) ;;
    *) printf 'Unknown block-ping case\n' >&2; exit 1 ;;
esac
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin"
export BLOCK_PING_DIR="$scratch/etc/block-ping" BLOCK_PING_UNIT="$scratch/block-ping.service"
export STUB_LOG="$scratch/calls" STUB_ROUTE="$scratch/route"
cat > "$scratch/bin/id" <<'STUB'
#!/usr/bin/env bash
echo 0
STUB
cat > "$scratch/bin/ip" <<'STUB'
#!/usr/bin/env bash
[[ $1 == -4 && -s $STUB_ROUTE ]] && cat "$STUB_ROUTE"
exit 0
STUB
cat > "$scratch/bin/nft" <<'STUB'
#!/usr/bin/env bash
printf 'nft %s\n' "$*" >> "$STUB_LOG"
[[ $1 == list ]] && exit 1
exit 0
STUB
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$scratch"/bin/*
export PATH="$scratch/bin:$PATH"
route() { printf 'default via 192.0.2.1 dev %s proto static\n' "$1" > "$STUB_ROUTE"; }
block_ping() { bash "$PROJECT_DIR/block-ping" "$@"; }
reset() { rm -rf "${scratch:?}/etc" "${scratch:?}/block-ping.service" "$STUB_LOG" "$STUB_ROUTE"; : > "$STUB_LOG"; }


assert_failure 'the script does not point at the sibling project' grep -q 'awg-vps-kit' "$PROJECT_DIR/block-ping"
assert_eq '#!/usr/bin/env bash' "$(head -n 1 "$PROJECT_DIR/block-ping")" 'portable shebang'
assert_failure 'no hardcoded nft path in the script' grep -q '/usr/sbin/nft' "$PROJECT_DIR/block-ping"

if [[ ${1:-all} == all || $1 == on-and-redetect ]]; then
    reset; route eth0
    assert_success 'on succeeds with a default route' block_ping on
    assert_success 'helper is installed' test -x "$BLOCK_PING_DIR/apply"
    assert_failure 'no fixed interface file in auto mode' test -e "$BLOCK_PING_DIR/wan-if"
    assert_success 'unit follows nftables reloads' grep -q '^ReloadPropagatedFrom=nftables.service' "$BLOCK_PING_UNIT"
    assert_success 'unit follows nftables restarts' grep -q '^PartOf=nftables.service' "$BLOCK_PING_UNIT"
    assert_success 'unit starts the helper' grep -q "^ExecStart=$BLOCK_PING_DIR/apply" "$BLOCK_PING_UNIT"
    assert_success 'unit reload runs the helper' grep -q "^ExecReload=$BLOCK_PING_DIR/apply" "$BLOCK_PING_UNIT"
    assert_failure 'unit hardcodes no nft path' grep -q '/usr/sbin/nft' "$BLOCK_PING_UNIT"
    assert_success 'service is enabled and restarted' grep -q '^systemctl restart block-ping' "$STUB_LOG"
    assert_success 'helper writes rules for the current uplink' bash "$BLOCK_PING_DIR/apply"
    assert_success 'rules name eth0' grep -q 'iifname { "eth0" } icmp type echo-request' "$BLOCK_PING_DIR/rules.nft"
    assert_success 'rules cover ICMPv6' grep -q 'icmpv6 type echo-request' "$BLOCK_PING_DIR/rules.nft"
    assert_success 'rules were checked before loading' grep -q "^nft -c -f $BLOCK_PING_DIR/rules.nft" "$STUB_LOG"
    route ens3
    assert_success 'helper re-detects a changed uplink' bash "$BLOCK_PING_DIR/apply"
    assert_success 'rules now name ens3' grep -q 'iifname { "ens3" } icmp type echo-request' "$BLOCK_PING_DIR/rules.nft"
    assert_failure 'rules no longer name eth0' grep -q '"eth0"' "$BLOCK_PING_DIR/rules.nft"
    : > "$STUB_ROUTE"
    assert_failure 'helper refuses to run without an uplink' bash "$BLOCK_PING_DIR/apply"
fi

if [[ ${1:-all} == all || $1 == explicit-interfaces ]]; then
    reset
    assert_success 'on --wan-if works without a default route' block_ping on --wan-if eth0,eth1
    assert_eq 'eth0 eth1' "$(cat "$BLOCK_PING_DIR/wan-if")" 'chosen interfaces are stored'
    assert_success 'helper uses the chosen interfaces' bash "$BLOCK_PING_DIR/apply"
    assert_success 'rules name both interfaces' grep -q 'iifname { "eth0", "eth1" } icmp type' "$BLOCK_PING_DIR/rules.nft"
    route ens3
    assert_success 'a later route change does not override the choice' bash "$BLOCK_PING_DIR/apply"
    assert_failure 'the chosen interfaces stay in force' grep -q '"ens3"' "$BLOCK_PING_DIR/rules.nft"
    assert_success 'switching back to auto mode works' block_ping on
    assert_failure 'auto mode removes the stored choice' test -e "$BLOCK_PING_DIR/wan-if"
fi

if [[ ${1:-all} == all || $1 == refusals-and-off ]]; then
    reset
    assert_failure 'on without an uplink is refused' block_ping on
    assert_failure 'nothing is installed after the refusal' test -e "$BLOCK_PING_UNIT"
    assert_failure 'a bad interface name is refused' block_ping on --wan-if 'eth0;reboot'
    assert_failure 'an empty --wan-if is refused' block_ping on --wan-if
    assert_failure 'unknown option is refused' block_ping on --bogus
    assert_failure '--wan-if is refused for status' block_ping status --wan-if eth0
    assert_failure 'unknown command is refused' block_ping wat
    route eth0
    block_ping on > /dev/null
    assert_success 'status reports not active when the table is absent' block_ping status
    assert_success 'off succeeds' block_ping off
    assert_failure 'off removes the unit' test -e "$BLOCK_PING_UNIT"
    assert_failure 'off removes the whole state directory' test -e "$BLOCK_PING_DIR"
    assert_success 'off deleted the nft table' grep -q '^nft delete table inet block_ping' "$STUB_LOG"
fi
