#!/usr/bin/env bash
# Client lifecycle. Mutations build the next state generation, render and
# validate the server config, then commit exclusively through the transaction
# engine; reads never write and never allocate a second credential database.

xvk_client_root_from_bundle() {
    local bundle=${1:-}
    case $bundle in
        */opt/xray-vps-kit/releases/*) printf '%s\n' "${bundle%/opt/xray-vps-kit/releases/*}" ;;
        *) return 1 ;;
    esac
}

xvk_client_require_install() {
    local root=${1%/} cfg
    cfg="${root%/}/etc/xray-vps-kit"
    [[ -f $cfg/state.json && -f $cfg/config.json && -f $cfg/ownership.json ]] || {
        xvk_error 'Kit is not installed at this location'; return 1;
    }
    xvk_state_validate "$cfg/state.json" || { xvk_error 'Installed state is invalid'; return 1; }
}

xvk_client_list() {
    local root=${1%/} cfg
    cfg="${root%/}/etc/xray-vps-kit"
    xvk_client_require_install "$root" || return 1
    jq -r '.clients[].name' "$cfg/state.json"
}

xvk_client_mutate() (
    set -euo pipefail
    local root=${1%/} operation=${2:-} name=${3:-}
    local cfg lock stage='' client bundle core firewall
    cfg="${root%/}/etc/xray-vps-kit"
    lock="${root%/}/run/lock/xray-vps-kit.lock"
    # Reads the dynamically scoped locals at EXIT; only the exact stage path
    # this invocation created is ever removed.
    trap 'if [[ -n ${stage:-} && $stage == "$cfg"/.stage.* ]]; then rm -rf -- "$stage"; fi' EXIT
    xvk_client_require_install "$root" || exit 1
    xvk_validate_name "$name" || { xvk_error 'Invalid client name'; exit 1; }
    case $operation in
        add)
            if jq -e --arg name "$name" 'any(.clients[]; .name==$name)' "$cfg/state.json" > /dev/null; then
                xvk_error 'Client name already exists'; exit 1
            fi ;;
        remove)
            if ! jq -e --arg name "$name" 'any(.clients[]; .name==$name)' "$cfg/state.json" > /dev/null; then
                xvk_error 'No such client'; exit 1
            fi ;;
        *) xvk_error 'Unsupported client operation'; exit 1 ;;
    esac
    xvk_require_commands jq openssl flock || exit 1
    bundle=$(readlink "$root/opt/xray-vps-kit/current") || exit 1
    [[ $bundle =~ ^releases/[A-Za-z0-9._-]+$ && $bundle != *..* ]] || {
        xvk_error 'Installed bundle is inconsistent'; exit 1;
    }
    core="${root%/}/opt/xray-vps-kit/$bundle/xray"
    [[ -x $core ]] || { xvk_error 'Installed core is missing'; exit 1; }
    stage=$(mktemp -d "$cfg/.stage.XXXXXXXX") || exit 1
    chmod 700 "$stage" || exit 1
    umask 077
    mkdir -p "$stage/etc/xray-vps-kit" "$stage/etc/systemd/system" \
        "$stage/usr/local/bin" "$stage/opt/xray-vps-kit" || exit 1
    case $operation in
        add)
            client=$(xvk_new_identity "$core" "$name" "$cfg/state.json") || exit 1
            jq --argjson client "$client" '.generation+=1 | .clients += [$client]' \
                "$cfg/state.json" > "$stage/etc/xray-vps-kit/state.json" || exit 1 ;;
        remove)
            jq --arg name "$name" '.generation+=1 | .clients |= map(select(.name!=$name))' \
                "$cfg/state.json" > "$stage/etc/xray-vps-kit/state.json" || exit 1 ;;
    esac
    chmod 600 "$stage/etc/xray-vps-kit/state.json" || exit 1
    xvk_render_server "$stage/etc/xray-vps-kit/state.json" > "$stage/etc/xray-vps-kit/config.json" || exit 1
    chmod 640 "$stage/etc/xray-vps-kit/config.json" || exit 1
    # The unprivileged service user reads the config through its group; a freshly rendered
    # file would otherwise be root:root and the next restart could not open it.
    chgrp --reference="$cfg/config.json" "$stage/etc/xray-vps-kit/config.json" || exit 1
    "$core" run -test -config "$stage/etc/xray-vps-kit/config.json" > /dev/null 2>&1 || {
        xvk_error 'Candidate core rejected generated config'; exit 1;
    }
    cp -p "$root/etc/systemd/system/xray-vps-kit.service" "$stage/etc/systemd/system/xray-vps-kit.service" || exit 1
    cp -p "$root/usr/local/bin/xray-client" "$stage/usr/local/bin/xray-client" || exit 1
    ln -s -- "$bundle" "$stage/opt/xray-vps-kit/current" || exit 1
    xvk_core_link_sync "$root" "$stage" || exit 1
    firewall=$(jq -c .firewallRule "$cfg/ownership.json") || exit 1
    xvk_ownership_manifest "$stage" "$root" "$firewall" > "$stage/etc/xray-vps-kit/ownership.json" || exit 1
    chmod 600 "$stage/etc/xray-vps-kit/ownership.json" || exit 1
    xvk_with_lock "$lock" xvk_transaction_apply "$root" "$stage" xvk_service_hook || exit 1
)

xvk_client_add() {
    local root=${1%/} name=${2:-} cfg
    cfg="${root%/}/etc/xray-vps-kit"
    xvk_client_mutate "$root" add "$name" || return 1
    xvk_render_uri "$cfg/state.json" "$name"
}

xvk_client_remove() {
    local root=${1%/} name=${2:-}
    xvk_client_mutate "$root" remove "$name"
}
