#!/usr/bin/env bash
# lock_fd is a dynamically scoped local inherited by the callback and its
# nested subshell, never read after the with_lock subshell has exited.
# shellcheck disable=SC2030,SC2031

xvk_with_lock() (
    set -euo pipefail
    local lock=$1 lock_fd
    shift
    xvk_no_symlink_path "$lock" && [[ -d ${lock%/*} ]] || exit 1
    if [[ ! -e $lock ]]; then
        # noclobber creates only a new regular file; a racing creator is then
        # validated before opening. Never truncate an existing lock inode.
        (umask 077; set -o noclobber; : > "$lock") 2>/dev/null || true
    fi
    xvk_private_file "$lock" || { xvk_error 'Unsafe mutation lock'; exit 1; }
    exec {lock_fd}<"$lock" || exit 1
    flock --exclusive --timeout 10 "$lock_fd" || { xvk_error 'Mutation lock timeout'; exit 1; }
    "$@"
)

xvk_transaction_apply() (
    set -euo pipefail
    local root=${1%/} stage=$2 hook=$3 cfg snapshot generation old_snapshot rel apply_failed=false
    cfg="$root/etc/xray-vps-kit"
    if [[ ! ${lock_fd:-} =~ ^[0-9]+$ ]] ||
        [[ $(readlink "/proc/self/fd/$lock_fd") != "$root/run/lock/xray-vps-kit.lock" ]] ||
        ! flock --nonblock --exclusive "$lock_fd"; then
        xvk_error 'Mutation requires the kit lock'; exit 1;
    fi
    [[ $hook =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && declare -F "$hook" > /dev/null || exit 1
    [[ $stage == "$cfg"/.stage.* && -d $stage ]] && xvk_no_symlink_path "$stage" || exit 1
    [[ $(stat -c %u "$stage") == "$EUID" && $(stat -c %a "$stage") == 700 ]] || exit 1
    local lib_dir
    lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    # shellcheck source=lib/snapshot.sh
    source "$lib_dir/snapshot.sh" || exit 1
    # Every failure is explicit: Bash suppresses errexit for an entire function
    # called from if/! or an assertion helper, even inside a set -e subshell.
    xvk_ownership_verify "$root" "$root" || exit 1
    xvk_ownership_verify "$stage" "$root" || exit 1
    generation=$(jq -r .generation "$cfg/state.json") || exit 1
    [[ $(jq -r .generation "$stage/etc/xray-vps-kit/state.json") == "$((generation + 1))" ]] || {
        xvk_error 'Stale candidate generation'; exit 1;
    }
    "$hook" validate "$stage" "$root" || { xvk_error 'Candidate validation failed'; exit 1; }
    old_snapshot=$(jq -r '.lastSuccessfulSnapshot // empty' "$cfg/state.json") || exit 1
    if [[ -n $old_snapshot ]]; then
        xvk_ownership_verify "$cfg/backups/$old_snapshot" "$root" || {
            xvk_error 'Referenced prior snapshot is inconsistent'; exit 1;
        }
    fi
    local random
    random=$(openssl rand -hex 8) || exit 1
    snapshot="snapshot-$generation-$random"
    xvk_no_symlink_path "$cfg/backups" || exit 1
    (umask 077; mkdir -p -- "$cfg/backups" && mkdir -- "$cfg/backups/$snapshot") || exit 1
    [[ $(stat -c %u "$cfg/backups") == "$EUID" && $(stat -c %a "$cfg/backups") == 700 ]] || exit 1
    xvk_snapshot_copy "$root" "$cfg/backups/$snapshot" || exit 1
    xvk_ownership_verify "$cfg/backups/$snapshot" "$root" || exit 1
    # Final committed state names its exact preceding snapshot; no second
    # mutable client DB is created.
    jq --arg snapshot "$snapshot" '.lastSuccessfulSnapshot=$snapshot' "$stage/etc/xray-vps-kit/state.json" > "$stage/new-state" || exit 1
    chmod 600 "$stage/new-state" || exit 1
    mv -fT "$stage/new-state" "$stage/etc/xray-vps-kit/state.json" || exit 1
    xvk_ownership_manifest "$stage" "$root" "$(jq -c .firewallRule "$stage/etc/xray-vps-kit/ownership.json")" > "$stage/new-ownership" || exit 1
    chmod 600 "$stage/new-ownership" || exit 1
    mv -fT "$stage/new-ownership" "$stage/etc/xray-vps-kit/ownership.json" || exit 1
    while IFS= read -r rel; do
        if ! xvk_atomic_file_replace "$stage/$rel" "$root/$rel"; then
            apply_failed=true; break
        fi
    done < <(xvk_owned_file_paths; printf '%s\n' etc/xray-vps-kit/ownership.json)
    if [[ $apply_failed == false ]]; then
        xvk_atomic_selection_replace "$stage/opt/xray-vps-kit/current" "$root/opt/xray-vps-kit/current" || apply_failed=true
    fi
    if [[ $apply_failed == false ]]; then
        "$hook" activate "$stage" "$root" || apply_failed=true
    fi
    if [[ $apply_failed == false ]]; then
        "$hook" healthcheck "$stage" "$root" || apply_failed=true
    fi
    if [[ $apply_failed == true ]]; then
        if xvk_snapshot_restore "$root" "$cfg/backups/$snapshot" && "$hook" restore "$stage" "$root"; then
            xvk_error 'Activation failed; previous files and selection restored'
        else
            xvk_error 'Activation failed; rollback failed; operator recovery required'
        fi
        exit 1
    fi
    # Only a verified old snapshot may be pruned; preserve the newest known
    # good snapshot and every failed/in-flight backup for operator recovery.
    if [[ -n $old_snapshot && $old_snapshot != "$snapshot" ]]; then
        xvk_snapshot_remove "$cfg/backups/$old_snapshot" "$root" ||
            xvk_error 'Change committed; prior snapshot retained because cleanup guard refused'
    fi
)
