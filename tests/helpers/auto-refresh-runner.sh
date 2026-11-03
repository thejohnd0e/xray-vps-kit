#!/usr/bin/env bash
# Test-only child process that performs one worker refresh with an injected
# failure. Running in its own process keeps production errexit semantics; the
# suite only inspects the resulting filesystem state.
set -euo pipefail
project=$1
root=${2%/}
mode=$3
failpoint=$4
for module in common state release render ownership transaction snapshot bundle service firewall dependencies preflight update-lifecycle auto-owned auto-release auto-lifecycle; do
    # shellcheck source=/dev/null
    source "$project/lib/$module.sh"
done
export XVK_ROOT="$root" XVK_SANDBOX=true XVK_ARCH=amd64
eval "xvk_auto_verify_real() $(declare -f xvk_auto_verify | tail -n +2)"
eval "xvk_auto_payload_remove_real() $(declare -f xvk_auto_payload_remove | tail -n +2)"
case $failpoint in
    none) ;;
    *)
        IFS=',' read -ra failpoints <<< "$failpoint"
        for point in "${failpoints[@]}"; do
            case $point in
                verify:*)
                    verify_target=${point#verify:}
                    verify_calls=0
                    xvk_auto_verify() {
                        verify_calls=$((verify_calls + 1))
                        (( verify_calls != verify_target )) || return 1
                        xvk_auto_verify_real "$@"
                    }
                    ;;
                payload-remove)
                    # Models a filesystem error during recovery cleanup.
                    xvk_auto_payload_remove() { return 1; }
                    ;;
                *)
                    printf 'unknown failpoint\n' >&2
                    exit 2
                    ;;
            esac
        done
        ;;
esac
xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_auto_install_locked "$project" "$root" "$mode"
