#!/usr/bin/env bash

xvk_bundle_build() (
    set -euo pipefail
    local source=$1 archive=$2 destination=$3 file
    if [[ -d $archive ]]; then
        # An installed bundle of the very same core: reuse its binary and license.
        cp -- "$archive/xray" "$archive/LICENSE-Xray-core" "$destination/" || exit 1
    else
        xvk_release_extract "$source/releases/xray.lock.json" "$XVK_ARCH" "$archive" "$destination" || exit 1
        mv "$destination/LICENSE" "$destination/LICENSE-Xray-core" || exit 1
    fi
    mkdir "$destination/lib" "$destination/releases" || exit 1
    for file in "$source"/lib/*.sh "$source"/lib/*.jq; do
        cp -- "$file" "$destination/lib/" || exit 1
    done
    cp "$source/VERSION" "$source/xray-client" "$destination/" || exit 1
    cp "$source/releases/xray.lock.json" "$destination/releases/" || exit 1
    find "$destination" -type d -exec chmod 755 {} + || exit 1
    find "$destination" -type f -exec chmod 644 {} + || exit 1
    chmod 755 "$destination/xray" "$destination/xray-client" || exit 1
    xvk_bundle_content_digest "$destination"
)

xvk_bundle_remove() {
    local directory=$1 expected=$2 file
    [[ $directory == */opt/xray-vps-kit/releases/* ]] && xvk_no_symlink_path "$directory" || return 1
    [[ $(xvk_bundle_content_digest "$directory") == "$expected" ]] || return 1
    while IFS= read -r -d '' file; do rm -f -- "$file" || return 1; done < <(find "$directory" -type f -print0)
    while IFS= read -r -d '' file; do rmdir -- "$file" || return 1; done < <(find "$directory" -depth -type d -print0)
}

# Cleanup after a failed update may only delete a candidate that is not the live
# selection: a failed rollback can leave current pointing at the uncommitted
# bundle, which is then the only runnable core and must be retained.
xvk_bundle_remove_unselected() {
    local root=${1%/} directory=$2 expected=$3 current target name
    [[ $directory == "$root"/opt/xray-vps-kit/releases/* ]] || return 1
    current="$root/opt/xray-vps-kit/current"
    if [[ -L $current ]]; then
        target=$(readlink -- "$current") || {
            xvk_error "Active bundle selection could not be read; uncommitted bundle retained at $directory"
            return 1
        }
        if [[ $target =~ ^releases/([A-Za-z0-9._-]+)$ && ${BASH_REMATCH[1]} != *..* ]]; then
            name=${BASH_REMATCH[1]}
        else
            xvk_error "Active bundle selection is ambiguous; uncommitted bundle retained at $directory"
            return 1
        fi
        [[ $name != "${directory##*/}" ]] || {
            xvk_error "Uncommitted bundle is still selected; retained at $directory"
            return 1
        }
    elif [[ -e $current ]]; then
        xvk_error "Active bundle selection is not a symlink; uncommitted bundle retained at $directory"
        return 1
    fi
    xvk_bundle_remove "$directory" "$expected" || {
        xvk_error "Uncommitted bundle retained at $directory"
        return 1
    }
}
