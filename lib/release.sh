#!/usr/bin/env bash

xvk_release_validate_lock() {
    local lock=$1
    xvk_regular_file "$lock" || return 1
    jq -e -s '
        length == 1 and (.[0] |
        type == "object" and (keys == ["assets","schemaVersion","version"])
        and .schemaVersion == 1
        and (.version | type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
        and (.assets | type == "object" and (keys == ["amd64","arm64"]))
        and (.version as $version | .assets | to_entries | all(.[];
            (.value | type == "object" and (keys == ["name","sha256","url"]))
            and .value.name == (if .key == "amd64" then "Xray-linux-64.zip" else "Xray-linux-arm64-v8a.zip" end)
            and (.value.sha256 | type == "string" and test("^[a-f0-9]{64}$"))
            and .value.url == ("https://github.com/XTLS/Xray-core/releases/download/" + $version + "/" + .value.name))))
    ' "$lock" > /dev/null 2>&1
}

xvk_https_get() {
    # Both the initial URL and redirects must remain HTTPS. This does not
    # replace the archive checksum check performed before every extraction.
    # A progress bar only on a terminal; logs and pipes stay quiet.
    local quiet=(--silent --show-error)
    [[ ! -t 2 ]] || quiet=(--progress-bar)
    curl --fail "${quiet[@]}" --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 180 --retry 2 --retry-max-time 360 \
        --output "$2" "$1"
}

xvk_verify_sha256() {
    local file=$1 expected=$2 observed
    [[ $expected =~ ^[a-f0-9]{64}$ ]] && xvk_regular_file "$file" || return 1
    observed=$(sha256sum -- "$file") || return 1
    [[ ${observed%% *} == "$expected" ]]
}

xvk_archive_extract() (
    set -euo pipefail
    local archive=$1 expected=$2 destination=$3 names entry listing
    # No extractor sees bytes before the complete archive digest passes.
    xvk_verify_sha256 "$archive" "$expected" || { xvk_error 'Archive checksum mismatch'; exit 1; }
    [[ -d $destination && -z $(find "$destination" -mindepth 1 -maxdepth 1 -print -quit) ]] || exit 1
    xvk_no_symlink_path "$destination" || exit 1
    names=$(unzip -Z -1 "$archive") || exit 1
    [[ -n $names ]] || exit 1
    local -A seen=()
    while IFS= read -r entry; do
        # An allowlist excludes traversal, paths, control bytes and duplicates.
        case $entry in xray|LICENSE|README.md|geoip.dat|geosite.dat) ;; *) exit 1 ;; esac
        [[ ! ${seen[$entry]+present} ]] || exit 1
        seen[$entry]=1
    done <<< "$names"
    [[ ${seen[xray]+present} && ${seen[LICENSE]+present} ]] || exit 1
    listing=$(zipinfo -l "$archive") || exit 1
    # zipinfo's permission records start with the Unix entry type (or '?'
    # for DOS regular files). Refuse links/devices/directories outright.
    if grep -Eq '^[lbcdps?]' <<< "$listing"; then
        xvk_error 'Archive contains a non-regular entry'; exit 1
    fi
    # Never unzip into the filesystem using archive paths. Copy only these
    # two exact members; upstream geodata is deliberately not installed.
    umask 077
    unzip -p "$archive" xray > "$destination/xray" || exit 1
    unzip -p "$archive" LICENSE > "$destination/LICENSE" || exit 1
    [[ -s $destination/xray && -s $destination/LICENSE ]] || exit 1
    chmod 755 "$destination/xray" || exit 1
    chmod 644 "$destination/LICENSE" || exit 1
)

# Four independent inputs identify the trust manifest, architecture, archive
# and staging output. Keeping them explicit prevents ambient manifest state.
xvk_release_extract() {
    local lock=$1 arch=$2 archive=$3 destination=$4 expected version actual native
    xvk_release_validate_lock "$lock" || { xvk_error 'Invalid release lock'; return 1; }
    case $arch in amd64|arm64) ;; *) xvk_error 'Unsupported release architecture'; return 1 ;; esac
    expected=$(jq -r --arg arch "$arch" '.assets[$arch].sha256' "$lock") || return 1
    xvk_archive_extract "$archive" "$expected" "$destination" || return 1
    native=$(uname -m)
    case "$native:$arch" in
        x86_64:amd64|aarch64:arm64)
            version=$(jq -r .version "$lock") || return 1
            actual=$("$destination/xray" version) || return 1
            [[ $actual == "Xray ${version#v} "* ]] || { xvk_error 'Core version mismatch'; return 1; } ;;
        *) ;; # Cross-architecture extraction never executes the binary.
    esac
}

xvk_release_acquire() (
    set -euo pipefail
    local lock=$1 arch=$2 cache=$3 expected name url archive temporary
    xvk_release_validate_lock "$lock" || exit 1
    case $arch in amd64|arm64) ;; *) exit 1 ;; esac
    xvk_no_symlink_path "$cache" && [[ -d $cache ]] || exit 1
    expected=$(jq -r --arg arch "$arch" '.assets[$arch].sha256' "$lock") || exit 1
    name=$(jq -r --arg arch "$arch" '.assets[$arch].name' "$lock") || exit 1
    url=$(jq -r --arg arch "$arch" '.assets[$arch].url' "$lock") || exit 1
    archive="$cache/$expected-$name"
    if [[ -e $archive || -L $archive ]]; then
        xvk_verify_sha256 "$archive" "$expected" || { xvk_error 'Cached archive mismatch; remove it explicitly before retrying'; exit 1; }
    else
        temporary=$(xvk_private_temp "$cache") || exit 1
        trap 'rm -f -- "$temporary"' EXIT
        printf 'Downloading %s from github.com (about 20 MB)...
' "$name" >&2
        xvk_https_get "$url" "$temporary" || exit 1
        xvk_verify_sha256 "$temporary" "$expected" || { xvk_error 'Downloaded archive mismatch'; exit 1; }
        # noclobber publishing: concurrent cache writers cannot replace data.
        ln -- "$temporary" "$archive" || xvk_verify_sha256 "$archive" "$expected" || exit 1
    fi
    printf '%s\n' "$archive"
)

xvk_bundle_content_digest() (
    set -euo pipefail
    local directory=$1 paths path digest
    [[ -d $directory && -f $directory/xray ]] && xvk_no_symlink_path "$directory" || exit 1
    [[ -z $(find "$directory" -type l -print -quit) ]] || exit 1
    cd -- "$directory" || exit 1
    paths=$(find . -type f -printf '%P\n' | LC_ALL=C sort) || exit 1
    [[ -n $paths ]] || exit 1
    digest=$(
        while IFS= read -r path; do
            [[ $path =~ ^([A-Za-z0-9_-]+/)*[A-Za-z0-9._-]+$ && $path != *..* ]] || exit 1
            sha256sum -- "$path" || exit 1
        done <<< "$paths" | sha256sum
    ) || exit 1
    printf '%s\n' "${digest%% *}"
)
