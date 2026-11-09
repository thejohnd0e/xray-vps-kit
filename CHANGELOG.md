# Changelog

## 0.1.2

- IPv6: `install.sh --ipv6` and `xray-client ipv6 on|off` manage the UFW IPv6 row (owned with the IPv4 one) and a doctor check; IPv6 endpoints in URIs are bracketed.
- `xray-client doctor --probe-reality`: functional REALITY check through a throwaway local client.

## 0.1.1

- Service unit: restarts after any exit without a start limit; extra systemd sandboxing.
- `block-ping`: the uplink is detected again at every start and reload, `systemctl reload nftables`
  no longer erases the rule, new test suite.
- Automatic core updates: per-server cron minute, a release must be at least three days old
  before a scheduled run installs it.
- UFW: append the allow rule when `ufw insert 1` is refused.
- Crash recovery: a journal and `xray-client recover` undo a change cut short by a crash or
  power loss; `doctor` reports a pending journal.
- `uninstall.sh` works without GitHub (uses the installed copy); `--purge-preserved`.
- Bootstrap: `XVK_REF` pins a tag or commit, `XVK_ALLOW_UNSUPPORTED_OS=1` for derivatives; the
  bootstrap block is generated from `tools/bootstrap.block.in`.
- Weekly workflow proposes new Xray-core pins as pull requests; Dependabot for Actions;
  advisory Debian CI job; `SECURITY.md`; Russian README.
- `xray-client export --format singbox|clash`, `list --json`, `doctor` advisories and `--probe-target`.
- Failed worker refresh restores the exact previous payload, candidate bundles are not deleted
  while selected, `doctor` verifies ownership and listener ownership, client mutations are
  serialized, installed workers are recognised under relative and symlinked invocation.

## 0.1.0

- First public version: VLESS + REALITY server with `xray-client`, pinned Xray-core, transactional
  updates, owned-resource uninstall, optional automatic core updates, `block-ping`.
