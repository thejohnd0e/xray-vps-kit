# Changelog

## Unreleased

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

## 0.1.1

- Failed worker refresh restores the exact previous payload, candidate bundles are not deleted
  while selected, `doctor` verifies ownership and listener ownership, client mutations are
  serialized, installed workers are recognised under relative and symlinked invocation.

## 0.1.0

- First public version: VLESS + REALITY server with `xray-client`, pinned Xray-core, transactional
  updates, owned-resource uninstall, optional automatic core updates, `block-ping`.
