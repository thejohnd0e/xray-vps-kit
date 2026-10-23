#!/usr/bin/env bash

xvk_install_locked() (
    set -euo pipefail
    local project=$1 root=${XVK_ROOT%/} cfg archive temporary digest kit core_version bundle keys client rule=null applied=false
    local opened writes_started=false bundle_written=false runtime_written=false committed=false status recovery_failed=false
    cfg="$root/etc/xray-vps-kit"
    local controlled
    for controlled in "$cfg" "$root/opt/xray-vps-kit/releases" "$root/usr/local/bin/xray-client" "$root/etc/systemd/system/xray-vps-kit.service"; do
        xvk_no_symlink_path "$controlled" || { xvk_error 'Symlink in installation paths'; exit 1; }
    done
    xvk_port_free "$XVK_PORT" || { xvk_error 'TCP port became occupied'; exit 1; }
    for controlled in "$root/usr/local/bin/xray" "$root/usr/local/bin/xray-client" "$root/opt/xray-vps-kit/current" "$root/etc/systemd/system/xray-vps-kit.service"; do
        [[ ! -e $controlled && ! -L $controlled ]] || { xvk_error 'Existing runtime resource conflicts with install/restore'; exit 1; }
    done
    if [[ $XVK_RESTORE == true ]]; then
        xvk_preserved_verify "${root:-/}" || { xvk_error 'Invalid preserved ownership or configuration'; exit 1; }
    else
        [[ ! -e $cfg ]] || { xvk_error 'State appeared during preflight'; exit 1; }
    fi
    if [[ $XVK_SANDBOX != true ]]; then
        xvk_service_account_check || exit 1
        xvk_service_account_create || exit 1
    fi
    xvk_require_commands jq curl unzip zipinfo openssl qrencode flock || exit 1
    if [[ $XVK_RESTORE == true ]]; then
        temporary=$(mktemp -d "$cfg/.restore.XXXXXXXX") || exit 1
    else
        temporary=$(mktemp -d) || exit 1
    fi
    # Scratch always removed. Runtime resources are removed only if this fresh
    # install created them and a later activation failed.
    trap 'status=$?; if [[ $committed != true && $writes_started == true ]]; then xvk_install_rollback "$root" "$temporary" "$bundle" || recovery_failed=true; fi; if [[ $recovery_failed == true ]]; then xvk_error "Rollback incomplete; private recovery files retained at $temporary"; else rm -rf -- "$temporary"; fi; if (( status != 0 )) && [[ $XVK_SANDBOX != true ]]; then xvk_error "Installation failed; installed packages and any dedicated account are retained"; fi; exit "$status"' EXIT
    mkdir "$temporary/bundle" || exit 1
    archive=$XVK_ARCHIVE
    if [[ -z $archive ]]; then
        mkdir "$temporary/cache" || exit 1
        archive=$(xvk_release_acquire "$project/releases/xray.lock.json" "$XVK_ARCH" "$temporary/cache") || exit 1
    fi
    digest=$(xvk_bundle_build "$project" "$archive" "$temporary/bundle") || exit 1
    kit=$(cat "$project/VERSION")
    core_version=$(jq -r .version "$project/releases/xray.lock.json")
    bundle="$kit-$core_version-$digest"
    if [[ $XVK_RESTORE == true ]]; then
        mkdir "$temporary/preserved" || exit 1
        cp -p "$cfg/state.json" "$cfg/config.json" "$cfg/ownership.json" "$temporary/preserved/" || exit 1
        jq --arg kit "$kit" --arg core "$core_version" --arg bundle "$bundle" --arg sha "$digest" \
            '.generation+=1 | .lastSuccessfulSnapshot=null | .installed={kitVersion:$kit,coreVersion:$core,bundleId:$bundle,contentSha256:$sha}' \
            "$cfg/state.json" > "$temporary/state.json" || exit 1
    else
        keys=$(xvk_new_keys "$temporary/bundle/xray") || exit 1
        jq -n --arg endpoint "$XVK_ENDPOINT" --argjson port "$XVK_PORT" --arg sni "$XVK_SNI" --arg target "$XVK_TARGET" \
            --argjson keys "$keys" --arg kit "$kit" --arg core "$core_version" --arg bundle "$bundle" --arg sha "$digest" \
            '{schemaVersion:1,generation:1,transport:"reality-tcp",endpoint:$endpoint,port:$port,target:$target,serverName:$sni,
            privateKey:$keys.privateKey,publicKey:$keys.publicKey,clients:[],installed:{kitVersion:$kit,coreVersion:$core,bundleId:$bundle,contentSha256:$sha},lastSuccessfulSnapshot:null}' \
            > "$temporary/state.json" || exit 1
        chmod 600 "$temporary/state.json" || exit 1
        if [[ $XVK_NO_FIRST != true ]]; then
            client=$(xvk_new_identity "$temporary/bundle/xray" "$XVK_FIRST" "$temporary/state.json") || exit 1
            jq --argjson client "$client" '.clients=[$client]' "$temporary/state.json" > "$temporary/initial-state" || exit 1
            mv "$temporary/initial-state" "$temporary/state.json" || exit 1
        fi
    fi
    chmod 600 "$temporary/state.json" || exit 1
    xvk_render_server "$temporary/state.json" > "$temporary/config.json" || exit 1
    "$temporary/bundle/xray" run -test -config "$temporary/config.json" > /dev/null 2>&1 || { xvk_error 'Candidate core rejected generated config'; exit 1; }
    mkdir -p "$temporary/usr/local/bin" "$temporary/etc/systemd/system" || exit 1
    printf '#!/usr/bin/env bash\nexec /bin/bash %q "$@"\n' "$root/opt/xray-vps-kit/current/xray-client" > "$temporary/usr/local/bin/xray-client" || exit 1
    cp "$project/templates/xray-vps-kit.service" "$temporary/etc/systemd/system/xray-vps-kit.service" || exit 1
    writes_started=true
    mkdir -p "$cfg" "$root/opt/xray-vps-kit/releases" "$root/usr/local/bin" "$root/etc/systemd/system" || exit 1
    chmod 750 "$cfg" || exit 1
    [[ ! -e $root/opt/xray-vps-kit/releases/$bundle && ! -L $root/opt/xray-vps-kit/releases/$bundle ]] || { xvk_error 'Bundle path already exists'; exit 1; }
    # Read by the dynamically scoped rollback callback.
    # shellcheck disable=SC2034
    bundle_written=true
    cp -a "$temporary/bundle" "$root/opt/xray-vps-kit/releases/$bundle" || exit 1
    install -m 600 "$temporary/state.json" "$cfg/state.json" || exit 1
    install -m 640 "$temporary/config.json" "$cfg/config.json" || exit 1
    # Read by the dynamically scoped rollback callback.
    # shellcheck disable=SC2034
    runtime_written=true
    install -m 644 "$temporary/etc/systemd/system/xray-vps-kit.service" "$root/etc/systemd/system/xray-vps-kit.service" || exit 1
    install -m 755 "$temporary/usr/local/bin/xray-client" "$root/usr/local/bin/xray-client" || exit 1
    ln -s "releases/$bundle" "$root/opt/xray-vps-kit/current" || exit 1
    xvk_core_link_create "${root:-/}" || exit 1
    if [[ $XVK_SANDBOX != true ]]; then
        chown root:xray-vps-kit "$cfg" "$cfg/config.json" || exit 1
        # Assign only after success: a failed substitution would leave rule empty and
        # make the rollback treat an empty record as a corrupt firewall record.
        opened=$(xvk_firewall_open "$XVK_PORT") || exit 1
        rule=$opened
    fi
    xvk_ownership_manifest "${root:-/}" "${root:-/}" "$rule" > "$temporary/ownership.json" || exit 1
    install -m 600 "$temporary/ownership.json" "$cfg/ownership.json" || exit 1
    if [[ $XVK_SANDBOX != true ]]; then
        if systemctl daemon-reload && systemctl enable --now xray-vps-kit.service && xvk_service_health "$XVK_PORT"; then
            applied=true
        else
            xvk_error 'Installation activation failed'
            exit 1
        fi
    fi
    if [[ $XVK_SANDBOX == true ]]; then
        printf 'Testing-only file generation succeeded; no service or firewall was activated.\n'
    elif [[ $applied == true ]]; then
        printf 'Xray-core %s installed; service active on TCP %s. Check provider firewall separately; internet reachability is not proven locally.\n' "$core_version" "$XVK_PORT"
        if [[ $XVK_RESTORE != true && $XVK_NO_FIRST != true ]]; then
            xvk_client_print_profile "${root:-/}" "$XVK_FIRST" || xvk_error "Could not print the profile; run: xray-client show $XVK_FIRST"
        fi
    fi
    committed=true
)
