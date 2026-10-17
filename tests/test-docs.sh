#!/usr/bin/env bash
# Backticks in the fixtures are Markdown, not command substitution.
# shellcheck disable=SC2016
case "${1:-all}" in
    all|documented-lifecycle-and-links|stale-command-and-cdn-claim|evidence-claim-mismatch) selected=${1:-all} ;;
    *) printf 'Unknown docs case\n' >&2; exit 1 ;;
esac
# Documentation must describe what the code does. The checks below are plain functions
# over a Markdown file so the same code judges the real docs and the negative fixtures.
# shellcheck source=tests/helpers/sandbox.sh
source "$TESTS_DIR/helpers/sandbox.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xvk_test_probe_path "$scratch"

docs_files=("$PROJECT_DIR/README.md" "$PROJECT_DIR/docs/transport-extension.md")
# Pinned snapshot of the companion README that the backlink patch is written against.
awg_pin=7eb88d0c7f80f95baa1e0a343d99ba9dc25bbdfd
# Flags of tools this project does not own, plus the test runners' own options.
external_flags=' --no-pager --suite --case --os --guest '

# Every relative Markdown link must point at an existing file.
docs_links() {
    local file=$1 base target status=0
    base=$(dirname -- "$file")
    while IFS= read -r target; do
        target=${target%%#*}
        [[ -n $target && $target != http* && $target != mailto:* ]] || continue
        [[ -e $base/$target ]] || { printf 'broken link in %s: %s\n' "${file##*/}" "$target" >&2; status=1; }
    done < <(grep -oE '\]\([^)]+\)' "$file" | sed -E 's/^\]\((.*)\)$/\1/')
    return "$status"
}

# Every --flag the docs mention must exist in a help text of this project (or be external).
docs_flags() {
    local file=$1 flag status=0 help
    help=$(
        bash "$PROJECT_DIR/install.sh" --help
        bash "$PROJECT_DIR/update.sh" --help
        bash "$PROJECT_DIR/uninstall.sh" --help
        bash "$PROJECT_DIR/xray-client" help
    ) || { printf 'could not read the help texts\n' >&2; return 1; }
    while IFS= read -r flag; do
        [[ $external_flags == *" $flag "* ]] && continue
        grep -q -F -e "$flag" <<< "$help" || { printf 'unknown flag in %s: %s\n' "${file##*/}" "$flag" >&2; status=1; }
    done < <(grep -oE -e '--[a-z][a-z-]*[a-z]' "$file" | sort -u)
    return "$status"
}

# Claims the project cannot back: unhedged CDN statements, blanket compatibility or
# detection claims, and concrete secrets or identities in examples.
docs_claims() {
    local file=$1 status=0 paragraph line
    while IFS= read -r -d $'\x1e' paragraph; do
        if grep -qiE 'cloudflare|cdn|orange' <<< "$paragraph" &&
            ! grep -qiE 'not implemented|future|planned|would|must not|not "' <<< "$paragraph"; then
            printf 'unhedged CDN statement in %s: %s\n' "${file##*/}" "$(head -n 1 <<< "$paragraph")" >&2; status=1
        fi
    done < <(awk 'BEGIN{RS=""; ORS="\x1e"} {print}' "$file")
    while IFS= read -r line; do
        grep -qiE '(^|[^a-z])(no|not|never|nothing|without|isn.t)([^a-z]|$)' <<< "$line" && continue
        printf 'overclaim in %s: %s\n' "${file##*/}" "$line" >&2; status=1
    done < <(grep -iE 'works? (on|with) all (clients|apps)|undetectable|unblockable|cannot be blocked|guaranteed' "$file" || true)
    if grep -qiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$file"; then
        printf 'identity-like UUID in %s\n' "${file##*/}" >&2; status=1
    fi
    if grep -qiE 'private[ _-]?key[^a-z]{0,6}[A-Za-z0-9_-]{43}([^A-Za-z0-9_-]|$)' "$file"; then
        printf 'private key example in %s\n' "${file##*/}" >&2; status=1
    fi
    if grep -qE 'vless://[^ ]*@' "$file"; then
        printf 'concrete client URI in %s\n' "${file##*/}" >&2; status=1
    fi
    return "$status"
}

# Evidence receipts: every receipt an index names must exist and be non-empty.
docs_receipts() {
    local index=$1 dir=$2 receipt status=0
    while IFS= read -r receipt; do
        [[ -s $dir/$receipt ]] || { printf 'missing or empty receipt: %s
' "$receipt" >&2; status=1; }
    done < <(grep -oE '`[A-Za-z0-9._-]+\.(txt|md|jsonl)`' "$index" | tr -d '`' | sort -u)
    return "$status"
}

# A line that says arm64 (or a physical-app test) was verified needs a matching receipt.
docs_verified_claims() {
    local file=$1 dir=$2 line status=0
    while IFS= read -r line; do
        grep -qiE '(^|[^a-z])(no|not|never|nothing|without|only|unverified)([^a-z]|$)' <<< "$line" && continue
        if grep -qi 'arm64' <<< "$line" && ! compgen -G "$dir/*arm64*" > /dev/null; then
            printf 'arm64 claimed verified without a receipt: %s
' "$line" >&2; status=1
        fi
        if grep -qiE 'physical|nekobox|v2rayn|hiddify' <<< "$line" && ! compgen -G "$dir/*physical*" > /dev/null; then
            printf 'physical-app test claimed without a receipt: %s
' "$line" >&2; status=1
        fi
    done < <(grep -iE 'verified|passes|passed|tested' "$file" || true)
    return "$status"
}

docs_all() {
    local file status=0
    for file in "$@"; do
        docs_links "$file" || status=1
        docs_flags "$file" || status=1
        docs_claims "$file" || status=1
    done
    return "$status"
}

if [[ $selected == all || $selected == documented-lifecycle-and-links ]]; then
    assert_success 'README and the extension note have valid links, real flags and no unbacked claims' docs_all "${docs_files[@]}"

    # Each verb the README shows for xray-client is in the tool's own help.
    help=$(bash "$PROJECT_DIR/xray-client" help)
    verbs=$(grep -oE '^xray-client [a-z]+' "$PROJECT_DIR/README.md" | awk '{print $2}' | sort -u)
    for verb in $verbs; do
        assert_success "README verb '$verb' is in xray-client help" grep -q -F "xray-client $verb" <<< "$help"
    done

    # The README quickstart, replayed against a disposable root with the real commands.
    archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)
    root=$(mktemp -d "$scratch/root.XXXXXXXX")
    assert_success 'documented install with --first-client' xvk_test_install "$root" "$archive" --first-client user_01
    manager="$root/usr/local/bin/xray-client"
    bash "$manager" show user_01 > "$scratch/show"
    assert_success 'show prints a URI' grep -q '^vless://' "$scratch/show"
    assert_success 'show prints the QR heading' grep -q '^QR code:' "$scratch/show"
    assert_success 'documented add' bash "$manager" add phone
    assert_eq 'phone,user_01' "$(bash "$manager" list | LC_ALL=C sort | paste -sd ,)" 'list shows both clients'
    assert_success 'documented export' bash "$manager" export phone --output "$scratch/phone.uri"
    assert_eq 600 "$(stat -c %a "$scratch/phone.uri")" 'export file mode is 0600'
    assert_success 'documented remove' bash "$manager" remove phone
    assert_failure 'removed client is gone' bash "$manager" show phone
    assert_failure 'the removed --uri flag is rejected' bash "$manager" show user_01 --uri
    assert_success 'documented update --check on the same checkout' \
        bash "$PROJECT_DIR/update.sh" --check --root "$root" --archive "$archive"
    assert_success 'documented uninstall --keep-config' bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes --keep-config
    assert_success 'documented install --restore' \
        bash "$PROJECT_DIR/install.sh" --restore --non-interactive --no-service --root "$root" --archive "$archive"
    assert_eq user_01 "$(bash "$manager" list)" 'restore keeps the old client and adds no main-user'
    assert_success 'documented uninstall' bash "$PROJECT_DIR/uninstall.sh" --root "$root" --yes

    # The companion patch applies to the pinned AWG README and changes only that file.
    patch_file="$PROJECT_DIR/docs/companion/awg-readme-link.patch"
    assert_eq 1 "$(grep -c '^diff --git' "$patch_file")" 'patch touches one file'
    assert_success 'patch touches README.md only' grep -q '^diff --git a/README.md b/README.md$' "$patch_file"
    assert_eq 0 "$(grep -c '^-[^-]' "$patch_file")" 'patch only adds lines'
    assert_success 'patch links to this project' grep -q 'github.com/thejohnd0e/xray-vps-kit' "$patch_file"
    mkdir "$scratch/awg"
    assert_success 'pinned AWG README downloads' \
        curl --fail --silent --show-error --location --proto '=https' --max-time 60 \
            --output "$scratch/awg/README.md" "https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/$awg_pin/README.md"
    git -C "$scratch/awg" init -q
    assert_success 'patch applies to the pinned AWG README' git -C "$scratch/awg" apply --check "$patch_file"
    git -C "$scratch/awg" apply "$patch_file"
    assert_success 'patched README carries the reciprocal link' grep -q 'xray-vps-kit' "$scratch/awg/README.md"
fi

if [[ $selected == all || $selected == stale-command-and-cdn-claim ]]; then
    assert_success 'the real documentation is accepted by every check' docs_all "${docs_files[@]}"
    bad="$scratch/bad"
    mkdir -p "$bad/docs"
    cp "$PROJECT_DIR/README.md" "$bad/README.md"
    printf 'x\n' > "$bad/docs/transport-extension.md"
    negative() {
        local name=$1 check=$2 text=$3
        cp "$PROJECT_DIR/README.md" "$bad/README.md"
        printf '\n%s\n' "$text" >> "$bad/README.md"
        assert_failure "negative fixture is rejected: $name" "$check" "$bad/README.md"
    }
    negative 'nonexistent flag' docs_flags '```bash
./install.sh --cdn cloudflare
```'
    negative 'removed flag still documented' docs_flags 'Run `xray-client show NAME --uri` to print the link.'
    negative 'live CDN claim' docs_claims 'Cloudflare CDN mode is available now: enable it during install.'
    negative 'blanket compatibility claim' docs_claims 'This setup works with all clients and is undetectable.'
    negative 'private key example' docs_claims 'privateKey: 0123456789abcdefghijklmnopqrstuvwxyzABCDEFG'
    negative 'identity-like UUID' docs_claims 'Example id: 5b619b82-c3be-4c5a-9bce-0c00be17db88'
    negative 'concrete client URI' docs_claims 'vless://user@example.com:443?security=reality'
    negative 'broken link' docs_links 'See [the guide](docs/missing-guide.md).'
fi

if [[ $selected == all || $selected == evidence-claim-mismatch ]]; then
    evidence="$scratch/evidence"
    mkdir -p "$evidence"
    printf 'real receipt
' > "$evidence/task-1-happy.txt"
    : > "$evidence/empty.txt"
    printf '| 1 | `task-1-happy.txt` |
' > "$scratch/good-index.md"
    printf '| 1 | `task-1-happy.txt` |
| 2 | `task-2-happy.txt` |
' > "$scratch/missing-index.md"
    printf '| 3 | `empty.txt` |
' > "$scratch/empty-index.md"
    assert_success 'an index whose receipts exist is accepted' docs_receipts "$scratch/good-index.md" "$evidence"
    assert_failure 'a missing mandatory receipt blocks the success claim' docs_receipts "$scratch/missing-index.md" "$evidence"
    assert_failure 'an empty receipt blocks the success claim' docs_receipts "$scratch/empty-index.md" "$evidence"
    printf 'Native arm64 service smoke is verified on a real host.
' > "$scratch/claim-arm64.md"
    printf 'Hiddify import was tested on a phone.
' > "$scratch/claim-physical.md"
    printf 'Native arm64 is not tested yet; only the archive digest is checked.
' > "$scratch/limitation.md"
    assert_failure 'arm64 verified without a receipt is rejected' docs_verified_claims "$scratch/claim-arm64.md" "$evidence"
    assert_failure 'a physical-app claim without a receipt is rejected' docs_verified_claims "$scratch/claim-physical.md" "$evidence"
    assert_success 'a stated limitation is accepted' docs_verified_claims "$scratch/limitation.md" "$evidence"
    printf 'arm64 smoke receipt
' > "$evidence/task-arm64.txt"
    assert_success 'the same arm64 claim passes once its receipt exists' docs_verified_claims "$scratch/claim-arm64.md" "$evidence"
    assert_success 'the README keeps its limitations and claims nothing unreceipted'         docs_verified_claims "$PROJECT_DIR/README.md" "$scratch/no-receipts"
    # The project's own index is checked only where the (git-ignored) evidence directory exists.
    real_evidence="$PROJECT_DIR/.omo/evidence/xray-companion-kit"
    if [[ -f $real_evidence/index.md ]]; then
        assert_success 'every receipt in the real evidence index exists' docs_receipts "$real_evidence/index.md" "$real_evidence"
    else
        printf '# real evidence index not present in this checkout; synthetic cases only
'
    fi
fi
