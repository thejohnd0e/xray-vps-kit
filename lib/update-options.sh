#!/usr/bin/env bash
# XVK_UPDATE_ACTION is read by xvk_update_run after option parsing.
# shellcheck disable=SC2034

xvk_update_help() {
    cat <<'HELP'
Usage: bash update.sh [OPTIONS]
  --check          Compare the installed kit with this checkout (0/10/1)
  --rollback       Restore the previous matching bundle through a transaction
  --archive FILE   Local Xray archive; pinned SHA256 is still required
  --root DIR       Testing only: operate on an installed sandbox root
  --help           Print help
HELP
}

xvk_update_options() {
    local mode_seen=false
    XVK_ROOT=/ XVK_ARCHIVE='' XVK_UPDATE_ACTION=apply XVK_SANDBOX=false
    while (( $# )); do
        case $1 in
            --check|--rollback)
                [[ $mode_seen == false ]] || { xvk_error 'Choose only one of --check or --rollback'; return 1; }
                mode_seen=true
                if [[ $1 == --check ]]; then
                    XVK_UPDATE_ACTION=check
                else
                    XVK_UPDATE_ACTION=rollback
                fi
                shift ;;
            --archive|--root)
                xvk_require_value "$@" || return 1
                case $1 in
                    --archive) XVK_ARCHIVE=$2 ;;
                    --root) XVK_ROOT=$2 ;;
                esac
                shift 2 ;;
            *) xvk_error 'Unknown update argument'; return 1 ;;
        esac
    done
    if [[ $XVK_ROOT != / ]]; then
        xvk_validate_test_root "$XVK_ROOT" || { xvk_error 'Invalid testing root'; return 1; }
        XVK_SANDBOX=true
    elif [[ $EUID != 0 ]]; then
        xvk_error 'Production update requires root'; return 1
    fi
    if [[ -n $XVK_ARCHIVE ]]; then
        xvk_regular_file "$XVK_ARCHIVE" || { xvk_error 'Local archive must be a regular non-symlink file'; return 1; }
        XVK_ARCHIVE=$(realpath -e -- "$XVK_ARCHIVE") || return 1
    fi
    XVK_ARCH=$(xvk_update_arch) || return 1
    export XVK_ROOT XVK_ARCHIVE XVK_ARCH XVK_SANDBOX
}
