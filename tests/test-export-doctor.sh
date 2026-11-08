#!/usr/bin/env bash
case "${1:-all}" in
    all|uri-text-qr-equivalence|unsafe-output-and-redaction|doctor-integrity-and-pid) selected=${1:-all} ;;
    *) printf 'Unknown export-doctor case\n' >&2; exit 1 ;;
esac
[[ -f $PROJECT_DIR/lib/diagnostics.sh ]] || { printf 'FAIL: export/doctor module not implemented\n' >&2; exit 1; }
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
if [[ $selected != unsafe-output-and-redaction && $selected != doctor-integrity-and-pid ]]; then
    command -v zbarimg > /dev/null || { printf 'Missing test-only QR decoder: zbarimg\n' >&2; exit 1; }
    real_qrencode=$(command -v qrencode)
    mkdir "$scratch/qr-bin"
    export XVK_REAL_QRENCODE="$real_qrencode" XVK_QR_INPUT="$scratch/qr-input" XVK_QR_PNG="$scratch/qr.png"
    cat > "$scratch/qr-bin/qrencode" <<'QR'
#!/usr/bin/env bash
set -euo pipefail
umask 077
cat > "$XVK_QR_INPUT"
"$XVK_REAL_QRENCODE" -o "$XVK_QR_PNG" < "$XVK_QR_INPUT"
exec "$XVK_REAL_QRENCODE" "$@" < "$XVK_QR_INPUT"
QR
    chmod 755 "$scratch/qr-bin/qrencode"
    bash "$manager" show main-user | grep '^vless://' > "$scratch/uri"
    assert_success 'URI export parses independently' python3 "$TESTS_DIR/helpers/uri-check.py" "$state" "$scratch/uri"
    bash "$manager" show main-user --fp firefox | grep '^vless://' > "$scratch/uri-firefox"
    assert_success 'show --fp firefox emits the firefox profile' grep -q -F '&fp=firefox&' "$scratch/uri-firefox"
    assert_success 'export --fp writes the same bytes as show --fp' bash "$manager" export main-user --output "$scratch/export-firefox" --fp firefox
    assert_success 'fingerprint export matches show including LF' cmp -s "$scratch/uri-firefox" "$scratch/export-firefox"
    assert_failure 'export with an unknown fingerprint is refused' bash "$manager" export main-user --output "$scratch/export-bad" --fp bogus
    assert_failure 'refused fingerprint export created no file' test -e "$scratch/export-bad"
    assert_success 'text export creates a new private file' bash "$manager" export main-user --output "$scratch/export"
    assert_eq 600 "$(stat -c %a "$scratch/export")" 'export mode is0600'
    assert_success 'URI and exported bytes match exactly including LF' cmp -s "$scratch/uri" "$scratch/export"
    PATH="$scratch/qr-bin:$PATH" bash "$manager" show main-user > "$scratch/terminal"
    assert_success 'show prints the URI and the QR heading' grep -q -e '^vless://' -e '^QR code:' "$scratch/terminal"
    zbarimg --quiet --raw "$scratch/qr.png" > "$scratch/decoded" 2>/dev/null
    assert_success 'real QR decodes to the exact same URI' cmp -s "$scratch/uri" "$scratch/decoded"
    printf '%s' "$(cat "$scratch/uri")" > "$scratch/without-lf"
    assert_success 'QR payload has no added newline' cmp -s "$scratch/without-lf" "$scratch/qr-input"
fi
if [[ $selected != uri-text-qr-equivalence && $selected != doctor-integrity-and-pid ]]; then
    printf 'foreign data\n' > "$scratch/foreign"
    assert_failure 'existing export file is never overwritten' bash "$manager" export main-user --output "$scratch/foreign"
    assert_eq 'foreign data' "$(cat "$scratch/foreign")" 'existing contents preserved'
    ln -s "$scratch/missing" "$scratch/link"
    assert_failure 'dangling output symlink is refused' bash "$manager" export main-user --output "$scratch/link"
    assert_failure 'symlink target was not created' test -e "$scratch/missing"
    uuid=$(jq -r '.clients[] | select(.name=="main-user") | .uuid' "$state")
    assert_success 'sing-box export succeeds' bash "$manager" export main-user --output "$scratch/export-singbox" --format singbox --fp firefox
    assert_eq 600 "$(stat -c %a "$scratch/export-singbox")" 'sing-box export is private'
    assert_eq "$uuid" "$(jq -r .uuid "$scratch/export-singbox")" 'sing-box outbound carries the client uuid'
    assert_eq firefox "$(jq -r .tls.utls.fingerprint "$scratch/export-singbox")" 'sing-box outbound carries the fingerprint'
    assert_eq "$(jq -r .publicKey "$state")" "$(jq -r .tls.reality.public_key "$scratch/export-singbox")" 'sing-box outbound carries the public key'
    assert_success 'Clash export succeeds' bash "$manager" export main-user --output "$scratch/export-clash" --format clash
    assert_success 'Clash proxy names the uuid' grep -q -F "uuid: \"$uuid\"" "$scratch/export-clash"
    assert_success 'Clash proxy is a REALITY Vision entry' grep -q -F 'flow: xtls-rprx-vision' "$scratch/export-clash"
    assert_failure 'unknown export format is refused' bash "$manager" export main-user --output "$scratch/export-fmt" --format xml
    assert_failure 'refused format created no file' test -e "$scratch/export-fmt"
    assert_failure 'a repeated option is refused' bash "$manager" export main-user --output "$scratch/export-dup" --format clash --format uri
    assert_eq '[{"name":"main-user"}]' "$(bash "$manager" list --json)" 'list --json prints names only'
    assert_failure 'list rejects other arguments' bash "$manager" list --yaml
    doctor_status=0
    bash "$manager" doctor > "$scratch/doctor" 2>&1 || doctor_status=$?
    assert_failure 'sandbox doctor cannot falsely report live service health' test "$doctor_status" -eq 0
    assert_success 'doctor ends with the fingerprint note' grep -q -F 'xray-client show NAME --fp firefox' "$scratch/doctor"
    for secret in "$(jq -r .privateKey "$state")" "$(jq -r '.clients[0].uuid' "$state")"; do
        assert_failure 'doctor output contains no credential sentinel' grep -Fq "$secret" "$scratch/doctor"
    done
    cp -p "$root/etc/xray-vps-kit/config.json" "$scratch/doctor-valid-config"
    printf 'broken config\n' > "$root/etc/xray-vps-kit/config.json"
    assert_failure 'invalid config makes doctor fail' bash "$manager" doctor
    cp -p "$scratch/doctor-valid-config" "$root/etc/xray-vps-kit/config.json"
fi

if [[ $selected == all || $selected == doctor-integrity-and-pid ]]; then
    port=$(jq -r .port "$state")
    bindir="$scratch/doctor-bin"
    mkdir "$bindir"
    cat > "$bindir/systemctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    'is-active --quiet xray-vps-kit.service') [[ ${XVK_DOCTOR_ACTIVE:-0} == 1 ]] ;;
    'show --property=MainPID --value xray-vps-kit.service') printf '%s\n' "${XVK_DOCTOR_PID:-0}" ;;
    *) exit 1 ;;
esac
STUB
    cat > "$bindir/ss" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ ${XVK_DOCTOR_SS_FAIL:-0} != 1 ]] || exit 1
[[ -n ${XVK_DOCTOR_SS_OUTPUT:-} ]] || exit 0
printf '%s\n' "$XVK_DOCTOR_SS_OUTPUT"
STUB
    chmod 755 "$bindir/systemctl" "$bindir/ss"
    listener="LISTEN 0 128 0.0.0.0:$port 0.0.0.0:* users:((\"xray\",pid=4242,fd=3))"
    doctor_run() {
        local log=$1 status=0
        shift
        env "$@" PATH="$bindir:$PATH" bash "$manager" doctor > "$log" 2>&1 || status=$?
        printf '%s\n' "$status"
    }
    assert_eq 0 "$(doctor_run "$scratch/doctor-healthy" XVK_DOCTOR_ACTIVE=1 XVK_DOCTOR_PID=4242 \
        XVK_DOCTOR_SS_OUTPUT="$listener")" 'healthy service with its own listener passes'
    assert_success 'doctor reports the owned listener' grep -q 'listening socket belongs to the service' "$scratch/doctor-healthy"

    unrelated="LISTEN 0 128 0.0.0.0:$port 0.0.0.0:* users:((\"other\",pid=9999,fd=3))"
    assert_failure 'an unrelated listener is not accepted as healthy' \
        test "$(doctor_run "$scratch/doctor-unrelated" XVK_DOCTOR_ACTIVE=1 XVK_DOCTOR_PID=4242 \
            XVK_DOCTOR_SS_OUTPUT="$unrelated")" -eq 0
    assert_success 'the unrelated listener is reported as a failure' \
        grep -q '\[FAIL\] listening socket belongs to the service' "$scratch/doctor-unrelated"

    assert_failure 'a missing MainPID is not accepted as healthy' \
        test "$(doctor_run "$scratch/doctor-nopid" XVK_DOCTOR_ACTIVE=1 XVK_DOCTOR_PID=0 \
            XVK_DOCTOR_SS_OUTPUT="$listener")" -eq 0
    assert_failure 'a failing listener probe is not accepted as healthy' \
        test "$(doctor_run "$scratch/doctor-ssfail" XVK_DOCTOR_ACTIVE=1 XVK_DOCTOR_PID=4242 XVK_DOCTOR_SS_FAIL=1)" -eq 0

    # Integrity drift: a changed owned launcher and a malformed manifest must both
    # fail the report even though state.json and config.json remain valid.
    cp -p "$manager" "$scratch/launcher-backup"
    printf '# drift\n' >> "$manager"
    assert_failure 'a changed owned launcher fails doctor' \
        test "$(doctor_run "$scratch/doctor-drift" XVK_DOCTOR_ACTIVE=1 XVK_DOCTOR_PID=4242 \
            XVK_DOCTOR_SS_OUTPUT="$listener")" -eq 0
    assert_success 'drift is reported as a manifest failure' \
        grep -q '\[FAIL\] installed state and manifest' "$scratch/doctor-drift"
    cp -p "$scratch/launcher-backup" "$manager"

    manifest="$root/etc/xray-vps-kit/ownership.json"
    cp -p "$manifest" "$scratch/manifest-backup"
    printf 'not json\n' > "$manifest"
    assert_failure 'a malformed ownership manifest fails doctor' \
        test "$(doctor_run "$scratch/doctor-manifest" XVK_DOCTOR_ACTIVE=1 XVK_DOCTOR_PID=4242 \
            XVK_DOCTOR_SS_OUTPUT="$listener")" -eq 0
    for secret in "$(jq -r .privateKey "$state")" "$(jq -r '.clients[0].uuid' "$state")"; do
        assert_failure 'integrity failures leak no credential sentinel' grep -Fq "$secret" "$scratch/doctor-manifest"
    done
    cp -p "$scratch/manifest-backup" "$manifest"
    assert_eq 0 "$(doctor_run "$scratch/doctor-restored" XVK_DOCTOR_ACTIVE=1 XVK_DOCTOR_PID=4242 \
        XVK_DOCTOR_SS_OUTPUT="$listener")" 'restoring the manifest makes doctor pass again'
fi
