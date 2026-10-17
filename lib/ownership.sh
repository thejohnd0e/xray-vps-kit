#!/usr/bin/env bash

xvk_owned_file_paths() {
    printf '%s\n' etc/xray-vps-kit/state.json etc/xray-vps-kit/config.json \
        etc/systemd/system/xray-vps-kit.service usr/local/bin/xray-client
}

xvk_owned_relative_path() {
    case $1 in
        etc/xray-vps-kit/state.json|etc/xray-vps-kit/config.json|etc/systemd/system/xray-vps-kit.service|usr/local/bin/xray-client) return 0 ;;
    esac
    [[ $1 =~ ^opt/xray-vps-kit/releases/[A-Za-z0-9._-]+/([A-Za-z0-9_-]+/)*[A-Za-z0-9._-]+$ && $1 != *..* ]]
}

xvk_ownership_manifest() (
    set -euo pipefail
    local root=${1%/} bundle_root=${2%/} state bundle bundle_link rel base file mode entries hash firewall=${3:-null}
    jq -e ' .==null or (type=="object" and (keys==["backend","marker","port"]) and .backend=="ufw" and (.marker|test("^xray-vps-kit-[a-f0-9]{16}$")) and (.port|type=="number" and floor==. and .>=1 and .<=65535))' <<< "$firewall" > /dev/null || exit 1
    state="$root/etc/xray-vps-kit/state.json"
    xvk_state_validate "$state" || exit 1
    bundle=$(jq -r .installed.bundleId "$state") || exit 1
    bundle_link="$root/opt/xray-vps-kit/current"
    [[ -L $bundle_link && $(stat -c %u "$bundle_link") == "$EUID" && $(readlink "$bundle_link") == "releases/$bundle" ]] || exit 1
    xvk_no_symlink_path "$root/opt/xray-vps-kit" || exit 1
    base="$bundle_root/opt/xray-vps-kit/releases/$bundle"
    [[ -d $base && -f $base/xray ]] && xvk_no_symlink_path "$base" || exit 1
    [[ -z $(find "$base" -type l -print -quit) ]] || exit 1
    umask 077
    entries=$(mktemp) || exit 1
    trap 'rm -f -- "$entries"' EXIT
    while IFS= read -r rel; do
        xvk_owned_relative_path "$rel" || exit 1
        case $rel in opt/*) file="$bundle_root/$rel" ;; *) file="$root/$rel" ;; esac
        xvk_regular_file "$file" || exit 1
        [[ $(stat -c %u "$file") == "$EUID" && $(stat -c %h "$file") == 1 ]] || exit 1
        mode=$(stat -c %a "$file") || exit 1
        case "$rel:$mode" in
            etc/xray-vps-kit/state.json:600|etc/xray-vps-kit/config.json:640|etc/systemd/system/xray-vps-kit.service:644|usr/local/bin/xray-client:755|opt/*:644|opt/*:755) ;;
            *) exit 1 ;;
        esac
        hash=$(sha256sum "$file" | cut -d ' ' -f 1) || exit 1
        [[ $hash =~ ^[a-f0-9]{64}$ ]] || exit 1
        jq -cn --arg path "$rel" --arg hash "$hash" \
            --arg mode "$mode" --argjson uid "$(stat -c %u "$file")" --argjson gid "$(stat -c %g "$file")" \
            '{path:$path,sha256:$hash,mode:$mode,uid:$uid,gid:$gid}' >> "$entries" || exit 1
    done < <({ xvk_owned_file_paths; find "$base" -type f -printf "opt/xray-vps-kit/releases/$bundle/%P\n"; } | LC_ALL=C sort)
    jq -s --arg bundle "$bundle" --argjson firewall "$firewall" '{schemaVersion:1,bundleId:$bundle,files:.,firewallRule:$firewall}' "$entries"
)

xvk_ownership_verify() (
    set -euo pipefail
    local root=${1%/} bundle_root=${2%/} manifest actual
    manifest="$root/etc/xray-vps-kit/ownership.json"
    xvk_private_file "$manifest" || { xvk_error 'Unsafe ownership manifest'; exit 1; }
    actual=$(xvk_ownership_manifest "$root" "$bundle_root" "$(jq -c .firewallRule "$manifest")") || { xvk_error 'Owned resource mismatch'; exit 1; }
    # Compare whole normalized documents: no unknown fields, resource adoption,
    # changed modes/groups, missing files or forged broad parent permissions.
    jq -e -s --argjson actual "$actual" 'length==1 and .[0]==$actual' "$manifest" > /dev/null 2>&1 || {
        xvk_error 'Ownership manifest does not match resources'; exit 1;
    }
    # Generated config drift is an error even if a user also edited its hash.
    xvk_render_server "$root/etc/xray-vps-kit/state.json" | cmp -s - "$root/etc/xray-vps-kit/config.json" || {
        xvk_error 'Generated configuration drift'; exit 1;
    }
)

xvk_preserved_verify() (
    local root=${1%/} manifest path expected file record
    manifest="$root/etc/xray-vps-kit/ownership.json"
    xvk_private_file "$manifest" && xvk_state_validate "$root/etc/xray-vps-kit/state.json" || exit 1
    jq -e --arg bundle "$(jq -r .installed.bundleId "$root/etc/xray-vps-kit/state.json")" \
        'type=="object" and (keys==["bundleId","files","firewallRule","schemaVersion"]) and .schemaVersion==1 and .bundleId==$bundle and
        (.files|type=="array" and length>=5 and all(.[]; type=="object" and (keys==["gid","mode","path","sha256","uid"]) and (.sha256|test("^[a-f0-9]{64}$"))))' "$manifest" > /dev/null || exit 1
    while IFS= read -r path; do xvk_owned_relative_path "$path" || exit 1; done < <(jq -r '.files[].path' "$manifest")
    for path in etc/xray-vps-kit/state.json etc/xray-vps-kit/config.json; do
        file="$root/$path"
        xvk_regular_file "$file" || exit 1
        record=$(jq -ce --arg path "$path" '[.files[]|select(.path==$path)] | select(length==1) | .[0]' "$manifest") || exit 1
        expected=$(jq -cn --arg path "$path" --arg hash "$(sha256sum "$file" | cut -d ' ' -f 1)" \
            --arg mode "$(stat -c %a "$file")" --argjson uid "$(stat -c %u "$file")" --argjson gid "$(stat -c %g "$file")" \
            '{path:$path,sha256:$hash,mode:$mode,uid:$uid,gid:$gid}') || exit 1
        [[ $record == "$expected" ]] || exit 1
    done
    xvk_render_server "$root/etc/xray-vps-kit/state.json" | cmp -s - "$root/etc/xray-vps-kit/config.json"
)
