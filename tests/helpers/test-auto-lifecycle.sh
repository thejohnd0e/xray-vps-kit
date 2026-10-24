#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers/assert.sh
source "$TESTS_DIR/helpers/assert.sh"
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
for module in common state release render ownership transaction snapshot bundle service firewall auto-owned update-lifecycle; do
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/$module.sh"
done
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_test_probe_path "$scratch"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
root=$(mktemp -d "$scratch/root.XXXXXXXX")
xvk_test_install "$root" "$archive" > /dev/null
bash "$PROJECT_DIR/auto-update.sh" enable --root "$root" > /dev/null
fixture="$scratch/kit"
mkdir "$fixture"
cp "$PROJECT_DIR/VERSION" "$PROJECT_DIR/xray-client" "$PROJECT_DIR/update.sh" "$fixture/"
cp -a "$PROJECT_DIR/lib" "$PROJECT_DIR/releases" "$PROJECT_DIR/templates" "$fixture/"
printf '0.2.0\n' > "$fixture/VERSION"
bash "$fixture/update.sh" --root "$root" --archive "$archive" > /dev/null
control="$root/var/lib/xray-vps-kit-auto-update/control.json"
job="$root/etc/cron.d/xray-vps-kit-auto-update"
cp "$job" "$scratch/job-original"
assert_success 'manual rollback succeeds with the optional scheduler installed' bash "$PROJECT_DIR/update.sh" --rollback --root "$root"
assert_eq paused "$(jq -r .mode "$control")" 'successful manual rollback pauses scheduled updates'
assert_success 'a paused scheduled invocation cannot silently upgrade again' bash "$PROJECT_DIR/auto-update.sh" scheduled --root "$root"
assert_success 'explicit enable resumes after manual rollback' bash "$PROJECT_DIR/auto-update.sh" enable --root "$root"
assert_eq enabled "$(jq -r .mode "$control")" 'enable clears the rollback pause'
bash "$fixture/update.sh" --root "$root" --archive "$archive" > /dev/null
before_control=$(sha256sum "$control")
before_state=$(sha256sum "$root/etc/xray-vps-kit/state.json")
auto_test_fail() {
    [[ $1 != activate ]] || return 1
    xvk_service_hook "$@"
}
export XVK_UPDATE_HOOK=auto_test_fail
assert_failure 'failed manual rollback reports failure' xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_update_rollback_locked "$root"
unset XVK_UPDATE_HOOK
assert_eq "$before_control" "$(sha256sum "$control")" 'ordinary rollback failure restores prior scheduling eligibility'
assert_eq "$before_state" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'failed rollback preserves the active kit state'
printf 'foreign replacement\n' > "$job"
assert_failure 'foreign auxiliary cron entry blocks rollback before mutation' bash "$PROJECT_DIR/update.sh" --rollback --root "$root"
assert_eq "$before_state" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'auxiliary ownership refusal leaves main state unchanged'
assert_failure 'foreign auxiliary cron entry blocks uninstall before deletion' bash "$PROJECT_DIR/uninstall.sh" --yes --root "$root"
assert_eq 'foreign replacement' "$(cat "$job")" 'uninstall never deletes a foreign cron replacement'
assert_eq "$before_state" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'refused uninstall leaves installed state intact'
cp "$scratch/job-original" "$job"
assert_success 'keep-config uninstall cleans the optional scheduler too' bash "$PROJECT_DIR/uninstall.sh" --yes --keep-config --root "$root"
assert_failure 'uninstall removes the optional cron file' test -e "$job"
assert_failure 'uninstall removes the separate worker' test -e "$root/opt/xray-vps-kit-auto-update"
assert_failure 'uninstall removes bounded auxiliary status and logs' test -e "$root/var/lib/xray-vps-kit-auto-update"
assert_success 'restoring identities still works after scheduler removal' bash "$PROJECT_DIR/install.sh" --restore --non-interactive --no-service --root "$root" --archive "$archive"
assert_failure 'restore does not silently re-enable automatic updates' test -e "$job"
bash "$PROJECT_DIR/auto-update.sh" enable --root "$root" > /dev/null
# Reproduce runtime removed by a historical uninstaller, which does not know the
# separate scheduler. A repeated feature-aware keep-config removal must clean it.
bundle=$(jq -r .installed.bundleId "$root/etc/xray-vps-kit/state.json")
digest=$(jq -r .installed.contentSha256 "$root/etc/xray-vps-kit/state.json")
rm "$root/usr/local/bin/xray" "$root/usr/local/bin/xray-client" "$root/etc/systemd/system/xray-vps-kit.service" "$root/opt/xray-vps-kit/current"
xvk_bundle_remove "$root/opt/xray-vps-kit/releases/$bundle" "$digest"
rmdir "$root/opt/xray-vps-kit/releases" "$root/opt/xray-vps-kit"
assert_success 'runtime-already-removed path still cleans an owned scheduler' bash "$PROJECT_DIR/uninstall.sh" --yes --keep-config --root "$root"
assert_failure 'no-op lifecycle path leaves no active cron job' test -e "$job"
assert_failure 'no-op lifecycle path leaves no worker payload' test -e "$root/opt/xray-vps-kit-auto-update"
test_finish
