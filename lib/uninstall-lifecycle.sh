#!/usr/bin/env bash
# Guards with explicit error returns are intentional (A && B || error).
# shellcheck disable=SC2015
# Removal touches only resources named by the verified ownership contract. Every
# refusal is decided before the first deletion; a leftover foreign entry keeps
# its parent directory instead of authorizing recursive removal.

# shellcheck source=lib/auto-owned.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/auto-owned.sh"

# Actions: firewall RECORD | stop | reload. Only the production prefix acts on the
# host; sandbox roots never touch systemd or the firewall.
xvk_uninstall_hook() {
    local action=$1 root=$2 record=${3:-null}
    [[ -z $root || $root == / ]] || return 0
    case $action in
        firewall) xvk_firewall_remove "$record" ;;
        stop) systemctl disable --now xray-vps-kit.service ;;
        reload) systemctl daemon-reload ;;
        *) return 1 ;;
    esac
}

xvk_uninstall_require_install() {
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
    xvk_ownership_verify "$root" "$root" || { xvk_error 'Installed resources have drifted; refusing removal'; return 1; }
}

# Prints every non-current bundle directory name after proving each is a plain
# bundle whose content digest matches the digest embedded in its name.
xvk_uninstall_other_bundles() {
    local root=${1%/} current=$2 release_root entry name digest
    release_root="$root/opt/xray-vps-kit/releases"
    while IFS= read -r -d '' entry; do
        name=${entry##*/}
        [[ $name != "$current" ]] || continue
        [[ $name =~ ^[0-9]+\.[0-9]+\.[0-9]+-v[0-9A-Za-z.]+-([a-f0-9]{64})$ && -d $entry && ! -L $entry ]] || {
            xvk_error 'Unrecognized entry in the release directory; refusing removal'; return 1;
        }
        digest=${BASH_REMATCH[1]}
        [[ $(xvk_bundle_content_digest "$entry") == "$digest" ]] || {
            xvk_error 'Retained bundle does not match its digest; refusing removal'; return 1;
        }
        printf '%s\n' "$name"
    done < <(find "$release_root" -mindepth 1 -maxdepth 1 -print0)
}

xvk_uninstall_snapshots() {
    local root=${1%/} cfg entry name
    cfg="$root/etc/xray-vps-kit"
    [[ -e $cfg/backups ]] || return 0
    xvk_no_symlink_path "$cfg/backups" && [[ -d $cfg/backups ]] || { xvk_error 'Unsafe backups directory'; return 1; }
    while IFS= read -r -d '' entry; do
        name=${entry##*/}
        [[ $name =~ ^snapshot-[0-9]+-[a-f0-9]{16}$ && -d $entry && ! -L $entry ]] || {
            xvk_error 'Unrecognized entry in backups; refusing removal'; return 1;
        }
        xvk_ownership_verify "$entry" "$root" || xvk_snapshot_intact "$entry" || {
            xvk_error 'Backup snapshot is inconsistent; refusing removal'; return 1;
        }
        printf '%s\n' "$name"
    done < <(find "$cfg/backups" -mindepth 1 -maxdepth 1 -print0)
}

xvk_uninstall_confirm() {
    local keep=$1 answer
    printf 'This removes the xray-vps-kit service, launcher, code and owned firewall rule.\n' >&2
    if [[ $keep == true ]]; then
        printf 'State, config and backups are kept for install.sh --restore.\n' >&2
    else
        printf 'Identities, keys and backups are deleted; clients stop working permanently.\n' >&2
    fi
    printf 'Proceed with uninstall? [y/N]: ' >&2
    IFS= read -r answer || { xvk_error 'Uninstall canceled (EOF)'; return 1; }
    case $answer in y|Y|yes|YES) ;; *) xvk_error 'Uninstall canceled'; return 1 ;; esac
}

xvk_uninstall_locked() (
    set -euo pipefail
    local root=${1%/} keep=$2 hook=${3:-xvk_uninstall_hook}
    local filesystem_root cfg bundle digest name rel firewall listing retained=false
    local -a others=() snapshots=()
    filesystem_root=$root
    cfg="$filesystem_root/etc/xray-vps-kit"
    [[ $hook =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && declare -F "$hook" > /dev/null || {
        xvk_error 'Invalid uninstall hook'; exit 1;
    }
    xvk_auto_verify "$root" || { xvk_error 'Automatic-update resources have drifted; refusing removal'; exit 1; }
    if [[ -f $cfg/state.json && ! -e $filesystem_root/opt/xray-vps-kit/current && ! -L $filesystem_root/opt/xray-vps-kit/current &&
        ! -e $filesystem_root/usr/local/bin/xray-client && ! -e $filesystem_root/etc/systemd/system/xray-vps-kit.service &&
        ! -e $filesystem_root/usr/local/bin/xray && ! -L $filesystem_root/usr/local/bin/xray ]]; then
        xvk_auto_remove "$root" || exit 1
        printf 'Kit runtime is already removed; preserved configuration was not touched.\n'
        exit 0
    fi
    xvk_uninstall_require_install "$root" || exit 1
    bundle=$(jq -r .installed.bundleId "$cfg/state.json") || exit 1
    digest=$(jq -r .installed.contentSha256 "$cfg/state.json") || exit 1
    firewall=$(jq -c .firewallRule "$cfg/ownership.json") || exit 1
    # Command substitution, not mapfile < <(...): a process substitution would
    # swallow the validator's failure and let removal continue.
    listing=$(xvk_uninstall_other_bundles "$root" "$bundle") || exit 1
    [[ -z $listing ]] || mapfile -t others <<< "$listing"
    if [[ $keep != true ]]; then
        listing=$(xvk_uninstall_snapshots "$root") || exit 1
        [[ -z $listing ]] || mapfile -t snapshots <<< "$listing"
    fi
    # Firewall first: a changed rule refuses the whole uninstall with nothing removed.
    "$hook" firewall "$root" "$firewall" || { xvk_error 'Firewall rule could not be removed safely'; exit 1; }
    "$hook" stop "$root" || { xvk_error 'Could not stop the owned service; no files were removed'; exit 1; }
    xvk_auto_remove "$root" || exit 1
    xvk_core_link_remove "$root" || exit 1
    for rel in usr/local/bin/xray-client etc/systemd/system/xray-vps-kit.service; do
        rm -f -- "$filesystem_root/$rel" || exit 1
    done
    [[ $(readlink "$filesystem_root/opt/xray-vps-kit/current") == "releases/$bundle" ]] || exit 1
    rm -- "$filesystem_root/opt/xray-vps-kit/current" || exit 1
    "$hook" reload "$root" || xvk_error 'systemd reload failed after file removal'
    if [[ $keep != true ]]; then
        for name in "${snapshots[@]}"; do
            xvk_snapshot_remove "$cfg/backups/$name" "$root" ||
                { xvk_snapshot_intact "$cfg/backups/$name" && xvk_snapshot_remove_leaves "$cfg/backups/$name"; } ||
                { xvk_error "Backup $name retained: cleanup guard refused"; retained=true; }
        done
    fi
    xvk_bundle_remove "$filesystem_root/opt/xray-vps-kit/releases/$bundle" "$digest" || { xvk_error 'Current bundle retained: cleanup guard refused'; retained=true; }
    for name in "${others[@]}"; do
        xvk_bundle_remove "$filesystem_root/opt/xray-vps-kit/releases/$name" "${name##*-}" || { xvk_error "Bundle $name retained: cleanup guard refused"; retained=true; }
    done
    rmdir -- "$filesystem_root/opt/xray-vps-kit/releases" "$filesystem_root/opt/xray-vps-kit" 2> /dev/null || retained=true
    if [[ $keep == true ]]; then
        printf 'Uninstalled; state, config and backups kept for install.sh --restore.\n'
    else
        for rel in state.json config.json ownership.json; do
            rm -f -- "$cfg/$rel" || exit 1
        done
        rmdir -- "$cfg/backups" 2> /dev/null || [[ ! -e $cfg/backups ]] || retained=true
        rmdir -- "$cfg" 2> /dev/null || retained=true
        printf 'Uninstalled; identities, keys and backups were deleted.\n'
    fi
    printf 'The xray-vps-kit service account and installed packages were retained.\n'
    [[ $retained != true ]] || { xvk_error 'Some entries were retained because they are not provably owned'; exit 1; }
)

xvk_uninstall_run() {
    local root=${XVK_ROOT%/} filesystem_root
    filesystem_root=$root
    xvk_require_commands jq sha256sum realpath flock find || return 1
    [[ -d $filesystem_root/run/lock ]] || { xvk_error 'Missing lock directory'; return 1; }
    if [[ $XVK_ASSUME_YES != true ]]; then
        xvk_uninstall_confirm "$XVK_KEEP" || return 1
    fi
    xvk_with_lock "$filesystem_root/run/lock/xray-vps-kit.lock" \
        xvk_uninstall_locked "$root" "$XVK_KEEP" xvk_uninstall_hook
}
