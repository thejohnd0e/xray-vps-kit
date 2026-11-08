#!/usr/bin/env bash
# Writes the pin for the newest stable official Xray-core release to releases/xray.lock.json.
# It reuses the strict metadata validation of the optional auto-updater, so the result has the
# same shape as a reviewed pin. Prints the new version, or nothing when the pin is current.
# Used by .github/workflows/update-xray-lock.yml; the resulting change is reviewed in a pull request.
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
for module in common release auto-release; do
    # shellcheck source=/dev/null
    source "$project/lib/$module.sh"
done
xvk_require_commands jq curl || exit 1
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_auto_fetch_release "$scratch/release.json" || { xvk_error 'Release query failed'; exit 1; }
xvk_auto_release_lock "$scratch/release.json" "$scratch/lock.json" || exit 1
current=$(jq -r .version "$project/releases/xray.lock.json")
latest=$(jq -r .version "$scratch/lock.json")
[[ $current != "$latest" ]] || exit 0
# Never move the pin backwards.
sorted=$(printf '%s\n%s\n' "${current#v}" "${latest#v}" | sort -V | tail -n 1)
[[ $sorted == "${latest#v}" ]] || { xvk_error "Upstream $latest is older than the pin $current"; exit 1; }
jq . "$scratch/lock.json" > "$project/releases/xray.lock.json"
printf '%s\n' "$latest"
