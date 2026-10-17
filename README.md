# Xray VPS Kit
[![CI](https://github.com/thejohnd0e/xray-vps-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/thejohnd0e/xray-vps-kit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/github/license/thejohnd0e/xray-vps-kit)](LICENSE) ![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white) ![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-A81D33?logo=debian&logoColor=white) ![Protocol](https://img.shields.io/badge/protocol-VLESS%20%2B%20REALITY%20%2B%20Vision%20(TCP)-blue)

Xray-core (VLESS + REALITY + XTLS Vision) on TCP 443 and the `xray-client` command to
manage clients. Companion to [awg-vps-kit](https://github.com/thejohnd0e/awg-vps-kit):
AmneziaWG uses UDP, this kit uses TCP, and both can live on the same server.

Files in this directory:

| File | Purpose |
|---|---|
| `install.sh` | installer for a fresh Debian/Ubuntu server |
| `xray-client` | client manager, installed to `/usr/local/bin` |
| `update.sh` | applies a newer kit / pinned Xray-core, with rollback |
| `uninstall.sh` | removes everything `install.sh` created |
| `releases/xray.lock.json` | pinned Xray-core version with SHA256 per architecture |

> **Status: pre-release (0.1.0).** The full lifecycle (install, clients, update, rollback,
> uninstall) and real REALITY traffic are tested in disposable VMs on Debian 12/13 and
> Ubuntu 22.04/24.04 (amd64). Not yet verified: native arm64, internet-facing traffic,
> imports in physical client apps. Do not deploy on a production server yet.

## Requirements

| | Minimum | Notes |
|---|---|---|
| OS | **Debian 12 or 13**, Ubuntu 22.04 / 24.04 | systemd and `apt` are required |
| CPU | amd64 or arm64 | arm64 is supported by the pinned archive but not yet tested natively |
| Network | public IPv4, TCP port open | default TCP 443; open it in the provider's firewall too |
| Access | root | |

The installer needs `jq`, `curl`, `unzip`, `openssl`, `qrencode`, `flock` (util-linux), `iproute2`,
and `nftables` or `iptables` for the firewall check. Install them with `apt-get install -y jq curl unzip openssl qrencode iproute2 nftables`.

## Install on a new server

```bash
# on the server, as root:
apt-get update && apt-get install -y git jq curl unzip openssl qrencode
git clone https://github.com/thejohnd0e/xray-vps-kit.git
cd xray-vps-kit
./install.sh --first-client user_01
```

Without options the installer asks for the port and SNI (press Enter for the defaults) and
installs without a final confirmation. At the end it prints the first client's URI and QR code;
to see them again later run `xray-client show user_01`. For automation add `--non-interactive`.

**Update** (later, from the same folder; details in "Updating"):

```bash
cd ~/xray-vps-kit    # the folder you cloned into
git pull
./update.sh --check  # only report (exit 0 = up to date, 10 = update available)
./update.sh          # apply; ./update.sh --rollback returns to the previous version
```

**Uninstall** (details in "Uninstall"):

```bash
cd ~/xray-vps-kit
./uninstall.sh       # asks for confirmation; add --keep-config to keep keys and clients
```

| Option | Default | Meaning |
|---|---|---|
| `--port PORT` | `443` | TCP listen port |
| `--server-name DNS` | `github.com` | REALITY SNI (must support TLS 1.3 and h2) |
| `--target HOST:PORT` | `<SNI>:443` | REALITY target |
| `--first-client NAME` | `main-user` | first identity |
| `--no-first-client` | | do not create an identity |
| `--endpoint IPV4/HOST` | auto (HTTPS lookup) | address written into client URIs |
| `--restore` | | recreate the service from preserved config (after `uninstall --keep-config`) |
| `--archive FILE` | download | local Xray-core archive; the pinned SHA256 is still checked |
| `--non-interactive` | | use flags and defaults without questions |
| `--no-service --root DIR` | | testing only: write files into an empty directory, no systemd/firewall |

What the installer does:

1. downloads the pinned Xray-core archive and verifies its SHA256 before using it;
2. creates the `xray-vps-kit` system user and a systemd unit that runs without root,
   with only `CAP_NET_BIND_SERVICE`;
3. generates UUID, REALITY key pair and short id, and writes the server config;
4. if `ufw` is active, opens the TCP port with an owned rule (marked `xray-vps-kit-<id>`);
   it refuses to continue if other firewall rules would block the port in a way it cannot judge;
5. starts `xray-vps-kit.service` and prints the first client's URI and QR code.

If the provider has a cloud firewall / security group, open the TCP port there yourself.

## Layout on the server

| | |
|---|---|
| Config and state | `/etc/xray-vps-kit/{config.json,state.json,ownership.json}` |
| Snapshots for rollback | `/etc/xray-vps-kit/backups/` |
| Code and Xray-core | `/opt/xray-vps-kit/releases/<kit>-<core>-<digest>/`, `current` symlink |
| Service | `xray-vps-kit.service` |
| Launcher | `/usr/local/bin/xray-client` |

## Managing clients: `xray-client`

Run as root.

```bash
xray-client help                         # short help
xray-client add <name>                   # create a client, print its URI + QR code
xray-client list                         # clients
xray-client show <name>                  # print the URI + QR code of an existing client
xray-client export <name> --output FILE  # URI only, to a new file with mode 0600
xray-client remove <name>                # revoke a client
xray-client doctor                       # health report (never prints keys, UUIDs or URIs)
xray-client version                      # kit and Xray-core versions
```

- One identity = one device is recommended; revoking a client disconnects it.
- Changes are applied atomically and the service is restarted; on failure the previous
  config is restored.
- Import the URI (or scan the QR code) in any VLESS + REALITY client (v2rayN, v2rayNG,
  Streisand, Hiddify, Shadowrocket, and others).

## Service and diagnostics

```bash
systemctl status xray-vps-kit
journalctl -u xray-vps-kit -n 30 --no-pager   # if it does not start
xray-client doctor
```

## Updating

Run from the cloned repo on the server:

```bash
cd ~/xray-vps-kit
git pull
./update.sh --check      # report only; exit 0 = up to date, 10 = update available
./update.sh              # apply this checkout and its pinned Xray-core
./update.sh --rollback   # return to the previous version
```

Keys and clients are kept. If the new version fails to start, the previous one is
restored automatically.

## Uninstall

```bash
./uninstall.sh                 # asks for confirmation (--yes for automation)
./uninstall.sh --keep-config   # keep keys and clients for a later install.sh --restore
```

Removes the service, launcher, installed code, the owned firewall rule and (without
`--keep-config`) config, keys and backups. Anything it cannot prove it created is left
alone, and the whole removal is refused if installed files were modified. The
`xray-vps-kit` user and installed apt packages are left in place.

## Coexistence with awg-vps-kit

The kit does not touch AmneziaWG files, units, nft tables, sysctl or UFW rules.
AWG on UDP 443 and Xray on TCP 443 do not conflict. This is tested with an AWG-named
fixture (files, UDP echo service, nft table, UFW rules) that stays byte-identical
through the whole install / update / rollback / uninstall cycle. A real AWG handshake
is not part of that test.

## Development and testing

Pure Bash plus `jq`, no build step. Python 3 is used only by test helpers.

```bash
bash tests/run.sh --suite validation      # also: harness release render transaction install
                                          #       clients export-doctor update uninstall coexistence
sudo bash tests/run.sh --suite e2e        # real REALITY traffic; root + netns, use a disposable VM
shellcheck *.sh xray-client lib/*.sh tests/*.sh tests/helpers/*.sh
```

Real systemd / UFW / reboot lifecycle in a disposable guest (never a production host):

```bash
XVK_VM_PASSWORD=... bash tests/run-vm.sh --guest USER@HOST --case lifecycle-coexistence
bash tests/run-vm.sh --os debian-12|debian-13|ubuntu-22.04|ubuntu-24.04 --case all   # QEMU
```

CI runs ShellCheck and all sandbox suites plus the real-traffic e2e suite on Ubuntu 22.04 and 24.04 for every push.

## License

MIT, see `LICENSE`.
