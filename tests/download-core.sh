#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
# shellcheck source=lib/release.sh
source "$project/lib/release.sh"
if (( $# != 2 )) || [[ $1 != --arch ]]; then
    printf 'Usage: bash tests/download-core.sh --arch amd64|arm64\n' >&2; exit 1
fi
arch=$2
case $arch in amd64|arm64) ;; *) xvk_error 'Unsupported test architecture'; exit 1 ;; esac
xvk_require_commands jq curl sha256sum
cache="$project/.omo/cache/core"
xvk_no_symlink_path "$cache" || exit 1
(umask 077; mkdir -p -- "$cache")
archive=$(xvk_release_acquire "$project/releases/xray.lock.json" "$arch" "$cache")
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_release_extract "$project/releases/xray.lock.json" "$arch" "$archive" "$scratch"
printf '%s\n' "$archive"
