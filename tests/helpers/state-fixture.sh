#!/usr/bin/env bash
# Ephemeral test data, never an installed or persistent credential database.
write_state_fixture() {
    local output=$1 private public
    private=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
    public=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
    jq -n --arg private "$private" --arg public "$public" '{
        schemaVersion: 1, generation: 0, transport: "reality-tcp",
        endpoint: "vpn.example.com", port: 443, target: "github.com:443",
        serverName: "github.com", privateKey: $private, publicKey: $public,
        clients: [{name:"test-device",uuid:"a4eeb59c-e063-4d80-bcca-6b1b8a8ee922",shortId:"0123456789abcdef"}],
        installed: {kitVersion:"0.1.0",coreVersion:"v26.3.27",
            bundleId:("0.1.0-v26.3.27-" + ("a" * 64)),contentSha256:("a" * 64)},
        lastSuccessfulSnapshot: null
    }' > "$output"
    chmod 600 "$output"
}
