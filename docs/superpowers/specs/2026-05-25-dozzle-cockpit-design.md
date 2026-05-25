# Dozzle + Cockpit on dev_machine — design

**Status:** approved
**Date:** 2026-05-25
**Topic:** Add Dozzle (Docker log viewer) and Cockpit (web admin console) to the dev-only provisioning path, with tracked system-scope configuration.

## Motivation

`dev_machine` hosts already pull in Docker-adjacent CLI tooling (`lazydocker`, `dive`, `ctop`) and system-observability tooling (`btop`, `bottom`, `systemctl-tui`, `lazyjournal`), but lack browser-accessible equivalents. Dozzle covers real-time container log viewing; Cockpit covers system administration (services, journal, storage, network, podman containers, package updates). Both are useful additions to a workstation-style host; neither belongs on a `prod_machine` (which doesn't get sudo or system services from this repo). The work also exercises a new pattern — system-scope (`/etc/`) configuration tracking — that future system services can reuse.

## Decisions

| Decision | Choice | Rejected alternatives |
|---|---|---|
| Dozzle install method | Standalone binary via `EGET_TOOL` + systemd unit | Docker container (adds undeclared Docker dependency); shipping both (drift risk) |
| Cockpit footprint | Full workstation set: `cockpit` + `cockpit-system` + `cockpit-storaged` + `cockpit-networkmanager` + `cockpit-packagekit` + `cockpit-podman` | Minimal (too thin); full + `cockpit-machines` (pulls libvirtd, only useful if libvirt is in use) |
| Network exposure | Cockpit LAN (firewalld opened, PAM+TLS); Dozzle localhost (SSH-tunnel) | All-localhost (Cockpit already has PAM+TLS; tunneling for every admin session is friction); all-LAN (Dozzle has no auth by default) |
| Config tracking pattern | New top-level `configs/` directory, deployed by make targets via `sudo install` | Chezmoi (doesn't manage `/etc/`); `makefile/configs/` (less discoverable); ad-hoc heredocs in recipes (not reviewable) |

## Components

### 1. Version pin — `makefile/versions.mk`

New entries in a new "Service / web admin" group:

```make
# --- Service / web admin (dev_machine only) ---------------------------------
# Cockpit comes from dnf (see packages.mk); only Dozzle is binary-installed.
DOZZLE_VERSION := <latest stable from amir20/dozzle releases>
```

The version literal is filled in at implementation time. Bumping invalidates the per-tool stamp and the `dozzle-service` stamp (since the latter's stamp filename encodes `$(DOZZLE_VERSION)`) so unit-file edits after a version bump pick up on the next `make dev`.

### 2. Tool registration — `makefile/tools.mk`

New `EGET_TOOL` line in a new section:

```make
# =============================================================================
# OBSERVABILITY SERVICES (dev_machine only — paired with service targets in
# the top-level Makefile that install systemd units + tracked configs.)
# =============================================================================

$(eval $(call EGET_TOOL,dozzle,$(DOZZLE_VERSION),amir20/dozzle))
```

Dozzle ships a single static linux_amd64 binary on GitHub releases — no asset flags needed; default `v$(version)` tag matches upstream's tag format.

### 3. Package additions — `makefile/packages.mk`

Cockpit packages join `LINUX_OPTIONAL_PACKAGES` (which is already `INSTALL_PACKAGES=true` gated, i.e. dev-only) in a new group:

```make
LINUX_OPTIONAL_PACKAGES := \
  ripgrep bash-completion \
  htop multitail goaccess \
  nmap mtr \
  parallel pv entr tree strace perf cronie time \
  rsync vim-common vim-enhanced \
  shellcheck gdb lsof tcpdump \
  cockpit cockpit-system cockpit-storaged cockpit-networkmanager \
  cockpit-packagekit cockpit-podman
```

`packages-optional`'s per-package `|| true` semantics handle the case where `cockpit-podman` is missing on a given RHEL minor version (lives in EPEL on some, AppStream on others). Missing packages get reported as `skipped` instead of poisoning the run.

### 4. New `configs/` top-level directory

```
configs/
  dozzle/
    dozzle.service       → /etc/systemd/system/dozzle.service  (mode 0644)
    dozzle.env           → /etc/dozzle/dozzle.env              (mode 0644)
  cockpit/
    cockpit.conf         → /etc/cockpit/cockpit.conf           (mode 0644)
```

Files are committed in the repo, deployed by make recipes via `sudo install -m 0644`. Chezmoi's scope (`$HOME` only) is unchanged.

#### `configs/dozzle/dozzle.service`

```ini
[Unit]
Description=Dozzle — real-time Docker log viewer
Documentation=https://dozzle.dev/
After=docker.service
Wants=docker.service

[Service]
Type=simple
EnvironmentFile=/etc/dozzle/dozzle.env
ExecStart=/usr/local/bin/dozzle
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Runs as `root` (default) — needed for `/var/run/docker.sock` access. `After=docker.service` + `Wants=docker.service` means the unit waits for Docker but doesn't *require* it (the service stays up if Docker is later stopped; Dozzle re-connects when Docker returns).

#### `configs/dozzle/dozzle.env`

```
DOZZLE_ADDR=127.0.0.1:8080
DOZZLE_LEVEL=info
DOZZLE_NO_ANALYTICS=true
# DOZZLE_AUTH_PROVIDER=simple   # uncomment + create /etc/dozzle/users.yml for basic auth
```

127.0.0.1 binding implements the "Dozzle localhost only" decision. Access via SSH tunnel: `ssh -L 8080:localhost:8080 <host>` then browse `http://localhost:8080`.

#### `configs/cockpit/cockpit.conf`

```ini
[WebService]
LoginTitle = Cockpit
MaxStartups = 10
# Origins — uncomment and list every hostname/IP you'll reach this Cockpit instance from.
# Cockpit rejects cross-origin connections by default; you only need this if you embed
# Cockpit elsewhere or proxy it. Example:
# Origins = https://host.example:9090 https://host.example.lan:9090
```

Thin on purpose — Cockpit's defaults are already sane. `Origins` is left commented with a worked example so it's obvious how to opt in.

### 5. New makefile targets — `makefile/Makefile`

Two new bespoke rules (outside the `TOOL` / `EGET_TOOL` / `USER_TOOL` macros), in the same neighborhood as `claude-cli` / `node-runtime` / `claude-statusline`:

```make
# -----------------------------------------------------------------------------
# dozzle-service — install systemd unit + env file, enable+start. dev-only.
#   - Order-only dep on the dozzle BINARY STAMP (not the `dozzle` phony) —
#     matches the EGET_TOOL stamp-on-stamp invariant from CLAUDE.md; depending
#     on a phony breaks `make -j` (phonies are always-rebuild).
#   - This rule's stamp encodes $(DOZZLE_VERSION); bumping the binary version
#     also re-applies the unit file (in case it changed alongside).
#   - prod_machine: no-op (recipe body gated on MODE=dev).
# -----------------------------------------------------------------------------
.PHONY: dozzle-service clean-dozzle-service
ifeq ($(MODE),dev)
dozzle-service: $(STAMP)/dozzle-service-$(DOZZLE_VERSION).done
$(STAMP)/dozzle-service-$(DOZZLE_VERSION).done: | $(STAMP)/dozzle-$(DOZZLE_VERSION).done
$(STAMP)/dozzle-service-$(DOZZLE_VERSION).done:
	@printf '==> dozzle-service (systemd)\n'
	@$(SUDO) install -m 0755 -d /etc/dozzle
	@$(SUDO) install -m 0644 ../configs/dozzle/dozzle.env /etc/dozzle/dozzle.env
	@$(SUDO) install -m 0644 ../configs/dozzle/dozzle.service /etc/systemd/system/dozzle.service
	@$(SUDO) systemctl daemon-reload
	@$(SUDO) systemctl enable --now dozzle.service
	@mkdir -p $(@D) && touch $@
else
dozzle-service:
	@echo "dozzle-service is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-dozzle-service:
	@$(SUDO) systemctl disable --now dozzle.service 2>/dev/null || true
	@$(SUDO) rm -f /etc/systemd/system/dozzle.service /etc/dozzle/dozzle.env
	@$(SUDO) rmdir /etc/dozzle 2>/dev/null || true
	@$(SUDO) systemctl daemon-reload
	@rm -f $(STAMP)/dozzle-service-*.done

# -----------------------------------------------------------------------------
# cockpit-service — install cockpit.conf, enable socket, open firewalld.
#   - CANNOT depend on the `packages` phony (would break `make -j8`).
#     packages.mk doesn't produce a stamp file either, so there's no stamp
#     to order-only-depend on. Instead, the recipe sanity-checks
#     `rpm -q cockpit` at the top and aborts with a clear message if the
#     package isn't installed yet. Correct under both serial and -j make.
#   - Stamp has no version suffix; Cockpit's package version comes from dnf.
#   - firewalld step skipped (with a message) when firewalld is inactive.
# -----------------------------------------------------------------------------
.PHONY: cockpit-service clean-cockpit-service
ifeq ($(MODE),dev)
cockpit-service: $(STAMP)/cockpit-service.done
$(STAMP)/cockpit-service.done:
	@printf '==> cockpit-service (socket + firewall + conf)\n'
	@if ! rpm -q cockpit >/dev/null 2>&1; then \
	   printf '  ERROR: cockpit package not installed. Run `make MODE=dev packages` first,\n'; \
	   printf '         or `make MODE=dev provision` (which runs packages before this target).\n' >&2; \
	   exit 1; \
	 fi
	@$(SUDO) install -m 0755 -d /etc/cockpit
	@$(SUDO) install -m 0644 ../configs/cockpit/cockpit.conf /etc/cockpit/cockpit.conf
	@$(SUDO) systemctl enable --now cockpit.socket
	@if systemctl is-active --quiet firewalld 2>/dev/null; then \
	   $(SUDO) firewall-cmd --permanent --add-service=cockpit >/dev/null && \
	   $(SUDO) firewall-cmd --reload >/dev/null && \
	   printf '  firewalld: cockpit service opened\n'; \
	 else \
	   printf '  firewalld inactive — skipping firewall step\n'; \
	 fi
	@mkdir -p $(@D) && touch $@
else
cockpit-service:
	@echo "cockpit-service is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-cockpit-service:
	@$(SUDO) systemctl disable --now cockpit.socket 2>/dev/null || true
	@if systemctl is-active --quiet firewalld 2>/dev/null; then \
	   $(SUDO) firewall-cmd --permanent --remove-service=cockpit >/dev/null 2>&1 || true; \
	   $(SUDO) firewall-cmd --reload >/dev/null 2>&1 || true; \
	 fi
	@$(SUDO) rm -f /etc/cockpit/cockpit.conf
	@rm -f $(STAMP)/cockpit-service.done
```

Both targets join `provision`'s dev-only dep list:

```make
ifeq ($(MODE),dev)
provision: claude-cli node-runtime dozzle-service cockpit-service
endif
```

**Ordering under `make -j8`:** the existing `provision: packages tools user-tools shell dotfiles` line already lets `packages` and `tools` run in parallel — that's safe today because tool installs are self-contained downloads. Adding `dozzle-service` and `cockpit-service` doesn't change that: `dozzle-service` declares an order-only stamp-on-stamp dep on the `dozzle` binary stamp (so the binary lands first), and `cockpit-service` does a runtime `rpm -q cockpit` check (since `packages.mk` produces no stamp to depend on). The check fails loud and clear if a user races things by hand; the normal `make dev` flow under `-j` works because `cockpit.socket` enable is a fast operation that loses any race against the multi-second `dnf install`.

**Followup (out of scope for this design):** if more services-that-need-packages get added later, the cleanest fix is to make `packages-optional` produce a stamp file — `cockpit-service` could then declare an order-only dep on that stamp instead of the rpm-q runtime check. Deferring until there's a second consumer.

### 6. `make list` and `make help` updates

`make list` already enumerates `SCOPE_TOOLS` and `USER_TOOLS`. Dozzle joins `SCOPE_TOOLS` automatically via `EGET_TOOL`. The two new service targets are bespoke, so add a parallel `services (provisioned on MODE=dev only)` block to `list`:

```make
list:
	@printf 'scope-tools (%d):\n' $(words $(SCOPE_TOOLS))
	@printf '  %s\n' $(sort $(SCOPE_TOOLS))
	@printf '\nuser-tools (%d):\n' $(words $(USER_TOOLS))
	@printf '  %s\n' $(sort $(USER_TOOLS))
	@printf '\nservices (provisioned on MODE=dev only):\n'
	@printf '  dozzle-service\n  cockpit-service\n'
	@printf '\nclaude-cli (provisioned on MODE=dev only)\n'
```

And add corresponding lines to `make help`.

### 7. README + CLAUDE.md + CLAUDE_CHANGELOG.md updates

Per the load-bearing invariant in `CLAUDE.md`: "When changing user-facing surface, update `README.html` ... in the same commit, then append a row to `CLAUDE_CHANGELOG.md`."

**`README.html`** — additions:
- New tool entries in the existing tools accordion: Dozzle (under containers / Docker), Cockpit (under system admin)
- Two new troubleshooting entries:
  - *"Cockpit login fails — Permission denied"* — PAM auth; user account must have a password set (SSH-key-only accounts can't log in via Cockpit web)
  - *"Dozzle service starts but shows no containers"* — Docker not running, or Dozzle user has no access to `/var/run/docker.sock`
- The "Daily workflows" section gets a one-line mention: `https://<host>:9090` for Cockpit, `ssh -L 8080:localhost:8080 <host>` then `http://localhost:8080` for Dozzle

**`CLAUDE.md`** — additions:
- New row in "Where things are documented" table: `configs/` → `README.html §services` (or wherever the accordion lives)
- New load-bearing invariant about the `configs/` pattern: files there are NOT chezmoi-managed; they're sudo-installed into `/etc/` by paired `*-service` make targets. Don't try to migrate them under chezmoi.
- New "Files Claude should be careful with" entries for `configs/dozzle/dozzle.service`, `configs/dozzle/dozzle.env`, `configs/cockpit/cockpit.conf` — note that hand-editing these on a host is futile (the make target overwrites them next run); edits belong in the repo file.
- Verification recipes append (see §8 below)

**`CLAUDE_CHANGELOG.md`** — one row capturing the pattern decisions (the new `configs/` TLD, the `*-service` make target naming, the dev-only gating).

**`docs/README/README.css` / `.js`** — no asset changes needed; new accordion + troubleshooting entries reuse existing primitives.

### 8. Verification recipes (to be added to CLAUDE.md "Quick verification")

```bash
# After install:
systemctl status dozzle.service cockpit.socket                # both active
ss -tlnp | grep -E ':(8080|9090)'                              # 8080 on 127.0.0.1, 9090 on ::/0
sudo firewall-cmd --list-services | grep -q cockpit && echo "firewall ok"
journalctl -u dozzle -n 20 --no-pager                          # no errors
curl -sI http://127.0.0.1:8080 | head -1                       # HTTP/1.1 200 OK
curl -skI https://127.0.0.1:9090 | head -1                     # HTTP/1.1 200 OK

# Dry-run checks (no sandbox install):
cd makefile && make list MODE=dev                              # shows dozzle in scope-tools, services block listed
cd makefile && make -n MODE=dev provision | grep -E '(dozzle|cockpit)'  # both fire
cd makefile && make -n MODE=prod provision | grep -E '(dozzle|cockpit)' # neither fires
```

## Out of scope

- **Docker install** — same as today; the binary works headlessly until Docker is present, then auto-connects via the socket.
- **Cockpit reverse-proxy / signed TLS cert** — self-signed default is fine for dev; users can drop a cert under `/etc/cockpit/ws-certs.d/` per-host (un-tracked, per the existing per-host override pattern).
- **Dozzle `users.yml`** — auth is opt-in via the commented env var.
- **Cockpit `cockpit-machines` / libvirt** — only useful if libvirtd is already provisioned (it isn't).
- **Windows side** — Cockpit is Linux-only; Dozzle Windows binary exists but doesn't belong on the WezTerm GUI host.
- **chezmoi-template-driven config** — `cockpit.conf` and `dozzle.env` are plain INI/env, not `.tmpl`. If per-host variation becomes necessary, escalate to a chezmoi-style template in `configs/<tool>/*.tmpl` rendered by a new lib helper, but defer until a concrete need shows up.

## Open questions

None at design time; both flagged questions resolved during brainstorming.

## Implementation plan

To be authored in a follow-up via the `writing-plans` skill — see `docs/superpowers/plans/2026-05-25-dozzle-cockpit-plan.md` (forthcoming).
