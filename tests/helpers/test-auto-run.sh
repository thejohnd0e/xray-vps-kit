#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers/assert.sh
source "$TESTS_DIR/helpers/assert.sh"
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
for module in common state release render ownership transaction snapshot bundle service firewall dependencies preflight update-lifecycle auto-owned auto-release core-update auto-lifecycle auto-run; do
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
metadata="$scratch/api.json"
future="$scratch/future.zip"
fetch_trace="$scratch/fetches"
download_trace="$scratch/downloads"
network_fail=false
after_fetch=:
after_download=:
make_release() {
    local version=$1 sha
    python3 "$TESTS_DIR/helpers/fake-auto-core.py" "$future" "$version"
    sha=$(sha256sum "$future" | cut -d ' ' -f 1)
    jq -n --arg tag "v$version" --arg sha "$sha" '{tag_name:$tag,draft:false,prerelease:false,assets:[
        {name:"Xray-linux-64.zip",browser_download_url:("https://github.com/XTLS/Xray-core/releases/download/"+$tag+"/Xray-linux-64.zip"),digest:("sha256:"+$sha)},
        {name:"Xray-linux-arm64-v8a.zip",browser_download_url:("https://github.com/XTLS/Xray-core/releases/download/"+$tag+"/Xray-linux-arm64-v8a.zip"),digest:("sha256:"+$sha)}]}' > "$metadata"
}
# The production network boundary is replaced; metadata validation, archive
# hashing/extraction, bundle construction, locking and transactions remain real.
xvk_auto_fetch_release() {
    printf 'fetch\n' >> "$fetch_trace"
    [[ $network_fail == false ]] || return 22
    cp "$metadata" "$1" || return 1
    "$after_fetch"
}
xvk_https_get() {
    [[ $1 == https://github.com/XTLS/Xray-core/releases/download/*/Xray-linux-64.zip ]] || return 2
    [[ ${3:-} == 134217728 ]] || return 3
    printf 'download\n' >> "$download_trace"
    cp "$future" "$2" || return 1
    "$after_download"
}
make_release 26.10.22
assert_success 'explicit run discovers, verifies and installs a newer stable core' xvk_auto_run "$PROJECT_DIR" "$root" run
assert_eq v26.10.22 "$(jq -r .installed.coreVersion "$root/etc/xray-vps-kit/state.json")" 'daily worker selects the discovered core'
assert_eq updated "$(jq -r .outcome "$root/var/lib/xray-vps-kit-auto-update/last-run.json")" 'last result records a successful update'
before=$(sha256sum "$root/etc/xray-vps-kit/state.json")
assert_success 'same-version check is a no-op' xvk_auto_run "$PROJECT_DIR" "$root" run
assert_eq "$before" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'same-version check does not advance state'
assert_eq 1 "$(wc -l < "$download_trace" | tr -d ' ')" 'same version does not download its archive again'
make_release 26.1.1
assert_success 'older upstream version is not installed' xvk_auto_run "$PROJECT_DIR" "$root" run
assert_eq "$before" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'older release never downgrades the running core'
network_fail=true
assert_failure 'network failure reports failure without proxy mutation' xvk_auto_run "$PROJECT_DIR" "$root" run
assert_eq "$before" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'network failure leaves active state unchanged'
assert_eq error "$(jq -r .outcome "$root/var/lib/xray-vps-kit-auto-update/last-run.json")" 'network error is visible in last result'
network_fail=false
xvk_auto_control_write "$root" paused rollback
fetches=$(wc -l < "$fetch_trace")
assert_success 'paused scheduled run exits without attempting an update' xvk_auto_run "$PROJECT_DIR" "$root" scheduled
assert_eq "$fetches" "$(wc -l < "$fetch_trace")" 'paused job makes no API request'
xvk_auto_disable_locked "$root" > /dev/null
make_release 26.11.1
assert_success 'explicit run is allowed while scheduled updates are disabled' xvk_auto_run "$PROJECT_DIR" "$root" run
assert_eq disabled "$(jq -r .mode "$root/var/lib/xray-vps-kit-auto-update/control.json")" 'manual run does not silently re-enable cron'
xvk_auto_enable "$PROJECT_DIR" "$root" > /dev/null
make_release 26.12.1
disable_during_fetch() { xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_auto_disable_locked "$root" > /dev/null; }
after_fetch=disable_during_fetch
before=$(sha256sum "$root/etc/xray-vps-kit/state.json")
assert_success 'scheduled job honors disable that wins during metadata staging' xvk_auto_run "$PROJECT_DIR" "$root" scheduled
assert_eq "$before" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'staged job cannot apply after opt-out'
after_fetch=:
xvk_auto_enable "$PROJECT_DIR" "$root" > /dev/null
after_download=disable_during_fetch
before=$(sha256sum "$root/etc/xray-vps-kit/state.json")
assert_success 'apply lock rechecks eligibility after archive download too' xvk_auto_run "$PROJECT_DIR" "$root" scheduled
assert_eq "$before" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'disable after download prevents selection changes'
after_download=:
xvk_auto_enable "$PROJECT_DIR" "$root" > /dev/null
make_release 26.12.2
jq '.assets[].digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$metadata" > "$scratch/bad-digest.json"
mv "$scratch/bad-digest.json" "$metadata"
before=$(sha256sum "$root/etc/xray-vps-kit/state.json")
assert_failure 'advertised digest mismatch rejects the downloaded archive' xvk_auto_run "$PROJECT_DIR" "$root" run
assert_eq "$before" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'digest mismatch preserves the exact running state'
make_release 27.1.1
remove_during_fetch() { bash "$PROJECT_DIR/uninstall.sh" --yes --root "$root" > /dev/null; }
after_fetch=remove_during_fetch
assert_success 'uninstall can win while a scheduled job is staging metadata' xvk_auto_run "$PROJECT_DIR" "$root" scheduled
assert_failure 'staged job never recreates an uninstalled proxy' test -e "$root/opt/xray-vps-kit/current"
assert_failure 'staged reporting never recreates removed scheduler status' test -e "$root/var/lib/xray-vps-kit-auto-update"
test_finish
