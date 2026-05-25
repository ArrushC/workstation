# Dozzle + Cockpit on dev_machine — design

**Status:** approved (revised 2026-05-25 — Dozzle pivoted from binary to Docker after upstream verification)
**Date:** 2026-05-25
**Topic:** Add Dozzle (Docker log viewer, run as a container via systemd) and Cockpit (web admin console, dnf-installed) to the dev-only provisioning path, with tracked system-scope configuration.

## Revision history

- **2026-05-25 v1** — original design picked "standalone binary via EGET_TOOL" for Dozzle. Verification during implementation showed Dozzle's 10.x GitHub releases publish **zero binary assets** (Docker-only distribution). Spec revised in-place; the binary-based EGET_TOOL commit `a4c99c4` was reverted (`9bd50dd`). All other design decisions (Cockpit footprint, network exposure, `configs/` pattern) carried forward unchanged.

## Motivation

`dev_machine` hosts already pull in Docker-adjacent CLI tooling (`lazydocker`, `dive`, `ctop`) and system-observability tooling (`btop`, `bottom`, `systemctl-tui`, `lazyjournal`), but lack browser-accessible equivalents. Dozzle covers real-time container log viewing; Cockpit covers system administration (services, journal, storage, network, podman containers, package updates). Both are useful additions to a workstation-style host; neither belongs on a `prod_machine` (which doesn't get sudo or system services from this repo). The work also exercises a new pattern — system-scope (`/etc/`) configuration tracking — that future system services can reuse.

## Decisions

| Decision | Choice | Rejected alternatives |
|---|---|---|
| Dozzle install method | Docker image (`amir20/dozzle:$(DOZZLE_VERSION)`) pulled and run by a systemd unit; bind-mount `/var/run/docker.sock` read-only; bound to 127.0.0.1:8080 | Binary via `EGET_TOOL` (rejected: upstream publishes no binary release assets, verified across v10.0.5–v10.6.1); building from source (over-scope: needs Go toolchain provisioning); dropping Dozzle (rejected: `cockpit-podman` covers podman but not Docker, and the live-log UX of Dozzle is distinct) |
| Dozzle Docker prerequisite | Assumed-present (consistent with `lazydocker` / `dive` / `ctop`, which also assume Docker); systemd unit declares `Requires=docker.service` so failure is loud and self-disabling on hosts without Docker | Provision Docker via this repo (rejected: blast radius too large for the scope of this design; can be a follow-up) |
| Cockpit footprint | Full workstation set: `cockpit` + `cockpit-system` + `cockpit-storaged` + `cockpit-networkmanager` + `cockpit-packagekit` + `cockpit-podman` | Minimal (too thin); full + `cockpit-machines` (pulls libvirtd, only useful if libvirt is in use) |
| Network exposure | Cockpit LAN (firewalld opened, PAM+TLS); Dozzle localhost (SSH-tunnel) | All-localhost (Cockpit already has PAM+TLS; tunneling for every admin session is friction); all-LAN (Dozzle has no auth by default) |
| Config tracking pattern | New top-level `configs/` directory, deployed by make targets via `sudo install` | Chezmoi (doesn't manage `/etc/`); `makefile/configs/` (less discoverable); ad-hoc heredocs in recipes (not reviewable) |

## Components

### 1. Version pin — `makefile/versions.mk`

New entry in a new "Service / web admin" group. The version is the Docker image tag (`amir20/dozzle:<tag>`), substituted into the tracked env file by the make target at install time:

```make
# --- Service / web admin (dev_machine only) ---------------------------------
# Dozzle is run as a Docker container via systemd (no native binary — upstream
# publishes Docker images only). The value below pins the Docker image tag
# (amir20/dozzle:$(DOZZLE_VERSION)); bumping it invalidates the
# dozzle-service stamp so the next `make dev` re-pulls + re-installs.
# Cockpit comes from dnf (see packages.mk) and isn't versioned here.
DOZZLE_VERSION := 10.6.1
```

Bumping `DOZZLE_VERSION` invalidates the `dozzle-service` stamp (its filename encodes `$(DOZZLE_VERSION)`) so the next `make dev` re-renders `/etc/dozzle/dozzle.env`, re-pulls the image, and restarts the unit.

### 2. Tool registration — *(none)*

Dozzle is **not** registered in `tools.mk`. It's not a binary deposited into `$(DEST)` — it's a Docker image whose lifecycle is owned entirely by the `dozzle-service` make target plus the systemd unit. This is intentional: every other entry in `tools.mk` represents a single-file binary under `$(DEST)`, and adding a "Docker image" entry would muddy that invariant.

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
Description=Dozzle — real-time Docker log viewer (containerized)
Documentation=https://dozzle.dev/
After=docker.service
Requires=docker.service

[Service]
Type=simple
EnvironmentFile=/etc/dozzle/dozzle.env
# Pre-flight: kill any leftover container from a prior unclean shutdown.
# Leading `-` keeps systemd going if the container doesn't exist.
ExecStartPre=-/usr/bin/docker stop dozzle
ExecStartPre=-/usr/bin/docker rm dozzle
ExecStartPre=/usr/bin/docker pull ${DOZZLE_IMAGE}
# Foreground run (no -d) so systemd owns the lifecycle.
ExecStart=/usr/bin/docker run --rm --name dozzle \
  -p ${DOZZLE_BIND}:8080 \
  -e DOZZLE_LEVEL=${DOZZLE_LEVEL} \
  -e DOZZLE_NO_ANALYTICS=${DOZZLE_NO_ANALYTICS} \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  ${DOZZLE_IMAGE}
ExecStop=/usr/bin/docker stop dozzle
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`Requires=docker.service` is stricter than the original `Wants=` — if Docker stops, Dozzle stops too (the container can't survive without its host daemon). The systemd unit owns the container lifecycle; the container runs in the foreground (no `-d`) so `systemctl stop dozzle` cleanly tears it down. The read-only Docker socket bind-mount is the only thing the container needs from the host (besides its own port). All tunables flow from `dozzle.env` so the unit itself never needs editing for routine config changes.

#### `configs/dozzle/dozzle.env`

The tracked source file uses a `@DOZZLE_VERSION@` placeholder which `dozzle-service`'s recipe substitutes from `$(DOZZLE_VERSION)` at install time (so `versions.mk` stays the single source of truth for the version):

```
# /etc/dozzle/dozzle.env — read by dozzle.service.
# Edit DOZZLE_VERSION in makefile/versions.mk to bump the image tag; this
# file's @DOZZLE_VERSION@ placeholder is substituted at `make dozzle-service`
# install time.
DOZZLE_IMAGE=amir20/dozzle:@DOZZLE_VERSION@
DOZZLE_BIND=127.0.0.1
DOZZLE_LEVEL=info
DOZZLE_NO_ANALYTICS=true
```

`DOZZLE_BIND=127.0.0.1` implements the "Dozzle localhost only" decision — the `-p ${DOZZLE_BIND}:8080` flag in the unit yields `-p 127.0.0.1:8080:8080` (host:container). Access from a workstation: `ssh -L 8080:localhost:8080 <host>` then `http://localhost:8080`. Flipping `DOZZLE_BIND=0.0.0.0` opens the unauthenticated log viewer on every interface — only do this after configuring Dozzle's `DOZZLE_AUTH_PROVIDER=simple` and a `users.yml` (out of scope here; opt-in by editing the unit + adding `/etc/dozzle/users.yml`).

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
# dozzle-service — install systemd unit + env file, pull image, enable + start.
#   - dev_machine only (recipe body gated on MODE=dev).
#   - Env file is templated: `@DOZZLE_VERSION@` in configs/dozzle/dozzle.env
#     is substituted with $(DOZZLE_VERSION) at install time via sed. Keeps
#     versions.mk as the single source of truth.
#   - Stamp encodes $(DOZZLE_VERSION); bumping the pin invalidates the stamp
#     so the next `make dev` re-renders dozzle.env, re-pulls the image, and
#     restarts the unit.
#   - Sanity-checks `docker --version` at the top of the recipe (since this
#     repo doesn't install Docker; lazydocker/dive/ctop already assume it).
#     Loud failure with a clear message if Docker is missing.
# -----------------------------------------------------------------------------
.PHONY: dozzle-service clean-dozzle-service
ifeq ($(MODE),dev)
dozzle-service: $(STAMP)/dozzle-service-$(DOZZLE_VERSION).done
$(STAMP)/dozzle-service-$(DOZZLE_VERSION).done:
	@printf '==> dozzle-service (docker + systemd)\n'
	@if ! command -v docker >/dev/null 2>&1; then \
	   printf '  ERROR: docker is not installed. Dozzle runs as a container.\n' >&2; \
	   printf '         Install Docker (or Podman with a docker shim) and retry.\n' >&2; \
	   exit 1; \
	 fi
	@$(SUDO) install -m 0755 -d /etc/dozzle
	@sed 's|@DOZZLE_VERSION@|$(DOZZLE_VERSION)|g' ../configs/dozzle/dozzle.env \
	   | $(SUDO) install -m 0644 /dev/stdin /etc/dozzle/dozzle.env
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
	@$(SUDO) docker rm -f dozzle 2>/dev/null || true
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

**Ordering under `make -j8`:** the existing `provision: packages tools user-tools shell dotfiles` line already lets `packages` and `tools` run in parallel — that's safe today because tool installs are self-contained downloads. The two new service rules don't change that: `dozzle-service` does a runtime `command -v docker` check (the repo doesn't own Docker provisioning, so no stamp to depend on), and `cockpit-service` does a runtime `rpm -q cockpit` check (`packages.mk` produces no stamp). Both checks fail loud and clear if invoked out of order by hand; under `make dev` (or `make -j8 dev`) the docker presence check is fine because Docker is a host-level prerequisite assumed pre-existing, and the cockpit check loses any race against the multi-second `dnf install`.

**Followup (out of scope for this design):** if more services-that-need-packages get added later, the cleanest fix is to make `packages-optional` produce a stamp file — `cockpit-service` could then declare an order-only dep on that stamp instead of the rpm-q runtime check. Similarly, if this repo ever owns Docker provisioning, `dozzle-service` should gain an order-only stamp dep on that. Defer both until there's a second consumer.

### 6. `make list` and `make help` updates

`make list` already enumerates `SCOPE_TOOLS` and `USER_TOOLS`. Dozzle is **not** a SCOPE_TOOL in the revised design (it has no binary in `$(DEST)`); it shows up only in the new `services (provisioned on MODE=dev only)` block:

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
cd makefile && make list MODE=dev                              # services block listed (no scope-tools entry for dozzle in revised design)
cd makefile && make -n MODE=dev provision | grep -E '(dozzle-service|cockpit-service)'  # both fire
cd makefile && make -n MODE=prod provision | grep -E '(dozzle-service|cockpit-service)' # neither fires
```

## Out of scope

- **Docker install** — same as today: this repo doesn't provision Docker; `lazydocker` / `dive` / `ctop` already assume it's present, and `dozzle-service` now does too. The recipe's `command -v docker` check fails loud on hosts without Docker.
- **Cockpit reverse-proxy / signed TLS cert** — self-signed default is fine for dev; users can drop a cert under `/etc/cockpit/ws-certs.d/` per-host (un-tracked, per the existing per-host override pattern).
- **Dozzle `users.yml`** — Dozzle has no auth by default; enabling `DOZZLE_AUTH_PROVIDER=simple` + adding `/etc/dozzle/users.yml` is opt-in and outside this design (only matters if `DOZZLE_BIND` is moved off `127.0.0.1`).
- **Cockpit `cockpit-machines` / libvirt** — only useful if libvirtd is already provisioned (it isn't).
- **Windows side** — Cockpit is Linux-only; Dozzle is also Linux-side (the Docker image runs where Docker runs). Nothing for the WezTerm GUI host.
- **chezmoi-template-driven config** — `cockpit.conf` and `dozzle.env` are plain INI/env, not `.tmpl`. If per-host variation becomes necessary, escalate to a chezmoi-style template in `configs/<tool>/*.tmpl` rendered by a new lib helper, but defer until a concrete need shows up.

## Open questions

None at design time; both flagged questions resolved during brainstorming.

## Implementation plan

To be authored in a follow-up via the `writing-plans` skill — see `docs/superpowers/plans/2026-05-25-dozzle-cockpit-plan.md` (forthcoming).
