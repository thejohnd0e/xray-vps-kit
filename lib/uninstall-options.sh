#!/usr/bin/env bash
# XVK_KEEP and XVK_ASSUME_YES are read by the uninstall lifecycle module.
# shellcheck disable=SC2034

xvk_uninstall_help() {
    cat <<'HELP'
Usage: bash uninstall.sh [OPTIONS]
  --yes            Remove without the confirmation prompt (automation)
  --keep-config    Keep state, config, ownership and backups for install --restore
  --root DIR       Testing only: operate on an installed sandbox root
  --help           Print help without prompting
The dedicated xray-vps-kit account and installed packages are always retained.
HELP
}

xvk_uninstall_options() {
    XVK_ROOT=/ XVK_KEEP=false XVK_ASSUME_YES=false XVK_SANDBOX=false
    while (( $# )); do
        case $1 in
            --yes) XVK_ASSUME_YES=true; shift ;;
            --keep-config) XVK_KEEP=true; shift ;;
            --root)
                xvk_require_value "$@" || return 1
                XVK_ROOT=$2
                shift 2 ;;
            *) xvk_error 'Unknown uninstall argument'; return 1 ;;
        esac
    done
    if [[ $XVK_ROOT != / ]]; then
        xvk_validate_test_root "$XVK_ROOT" || { xvk_error 'Invalid testing root'; return 1; }
        XVK_SANDBOX=true
    elif [[ $EUID != 0 ]]; then
        xvk_error 'Production uninstall requires root'; return 1
    fi
    if [[ $XVK_ASSUME_YES != true && ! -t 0 ]]; then
        xvk_error 'No TTY: use --yes for explicit automation'; return 1
    fi
    export XVK_ROOT XVK_KEEP XVK_ASSUME_YES XVK_SANDBOX
}
