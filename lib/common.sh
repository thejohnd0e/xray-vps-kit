#!/usr/bin/env bash
# Shared validation has no source-time side effects or privileged operations.

xvk_error() { printf 'xray-vps-kit: %s\n' "$1" >&2; }

xvk_require_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" > /dev/null 2>&1 || {
            xvk_error "Missing required command: $command_name"; return 1;
        }
    done
}

xvk_require_value() {
    if (( $# < 2 )) || [[ -z $2 || $2 == --* ]]; then
        xvk_error 'Option requires a value'; return 1
    fi
}

xvk_validate_port() {
    [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

xvk_validate_name() { [[ ${1:-} =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

xvk_validate_host() {
    local host=${1:-} label octet
    local -a labels
    [[ -n $host && ${#host} -le 253 && $host != *[!a-zA-Z0-9.-]* ]] || return 1
    [[ $host != .* && $host != *. && $host != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$host"
    if [[ $host =~ ^[0-9.]+$ ]]; then
        (( ${#labels[@]} == 4 )) || return 1
        for octet in "${labels[@]}"; do
            [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( 10#$octet <= 255 )) || return 1
        done
    else
        for label in "${labels[@]}"; do
            [[ ${#label} -le 63 && $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
        done
    fi
}

xvk_validate_target() {
    local value=${1:-}
    [[ $value == *:* && ${value#*:} != *:* ]] || return 1
    xvk_validate_host "${value%:*}" && xvk_validate_port "${value##*:}"
}

xvk_platform() {
    (( $# == 3 )) || return 1
    case "$1:$2" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
        *) xvk_error 'Unsupported operating system'; return 1 ;;
    esac
    case $3 in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) xvk_error 'Unsupported architecture'; return 1 ;;
    esac
}

# Reject traversal lexically before any filesystem resolution can hide it.
# This guard is also used for regular files, including their ancestor paths.
xvk_no_symlink_path() {
    local path=${1:-} component cursor=''
    local -a components
    [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* && $path != *//* ]] || return 1
    IFS=/ read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [[ -n $component && $component != . && $component != .. ]] || return 1
        cursor+=/"$component"
        [[ ! -L $cursor ]] || return 1
    done
}

xvk_regular_file() {
    [[ -f ${1:-} && ! -L $1 ]] && xvk_no_symlink_path "$1"
}

xvk_private_file() {
    # EUID is root for installed state; unprivileged tests use their own UID.
    xvk_regular_file "$1" &&
        [[ $(stat -c %u -- "$1") == "$EUID" && $(stat -c %a -- "$1") == 600 && $(stat -c %h -- "$1") == 1 ]]
}

xvk_validate_test_root() {
    local path=${1:-} cursor owner mode bits
    [[ $path != / && -d $path ]] && xvk_no_symlink_path "$path" || return 1
    [[ $(stat -c %u -- "$path") == "$EUID" ]] || return 1
    cursor=$path
    while [[ $cursor != / ]]; do
        owner=$(stat -c %u -- "$cursor") || return 1
        mode=$(stat -c %a -- "$cursor") || return 1
        [[ $owner == 0 || $owner == "$EUID" ]] || return 1
        bits=$((8#$mode))
        # Root-owned sticky /tmp is safe when the child belongs to the caller.
        if (( (bits & 0022) != 0 )); then
            [[ $owner == 0 ]] && (( (bits & 01000) != 0 )) || return 1
        fi
        cursor=${cursor%/*}
        [[ -n $cursor ]] || cursor=/
    done
}

xvk_require_empty_test_root() {
    xvk_validate_test_root "$1" && [[ -z $(find "$1" -mindepth 1 -maxdepth 1 -print -quit) ]]
}

xvk_private_temp() {
    # Caller owns and validates parent first; same-filesystem staging can be
    # selected by passing the intended destination's parent directory.
    local parent=$1
    [[ -d $parent ]] && xvk_no_symlink_path "$parent" || return 1
    (umask 077; mktemp -- "$parent/.xvk.XXXXXXXXXX")
}
