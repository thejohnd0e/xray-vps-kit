#!/usr/bin/env bash

xvk_firewall_preflight() {
    local port=$1 status rules='' rule
    XVK_FIREWALL=none
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        xvk_error "Unsupported firewalld: inbound TCP $port must be resolved before installation"; return 1
    fi
    if command -v ufw > /dev/null; then
        status=$(LC_ALL=C ufw status) || return 1
        [[ $status != 'Status: active'* ]] || XVK_FIREWALL=ufw
    fi
    if command -v nft > /dev/null; then
        rules=$(nft -j list ruleset) || return 1
        if [[ $XVK_FIREWALL == ufw ]]; then
            jq -e 'all(.nftables[] | select(has("chain")) | .chain | select(.hook=="input"); (.family=="ip" or .family=="ip6") and .table=="filter" and .name=="INPUT")' <<< "$rules" > /dev/null || {
                xvk_error "Ambiguous nft input backend; resolve inbound TCP $port"; return 1;
            }
        else
            # An empty accept-policy base chain (created by any iptables-nft use) blocks nothing;
            # only an input chain that has rules or a non-accept policy is unmanaged filtering.
            jq -e '[.nftables[] | select(has("rule")) | .rule | "\(.family)/\(.table)/\(.chain)"] as $used
                | all(.nftables[] | select(has("chain")) | .chain | select(.hook=="input");
                    (.policy // "accept") == "accept" and (("\(.family)/\(.table)/\(.name)" | IN($used[])) | not))' <<< "$rules" > /dev/null || {
                xvk_error "Unsupported unmanaged nft input rules; resolve inbound TCP $port"; return 1;
            }
        fi
    fi
    if command -v iptables-save > /dev/null; then
        rules=$(iptables-save -t filter) || return 1
        if [[ $XVK_FIREWALL == none ]] && grep -Eq '^:INPUT (DROP|REJECT)|^-A INPUT ' <<< "$rules"; then
            xvk_error "Unsupported unmanaged iptables input rules; resolve inbound TCP $port"; return 1
        fi
    fi
    if [[ $XVK_FIREWALL == ufw ]]; then
        xvk_require_commands iptables || return 1
        rules=$(iptables -S INPUT) || return 1
        while IFS= read -r rule; do
            [[ $rule == '-A INPUT '* ]] || continue
            # AWG UDP-only exceptions cannot block the selected TCP port.
            [[ $rule != *' -p udp '* ]] || continue
            [[ $rule =~ ^-A[[:space:]]INPUT[[:space:]]-j[[:space:]]ufw-[A-Za-z0-9_-]+$ ]] || {
                xvk_error "Foreign INPUT rule precedes UFW; resolve TCP $port"; return 1;
            }
        done <<< "$rules"
        for status in ufw-before-input ufw-before-logging-input; do
            rules=$(iptables -S "$status") || return 1
            while IFS= read -r rule; do
                [[ $rule == '-A '* ]] || continue
                case $rule in
                    *' -j ACCEPT'|*' -j LOG'|*' -j LOG '*|*' -j ufw-not-local'|*' -j ufw-user-input'|*' -m conntrack --ctstate INVALID -j DROP'|*' -m conntrack --ctstate INVALID -j ufw-logging-deny') ;;
                    *) xvk_error "Nonstandard UFW before-rule; resolve TCP $port"; return 1 ;;
                esac
            done <<< "$rules"
        done
        rules=$(iptables -S ufw-not-local) || return 1
        rule=$(awk '/^-A / {print; exit}' <<< "$rules")
        [[ $rule == '-A ufw-not-local -m addrtype --dst-type LOCAL -j RETURN' ]] || {
            xvk_error 'Nonstandard UFW local-address chain'; return 1;
        }
    elif ! command -v nft > /dev/null && ! command -v iptables-save > /dev/null; then
        xvk_error 'Cannot inspect local firewall. Bootstrap: sudo apt-get install nftables iptables'; return 1
    fi
}

xvk_ufw_effective_allow() {
    local port=$1 rules rule status
    rules=$(iptables -S ufw-user-input) || return 1
    while IFS= read -r rule; do
        [[ $rule == '-A ufw-user-input '* ]] || continue
        [[ $rule != *' -p udp '* ]] || continue
        if [[ $rule =~ --dport[[:space:]]([0-9]+)([[:space:]]|$) && ${BASH_REMATCH[1]} != "$port" ]]; then continue; fi
        case $rule in
            "-A ufw-user-input -p tcp -m tcp --dport $port -j ACCEPT"|'-A ufw-user-input -j ACCEPT') return 0 ;;
            *' -j ACCEPT') continue ;;
            *) return 1 ;;
        esac
    done <<< "$rules"
    status=$(LC_ALL=C ufw status verbose) || return 1
    [[ $status == *'Default: allow (incoming)'* ]]
}

xvk_firewall_open() {
    local port=$1 marker record
    if [[ ${XVK_FIREWALL:-none} == none ]] || xvk_ufw_effective_allow "$port"; then
        printf 'null\n'; return 0
    fi
    marker="xray-vps-kit-$(openssl rand -hex 8)" || return 1
    record=$(jq -cn --arg marker "$marker" --argjson port "$port" '{backend:"ufw",marker:$marker,port:$port}') || return 1
    if ! LC_ALL=C ufw insert 1 allow in proto tcp from 0.0.0.0/0 to any port "$port" comment "$marker" > /dev/null ||
        ! xvk_ufw_effective_allow "$port"; then
        xvk_firewall_remove "$record" || xvk_error 'Failed firewall insertion rollback needs operator recovery'
        xvk_error "UFW rule insertion/effectiveness failed; an identical or earlier foreign rule may shadow TCP $port"; return 1
    fi
    printf '%s\n' "$record"
}

xvk_firewall_remove() {
    local record=$1 marker port rows line number
    [[ $record != null ]] || return 0
    jq -e '.backend=="ufw" and (.marker|test("^xray-vps-kit-[a-f0-9]{16}$")) and (.port|type=="number" and floor==. and .>=1 and .<=65535)' <<< "$record" > /dev/null || return 1
    marker=$(jq -r .marker <<< "$record")
    port=$(jq -r .port <<< "$record")
    rows=$(LC_ALL=C ufw status numbered) || return 1
    line=$(grep -F "$marker" <<< "$rows") || return 0
    local exact="^[[:space:]]*\\[[[:space:]]*([0-9]+)\\][[:space:]]+${port}/tcp[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]+Anywhere[[:space:]]+#[[:space:]]+${marker}[[:space:]]*$"
    [[ $(wc -l <<< "$line") == 1 && $line =~ $exact ]] || { xvk_error 'Owned firewall rule changed; refusing deletion'; return 1; }
    number=${BASH_REMATCH[1]}
    LC_ALL=C ufw --force delete "$number" > /dev/null
}
