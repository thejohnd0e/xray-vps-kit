#!/usr/bin/env bash
case "${1:-all}" in
    all|add-list-show-remove|failed-add-and-remove) selected=${1:-all} ;;
    *) printf 'Unknown clients case\n' >&2; exit 1 ;;
esac
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_test_probe_path "$scratch"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
root=$(mktemp -d "$scratch/root.XXXXXXXX")
xvk_test_install "$root" "$archive" > /dev/null
manager="$root/usr/local/bin/xray-client"
state="$root/etc/xray-vps-kit/state.json"
config="$root/etc/xray-vps-kit/config.json"
if [[ $selected != failed-add-and-remove ]]; then
    assert_success 'add phone commits and exports a profile' bash "$manager" add phone
    assert_success 'add tablet survives fresh process state load' bash "$manager" add tablet
    bash "$manager" add printed > "$scratch/add-output"
    assert_success 'add prints the URI and a QR code' grep -q -e '^vless://' -e '^QR code:' "$scratch/add-output"
    assert_eq 2 "$(grep -c -e '^vless://' -e '^QR code:' "$scratch/add-output")" 'add output has both the URI and the QR heading'
    bash "$manager" remove printed
    assert_eq 'main-user,phone,tablet' "$(bash "$manager" list | LC_ALL=C sort | paste -sd ,)" 'list contains only client names'
    bash "$manager" show phone | grep '^vless://' > "$scratch/profile"
    jq '.clients |= map(select(.name=="phone"))' "$state" > "$scratch/selected-state.json"
    assert_success 'show profile independently parses to stored identity' python3 "$TESTS_DIR/helpers/uri-check.py" "$scratch/selected-state.json" "$scratch/profile"
    phone_uuid=$(jq -r '.clients[]|select(.name=="phone")|.uuid' "$state")
    phone_sid=$(jq -r '.clients[]|select(.name=="phone")|.shortId' "$state")
    survivor=$(jq -c '.clients[]|select(.name=="tablet")' "$state")
    assert_success 'remove phone commits revocation' bash "$manager" remove phone
    assert_eq "$survivor" "$(jq -c '.clients[]|select(.name=="tablet")' "$state")" 'survivor identity remains unchanged'
    # jq variables intentionally remain literal.
    # shellcheck disable=SC2016
    assert_success 'revoked UUID and shortId absent from config' jq -e --arg uuid "$phone_uuid" --arg sid "$phone_sid" \
        '[..|strings]|index($uuid)==null and index($sid)==null' "$config"
    assert_failure 'removed profile is no longer exportable' bash "$manager" show phone
fi
if [[ $selected != add-list-show-remove ]]; then
    before=$(sha256sum "$state")
    assert_failure 'duplicate name is rejected' bash "$manager" add main-user
    assert_failure 'unknown removal is rejected' bash "$manager" remove absent
    assert_eq "$before" "$(sha256sum "$state")" 'duplicate and unknown operations leave state unchanged'
    cp -p "$config" "$scratch/original-config"
    printf '\n' >> "$config"
    status=0
    bash "$manager" add rejected > "$scratch/failed-add.stdout" 2> "$scratch/failed-add.stderr" || status=$?
    assert_failure 'drifted candidate add returns failure' test "$status" -eq 0
    assert_eq '' "$(cat "$scratch/failed-add.stdout")" 'failed add issues no profile'
    assert_failure 'drifted removal cannot report success' bash "$manager" remove main-user
    assert_eq "$before" "$(sha256sum "$state")" 'failed mutations preserve all state bytes'
    cp -p "$scratch/original-config" "$config"
    assert_success 'version has no root-state dependency' bash "$PROJECT_DIR/xray-client" version
    assert_success 'help has no root-state dependency' bash "$PROJECT_DIR/xray-client" help
    assert_failure 'source checkout cannot manage installed state implicitly' bash "$PROJECT_DIR/xray-client" list
fi
