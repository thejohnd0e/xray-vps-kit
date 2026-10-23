# Xray VPS Kit
[![CI](https://github.com/thejohnd0e/xray-vps-kit/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/thejohnd0e/xray-vps-kit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/github/license/thejohnd0e/xray-vps-kit)](LICENSE) ![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white) ![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-A81D33?logo=debian&logoColor=white) ![Protocol](https://img.shields.io/badge/protocol-VLESS%20%2B%20REALITY%20%2B%20Vision%20(TCP)-blue)

> **Complementary solutions:** [awg-vps-kit](https://github.com/thejohnd0e/awg-vps-kit) (AmneziaWG over UDP)
> and this kit (VLESS + REALITY over TCP) are two independent tools for the same job. Use either one, or
> both on the same server; see "AWG or Xray?" below.

Xray-core (VLESS + REALITY + XTLS Vision) on TCP 443 and the `xray-client` command to
manage clients.

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

Before preflight, the installer automatically installs missing dependencies through `apt`
(`jq`, `curl`, `unzip`, `openssl`, `qrencode`, `iproute2`, `util-linux` and CA certificates).
It shows the missing package list, current stage and APT's native download/installation progress;
if the tools are already available, APT is skipped. If neither firewall inspection tool is
available, it installs `iptables`; this does not enable a firewall. Package installation uses
`--no-remove`, and uninstall retains system packages without running `autoremove`.
Testing installs (`--no-service --root DIR`) never install host packages.

## Install on a new server

Run it on the server as root, from any folder. `curl` is the only prerequisite; if it is missing,
run `apt-get update && apt-get install -y curl` first.

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/install.sh | bash -s -- --first-client user_01
```

The script installs `git` if needed, puts the kit in `/opt/xray-vps-kit-src` (fast-forwarding it if it
is already there) and continues from that copy with the options you passed. Without options it asks for
the port and SNI (press Enter for the defaults) and installs without a final confirmation. At the end it
prints the first client's URI and QR code; to see them again later run `xray-client show user_01`.
For automation add `--non-interactive`.

**Update** (fetches the latest kit and applies it; changes nothing if nothing is newer):

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/update.sh | bash
```

Add `-s -- --check` after `bash` to only report (exit 0 = up to date, 10 = update available) or
`-s -- --rollback` to return to the previous version.

**Uninstall** (asks for confirmation; details in "Uninstall"):

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/uninstall.sh | bash
```

Add `-s -- --keep-config` to keep keys and clients.

Prefer to read the code first? Clone it and run the same scripts locally:

```bash
git clone https://github.com/thejohnd0e/xray-vps-kit.git && cd xray-vps-kit
./install.sh --first-client user_01     # likewise ./update.sh and ./uninstall.sh
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

If the provider has a cloud firewall / security group, open the TCP port there yourself: the
installer only manages the server's own UFW and cannot see the provider's. Without `ufw` it
opens nothing and only checks that no other local rule would block the port.

### Two different "443"s

- `--port` is the **local listen port** on your server, the one clients connect to.
- `--target` (default `<SNI>:443`) is the **remote site** that REALITY imitates; the server
  contacts it during the handshake. It is unrelated to your own port 443 and is checked
  (TLS 1.3, h2) before anything is installed. `--server-name` is the SNI clients present.

### Restore and `--no-first-client`

`--no-first-client` installs with no identities; add them later with `xray-client add`.
`--restore` (after `uninstall.sh --keep-config`) recreates the service from the preserved
keys and clients; it does **not** create a new `main-user`, and the old profiles keep working.

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

- Names: letters, digits, `_` and `-`. One identity = one device is recommended.
- `add` and `remove` change the config atomically and **restart the service**, so every
  connected client drops for a moment and reconnects. On failure the previous config is
  restored. Removing a client disconnects that device for good.
- Import the URI (or scan the QR code) in a VLESS + REALITY client. See
  "Client compatibility" for what has and has not been tested.

## Service and diagnostics

```bash
systemctl status xray-vps-kit
journalctl -u xray-vps-kit -n 30 --no-pager   # if it does not start
xray-client doctor
```

## Updating

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/update.sh | bash -s -- --check      # report only
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/update.sh | bash                    # apply
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/update.sh | bash -s -- --rollback   # previous version
```

`--check` exits 0 when up to date and 10 when an update is available.

The one-liner fast-forwards `/opt/xray-vps-kit-src` to the latest `master` and applies that code,
so you are trusting what is on GitHub at that moment. To review first, `cd /opt/xray-vps-kit-src`,
`git pull`, read `git log -p`, then run `./update.sh` from there (or from your own clone).
The Xray-core version is the one pinned in `releases/xray.lock.json`, checked against its SHA256
before use. Keys and clients are kept. If the new version fails to start, the previous one is
restored automatically. `--rollback` returns to the previous version, but is refused once clients
were added or removed after the update (to avoid losing those changes).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/uninstall.sh | bash                      # asks for confirmation
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/uninstall.sh | bash -s -- --keep-config  # keep keys and clients
```

`--yes` skips the confirmation; `--keep-config` keeps keys and clients for a later `install.sh --restore`.
Removes the service, launcher, installed code, the owned firewall rule and (without `--keep-config`)
config, keys and backups. Anything it cannot prove it created is left alone, and the whole removal is
refused if installed files were modified. The `xray-vps-kit` user, installed apt packages and the
downloaded kit copy `/opt/xray-vps-kit-src` are left in place (`rm -rf /opt/xray-vps-kit-src` removes it).

## Privacy and secrets

- A client URI contains the client's UUID and the server's REALITY public key. Treat it as
  a password: anyone holding it can use your server.
- State, config and ownership files are root-only (mode 0600/0640); `export` creates its
  file with mode 0600 and refuses to overwrite.
- `xray-client doctor` never prints keys, UUIDs or URIs, so its output is safe to share.
- The service runs as the unprivileged `xray-vps-kit` user.

## Client compatibility

The URI is a standard `vless://` link with REALITY and Vision parameters. What has been
verified is separated here on purpose:

| Check | Result |
|---|---|
| URI parsed by an independent parser against the stored identity | passes |
| QR code decodes to exactly the same URI | passes |
| Real pinned Xray-core connects from an exported URI, reaches a test origin, and is refused after revocation | passes |
| v2rayN, v2rayNG, Streisand, Hiddify, Shadowrocket and other apps | **not tested**; check that your app supports VLESS + REALITY + `xtls-rprx-vision` |

There is no guarantee that every client works.

## AWG or Xray?

They solve different problems and are managed separately (no shared commands, no automatic
switching):

| | awg-vps-kit | xray-vps-kit |
|---|---|---|
| Transport | AmneziaWG over UDP | VLESS + REALITY + Vision over TCP |
| Typical reason to pick it | the network throttles inbound TCP from foreign hosting | UDP is blocked or filtered, or you need per-client URIs for common apps |
| Server port | UDP 443 | TCP 443 |

Both can run on one server. Measure your own path before choosing (for example with `iperf3`
over TCP and UDP): this project makes no speed claims.

## Coexistence with awg-vps-kit

The kit does not touch AmneziaWG files, units, nft tables, sysctl or UFW rules.
AWG on UDP 443 and Xray on TCP 443 do not conflict. This is tested with an AWG-named
fixture (files, UDP echo service, nft table, UFW rules) that stays byte-identical
through the whole install / update / rollback / uninstall cycle. A real AWG handshake
is not part of that test.

## What is not measured or verified

- Throughput, latency, RAM and disk use: not measured, so no minimums beyond the table above.
- Native arm64: only the pinned archive and rendering are checked, not a running service.
- Reachability from the internet and from physical client apps: not tested.
- Blocking resistance: no claim is made.

## Future CDN transport

Not implemented. A CDN-fronted mode would be a separate deployment; the design boundaries
are written down in [docs/transport-extension.md](docs/transport-extension.md).

## Development and testing

Pure Bash plus `jq`, no build step. Python 3 is used only by test helpers.

```bash
bash tests/run.sh --suite validation      # also: harness release render transaction install
                                          #       clients export-doctor update uninstall coexistence docs
sudo bash tests/run.sh --suite e2e        # real REALITY traffic; root + netns, use a disposable VM
bash tests/run.sh --suite docs            # README commands, flags, links, claims
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
