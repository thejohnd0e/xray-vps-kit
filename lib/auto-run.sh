#!/usr/bin/env bash

xvk_auto_report_locked() (
    set -euo pipefail
    local root=${1%/} outcome=$2 installed=$3 latest=$4 data json='' log='' timestamp
    # An uninstall may have won the lock while the network request was in flight.
    # Reporting must never recreate removed resources.
    xvk_auto_present "$root" || exit 0
    xvk_auto_verify "$root" || exit 1
    data="$root/var/lib/xray-vps-kit-auto-update"
    json=$(xvk_private_temp "$data") || exit 1
    log=$(xvk_private_temp "$data") || { rm -f "$json"; exit 1; }
    trap 'rm -f -- "$json" "$log"' EXIT
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ) || exit 1
    jq -n --arg timestamp "$timestamp" --arg outcome "$outcome" --arg installed "$installed" --arg latest "$latest" \
        '{schemaVersion:1,timestamp:$timestamp,outcome:$outcome,
          installedVersion:(if $installed=="" then null else $installed end),
          latestVersion:(if $latest=="" then null else $latest end)}' > "$json" || exit 1
    printf '%s outcome=%s installed=%s latest=%s\n' "$timestamp" "$outcome" "${installed:-unknown}" "${latest:-unknown}" > "$log" || exit 1
    mv -fT "$log" "$data/last-run.log" && mv -fT "$json" "$data/last-run.json" || exit 1
)

xvk_auto_report() {
    local root=${1%/} outcome=$2 installed=${3:-} latest=${4:-}
    printf '[Automatic updates] %s; installed=%s; latest=%s\n' "$outcome" "${installed:-unknown}" "${latest:-unknown}"
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_auto_report_locked "$root" "$outcome" "$installed" "$latest"
}

xvk_auto_run_once() (
    set -euo pipefail
    local root=${1%/} action=$2 hook=$3 temporary installed latest='' base prepared_base archive status=0 scheduled=false
    temporary=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$temporary"' EXIT
    installed=$(jq -r .installed.coreVersion "$root/etc/xray-vps-kit/state.json") || exit 1
    base=$(jq -r .installed.bundleId "$root/etc/xray-vps-kit/state.json") || exit 1
    [[ $action != scheduled ]] || scheduled=true
    fail_check() {
        xvk_error "$1"
        xvk_auto_report "$root" error "$installed" "$latest" || xvk_error 'Could not record the automatic-update error'
        exit 1
    }
    if ! xvk_auto_fetch_release "$temporary/release.json"; then fail_check 'Official release query failed; running core unchanged'; fi
    if ! xvk_auto_release_lock "$temporary/release.json" "$temporary/lock.json"; then fail_check 'Official release metadata rejected; running core unchanged'; fi
    latest=$(jq -r .version "$temporary/lock.json") || fail_check 'Cannot read resolved core version'
    if ! xvk_update_version_lt "${installed#v}" "${latest#v}"; then
        xvk_auto_report "$root" current "$installed" "$latest" || exit 1
        exit 0
    fi
    if [[ $scheduled == true ]] && ! xvk_auto_eligible "$root"; then
        xvk_auto_report "$root" skipped "$installed" "$latest" || exit 1
        exit 0
    fi
    mkdir "$temporary/cache" "$temporary/candidate" || fail_check 'Cannot create private update stage'
    if ! archive=$(xvk_release_acquire "$temporary/lock.json" "$XVK_ARCH" "$temporary/cache" 134217728); then fail_check 'Official core acquisition/checksum failed; running core unchanged'; fi
    if ! prepared_base=$(xvk_core_candidate "$root" "$temporary/lock.json" "$archive" "$temporary/candidate"); then
        fail_check 'Cannot build a verified core-only candidate; running core unchanged'
    fi
    if [[ $prepared_base != "$base" ]]; then
        xvk_auto_report "$root" skipped "$installed" "$latest" || exit 1
        exit 0
    fi
    xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_core_apply_locked \
        "$root" "$temporary/candidate" "$base" "$scheduled" "$hook" || status=$?
    case $status in
        0) xvk_auto_report "$root" updated "$latest" "$latest" || exit 1 ;;
        75) xvk_auto_report "$root" skipped "$installed" "$latest" || exit 1 ;;
        *) fail_check 'Core update failed; inspect local service and rollback diagnostics' ;;
    esac
)

xvk_auto_run() {
    local project=$1 root=${2%/} action=$3 hook=${4:-xvk_core_service_hook}
    if [[ $action == scheduled ]]; then
        if ! xvk_auto_present "$root"; then printf '[Automatic updates] Scheduled updates are unconfigured.\n'; return 0; fi
        xvk_auto_verify "$root" || { xvk_error 'Automatic-update resources have drifted'; return 1; }
        if ! xvk_auto_eligible "$root"; then
            printf '[Automatic updates] Scheduled updates are disabled or paused.\n'
            return 0
        fi
    fi
    xvk_require_commands jq curl unzip zipinfo openssl flock sha256sum sort realpath timeout || return 1
    xvk_update_require_install "$root" || {
        xvk_error 'Automatic updates require an existing intact runtime; nothing will be recreated'; return 1;
    }
    if ! xvk_auto_present "$root"; then
        # Explicit one-shot use may install reporting/worker files, but never
        # installs packages, enables cron or silently opts into scheduling.
        xvk_with_lock "$root/run/lock/xray-vps-kit.lock" xvk_auto_install_locked "$project" "$root" disabled || return 1
    fi
    xvk_auto_verify "$root" || { xvk_error 'Automatic-update resources have drifted'; return 1; }
    xvk_with_lock "$root/run/lock/xray-vps-kit-auto-update.lock" xvk_auto_run_once "$root" "$action" "$hook"
}
