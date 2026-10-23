#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/helpers/assert.sh
source "$TESTS_DIR/helpers/assert.sh"
source "$PROJECT_DIR/lib/common.sh"
[[ ! -f $PROJECT_DIR/lib/dependencies.sh ]] || source "$PROJECT_DIR/lib/dependencies.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin"
# Command discovery is real; only package installation is replaced, so tests cannot
# change the host even if run as root. Missing commands appear only after install.
for tool in curl openssl ss timeout realpath sha256sum sort stat install cp mv rm mkdir \
    chmod cat readlink basename dirname date head cut tr wc id sleep mktemp \
    flock find sed grep awk tar systemctl getent useradd nft bash; do
    location=$(command -v "$tool" || printf '/bin/true')
    ln -s "$location" "$scratch/bin/$tool"
done
cat > "$scratch/bin/apt-get" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$DEP_TRACE"
case " $* " in
    *' remove '*|*' purge '*|*' autoremove '*) exit 99 ;;
    *' update '*) [[ ${DEP_FAIL:-} != update ]] ;;
    *' install '*)
        [[ ${DEP_FAIL:-} != install ]] || exit 23
        if [[ ${DEP_FAIL:-} != incomplete ]]; then
            for tool in jq unzip zipinfo qrencode; do /bin/ln -sf /bin/true "$DEP_BIN/$tool"; done
        fi
        printf 'APT download output\nProgress: [100%%]\n'
        ;;
    *) exit 98 ;;
esac
STUB
chmod +x "$scratch/bin/apt-get"
export DEP_TRACE="$scratch/apt.trace" DEP_BIN="$scratch/bin"
original_path=$PATH
export PATH="$scratch/bin"
XVK_SANDBOX=false
run_dependencies() { xvk_install_dependencies > "$scratch/output" 2>&1; }
assert_success 'automatically installs missing tools before requiring jq' \
    run_dependencies
assert_success 'missing package list is visible' grep -q 'jq.*unzip.*qrencode' "$scratch/output"
assert_success 'APT download output remains visible' grep -q 'APT download output' "$scratch/output"
assert_success 'APT progress remains visible' grep -q 'Progress:' "$scratch/output"
assert_success 'APT is instructed to show native progress' grep -q 'Dpkg::Progress-Fancy=1' "$DEP_TRACE"
assert_success 'APT refuses package removals' grep -q -- '--no-remove' "$DEP_TRACE"
assert_eq 1 "$(grep -c ' install ' "$DEP_TRACE")" 'missing packages installed in one invocation'
assert_success 'unzip package is not duplicated for zipinfo' grep -q 'install.*jq unzip qrencode$' "$DEP_TRACE"
: > "$DEP_TRACE"
assert_success 'already present tools skip APT' xvk_install_dependencies
assert_eq '' "$(cat "$DEP_TRACE")" 'no package-manager call when tools are present'
rm "$scratch/bin/jq"
XVK_SANDBOX=true
assert_failure 'sandbox reports missing tools without installing' xvk_install_dependencies
assert_eq '' "$(cat "$DEP_TRACE")" 'sandbox never invokes APT'
XVK_SANDBOX=false
for failure in update install incomplete; do
    : > "$DEP_TRACE"
    export DEP_FAIL=$failure
    assert_failure "dependency $failure failure stops installation" xvk_install_dependencies
    if [[ $failure == update ]]; then
        assert_failure 'failed update cannot proceed to install' grep -q ' install ' "$DEP_TRACE"
    fi
done
unset DEP_FAIL
export PATH=$original_path
test_finish
