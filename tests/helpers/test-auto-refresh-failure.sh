#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers/assert.sh
source "$TESTS_DIR/helpers/assert.sh"
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
for module in common state release render ownership transaction snapshot bundle service firewall dependencies preflight update-lifecycle auto-owned auto-lifecycle; do
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/$module.sh"
done
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_test_probe_path "$scratch"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
root=$(mktemp -d "$scratch/root.XXXXXXXX")
xvk_test_install "$root" "$archive" > /dev/null
export XVK_ROOT="$root" XVK_SANDBOX=true XVK_ARCH=amd64
xvk_auto_enable "$PROJECT_DIR" "$root" > /dev/null
control="$root/var/lib/xray-vps-kit-auto-update/control.json"
job="$root/etc/cron.d/xray-vps-kit-auto-update"
payload_before=$(xvk_auto_payload_manifest "$root/opt/xray-vps-kit-auto-update")
assert_eq enabled "$(jq -r .mode "$control")" 'worker starts enabled'
# Force the refresh to fail after the new worker is staged, at the cron write.
chmod 500 "$root/etc/cron.d"
assert_failure 'a failed refresh of an enabled worker reports failure' \
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_auto_install_locked "$PROJECT_DIR" "$root" enabled
chmod 755 "$root/etc/cron.d"
assert_eq enabled "$(jq -r .mode "$control")" 'failed refresh restores the prior enabled mode'
assert_success 'failed refresh leaves the previous worker payload intact and valid' xvk_auto_verify "$root"
assert_eq "$payload_before" "$(xvk_auto_payload_manifest "$root/opt/xray-vps-kit-auto-update")" 'failed refresh keeps the exact previous worker payload'
assert_success 'the cron job survives a failed refresh' test -f "$job"
# A paused worker must not be silently downgraded to disabled by a failed refresh either.
xvk_auto_pause "$root" > /dev/null
chmod 500 "$root/etc/cron.d"
assert_failure 'failed refresh of a paused worker reports failure' \
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_auto_install_locked "$PROJECT_DIR" "$root" enabled
chmod 755 "$root/etc/cron.d"
assert_eq paused "$(jq -r .mode "$control")" 'failed refresh restores the paused mode'
assert_eq rollback "$(jq -r .reason "$control")" 'failed refresh preserves the pause reason'
assert_success 'restored paused worker remains structurally valid' xvk_auto_verify "$root"
test_finish
