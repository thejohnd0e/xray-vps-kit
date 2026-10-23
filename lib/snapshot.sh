#!/usr/bin/env bash

xvk_snapshot_copy() {
    local source=${1%/} destination=${2%/} rel
    mkdir -p -- "$destination/etc/xray-vps-kit" "$destination/etc/systemd/system" \
        "$destination/usr/local/bin" "$destination/opt/xray-vps-kit" || return 1
    chmod 700 "$destination" "$destination/etc" "$destination/etc/xray-vps-kit" || return 1
    while IFS= read -r rel; do
        cp -p -- "$source/$rel" "$destination/$rel" || return 1
    done < <(xvk_owned_file_paths; printf '%s\n' etc/xray-vps-kit/ownership.json)
    cp -P -- "$source/opt/xray-vps-kit/current" "$destination/opt/xray-vps-kit/current" || return 1
    xvk_core_link_sync "$source" "$destination"
}

# A restored pre-command manager must be able to validate its referenced reverse
# snapshot. Its verifier knows only the regular resources and current selection.
# Drop optional command-link metadata only AFTER activation succeeds, so a failed
# rollback still restores the exact original command and ownership manifest.
xvk_snapshot_legacy_compatible() (
    set -euo pipefail
    local snapshot=$1 root=$2 manifest temporary
    xvk_ownership_verify "$snapshot" "$root" || exit 1
    manifest="$snapshot/etc/xray-vps-kit/ownership.json"
    if ! jq -e 'has("links")' "$manifest" > /dev/null; then exit 0; fi
    temporary=$(xvk_private_temp "${manifest%/*}") || exit 1
    trap 'rm -f -- "$temporary"' EXIT
    jq 'del(.links)' "$manifest" > "$temporary" || exit 1
    xvk_core_link_remove "$snapshot" || exit 1
    if ! mv -fT -- "$temporary" "$manifest"; then
        # The old manifest still owns the link; put it back before the caller
        # attempts failure rollback from this snapshot.
        xvk_core_link_create "$snapshot" || xvk_error 'Could not restore the reverse snapshot command link'
        exit 1
    fi
)

xvk_atomic_file_replace() (
    set -euo pipefail
    local source=$1 destination=$2 temporary
    xvk_regular_file "$source" && xvk_regular_file "$destination" || exit 1
    temporary=$(xvk_private_temp "${destination%/*}") || exit 1
    trap 'rm -f -- "$temporary"' EXIT
    cp -p -- "$source" "$temporary" || exit 1
    mv -fT -- "$temporary" "$destination" || exit 1
)

xvk_atomic_selection_replace() (
    set -euo pipefail
    local source=$1 destination=$2 temporary target
    [[ -L $source && -L $destination ]] || exit 1
    target=$(readlink "$source") || exit 1
    [[ $target =~ ^releases/[A-Za-z0-9._-]+$ && $target != *..* ]] || exit 1
    temporary=$(mktemp -d -- "${destination%/*}/.selection.XXXXXXXX") || exit 1
    trap 'rm -f -- "$temporary/current"; rmdir -- "$temporary"' EXIT
    ln -s -- "$target" "$temporary/current" || exit 1
    mv -fT -- "$temporary/current" "$destination" || exit 1
)

xvk_snapshot_restore() {
    local root=${1%/} snapshot=$2 rel
    xvk_ownership_verify "$snapshot" "$root" || return 1
    while IFS= read -r rel; do
        xvk_atomic_file_replace "$snapshot/$rel" "$root/$rel" || return 1
    done < <(xvk_owned_file_paths; printf '%s\n' etc/xray-vps-kit/ownership.json)
    xvk_core_link_sync "$snapshot" "$root" || return 1
    xvk_atomic_selection_replace "$snapshot/opt/xray-vps-kit/current" "$root/opt/xray-vps-kit/current"
}

xvk_snapshot_remove() {
    local snapshot=$1 root=$2
    [[ $snapshot =~ /backups/snapshot-[0-9]+-[a-f0-9]{16}$ ]] || return 1
    xvk_ownership_verify "$snapshot" "$root" || return 1
    xvk_snapshot_remove_leaves "$snapshot"
}

# A snapshot whose bundle was removed (uninstall --keep-config, then restore) can no
# longer pass the full ownership check. It is still provably ours when its own four files
# match the hashes in its own manifest and nothing else is inside it.
xvk_snapshot_intact() {
    local snapshot=$1 manifest rel expected link
    [[ $snapshot =~ /backups/snapshot-[0-9]+-[a-f0-9]{16}$ ]] && xvk_no_symlink_path "$snapshot" || return 1
    manifest="$snapshot/etc/xray-vps-kit/ownership.json"
    xvk_private_file "$manifest" && jq -e '.schemaVersion==1' "$manifest" > /dev/null || return 1
    while IFS= read -r rel; do
        xvk_regular_file "$snapshot/$rel" || return 1
        expected=$(jq -r --arg path "$rel" '[.files[]|select(.path==$path)|.sha256][0] // empty' "$manifest") || return 1
        [[ $expected =~ ^[a-f0-9]{64}$ && $(sha256sum "$snapshot/$rel" | cut -d ' ' -f 1) == "$expected" ]] || return 1
    done < <(xvk_owned_file_paths)
    link=$(xvk_core_link_entry "$snapshot") || return 1
    jq -e --argjson links "[$link]" '(.links // [])==$links' "$manifest" > /dev/null || return 1
    [[ -L $snapshot/opt/xray-vps-kit/current ]]
}

xvk_snapshot_remove_leaves() {
    local snapshot=$1 path listing expected
    expected=$({ printf '%s\n' etc etc/systemd etc/systemd/system \
        etc/systemd/system/xray-vps-kit.service etc/xray-vps-kit \
        etc/xray-vps-kit/config.json etc/xray-vps-kit/state.json etc/xray-vps-kit/ownership.json \
        opt opt/xray-vps-kit opt/xray-vps-kit/current usr usr/local usr/local/bin usr/local/bin/xray-client
        if jq -e 'has("links")' "$snapshot/etc/xray-vps-kit/ownership.json" > /dev/null; then
            printf '%s\n' usr/local/bin/xray
        fi
    } | LC_ALL=C sort)
    listing=$(find "$snapshot" -mindepth 1 -printf '%P\n' | LC_ALL=C sort) || return 1
    [[ $listing == "$expected" ]] || return 1
    xvk_core_link_remove "$snapshot" || return 1
    while IFS= read -r path; do
        rm -f -- "$snapshot/$path" || return 1
    done < <(xvk_owned_file_paths; printf '%s\n' etc/xray-vps-kit/ownership.json opt/xray-vps-kit/current)
    # Explicit leaves only. Unexpected files can never authorize recursive
    # deletion of a snapshot, releases tree, or any broad parent directory.
    for path in etc/xray-vps-kit etc/systemd/system etc/systemd etc opt/xray-vps-kit opt usr/local/bin usr/local usr; do
        rmdir -- "$snapshot/$path" || return 1
    done
    rmdir -- "$snapshot"
}
