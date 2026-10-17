#!/usr/bin/env bash
case "${1:-all}" in
    all|official-pinned-assets|corrupt-and-traversal) selected=${1:-all} ;;
    *) printf 'Unknown release case\n' >&2; exit 1 ;;
esac
[[ -f $PROJECT_DIR/lib/release.sh ]] || { printf 'FAIL: release module not implemented\n' >&2; exit 1; }
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/release.sh
source "$PROJECT_DIR/lib/release.sh"
xvk_require_commands jq curl unzip zipinfo sha256sum python3
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
lock="$PROJECT_DIR/releases/xray.lock.json"
assert_success 'official manifest validates' xvk_release_validate_lock "$lock"
if [[ $selected != corrupt-and-traversal ]]; then
    for arch in amd64 arm64; do
        url=$(jq -r --arg arch "$arch" '.assets[$arch].url' "$lock")
        expected=$(jq -r --arg arch "$arch" '.assets[$arch].sha256' "$lock")
        xvk_https_get "$url.dgst" "$scratch/digest"
        observed=$(sed -n 's/^SHA2-256= //p' "$scratch/digest" | tr -d '\r')
        assert_eq "$expected" "$observed" "official $arch digest matches pinned archive"
        archive=$(bash "$TESTS_DIR/download-core.sh" --arch "$arch")
        assert_success "$arch full archive digest verifies" xvk_verify_sha256 "$archive" "$expected"
        if [[ $arch == amd64 ]]; then
            mkdir "$scratch/core"
            assert_success 'native binary and license safely extracted' xvk_release_extract "$lock" "$arch" "$archive" "$scratch/core"
            version=$("$scratch/core/xray" version)
            assert_success 'real binary identifies pinned version' grep -q '^Xray 26\.3\.27 ' <<< "$version"
            assert_success 'upstream license retained' test -s "$scratch/core/LICENSE"
            assert_failure 'geodata not installed' test -e "$scratch/core/geoip.dat"
            digest=$(xvk_bundle_content_digest "$scratch/core")
            cp -a "$scratch/core" "$scratch/core-copy"
            assert_eq "$digest" "$(xvk_bundle_content_digest "$scratch/core-copy")" 'bundle digest is independent of parent directory'
            printf 'changed bytes\n' >> "$scratch/core-copy/LICENSE"
            assert_failure 'bundle digest detects content changes' test "$digest" = "$(xvk_bundle_content_digest "$scratch/core-copy")"
        fi
    done
fi
if [[ $selected != official-pinned-assets ]]; then
    printf 'corrupt bytes' > "$scratch/corrupt.zip"
    assert_failure 'local archive does not bypass pinned hash' xvk_release_extract "$lock" amd64 "$scratch/corrupt.zip" "$scratch"
    assert_failure 'wrong architecture rejected' xvk_release_extract "$lock" riscv64 "$scratch/corrupt.zip" "$scratch"
    jq 'del(.assets.amd64.sha256)' "$lock" > "$scratch/bad-lock.json"
    assert_failure 'missing digest rejected' xvk_release_validate_lock "$scratch/bad-lock.json"
    for kind in traversal symlink; do
        python3 "$TESTS_DIR/helpers/archive-fixture.py" "$scratch/$kind.zip" "$kind"
        mkdir "$scratch/$kind"
        assert_failure "unsafe $kind entry rejected before extraction" xvk_archive_extract "$scratch/$kind.zip" "$(sha256sum "$scratch/$kind.zip" | cut -d ' ' -f 1)" "$scratch/$kind"
        assert_eq '' "$(find "$scratch/$kind" -mindepth 1 -print -quit)" 'rejected archive left no files'
    done
    assert_failure 'no traversal escape' test -e "$scratch/escaped"
fi
