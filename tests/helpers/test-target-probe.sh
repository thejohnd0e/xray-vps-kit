#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
# shellcheck source=lib/preflight.sh
source "$project/lib/preflight.sh"
scratch=$(mktemp -d)
server=''
cleanup() {
    if [[ -n $server ]]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$scratch/key" -out "$scratch/cert" \
    -subj /CN=github.com -addext subjectAltName=DNS:github.com > /dev/null 2>&1
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
mkfifo "$scratch/ready"
openssl s_server -accept "127.0.0.1:$port" -www -tls1_3 -alpn h2 -cert "$scratch/cert" -key "$scratch/key" \
    > "$scratch/ready" 2> "$scratch/server-errors" &
server=$!
exec {readiness}<"$scratch/ready"
while IFS= read -r -t 15 line <&"$readiness"; do
    [[ $line != ACCEPT ]] || break
done
[[ ${line:-} == ACCEPT ]] || { printf 'TLS fixture never reached ACCEPT\n' >&2; exit 1; }
SSL_CERT_FILE="$scratch/cert" xvk_probe_target "127.0.0.1:$port" github.com
if SSL_CERT_FILE="$scratch/cert" xvk_probe_target "127.0.0.1:$port" wrong.example > /dev/null 2>&1; then
    printf 'Hostname verification was bypassed\n' >&2; exit 1
fi
if SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt xvk_probe_target "127.0.0.1:$port" github.com > /dev/null 2>&1; then
    printf 'Untrusted test certificate was accepted\n' >&2; exit 1
fi
printf 'Real TLS1.3+h2 trusted target passes; bad hostname and untrusted CA fail.\n'
