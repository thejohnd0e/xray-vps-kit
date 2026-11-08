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

# Family "6" inspects the IPv6 chain through ip6tables.
xvk_ufw_effective_allow() {
    local port=$1 family=${2:-} rules rule status chain=ufw-user-input tool=iptables
    if [[ $family == 6 ]]; then chain=ufw6-user-input tool=ip6tables; fi
    rules=$("$tool" -S "$chain") || return 1
    while IFS= read -r rule; do
        [[ $rule == "-A $chain "* ]] || continue
        [[ $rule != *' -p udp '* ]] || continue
        if [[ $rule =~ --dport[[:space:]]([0-9]+)([[:space:]]|$) && ${BASH_REMATCH[1]} != "$port" ]]; then continue; fi
        case $rule in
            "-A $chain -p tcp -m tcp --dport $port -j ACCEPT"|"-A $chain -j ACCEPT") return 0 ;;
            *' -j ACCEPT') continue ;;
            *) return 1 ;;
        esac
    done <<< "$rules"
    status=$(LC_ALL=C ufw status verbose) || return 1
    [[ $status == *'Default: allow (incoming)'* ]]
}

# Insert at the top so an earlier rule cannot shadow it. UFW refuses position 1 when it has
# no rules yet; then a plain append is the same thing, and the effectiveness check that
# follows still proves the rule works.
xvk_ufw_add_allow() {
    local port=$1 marker=$2
    LC_ALL=C ufw insert 1 allow in proto tcp from 0.0.0.0/0 to any port "$port" comment "$marker" > /dev/null 2>&1 ||
        LC_ALL=C ufw allow in proto tcp from 0.0.0.0/0 to any port "$port" comment "$marker" > /dev/null
}

# The IPv6 twin of xvk_ufw_add_allow; it carries the same marker so one record owns both rows.
xvk_ufw_add_allow6() {
    local port=$1 marker=$2
    LC_ALL=C ufw insert 1 allow in proto tcp from ::/0 to any port "$port" comment "$marker" > /dev/null 2>&1 ||
        LC_ALL=C ufw allow in proto tcp from ::/0 to any port "$port" comment "$marker" > /dev/null
}

# UFW only creates IPv6 rules when /etc/default/ufw says IPV6=yes.
xvk_ufw_ipv6_enabled() { grep -Eqi '^IPV6=yes' "${XVK_UFW_DEFAULTS:-/etc/default/ufw}" 2> /dev/null; }

# IPv6 must be usable before the server is told to listen on "::": the kernel supports it,
# it is not disabled, and "::" still accepts IPv4 (bindv6only=0), otherwise IPv4 clients break.
xvk_ipv6_available() {
    local proc=${XVK_PROC_NET_IF_INET6:-/proc/net/if_inet6}
    [[ -e $proc ]] || { xvk_error 'IPv6 is not available on this host'; return 1; }
    if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2> /dev/null || printf 0) == 1 ]]; then
        xvk_error 'IPv6 is disabled on this host (net.ipv6.conf.all.disable_ipv6=1)'; return 1
    fi
    if [[ $(sysctl -n net.ipv6.bindv6only 2> /dev/null || printf 0) == 1 ]]; then
        xvk_error 'net.ipv6.bindv6only=1 would stop IPv4 clients on a dual-stack listener'; return 1
    fi
}

# xvk_firewall_open PORT [IPV6]: prints the ownership record (or null when nothing was added).
# Each family is added only when its traffic is not already allowed.
xvk_firewall_open() {
    local port=$1 ipv6=${2:-false} marker record add4=false add6=false
    [[ ${XVK_FIREWALL:-none} != none ]] || { printf 'null\n'; return 0; }
    xvk_ufw_effective_allow "$port" || add4=true
    if [[ $ipv6 == true ]]; then
        xvk_ufw_ipv6_enabled || { xvk_error 'UFW has IPV6=no; set IPV6=yes in /etc/default/ufw and reload UFW'; return 1; }
        xvk_ufw_effective_allow "$port" 6 || add6=true
    fi
    if [[ $add4 == false && $add6 == false ]]; then printf 'null\n'; return 0; fi
    marker="xray-vps-kit-$(openssl rand -hex 8)" || return 1
    record=$(jq -cn --arg marker "$marker" --argjson port "$port" '{backend:"ufw",marker:$marker,port:$port}') || return 1
    if [[ $add4 == true ]] && { ! xvk_ufw_add_allow "$port" "$marker" || ! xvk_ufw_effective_allow "$port"; }; then
        xvk_firewall_remove "$record" || xvk_error 'Failed firewall insertion rollback needs operator recovery'
        xvk_error "UFW rule insertion/effectiveness failed; an identical or earlier foreign rule may shadow TCP $port"; return 1
    fi
    if [[ $add6 == true ]] && { ! xvk_ufw_add_allow6 "$port" "$marker" || ! xvk_ufw_effective_allow "$port" 6; }; then
        xvk_firewall_remove "$record" || xvk_error 'Failed firewall insertion rollback needs operator recovery'
        xvk_error "UFW IPv6 rule insertion/effectiveness failed; an earlier foreign rule may shadow TCP $port"; return 1
    fi
    printf '%s\n' "$record"
}

# Adds the IPv6 row for an existing install. $2 is the current ownership record (maybe null);
# prints "added" or "kept", then the record to keep (a new one when the kit had no rule of
# its own yet).
xvk_firewall_open_ipv6() {
    local port=$1 record=$2 marker
    XVK_FIREWALL=none
    if command -v ufw > /dev/null 2>&1 && [[ $(LC_ALL=C ufw status 2> /dev/null) == 'Status: active'* ]]; then XVK_FIREWALL=ufw; fi
    [[ $XVK_FIREWALL == ufw ]] || { printf 'kept\n%s\n' "$record"; return 0; }
    xvk_ufw_ipv6_enabled || { xvk_error 'UFW has IPV6=no; set IPV6=yes in /etc/default/ufw and reload UFW'; return 1; }
    if xvk_ufw_effective_allow "$port" 6; then printf 'kept\n%s\n' "$record"; return 0; fi
    if [[ $record == null ]]; then
        marker="xray-vps-kit-$(openssl rand -hex 8)" || return 1
        record=$(jq -cn --arg marker "$marker" --argjson port "$port" '{backend:"ufw",marker:$marker,port:$port}') || return 1
    else
        marker=$(jq -r .marker <<< "$record") || return 1
    fi
    if ! xvk_ufw_add_allow6 "$port" "$marker" || ! xvk_ufw_effective_allow "$port" 6; then
        xvk_firewall_remove "$record" 6 > /dev/null 2>&1 || true
        xvk_error 'UFW IPv6 rule insertion/effectiveness failed'; return 1
    fi
    printf 'added\n%s\n' "$record"
}

# xvk_firewall_remove RECORD [6]: deletes every row carrying the record's marker (or only the
# IPv6 row when the second argument is 6). Every row must still look exactly as the kit wrote
# it, otherwise nothing is deleted.
xvk_firewall_remove() {
    local record=$1 only=${2:-} marker port rows line number exact exact6 count=0
    local -a numbers=()
    [[ $record != null ]] || return 0
    jq -e '.backend=="ufw" and (.marker|test("^xray-vps-kit-[a-f0-9]{16}$")) and (.port|type=="number" and floor==. and .>=1 and .<=65535)' <<< "$record" > /dev/null || return 1
    marker=$(jq -r .marker <<< "$record")
    port=$(jq -r .port <<< "$record")
    rows=$(LC_ALL=C ufw status numbered) || return 1
    exact="^[[:space:]]*\\[[[:space:]]*([0-9]+)\\][[:space:]]+${port}/tcp[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]+Anywhere[[:space:]]+#[[:space:]]+${marker}[[:space:]]*$"
    exact6="^[[:space:]]*\\[[[:space:]]*([0-9]+)\\][[:space:]]+${port}/tcp[[:space:]]+\\(v6\\)[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]+Anywhere[[:space:]]+\\(v6\\)[[:space:]]+#[[:space:]]+${marker}[[:space:]]*$"
    while IFS= read -r line; do
        [[ $line == *"$marker"* ]] || continue
        count=$((count + 1))
        if [[ $line =~ $exact6 ]]; then
            numbers+=("${BASH_REMATCH[1]}")
        elif [[ $line =~ $exact ]]; then
            [[ $only == 6 ]] || numbers+=("${BASH_REMATCH[1]}")
        else
            xvk_error 'Owned firewall rule changed; refusing deletion'; return 1
        fi
    done <<< "$rows"
    (( count <= 2 )) || { xvk_error 'Owned firewall rule changed; refusing deletion'; return 1; }
    (( ${#numbers[@]} )) || return 0
    # Highest number first so the remaining numbers stay valid.
    for number in $(printf '%s\n' "${numbers[@]}" | sort -rn); do
        LC_ALL=C ufw --force delete "$number" > /dev/null || return 1
    done
}
