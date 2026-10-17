#!/usr/bin/env bash
# Conditional guards with explicit error returns are intentional; status in
# the check/apply subshells is local by design.
# shellcheck disable=SC2015,SC2030,SC2031

xvk_update_arch() {
    case $(uname -m) in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) xvk_error 'Unsupported update architecture'; return 1 ;;
    esac
}

xvk_update_require_install() {
    local root=${1%/} filesystem_root cfg path
    filesystem_root=$root
    cfg="$filesystem_root/etc/xray-vps-kit"
    for path in "$cfg" "$filesystem_root/opt/xray-vps-kit"; do
        xvk_no_symlink_path "$path" || { xvk_error 'Symlink in installed kit paths'; return 1; }
    done
    [[ -f $cfg/state.json && -f $cfg/config.json && -f $cfg/ownership.json ]] || {
        xvk_error 'Kit is not installed at this location'; return 1;
    }
    xvk_state_validate "$cfg/state.json" || { xvk_error 'Installed state is invalid'; return 1; }
    xvk_ownership_verify "$root" "$root" || { xvk_error 'Installed resources have drifted'; return 1; }
}

xvk_update_validate_checkout() {
    local project=$1 file
    [[ -f $project/VERSION && ! -L $project/VERSION ]] || { xvk_error 'Missing kit VERSION'; return 1; }
    [[ $(cat "$project/VERSION") =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { xvk_error 'Invalid kit VERSION'; return 1; }
    xvk_release_validate_lock "$project/releases/xray.lock.json" || { xvk_error 'Invalid source release lock'; return 1; }
    xvk_regular_file "$project/templates/xray-vps-kit.service" || { xvk_error 'Missing or unsafe service unit'; return 1; }
    for file in "$project/xray-client" "$project"/lib/*.sh; do
        xvk_regular_file "$file" && bash -n "$file" || { xvk_error 'Invalid candidate manager shell syntax'; return 1; }
    done
}

# Emits kit version, core version, content digest and bundle ID as tab-separated
# non-secret metadata after building the exact installable candidate bundle.
xvk_update_build_candidate() (
    set -euo pipefail
    local project=$1 temporary=$2 archive digest kit core bundle
    xvk_update_validate_checkout "$project" || exit 1
    mkdir "$temporary/bundle" || exit 1
    archive=$XVK_ARCHIVE
    if [[ -z $archive ]]; then
        mkdir "$temporary/cache" || exit 1
        archive=$(xvk_release_acquire "$project/releases/xray.lock.json" "$XVK_ARCH" "$temporary/cache") || exit 1
    fi
    digest=$(xvk_bundle_build "$project" "$archive" "$temporary/bundle") || exit 1
    kit=$(cat "$project/VERSION") || exit 1
    core=$(jq -r .version "$project/releases/xray.lock.json") || exit 1
    bundle="$kit-$core-$digest"
    printf '%s\t%s\t%s\t%s\n' "$kit" "$core" "$digest" "$bundle"
)

xvk_update_version_lt() {
    local candidate=$1 installed=$2 ordered
    [[ $candidate != "$installed" ]] || return 1
    ordered=$(printf '%s\n%s\n' "$candidate" "$installed" | LC_ALL=C sort -V) || return 1
    [[ ${ordered%%$'\n'*} == "$candidate" ]]
}

xvk_update_candidate_status() {
    local installed_bundle=$1 installed_kit=$2 installed_core=$3
    local candidate_bundle=$4 candidate_kit=$5 candidate_core=$6
    [[ $candidate_bundle != "$installed_bundle" ]] || { printf 'same\n'; return 0; }
    if xvk_update_version_lt "$candidate_kit" "$installed_kit" ||
        xvk_update_version_lt "${candidate_core#v}" "${installed_core#v}"; then
        printf 'downgrade\n'
    else
        printf 'available\n'
    fi
}

xvk_update_check() (
    set -euo pipefail
    local project=$1 root=${2%/} filesystem_root cfg temporary metadata
    local kit core digest bundle installed_bundle installed_kit installed_core classification status=0
    filesystem_root=$root
    cfg="$filesystem_root/etc/xray-vps-kit"
    xvk_require_commands jq unzip zipinfo openssl sha256sum sort realpath bash || exit 1
    xvk_update_require_install "$root" || exit 1
    temporary=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$temporary"' EXIT
    metadata=$(xvk_update_build_candidate "$project" "$temporary") || exit 1
    IFS=$'\t' read -r kit core digest bundle <<< "$metadata"
    installed_bundle=$(jq -r .installed.bundleId "$cfg/state.json") || exit 1
    installed_kit=$(jq -r .installed.kitVersion "$cfg/state.json") || exit 1
    installed_core=$(jq -r .installed.coreVersion "$cfg/state.json") || exit 1
    classification=$(xvk_update_candidate_status "$installed_bundle" "$installed_kit" "$installed_core" \
        "$bundle" "$kit" "$core") || exit 1
    case $classification in
        same) printf 'Installed kit is current (%s, %s).\n' "$installed_kit" "$installed_core" ;;
        available)
            printf 'Update available: kit %s -> %s; core %s -> %s.\n' \
                "$installed_kit" "$kit" "$installed_core" "$core"
            status=10 ;;
        downgrade)
            xvk_error 'Refusing downgrade to an older kit or core'
            status=1 ;;
        *) xvk_error 'Could not classify candidate bundle'; status=1 ;;
    esac
    exit "$status"
)

xvk_update_prepare_stage() {
    local project=$1 root=${2%/} cfg=$3 stage=$4 state_source=$5 generation=$6
    local filesystem_root state_dir snapshot
    filesystem_root=$root
    mkdir -p "$stage/etc/xray-vps-kit" "$stage/etc/systemd/system" \
        "$stage/usr/local/bin" "$stage/opt/xray-vps-kit" || return 1
    jq --argjson generation "$generation" '.generation=$generation' "$state_source" \
        > "$stage/etc/xray-vps-kit/state.json" || return 1
    chmod 600 "$stage/etc/xray-vps-kit/state.json" || return 1
    if [[ $state_source == "$cfg/state.json" ]]; then
        cp -p "$cfg/config.json" "$stage/etc/xray-vps-kit/config.json" || return 1
        cp "$project/templates/xray-vps-kit.service" "$stage/etc/systemd/system/xray-vps-kit.service" || return 1
        printf '#!/usr/bin/env bash\nexec /bin/bash %q "$@"\n' \
            "$filesystem_root/opt/xray-vps-kit/current/xray-client" > "$stage/usr/local/bin/xray-client" || return 1
    else
        state_dir=${state_source%/*}
        snapshot=${state_source%/etc/xray-vps-kit/state.json}
        cp -p "$state_dir/config.json" "$stage/etc/xray-vps-kit/config.json" || return 1
        cp -p "$snapshot/etc/systemd/system/xray-vps-kit.service" \
            "$stage/etc/systemd/system/xray-vps-kit.service" || return 1
        cp -p "$snapshot/usr/local/bin/xray-client" "$stage/usr/local/bin/xray-client" || return 1
        cp -P "$snapshot/opt/xray-vps-kit/current" "$stage/opt/xray-vps-kit/current" || return 1
    fi
    chmod 640 "$stage/etc/xray-vps-kit/config.json" || return 1
    chmod 644 "$stage/etc/systemd/system/xray-vps-kit.service" || return 1
    chmod 755 "$stage/usr/local/bin/xray-client" || return 1
}

xvk_update_write_stage_manifest() {
    local root=${1%/} stage=$2 firewall=$3
    xvk_ownership_manifest "$stage" "$root" "$firewall" > "$stage/etc/xray-vps-kit/ownership.json" || return 1
    chmod 600 "$stage/etc/xray-vps-kit/ownership.json"
}

xvk_update_rollback_locked() (
    set -euo pipefail
    local root=${1%/} cfg filesystem_root snapshot_name snapshot current_target snapshot_target
    local current_generation old_bundle core stage firewall
    filesystem_root=$root
    cfg="$filesystem_root/etc/xray-vps-kit"
    snapshot_name=$(jq -r '.lastSuccessfulSnapshot // empty' "$cfg/state.json") || exit 1
    [[ $snapshot_name =~ ^snapshot-[0-9]+-[a-f0-9]{16}$ ]] || {
        xvk_error 'No valid previous update snapshot is available'; exit 1;
    }
    snapshot="$cfg/backups/$snapshot_name"
    xvk_ownership_verify "$snapshot" "$root" || { xvk_error 'Previous update snapshot is inconsistent'; exit 1; }
    current_target=$(readlink "$filesystem_root/opt/xray-vps-kit/current") || exit 1
    snapshot_target=$(readlink "$snapshot/opt/xray-vps-kit/current") || exit 1
    [[ $snapshot_target != "$current_target" ]] || {
        xvk_error 'Client state changed since the update; rollback refused'; exit 1;
    }
    old_bundle=$(jq -r .installed.bundleId "$snapshot/etc/xray-vps-kit/state.json") || exit 1
    [[ $snapshot_target == "releases/$old_bundle" ]] || { xvk_error 'Snapshot bundle selection is inconsistent'; exit 1; }
    current_generation=$(jq -r .generation "$cfg/state.json") || exit 1
    (( current_generation < 9007199254740990 )) || { xvk_error 'State generation is exhausted'; exit 1; }
    core="$filesystem_root/opt/xray-vps-kit/$snapshot_target/xray"
    [[ -x $core ]] || { xvk_error 'Previous bundle core is missing'; exit 1; }
    stage=$(mktemp -d "$cfg/.stage.XXXXXXXX") || exit 1
    chmod 700 "$stage" || exit 1
    trap 'rm -rf -- "$stage"' EXIT
    xvk_update_prepare_stage '' "$root" "$cfg" "$stage" "$snapshot/etc/xray-vps-kit/state.json" \
        "$((current_generation + 1))" || exit 1
    firewall=$(jq -c .firewallRule "$snapshot/etc/xray-vps-kit/ownership.json") || exit 1
    xvk_update_write_stage_manifest "$root" "$stage" "$firewall" || exit 1
    "$core" run -test -config "$stage/etc/xray-vps-kit/config.json" > /dev/null 2>&1 || {
        xvk_error 'Previous core rejected its preserved config'; exit 1;
    }
    xvk_transaction_apply "$root" "$stage" "${XVK_UPDATE_HOOK:-xvk_service_hook}" || exit 1
    printf 'Rolled back to kit %s; client identities were preserved.\n' \
        "$(jq -r .installed.kitVersion "$cfg/state.json")"
)

xvk_update_locked() (
    set -euo pipefail
    local project=$1 root=${2%/} action=$3 hook=${4:-xvk_service_hook}
    local filesystem_root cfg temporary metadata kit core digest bundle classification
    local installed_bundle installed_kit installed_core release_root='' bundle_stage='' bundle_dir='' digest=''
    local bundle_written=false committed=false stage='' status
    filesystem_root=$root
    cfg="$filesystem_root/etc/xray-vps-kit"
    [[ $hook =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && declare -F "$hook" > /dev/null || {
        xvk_error 'Invalid service hook'; exit 1;
    }
    xvk_update_require_install "$root" || exit 1
    if [[ $action == rollback ]]; then
        XVK_UPDATE_HOOK=$hook xvk_update_rollback_locked "$root"
        exit $?
    fi
    [[ $action == apply ]] || { xvk_error 'Unsupported update action'; exit 1; }
    xvk_update_validate_checkout "$project" || exit 1
    temporary=$(mktemp -d) || exit 1
    trap 'status=$?; if [[ $committed != true && $bundle_written == true && -n $bundle_dir ]]; then if ! xvk_bundle_remove "$bundle_dir" "$digest"; then xvk_error "Uncommitted candidate bundle retained at $bundle_dir"; fi; fi; if [[ -n $bundle_stage && $bundle_stage == "$release_root"/.update.* && -d $bundle_stage ]]; then rm -rf -- "$bundle_stage"; fi; if [[ -n $stage && $stage == "$cfg"/.stage.* && -d $stage ]]; then rm -rf -- "$stage"; fi; rm -rf -- "$temporary"; exit "$status"' EXIT
    metadata=$(xvk_update_build_candidate "$project" "$temporary") || exit 1
    IFS=$'\t' read -r kit core digest bundle <<< "$metadata"
    installed_bundle=$(jq -r .installed.bundleId "$cfg/state.json") || exit 1
    installed_kit=$(jq -r .installed.kitVersion "$cfg/state.json") || exit 1
    installed_core=$(jq -r .installed.coreVersion "$cfg/state.json") || exit 1
    classification=$(xvk_update_candidate_status "$installed_bundle" "$installed_kit" "$installed_core" \
        "$bundle" "$kit" "$core") || exit 1
    case $classification in
        same) printf 'Nothing to update: kit %s, Xray-core %s is installed.\n' "$installed_kit" "$installed_core"; committed=true; exit 0 ;;
        downgrade) xvk_error 'Refusing downgrade to an older kit or core'; exit 1 ;;
        available) ;;
        *) xvk_error 'Could not classify candidate bundle'; exit 1 ;;
    esac
    "$temporary/bundle/xray" run -test -config "$cfg/config.json" > /dev/null 2>&1 || {
        xvk_error 'Candidate core rejected the installed configuration'; exit 1;
    }
    release_root="$filesystem_root/opt/xray-vps-kit/releases"
    xvk_no_symlink_path "$release_root" && [[ -d $release_root ]] || { xvk_error 'Unsafe release directory'; exit 1; }
    bundle_dir="$release_root/$bundle"
    if [[ -e $bundle_dir || -L $bundle_dir ]]; then
        [[ -d $bundle_dir && ! -L $bundle_dir ]] &&
            [[ $(xvk_bundle_content_digest "$bundle_dir") == "$digest" ]] || {
                xvk_error 'Existing candidate bundle path is inconsistent'; exit 1;
            }
    else
        bundle_stage=$(mktemp -d "$release_root/.update.XXXXXXXX") || exit 1
        cp -a "$temporary/bundle/." "$bundle_stage/" || exit 1
        chmod 755 "$bundle_stage" || exit 1
        [[ $(xvk_bundle_content_digest "$bundle_stage") == "$digest" ]] || {
            xvk_error 'Staged bundle digest changed'; exit 1;
        }
        mv -T -- "$bundle_stage" "$bundle_dir" || exit 1
        bundle_stage=''
        bundle_written=true
    fi
    stage=$(mktemp -d "$cfg/.stage.XXXXXXXX") || exit 1
    chmod 700 "$stage" || exit 1
    local current_generation
    current_generation=$(jq -r .generation "$cfg/state.json") || exit 1
    (( current_generation < 9007199254740990 )) || { xvk_error 'State generation is exhausted'; exit 1; }
    xvk_update_prepare_stage "$project" "$root" "$cfg" "$stage" "$cfg/state.json" \
        "$((current_generation + 1))" || exit 1
    jq --arg kit "$kit" --arg core "$core" --arg bundle "$bundle" --arg digest "$digest" \
        '.installed={kitVersion:$kit,coreVersion:$core,bundleId:$bundle,contentSha256:$digest}' \
        "$stage/etc/xray-vps-kit/state.json" > "$stage/new-state" || exit 1
    chmod 600 "$stage/new-state" || exit 1
    mv -fT -- "$stage/new-state" "$stage/etc/xray-vps-kit/state.json" || exit 1
    local firewall
    firewall=$(jq -c .firewallRule "$cfg/ownership.json") || exit 1
    rm -f -- "$stage/opt/xray-vps-kit/current"
    ln -s -- "releases/$bundle" "$stage/opt/xray-vps-kit/current" || exit 1
    xvk_update_write_stage_manifest "$root" "$stage" "$firewall" || exit 1
    xvk_transaction_apply "$root" "$stage" "$hook" || exit 1
    committed=true
    printf 'Updated to kit %s; core %s. Client identities were preserved.\n' "$kit" "$core"
)

xvk_update_run() {
    local project=$1 root=${XVK_ROOT%/} filesystem_root lock status=0
    filesystem_root=$root
    xvk_require_commands jq unzip zipinfo openssl sha256sum sort realpath bash flock || return 1
    if [[ $XVK_UPDATE_ACTION == check ]]; then
        xvk_update_check "$project" "$root" || status=$?
        return "$status"
    fi
    lock="$filesystem_root/run/lock/xray-vps-kit.lock"
    xvk_with_lock "$lock" xvk_update_locked "$project" "$root" "$XVK_UPDATE_ACTION" xvk_service_hook
}
