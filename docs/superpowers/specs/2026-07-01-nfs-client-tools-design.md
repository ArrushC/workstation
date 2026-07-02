# NFS client tooling — dev-only, non-WSL (design)

**Date:** 2026-07-01
**Status:** approved

## Goal

Add client-side NFS tooling to the workstation toolbelt for `dev_machine`
hosts only, excluding WSL hosts entirely. Client-side means mount, inspect,
debug, and ACL work against NFS shares served elsewhere — this repo does NOT
turn dev boxes into NFS servers.

## Package set

| Package | Provides | Repo (EL9) |
|---|---|---|
| `nfs-utils` | `mount.nfs`, `showmount`, `nfsstat`, `nfsiostat`, `mountstats` | BaseOS |
| `nfs4-acl-tools` | `nfs4_getfacl`, `nfs4_setfacl`, `nfs4_editfacl` | AppStream |
| `autofs` | on-demand automounter daemon (`automount`) | AppStream |

No EPEL/CRB dependency; the per-package `|| true` best-effort path still
protects future distro variants.

## Mechanics (approach A — conditional package group)

In `makefile/packages.mk`, below `LINUX_OPTIONAL_PACKAGES`:

```make
LINUX_NFS_PACKAGES := nfs-utils nfs4-acl-tools autofs
ifeq ($(IS_WSL),false)
LINUX_OPTIONAL_PACKAGES += $(LINUX_NFS_PACKAGES)
endif
```

- `IS_WSL` is already computed and exported by `makefile/scope.mk`; no new
  detection logic.
- Dev-only gating is inherited: `packages-optional` only runs when
  `INSTALL_PACKAGES=true` (`MODE=dev`). Prod stays a no-op.
- The `rpm -q` fast path and per-package `|| true` fail-soft apply unchanged;
  re-provisioning is idempotent.
- A comment block above the variable records the group's intent (client-side
  only, no server), the WSL-exclusion policy (same family as
  `docker-engine`/`cockpit`/`rsyslog-service` skips), and the autofs
  install-only semantics (below).
- **Skip visibility:** the `packages-optional` recipe prints
  `skipping NFS client group on WSL (<packages>)` when `IS_WSL=true`,
  mirroring the repo's other skip messages, so the exclusion is auditable in
  provision output.

Rejected alternatives: a bespoke stamped Makefile target (that shape exists
for `/etc` config + service enablement, which this change doesn't do) and a
recipe-level WSL special-case inside the package loop (turns the package list
from data into logic).

## autofs semantics

Install-only. The design deliberately does NOT:

- `systemctl enable`/`start` autofs (an automounter with no maps does
  nothing);
- deploy `/etc/auto.master`/`/etc/auto.*` maps (inherently per-host; not
  templated by this repo — no `configs/` addition).

Per-host activation is a documented manual step: write maps, then
`sudo systemctl enable --now autofs`.

## Docs & generated memory

- `scripts/gen-tool-memory.sh`: add a stanza extracting
  `LINUX_NFS_PACKAGES` into a new
  `### System packages (dnf, dev-only, non-WSL)` section of the
  `<!-- TOOLS:START/END -->` block in
  `chezmoi/private_dot_claude/CLAUDE.md`. The `sync-tool-memory.sh` hook
  regenerates the block automatically when `packages.mk` is edited. After
  editing the script: re-verify LF endings + git mode, `shfmt -i 2` clean.
- `README.html`: add the NFS group to the dnf-packages surface, with the
  WSL-exclusion note and the autofs per-host activation hint. Same commit.
- `CLAUDE_CHANGELOG.md`: append a row.
- `scripts/check-invariants.sh`: no change — no version pins, sentinel
  blocks, parity pairs, or mode/CRLF-sensitive file classes are added (the
  TOOLS sentinel already exists and is generator-owned).

## Verification

On this WSL dev host:

```bash
make -C makefile -n packages-optional MODE=dev              # skip message, no NFS pkgs
make -C makefile -n packages-optional MODE=dev IS_WSL=false # NFS pkgs present
make -C makefile packages MODE=prod                         # no-op skip message
bash scripts/gen-tool-memory.sh                             # TOOLS block gains the new stanza
make -C makefile lint MODE=prod                             # invariants + shellcheck + shfmt + gitleaks pass
```

## Out of scope

- NFS server capability (`nfs-server`, `exportfs`, `rpcbind` service wiring).
- Enabling/configuring autofs.
- Wire-level NFS observability extras (`nfswatch`, wireshark) — `tcpdump`
  and `nmap` are already in the toolbelt.
- Windows / `bootstrap.ps1` (NFS tooling is Linux-only here).
