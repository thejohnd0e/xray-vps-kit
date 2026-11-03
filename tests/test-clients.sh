#!/usr/bin/env bash
case "${1:-all}" in
    all|add-list-show-remove|failed-add-and-remove|concurrent-mutations) selected=${1:-all} ;;
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
if [[ $selected != failed-add-and-remove && $selected != concurrent-mutations ]]; then
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
    bash "$manager" show phone --fp firefox | grep '^vless://' > "$scratch/profile-firefox"
    assert_success 'show --fp firefox prints that fingerprint' grep -q -F '&fp=firefox&' "$scratch/profile-firefox"
    assert_success 'show --fp changes only the fingerprint' cmp -s "$scratch/profile-firefox" <(sed 's/&fp=chrome&/\&fp=firefox\&/' "$scratch/profile")
    assert_failure 'show with an unknown fingerprint fails' bash "$manager" show phone --fp bogus
    assert_failure 'show with a stray argument fails' bash "$manager" show phone --fingerprint firefox
    bash "$manager" add fpdevice --fp safari | grep '^vless://' > "$scratch/add-safari"
    assert_success 'add --fp safari prints that fingerprint' grep -q -F '&fp=safari&' "$scratch/add-safari"
    assert_failure 'add with an unknown fingerprint creates no client' bash "$manager" add fpbad --fp bogus
    assert_failure 'rejected fingerprint left no client behind' bash "$manager" show fpbad
    bash "$manager" remove fpdevice
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
if [[ $selected != add-list-show-remove && $selected != concurrent-mutations ]]; then
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

if [[ $selected == all || $selected == concurrent-mutations ]]; then
    lock="$root/run/lock/xray-vps-kit.lock"
    generation_before=$(jq -r .generation "$state")
    umask 077
    exec 9>>"$lock"
    flock -x 9
    bash "$manager" add alpha > "$scratch/alpha.log" 2>&1 &
    alpha_pid=$!
    bash "$manager" add beta > "$scratch/beta.log" 2>&1 &
    beta_pid=$!
    sleep 2
    flock -u 9
    exec 9>&-
    alpha_status=0
    wait "$alpha_pid" || alpha_status=$?
    beta_status=0
    wait "$beta_pid" || beta_status=$?
    assert_eq 0 "$alpha_status" 'first queued add succeeds'
    assert_eq 0 "$beta_status" 'second queued add succeeds'
    assert_eq "$((generation_before + 2))" "$(jq -r .generation "$state")" 'both queued adds advance one generation each'
    assert_eq 'alpha,beta' "$(bash "$manager" list | grep -E '^(alpha|beta)$' | LC_ALL=C sort | paste -sd ,)" \
        'both concurrent clients exist'
    assert_success 'concurrent adds leave a readable install' bash "$manager" list

    exec 9>>"$lock"
    flock -x 9
    bash "$manager" add same > "$scratch/same-a.log" 2>&1 &
    same_a=$!
    bash "$manager" add same > "$scratch/same-b.log" 2>&1 &
    same_b=$!
    sleep 2
    flock -u 9
    exec 9>&-
    same_a_status=0
    wait "$same_a" || same_a_status=$?
    same_b_status=0
    wait "$same_b" || same_b_status=$?
    assert_eq 1 "$(( (same_a_status == 0) + (same_b_status == 0) ))" \
        'exactly one of two identical queued adds succeeds'
    assert_eq 1 "$(jq '[.clients[]|select(.name=="same")]|length' "$state")" \
        'the duplicate-name race creates exactly one client'
    assert_success 'the losing add reports a duplicate name' grep -q 'already exists' "$scratch/same-a.log" "$scratch/same-b.log"

    # A held lock must fail cleanly and leave no stage or state change behind.
    before_timeout=$(sha256sum "$state")
    flock "$lock" sleep 8 &
    holder=$!
    sleep 0.5
    timeout_status=0
    env XVK_LOCK_TIMEOUT=2 bash "$manager" add slow > /dev/null 2>&1 || timeout_status=$?
    assert_failure 'a held lock makes the mutation fail instead of racing' test "$timeout_status" -eq 0
    assert_eq "$before_timeout" "$(sha256sum "$state")" 'lock timeout leaves state unchanged'
    assert_eq '' "$(find "$root/etc/xray-vps-kit" -maxdepth 1 -name '.stage.*' -print -quit)" \
        'lock timeout leaves no stage directory'
    wait "$holder" || true
fi
