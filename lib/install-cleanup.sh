#!/usr/bin/env bash
# Rollback is a callback inside xvk_install_locked; its mutation flags and
# firewall record are dynamically scoped locals owned by that caller.
# shellcheck disable=SC2154

xvk_uncommitted_bundle_remove() {
    local directory=$1 reference=$2 file relative
    [[ -d $directory ]] || return 0
    xvk_no_symlink_path "$directory" || return 1
    while IFS= read -r -d '' file; do
        relative=${file#"$directory"/}
        [[ ! -L $file && -e $reference/$relative ]] || return 1
        if [[ -f $file ]]; then cmp -s "$file" "$reference/$relative" || return 1; fi
    done < <(find "$directory" -mindepth 1 -print0)
    while IFS= read -r -d '' file; do rm -f -- "$file" || return 1; done < <(find "$directory" -type f -print0)
    while IFS= read -r -d '' file; do rmdir -- "$file" || return 1; done < <(find "$directory" -depth -type d -print0)
}

xvk_install_rollback() {
    local root=$1 scratch=$2 bundle=$3 file temporary_file
    if [[ $XVK_SANDBOX != true && $runtime_written == true ]]; then
        systemctl disable --now xray-vps-kit.service > /dev/null 2>&1 || true
        xvk_firewall_remove "$rule" || xvk_error 'Firewall rollback requires operator recovery'
    fi
    if [[ $runtime_written == true ]]; then
        for file in usr/local/bin/xray-client etc/systemd/system/xray-vps-kit.service; do
            if [[ -e $root/$file ]]; then
                [[ ! -L $root/$file ]] && cmp -s "$root/$file" "$scratch/$file" || return 1
                rm -- "$root/$file" || return 1
            fi
        done
        if [[ -L $root/opt/xray-vps-kit/current ]]; then
            [[ $(readlink "$root/opt/xray-vps-kit/current") == "releases/$bundle" ]] || return 1
            rm "$root/opt/xray-vps-kit/current" || return 1
        fi
    fi
    if [[ $XVK_RESTORE == true ]]; then
        for file in state.json config.json ownership.json; do
            temporary_file=$(xvk_private_temp "$root/etc/xray-vps-kit") || return 1
            cp -p "$scratch/preserved/$file" "$temporary_file" && mv -fT "$temporary_file" "$root/etc/xray-vps-kit/$file" || return 1
        done
    elif [[ $writes_started == true ]]; then
        for file in state.json config.json ownership.json; do
            if [[ -e $root/etc/xray-vps-kit/$file ]]; then
                [[ ! -L $root/etc/xray-vps-kit/$file && -f $scratch/$file ]] &&
                    cmp -s "$root/etc/xray-vps-kit/$file" "$scratch/$file" || return 1
                rm "$root/etc/xray-vps-kit/$file" || return 1
            fi
        done
        rmdir "$root/etc/xray-vps-kit" || return 1
    fi
    if [[ $bundle_written == true ]]; then
        xvk_uncommitted_bundle_remove "$root/opt/xray-vps-kit/releases/$bundle" "$scratch/bundle" || return 1
    fi
    # Empty directories this install created; rmdir never touches a non-empty (foreign) one.
    if [[ $writes_started == true ]]; then
        rmdir "$root/opt/xray-vps-kit/releases" "$root/opt/xray-vps-kit" 2> /dev/null || true
    fi
    if [[ $XVK_SANDBOX != true && $runtime_written == true ]]; then systemctl daemon-reload || return 1; fi
    xvk_error 'Failed install rolled back; any installed packages and dedicated account are retained'
}
