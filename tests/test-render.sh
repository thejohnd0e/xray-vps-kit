#!/usr/bin/env bash
case "${1:-all}" in
    all|real-core-and-uri-roundtrip|malformed-state-and-future-transport) selected=${1:-all} ;;
    *) printf 'Unknown render case\n' >&2; exit 1 ;;
esac
[[ -f $PROJECT_DIR/lib/render.sh ]] || { printf 'FAIL: renderer not implemented\n' >&2; exit 1; }
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/state.sh
source "$PROJECT_DIR/lib/state.sh"
# shellcheck source=lib/release.sh
source "$PROJECT_DIR/lib/release.sh"
# shellcheck source=lib/render.sh
source "$PROJECT_DIR/lib/render.sh"
# shellcheck source=tests/helpers/state-fixture.sh
source "$TESTS_DIR/helpers/state-fixture.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/core"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
xvk_release_extract "$PROJECT_DIR/releases/xray.lock.json" amd64 "$archive" "$scratch/core"
core="$scratch/core/xray"
write_state_fixture "$scratch/base.json"
xvk_new_keys "$core" > "$scratch/keys.json"
jq --slurpfile keys "$scratch/keys.json" '.privateKey=$keys[0].privateKey | .publicKey=$keys[0].publicKey' "$scratch/base.json" > "$scratch/state.json"
chmod 600 "$scratch/state.json"

if [[ $selected != malformed-state-and-future-transport ]]; then
    xvk_render_server "$scratch/state.json" > "$scratch/config.json"
    core_status=0
    "$core" run -test -config "$scratch/config.json" > "$scratch/core-check.log" 2>&1 || core_status=$?
    if (( core_status != 0 )); then
        sed -E 's/[A-Za-z0-9_-]{43}/[REDACTED]/g; s/[a-f0-9-]{36}/[REDACTED]/g' "$scratch/core-check.log" >&2
    fi
    assert_eq 0 "$core_status" 'generated server config accepted by pinned real core'
    xvk_render_uri "$scratch/state.json" test-device > "$scratch/uri"
    assert_success 'independent URI parser recovers exact portable fields' python3 "$TESTS_DIR/helpers/uri-check.py" "$scratch/state.json" "$scratch/uri"
    sed -e "s/{{UUID}}/$(jq -r '.clients[0].uuid' "$scratch/state.json")/" \
        -e "s/{{PUBLIC_KEY}}/$(jq -r .publicKey "$scratch/state.json")/" \
        "$TESTS_DIR/fixtures/uri/reality-tcp.template" > "$scratch/expected-uri"
    assert_success 'existing REALITY profile format matches portable fixture' cmp -s "$scratch/expected-uri" "$scratch/uri"
    xvk_render_uri "$scratch/state.json" test-device > "$scratch/uri-again"
    assert_success 'repeat export is byte-identical' cmp -s "$scratch/uri" "$scratch/uri-again"
    assert_success 'default fingerprint is chrome' grep -q -F '&fp=chrome&' "$scratch/uri"
    xvk_render_uri "$scratch/state.json" test-device firefox > "$scratch/uri-firefox"
    assert_success 'firefox fingerprint is written into the URI' grep -q -F '&fp=firefox&' "$scratch/uri-firefox"
    assert_success 'only the fingerprint differs between profiles' cmp -s "$scratch/uri-firefox" <(sed 's/&fp=chrome&/\&fp=firefox\&/' "$scratch/uri")
    assert_failure 'unknown fingerprint is refused' xvk_render_uri "$scratch/state.json" test-device bogus
    assert_failure 'fingerprint cannot smuggle extra URI parameters' xvk_render_uri "$scratch/state.json" test-device 'chrome&sni=evil.example'
    assert_eq 'hello%20%26%20%2B%2F%23%E2%98%83' "$(xvk_url_component 'hello & +/#☃')" 'UTF-8 values encode as URL components'
    assert_success 'routing uses explicit IP blocks, no geo-data' jq -e '.routing.domainStrategy == "IPOnDemand" and (.routing.rules[0].ip | index("169.254.0.0/16") != null) and .inbounds[0].sniffing.enabled == false' "$scratch/config.json"
    for client_count in 0 2; do
        if [[ $client_count == 0 ]]; then
            jq '.clients=[]' "$scratch/state.json" > "$scratch/changed.json"
        else
            identity=$(xvk_new_identity "$core" second "$scratch/state.json")
            jq --argjson client "$identity" '.clients += [$client]' "$scratch/state.json" > "$scratch/changed.json"
        fi
        chmod 600 "$scratch/changed.json"
        xvk_render_server "$scratch/changed.json" > "$scratch/config.json"
        core_status=0
        "$core" run -test -config "$scratch/config.json" > "$scratch/core-check.log" 2>&1 || core_status=$?
        if (( core_status != 0 )); then
            sed -E 's/[A-Za-z0-9_-]{43}/[REDACTED]/g; s/[a-f0-9-]{36}/[REDACTED]/g' "$scratch/core-check.log" >&2
        fi
        assert_eq 0 "$core_status" "real core accepts $client_count clients"
        assert_eq "$client_count" "$(jq '.inbounds[0].settings.clients | length' "$scratch/config.json")" 'renderer reflects exact client count'
    done
    jq '.clients |= map(select(.name != "test-device"))' "$scratch/changed.json" > "$scratch/removed.json"
    chmod 600 "$scratch/removed.json"
    xvk_render_server "$scratch/removed.json" > "$scratch/config.json"
    assert_success 'real core accepts selective removal state' "$core" run -test -config "$scratch/config.json"
    assert_eq "$(jq -r .uuid <<< "$identity")" "$(jq -r '.inbounds[0].settings.clients[0].id' "$scratch/config.json")" 'survivor UUID preserved after removal'
    assert_eq "$(jq -r .shortId <<< "$identity")" "$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$scratch/config.json")" 'survivor SID preserved after removal'
    assert_eq 1 "$(jq '.inbounds[0].settings.clients | length' "$scratch/config.json")" 'removed identity no longer rendered'
    # jq variables intentionally remain literal in the filter.
    # shellcheck disable=SC2016
    assert_success 'revoked UUID and SID absent from entire server config' jq -e \
        --arg uuid "$(jq -r '.clients[0].uuid' "$scratch/state.json")" \
        --arg sid "$(jq -r '.clients[0].shortId' "$scratch/state.json")" \
        '[.. | strings] | index($uuid)==null and index($sid)==null' "$scratch/config.json"
fi
if [[ $selected != real-core-and-uri-roundtrip ]]; then
    for filter in '.privateKey="invalid"' '.transport="future-cdn"' '.clients += .clients'; do
        jq "$filter" "$scratch/state.json" > "$scratch/bad.json"
        chmod 600 "$scratch/bad.json"
        status=0
        xvk_render_uri "$scratch/bad.json" test-device > "$scratch/rejected-uri" 2>/dev/null || status=$?
        assert_failure 'invalid state returns failure' test "$status" -eq 0
        assert_eq '' "$(cat "$scratch/rejected-uri")" 'invalid state emits no URI bytes'
        status=0
        xvk_render_server "$scratch/bad.json" > "$scratch/rejected-config" 2>/dev/null || status=$?
        assert_failure 'invalid server state returns failure' test "$status" -eq 0
        assert_eq '' "$(cat "$scratch/rejected-config")" 'invalid server state emits no config bytes'
    done
    printf 'PrivateKey: incomplete\n' > "$scratch/key-output"
    assert_failure 'incomplete key output refused' xvk_parse_keys "$scratch/key-output"
    assert_failure 'unknown client has no profile' xvk_render_uri "$scratch/state.json" absent
fi
