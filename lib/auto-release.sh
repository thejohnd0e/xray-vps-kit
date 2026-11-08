#!/usr/bin/env bash

xvk_auto_fetch_release() {
    curl --fail --silent --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 45 --max-filesize 1048576 \
        --header 'Accept: application/vnd.github+json' --header 'X-GitHub-Api-Version: 2022-11-28' \
        --user-agent 'xray-vps-kit-auto-update' \
        --output "$1" https://api.github.com/repos/XTLS/Xray-core/releases/latest
}

# A scheduled run waits until the release is a few days old, so a regression found
# right after publication does not reach every server at once. An explicit `run`
# skips this wait. Unknown or unparsable publication time counts as too young.
xvk_auto_release_aged() {
    local metadata=$1 days=${XVK_AUTO_MIN_AGE_DAYS:-3} published stamp now
    [[ $days =~ ^[0-9]{1,3}$ ]] || return 1
    published=$(jq -er '.published_at | select(type=="string")' "$metadata") || return 1
    stamp=$(date -u -d "$published" +%s 2> /dev/null) || return 1
    now=${XVK_AUTO_NOW:-$(date -u +%s)}
    (( now - stamp >= 10#$days * 86400 ))
}

# API fields never become executable text or arbitrary download URLs. The resolved
# lock has the same strict shape as a reviewed pin, but upstream metadata is the
# explicit trust source for this opt-in feature.
xvk_auto_release_lock() (
    set -euo pipefail
    local metadata=$1 output=$2 temporary
    xvk_regular_file "$metadata" && xvk_no_symlink_path "$output" || exit 1
    temporary=$(xvk_private_temp "${output%/*}") || exit 1
    trap 'rm -f -- "$temporary"' EXIT
    jq -e -s '
        def asset($name; $tag):
            [.assets[] | select(.name==$name)] as $items
            | if ($items|length)!=1 then error("Missing or duplicate official asset") else $items[0] end
            | ("https://github.com/XTLS/Xray-core/releases/download/"+$tag+"/"+$name) as $url
            | if .browser_download_url!=$url or (.digest|type)!="string" then error("Invalid official asset metadata")
              elif (.digest|test("^sha256:[a-f0-9]{64}$")|not) then error("Missing official SHA256 digest")
              else {name:$name,url:$url,sha256:(.digest|ltrimstr("sha256:"))} end;
        if length!=1 then error("Expected one API release document") else .[0] end
        | if type!="object" then error("Invalid release document")
          elif .draft!=false or .prerelease!=false then error("Only stable official releases are supported")
          elif (.tag_name|type)!="string" then error("Missing release tag")
          elif (.tag_name|test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")|not) then error("Unsupported release tag")
          elif (.assets|type)!="array" then error("Missing release assets")
          elif (.assets|all(.[];type=="object")|not) then error("Malformed release assets")
          else . end
        | .tag_name as $tag
        | {schemaVersion:1,version:$tag,assets:{
            amd64:asset("Xray-linux-64.zip";$tag),
            arm64:asset("Xray-linux-arm64-v8a.zip";$tag)}}
    ' "$metadata" > "$temporary" || { xvk_error 'Official release metadata was rejected'; exit 1; }
    xvk_release_validate_lock "$temporary" || exit 1
    mv -fT -- "$temporary" "$output" || exit 1
)
