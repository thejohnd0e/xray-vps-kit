#!/usr/bin/env bash
case "${1:-all}" in
    all|uri-text-qr-equivalence|unsafe-output-and-redaction) selected=${1:-all} ;;
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
if [[ $selected != unsafe-output-and-redaction ]]; then
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
    bash "$manager" show main-user --uri > "$scratch/uri"
    assert_success 'URI export parses independently' python3 "$TESTS_DIR/helpers/uri-check.py" "$state" "$scratch/uri"
    assert_success 'text export creates a new private file' bash "$manager" export main-user --output "$scratch/export"
    assert_eq 600 "$(stat -c %a "$scratch/export")" 'export mode is0600'
    assert_success 'URI and exported bytes match exactly including LF' cmp -s "$scratch/uri" "$scratch/export"
    PATH="$scratch/qr-bin:$PATH" bash "$manager" show main-user > "$scratch/terminal"
    zbarimg --quiet --raw "$scratch/qr.png" > "$scratch/decoded" 2>/dev/null
    assert_success 'real QR decodes to the exact same URI' cmp -s "$scratch/uri" "$scratch/decoded"
    printf '%s' "$(cat "$scratch/uri")" > "$scratch/without-lf"
    assert_success 'QR payload has no added newline' cmp -s "$scratch/without-lf" "$scratch/qr-input"
fi
if [[ $selected != uri-text-qr-equivalence ]]; then
    printf 'foreign data\n' > "$scratch/foreign"
    assert_failure 'existing export file is never overwritten' bash "$manager" export main-user --output "$scratch/foreign"
    assert_eq 'foreign data' "$(cat "$scratch/foreign")" 'existing contents preserved'
    ln -s "$scratch/missing" "$scratch/link"
    assert_failure 'dangling output symlink is refused' bash "$manager" export main-user --output "$scratch/link"
    assert_failure 'symlink target was not created' test -e "$scratch/missing"
    doctor_status=0
    bash "$manager" doctor > "$scratch/doctor" 2>&1 || doctor_status=$?
    assert_failure 'sandbox doctor cannot falsely report live service health' test "$doctor_status" -eq 0
    for secret in "$(jq -r .privateKey "$state")" "$(jq -r '.clients[0].uuid' "$state")"; do
        assert_failure 'doctor output contains no credential sentinel' grep -Fq "$secret" "$scratch/doctor"
    done
    printf 'broken config\n' > "$root/etc/xray-vps-kit/config.json"
    assert_failure 'invalid config makes doctor fail' bash "$manager" doctor
fi
