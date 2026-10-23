#!/usr/bin/env bash
case "${1:-all}" in
    all|relocated-source|curl-pipe-bootstrap) selected=${1:-all} ;;
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
    assert_success 'xray command works without the checkout' run_clean "$root/usr/local/bin/xray" version
    assert_eq user_01 "$(run_clean bash "$manager" list)" 'list works without the checkout'
    assert_success 'add works without the checkout' run_clean bash "$manager" add phone
    assert_success 'show works without the checkout' run_clean bash "$manager" show phone
    assert_success 'remove works without the checkout' run_clean bash "$manager" remove phone
    assert_eq user_01 "$(run_clean bash "$manager" list)" 'state is consistent afterwards'
fi

if [[ $selected == all || $selected == curl-pipe-bootstrap ]]; then
    # `curl ... | bash`: the script arrives on stdin with no checkout beside it. The repository
    # is a local one so the test needs no network; the code path is the real one.
    repo="$scratch/repo"
    mkdir "$repo"
    cp -a "$PROJECT_DIR/install.sh" "$PROJECT_DIR/update.sh" "$PROJECT_DIR/uninstall.sh" "$PROJECT_DIR/xray-client"         "$PROJECT_DIR/VERSION" "$PROJECT_DIR/lib" "$PROJECT_DIR/releases" "$PROJECT_DIR/templates" "$repo/"
    git -C "$repo" init -q
    git -C "$repo" add -A
    git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -q -m fixture
    src="$scratch/src-copy"
    bootstrap_bin="$scratch/bootstrap-bin"
    mkdir "$bootstrap_bin"
    for tool in bash dirname cat uname; do ln -s "$(command -v "$tool")" "$bootstrap_bin/$tool"; done
    XVK_TEST_GIT=$(command -v git)
    export XVK_TEST_GIT XVK_TEST_BOOTSTRAP_BIN="$bootstrap_bin" XVK_TEST_APT_TRACE="$scratch/bootstrap-apt-trace"
    cat > "$bootstrap_bin/apt-get" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$XVK_TEST_APT_TRACE"
case " $* " in
    *' update '*) printf 'bootstrap package-list output\n' ;;
    *' install '*)
        [[ " $* " == *' --no-remove '* ]] || exit 77
        [[ " $* " == *' Dpkg::Progress-Fancy=1 '* ]] || exit 78
        /bin/ln -s "$XVK_TEST_GIT" "$XVK_TEST_BOOTSTRAP_BIN/git"
        printf 'bootstrap APT progress\n'
        ;;
    *) exit 79 ;;
esac
STUB
    chmod +x "$bootstrap_bin/apt-get"
    bootstrap_without_git() {
        local script=${1:-install.sh}
        shift || true
        PATH="$bootstrap_bin" XVK_SRC="$scratch/bootstrap-src" XVK_REPO="file://$repo" \
            bash -s -- "$@" < "$PROJECT_DIR/$script" > "$scratch/bootstrap-output" 2>&1
    }
    for script in install.sh update.sh uninstall.sh; do
        rm -f "$bootstrap_bin/git"
        : > "$XVK_TEST_APT_TRACE"
        assert_failure 'piped sandbox refuses missing git' bootstrap_without_git "$script" --no-service --root "$scratch/sandbox"
        assert_eq '' "$(cat "$XVK_TEST_APT_TRACE")" 'piped sandbox never invokes APT'
    done
    if (( EUID == 0 )); then
        assert_success 'piped bootstrap installs missing git without removing packages' bootstrap_without_git install.sh --help
        assert_success 'bootstrap package installation progress is visible' grep -q 'bootstrap APT progress' "$scratch/bootstrap-output"
    else
        assert_failure 'source override cannot bypass root for package installation' bootstrap_without_git install.sh --help
        assert_eq '' "$(cat "$XVK_TEST_APT_TRACE")" 'non-root bootstrap never invokes APT'
    fi
    # Unsupported architectures must be rejected before package mutation, even
    # when a source-directory override is provided for the local fixture.
    rm -f "$bootstrap_bin/git"
    : > "$XVK_TEST_APT_TRACE"
    rm "$bootstrap_bin/uname"
    printf '#!/bin/bash\nprintf "unsupported-arch\\n"\n' > "$bootstrap_bin/uname"
    chmod +x "$bootstrap_bin/uname"
    assert_failure 'unsupported bootstrap architecture refuses' bootstrap_without_git install.sh --help
    assert_success 'unsupported platform is diagnosed' grep -qi 'unsupported' "$scratch/bootstrap-output"
    assert_eq '' "$(cat "$XVK_TEST_APT_TRACE")" 'unsupported bootstrap never invokes APT'
    piped() {
        local script=$1
        shift
        (cd /usr && XVK_SRC="$src" XVK_REPO="file://$repo" bash -s -- "$@" < "$PROJECT_DIR/$script")
    }
    assert_success 'piped install.sh clones the kit and runs from the copy (--help)' piped install.sh --help
    assert_success 'the kit was cloned to the source directory' test -f "$src/lib/common.sh" -a -d "$src/.git"
    assert_success 'piped output is the real installer help' grep -q 'Usage: bash install.sh' <<< "$(piped install.sh --help)"
    assert_success 'piped update.sh runs from the copy' grep -q 'Usage' <<< "$(piped update.sh --help)"
    assert_success 'piped uninstall.sh runs from the copy' grep -q 'Usage' <<< "$(piped uninstall.sh --help)"
    printf '0.0.9-bootstrap-check
' > "$repo/MARKER"
    git -C "$repo" add MARKER
    git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -q -m 'new commit'
    piped install.sh --help > /dev/null
    assert_success 'a second run fast-forwards the existing copy' test -f "$src/MARKER"
    printf 'local edit
' >> "$src/VERSION"
    assert_failure 'local changes that block the fast-forward are reported, not overwritten' bash -c "
        printf x > '$repo/MARKER2'; git -C '$repo' add MARKER2
        git -C '$repo' -c user.name=t -c user.email=t@e.invalid commit -q -m conflict
        git -C '$repo' -c user.name=t -c user.email=t@e.invalid mv VERSION VERSION.moved
        git -C '$repo' -c user.name=t -c user.email=t@e.invalid commit -q -m move
        cd /usr && XVK_SRC='$src' XVK_REPO='file://$repo' bash -s -- --help < '$PROJECT_DIR/install.sh'"
    block_of() { sed -n '/^# Started through `curl/,/^fi$/p' "$PROJECT_DIR/$1" | sed "s/$1/SCRIPT/g"; }
    assert_success 'the bootstrap block is not empty' test -n "$(block_of install.sh)"
    assert_eq "$(block_of install.sh)" "$(block_of update.sh)" 'install.sh and update.sh share one bootstrap block'
    assert_eq "$(block_of install.sh)" "$(block_of uninstall.sh)" 'install.sh and uninstall.sh share one bootstrap block'
    mkdir "$scratch/not-a-clone"
    assert_failure 'a directory that is not a clone is refused' bash -c "
        cd /usr && XVK_SRC='$scratch/not-a-clone' XVK_REPO='file://$repo' bash -s -- --help < '$PROJECT_DIR/install.sh'"
    assert_success 'inside a checkout the script runs locally and clones nothing'         bash -c "cd '$scratch' && XVK_SRC='$scratch/never' bash '$PROJECT_DIR/install.sh' --help > /dev/null && test ! -e '$scratch/never'"
fi
