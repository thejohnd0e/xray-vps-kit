#!/usr/bin/env bash
# Drive the real kit lifecycle (systemd, UFW, reboot) in a disposable guest.
#
#   bash tests/run-vm.sh --os debian-12|debian-13|ubuntu-22.04|ubuntu-24.04 [--case NAME]
#   bash tests/run-vm.sh --guest USER@HOST [--case NAME]     # an existing disposable guest
#
# Cases: lifecycle-coexistence, selected-tcp-port-opened, occupied-port-and-rollback, all.
# --os boots an official cloud image under QEMU (KVM when present, else TCG) with a
# loopback-only SSH forward; the guest and its scratch disk are destroyed on exit.
# --guest uses a machine you provide (password only through XVK_VM_PASSWORD, never
# stored). Never point either mode at a production host: the cases enable UFW,
# reboot the guest and remove services.
# Guards with explicit error paths, remote-expanded quotes and the EXIT trap are intentional.
# shellcheck disable=SC2015,SC2016,SC2317
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cache="$project/.omo/cache/images"
os='' guest='' selected=lifecycle-coexistence
usage() { printf 'Usage: bash tests/run-vm.sh (--os OS | --guest USER@HOST) [--case NAME]\n'; }
while (( $# )); do
    case $1 in
        --os|--guest|--case)
            (( $# >= 2 )) && [[ $2 != --* ]] || { usage >&2; exit 1; }
            case $1 in --os) os=$2 ;; --guest) guest=$2 ;; --case) selected=$2 ;; esac
            shift 2 ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
[[ -n $os || -n $guest ]] && [[ -z $os || -z $guest ]] || { usage >&2; exit 1; }
case $selected in
    lifecycle-coexistence|selected-tcp-port-opened|occupied-port-and-rollback|all) ;;
    *) printf 'Unknown VM case\n' >&2; exit 1 ;;
esac
case $os in ''|debian-12|debian-13|ubuntu-22.04|ubuntu-24.04) ;; *) printf 'Unsupported guest OS\n' >&2; exit 1 ;; esac

scratch=$(mktemp -d /tmp/xvk-vm.XXXXXXXX)
qemu_pid=''
cleanup() {
    if [[ -n $qemu_pid ]]; then kill "$qemu_pid" 2> /dev/null || true; wait "$qemu_pid" 2> /dev/null || true; fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

# ------------------------------------------------------------- guest access --

ssh_base=(-o StrictHostKeyChecking=accept-new "-o" "UserKnownHostsFile=$scratch/known_hosts" -o LogLevel=ERROR -o ConnectTimeout=20)
ssh_prefix=()
as_root=''
target=''
setup_guest_access() {
    if [[ -n $guest ]]; then
        target=$guest
        if [[ -n ${XVK_VM_PASSWORD:-} ]]; then
            command -v sshpass > /dev/null || { printf 'sshpass is required with XVK_VM_PASSWORD\n' >&2; exit 1; }
            export SSHPASS=$XVK_VM_PASSWORD
            ssh_prefix=(sshpass -e)
        else
            ssh_base+=(-o BatchMode=yes)
        fi
        [[ ${guest%%@*} == root ]] || as_root=sudo
    fi
}
gssh() { "${ssh_prefix[@]}" ssh "${ssh_base[@]}" -p "${ssh_port:-22}" "$target" "$@"; }

# ------------------------------------------------------------------- QEMU ----

vm_image_spec() {
    case $1 in
        debian-12) printf '%s\n' https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 \
            https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS sha512sum debian-12-genericcloud-amd64.qcow2 ;;
        debian-13) printf '%s\n' https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 \
            https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS sha512sum debian-13-genericcloud-amd64.qcow2 ;;
        ubuntu-22.04) printf '%s\n' https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img \
            https://cloud-images.ubuntu.com/releases/jammy/release/SHA256SUMS sha256sum ubuntu-22.04-server-cloudimg-amd64.img ;;
        ubuntu-24.04) printf '%s\n' https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img \
            https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS sha256sum ubuntu-24.04-server-cloudimg-amd64.img ;;
    esac
}

# The checksum list comes from the official host over HTTPS; the image is used only
# after it verifies against that list.
ensure_image() {
    local spec url sums_url algorithm file expected image
    mapfile -t spec < <(vm_image_spec "$os")
    url=${spec[0]} sums_url=${spec[1]} algorithm=${spec[2]} file=${spec[3]}
    mkdir -p "$cache"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 \
        --max-time 60 --output "$scratch/sums" "$sums_url"
    expected=$(grep -E "[ *]${file//./\\.}\$" "$scratch/sums" | awk '{print $1}')
    [[ $expected =~ ^[a-f0-9]{64,128}$ ]] || { printf 'No official checksum found for %s\n' "$file" >&2; exit 1; }
    image="$cache/$os-$expected.img"
    if [[ ! -f $image ]]; then
        curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 1800 \
            --output "$image.partial" "$url"
        printf '%s  %s\n' "$expected" "$image.partial" | "$algorithm" -c - > /dev/null
        mv "$image.partial" "$image"
    fi
    printf '%s  %s\n' "$expected" "$image" | "$algorithm" -c - > /dev/null
    printf '%s\n' "$image"
}

qemu_tooling() {
    command -v qemu-system-x86_64 > /dev/null && command -v genisoimage > /dev/null && return 0
    local runtime="$scratch/qemu" package
    mkdir -p "$runtime"
    for package in "$project"/.omo/cache/qemu-debs/*.deb; do dpkg-deb -x "$package" "$runtime"; done
    export PATH="$runtime/usr/bin:$PATH"
    export LD_LIBRARY_PATH="$runtime/lib/x86_64-linux-gnu:$runtime/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export QEMU_MODULE_DIR="$runtime/usr/lib/x86_64-linux-gnu/qemu" QEMU_AUDIO_DRV=none
    qemu_data="$runtime/usr/share/qemu" qemu_bios="$runtime/usr/share/seabios/bios-256k.bin"
}

boot_qemu_guest() {
    local image public_key accel=(-accel "tcg,thread=multi" -cpu max)
    qemu_tooling
    image=$(ensure_image)
    cp -- "$image" "$scratch/base.img"
    (umask 077; ssh-keygen -q -t ed25519 -N '' -f "$scratch/key")
    public_key=$(cat "$scratch/key.pub")
    cat > "$scratch/user-data" <<CLOUD
#cloud-config
ssh_pwauth: false
disable_root: true
users:
  - name: xvkqa
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $public_key
package_update: true
packages: [curl, ca-certificates, openssl, iproute2, jq, nftables, iptables, unzip, qrencode, util-linux, ufw, python3]
runcmd:
  - [ bash, -c, "{ echo XVK_READY; } > /dev/ttyS0 2>&1" ]
CLOUD
    printf 'instance-id: xvk-vm-%s\nlocal-hostname: xvk-vm\n' "${scratch##*.}" > "$scratch/meta-data"
    genisoimage -quiet -output "$scratch/seed.iso" -volid cidata -joliet -rock "$scratch/user-data" "$scratch/meta-data"
    qemu-img create -q -f qcow2 -F qcow2 -b "$scratch/base.img" "$scratch/disk.qcow2" 8G
    ssh_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    if [[ -e /dev/kvm && -w /dev/kvm ]]; then accel=(-accel kvm -cpu host); fi
    : > "$scratch/serial.log"
    local bios_args=()
    [[ -z ${qemu_data:-} ]] || bios_args=(-L "$qemu_data" -bios "$qemu_bios")
    qemu-system-x86_64 "${bios_args[@]}" -machine q35 "${accel[@]}" -smp 2 -m 2048 -display none -vga none -monitor none \
        -serial "file:$scratch/serial.log" -drive "file=$scratch/disk.qcow2,format=qcow2,if=virtio" \
        -drive "file=$scratch/seed.iso,format=raw,if=virtio,readonly=on" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$ssh_port-:22" -device virtio-net-pci,netdev=n0,romfile= &
    qemu_pid=$!
    target=xvkqa@127.0.0.1
    as_root=sudo
    ssh_base+=(-i "$scratch/key" -o BatchMode=yes)
    wait_for_guest 1500
    gssh 'sudo cloud-init status --wait > /dev/null'
}

# ------------------------------------------------------------ guest control --

wait_for_guest() {
    local limit=${1:-300} deadline=$((SECONDS + ${1:-300}))
    while (( SECONDS < deadline )); do
        if gssh true 2> /dev/null; then return 0; fi
        # Bounded readiness poll of an external guest.
        sleep 5
    done
    printf 'Guest did not become reachable within %ss\n' "$limit" >&2
    [[ ! -s $scratch/serial.log ]] || tail -n 40 "$scratch/serial.log" >&2
    return 1
}

push_tree() {
    local archive
    archive=$(bash "$project/tests/download-core.sh" --arch amd64)
    tar -C "$project" -cf "$scratch/source.tar" install.sh uninstall.sh update.sh xray-client VERSION lib templates releases tests/helpers tests/vm
    gssh 'rm -rf ~/xvk-vm && mkdir -p ~/xvk-vm && tar -xf - -C ~/xvk-vm' < "$scratch/source.tar"
    gssh 'cat > ~/xvk-core.zip' < "$archive"
}

guest_run() {
    local case_name=$1 phase=$2 home
    home=$(gssh 'printf %s "$HOME"')
    gssh "$as_root env XVK_ARCHIVE=$home/xvk-core.zip bash $home/xvk-vm/tests/vm/guest-runner.sh $case_name $phase"
}

guest_reboot() {
    local before
    before=$(gssh 'cat /proc/sys/kernel/random/boot_id')
    gssh "$as_root systemctl reboot" 2> /dev/null || true
    sleep 15
    wait_for_guest 600
    [[ $(gssh 'cat /proc/sys/kernel/random/boot_id') != "$before" ]] || { printf 'Guest did not reboot\n' >&2; return 1; }
}

run_case() {
    local name=$1 status=0
    printf '== case: %s\n' "$name"
    case $name in
        lifecycle-coexistence)
            guest_run "$name" a || status=$?
            if (( status == 0 )); then
                guest_reboot
                guest_run "$name" b || status=$?
            fi ;;
        *) guest_run "$name" run || status=$? ;;
    esac
    return "$status"
}

setup_guest_access
[[ -z $os ]] || boot_qemu_guest
wait_for_guest 120
printf 'Guest: %s\n' "$(gssh '. /etc/os-release; printf "%s, %s" "$PRETTY_NAME" "$(uname -r)"')"
push_tree
overall=0
if [[ $selected == all ]]; then
    for name in lifecycle-coexistence selected-tcp-port-opened occupied-port-and-rollback; do
        run_case "$name" || overall=1
    done
else
    run_case "$selected" || overall=1
fi
exit "$overall"
