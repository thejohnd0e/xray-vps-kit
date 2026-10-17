#!/usr/bin/env bash
case "${1:-all}" in
    all|coherent-upgrade-and-rollback|bad-bundle-and-stale-rollback) selected=${1:-all} ;;
    *) printf 'Unknown update case\n' >&2; exit 1 ;;
esac
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_test_probe_path "$scratch"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)

make_fixture_kit() {
    local destination=$1
    mkdir -p "$destination"
    cp "$PROJECT_DIR/VERSION" "$PROJECT_DIR/xray-client" "$destination/"
    cp -a "$PROJECT_DIR/lib" "$PROJECT_DIR/releases" "$PROJECT_DIR/templates" "$destination/"
    [[ ! -f $PROJECT_DIR/update.sh ]] || cp "$PROJECT_DIR/update.sh" "$destination/"
    printf '0.2.0\n' > "$destination/VERSION"
}

capture_status() {
    local output=$1 status=0
    shift
    "$@" > "$output" 2>&1 || status=$?
    printf '%s\n' "$status"
}

state_identity_view() {
    jq -c 'del(.generation,.installed,.lastSuccessfulSnapshot)' "$1"
}

install_test_root() {
    local root=$1
    mkdir -p "$root"
    xvk_test_install "$root" "$archive" > /dev/null
}

if [[ $selected == all || $selected == coherent-upgrade-and-rollback ]]; then
    root=$(mktemp -d "$scratch/upgrade.XXXXXXXX")
    install_test_root "$root"
    fixture="$scratch/kit-0.2.0"
    make_fixture_kit "$fixture"
    state="$root/etc/xray-vps-kit/state.json"
    config="$root/etc/xray-vps-kit/config.json"
    manager="$root/usr/local/bin/xray-client"
    before_state=$(sha256sum "$state")
    before_config=$(sha256sum "$config")
    cp -p "$config" "$scratch/initial-config"

    status=$(capture_status "$scratch/check-current.log" \
        bash "$PROJECT_DIR/update.sh" --check --root "$root" --archive "$archive")
    assert_eq 0 "$status" 'check returns 0 for the installed bundle'
    assert_eq "$before_state" "$(sha256sum "$state")" 'no-op check leaves state unchanged'
    assert_eq "$before_config" "$(sha256sum "$config")" 'no-op check leaves config unchanged'

    status=$(capture_status "$scratch/check-update.log" \
        bash "$fixture/update.sh" --check --root "$root" --archive "$archive")
    assert_eq 10 "$status" 'check returns 10 when a valid newer bundle is available'
    assert_eq "$before_state" "$(sha256sum "$state")" 'available check leaves state unchanged'
    assert_eq "$before_config" "$(sha256sum "$config")" 'available check leaves config unchanged'

    initial_identity=$(state_identity_view "$state")
    initial_uri="$scratch/initial-uri"
    bash "$manager" show main-user | grep '^vless://' > "$initial_uri"
    initial_bundle=$(readlink "$root/opt/xray-vps-kit/current")
    assert_success 'update switches to a self-contained candidate bundle' \
        bash "$fixture/update.sh" --root "$root" --archive "$archive"
    assert_eq '0.2.0' "$(jq -r '.installed.kitVersion' "$state")" 'updated kit version is recorded'
    assert_eq 2 "$(jq -r '.generation' "$state")" 'successful update advances state generation once'
    assert_eq "$initial_identity" "$(state_identity_view "$state")" 'update preserves endpoint, keys and client identities'
    assert_success 'unchanged identities produce byte-identical generated config' cmp -s "$config" "$scratch/initial-config"
    assert_failure 'updated current symlink differs from original bundle' test "$(readlink "$root/opt/xray-vps-kit/current")" = "$initial_bundle"
    bash "$manager" show main-user | grep '^vless://' > "$scratch/updated-uri"
    assert_success 'client profile bytes survive update' cmp -s "$initial_uri" "$scratch/updated-uri"
    assert_success 'installed manager version is self-contained' bash "$manager" version

    moved_fixture="$scratch/kit-0.2.0-moved"
    mv "$fixture" "$moved_fixture"
    assert_success 'installed manager runs after source checkout moves away' bash "$manager" version
    assert_success 'rollback restores prior bundle, state and config' \
        bash "$moved_fixture/update.sh" --rollback --root "$root"
    assert_eq "$initial_bundle" "$(readlink "$root/opt/xray-vps-kit/current")" 'rollback restores previous bundle selection'
    assert_eq '0.1.0' "$(jq -r '.installed.kitVersion' "$state")" 'rollback restores prior installed metadata'
    assert_eq "$initial_identity" "$(state_identity_view "$state")" 'rollback restores matching client state'
    bash "$manager" show main-user | grep '^vless://' > "$scratch/rolled-back-uri"
    assert_success 'rollback preserves the exact client profile' cmp -s "$initial_uri" "$scratch/rolled-back-uri"
fi

if [[ $selected == all || $selected == bad-bundle-and-stale-rollback ]]; then
    root=$(mktemp -d "$scratch/failure.XXXXXXXX")
    install_test_root "$root"
    fixture="$scratch/bad-kit"
    make_fixture_kit "$fixture"
    state="$root/etc/xray-vps-kit/state.json"
    current="$root/opt/xray-vps-kit/current"
    before_bundle=$(readlink "$current")
    before_state=$(sha256sum "$state")
    before_config=$(sha256sum "$root/etc/xray-vps-kit/config.json")
    cp -p "$root/etc/xray-vps-kit/ownership.json" "$scratch/original-ownership"

    cp "$archive" "$scratch/corrupt.zip"
    printf 'tamper' >> "$scratch/corrupt.zip"
    status=$(capture_status "$scratch/corrupt.log" \
        bash "$fixture/update.sh" --check --root "$root" --archive "$scratch/corrupt.zip")
    assert_eq 1 "$status" 'corrupt pinned archive returns update error'
    assert_eq "$before_bundle" "$(readlink "$current")" 'corrupt archive leaves bundle selected'
    assert_eq "$before_state" "$(sha256sum "$state")" 'corrupt archive leaves state unchanged'

    cp -p "$fixture/xray-client" "$scratch/valid-xray-client"
    printf 'if then invalid shell syntax\n' > "$fixture/xray-client"
    assert_failure 'invalid candidate manager is rejected before switch' \
        bash "$fixture/update.sh" --root "$root" --archive "$archive"
    assert_eq "$before_bundle" "$(readlink "$current")" 'invalid manager leaves old bundle selected'
    assert_eq "$before_state" "$(sha256sum "$state")" 'invalid manager leaves state unchanged'
    assert_eq "$before_config" "$(sha256sum "$root/etc/xray-vps-kit/config.json")" 'invalid manager leaves config unchanged'
    cp -p "$scratch/valid-xray-client" "$fixture/xray-client"

    python3 "$TESTS_DIR/helpers/fake-rejecting-core-archive.py" "$scratch/rejecting-core.zip"
    fake_sha=$(sha256sum "$scratch/rejecting-core.zip")
    fake_sha=${fake_sha%% *}
    jq --arg sha "$fake_sha" '.assets.amd64.sha256=$sha' \
        "$fixture/releases/xray.lock.json" > "$scratch/fake-lock.json"
    chmod 644 "$scratch/fake-lock.json"
    cp "$scratch/fake-lock.json" "$fixture/releases/xray.lock.json"
    assert_failure 'candidate core rejecting preserved config is refused' \
        bash "$fixture/update.sh" --root "$root" --archive "$scratch/rejecting-core.zip"
    assert_eq "$before_bundle" "$(readlink "$current")" 'rejected config candidate leaves old bundle selected'
    assert_eq "$before_state" "$(sha256sum "$state")" 'rejected config candidate leaves state unchanged'
    assert_eq "$before_config" "$(sha256sum "$root/etc/xray-vps-kit/config.json")" 'rejected config candidate leaves config unchanged'
    cp "$PROJECT_DIR/releases/xray.lock.json" "$fixture/releases/xray.lock.json"

    # A caller-supplied hook injects a failure after selection so transaction
    # recovery must restore the installed manager and core together.
    status=0
    (
        for module in common state release render ownership transaction bundle service update-options update-lifecycle; do
            # shellcheck source=/dev/null
            source "$fixture/lib/$module.sh"
        done
        # Invoked indirectly by the transaction engine.
        # shellcheck disable=SC2317
        failing_activation_hook() {
            local action=$1
            [[ $action != activate ]] || return 1
            xvk_service_hook "$@"
        }
        export XVK_ROOT="$root" XVK_ARCHIVE="$archive" XVK_ARCH=amd64
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" \
            xvk_update_locked "$fixture" "$root" apply failing_activation_hook
    ) || status=$?
    assert_failure 'activation failure returns nonzero' test "$status" -eq 0
    assert_eq "$before_bundle" "$(readlink "$current")" 'failed activation restores old bundle selection'
    assert_eq "$before_state" "$(sha256sum "$state")" 'failed activation restores exact old state'
    assert_eq "$before_config" "$(sha256sum "$root/etc/xray-vps-kit/config.json")" 'failed activation restores exact old config'
    assert_success 'failed activation leaves old ownership coherent' \
        bash "$root/usr/local/bin/xray-client" version

    # A later committed revocation advances state and replaces the update
    # snapshot with one matching the current bundle; rollback must refuse it.
    assert_success 'candidate update succeeds before stale rollback case' \
        bash "$fixture/update.sh" --root "$root" --archive "$archive"
    assert_success 'client revocation commits after update' bash "$root/usr/local/bin/xray-client" remove main-user
    assert_failure 'rollback is refused after client-state generation changes' \
        bash "$fixture/update.sh" --rollback --root "$root"
    assert_eq 0 "$(jq '.clients|length' "$state")" 'stale rollback does not resurrect the revoked client'
    assert_eq '0.2.0' "$(jq -r '.installed.kitVersion' "$state")" 'stale rollback keeps the newer bundle installed'
fi
