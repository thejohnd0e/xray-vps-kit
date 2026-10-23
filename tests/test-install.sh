#!/usr/bin/env bash
case "${1:-all}" in
    all|dependencies|sandbox-and-restore|preflight-and-start-failure|interactive-defaults-and-overrides|cancellation-and-noninteractive-errors) selected=${1:-all} ;;
    *) printf 'Unknown install case\n' >&2; exit 1 ;;
esac
[[ -f $PROJECT_DIR/install.sh ]] || { printf 'FAIL: installer not implemented\n' >&2; exit 1; }
if [[ $selected == all || $selected == dependencies ]]; then
    assert_success 'dependency bootstrap handles missing tools, progress and failures safely' \
        bash "$TESTS_DIR/helpers/test-dependencies.sh"
    [[ $selected != dependencies ]] || return 0
fi
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin"
export XVK_PROBE_TRACE="$scratch/probes" XVK_TEST_BUSY=false XVK_TEST_TARGET_OK=true XVK_TEST_FAIL_INSTALL=false
cat > "$scratch/bin/openssl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 != s_client ]]; then exec /usr/bin/openssl "$@"; fi
printf 'openssl' >> "$XVK_PROBE_TRACE"
printf ' %s' "$@" >> "$XVK_PROBE_TRACE"
printf '\n' >> "$XVK_PROBE_TRACE"
[[ $XVK_TEST_TARGET_OK == true ]] || exit 1
printf 'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nALPN protocol: h2\nVerify return code: 0 (ok)\n'
STUB
cat > "$scratch/bin/ss" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ss %s\n' "$*" >> "$XVK_PROBE_TRACE"
if [[ $XVK_TEST_BUSY == true ]]; then printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; fi
STUB
chmod 755 "$scratch/bin/openssl" "$scratch/bin/ss"
cat > "$scratch/bin/install" <<'STUB'
#!/usr/bin/env bash
if [[ $XVK_TEST_FAIL_INSTALL == true && ${*: -1} == */etc/xray-vps-kit/config.json ]]; then exit 17; fi
exec /usr/bin/install "$@"
STUB
chmod 755 "$scratch/bin/install"
export PATH="$scratch/bin:$PATH"
archive=$(bash "$TESTS_DIR/download-core.sh" --arch amd64)

if [[ $selected == all || $selected == sandbox-and-restore ]]; then
    root=$(mktemp -d "$scratch/root.XXXXXXXX")
    assert_success 'sandbox generates validated install without host service operations' \
        bash "$PROJECT_DIR/install.sh" --non-interactive --no-service --root "$root" --endpoint 203.0.113.7 --archive "$archive"
    assert_eq main-user "$(jq -r '.clients[0].name' "$root/etc/xray-vps-kit/state.json")" 'default first client is main-user'
    assert_eq 443 "$(jq -r .port "$root/etc/xray-vps-kit/state.json")" 'default local TCP port'
    assert_eq github.com:443 "$(jq -r .target "$root/etc/xray-vps-kit/state.json")" 'implicit target uses443'
    assert_eq 600 "$(stat -c %a "$root/etc/xray-vps-kit/state.json")" 'private state permissions'
    assert_eq 640 "$(stat -c %a "$root/etc/xray-vps-kit/config.json")" 'service config permissions'
    assert_success 'installed manager resolves without source checkout' bash "$root/usr/local/bin/xray-client" version
    assert_failure 'repeat ordinary install refuses state' \
        bash "$PROJECT_DIR/install.sh" --non-interactive --no-service --root "$root" --endpoint 203.0.113.7 --archive "$archive"
    root_empty=$(mktemp -d "$scratch/root.XXXXXXXX")
    assert_success 'explicit no-first-client creates no identities' \
        bash "$PROJECT_DIR/install.sh" --non-interactive --no-service --root "$root_empty" --endpoint 203.0.113.7 --no-first-client --port 8443 --archive "$archive"
    assert_eq 0 "$(jq '.clients|length' "$root_empty/etc/xray-vps-kit/state.json")" 'no client accidentally created'
    assert_eq github.com:443 "$(jq -r .target "$root_empty/etc/xray-vps-kit/state.json")" 'local8443 still targets443'
    before=$(jq -c 'del(.generation,.installed,.lastSuccessfulSnapshot)' "$root_empty/etc/xray-vps-kit/state.json")
    # Simulate runtime removal while retaining kit-generated private metadata.
    rm "$root_empty/usr/local/bin/xray-client" "$root_empty/etc/systemd/system/xray-vps-kit.service" "$root_empty/opt/xray-vps-kit/current"
    rm -rf -- "$root_empty/opt/xray-vps-kit/releases"
    assert_success 'explicit restore reuses retained settings and keys' bash "$PROJECT_DIR/install.sh" --non-interactive --no-service --root "$root_empty" --restore --archive "$archive"
    assert_eq "$before" "$(jq -c 'del(.generation,.installed,.lastSuccessfulSnapshot)' "$root_empty/etc/xray-vps-kit/state.json")" 'restore preserves all identities and never creates main-user'
    before=$(sha256sum "$root_empty/etc/xray-vps-kit/state.json")
    rm "$root_empty/usr/local/bin/xray-client" "$root_empty/opt/xray-vps-kit/current"
    printf 'foreign unit\n' > "$root_empty/etc/systemd/system/xray-vps-kit.service"
    assert_failure 'restore refuses a foreign/replaced runtime unit' bash "$PROJECT_DIR/install.sh" --non-interactive --no-service --root "$root_empty" --restore --archive "$archive"
    assert_eq 'foreign unit' "$(cat "$root_empty/etc/systemd/system/xray-vps-kit.service")" 'foreign runtime unit preserved'
    assert_eq "$before" "$(sha256sum "$root_empty/etc/xray-vps-kit/state.json")" 'runtime conflict does not overwrite preserved identities'
fi
if [[ $selected == all || $selected == preflight-and-start-failure || $selected == cancellation-and-noninteractive-errors ]]; then
    assert_success 'help is noninteractive' bash "$PROJECT_DIR/install.sh" --help
    assert_failure 'non-TTY without explicit automation refuses before reads' timeout 3 bash "$PROJECT_DIR/install.sh"
    for args in '--port' '--port 0' '--port 65536' '--server-name bad/host' '--first-client ../bad' '--first-client x --no-first-client' '--root / --no-service' '--restore --port 443' '--unknown'; do
        # This fixed test matrix deliberately splits words, never evals them.
        read -r -a arguments <<< "$args"
        assert_failure 'malformed flags fail before mutation' bash "$PROJECT_DIR/install.sh" --non-interactive "${arguments[@]}"
    done
    root=$(mktemp -d "$scratch/refused.XXXXXXXX")
    export XVK_TEST_BUSY=true
    assert_failure 'occupied TCP port refuses sandbox before writes' bash "$PROJECT_DIR/install.sh" --non-interactive --no-service --root "$root" --endpoint 203.0.113.7 --archive "$archive"
    export XVK_TEST_BUSY=false XVK_TEST_TARGET_OK=false
    assert_failure 'bad verified target refuses before writes' bash "$PROJECT_DIR/install.sh" --non-interactive --no-service --root "$root" --endpoint 203.0.113.7 --archive "$archive"
    assert_eq '' "$(find "$root" -mindepth 1 -print -quit)" 'failed preflight leaves root empty'
    export XVK_TEST_TARGET_OK=true
    assert_success 'real TLS probe enforces hostname and CA validation' env PATH="${PATH#"$scratch/bin:"}" \
        bash "$TESTS_DIR/helpers/test-target-probe.sh"
    assert_success 'real UDP-only port is allowed and real TCP listener conflicts' env PATH="${PATH#"$scratch/bin:"}" \
        python3 "$TESTS_DIR/helpers/test-port-preflight.py" "$PROJECT_DIR"
    export XVK_TEST_FAIL_INSTALL=true
    assert_failure 'partial file installation returns nonzero' bash "$PROJECT_DIR/install.sh" --non-interactive --no-service --root "$root" --endpoint 203.0.113.7 --archive "$archive"
    assert_failure 'failed fresh activation retains no credential state' test -e "$root/etc/xray-vps-kit/state.json"
    export XVK_TEST_FAIL_INSTALL=false
    # Read-only system identity adapter: exercise the complete retained-account
    # contract without creating/changing an account in the everyday WSL distro.
    (
        # shellcheck source=lib/common.sh
        source "$PROJECT_DIR/lib/common.sh"
        # shellcheck source=lib/service.sh
        source "$PROJECT_DIR/lib/service.sh"
        fixture_account='xray-vps-kit:x:994:994:xray-vps-kit managed service account:/nonexistent:/usr/sbin/nologin'
        fixture_group='xray-vps-kit:x:994:'
        fixture_memberships=994
        getent() {
            case $1 in passwd) printf '%s\n' "$fixture_account" ;; group) printf '%s\n' "$fixture_group" ;; *) return 2 ;; esac
        }
        id() { printf '%s\n' "$fixture_memberships"; }
        xvk_service_account_check
        fixture_account='xray-vps-kit:x:994:994:foreign owner:/nonexistent:/usr/sbin/nologin'
        if xvk_service_account_check; then exit 1; fi
        fixture_account='xray-vps-kit:x:994:994:xray-vps-kit managed service account:/nonexistent:/usr/sbin/nologin'
        fixture_memberships='994 995'
        if xvk_service_account_check; then exit 1; fi
    )
    assert_success 'retained-account fixture completed all positive/negative checks' true
    # A changed rule retaining our comment is no longer ours to delete.
    # Exercise the status/deletion adapter on a file-backed ruleset, not host UFW.
    {
        # shellcheck source=lib/firewall.sh
        source "$PROJECT_DIR/lib/firewall.sh"
        fixture_ufw_rows="$scratch/ufw-rows"
        # Invoked indirectly by the sourced firewall adapter.
        # shellcheck disable=SC2317
        ufw() {
            if [[ $1 == status ]]; then cat "$fixture_ufw_rows"; return; fi
            if [[ $1 == --force && $2 == delete ]]; then : > "$fixture_ufw_rows"; return; fi
            return 1
        }
        record='{"backend":"ufw","marker":"xray-vps-kit-0123456789abcdef","port":443}'
        printf '[ 1] 4443/tcp ALLOW IN Anywhere # xray-vps-kit-0123456789abcdef\n' > "$fixture_ufw_rows"
        assert_failure 'owned comment with changed port is not deleted' xvk_firewall_remove "$record"
        assert_success 'foreign changed-port rule remains intact' test -s "$fixture_ufw_rows"
        printf '[ 1] 443/tcp ALLOW IN 192.0.2.1 # xray-vps-kit-0123456789abcdef\n' > "$fixture_ufw_rows"
        assert_failure 'owned comment with changed source is not deleted' xvk_firewall_remove "$record"
        assert_success 'foreign changed-source rule remains intact' test -s "$fixture_ufw_rows"
        unset -f ufw
    }
    {
        # Callbacks receive the normalized prefix from transaction.sh: the
        # production '/' becomes an empty prefix, not a sandbox marker.
        # shellcheck source=lib/service.sh
        source "$PROJECT_DIR/lib/service.sh"
        # shellcheck source=tests/helpers/state-fixture.sh
        source "$TESTS_DIR/helpers/state-fixture.sh"
        mkdir -p "$scratch/hook-stage/etc/xray-vps-kit"
        write_state_fixture "$scratch/hook-stage/etc/xray-vps-kit/state.json"
        fixture_service_state="$scratch/service-restarted"
        # Invoked indirectly by the production service callback.
        # shellcheck disable=SC2317
        systemctl() {
            case "$*" in
                daemon-reload) return 0 ;;
                'restart xray-vps-kit.service') printf 'restarted\n' > "$fixture_service_state" ;;
                *) return 1 ;;
            esac
        }
        xvk_service_hook activate "$scratch/hook-stage" ''
        assert_success 'normalized empty production prefix must restart service' test -s "$fixture_service_state"
        rm "$fixture_service_state"
        xvk_service_hook activate "$scratch/hook-stage" /sandbox
        assert_failure 'sandbox callback never restarts a host service' test -e "$fixture_service_state"
        unset -f systemctl
    }
fi
if [[ $selected == all || $selected == interactive-defaults-and-overrides || $selected == cancellation-and-noninteractive-errors ]]; then
    assert_success 'real PTY tests prompts, defaults, overrides, cancellation and EOF' \
        python3 "$TESTS_DIR/helpers/install-pty.py" "$PROJECT_DIR" "$scratch" "$archive" "$selected"
fi
