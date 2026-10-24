#!/usr/bin/env bash

xvk_core_extract_bounded() {
    local library
    library=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    # Bound extraction and the upstream binary's version command together.
    # The file-size limit applies only in this child, never to the user's shell.
    # shellcheck disable=SC2016
    timeout --kill-after=5 45 /bin/bash -c '
        set -euo pipefail
        ulimit -f 262144
        source "$1/common.sh"
        source "$1/release.sh"
        xvk_release_extract "$2" "$3" "$4" "$5"
    ' _ "$library" "$1" "$2" "$3" "$4"
}

xvk_core_service_hook() {
    local action=$1 stage=$2 root=$3 bundle
    if [[ $action == validate ]]; then
        bundle=$(jq -r .installed.bundleId "$stage/etc/xray-vps-kit/state.json") || return 1
        timeout --kill-after=5 30 "${root%/}/opt/xray-vps-kit/releases/$bundle/xray" \
            run -test -config "$stage/etc/xray-vps-kit/config.json" > /dev/null 2>&1
    else
        xvk_service_hook "$@"
    fi
}

# Build from an installed immutable bundle, not a source checkout. Only the
# executable, its license and resolved release lock differ in the output.
xvk_core_candidate() (
    set -euo pipefail
    local root=${1%/} lock=$2 archive=$3 output=$4 base source extract
    xvk_update_require_install "$root" || exit 1
    xvk_release_validate_lock "$lock" || exit 1
    [[ -d $output && -z $(find "$output" -mindepth 1 -print -quit) ]] && xvk_no_symlink_path "$output" || exit 1
    base=$(jq -r .installed.bundleId "$root/etc/xray-vps-kit/state.json") || exit 1
    source="$root/opt/xray-vps-kit/releases/$base"
    extract=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$extract"' EXIT
    xvk_core_extract_bounded "$lock" "$XVK_ARCH" "$archive" "$extract" || exit 1
    cp -a "$source/." "$output/" || exit 1
    install -m 755 "$extract/xray" "$output/xray" || exit 1
    install -m 644 "$extract/LICENSE" "$output/LICENSE-Xray-core" || exit 1
    install -m 644 "$lock" "$output/releases/xray.lock.json" || exit 1
    printf '%s\n' "$base"
)

xvk_core_apply_locked() (
    set -euo pipefail
    local root=${1%/} candidate=$2 base=$3 scheduled=$4 hook=${5:-xvk_core_service_hook}
    local cfg version installed kit digest bundle directory stage='' release_stage='' written=false committed=false
    cfg="$root/etc/xray-vps-kit"
    xvk_update_require_install "$root" || exit 1
    if [[ $(jq -r .installed.bundleId "$cfg/state.json") != "$base" ]]; then
        xvk_error 'Installed bundle changed during staging; retry on a later check'; exit 75
    fi
    if [[ $scheduled == true ]]; then
        xvk_auto_eligible "$root" || { xvk_error 'Scheduled updates are disabled or paused'; exit 75; }
    fi
    xvk_release_validate_lock "$candidate/releases/xray.lock.json" || exit 1
    version=$(jq -r .version "$candidate/releases/xray.lock.json") || exit 1
    installed=$(jq -r .installed.coreVersion "$cfg/state.json") || exit 1
    xvk_update_version_lt "${installed#v}" "${version#v}" || { xvk_error 'Candidate core is not newer'; exit 1; }
    kit=$(jq -r .installed.kitVersion "$cfg/state.json") || exit 1
    [[ $(cat "$candidate/VERSION") == "$kit" ]] || { xvk_error 'Core-only update cannot change kit version'; exit 1; }
    timeout --kill-after=5 30 "$candidate/xray" run -test -config "$cfg/config.json" > /dev/null 2>&1 || {
        xvk_error 'New core rejected the installed configuration'; exit 1;
    }
    digest=$(xvk_bundle_content_digest "$candidate") || exit 1
    bundle="$kit-$version-$digest"
    directory="$root/opt/xray-vps-kit/releases/$bundle"
    trap 'if [[ -n $stage ]]; then rm -rf -- "$stage"; fi; if [[ -n $release_stage ]]; then rm -rf -- "$release_stage"; fi; if [[ $written == true && $committed != true ]]; then xvk_bundle_remove "$directory" "$digest" || xvk_error "Uncommitted core bundle retained: $directory"; fi' EXIT
    xvk_no_symlink_path "$directory" || exit 1
    if [[ -e $directory || -L $directory ]]; then
        [[ -d $directory && ! -L $directory && $(xvk_bundle_content_digest "$directory") == "$digest" ]] || exit 1
    else
        release_stage=$(mktemp -d "$root/opt/xray-vps-kit/releases/.core.XXXXXXXX") || exit 1
        cp -a "$candidate/." "$release_stage/" || exit 1
        chmod 755 "$release_stage" || exit 1
        [[ $(xvk_bundle_content_digest "$release_stage") == "$digest" ]] || exit 1
        mv -T "$release_stage" "$directory" || exit 1
        release_stage=''
        written=true
    fi
    stage=$(mktemp -d "$cfg/.stage.XXXXXXXX") || exit 1
    xvk_snapshot_copy "$root" "$stage" || exit 1
    local generation firewall
    generation=$(jq -r .generation "$cfg/state.json") || exit 1
    (( generation < 9007199254740990 )) || { xvk_error 'State generation is exhausted'; exit 1; }
    jq --arg core "$version" --arg digest "$digest" --arg bundle "$bundle" \
        '.generation+=1 | .installed.coreVersion=$core | .installed.contentSha256=$digest | .installed.bundleId=$bundle' \
        "$cfg/state.json" > "$stage/new-state" || exit 1
    chmod 600 "$stage/new-state" || exit 1
    mv -fT "$stage/new-state" "$stage/etc/xray-vps-kit/state.json" || exit 1
    rm -- "$stage/opt/xray-vps-kit/current" || exit 1
    ln -s "releases/$bundle" "$stage/opt/xray-vps-kit/current" || exit 1
    firewall=$(jq -c .firewallRule "$cfg/ownership.json") || exit 1
    xvk_ownership_manifest "$stage" "$root" "$firewall" > "$stage/etc/xray-vps-kit/ownership.json" || exit 1
    xvk_transaction_apply "$root" "$stage" "$hook" || exit 1
    committed=true
    printf 'Updated Xray-core %s -> %s; kit %s and client identities preserved.\n' "$installed" "$version" "$kit"
)
