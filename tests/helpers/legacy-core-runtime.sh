#!/usr/bin/env bash
# Test-only reconstruction of the genuine pre-command manager transaction stack.
# Other modules loaded by xray-client are unchanged from the pinned commit.
make_legacy_core_runtime() (
    set -euo pipefail
    local root=$1 old_bundle directory digest bundle module expected cache temporary state
    local commit=d59a902a5c56767ea27c24a5d8dbcb5c0f4ae22d
    for module in common state release render ownership bundle; do
        # shellcheck source=/dev/null
        source "$PROJECT_DIR/lib/$module.sh"
    done
    old_bundle=$(readlink "$root/opt/xray-vps-kit/current")
    directory="$root/opt/xray-vps-kit/$old_bundle"
    cache="$PROJECT_DIR/.omo/cache/core/legacy-$commit"
    mkdir -p "$cache"
    while read -r expected module; do
        if [[ ! -f $cache/$module ]] || [[ $(sha256sum "$cache/$module" | cut -d ' ' -f 1) != "$expected" ]]; then
            temporary=$(mktemp "$cache/.download.XXXXXXXX")
            if ! git -C "$PROJECT_DIR" show "$commit:lib/$module" > "$temporary" 2>/dev/null; then
                curl --fail --silent --show-error --proto '=https' --connect-timeout 10 --max-time 30 \
                    "https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/$commit/lib/$module" > "$temporary"
            fi
            [[ $(sha256sum "$temporary" | cut -d ' ' -f 1) == "$expected" ]] || {
                rm -f "$temporary"; printf 'Legacy runtime checksum mismatch\n' >&2; exit 1;
            }
            mv "$temporary" "$cache/$module"
        fi
        install -m 644 "$cache/$module" "$directory/lib/$module"
    done <<'LOCK'
5d0a06db8b86e89cc29e14507a1bf4904dc87de5cb62d5056de73fc799d0476f ownership.sh
53f0e66b2d3a9dc757f6a828a27613271980e31b0975abbcc7f4e8d361935a23 transaction.sh
0836355c03f6738f7ea466ba9ef5f6ae243e7ab9dd046ec7c40297e665837069 snapshot.sh
dddd8340fb17d388cb9b82e7b8623fe853e8d53a0a59b0057052c582bfc2b99f clients.sh
36764df2c1543b69450688b6979587fc288293061f175c14106b01a2501d7ef5 release.sh
LOCK
    digest=$(xvk_bundle_content_digest "$directory")
    state="$root/etc/xray-vps-kit/state.json"
    bundle=$(jq -r --arg digest "$digest" '.installed | .kitVersion+"-"+.coreVersion+"-"+$digest' "$state")
    mv "$directory" "$root/opt/xray-vps-kit/releases/$bundle"
    rm "$root/opt/xray-vps-kit/current" "$root/usr/local/bin/xray"
    ln -s "releases/$bundle" "$root/opt/xray-vps-kit/current"
    temporary=$(mktemp "$root/etc/xray-vps-kit/.legacy-state.XXXXXXXX")
    jq --arg digest "$digest" --arg bundle "$bundle" \
        '.installed.contentSha256=$digest | .installed.bundleId=$bundle' "$state" > "$temporary"
    install -m 600 "$temporary" "$state"
    rm "$temporary"
    # Generate exactly the manifest understood by the actual legacy manager.
    # shellcheck source=/dev/null
    source "$root/opt/xray-vps-kit/current/lib/ownership.sh"
    xvk_ownership_manifest "$root" "$root" > "$root/etc/xray-vps-kit/ownership.json"
    chmod 600 "$root/etc/xray-vps-kit/ownership.json"
)
