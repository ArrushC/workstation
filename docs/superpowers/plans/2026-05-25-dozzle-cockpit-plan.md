# Dozzle + Cockpit on dev_machine — Implementation Plan (revised)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Dozzle (Docker log viewer, run as a container via systemd) and Cockpit (web admin console, dnf packages) to the `dev_machine` provisioning path, with tracked system-scope (`/etc/`) configuration via a new top-level `configs/` directory.

**Architecture:** Two paired configure-service flows. **Dozzle** runs as a Docker container managed by a systemd unit; the tracked env file (`configs/dozzle/dozzle.env`) declares `DOZZLE_IMAGE`, `DOZZLE_BIND`, and Dozzle-app env vars, with a `@DOZZLE_VERSION@` placeholder substituted from `$(DOZZLE_VERSION)` at install time so `versions.mk` stays the single source of truth. **Cockpit** dnf packages join `LINUX_OPTIONAL_PACKAGES` in `packages.mk`, then a `cockpit-service` make target enables `cockpit.socket`, opens firewalld, and deploys `cockpit.conf`. Both service targets are dev-only via `ifeq ($(MODE),dev)` gates and use stamp-based idempotency.

**Tech Stack:** GNU Make + bash + systemd + firewalld + dnf + Docker (assumed-present). No new languages or build tools.

**Spec:** `docs/superpowers/specs/2026-05-25-dozzle-cockpit-design.md` (revised — see the spec's "Revision history" section for the binary→Docker pivot rationale).

**Revision note:** Earlier iterations of this plan registered Dozzle as an `EGET_TOOL` binary install in `tools.mk`. Verification during execution confirmed Dozzle's 10.x line publishes **zero** GitHub release assets (Docker-only distribution). The bad commit (`a4c99c4`) was reverted (`9bd50dd`), spec + plan updated. The originally-completed Task 1 (which created `configs/dozzle/*` with binary-pointing content) is **superseded by Task 1' below** which rewrites those files in place to the Docker shape.

**Dozzle Docker image tag pinned at plan time:** `10.6.1` (latest from `amir20/dozzle` at the time of writing).

---

## File map (revised)

**Already created (by superseded Task 1 — see Task 1' below for the fix-up commit):**
- `configs/dozzle/dozzle.service` — currently holds the binary-shaped unit; will be rewritten to a Docker-wrapper unit
- `configs/dozzle/dozzle.env` — currently holds binary-shaped vars (DOZZLE_ADDR etc.); will be rewritten with Docker-aware vars + the `@DOZZLE_VERSION@` placeholder
- `configs/cockpit/cockpit.conf` — unchanged

**Modify:**
- `makefile/versions.mk` — add `DOZZLE_VERSION := 10.6.1` in a new "Service / web admin" group (commented as a Docker image tag, not a binary version)
- `makefile/packages.mk` — extend `LINUX_OPTIONAL_PACKAGES` with the six Cockpit packages
- `makefile/Makefile` — add `dozzle-service` (Docker-shape) + `cockpit-service` bespoke rules alongside `claude-cli` / `node-runtime` / `claude-statusline`; extend `provision` dev-only deps; update `make list` + `make help`
- `README.html` — new "Web admin" tool-card under `#stack > toolbelt`, two new troubleshooting accordion entries, new `#daily-services` subsection
- `CLAUDE.md` — new row in "Where things are documented", new load-bearing invariant for the `configs/` pattern, three new "Files Claude should be careful with" entries, four new verification recipes
- `CLAUDE_CHANGELOG.md` — one new row

**Do NOT touch:**
- `makefile/tools.mk` — Dozzle is no longer a tool. The previous plan added an `EGET_TOOL` line here; the revert removed it. Don't re-add.
- `chezmoi/` — chezmoi continues to own `$HOME` exclusively
- `bootstrap.sh` / `bootstrap.ps1` / `scripts/` — no entry-point changes needed
- `makefile/scope.mk` — `MODE`/`SUDO`/`DEST` semantics unchanged

---

## Verification recipes (referenced from multiple tasks)

**A. Dry-run + listing checks (no sudo, no real install — run from `makefile/`):**
```bash
cd makefile

# Dozzle is NOT in scope-tools in the revised design (it's not an EGET_TOOL)
make list MODE=dev | grep -E '^\s+dozzle$' && echo FAIL || echo OK

# Both services appear under provision (after Tasks 4 + 5 + 6)
make -n MODE=dev provision  | grep -E '(dozzle-service|cockpit-service)'

# Neither service runs under prod
make -n MODE=prod provision | grep -E '(dozzle-service|cockpit-service)' && echo FAIL || echo OK

# Both modes parse without error
make -n MODE=dev provision  > /dev/null
make -n MODE=prod provision > /dev/null

# list shows the services block
make list MODE=dev | grep -E 'dozzle-service|cockpit-service'

# help shows both
make help | grep -E 'dozzle-service|cockpit-service' | wc -l   # 2
```

**B. Docker image pull smoke test (validates the pin is fetchable; needs network + docker):**
```bash
docker pull amir20/dozzle:10.6.1
docker image inspect amir20/dozzle:10.6.1 | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['RepoTags'])"
# Expected: ['amir20/dozzle:10.6.1']
```
*(Skip this step if docker is not installed locally; the real install verification is Reference C on an actual dev_machine.)*

**C. Real dev_machine end-to-end (requires sudo + systemd + firewalld + Docker — run on an actual dev host):**
```bash
cd makefile && sudo make MODE=dev dozzle-service cockpit-service

systemctl status dozzle.service cockpit.socket             # both active
docker ps --filter name=dozzle --format '{{.Image}}'        # amir20/dozzle:10.6.1
ss -tlnp | grep -E ':(8080|9090)'                          # 8080 on 127.0.0.1, 9090 on ::/0
sudo firewall-cmd --list-services | grep -q cockpit && echo "firewall ok"
journalctl -u dozzle -n 20 --no-pager                       # no errors
curl -sI  http://127.0.0.1:8080 | head -1                   # HTTP/1.1 200 OK
curl -skI https://127.0.0.1:9090 | head -1                   # HTTP/1.1 200 OK
```

**D. README round-trip:**
```bash
# Asset paths intact
grep -c 'href="docs/README/README.css"' README.html  # 1
grep -c 'src="docs/README/README.js"'   README.html  # 1
# Visual check: open README.html in a browser — Dozzle + Cockpit chips visible in new "Web admin" card,
# new troubleshooting entries reachable via accordion filter.
```

---

## Task 1' (REVISED): Rewrite `configs/dozzle/*` to Docker-wrapper shape

**Files:**
- Modify: `configs/dozzle/dozzle.service` — replace binary-shape unit with Docker-wrapper unit
- Modify: `configs/dozzle/dozzle.env` — replace `DOZZLE_ADDR` etc. with `DOZZLE_IMAGE` (with `@DOZZLE_VERSION@` placeholder) + `DOZZLE_BIND` + per-tunable env vars

These files were created by the original Task 1 commit (`8f1d82a`) with binary-shaped content. This task rewrites them in place — no file additions/deletions.

- [ ] **Step 1: Pre-condition check**

Run from repo root:
```bash
grep -c 'ExecStart=/usr/local/bin/dozzle' configs/dozzle/dozzle.service   # 1
grep -c 'DOZZLE_ADDR' configs/dozzle/dozzle.env                            # 1
```
Expected: both `1`. (Confirms we're starting from the binary-shape content.)

- [ ] **Step 2: Replace `configs/dozzle/dozzle.service` with the Docker-wrapper unit**

Write the file with exactly this content (overwriting):

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

- [ ] **Step 3: Replace `configs/dozzle/dozzle.env`**

Write the file with exactly this content (overwriting):

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

- [ ] **Step 4: Post-condition check**

```bash
grep -c 'ExecStart=/usr/bin/docker run' configs/dozzle/dozzle.service   # 1
grep -c '@DOZZLE_VERSION@' configs/dozzle/dozzle.env                    # 1
grep -c 'DOZZLE_BIND=127.0.0.1' configs/dozzle/dozzle.env               # 1
grep -c 'Requires=docker.service' configs/dozzle/dozzle.service         # 1
file configs/dozzle/dozzle.service configs/dozzle/dozzle.env             # LF, no CRLF
```

- [ ] **Step 5: Commit (batched with the spec + plan revisions — see commit guidance below)**

This task is part of a single "switch Dozzle to Docker" rework commit that also carries the spec + plan revisions made by the controller. The expected commit:

```bash
git add docs/superpowers/specs/2026-05-25-dozzle-cockpit-design.md \
        docs/superpowers/plans/2026-05-25-dozzle-cockpit-plan.md \
        configs/dozzle/dozzle.service \
        configs/dozzle/dozzle.env
git commit -m "$(cat <<'EOF'
refactor(dozzle): switch to Docker-managed-by-systemd

Dozzle's 10.x line publishes zero GitHub release binaries — distribution
is Docker-only (verified across v10.0.5..v10.6.1). The binary-based
EGET_TOOL approach was reverted in 9bd50dd; this commit lands the
Docker-based replacement.

  - configs/dozzle/dozzle.service: docker run wrapper. Pre-flight cleans
    leftover containers; ExecStart runs the image in foreground so
    systemd owns the lifecycle; Requires=docker.service makes the
    dependency loud.
  - configs/dozzle/dozzle.env: declares DOZZLE_IMAGE (with @DOZZLE_VERSION@
    placeholder substituted from $(DOZZLE_VERSION) at install time),
    DOZZLE_BIND=127.0.0.1, and the Dozzle-app env vars.
  - spec + plan updated with revision history.

No EGET_TOOL entry in tools.mk (Dozzle isn't a $(DEST) binary). The
dozzle-service make target (next commit) owns the install: it sed-
substitutes the placeholder and drops both files into /etc/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2 (REVISED): Pin `DOZZLE_VERSION` in `versions.mk`

**Files:**
- Modify: `makefile/versions.mk` — add `DOZZLE_VERSION := 10.6.1` in a new group

No `tools.mk` change in the revised design.

- [ ] **Step 1: Pre-condition check**

Run: `grep -c DOZZLE_VERSION makefile/versions.mk`
Expected: `0` (the original Task 2 commit was reverted; pin is gone).

- [ ] **Step 2: Edit `makefile/versions.mk`**

Append after the last existing line (currently `NODE_VERSION := 24.16.0` under `# --- Claude Code CLI ---`):

```make

# --- Service / web admin (dev_machine only) ---------------------------------
# Dozzle is run as a Docker container via systemd (no native binary —
# upstream publishes Docker images only). The value below pins the Docker
# image tag (amir20/dozzle:$(DOZZLE_VERSION)). The dozzle-service make
# target sed-substitutes it into the deployed /etc/dozzle/dozzle.env;
# bumping invalidates the dozzle-service stamp so the next `make dev`
# re-renders the env file, re-pulls the image, and restarts the unit.
# Cockpit comes from dnf (see packages.mk) and isn't versioned here.
DOZZLE_VERSION := 10.6.1
```

- [ ] **Step 3: Post-condition check**

```bash
grep -c '^DOZZLE_VERSION := 10.6.1$' makefile/versions.mk   # 1
cd makefile && make -n MODE=dev provision > /dev/null && echo OK
cd makefile && make -n MODE=prod provision > /dev/null && echo OK
# Confirm dozzle is NOT in scope-tools (no EGET_TOOL entry)
make list MODE=dev | grep -E '^\s+dozzle$' && echo FAIL || echo OK
```

- [ ] **Step 4: Commit**

```bash
git add makefile/versions.mk
git commit -m "$(cat <<'EOF'
feat(makefile): pin DOZZLE_VERSION as Docker image tag (10.6.1)

Single-source-of-truth pin for the amir20/dozzle Docker image tag,
substituted into /etc/dozzle/dozzle.env by the dozzle-service make
target (next commit). No tools.mk EGET_TOOL — Dozzle is a container,
not a binary.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add Cockpit packages to `LINUX_OPTIONAL_PACKAGES`

*(unchanged from previous plan)*

**Files:**
- Modify: `makefile/packages.mk` — extend `LINUX_OPTIONAL_PACKAGES` block

- [ ] **Step 1: Pre-condition check**

Run: `grep -c cockpit makefile/packages.mk`
Expected: `0`

- [ ] **Step 2: Edit `makefile/packages.mk`**

Locate `LINUX_OPTIONAL_PACKAGES :=` block (lines ~33-39). Append two new lines so the block becomes:

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

- [ ] **Step 3: Post-condition check**

```bash
cd makefile && make -n MODE=dev packages-optional | grep -oE 'cockpit[a-z-]*' | sort -u
# Expected: cockpit, cockpit-networkmanager, cockpit-packagekit, cockpit-podman, cockpit-storaged, cockpit-system (6 lines)

make -n MODE=prod provision > /dev/null && echo OK
```

- [ ] **Step 4: Commit**

```bash
git add makefile/packages.mk
git commit -m "$(cat <<'EOF'
feat(packages): add Cockpit packages to optional dev-only set

cockpit + cockpit-system + cockpit-storaged + cockpit-networkmanager +
cockpit-packagekit + cockpit-podman. Joins the existing LINUX_OPTIONAL_
PACKAGES list (INSTALL_PACKAGES=true gated, i.e. dev-only). Per-package
`|| true` in packages-optional handles RHEL minor versions where
cockpit-podman lives in EPEL vs AppStream.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 (REVISED): Add `dozzle-service` make target (Docker shape)

**Files:**
- Modify: `makefile/Makefile` (add bespoke rule alongside `claude-cli` / `node-runtime`)

The previous plan's Task 4 declared an order-only stamp-on-stamp dep on the dozzle binary stamp; that no longer exists. The revised rule runs a `command -v docker` sanity check at the top instead, and uses `sed` to substitute `@DOZZLE_VERSION@` in the env file at install time.

- [ ] **Step 1: Pre-condition check**

Run: `cd makefile && make -n dozzle-service MODE=dev 2>&1 | head -1`
Expected: `make: *** No rule to make target 'dozzle-service'.  Stop.`

- [ ] **Step 2: Edit `makefile/Makefile`**

Insert the following block immediately after the existing `claude-statusline` rule (currently ends with `endif` around line 165), before `include packages.mk`:

```make
# -----------------------------------------------------------------------------
# dozzle-service — install systemd unit + env file, pull image, enable + start.
#   - dev_machine only (recipe body gated on MODE=dev).
#   - Env file is templated: `@DOZZLE_VERSION@` in configs/dozzle/dozzle.env
#     is substituted with $(DOZZLE_VERSION) at install time via sed. Keeps
#     versions.mk as the single source of truth for the image tag.
#   - Stamp encodes $(DOZZLE_VERSION); bumping the pin invalidates the
#     stamp so the next `make dev` re-renders dozzle.env, re-pulls the
#     image, and restarts the unit.
#   - Sanity-checks `command -v docker` at the top of the recipe (this
#     repo doesn't install Docker; lazydocker/dive/ctop already assume
#     it). Loud failure with a clear message if Docker is missing.
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

```

**Critical:** Recipe lines (the `@printf`, `@$(SUDO)`, etc.) MUST be tab-indented, not spaces — Makefile invariant. The `sed | install /dev/stdin /etc/dozzle/dozzle.env` pipeline uses `install`'s ability to read from stdin (POSIX-portable, used in other distro packagers).

- [ ] **Step 3: Post-condition check**

```bash
cd makefile

# dev: dry-run should print the install commands AND the sed pipeline
make -n dozzle-service MODE=dev | grep -E '(sed.*DOZZLE_VERSION|install -m|systemctl)'

# prod: must print the skip message
make dozzle-service MODE=prod

# provision parses cleanly
make -n MODE=dev provision > /dev/null && echo OK
```

- [ ] **Step 4: Commit**

```bash
git add makefile/Makefile
git commit -m "$(cat <<'EOF'
feat(makefile): add dozzle-service target (docker + systemd)

Bespoke rule alongside claude-cli / node-runtime / claude-statusline.
Sed-substitutes @DOZZLE_VERSION@ in configs/dozzle/dozzle.env from
$(DOZZLE_VERSION), installs both files into /etc/, daemon-reload,
enable --now. Recipe sanity-checks command -v docker at the top.
Dev-only; prod prints a skip message. Not yet wired into provision —
that's the wiring commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `cockpit-service` make target

*(unchanged from previous plan)*

**Files:**
- Modify: `makefile/Makefile` (add bespoke rule below dozzle-service)

- [ ] **Step 1: Pre-condition check**

Run: `cd makefile && make -n cockpit-service MODE=dev 2>&1 | head -1`
Expected: `make: *** No rule to make target 'cockpit-service'.  Stop.`

- [ ] **Step 2: Edit `makefile/Makefile`**

Insert immediately after the `dozzle-service` block from Task 4, still before `include packages.mk`:

```make
# -----------------------------------------------------------------------------
# cockpit-service — install cockpit.conf, enable cockpit.socket, open firewalld.
#   - dev_machine only (recipe body gated on MODE=dev).
#   - CANNOT depend on the `packages` phony (would break `make -j8`).
#     packages.mk doesn't produce a stamp file either, so there's no stamp
#     to order-only-depend on. Instead the recipe sanity-checks
#     `rpm -q cockpit` and aborts with a clear message if the package
#     isn't installed yet. Correct under both serial and -j make.
#   - Stamp has no version suffix; Cockpit's package version comes from dnf.
#   - firewalld step skipped (with a message) when firewalld is inactive.
# -----------------------------------------------------------------------------
.PHONY: cockpit-service clean-cockpit-service
ifeq ($(MODE),dev)
cockpit-service: $(STAMP)/cockpit-service.done
$(STAMP)/cockpit-service.done:
	@printf '==> cockpit-service (socket + firewall + conf)\n'
	@if ! rpm -q cockpit >/dev/null 2>&1; then \
	   printf '  ERROR: cockpit package not installed. Run `make MODE=dev packages` first,\n' >&2; \
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

**Critical:** Tab-indented recipe lines. No `define` wrapper, so single `$` (not `$$`) is correct.

- [ ] **Step 3: Post-condition check**

```bash
cd makefile
make -n cockpit-service MODE=dev | grep -E '(install -m|systemctl enable|firewall-cmd)'
make cockpit-service MODE=prod  # must print skip
make -n MODE=dev provision > /dev/null && echo OK
```

- [ ] **Step 4: Commit**

```bash
git add makefile/Makefile
git commit -m "$(cat <<'EOF'
feat(makefile): add cockpit-service target (socket + firewall + conf)

Bespoke rule, twin to dozzle-service. Installs configs/cockpit/cockpit.conf
into /etc/cockpit/, systemctl enable --now cockpit.socket, opens firewalld
cockpit service if firewalld is active. Runtime rpm -q cockpit check at
the top of the recipe (packages.mk produces no stamp to order-on);
correct under make -j. Dev-only; prod prints a skip message. Wiring into
provision lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 (REVISED): Wire both services into `provision`, update `make list` + `make help`

The only revision vs. the previous plan is that the new `services:` block in `make list` doesn't include Dozzle anywhere else — Dozzle is not a SCOPE_TOOL.

**Files:**
- Modify: `makefile/Makefile`

- [ ] **Step 1: Pre-condition check**

```bash
cd makefile
make -n MODE=dev provision | grep -E '(dozzle-service|cockpit-service)' && echo FAIL || echo OK
```
Expected: `OK` (services exist as standalone targets after Tasks 4-5, but `provision` doesn't depend on them yet).

- [ ] **Step 2: Extend `provision`'s dev-only deps**

Locate the existing dev-only deps block (around line 189-192):
```make
provision: packages tools user-tools shell dotfiles
ifeq ($(MODE),dev)
provision: claude-cli node-runtime
endif
```

Modify to:
```make
provision: packages tools user-tools shell dotfiles
ifeq ($(MODE),dev)
provision: claude-cli node-runtime dozzle-service cockpit-service
endif
```

- [ ] **Step 3: Update `make list` recipe**

Locate the existing `list:` recipe (around lines 206-211):
```make
list:
	@printf 'scope-tools (%d):\n' $(words $(SCOPE_TOOLS))
	@printf '  %s\n' $(sort $(SCOPE_TOOLS))
	@printf '\nuser-tools (%d):\n' $(words $(USER_TOOLS))
	@printf '  %s\n' $(sort $(USER_TOOLS))
	@printf '\nclaude-cli (provisioned on MODE=dev only)\n'
```

Replace with:
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

- [ ] **Step 4: Update `make help` recipe**

In the `help:` recipe, locate "Tool installs (scope-aware via MODE):" block. Add two new lines after `make claude-cli`:

```make
	@echo "  make dozzle-service   install dozzle systemd unit + start service (dev only)"
	@echo "  make cockpit-service  install cockpit.conf + enable socket + open firewall (dev only)"
```

Full block becomes:
```make
	@echo "Tool installs (scope-aware via MODE):"
	@echo "  make all          install every scope-aware tool (use -j8 for parallelism)"
	@echo "  make user-tools   install pip user-site tools (glances, asciinema, harlequin)"
	@echo "  make claude-cli   install the Claude Code CLI"
	@echo "  make dozzle-service   install dozzle systemd unit + start service (dev only)"
	@echo "  make cockpit-service  install cockpit.conf + enable socket + open firewall (dev only)"
	@echo "  make <tool>       install just one tool, e.g. make gitui"
	@echo "  make clean-<tool> wipe stamp (+ binary for scope tools)"
	@echo "  make list         list every managed tool, grouped"
	@echo "  make clean        wipe all stamps (forces full reinstall next run)"
```

- [ ] **Step 5: Post-condition check (Reference A)**

```bash
cd makefile
make list MODE=dev | grep -E '^\s+dozzle$' && echo FAIL || echo OK   # dozzle NOT in scope-tools
make list MODE=dev | grep -E 'dozzle-service|cockpit-service' | wc -l    # 2 (services block)
make -n MODE=dev  provision | grep -E '(dozzle-service|cockpit-service)' | wc -l    # >= 2
make -n MODE=prod provision | grep -E '(dozzle-service|cockpit-service)' && echo FAIL || echo OK
make help | grep -E '(dozzle-service|cockpit-service)' | wc -l    # 2
```

- [ ] **Step 6: Commit**

```bash
git add makefile/Makefile
git commit -m "$(cat <<'EOF'
feat(makefile): wire dozzle-service + cockpit-service into provision

Both join provision's dev-only deps. Adds a new 'services' block to
make list and two new lines to make help. After this commit, plain
`make dev` on a clean host with Docker present installs Dozzle (image
pull + systemd unit, localhost-bound) and Cockpit (dnf packages +
socket + firewalld).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update `README.html` (user-facing surface)

*(text mostly unchanged from previous plan — only the troubleshooting entry for Dozzle is updated to reflect the new "Docker required" failure mode)*

**Files:**
- Modify: `README.html`

- [ ] **Step 1: Pre-condition check**

`grep -c -i 'dozzle\|cockpit' README.html` → `0`

- [ ] **Step 2: Add a new "Web admin" tool-card to the toolbelt**

Locate the existing "Containers" tool-card (starts around line 714 with `data-cat="containers"`, ends ~line 752 with `</article>`). After that closing `</article>` and before the "Data / SQL" article, insert:

```html
                        <article
                            class="tool-card cat-containers"
                            data-cat="containers"
                        >
                            <h4>Web admin (dev_machine only)</h4>
                            <div class="chips">
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="Real-time Docker log viewer (container; localhost:8080, SSH-tunnel to access)"
                                    >dozzle<span class="sr-only">
                                        — real-time Docker log viewer
                                        (containerized; localhost:8080,
                                        SSH-tunnel to access)</span
                                    ></span
                                >
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="Web admin console — services, journal, storage, network, podman, packages (https://host:9090, PAM auth)"
                                    >cockpit<span class="sr-only">
                                        — web admin console: services,
                                        journal, storage, network, podman,
                                        packages (https://host:9090, PAM
                                        auth)</span
                                    ></span
                                >
                            </div>
                        </article>

```

- [ ] **Step 3: Add two troubleshooting accordion entries**

Locate `<section id="troubleshooting">` (around line 2538). Inside, find an existing `<details>` to mirror its attributes, then add two new ones:

```html
                    <details>
                        <summary>
                            <strong>Cockpit login fails — “Permission denied”</strong>
                        </summary>
                        <p>
                            Cockpit auths via PAM against local user accounts
                            — your account must have a password set. SSH-key-
                            only accounts can't log in to the Cockpit web UI.
                            Fix: <code>sudo passwd $USER</code> on the host,
                            then retry. (You'll still want to keep SSH on
                            keys; this password is only for the Cockpit
                            login form.)
                        </p>
                    </details>

                    <details>
                        <summary>
                            <strong>Dozzle fails to start — “docker not found” /
                                container won't pull</strong>
                        </summary>
                        <p>
                            Dozzle runs as a Docker container, so the host
                            must have Docker (or Podman with a Docker shim).
                            <code>make dozzle-service</code> fails loud
                            with a “docker not installed” message when
                            <code>command -v docker</code> returns nothing.
                            Install Docker via your distro's instructions,
                            then re-run <code>make dozzle-service</code>.
                            If Docker is installed but the
                            <code>docker pull amir20/dozzle:&lt;tag&gt;</code>
                            step fails, check
                            <code>journalctl -u dozzle -n 30</code> — likely
                            a registry-rate-limit or DNS issue.
                        </p>
                    </details>

```

- [ ] **Step 4: Add daily-workflows mentions**

Locate `<section id="daily">` (~line 2185). After the existing content (but inside the section), add:

```html
                    <h3 id="daily-services">Web admin services (dev_machine)</h3>
                    <ul>
                        <li>
                            <strong>Cockpit</strong> — open
                            <code>https://&lt;host&gt;:9090</code> in a
                            browser; log in with your Linux user account
                            (PAM). Self-signed cert on first hit — accept
                            the warning. Covers services, journal,
                            storage, network, packages, podman.
                        </li>
                        <li>
                            <strong>Dozzle</strong> — runs as a Docker
                            container managed by systemd; bound to
                            localhost. SSH-tunnel to view:
                            <code>ssh -L 8080:localhost:8080 &lt;host&gt;</code>,
                            then
                            <code>http://localhost:8080</code> on your
                            workstation. Real-time Docker container logs.
                            Bump the pinned image tag by editing
                            <code>DOZZLE_VERSION</code> in
                            <code>makefile/versions.mk</code>; the next
                            <code>make dev</code> re-pulls and restarts
                            the unit.
                        </li>
                    </ul>

```

- [ ] **Step 5: Post-condition check**

```bash
grep -c -i 'dozzle' README.html         # >= 4
grep -c -i 'cockpit' README.html        # >= 4
grep -c 'href="docs/README/README.css"' README.html   # 1 (asset paths intact)
grep -c 'src="docs/README/README.js"'   README.html   # 1
```

Then open `README.html` in a browser — verify the new card renders, troubleshooting filter finds new entries.

- [ ] **Step 6: Commit (deferred to Task 8 — batched)**

Do NOT commit yet. Task 8 batches README.html + CLAUDE.md + CLAUDE_CHANGELOG.md into one commit (per the repo's docs-update convention — the CLAUDE_CHANGELOG row references the README update in the same commit).

---

## Task 8: Update `CLAUDE.md` + `CLAUDE_CHANGELOG.md`, batched commit

**Files:**
- Modify: `CLAUDE.md`
- Modify: `CLAUDE_CHANGELOG.md`

- [ ] **Step 1: Add a row to the "Where things are documented" table in `CLAUDE.md`**

Append to the bottom of the existing table:

```markdown
| Dozzle + Cockpit web admin (dev_machine only) | `README.html` §stack > Web admin card; §troubleshooting; §daily-services |
```

- [ ] **Step 2: Add a new load-bearing invariant to `CLAUDE.md`**

Append to the "Load-bearing invariants" section:

```markdown
- **`configs/` is sudo-installed to `/etc/`, NOT chezmoi-managed.** Files under `configs/<tool>/` are deployed by paired `<tool>-service` make targets (see `makefile/Makefile`) via `sudo install -m 0644 ../configs/<tool>/<file> /etc/<dest>`. Chezmoi continues to own `$HOME` exclusively — don't try to migrate `configs/` files under `chezmoi/`. The pattern exists because chezmoi has no facility for system-scope (`/etc/`) destinations. Currently used by `dozzle-service` (`configs/dozzle/dozzle.service` + `.env`) and `cockpit-service` (`configs/cockpit/cockpit.conf`). For the Dozzle env file specifically, the recipe sed-substitutes `@DOZZLE_VERSION@` from `$(DOZZLE_VERSION)` so `versions.mk` remains the single source of truth for the Docker image tag. To add a new system service, create a `configs/<tool>/` directory and a matching `<tool>-service` bespoke rule in `makefile/Makefile`.
```

- [ ] **Step 3: Add three new "Files Claude should be careful with" entries to `CLAUDE.md`**

Append to that section:

```markdown
- **`configs/dozzle/dozzle.service`** — systemd unit deployed by `dozzle-service` make target into `/etc/systemd/system/`. Wraps `docker run amir20/dozzle:${DOZZLE_IMAGE}` in the foreground; `Requires=docker.service` couples Dozzle's lifecycle to Docker's. Hand-editing the deployed copy on a host is futile — the next `make dozzle-service MODE=dev` run overwrites it. Edits belong in this tracked file; a re-run picks them up via the version-stamped re-trigger (bumping `DOZZLE_VERSION` in `versions.mk`, or `make clean-dozzle-service` to force).
- **`configs/dozzle/dozzle.env`** — env vars consumed by `EnvironmentFile=` in the unit; deployed to `/etc/dozzle/dozzle.env` *with* `@DOZZLE_VERSION@` substituted from `$(DOZZLE_VERSION)`. **Don't hand-edit the `@DOZZLE_VERSION@` placeholder** in this source file — that'd break the substitution. To bump the image tag, edit `DOZZLE_VERSION` in `makefile/versions.mk`. `DOZZLE_BIND=127.0.0.1` is load-bearing — flipping to `0.0.0.0` exposes the unauthenticated log viewer on the LAN. If you change it, also configure `DOZZLE_AUTH_PROVIDER=simple` and create `/etc/dozzle/users.yml`.
- **`configs/cockpit/cockpit.conf`** — INI consumed by `cockpit-ws`; deployed to `/etc/cockpit/cockpit.conf`. Currently minimal (only `LoginTitle` + `MaxStartups`); `Origins` is left as a commented worked-example. If you uncomment `Origins`, every hostname you'll reach Cockpit from must be listed — Cockpit rejects cross-origin connections by default.
```

- [ ] **Step 4: Append to the "Quick verification" section of `CLAUDE.md`**

Append:

```markdown
- `cd makefile && make list MODE=dev` — `services` block lists `dozzle-service` + `cockpit-service`. Dozzle is NOT in scope-tools (no EGET_TOOL).
- `cd makefile && make -n MODE=dev provision | grep -E '(dozzle-service|cockpit-service)'` — both targets fire (2+ matched lines).
- `cd makefile && make -n MODE=prod provision | grep -E '(dozzle-service|cockpit-service)'` — no matches (services are dev-only).
- On a real dev_machine after `make dev` (Docker required): `systemctl status dozzle.service cockpit.socket` shows both active; `docker ps --filter name=dozzle --format '{{.Image}}'` shows the pinned tag; `ss -tlnp | grep -E ':(8080|9090)'` shows 8080 on `127.0.0.1` and 9090 on `::/0`; `curl -sI http://127.0.0.1:8080 | head -1` returns `HTTP/1.1 200 OK`.
```

- [ ] **Step 5: Append a row to `CLAUDE_CHANGELOG.md`**

Append at the bottom of the table:

```markdown
| Added Dozzle (real-time Docker log viewer, run as a container via systemd — `configs/dozzle/dozzle.service` wraps `docker run amir20/dozzle:$(DOZZLE_VERSION)`, with the image tag sed-substituted into `/etc/dozzle/dozzle.env` from `versions.mk`; localhost-bound) and Cockpit (web admin console, dnf packages + tracked `cockpit.conf` + firewalld open) to `dev_machine` provisioning. New top-level `configs/` directory for sudo-installed `/etc/` files (chezmoi owns `$HOME` only); paired `dozzle-service` + `cockpit-service` bespoke make targets join `provision`'s dev-only deps. Cockpit packages (`cockpit cockpit-system cockpit-storaged cockpit-networkmanager cockpit-packagekit cockpit-podman`) added to `LINUX_OPTIONAL_PACKAGES`. Initial design picked an EGET_TOOL binary install for Dozzle; verification showed Dozzle's 10.x releases publish zero binary assets (Docker-only), so the binary commit was reverted and the design pivoted to Docker-managed-by-systemd (see spec revision history). | **Yes** | New "Web admin" tool-card under `#stack > toolbelt` (chips for dozzle + cockpit, tagged `data-cat="containers"`). Two new troubleshooting entries: Cockpit PAM password requirement, Dozzle Docker prerequisite + image-pull failures. New `#daily > daily-services` subsection with the `https://host:9090` (Cockpit) and `ssh -L 8080:localhost:8080` (Dozzle) access patterns. CLAUDE.md gains the new `configs/` load-bearing invariant, three new file-care entries (`dozzle.service`, `dozzle.env`, `cockpit.conf`), and four new verification recipe lines. |
```

- [ ] **Step 6: Post-condition check**

```bash
grep -c 'configs/' CLAUDE.md           # >= 4
grep -c -i 'dozzle\|cockpit' CLAUDE.md # >= 6
grep -c 'Dozzle' CLAUDE_CHANGELOG.md   # 1
grep -c 'docker run' configs/dozzle/dozzle.service  # 1 (sanity-check)
grep -c '@DOZZLE_VERSION@' configs/dozzle/dozzle.env # 1
```

- [ ] **Step 7: Commit (batches Task 7 + Task 8)**

```bash
git add README.html CLAUDE.md CLAUDE_CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: Dozzle + Cockpit user-facing surface (README/CLAUDE/CHANGELOG)

README.html: new 'Web admin' tool-card with dozzle + cockpit chips,
two new troubleshooting entries (Cockpit PAM password requirement,
Dozzle's Docker prerequisite + image-pull failure modes), new
#daily-services subsection covering https://host:9090 and the
SSH-tunnel pattern for Dozzle.

CLAUDE.md: new 'configs/' load-bearing invariant (sudo-installed /etc/
files, NOT chezmoi-managed; sed-templated DOZZLE_VERSION), three new
file-care entries, four new verification recipes.

CLAUDE_CHANGELOG.md: one new row capturing the surface change, including
the binary→Docker pivot.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Final cross-check (no new commits)

- [ ] **Step 1: Replay Reference A** (dry-run + listing — see top of plan)
- [ ] **Step 2: Replay Reference B** (docker pull smoke — skip if no local docker)
- [ ] **Step 3: File-integrity check**

```bash
file configs/dozzle/dozzle.service configs/dozzle/dozzle.env configs/cockpit/cockpit.conf
# All "ASCII text" or "UTF-8 Unicode text" — NEVER "with CRLF line terminators"

git ls-files --stage scripts/ makefile/lib/ | awk '$1 != "100755"' | grep -v '\.md$\|README'
# Empty (no executable-bit drift)
```

- [ ] **Step 4: Reference D** (README asset paths)
- [ ] **Step 5: Manual browser check** (cannot be automated — see Reference D)
- [ ] **Step 6: Reference C — real dev_machine end-to-end** (requires actual host with Docker + sudo + systemd + firewalld; flag results; if any fails, file a follow-up fix commit rather than amending)

---

## Self-review (executed at plan-rewrite time)

**1. Spec coverage** (revised spec):
- §1 (version pin, Docker image tag) → Task 2 ✓
- §2 (no tool registration) → explicitly NOT in plan ✓
- §3 (Cockpit packages) → Task 3 ✓
- §4 (configs/ contents — Docker shape) → Task 1' ✓
- §5 (make targets — Docker shape) → Tasks 4 (revised) + 5 ✓
- §6 (provision wiring + list/help) → Task 6 (revised) ✓
- §7 (README/CLAUDE/CHANGELOG) → Tasks 7 + 8 ✓
- §8 (verification) → Reference A/B/C/D + Task 9 ✓

**2. Placeholder scan:** None. Every code block is a literal artifact.

**3. Type consistency:** Make variables (`DOZZLE_VERSION`, `STAMP`, `SUDO`, `DEST`), env file vars (`DOZZLE_IMAGE`, `DOZZLE_BIND`, `DOZZLE_LEVEL`, `DOZZLE_NO_ANALYTICS`), file paths (`/etc/dozzle/dozzle.env`, `/etc/dozzle/dozzle.service` → corrected to `/etc/systemd/system/dozzle.service`), and substitution token (`@DOZZLE_VERSION@`) are consistent across spec + plan + tracked files.

**4. Test ordering:** Pre-condition → edit → post-condition → commit, same TDD shape as before.

**5. Commit cadence:** 6 implementation commits after the rework (Tasks 1', 2, 3, 4, 5, 6, 7+8 batched). Plus 1 rework commit covering spec/plan/configs together. Total 8 commits on top of the existing 4 (spec, plan, configs/, revert). Final history is honest about the pivot.
