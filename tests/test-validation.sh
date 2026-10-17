#!/usr/bin/env bash
case "${1:-all}" in
    all|valid-boundaries|malicious-and-missing-inputs) selected=${1:-all} ;;
    *) printf 'Unknown validation case\n' >&2; exit 1 ;;
esac
for dependency in jq openssl; do
    command -v "$dependency" > /dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 1; }
done
[[ -f $PROJECT_DIR/lib/common.sh && -f $PROJECT_DIR/lib/state.sh ]] || {
    printf 'FAIL: validation modules not implemented\n' >&2; exit 1;
}
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/state.sh
source "$PROJECT_DIR/lib/state.sh"
# shellcheck source=tests/helpers/state-fixture.sh
source "$TESTS_DIR/helpers/state-fixture.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
assert_success 'empty controlled root accepted' xvk_require_empty_test_root "$scratch"
write_state_fixture "$scratch/state.json"
# This must stay literal input; only the scratch path is interpolated.
# shellcheck disable=SC2016
attack='$(touch '"$scratch"'/marker)'

if [[ $selected != malicious-and-missing-inputs ]]; then
    for port in 1 443 65535 00443; do
        assert_success "valid port $port" xvk_validate_port "$port"
    done
    for host in github.com vpn.example.com 203.0.113.7 0.0.0.0 255.255.255.255 localhost; do
        assert_success "valid ASCII host $host" xvk_validate_host "$host"
    done
    assert_success 'valid target keeps independent port' xvk_validate_target github.com:443
    assert_success 'name boundary accepted' xvk_validate_name A1234567890123456789012345678901
    assert_success 'valid schema accepted' xvk_state_validate "$scratch/state.json"
    assert_eq amd64 "$(xvk_platform debian 12 x86_64)" 'Debian amd64 mapped'
    assert_eq amd64 "$(xvk_platform ubuntu 22.04 amd64)" 'Ubuntu amd64 mapped'
    assert_eq arm64 "$(xvk_platform debian 13 aarch64)" 'Debian arm64 mapped'
    assert_eq arm64 "$(xvk_platform ubuntu 24.04 arm64)" 'Ubuntu arm64 mapped'
    assert_success 'value present' xvk_require_value --port 443
    assert_success 'controlled absolute root' xvk_validate_test_root "$scratch"
    assert_failure 'fresh root must be empty' xvk_require_empty_test_root "$scratch"
fi
if [[ $selected != valid-boundaries ]]; then
    for port in 0 65536 -1 +443 1.5 999999999999999999999999999999 '' '443;touch nope'; do
        assert_failure 'invalid port refused' xvk_validate_port "$port"
    done
    for host in 999.1.1.1 1.2.3 01.2.3.4 1.2.3.4.5 '[::1]' ::1 '-bad.com' bad-.com 'a..b' '.example' 'example.' 'bad_name' 'a/b' 'a b' "$(printf 'a\nb')" "$attack" ''; do
        assert_failure 'invalid host refused' xvk_validate_host "$host"
    done
    for name in '../escape' 'a/b' 'a b' '' 'a;b' "$attack" A12345678901234567890123456789012; do
        assert_failure 'unsafe name refused' xvk_validate_name "$name"
    done
    assert_failure 'missing flag value' xvk_require_value --port
    assert_failure 'next option is not a value' xvk_require_value --port --help
    assert_failure 'unknown OS refused' xvk_platform fedora 42 x86_64
    assert_failure 'unsupported Debian refused' xvk_platform debian 11 x86_64
    assert_failure 'unsupported architecture refused' xvk_platform debian 13 riscv64
    assert_failure 'root slash refused' xvk_validate_test_root /
    assert_failure 'relative root refused' xvk_validate_test_root relative
    ln -s "$scratch" "$scratch/link"
    assert_failure 'symlink root refused' xvk_validate_test_root "$scratch/link"
    assert_failure 'symlink ancestor refused' xvk_validate_test_root "$scratch/link/child"
    assert_failure 'path traversal refused' xvk_validate_test_root "$scratch/../other"
    assert_failure 'invalid target port refused' xvk_validate_target github.com:0
    assert_failure 'missing target port refused' xvk_validate_target github.com
    before=$(sha256sum "$scratch/state.json")
    mutations=(
        '.schemaVersion=2' '.transport="future-cdn"' '.generation=-1' '.generation=1.5'
        '.endpoint="bad host"' '.port=0' '.port="443"' '.target="github.com:0"'
        '.serverName="bad host"' '.privateKey="invalid"' '.publicKey="invalid"'
        '.clients += .clients' '.clients[0].name="../bad"' '.clients[0].uuid="no"'
        '.clients += [(.clients[0] | .name="second" | .shortId="1111111111111111")]'
        '.clients += [(.clients[0] | .name="second" | .uuid="33333333-3333-4333-8333-333333333333")]'
        '.clients[0].shortId="ABCDEF0123456789"' '.installed.kitVersion="../bad"'
        '.installed.bundleId="../outside"' '.lastSuccessfulSnapshot="../../bad"'
        'del(.clients)' '.unexpected="unknown field"'
    )
    for mutation in "${mutations[@]}"; do
        jq "$mutation" "$scratch/state.json" > "$scratch/invalid.json"
        chmod 600 "$scratch/invalid.json"
        assert_failure 'invalid state refused without writes' xvk_state_validate "$scratch/invalid.json"
    done
    printf '{broken' > "$scratch/invalid.json"
    assert_failure 'malformed JSON refused' xvk_state_validate "$scratch/invalid.json"
    cat "$scratch/state.json" "$scratch/state.json" > "$scratch/invalid.json"
    assert_failure 'multiple JSON documents refused' xvk_state_validate "$scratch/invalid.json"
    ln -s "$scratch/state.json" "$scratch/state-link.json"
    assert_failure 'symlink state refused' xvk_state_validate "$scratch/state-link.json"
    cp "$scratch/state.json" "$scratch/public-state.json"
    chmod 644 "$scratch/public-state.json"
    assert_failure 'world-readable credential state refused' xvk_state_validate "$scratch/public-state.json"
    chmod 660 "$scratch/public-state.json"
    assert_failure 'group-writable credential state refused' xvk_state_validate "$scratch/public-state.json"
    ln "$scratch/state.json" "$scratch/hardlink.json"
    assert_failure 'hardlinked credential state refused' xvk_state_validate "$scratch/hardlink.json"
    rm "$scratch/hardlink.json"
    assert_eq "$before" "$(sha256sum "$scratch/state.json")" 'validation does not modify state'
    assert_failure 'shell metacharacters were never executed' test -e "$scratch/marker"
fi
