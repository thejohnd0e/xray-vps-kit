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
