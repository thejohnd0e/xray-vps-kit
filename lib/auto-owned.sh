#!/usr/bin/env bash
# Independently owned optional resources; no source-time or host side effects.

xvk_auto_present() {
    local root=${1%/} path
    for path in opt/xray-vps-kit-auto-update var/lib/xray-vps-kit-auto-update etc/cron.d/xray-vps-kit-auto-update; do
        [[ ! -e $root/$path && ! -L $root/$path ]] || return 0
    done
    return 1
}

xvk_auto_cron_text() {
    local root=${1%/}
    printf '# xray-vps-kit: optional official stable core updates\nSHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf '30 3 * * * root /bin/bash %s/opt/xray-vps-kit-auto-update/auto-update.sh scheduled >/dev/null\n' "$root"
}

xvk_auto_payload_manifest() (
    set -euo pipefail
    local directory=$1 path rel mode entries
    xvk_no_symlink_path "$directory" || exit 1
    entries=$(mktemp) || exit 1
    trap 'rm -f -- "$entries"' EXIT
    while IFS= read -r -d '' path; do
        rel=${path#"$directory"/}
        if [[ $rel == lib && -d $path && ! -L $path ]]; then continue; fi
        [[ $rel != ownership.json ]] || continue
        [[ $rel == auto-update.sh || $rel == VERSION || $rel =~ ^lib/[A-Za-z0-9_-]+\.(sh|jq)$ ]] || exit 1
        xvk_regular_file "$path" || exit 1
        mode=$(stat -c %a "$path") || exit 1
        [[ $(stat -c %u "$path") == "$EUID" && $(stat -c %h "$path") == 1 ]] || exit 1
        case "$rel:$mode" in auto-update.sh:755|VERSION:644|lib/*:644) ;; *) exit 1 ;; esac
        jq -cn --arg path "$rel" --arg sha "$(sha256sum "$path" | cut -d ' ' -f 1)" \
            --arg mode "$mode" --argjson uid "$EUID" --argjson gid "$(stat -c %g "$path")" \
            '{path:$path,sha256:$sha,mode:$mode,uid:$uid,gid:$gid}' >> "$entries" || exit 1
    done < <(find "$directory" -mindepth 1 -print0)
    jq -s '{schemaVersion:1,files:sort_by(.path)}' "$entries"
)

xvk_auto_control_valid() {
    jq -e -s 'length==1 and (.[0] | type=="object" and keys==["mode","reason","schemaVersion"] and .schemaVersion==1
        and (.mode=="enabled" or .mode=="disabled" or .mode=="paused")
        and (.reason=="manual" or .reason=="rollback"))' "$1" > /dev/null
}

xvk_auto_verify() (
    set -euo pipefail
    local root=${1%/} payload data job actual path name
    xvk_auto_present "$root" || exit 0
    payload="$root/opt/xray-vps-kit-auto-update"
    data="$root/var/lib/xray-vps-kit-auto-update"
    job="$root/etc/cron.d/xray-vps-kit-auto-update"
    for path in "$payload" "$payload/lib" "$data"; do
        xvk_no_symlink_path "$path" && [[ -d $path && $(stat -c %u "$path") == "$EUID" ]] || exit 1
    done
    [[ $(stat -c %a "$payload") == 755 && $(stat -c %a "$payload/lib") == 755 && $(stat -c %a "$data") == 700 ]] || exit 1
    xvk_private_file "$payload/ownership.json" || exit 1
    [[ -f $payload/auto-update.sh && -f $payload/lib/auto-owned.sh && -f $payload/lib/core-update.sh ]] || exit 1
    actual=$(xvk_auto_payload_manifest "$payload") || exit 1
    jq -e -s --argjson actual "$actual" 'length==1 and .[0]==$actual' "$payload/ownership.json" > /dev/null || exit 1
    xvk_private_file "$data/control.json" && xvk_auto_control_valid "$data/control.json" || exit 1
    while IFS= read -r -d '' path; do
        name=${path##*/}
        case $name in control.json|last-run.json|last-run.log) ;; *) exit 1 ;; esac
        xvk_private_file "$path" && (( $(stat -c %s "$path") <= 65536 )) || exit 1
        if [[ $name == last-run.json ]]; then
            jq -e -s 'length==1 and (.[0] | keys==["installedVersion","latestVersion","outcome","schemaVersion","timestamp"]
                and .schemaVersion==1 and (.timestamp|type=="string" and length<64)
                and (.outcome=="updated" or .outcome=="current" or .outcome=="skipped" or .outcome=="error")
                and (.installedVersion==null or (.installedVersion|type=="string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
                and (.latestVersion==null or (.latestVersion|type=="string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))))' "$path" > /dev/null || exit 1
        fi
    done < <(find "$data" -mindepth 1 -maxdepth 1 -print0)
    if [[ -e $job || -L $job ]]; then
        xvk_regular_file "$job" && [[ $(stat -c %u "$job") == "$EUID" && $(stat -c %a "$job") == 644 && $(stat -c %h "$job") == 1 ]] || exit 1
        xvk_auto_cron_text "$root" | cmp -s - "$job" || exit 1
    fi
)

xvk_auto_control_write() {
    local root=${1%/} mode=$2 reason=${3:-manual} path temporary
    path="$root/var/lib/xray-vps-kit-auto-update/control.json"
    xvk_no_symlink_path "$path" || return 1
    [[ ! -e $path ]] || xvk_private_file "$path" || return 1
    temporary=$(xvk_private_temp "${path%/*}") || return 1
    if ! jq -n --arg mode "$mode" --arg reason "$reason" '{schemaVersion:1,mode:$mode,reason:$reason}' > "$temporary" ||
        ! xvk_auto_control_valid "$temporary" || ! mv -fT "$temporary" "$path"; then
        rm -f "$temporary"; return 1
    fi
}

xvk_auto_eligible() {
    local root=${1%/}
    xvk_auto_present "$root" && xvk_auto_verify "$root" &&
        [[ -f $root/etc/cron.d/xray-vps-kit-auto-update ]] &&
        jq -e '.mode=="enabled"' "$root/var/lib/xray-vps-kit-auto-update/control.json" > /dev/null
}

xvk_auto_pause() {
    local root=${1%/} previous
    if ! xvk_auto_present "$root"; then printf 'null\n'; return 0; fi
    xvk_auto_verify "$root" || return 1
    previous=$(cat "$root/var/lib/xray-vps-kit-auto-update/control.json") || return 1
    if [[ $(jq -r .mode <<< "$previous") == enabled ]]; then
        xvk_auto_control_write "$root" paused rollback || return 1
    fi
    printf '%s\n' "$previous"
}

xvk_auto_restore_control() {
    local root=${1%/} previous=$2 mode reason
    [[ $previous != null ]] || return 0
    xvk_auto_verify "$root" || return 1
    mode=$(jq -r .mode <<< "$previous") || return 1
    reason=$(jq -r .reason <<< "$previous") || return 1
    xvk_auto_control_write "$root" "$mode" "$reason"
}

xvk_auto_remove() {
    local root=${1%/} payload data path
    xvk_auto_present "$root" || return 0
    xvk_auto_verify "$root" || { xvk_error 'Automatic-update resources have drifted; refusing removal'; return 1; }
    payload="$root/opt/xray-vps-kit-auto-update" data="$root/var/lib/xray-vps-kit-auto-update"
    xvk_auto_control_write "$root" disabled manual || return 1
    rm -f -- "$root/etc/cron.d/xray-vps-kit-auto-update" || return 1
    while IFS= read -r path; do rm -- "$payload/$path" || return 1; done < <(jq -r '.files[].path' "$payload/ownership.json")
    rm -- "$payload/ownership.json" || return 1
    rmdir -- "$payload/lib" "$payload" || return 1
    for path in control.json last-run.json last-run.log; do rm -f -- "$data/$path" || return 1; done
    rmdir -- "$data"
}
