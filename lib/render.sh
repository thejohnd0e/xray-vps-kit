#!/usr/bin/env bash

xvk_url_component() { jq -nr --arg value "$1" '$value | @uri'; }

xvk_render_uri() {
    local state=$1 name=$2
    xvk_validate_name "$name" && xvk_state_validate "$state" || return 1
    jq -er --arg name "$name" '
        . as $state | .clients[] | select(.name==$name) |
        "vless://" + .uuid + "@" + $state.endpoint + ":" + ($state.port|tostring) +
        "?encryption=none&type=tcp&security=reality&flow=xtls-rprx-vision&sni=" + ($state.serverName|@uri) +
        "&fp=chrome&pbk=" + ($state.publicKey|@uri) + "&sid=" + (.shortId|@uri) + "#" + (.name|@uri)
    ' "$state"
}

xvk_render_server() {
    local state=$1
    xvk_state_validate "$state" || return 1
    jq '{
        log: {access:"none",loglevel:"warning"},
        inbounds: [{
            tag:"vless-in", listen:"0.0.0.0", port:.port, protocol:"vless",
            settings: {clients:[.clients[] | {id:.uuid,flow:"xtls-rprx-vision"}],decryption:"none"},
            streamSettings: {network:"raw",security:"reality",realitySettings:{
                show:false,target:.target,xver:0,serverNames:[.serverName],
                privateKey:.privateKey,
                # Pinned REALITY requires a nonempty shortIds array even when
                # VLESS has no identities. Empty SID creates no VLESS user.
                shortIds:(if (.clients|length)==0 then [""] else [.clients[].shortId] end)
            }},
            sniffing:{enabled:false}
        }],
        outbounds: [
            {tag:"direct",protocol:"freedom",settings:{domainStrategy:"UseIP"}},
            {tag:"blocked",protocol:"blackhole",settings:{}}
        ],
        routing: {domainStrategy:"IPOnDemand",rules:[{
            type:"field",inboundTag:["vless-in"],outboundTag:"blocked",
            ip:["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8",
                "169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","240.0.0.0/4",
                "::/128","::1/128","fc00::/7","fe80::/10","fec0::/10","ff00::/8"]
        }]}
    }' "$state"
}
