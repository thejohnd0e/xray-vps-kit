#!/usr/bin/env bash

xvk_auto_help() {
    cat <<'HELP'
Usage: bash auto-update.sh enable|disable|status|run [OPTIONS]
  enable       Install/refresh the optional worker; schedule daily at 03:30 local time
  disable      Disable scheduled updates; retain worker and last result
  status       Show scheduling mode and the last check/update result
  run          Check and update the official stable core immediately
  --root DIR   Testing only: never change host packages, cron or services
  --help       Print help
Enabling schedules only; it does not immediately update. No kit auto-upgrade.
HELP
}

xvk_auto_options() {
    XVK_ROOT=/ XVK_SANDBOX=false XVK_AUTO_ACTION=${1:-help}
    (( $# == 0 )) || shift
    case $XVK_AUTO_ACTION in enable|disable|status|run|scheduled) ;; *) xvk_error 'Choose enable, disable, status or run'; return 1 ;; esac
    while (( $# )); do
        case $1 in
            --root) xvk_require_value "$@" || return 1; XVK_ROOT=$2; shift 2 ;;
            *) xvk_error 'Unknown automatic-update argument'; return 1 ;;
        esac
    done
    if [[ $XVK_ROOT != / ]]; then
        if ! xvk_validate_test_root "$XVK_ROOT" || [[ ! $XVK_ROOT =~ ^/[A-Za-z0-9_./-]+$ ]]; then
            xvk_error 'Invalid automatic-update testing root'; return 1
        fi
        XVK_SANDBOX=true
    elif [[ $EUID != 0 ]]; then
        xvk_error 'Automatic-update management requires root'; return 1
    fi
    XVK_ARCH=$(xvk_detect_platform) || return 1
    export XVK_ROOT XVK_SANDBOX XVK_ARCH
}

xvk_auto_payload_remove() {
    local directory=$1 actual path
    xvk_private_file "$directory/ownership.json" || return 1
    actual=$(xvk_auto_payload_manifest "$directory") || return 1
    jq -e -s --argjson actual "$actual" 'length==1 and .[0]==$actual' "$directory/ownership.json" > /dev/null || return 1
    while IFS= read -r path; do rm -- "$directory/$path" || return 1; done < <(jq -r '.files[].path' "$directory/ownership.json")
    rm -- "$directory/ownership.json" && rmdir -- "$directory/lib" "$directory"
}

xvk_auto_install_locked() (
    set -euo pipefail
    local project=$1 root=${2%/} mode=$3 payload data job stage='' backup='' temporary file
    local previous_mode='' previous_reason='' control_changed=false committed=false
    payload="$root/opt/xray-vps-kit-auto-update"
    data="$root/var/lib/xray-vps-kit-auto-update"
    job="$root/etc/cron.d/xray-vps-kit-auto-update"
    xvk_update_require_install "$root" || exit 1
    xvk_auto_verify "$root" || { xvk_error 'Foreign or changed automatic-update resources'; exit 1; }
    xvk_no_symlink_path "$payload" && xvk_no_symlink_path "$data" && xvk_no_symlink_path "$job" || exit 1
    stage=$(mktemp -d "$root/opt/.xray-auto-new.XXXXXXXX") || exit 1
    # A failed refresh must restore the prior scheduling mode, not silently
    # disable a previously enabled (or paused) worker.
    if [[ -f $data/control.json ]]; then
        previous_mode=$(jq -r .mode "$data/control.json") || exit 1
        previous_reason=$(jq -r .reason "$data/control.json") || exit 1
    fi
    trap 'if [[ -n $stage ]]; then rm -rf -- "$stage"; fi; if [[ -n $backup ]]; then if [[ ! -e $payload ]]; then mv -T "$backup" "$payload" || xvk_error "Worker recovery retained at $backup"; else xvk_auto_payload_remove "$backup" || xvk_error "Previous worker retained at $backup"; fi; fi; if [[ $control_changed == true && $committed != true ]]; then if [[ -n $previous_mode ]]; then xvk_auto_control_write "$root" "$previous_mode" "$previous_reason" || xvk_error "Automatic-update control could not be restored to $previous_mode"; else rm -f -- "$data/control.json" || xvk_error "Could not remove the partial automatic-update control file"; fi; fi' EXIT
    mkdir "$stage/lib" || exit 1
    for file in "$project"/lib/*.sh "$project"/lib/*.jq; do
        xvk_regular_file "$file" && install -m 644 "$file" "$stage/lib/${file##*/}" || exit 1
    done
    install -m 755 "$project/auto-update.sh" "$stage/auto-update.sh" || exit 1
    install -m 644 "$project/VERSION" "$stage/VERSION" || exit 1
    chmod 755 "$stage" "$stage/lib" || exit 1
    temporary=$(xvk_private_temp "$root/opt") || exit 1
    xvk_auto_payload_manifest "$stage" > "$temporary" || { rm -f "$temporary"; exit 1; }
    install -m 600 "$temporary" "$stage/ownership.json" || { rm -f "$temporary"; exit 1; }
    rm "$temporary" || exit 1
    mkdir -p "$data" "${job%/*}" || exit 1
    chmod 700 "$data" || exit 1
    # Disable eligibility before replacing files; setup failure stays fail-closed.
    xvk_auto_control_write "$root" disabled manual || exit 1
    control_changed=true
    if [[ -d $payload ]]; then
        backup=$(mktemp -d "$root/opt/.xray-auto-old.XXXXXXXX") || exit 1
        rmdir "$backup" && mv -T "$payload" "$backup" || exit 1
    fi
    mv -T "$stage" "$payload" || exit 1
    stage=''
    if [[ $mode == enabled ]]; then
        temporary=$(xvk_private_temp "${job%/*}") || exit 1
        xvk_auto_cron_text "$root" > "$temporary" || { rm -f "$temporary"; exit 1; }
        if ! chmod 644 "$temporary" || ! mv -fT "$temporary" "$job"; then rm -f "$temporary"; exit 1; fi
        if [[ $XVK_SANDBOX != true ]]; then
            systemctl enable --now cron && systemctl is-active --quiet cron || exit 1
        fi
    fi
    xvk_auto_control_write "$root" "$mode" manual || exit 1
    xvk_auto_verify "$root" || exit 1
    committed=true
    if [[ -n $backup ]]; then xvk_auto_payload_remove "$backup" || exit 1; backup=''; fi
)

xvk_auto_enable() {
    local project=$1 root=${2%/}
    [[ -f $root/etc/xray-vps-kit/state.json && -L $root/opt/xray-vps-kit/current ]] || { xvk_error 'Install the kit before enabling automatic updates'; return 1; }
    xvk_install_dependencies || return 1
    if [[ $XVK_SANDBOX != true ]] && ! command -v cron > /dev/null 2>&1; then
        printf '[Automatic updates] Installing cron (APT progress below)...\n' >&2
        if ! apt-get update < /dev/null >&2 || ! DEBIAN_FRONTEND=noninteractive apt-get -y --no-remove \
            -o Dpkg::Progress-Fancy=1 -o APT::Color=0 install cron < /dev/null >&2; then
            xvk_error 'Could not install cron'; return 1
        fi
        hash -r
        xvk_require_commands cron || return 1
    fi
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_auto_install_locked "$project" "$root" enabled || return 1
    printf 'Automatic stable Xray-core updates enabled: daily at 03:30 server local time. No immediate update.\n'
}

xvk_auto_disable_locked() {
    local root=${1%/}
    if ! xvk_auto_present "$root"; then printf 'Automatic updates are not configured.\n'; return 0; fi
    xvk_auto_verify "$root" || { xvk_error 'Automatic-update resources have drifted'; return 1; }
    xvk_auto_control_write "$root" disabled manual || return 1
    rm -f -- "$root/etc/cron.d/xray-vps-kit-auto-update" || return 1
    printf 'Automatic updates disabled; worker and last result retained.\n'
}

xvk_auto_status() {
    local root=${1%/} data
    if ! xvk_auto_present "$root"; then printf 'Automatic updates: not configured (disabled).\n'; return 0; fi
    xvk_auto_verify "$root" || { xvk_error 'Automatic-update resources have drifted'; return 1; }
    data="$root/var/lib/xray-vps-kit-auto-update"
    printf 'Automatic updates: %s (%s).\n' "$(jq -r .mode "$data/control.json")" "$(jq -r .reason "$data/control.json")"
    if [[ -f $data/last-run.json ]]; then
        jq -r '"Last run: \(.timestamp); outcome: \(.outcome); installed: \(.installedVersion // "unknown"); latest: \(.latestVersion // "unknown")"' "$data/last-run.json"
    else printf 'No check has run yet.\n'; fi
}
