#!/usr/bin/env bash

xvk_state_validate() {
    local file=${1:-} lib_dir
    xvk_require_commands jq || return 1
    xvk_private_file "$file" || { xvk_error 'State requires caller ownership, mode 0600 and one regular-file link'; return 1; }
    lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    # Both parse errors and schema diagnostics are intentionally redacted:
    # jq errors may otherwise echo secret values supplied in malformed input.
    jq -e -s -f "$lib_dir/state-schema.jq" "$file" > /dev/null 2>&1 || {
        xvk_error 'Invalid or unsupported state schema'; return 1;
    }
    if ! xvk_validate_host "$(jq -r .endpoint "$file")" ||
        ! xvk_validate_host "$(jq -r .serverName "$file")" ||
        ! xvk_validate_target "$(jq -r .target "$file")"; then
        xvk_error 'Invalid state endpoint or target'; return 1
    fi
}

xvk_parse_keys() {
    local file=$1 line private='' public='' hash=''
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            'PrivateKey: '*)
                [[ -z $private ]] || return 1
                private=${line#'PrivateKey: '} ;;
            'Password (PublicKey): '*)
                [[ -z $public ]] || return 1
                public=${line#'Password (PublicKey): '} ;;
            'Hash32: '*)
                [[ -z $hash ]] || return 1
                hash=${line#'Hash32: '}
                [[ $hash =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1 ;;
            *) xvk_error 'Unexpected core key output'; return 1 ;;
        esac
    done < "$file"
    [[ $private =~ ^[A-Za-z0-9_-]{43}$ && $public =~ ^[A-Za-z0-9_-]{43}$ ]] || {
        xvk_error 'Incomplete core key output'; return 1;
    }
    jq -n --arg private "$private" --arg public "$public" '{privateKey:$private,publicKey:$public}'
}

xvk_new_keys() (
    set -euo pipefail
    local core=$1 output
    umask 077
    output=$(mktemp) || exit 1
    trap 'rm -f -- "$output"' EXIT
    "$core" x25519 > "$output" || exit 1
    xvk_parse_keys "$output"
)

xvk_new_identity() {
    local core=$1 name=$2 state=$3 uuid short_id attempt
    xvk_validate_name "$name" && xvk_state_validate "$state" || return 1
    if jq -e --arg name "$name" 'any(.clients[]; .name==$name)' "$state" > /dev/null; then
        xvk_error 'Client name already exists'; return 1
    fi
    for (( attempt=0; attempt<8; attempt++ )); do
        uuid=$("$core" uuid) || return 1
        short_id=$(openssl rand -hex 8) || return 1
        [[ $uuid =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ && $short_id =~ ^[a-f0-9]{16}$ ]] || return 1
        if ! jq -e --arg uuid "$uuid" --arg sid "$short_id" \
            'any(.clients[]; .uuid==$uuid or .shortId==$sid)' "$state" > /dev/null; then
            jq -n --arg name "$name" --arg uuid "$uuid" --arg sid "$short_id" '{name:$name,uuid:$uuid,shortId:$sid}'
            return 0
        fi
    done
    xvk_error 'Could not generate a unique identity'; return 1
}
