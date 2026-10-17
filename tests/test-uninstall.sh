#!/usr/bin/env bash
case "${1:-all}" in
    all|keep-restore-and-full-removal|foreign-rule-and-replaced-file) selected=${1:-all} ;;
    *) printf 'Unknown uninstall case\n' >&2; exit 1 ;;
esac
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_test_probe_path "$scratch"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)

install_test_root() {
    mkdir -p "$1"
    xvk_test_install "$1" "$archive" > /dev/null
}

# Deterministic view of paths, types, modes, link targets and file bytes.
tree_view() {
    (
        cd -- "$1" || exit 1
        find . -printf '%p %y %m %l\n' | LC_ALL=C sort
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    )
}

capture_status() {
    local output=$1 status=0
    shift
    "$@" > "$output" 2>&1 || status=$?
    printf '%s\n' "$status"
}

add_foreign() {
    mkdir -p "$1/etc/amnezia" "$1/usr/local/bin"
    printf 'foreign awg\n' > "$1/etc/amnezia/awg0.conf"
    printf 'foreign tool\n' > "$1/usr/local/bin/other-tool"
}

# Sourced modules drive the real locked uninstall with an injected firewall
# adapter and a stub ufw backed by a file of numbered rows.
run_locked_with_ufw() {
    local root=$1 ufw_rows=$2 keep=$3
    (
        for module in common state release render ownership transaction bundle snapshot firewall uninstall-options uninstall-lifecycle; do
            # shellcheck source=/dev/null
            source "$PROJECT_DIR/lib/$module.sh"
        done
        # Invoked indirectly by the sourced firewall adapter.
        # shellcheck disable=SC2317
        ufw() {
            if [[ $1 == status ]]; then cat "$ufw_rows"; return; fi
            if [[ $1 == --force && $2 == delete ]]; then sed -i "${3}d" "$ufw_rows"; return; fi
            return 1
        }
        # Invoked indirectly by the uninstall lifecycle.
        # shellcheck disable=SC2317
        ufw_hook() {
            case $1 in firewall) xvk_firewall_remove "$3" ;; *) return 0 ;; esac
        }
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_uninstall_locked "$root" "$keep" ufw_hook
    )
}

set_firewall_record() {
    local root=$1 manifest="$1/etc/xray-vps-kit/ownership.json" record=$2
    jq --argjson record "$record" '.firewallRule=$record' "$manifest" > "$scratch/manifest.new"
    chmod 600 "$scratch/manifest.new"
    mv -f "$scratch/manifest.new" "$manifest"
}

marker=xray-vps-kit-0123456789abcdef
owned_row="[ 1] 443/tcp                   ALLOW IN    Anywhere                   # $marker"
owned_record="{\"backend\":\"ufw\",\"marker\":\"$marker\",\"port\":443}"

if [[ $selected == all || $selected == keep-restore-and-full-removal ]]; then
    # Production passes an empty prefix; deriving paths from "/" would yield //etc and fail the
    # symlink-safe path guard. Sandbox roots cannot exercise that branch, so guard the cause.
    # shellcheck disable=SC2016
    assert_failure 'production prefix is never normalized to a slash' grep -rn -F 'filesystem_root=${root:-/}' "$PROJECT_DIR/lib"
    root=$(mktemp -d "$scratch/keep.XXXXXXXX")
    install_test_root "$root"
    add_foreign "$root"
    manager="$root/usr/local/bin/xray-client"
    bash "$manager" add second-user > /dev/null
    cfg="$root/etc/xray-vps-kit"
    bash "$manager" show main-user --uri > "$scratch/uri-before"
    assert_success 'help prints without prompting' bash "$PROJECT_DIR/uninstall.sh" --help
    assert_failure 'unknown argument is rejected' bash "$PROJECT_DIR/uninstall.sh" --bogus
    # The option parser rejects a production run before any lock or path access.
    if (( EUID != 0 )); then
        assert_failure 'production uninstall without root privileges is rejected' bash "$PROJECT_DIR/uninstall.sh" --yes
    fi

    before=$(tree_view "$root")
    status=$(capture_status "$scratch/notty.log" bash "$PROJECT_DIR/uninstall.sh" --root "$root" < /dev/null)
    assert_eq 1 "$status" 'removal without a TTY and without --yes fails'
    assert_eq "$before" "$(tree_view "$root")" 'no-tty refusal changes nothing'
    for reply in n ''; do
        status=$(python3 "$TESTS_DIR/helpers/uninstall-pty.py" "$PROJECT_DIR" "$root" "$reply")
        assert_eq 1 "$status" "canceled prompt (reply '$reply') exits nonzero"
        assert_eq "$before" "$(tree_view "$root")" "canceled prompt (reply '$reply') changes nothing"
    done

    state_before=$(sha256sum "$cfg/state.json" "$cfg/config.json" "$cfg/ownership.json")
    backups_before=$(cd "$cfg" && find backups -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
    assert_success '--keep-config removal succeeds' bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes --keep-config
    assert_failure 'launcher is removed' test -e "$root/usr/local/bin/xray-client"
    assert_failure 'unit is removed' test -e "$root/etc/systemd/system/xray-vps-kit.service"
    assert_failure 'selected bundle link is removed' test -L "$root/opt/xray-vps-kit/current"
    assert_failure 'all bundles are removed' test -e "$root/opt/xray-vps-kit"
    assert_eq "$state_before" "$(sha256sum "$cfg/state.json" "$cfg/config.json" "$cfg/ownership.json")" '--keep-config preserves state, config and manifest bytes'
    assert_eq "$backups_before" "$(cd "$cfg" && find backups -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)" '--keep-config preserves backups'
    assert_eq 'foreign awg' "$(cat "$root/etc/amnezia/awg0.conf")" 'foreign AWG file is untouched'
    assert_eq 'foreign tool' "$(cat "$root/usr/local/bin/other-tool")" 'foreign launcher directory file is untouched'
    assert_success 'second --keep-config run is a safe no-op' bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes --keep-config

    identity_before=$(jq -c 'del(.generation,.installed,.lastSuccessfulSnapshot)' "$cfg/state.json")
    cp -p "$cfg/config.json" "$scratch/config-before"
    assert_success 'install --restore recreates runtime resources' \
        bash "$PROJECT_DIR/install.sh" --restore --non-interactive --no-service --root "$root" --archive "$archive"
    assert_eq "$identity_before" "$(jq -c 'del(.generation,.installed,.lastSuccessfulSnapshot)' "$cfg/state.json")" 'restore keeps keys, endpoint and client identities'
    assert_success 'restore regenerates the identical server config' cmp -s "$scratch/config-before" "$cfg/config.json"
    bash "$manager" show main-user --uri > "$scratch/uri-after"
    assert_success 'client profile bytes survive uninstall and restore' cmp -s "$scratch/uri-before" "$scratch/uri-after"

    assert_success 'full removal with --yes succeeds' bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes
    leftovers=$(cd "$root" && find . -mindepth 1 \( -type f -o -type l \) | LC_ALL=C sort)
    assert_eq $'./etc/amnezia/awg0.conf\n./run/lock/xray-vps-kit.lock\n./usr/local/bin/other-tool' "$leftovers" 'full removal deletes exactly the owned artifacts'
    assert_failure 'kit configuration directory is removed' test -e "$cfg"
    assert_failure 'removal of an absent kit is refused cleanly' bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes
fi

if [[ $selected == all || $selected == foreign-rule-and-replaced-file ]]; then
    root=$(mktemp -d "$scratch/foreign.XXXXXXXX")
    install_test_root "$root"
    add_foreign "$root"
    unit="$root/etc/systemd/system/xray-vps-kit.service"
    launcher="$root/usr/local/bin/xray-client"
    before=$(tree_view "$root")

    cp -p "$unit" "$scratch/unit.orig"
    printf '# tampered\n' >> "$unit"
    tampered=$(tree_view "$root")
    status=$(capture_status "$scratch/replaced-unit.log" bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes)
    assert_eq 1 "$status" 'replaced unit file refuses removal'
    assert_eq "$tampered" "$(tree_view "$root")" 'replaced unit refusal deletes nothing'
    cp -p "$scratch/unit.orig" "$unit"

    cp -p "$launcher" "$scratch/launcher.orig"
    printf 'foreign target\n' > "$scratch/foreign-target"
    rm "$launcher"
    ln -s "$scratch/foreign-target" "$launcher"
    linked=$(tree_view "$root")
    status=$(capture_status "$scratch/symlink.log" bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes)
    assert_eq 1 "$status" 'symlinked launcher refuses removal'
    assert_eq "$linked" "$(tree_view "$root")" 'symlink refusal deletes nothing'
    assert_eq 'foreign target' "$(cat "$scratch/foreign-target")" 'symlink target is never followed'
    rm "$launcher"
    cp -p "$scratch/launcher.orig" "$launcher"
    assert_eq "$before" "$(tree_view "$root")" 'fixture restored to the pristine installation'

    bundle=$(jq -r .installed.bundleId "$root/etc/xray-vps-kit/state.json")
    printf 'foreign\n' > "$root/opt/xray-vps-kit/releases/$bundle/extra"
    status=$(capture_status "$scratch/extra.log" bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes)
    assert_eq 1 "$status" 'foreign file inside the owned bundle refuses removal'
    assert_success 'foreign bundle file survives the refusal' test -f "$root/opt/xray-vps-kit/releases/$bundle/extra"
    assert_success 'bundle refusal leaves state and unit installed' test -f "$root/etc/xray-vps-kit/state.json" -a -f "$unit"
    rm "$root/opt/xray-vps-kit/releases/$bundle/extra"
    assert_eq "$before" "$(tree_view "$root")" 'bundle refusal deleted nothing else'
    mkdir "$root/opt/xray-vps-kit/releases/foreign-dir"
    foreign_dir_tree=$(tree_view "$root")
    status=$(capture_status "$scratch/foreigndir.log" bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes)
    assert_eq 1 "$status" 'unrecognized release entry refuses removal'
    assert_eq "$foreign_dir_tree" "$(tree_view "$root")" 'release-entry refusal deletes nothing'
    rmdir "$root/opt/xray-vps-kit/releases/foreign-dir"

    # A backup directory the kit cannot prove it created also refuses a full removal.
    mkdir -p "$root/etc/xray-vps-kit/backups/not-a-snapshot"
    backup_tree=$(tree_view "$root")
    status=$(capture_status "$scratch/backup.log" bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes)
    assert_eq 1 "$status" 'unrecognized backup entry refuses full removal'
    assert_eq "$backup_tree" "$(tree_view "$root")" 'backup-entry refusal deletes nothing'
    rmdir "$root/etc/xray-vps-kit/backups/not-a-snapshot" "$root/etc/xray-vps-kit/backups"
    assert_eq "$before" "$(tree_view "$root")" 'fixture is pristine again before the firewall cases'

    # Null record: a preexisting equivalent allow was never ours, so it is never queried.
    printf '[ 1] 443/tcp ALLOW IN Anywhere\n' > "$scratch/rows-null"
    cp "$scratch/rows-null" "$scratch/rows-null.orig"
    assert_success 'removal with no owned firewall rule succeeds' run_locked_with_ufw "$root" "$scratch/rows-null" false
    assert_success 'preexisting equivalent allow is untouched' cmp -s "$scratch/rows-null" "$scratch/rows-null.orig"
    assert_eq 'foreign awg' "$(cat "$root/etc/amnezia/awg0.conf")" 'foreign files survive full removal'

    # Changed rule that still carries our marker is foreign: refuse before any deletion.
    root=$(mktemp -d "$scratch/rule.XXXXXXXX")
    install_test_root "$root"
    set_firewall_record "$root" "$owned_record"
    printf '[ 1] 4443/tcp ALLOW IN Anywhere # %s\n[ 2] 443/tcp DENY IN Anywhere\n' "$marker" > "$scratch/rows-changed"
    cp "$scratch/rows-changed" "$scratch/rows-changed.orig"
    before=$(tree_view "$root")
    status=0
    run_locked_with_ufw "$root" "$scratch/rows-changed" false > /dev/null 2>&1 || status=$?
    assert_eq 1 "$status" 'changed owned-marker rule refuses uninstall'
    assert_eq "$before" "$(tree_view "$root")" 'changed-rule refusal removes no kit file'
    assert_success 'changed-rule refusal leaves the firewall rows intact' cmp -s "$scratch/rows-changed" "$scratch/rows-changed.orig"

    # Exact owned allow above a foreign deny: only the allow is deleted, restoring the deny.
    printf '%s\n[ 2] 443/tcp                   DENY IN     Anywhere\n' "$owned_row" > "$scratch/rows-owned"
    assert_success 'owned allow is removed with the kit' run_locked_with_ufw "$root" "$scratch/rows-owned" false
    assert_eq '[ 2] 443/tcp                   DENY IN     Anywhere' "$(cat "$scratch/rows-owned")" 'foreign deny is preserved and active again'
    assert_failure 'kit configuration is gone after the owned rule removal' test -e "$root/etc/xray-vps-kit"

    # An owned rule that is already absent is safe to "remove".
    root=$(mktemp -d "$scratch/absent.XXXXXXXX")
    install_test_root "$root"
    set_firewall_record "$root" "$owned_record"
    printf '[ 1] 22/tcp ALLOW IN Anywhere\n' > "$scratch/rows-absent"
    assert_success 'already absent owned rule is safe' run_locked_with_ufw "$root" "$scratch/rows-absent" false
    assert_eq '[ 1] 22/tcp ALLOW IN Anywhere' "$(cat "$scratch/rows-absent")" 'unrelated firewall rows are untouched'
fi
