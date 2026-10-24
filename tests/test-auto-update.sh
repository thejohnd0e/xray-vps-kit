#!/usr/bin/env bash
case "${1:-all}" in
    all|metadata|http|core|core-failures|scheduler|lifecycle|run|refresh-failure) selected=${1:-all} ;;
    *) printf 'Unknown auto-update case\n' >&2; exit 1 ;;
esac
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/release.sh
source "$PROJECT_DIR/lib/release.sh"
if [[ -f $PROJECT_DIR/lib/auto-release.sh ]]; then
    # shellcheck source=lib/auto-release.sh
    source "$PROJECT_DIR/lib/auto-release.sh"
fi
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

if [[ $selected == all || $selected == lifecycle ]]; then
    assert_success 'optional scheduler integrates with rollback and uninstall safely' bash "$TESTS_DIR/helpers/test-auto-lifecycle.sh"
    [[ $selected != lifecycle ]] || return 0
fi
if [[ $selected == all || $selected == refresh-failure ]]; then
    assert_success 'failed worker refresh restores prior scheduling mode and payload' bash "$TESTS_DIR/helpers/test-auto-refresh-failure.sh"
    [[ $selected != refresh-failure ]] || return 0
fi
if [[ $selected == all || $selected == run ]]; then
    assert_success 'daily updater honors metadata, failures and scheduling eligibility' bash "$TESTS_DIR/helpers/test-auto-run.sh"
    [[ $selected != run ]] || return 0
fi
if [[ $selected == all || $selected == core-failures ]]; then
    assert_success 'core-only updates preserve legacy managers, concurrent identities and failure rollback' bash "$TESTS_DIR/helpers/test-auto-core-failures.sh"
    [[ $selected != core-failures ]] || return 0
fi
if [[ $selected == all || $selected == http ]]; then
    assert_success 'official release requests and archives have bounded HTTPS transfers' bash "$TESTS_DIR/helpers/test-auto-http.sh"
    [[ $selected != http ]] || return 0
fi

if [[ $selected == all || $selected == core ]]; then
    for module in state render ownership transaction snapshot bundle service firewall update-lifecycle core-update; do
        if [[ -f $PROJECT_DIR/lib/$module.sh ]]; then
            # shellcheck source=/dev/null
            source "$PROJECT_DIR/lib/$module.sh"
        fi
    done
    # shellcheck source=tests/helpers/sandbox.sh
    source "$TESTS_DIR/helpers/sandbox.sh"
    xvk_test_probe_path "$scratch"
    archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
    root=$(mktemp -d "$scratch/root.XXXXXXXX")
    xvk_test_install "$root" "$archive" > /dev/null
    python3 "$TESTS_DIR/helpers/fake-auto-core.py" "$scratch/future.zip" 26.10.21
    sha=$(sha256sum "$scratch/future.zip" | cut -d ' ' -f 1)
    jq --arg sha "$sha" '.version="v26.10.21" | .assets |= with_entries(
        .value.sha256=$sha | .value.url=("https://github.com/XTLS/Xray-core/releases/download/v26.10.21/"+.value.name))' \
        "$PROJECT_DIR/releases/xray.lock.json" > "$scratch/future.lock"
    before_identity=$(jq -c 'del(.generation,.installed,.lastSuccessfulSnapshot)' "$root/etc/xray-vps-kit/state.json")
    before_manager=$(sha256sum "$root/opt/xray-vps-kit/current/lib/clients.sh" | cut -d ' ' -f 1)
    mkdir "$scratch/candidate"
    export XVK_ARCH=amd64
    build_candidate() { xvk_core_candidate "$root" "$scratch/future.lock" "$scratch/future.zip" "$scratch/candidate" > "$scratch/base"; }
    assert_success 'core-only assembler builds from the active bundle without source templates' build_candidate
    base=$(cat "$scratch/base")
    assert_eq "$before_manager" "$(sha256sum "$scratch/candidate/lib/clients.sh" | cut -d ' ' -f 1)" 'core-only candidate preserves the active manager modules'
    assert_success 'new core applies through the shared transaction lock' \
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_core_apply_locked "$root" "$scratch/candidate" "$base" false xvk_service_hook
    assert_eq v26.10.21 "$(jq -r .installed.coreVersion "$root/etc/xray-vps-kit/state.json")" 'new official core version is recorded'
    assert_eq "$before_identity" "$(jq -c 'del(.generation,.installed,.lastSuccessfulSnapshot)' "$root/etc/xray-vps-kit/state.json")" 'core-only update preserves all identities and settings'
    assert_success 'core-only result passes ownership verification' xvk_ownership_verify "$root" "$root"
    assert_success 'xray command executes the new selected core' "$root/usr/local/bin/xray" version
    assert_success 'client mutations still work after core-only update' bash "$root/usr/local/bin/xray-client" add after-core-update
    assert_failure 'a candidate prepared against an older bundle cannot be applied again' \
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_core_apply_locked "$root" "$scratch/candidate" "$base" false xvk_service_hook
    fixture="$scratch/new-kit"
    mkdir "$fixture"
    cp "$PROJECT_DIR/VERSION" "$PROJECT_DIR/xray-client" "$PROJECT_DIR/update.sh" "$fixture/"
    cp -a "$PROJECT_DIR/lib" "$PROJECT_DIR/releases" "$PROJECT_DIR/templates" "$fixture/"
    printf '0.2.0\n' > "$fixture/VERSION"
    assert_success 'manual kit upgrade keeps a newer automatically installed core' \
        bash "$fixture/update.sh" --root "$root" --archive "$scratch/future.zip"
    assert_eq v26.10.21 "$(jq -r .installed.coreVersion "$root/etc/xray-vps-kit/state.json")" 'manual kit upgrade does not lower the effective core version'
    assert_eq 0.2.0 "$(jq -r .installed.kitVersion "$root/etc/xray-vps-kit/state.json")" 'manual upgrade still advances the kit version'
fi

if [[ $selected == all || $selected == metadata ]]; then
    jq -n '{tag_name:"v26.10.21",draft:false,prerelease:false,assets:[
        {name:"Xray-linux-64.zip",browser_download_url:"https://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-linux-64.zip",digest:("sha256:"+("a"*64))},
        {name:"Xray-linux-arm64-v8a.zip",browser_download_url:"https://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-linux-arm64-v8a.zip",digest:("sha256:"+("b"*64))}]}' > "$scratch/release.json"
    assert_success 'official stable metadata resolves a strict release lock' \
        xvk_auto_release_lock "$scratch/release.json" "$scratch/lock.json"
    assert_success 'resolved metadata satisfies the existing lock validator' xvk_release_validate_lock "$scratch/lock.json"
    assert_eq v26.10.21 "$(jq -r .version "$scratch/lock.json")" 'resolved version is the official tag'
    assert_eq aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        "$(jq -r .assets.amd64.sha256 "$scratch/lock.json")" 'amd64 digest is extracted without its prefix'
    assert_eq bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
        "$(jq -r .assets.arm64.sha256 "$scratch/lock.json")" 'arm64 digest is retained too'
    for mutation in \
        '.draft=true' '.prerelease=true' '.draft=null' '.tag_name="v26.10.21-beta"' \
        '.tag_name="../main"' '.assets=[]' '.assets += [.assets[0]]' \
        'del(.assets[1])' '.assets[0].digest=null' '.assets[1].digest="sha256:bad"' \
        '.assets[0].browser_download_url="https://example.invalid/core.zip"' \
        '.assets[0].browser_download_url="http://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-linux-64.zip"'; do
        jq "$mutation" "$scratch/release.json" > "$scratch/bad-release.json"
        assert_failure 'untrusted or incomplete release metadata is rejected' \
            xvk_auto_release_lock "$scratch/bad-release.json" "$scratch/rejected-lock.json"
        assert_failure 'invalid metadata publishes no usable lock' test -e "$scratch/rejected-lock.json"
    done
    cat "$scratch/release.json" "$scratch/release.json" > "$scratch/multiple.json"
    assert_failure 'multiple API documents are rejected' xvk_auto_release_lock "$scratch/multiple.json" "$scratch/rejected-lock.json"
fi

if [[ $selected == all || $selected == scheduler ]]; then
    assert_success 'optional updater help works without configuring cron' bash "$PROJECT_DIR/auto-update.sh" --help
    # shellcheck source=tests/helpers/sandbox.sh
    source "$TESTS_DIR/helpers/sandbox.sh"
    xvk_test_probe_path "$scratch"
    archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
    root=$(mktemp -d "$scratch/scheduler.XXXXXXXX")
    xvk_test_install "$root" "$archive" > /dev/null
    assert_failure 'ordinary installation does not enable daily updates' test -e "$root/etc/cron.d/xray-vps-kit-auto-update"
    mkdir -p "$root/etc/cron.d"
    printf 'foreign cron job\n' > "$root/etc/cron.d/foreign"
    export XVK_AUTO_APT_TRACE="$scratch/apt-calls"
    cat > "$scratch/probe-bin/apt-get" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$XVK_AUTO_APT_TRACE"
exit 97
STUB
    chmod +x "$scratch/probe-bin/apt-get"
    assert_success 'explicit enable installs an owned daily job in the sandbox' bash "$PROJECT_DIR/auto-update.sh" enable --root "$root"
    assert_success 'daily job uses the approved 03:30 server-local schedule' grep -q '^30 3 \* \* \* root ' "$root/etc/cron.d/xray-vps-kit-auto-update"
    assert_success 'worker is self-contained outside versioned core bundles' test -f "$root/opt/xray-vps-kit-auto-update/lib/core-update.sh"
    cp "$root/etc/cron.d/xray-vps-kit-auto-update" "$scratch/cron-original"
    assert_success 'repeated enable is idempotent' bash "$PROJECT_DIR/auto-update.sh" enable --root "$root"
    assert_success 'repeat enable creates no duplicate cron entry' cmp -s "$scratch/cron-original" "$root/etc/cron.d/xray-vps-kit-auto-update"
    # shellcheck disable=SC2016
    assert_success 'status reports the enabled scheduler' bash -c 'bash "$1" status --root "$2" | grep -q enabled' _ "$PROJECT_DIR/auto-update.sh" "$root"
    assert_success 'disable removes only the owned schedule' bash "$PROJECT_DIR/auto-update.sh" disable --root "$root"
    assert_failure 'disabled schedule is absent' test -e "$root/etc/cron.d/xray-vps-kit-auto-update"
    assert_eq 'foreign cron job' "$(cat "$root/etc/cron.d/foreign")" 'unrelated cron jobs remain untouched'
    assert_success 'disabled worker remains available for explicit runs and status' test -f "$root/opt/xray-vps-kit-auto-update/auto-update.sh"
    assert_success 'enable resumes a disabled scheduler' bash "$PROJECT_DIR/auto-update.sh" enable --root "$root"
    printf 'foreign replacement\n' > "$root/etc/cron.d/xray-vps-kit-auto-update"
    assert_failure 'disable refuses a replaced cron entry' bash "$PROJECT_DIR/auto-update.sh" disable --root "$root"
    assert_eq 'foreign replacement' "$(cat "$root/etc/cron.d/xray-vps-kit-auto-update")" 'replaced cron bytes are not deleted'
    cp "$scratch/cron-original" "$root/etc/cron.d/xray-vps-kit-auto-update"
    assert_success 'owned schedule can be disabled after restoring its exact bytes' bash "$PROJECT_DIR/auto-update.sh" disable --root "$root"
    assert_eq '' "$(cat "$XVK_AUTO_APT_TRACE" 2>/dev/null || true)" 'sandbox scheduling never invokes APT'
fi
