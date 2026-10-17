#!/usr/bin/env bash
# Read-only network probes are deterministic; real core cryptography/config
# validation and all filesystem installation code still execute normally.
xvk_test_probe_path() {
    local scratch=$1
    mkdir -p "$scratch/probe-bin"
    export XVK_PROBE_TRACE="$scratch/probes" XVK_TEST_BUSY=false XVK_TEST_TARGET_OK=true
    cat > "$scratch/probe-bin/openssl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 != s_client ]]; then exec /usr/bin/openssl "$@"; fi
printf 'openssl' >> "$XVK_PROBE_TRACE"
printf ' %s' "$@" >> "$XVK_PROBE_TRACE"
printf '\n' >> "$XVK_PROBE_TRACE"
[[ $XVK_TEST_TARGET_OK == true ]] || exit 1
printf 'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nALPN protocol: h2\nVerify return code: 0 (ok)\n'
STUB
    cat > "$scratch/probe-bin/ss" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ss %s\n' "$*" >> "$XVK_PROBE_TRACE"
if [[ $XVK_TEST_BUSY == true ]]; then printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; fi
STUB
    chmod 755 "$scratch/probe-bin/openssl" "$scratch/probe-bin/ss"
    export PATH="$scratch/probe-bin:$PATH"
}

xvk_test_install() {
    local root=$1 archive=$2
    shift 2
    bash "$PROJECT_DIR/install.sh" --non-interactive --no-service --root "$root" --endpoint 203.0.113.7 --archive "$archive" "$@"
}
