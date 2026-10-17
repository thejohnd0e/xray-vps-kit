#!/usr/bin/env bash
case "${1:-all}" in
    all|relocated-source) selected=${1:-all} ;;
    *) printf 'Unknown packaging case\n' >&2; exit 1 ;;
esac
# The installed bundle must run with the source checkout gone: every module the launcher
# loads is inside the bundle and nothing installed points back at the checkout.
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_test_probe_path "$scratch"

if [[ $selected == all || $selected == relocated-source ]]; then
    archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
    source_copy="$scratch/checkout"
    mkdir "$source_copy"
    cp -a "$PROJECT_DIR/install.sh" "$PROJECT_DIR/xray-client" "$PROJECT_DIR/VERSION" \
        "$PROJECT_DIR/lib" "$PROJECT_DIR/releases" "$PROJECT_DIR/templates" "$source_copy/"
    root=$(mktemp -d "$scratch/root.XXXXXXXX")
    assert_success 'install from a copied checkout' \
        bash "$source_copy/install.sh" --non-interactive --no-service --root "$root" --endpoint 203.0.113.7 \
            --archive "$archive" --first-client user_01
    bundle=$(readlink -f "$root/opt/xray-vps-kit/current")
    modules=$(sed -n 's/^for module in \(.*\); do$/\1/p' "$bundle/xray-client")
    assert_success 'launcher names the modules it loads' test -n "$modules"
    for module in $modules; do
        assert_success "bundle contains module $module" test -f "$bundle/lib/$module.sh"
    done
    for file in VERSION releases/xray.lock.json xray xray-client lib/state-schema.jq; do
        assert_success "bundle contains $file" test -e "$bundle/$file"
    done
    assert_eq 0 "$(grep -rlaF -- "$source_copy" "$root" | wc -l | tr -d ' ')" 'nothing installed points back at the checkout'

    rm -rf -- "$source_copy"
    assert_failure 'the checkout is really gone' test -e "$source_copy"
    manager="$root/usr/local/bin/xray-client"
    # A near-empty environment: the launcher must not rely on variables from the shell that installed it.
    run_clean() { env -i PATH="$PATH" ${LD_LIBRARY_PATH:+LD_LIBRARY_PATH="$LD_LIBRARY_PATH"} "$@"; }
    assert_success 'version works without the checkout' run_clean bash "$manager" version
    assert_eq user_01 "$(run_clean bash "$manager" list)" 'list works without the checkout'
    assert_success 'add works without the checkout' run_clean bash "$manager" add phone
    assert_success 'show works without the checkout' run_clean bash "$manager" show phone
    assert_success 'remove works without the checkout' run_clean bash "$manager" remove phone
    assert_eq user_01 "$(run_clean bash "$manager" list)" 'state is consistent afterwards'
fi
