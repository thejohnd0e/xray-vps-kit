#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers/assert.sh
source "$TESTS_DIR/helpers/assert.sh"
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
# shellcheck source=tests/helpers/legacy-core-runtime.sh
source "$TESTS_DIR/helpers/legacy-core-runtime.sh"
for module in common state release render ownership transaction snapshot bundle service firewall update-lifecycle core-update; do
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/$module.sh"
done
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_test_probe_path "$scratch"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
root=$(mktemp -d "$scratch/legacy.XXXXXXXX")
xvk_test_install "$root" "$archive" > /dev/null
make_legacy_core_runtime "$root"
export XVK_ARCH=amd64
make_candidate() {
    local name=$1 version=$2 reject=${3:-accept} sha
    python3 "$TESTS_DIR/helpers/fake-auto-core.py" "$scratch/$name.zip" "$version" "$reject"
    sha=$(sha256sum "$scratch/$name.zip" | cut -d ' ' -f 1)
    jq --arg tag "v$version" --arg sha "$sha" '.version=$tag | .assets |= with_entries(
        .value.sha256=$sha | .value.url=("https://github.com/XTLS/Xray-core/releases/download/"+$tag+"/"+.value.name))' \
        "$PROJECT_DIR/releases/xray.lock.json" > "$scratch/$name.lock"
    mkdir "$scratch/$name"
    xvk_core_candidate "$root" "$scratch/$name.lock" "$scratch/$name.zip" "$scratch/$name" > "$scratch/$name.base"
}
make_candidate rejected 26.10.22 reject
before_state=$(sha256sum "$root/etc/xray-vps-kit/state.json")
before_manifest=$(sha256sum "$root/etc/xray-vps-kit/ownership.json")
assert_failure 'new core rejecting the preserved config is refused before selection' \
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_core_apply_locked "$root" "$scratch/rejected" "$(cat "$scratch/rejected.base")" false xvk_service_hook
assert_eq "$before_state" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'config refusal keeps exact installed state'
assert_eq "$before_manifest" "$(sha256sum "$root/etc/xray-vps-kit/ownership.json")" 'config refusal keeps exact ownership metadata'
make_candidate future 26.10.22
auto_fail_activation() {
    [[ $1 != activate ]] || return 1
    xvk_service_hook "$@"
}
assert_failure 'activation failure restores the legacy runtime through a snapshot' \
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_core_apply_locked "$root" "$scratch/future" "$(cat "$scratch/future.base")" false auto_fail_activation
assert_eq "$before_state" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'activation failure restores exact state bytes'
assert_eq "$before_manifest" "$(sha256sum "$root/etc/xray-vps-kit/ownership.json")" 'activation failure restores exact legacy manifest bytes'
assert_failure 'failed update never adds a command link to the legacy manager' test -L "$root/usr/local/bin/xray"
assert_success 'client mutation can win between staging and the apply lock' bash "$root/usr/local/bin/xray-client" add during-staging
assert_success 'core-only update accepts fresh client state on the same active bundle' \
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_core_apply_locked "$root" "$scratch/future" "$(cat "$scratch/future.base")" false xvk_service_hook
assert_success 'concurrent client identity survives the core-only update' jq -e 'any(.clients[];.name=="during-staging")' "$root/etc/xray-vps-kit/state.json"
assert_failure 'successful update preserves legacy command-link absence' test -L "$root/usr/local/bin/xray"
assert_success 'genuine old manager adds clients after automatic core update' bash "$root/usr/local/bin/xray-client" add after-auto
assert_success 'genuine old manager removes clients after automatic core update' bash "$root/usr/local/bin/xray-client" remove after-auto
test_finish
