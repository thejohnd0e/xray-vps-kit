#!/usr/bin/env bash

xvk_install_help() {
    cat <<'HELP'
Usage: bash install.sh [OPTIONS]
  --port PORT             Local TCP listen port (default:443)
  --server-name DNS       Verified REALITY SNI (default:github.com)
  --first-client NAME     First identity (default:main-user)
  --no-first-client       Do not create an initial identity
  --fp FP                 TLS fingerprint in the first client's printed URI (default:chrome)
  --endpoint IPV4_OR_DNS  Public endpoint; otherwise discover IPv4 via HTTPS
  --target HOST:PORT      REALITY target (default:selected SNI:443)
  --non-interactive       Use validated defaults/flags without questions
  --restore               Restore preserved identities and settings
  --archive FILE          Local archive; pinned SHA256 still required
  --no-service --root DIR Testing only: existing empty owned absolute directory
  --help                  Print help without prompting
HELP
}

xvk_install_options() {
    XVK_PORT=443 XVK_SNI=github.com XVK_FIRST=main-user XVK_FP=chrome XVK_ENDPOINT='' XVK_TARGET=''
    XVK_ROOT=/ XVK_ARCHIVE='' XVK_AUTOMATION=false XVK_SANDBOX=false XVK_RESTORE=false
    XVK_PORT_SET=false XVK_SNI_SET=false XVK_FIRST_SET=false XVK_TARGET_SET=false XVK_FP_SET=false
    XVK_FRESH_FLAGS=false XVK_NO_FIRST=false
    while (( $# )); do
        case $1 in
            --port|--server-name|--first-client|--fp|--endpoint|--target|--root|--archive)
                xvk_require_value "$@" || return 1
                case $1 in
                    --port) XVK_PORT=$2; XVK_PORT_SET=true; XVK_FRESH_FLAGS=true ;;
                    --server-name) XVK_SNI=$2; XVK_SNI_SET=true; XVK_FRESH_FLAGS=true ;;
                    --first-client) XVK_FIRST=$2; XVK_FIRST_SET=true; XVK_FRESH_FLAGS=true ;;
                    --fp) XVK_FP=$2; XVK_FP_SET=true; XVK_FRESH_FLAGS=true ;;
                    --endpoint) XVK_ENDPOINT=$2; XVK_FRESH_FLAGS=true ;;
                    --target) XVK_TARGET=$2; XVK_TARGET_SET=true; XVK_FRESH_FLAGS=true ;;
                    --root) XVK_ROOT=$2 ;;
                    --archive) XVK_ARCHIVE=$2 ;;
                esac
                shift 2 ;;
            --non-interactive) XVK_AUTOMATION=true; shift ;;
            --no-service) XVK_SANDBOX=true; shift ;;
            --no-first-client) XVK_NO_FIRST=true; XVK_FRESH_FLAGS=true; shift ;;
            --restore) XVK_RESTORE=true; shift ;;
            *) xvk_error 'Unknown installer argument'; return 1 ;;
        esac
    done
    [[ $XVK_FIRST_SET != true || $XVK_NO_FIRST != true ]] || { xvk_error 'Conflicting first-client flags'; return 1; }
    [[ $XVK_FP_SET != true || $XVK_NO_FIRST != true ]] || { xvk_error '--fp needs a first client'; return 1; }
    [[ $XVK_RESTORE != true || $XVK_FRESH_FLAGS != true ]] || { xvk_error 'Restore rejects fresh setup flags'; return 1; }
    if [[ $XVK_SANDBOX == true ]]; then
        if [[ $XVK_ROOT == / ]] || ! xvk_validate_test_root "$XVK_ROOT"; then xvk_error 'Invalid testing root'; return 1; fi
    elif [[ $XVK_ROOT != / ]]; then
        xvk_error '--root requires --no-service'; return 1
    fi
    if [[ $XVK_AUTOMATION != true && ! -t 0 ]]; then
        xvk_error 'No TTY: use --non-interactive for explicit automation'; return 1
    fi
    if [[ $XVK_RESTORE != true ]]; then
        if ! xvk_validate_port "$XVK_PORT" || ! xvk_validate_host "$XVK_SNI"; then xvk_error 'Invalid port or SNI'; return 1; fi
        [[ $XVK_NO_FIRST == true ]] || xvk_validate_name "$XVK_FIRST" || { xvk_error 'Invalid first client'; return 1; }
        xvk_validate_fp "$XVK_FP" || { xvk_error 'Invalid fingerprint (see install.sh --help)'; return 1; }
        [[ -z $XVK_ENDPOINT ]] || xvk_validate_host "$XVK_ENDPOINT" || { xvk_error 'Invalid endpoint'; return 1; }
        [[ $XVK_TARGET_SET != true ]] || xvk_validate_target "$XVK_TARGET" || { xvk_error 'Invalid target'; return 1; }
    fi
    # Non-secret parsed configuration is shared with preflight/bundle modules.
    export XVK_PORT_SET XVK_SNI_SET XVK_ARCHIVE
}

xvk_prompt_value() {
    local prompt=$1 current=$2 value
    printf '%s [%s]: ' "$prompt" "$current" >&2
    IFS= read -r value || { xvk_error 'Installation canceled (EOF)'; return 1; }
    printf '%s\n' "${value:-$current}"
}
