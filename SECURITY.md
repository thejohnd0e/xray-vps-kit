# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub:
**Security → Report a vulnerability** on <https://github.com/thejohnd0e/xray-vps-kit/security>.
Do not open a public issue for them. Include the affected version (`xray-client version`), the
operating system, and the steps to reproduce. Expect an answer within a few days; this is a
single-maintainer project.

## Scope

In scope: the installer, updater, uninstaller, `xray-client`, `block-ping`, the generated
configuration and systemd unit, and the release pinning of Xray-core.
Out of scope: vulnerabilities in Xray-core itself (report them to
[XTLS/Xray-core](https://github.com/XTLS/Xray-core/security)), and the general visibility of
a proxy to network observers.

## Supported versions

Only the latest release and the current `master` branch receive fixes.

## Installing from a fixed version

The one-line installers fetch the newest `master`. To install exactly the code of a tag or
commit that you have reviewed, set `XVK_REF`:

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/install.sh | XVK_REF=v0.1.3 bash
```
