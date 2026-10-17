#!/usr/bin/env bash

xvk_service_account_check() {
    local entry group _ uid gid gecos home shell max_uid
    entry=$(getent passwd xray-vps-kit) || entry=''
    group=$(getent group xray-vps-kit) || group=''
    if [[ -z $entry ]]; then
        [[ -z $group ]] || { xvk_error 'Existing service group is not owned'; return 1; }
        return 0
    fi
    IFS=: read -r _ _ uid gid gecos home shell <<< "$entry"
    max_uid=$(awk '$1=="SYS_UID_MAX" {print $2; exit}' /etc/login.defs)
    max_uid=${max_uid:-999}
    [[ $uid =~ ^[0-9]+$ && $uid -gt 0 && $uid -le $max_uid && $gecos == 'xray-vps-kit managed service account' && $home == /nonexistent ]] || return 1
    [[ $shell == /usr/sbin/nologin || $shell == /sbin/nologin ]] || return 1
    [[ $(cut -d: -f3 <<< "$group") == "$gid" && $(id -G xray-vps-kit) == "$gid" ]] || return 1
}

xvk_service_account_create() {
    xvk_service_account_check || return 1
    if ! getent passwd xray-vps-kit > /dev/null; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin --comment 'xray-vps-kit managed service account' xray-vps-kit || return 1
    fi
}

xvk_service_health() {
    local port=$1 deadline=$((SECONDS + 15)) consecutive=0 pid listeners
    while (( SECONDS < deadline )); do
        pid=$(systemctl show --property=MainPID --value xray-vps-kit.service) || return 1
        listeners=$(ss -H -ltnp "sport = :$port") || return 1
        if systemctl is-active --quiet xray-vps-kit.service && [[ $pid =~ ^[1-9][0-9]*$ && $listeners == *"pid=$pid,"* ]]; then
            consecutive=$((consecutive + 1))
            (( consecutive < 3 )) || return 0
        else
            consecutive=0
        fi
        # Bounded stability sampling of an external systemd/socket state.
        sleep 1
    done
    xvk_error 'Service did not reach stable active state with its intended TCP socket'; return 1
}

# The unit bounds crash restarts with StartLimitBurst. Operator-driven restarts count
# toward that limit too, so a few quick client changes would otherwise be refused by
# systemd and roll back; clearing the counter first keeps crash-loop protection intact.
xvk_service_restart() {
    systemctl reset-failed xray-vps-kit.service > /dev/null 2>&1 || true
    systemctl daemon-reload && systemctl restart xray-vps-kit.service
}

xvk_service_hook() {
    local action=$1 stage=$2 root=$3 bundle core port
    bundle=$(jq -r .installed.bundleId "$stage/etc/xray-vps-kit/state.json") || return 1
    core="${root%/}/opt/xray-vps-kit/releases/$bundle/xray"
    case $action in
        validate) "$core" run -test -config "$stage/etc/xray-vps-kit/config.json" > /dev/null 2>&1 ;;
        activate)
            [[ -z $root || $root == / ]] || return 0
            xvk_service_restart ;;
        restore)
            [[ -z $root || $root == / ]] || return 0
            if ! xvk_service_restart; then return 1; fi
            port=$(jq -r .port /etc/xray-vps-kit/state.json) || return 1
            xvk_service_health "$port" ;;
        healthcheck)
            [[ -z $root || $root == / ]] || return 0
            port=$(jq -r .port /etc/xray-vps-kit/state.json) || return 1
            xvk_service_health "$port" ;;
        *) return 1 ;;
    esac
}
