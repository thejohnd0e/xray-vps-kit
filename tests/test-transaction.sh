#!/usr/bin/env bash
case "${1:-all}" in
    all|core-command|serialized-success|injected-failures) selected=${1:-all} ;;
    *) printf 'Unknown transaction case\n' >&2; exit 1 ;;
esac
[[ -f $PROJECT_DIR/lib/transaction.sh && -f $PROJECT_DIR/lib/ownership.sh ]] || {
    printf 'FAIL: transaction modules not implemented\n' >&2; exit 1;
}
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/state.sh
source "$PROJECT_DIR/lib/state.sh"
# shellcheck source=lib/render.sh
source "$PROJECT_DIR/lib/render.sh"
# shellcheck source=lib/ownership.sh
source "$PROJECT_DIR/lib/ownership.sh"
# shellcheck source=lib/transaction.sh
source "$PROJECT_DIR/lib/transaction.sh"
# shellcheck source=tests/helpers/state-fixture.sh
source "$TESTS_DIR/helpers/state-fixture.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

seed_root() {
    local root=$1 bundle
    mkdir -p "$root/etc/xray-vps-kit" "$root/etc/systemd/system" "$root/usr/local/bin" "$root/opt/xray-vps-kit/releases" "$root/run/lock"
    write_state_fixture "$root/etc/xray-vps-kit/state.json"
    bundle=$(jq -r .installed.bundleId "$root/etc/xray-vps-kit/state.json")
    mkdir "$root/opt/xray-vps-kit/releases/$bundle"
    printf 'test binary content\n' > "$root/opt/xray-vps-kit/releases/$bundle/xray"
    chmod 755 "$root/opt/xray-vps-kit/releases/$bundle/xray"
    printf 'test launcher\n' > "$root/usr/local/bin/xray-client"
    chmod 755 "$root/usr/local/bin/xray-client"
    printf 'test unit\n' > "$root/etc/systemd/system/xray-vps-kit.service"
    chmod 644 "$root/etc/systemd/system/xray-vps-kit.service"
    xvk_render_server "$root/etc/xray-vps-kit/state.json" > "$root/etc/xray-vps-kit/config.json"
    chmod 640 "$root/etc/xray-vps-kit/config.json"
    ln -s "releases/$bundle" "$root/opt/xray-vps-kit/current"
    xvk_ownership_manifest "$root" "$root" > "$root/etc/xray-vps-kit/ownership.json"
    chmod 600 "$root/etc/xray-vps-kit/ownership.json"
}

prepare_stage() {
    local root=$1 stage=$2 name=$3 uuid sid
    mkdir -p "$stage/etc/xray-vps-kit" "$stage/etc/systemd/system" "$stage/usr/local/bin" "$stage/opt/xray-vps-kit"
    uuid=$(python3 -c 'import uuid; print(uuid.uuid4())')
    sid=$(openssl rand -hex 8)
    jq --arg name "$name" --arg uuid "$uuid" --arg sid "$sid" \
        '.generation+=1 | .clients += [{name:$name,uuid:$uuid,shortId:$sid}]' \
        "$root/etc/xray-vps-kit/state.json" > "$stage/etc/xray-vps-kit/state.json"
    chmod 600 "$stage/etc/xray-vps-kit/state.json"
    xvk_render_server "$stage/etc/xray-vps-kit/state.json" > "$stage/etc/xray-vps-kit/config.json"
    chmod 640 "$stage/etc/xray-vps-kit/config.json"
    cp -p "$root/etc/systemd/system/xray-vps-kit.service" "$stage/etc/systemd/system/xray-vps-kit.service"
    cp -p "$root/usr/local/bin/xray-client" "$stage/usr/local/bin/xray-client"
    cp -P "$root/opt/xray-vps-kit/current" "$stage/opt/xray-vps-kit/current"
    xvk_ownership_manifest "$stage" "$root" > "$stage/etc/xray-vps-kit/ownership.json"
    chmod 600 "$stage/etc/xray-vps-kit/ownership.json"
}

# These hooks exercise file-transaction failure recovery only. They are NOT
# evidence of a running/healthy systemd service (VM coverage remains task12).
transaction_hook() {
    local action=$1 stage=$2
    [[ ${FAIL_AT:-} != "$action" ]] || return 1
    [[ $action != restore || ${FAIL_RESTORE:-false} == false ]] || return 1
    if [[ $action == validate ]]; then
        jq -e '.inbounds[0].protocol=="vless"' "$stage/etc/xray-vps-kit/config.json" > /dev/null
    fi
}

prepare_upgrade() {
    local root=$1 stage=$2 bundle
    jq '.installed.kitVersion="0.2.0" | .installed.bundleId=(.installed.kitVersion+"-"+.installed.coreVersion+"-"+.installed.contentSha256)' \
        "$stage/etc/xray-vps-kit/state.json" > "$stage/upgrade-state"
    chmod 600 "$stage/upgrade-state"
    mv "$stage/upgrade-state" "$stage/etc/xray-vps-kit/state.json"
    bundle=$(jq -r .installed.bundleId "$stage/etc/xray-vps-kit/state.json")
    mkdir "$root/opt/xray-vps-kit/releases/$bundle"
    printf 'candidate binary\n' > "$root/opt/xray-vps-kit/releases/$bundle/xray"
    chmod 755 "$root/opt/xray-vps-kit/releases/$bundle/xray"
    rm "$stage/opt/xray-vps-kit/current"
    ln -s "releases/$bundle" "$stage/opt/xray-vps-kit/current"
    xvk_ownership_manifest "$stage" "$root" > "$stage/etc/xray-vps-kit/ownership.json"
}

run_writer() {
    local root=$1 name=$2 stage
    stage=$(mktemp -d "$root/etc/xray-vps-kit/.stage.XXXXXXXX")
    prepare_stage "$root" "$stage" "$name" || return 1
    xvk_transaction_apply "$root" "$stage" transaction_hook
}

if [[ $selected == all || $selected == core-command ]]; then
    root="$scratch/core-command"
    seed_root "$root"
    assert_success 'legacy ownership manifest without xray link is accepted' xvk_ownership_verify "$root" "$root"
    stage=$(mktemp -d "$root/etc/xray-vps-kit/.stage.XXXXXXXX")
    prepare_stage "$root" "$stage" migrated
    xvk_core_link_create "$stage"
    xvk_ownership_manifest "$stage" "$root" > "$stage/etc/xray-vps-kit/ownership.json"
    assert_success 'transaction adds xray command to a legacy install' \
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_transaction_apply "$root" "$stage" transaction_hook
    assert_eq "$(readlink -f "$root/opt/xray-vps-kit/current/xray")" "$(readlink -f "$root/usr/local/bin/xray")" 'xray resolves to the selected core'
    assert_success 'new link is covered by ownership validation' xvk_ownership_verify "$root" "$root"
    original_manifest=$(sha256sum "$root/etc/xray-vps-kit/ownership.json")
    stage=$(mktemp -d "$root/etc/xray-vps-kit/.stage.XXXXXXXX")
    prepare_stage "$root" "$stage" failed-legacy-rollback
    FAIL_AT=healthcheck
    assert_failure 'failed rollback to legacy runtime is rejected' \
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_transaction_apply "$root" "$stage" transaction_hook
    unset FAIL_AT
    assert_success 'failed legacy rollback preserves the xray command' test -L "$root/usr/local/bin/xray"
    assert_eq "$original_manifest" "$(sha256sum "$root/etc/xray-vps-kit/ownership.json")" 'failed legacy rollback restores exact link ownership'
    stage=$(mktemp -d "$root/etc/xray-vps-kit/.stage.XXXXXXXX")
    prepare_stage "$root" "$stage" rollback-to-legacy
    assert_success 'transaction can restore legacy runtime without a link' \
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_transaction_apply "$root" "$stage" transaction_hook
    assert_failure 'legacy rollback removes the added command' test -L "$root/usr/local/bin/xray"
    stage=$(mktemp -d "$root/etc/xray-vps-kit/.stage.XXXXXXXX")
    prepare_stage "$root" "$stage" failed-migration
    prepare_upgrade "$root" "$stage"
    xvk_core_link_create "$stage"
    xvk_ownership_manifest "$stage" "$root" > "$stage/etc/xray-vps-kit/ownership.json"
    FAIL_AT=healthcheck
    assert_failure 'failed activation refuses link migration' \
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_transaction_apply "$root" "$stage" transaction_hook
    unset FAIL_AT
    assert_failure 'failed migration restores absence of the xray command' test -L "$root/usr/local/bin/xray"
    assert_success 'failed migration retains valid legacy ownership' xvk_ownership_verify "$root" "$root"
    foreign="$scratch/foreign-command"
    mkdir -p "$foreign/usr/local/bin"
    printf 'foreign binary\n' > "$foreign/usr/local/bin/xray"
    assert_failure 'link creation cannot overwrite an existing binary' xvk_core_link_create "$foreign"
    assert_failure 'link synchronization cannot overwrite an existing binary' xvk_core_link_sync "$stage" "$foreign"
    assert_eq 'foreign binary' "$(cat "$foreign/usr/local/bin/xray")" 'foreign binary bytes are preserved'
    rm "$foreign/usr/local/bin/xray"
    ln -s /missing/foreign-core "$foreign/usr/local/bin/xray"
    assert_failure 'link cleanup refuses a foreign dangling symlink' xvk_core_link_remove "$foreign"
    assert_eq /missing/foreign-core "$(readlink "$foreign/usr/local/bin/xray")" 'foreign dangling symlink is preserved'
    [[ $selected != core-command ]] || return 0
fi

if [[ $selected != injected-failures && $selected != core-command ]]; then
    root="$scratch/success"
    seed_root "$root"
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" run_writer "$root" one &
    first=$!
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" run_writer "$root" two &
    second=$!
    first_status=0
    second_status=0
    wait "$first" || first_status=$?
    wait "$second" || second_status=$?
    printf 'Concurrent writer exits: %s, %s\n' "$first_status" "$second_status"
    assert_eq 0 "$first_status" 'first writer succeeds under flock'
    assert_eq 0 "$second_status" 'second writer succeeds under flock'
    assert_eq 2 "$(jq -r .generation "$root/etc/xray-vps-kit/state.json")" 'serialized generations have no lost update'
    assert_eq 'one,test-device,two' "$(jq -r '[.clients[].name]|sort|join(",")' "$root/etc/xray-vps-kit/state.json")" 'both concurrent added clients survive'
    assert_success 'committed ownership verifies' xvk_ownership_verify "$root" "$root"
    assert_eq 600 "$(stat -c %a "$root/etc/xray-vps-kit/state.json")" 'state stays private'
    assert_eq 640 "$(stat -c %a "$root/etc/xray-vps-kit/config.json")" 'config stays group-readable only'
    assert_eq 1 "$(find "$root/etc/xray-vps-kit/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" 'only one prior successful snapshot retained'
    previous=$(jq -r .lastSuccessfulSnapshot "$root/etc/xray-vps-kit/state.json")
    assert_eq 700 "$(stat -c %a "$root/etc/xray-vps-kit/backups/$previous")" 'snapshot directory stays root-only'
    assert_eq 600 "$(stat -c %a "$root/etc/xray-vps-kit/backups/$previous/etc/xray-vps-kit/state.json")" 'snapshot credentials stay private'
fi
if [[ $selected != serialized-success ]]; then
    for phase in stage validate rename activate healthcheck rollback; do
        root="$scratch/$phase"
        seed_root "$root"
        stage=$(mktemp -d "$root/etc/xray-vps-kit/.stage.XXXXXXXX")
        prepare_stage "$root" "$stage" changed
        prepare_upgrade "$root" "$stage"
        before=$(xvk_ownership_manifest "$root" "$root")
        bundle_before=$(readlink "$root/opt/xray-vps-kit/current")
        FAIL_AT=$phase
        export FAIL_AT
        if [[ $phase == stage ]]; then
            rm "$stage/etc/xray-vps-kit/config.json"
        elif [[ $phase == rename ]]; then
            # Narrow command-level fault: fail one rename after the first
            # destination has changed. Recovery uses the real mv thereafter.
            mv() {
                if [[ ${*: -1} == "$root/etc/xray-vps-kit/config.json" && ! -f $scratch/rename-fired ]]; then
                    touch "$scratch/rename-fired"
                    return 1
                fi
                command mv "$@"
            }
        elif [[ $phase == rollback ]]; then
            export FAIL_AT=activate FAIL_RESTORE=true
        fi
        assert_failure "$phase failure returns nonzero" xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_transaction_apply "$root" "$stage" transaction_hook
        unset FAIL_AT FAIL_RESTORE
        if [[ $phase == rename ]]; then
            unset -f mv
            assert_success 'partial rename fault was actually reached' test -e "$scratch/rename-fired"
        fi
        assert_eq "$before" "$(xvk_ownership_manifest "$root" "$root")" "$phase failure restores exact bytes and modes"
        assert_eq "$bundle_before" "$(readlink "$root/opt/xray-vps-kit/current")" "$phase failure restores selected bundle"
        assert_success 'old ownership remains valid' xvk_ownership_verify "$root" "$root"
    done
    root="$scratch/attack"
    seed_root "$root"
    stage=$(mktemp -d "$root/etc/xray-vps-kit/.stage.XXXXXXXX")
    prepare_stage "$root" "$stage" changed
    mv "$root/usr/local/bin/xray-client" "$root/usr/local/bin/original"
    ln -s original "$root/usr/local/bin/xray-client"
    assert_failure 'replaced owned path is never adopted' xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_transaction_apply "$root" "$stage" transaction_hook
    assert_success 'foreign replacement survives refusal' test -L "$root/usr/local/bin/xray-client"
    assert_success 'original foreign content survives refusal' test -f "$root/usr/local/bin/original"
    root="$scratch/stale-manifest"
    seed_root "$root"
    stage=$(mktemp -d "$root/etc/xray-vps-kit/.stage.XXXXXXXX")
    prepare_stage "$root" "$stage" changed
    state_before=$(sha256sum "$root/etc/xray-vps-kit/state.json")
    jq '.files[0].sha256=("0"*64)' "$root/etc/xray-vps-kit/ownership.json" > "$root/bad-manifest"
    chmod 600 "$root/bad-manifest"
    mv "$root/bad-manifest" "$root/etc/xray-vps-kit/ownership.json"
    assert_failure 'stale manifest refused even under a conditional caller' \
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_transaction_apply "$root" "$stage" transaction_hook
    assert_eq "$state_before" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'refused stale manifest does not commit state'
    root="$scratch/stale-generation"
    seed_root "$root"
    stage=$(mktemp -d "$root/etc/xray-vps-kit/.stage.XXXXXXXX")
    prepare_stage "$root" "$stage" changed
    jq '.generation=0' "$stage/etc/xray-vps-kit/state.json" > "$stage/stale-state"
    chmod 600 "$stage/stale-state"
    mv "$stage/stale-state" "$stage/etc/xray-vps-kit/state.json"
    xvk_ownership_manifest "$stage" "$root" > "$stage/etc/xray-vps-kit/ownership.json"
    state_before=$(sha256sum "$root/etc/xray-vps-kit/state.json")
    assert_failure 'stale candidate generation is rejected' \
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_transaction_apply "$root" "$stage" transaction_hook
    assert_eq "$state_before" "$(sha256sum "$root/etc/xray-vps-kit/state.json")" 'stale generation leaves state unchanged'
    assert_failure 'direct mutation without real lock descriptor fails' xvk_transaction_apply "$root" "$stage" transaction_hook
    # Hold a distinct descriptor to test the actual bounded wait, not a stub.
    exec {held_fd}<"$root/run/lock/xray-vps-kit.lock"
    flock --exclusive "$held_fd"
    assert_failure 'contended lock times out instead of hanging' xvk_with_lock "$root/run/lock/xray-vps-kit.lock" true
    exec {held_fd}<&-
    root="$scratch/foreign-backup"
    seed_root "$root"
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" run_writer "$root" first
    previous=$(jq -r .lastSuccessfulSnapshot "$root/etc/xray-vps-kit/state.json")
    printf 'user work\n' > "$root/etc/xray-vps-kit/backups/$previous/foreign.txt"
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" run_writer "$root" second
    assert_success 'snapshot pruning preserves unexpected user files' test -f "$root/etc/xray-vps-kit/backups/$previous/foreign.txt"
fi
