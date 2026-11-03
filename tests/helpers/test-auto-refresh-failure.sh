#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers/assert.sh
source "$TESTS_DIR/helpers/assert.sh"
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
for module in common state release render ownership transaction snapshot bundle service firewall dependencies preflight update-lifecycle auto-owned auto-release auto-lifecycle; do
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/$module.sh"
done
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_test_probe_path "$scratch"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
export XVK_SANDBOX=true XVK_ARCH=amd64

# Builds a worker source tree whose payload differs from every other build.
make_worker_source() {
    local destination=$1 version=$2 marker=$3
    mkdir -p "$destination"
    cp -a "$PROJECT_DIR/lib" "$PROJECT_DIR/auto-update.sh" "$PROJECT_DIR/VERSION" "$destination/"
    printf '%s\n' "$version" > "$destination/VERSION"
    printf '# worker build: %s\n' "$marker" >> "$destination/lib/common.sh"
}

new_root() {
    local root
    root=$(mktemp -d "$scratch/root.XXXXXXXX")
    xvk_test_install "$root" "$archive" > /dev/null
    export XVK_ROOT="$root"
    printf '%s\n' "$root"
}

new_source() {
    local source
    source=$(mktemp -d "$scratch/src.XXXXXXXX")
    make_worker_source "$source" "$1" "$2"
    printf '%s\n' "$source"
}

# A refresh runs in its own process so the injected failure keeps production
# errexit semantics; the suite then inspects only the resulting state.
refresh() {
    local project=$1 root=$2 mode=$3 failpoint=$4 log=${5:-/dev/null}
    bash "$TESTS_DIR/helpers/auto-refresh-runner.sh" "$project" "$root" "$mode" "$failpoint" \
        > "$log" 2>&1
}

refresh_status() {
    local status=0
    refresh "$@" || status=$?
    printf '%s\n' "$status"
}

payload_of() { xvk_auto_payload_manifest "$1/opt/xray-vps-kit-auto-update"; }
installed_version() { cat "$1/opt/xray-vps-kit-auto-update/VERSION"; }
control_of() { cat "$1/var/lib/xray-vps-kit-auto-update/control.json"; }
cron_of() { sha256sum "$1/etc/cron.d/xray-vps-kit-auto-update" | cut -d ' ' -f 1; }
leftovers() { find "$1/opt" -maxdepth 1 -name '.xray-auto-*' -print -quit; }
backup_dir() { find "$1/opt" -maxdepth 1 -name '.xray-auto-old.*' -print -quit; }

# A failed refresh of an enabled worker with genuinely different payloads restores
# the exact previous payload, scheduling bytes and mode.
root=$(new_root)
old=$(new_source 0.0.9-old old-worker)
new=$(new_source 0.0.10-new new-worker)
xvk_auto_enable "$old" "$root" > /dev/null
payload_before=$(payload_of "$root")
control_before=$(control_of "$root")
cron_before=$(cron_of "$root")
assert_failure 'a failed refresh of an enabled worker reports failure' \
    test "$(refresh_status "$new" "$root" enabled verify:2)" -eq 0
assert_eq "$control_before" "$(control_of "$root")" 'failed refresh restores the exact previous control bytes'
assert_eq "$cron_before" "$(cron_of "$root")" 'failed refresh keeps the previous cron job'
assert_eq "$payload_before" "$(payload_of "$root")" 'failed refresh restores the exact previous worker payload'
assert_eq 0.0.9-old "$(installed_version "$root")" 'failed refresh leaves the old worker version in place'
assert_success 'restored worker is structurally valid' xvk_auto_verify "$root"
assert_eq '' "$(leftovers "$root")" 'failed refresh removes staging and backup directories'

# A paused worker must not be silently downgraded to disabled by a failed refresh either.
root=$(new_root)
old=$(new_source 0.0.9-old old-worker)
new=$(new_source 0.0.10-new new-worker)
xvk_auto_enable "$old" "$root" > /dev/null
xvk_auto_pause "$root" > /dev/null
payload_before=$(payload_of "$root")
control_before=$(control_of "$root")
assert_failure 'failed refresh of a paused worker reports failure' \
    test "$(refresh_status "$new" "$root" enabled verify:2)" -eq 0
assert_eq "$control_before" "$(control_of "$root")" 'failed refresh restores the paused mode and reason'
assert_eq "$payload_before" "$(payload_of "$root")" 'failed refresh of a paused worker restores the previous payload'
assert_success 'restored paused worker remains structurally valid' xvk_auto_verify "$root"

# A failed first enable must leave nothing eligible behind: no payload, no cron
# job and no control file that would make the feature look configured.
root=$(new_root)
new=$(new_source 0.0.10-new new-worker)
assert_failure 'a failed first enable reports failure' \
    test "$(refresh_status "$new" "$root" enabled verify:2)" -eq 0
assert_failure 'failed first enable leaves no worker resources' xvk_auto_present "$root"
assert_failure 'failed first enable leaves no cron job' test -e "$root/etc/cron.d/xray-vps-kit-auto-update"
assert_eq '' "$(leftovers "$root")" 'failed first enable removes staging and backup directories'

# A successful refresh publishes the new payload exactly and leaves no backup behind.
root=$(new_root)
old=$(new_source 0.0.9-old old-worker)
new=$(new_source 0.0.10-new new-worker)
xvk_auto_enable "$old" "$root" > /dev/null
assert_success 'a successful refresh of a different worker version commits' \
    refresh "$new" "$root" enabled none
assert_eq 0.0.10-new "$(installed_version "$root")" 'successful refresh installs the new worker payload'
assert_success 'committed worker is structurally valid' xvk_auto_verify "$root"
assert_eq '' "$(leftovers "$root")" 'successful refresh removes staging and backup directories'

# If recovery itself cannot remove the uncommitted payload, the previous payload
# must be retained and its location reported instead of being deleted.
root=$(new_root)
old=$(new_source 0.0.9-old old-worker)
new=$(new_source 0.0.10-new new-worker)
xvk_auto_enable "$old" "$root" > /dev/null
payload_before=$(payload_of "$root")
assert_failure 'failed recovery still reports the refresh failure' \
    test "$(refresh_status "$new" "$root" enabled verify:2,payload-remove "$scratch/recovery.log")" -eq 0
backup=$(backup_dir "$root")
assert_success 'failed recovery retains the previous worker payload directory' test -n "$backup"
assert_success 'retained recovery material is reported' grep -qi 'retained' "$scratch/recovery.log"
assert_success 'uncommitted payload stays at its published path when it cannot be removed' \
    test -d "$root/opt/xray-vps-kit-auto-update"
assert_eq "$payload_before" "$(xvk_auto_payload_manifest "$backup")" \
    'retained backup still holds the exact previous payload'

test_finish
