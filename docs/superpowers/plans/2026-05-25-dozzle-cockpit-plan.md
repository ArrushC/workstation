# Dozzle + Cockpit on dev_machine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Dozzle (Docker log viewer, standalone binary) and Cockpit (web admin console, dnf packages) to the `dev_machine` provisioning path, with tracked system-scope (`/etc/`) configuration via a new top-level `configs/` directory.

**Architecture:** Two paired install-binary + configure-service flows. Dozzle: `EGET_TOOL` in `tools.mk` installs the binary, then a new `dozzle-service` make target drops a systemd unit + env file from `configs/dozzle/`. Cockpit: dnf packages join `LINUX_OPTIONAL_PACKAGES` in `packages.mk`, then a new `cockpit-service` make target enables the socket, opens firewalld, and drops a tracked `cockpit.conf`. Both service targets are dev-only via `ifeq ($(MODE),dev)` gates. The pattern reuses the existing stamp-based idempotency (`$(STAMP)/<target>.done`).

**Tech Stack:** GNU Make + bash + systemd + firewalld + dnf. No new languages or build tools.

**Spec:** `docs/superpowers/specs/2026-05-25-dozzle-cockpit-design.md` (commit `950aabe`)

**Dozzle version pinned at plan time:** `10.6.1` (verified via `gh release view --repo amir20/dozzle`).

---

## File map

**Create:**
- `configs/dozzle/dozzle.service` — systemd unit deployed to `/etc/systemd/system/`
- `configs/dozzle/dozzle.env` — env vars deployed to `/etc/dozzle/dozzle.env`
- `configs/cockpit/cockpit.conf` — INI config deployed to `/etc/cockpit/cockpit.conf`

**Modify:**
- `makefile/versions.mk` — add `DOZZLE_VERSION := 10.6.1`
- `makefile/tools.mk` — add new "OBSERVABILITY SERVICES" section with one `EGET_TOOL` line for dozzle
- `makefile/packages.mk` — extend `LINUX_OPTIONAL_PACKAGES` with the six Cockpit packages
- `makefile/Makefile` — add `dozzle-service` + `cockpit-service` bespoke rules (alongside `claude-cli` / `node-runtime` / `claude-statusline`), extend `provision` dev-only deps, update `make list` + `make help`
- `README.html` — new "Web admin" tool-card under `#stack > toolbelt`, two new troubleshooting accordion entries, one-line mentions under `#daily`
- `CLAUDE.md` — new row in the "Where things are documented" table, new load-bearing invariant for the `configs/` pattern, three new "Files Claude should be careful with" entries, two new verification recipe lines
- `CLAUDE_CHANGELOG.md` — one new row at the bottom of the table

**Do NOT touch:**
- `chezmoi/` — chezmoi continues to own `$HOME` exclusively; no dotfiles change
- `bootstrap.sh` / `bootstrap.ps1` — provisioning entry points are unchanged
- `scripts/` — no manage-hosts or update-hosts changes needed
- `makefile/scope.mk` — `MODE`/`SUDO`/`DEST` semantics unchanged

---

## Verification recipes (referenced from multiple tasks)

**A. Dry-run + listing checks (no sudo, no real install — run from `makefile/`):**
```bash
cd makefile

# Lists dozzle in scope-tools (after Task 2)
make list MODE=dev | grep -E '^\s+dozzle$'

# Both services appear under provision (after Tasks 4 + 5 + 6)
make -n MODE=dev provision  | grep -E '(dozzle-service|cockpit-service)'

# Neither service runs under prod
make -n MODE=prod provision | grep -E '(dozzle-service|cockpit-service)' && echo FAIL || echo OK

# All Makefile parse without error under both modes
make -n MODE=dev provision  > /dev/null
make -n MODE=prod provision > /dev/null
```

**B. Sandbox tool install (prod sandbox, validates dozzle binary fetch — run from `makefile/`):**
```bash
GITHUB_TOKEN=$GITHUB_TOKEN \
  make -j8 dozzle MODE=prod DEST=/tmp/install-test STAMP=/tmp/install-test-stamps
ls -la /tmp/install-test/dozzle  # must exist, executable
/tmp/install-test/dozzle --version  # prints "10.6.1"
rm -rf /tmp/install-test /tmp/install-test-stamps  # cleanup
```

**C. Real dev_machine end-to-end (requires sudo + systemd + firewalld — run on an actual dev host):**
```bash
cd makefile && sudo make MODE=dev dozzle-service cockpit-service

systemctl status dozzle.service cockpit.socket             # both active
ss -tlnp | grep -E ':(8080|9090)'                          # 8080 on 127.0.0.1, 9090 on ::/0
sudo firewall-cmd --list-services | grep -q cockpit && echo "firewall ok"
journalctl -u dozzle -n 20 --no-pager                       # no errors
curl -sI  http://127.0.0.1:8080 | head -1                   # HTTP/1.1 200 OK
curl -skI https://127.0.0.1:9090 | head -1                  # HTTP/1.1 200 OK
```

**D. README round-trip:**
```bash
# Validate HTML/CSS still renders (no broken asset refs)
grep -c 'href="docs/README/README.css"' README.html  # 1
grep -c 'src="docs/README/README.js"'   README.html  # 1
# Open README.html in a browser — Dozzle + Cockpit chips visible in new "Web admin" card,
# new troubleshooting entries reachable via accordion filter.
```

Reference C is the only one that can't be run in this repo's environment without an actual dev_machine host; the others are local-only.

---

## Task 1: Create `configs/` tree with tracked system-scope config files

**Files:**
- Create: `configs/dozzle/dozzle.service`
- Create: `configs/dozzle/dozzle.env`
- Create: `configs/cockpit/cockpit.conf`

Nothing yet wires these files into the build; they're just tracked artifacts. Subsequent tasks add the make targets that install them.

- [ ] **Step 1: Pre-condition check**

Run: `ls configs/ 2>/dev/null && echo unexpected-exists || echo ok-missing`
Expected: `ok-missing`

- [ ] **Step 2: Create `configs/dozzle/dozzle.service`**

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

- [ ] **Step 3: Create `configs/dozzle/dozzle.env`**

```
DOZZLE_ADDR=127.0.0.1:8080
DOZZLE_LEVEL=info
DOZZLE_NO_ANALYTICS=true
# DOZZLE_AUTH_PROVIDER=simple   # uncomment + create /etc/dozzle/users.yml for basic auth
```

- [ ] **Step 4: Create `configs/cockpit/cockpit.conf`**

```ini
[WebService]
LoginTitle = Cockpit
MaxStartups = 10
# Origins — uncomment and list every hostname/IP you'll reach this Cockpit instance from.
# Cockpit rejects cross-origin connections by default; you only need this if you embed
# Cockpit elsewhere or proxy it. Example:
# Origins = https://host.example:9090 https://host.example.lan:9090
```

- [ ] **Step 5: Post-condition check**

Run:
```bash
ls -la configs/dozzle/ configs/cockpit/
file configs/dozzle/dozzle.service configs/dozzle/dozzle.env configs/cockpit/cockpit.conf
```
Expected: All three files exist; `file` reports ASCII / UTF-8 text with LF terminators (NOT "with CRLF line terminators" — that would break the sudo-install step later).

- [ ] **Step 6: Commit**

```bash
git add configs/
git commit -m "$(cat <<'EOF'
feat(configs): add configs/ tree for sudo-installed /etc/ files

New top-level pattern for tracking system-scope configuration that
chezmoi can't manage (since chezmoi owns $HOME only). Files here are
deployed into /etc/ by paired *-service make targets in subsequent
commits — Dozzle's systemd unit + env file, Cockpit's web service
conf. Tracked but inert until wired up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Pin Dozzle version + register binary install

**Files:**
- Modify: `makefile/versions.mk` (add `DOZZLE_VERSION` line in a new group)
- Modify: `makefile/tools.mk` (add new "OBSERVABILITY SERVICES" section)

- [ ] **Step 1: Pre-condition check (failing "test")**

Run: `cd makefile && make list MODE=dev 2>&1 | grep -c '^\s\+dozzle$' || true`
Expected: `0` (no `dozzle` target yet)

- [ ] **Step 2: Edit `makefile/versions.mk`**

Append after the existing `NODE_VERSION` line (currently the last `# --- Claude Code CLI ---` section):

```make

# --- Service / web admin (dev_machine only) ---------------------------------
# Cockpit comes from dnf (see packages.mk); only Dozzle is binary-installed.
# Dozzle is a single static linux_amd64 binary on GitHub releases.
DOZZLE_VERSION := 10.6.1
```

- [ ] **Step 3: Edit `makefile/tools.mk`**

Insert a new top-level section just before the closing `chezit` registration (so the section grouping stays coherent with the existing structure). Add after line ~227 (after the `USER TOOLS` section's `harlequin` line, before `chezit`):

```make
# =============================================================================
# OBSERVABILITY SERVICES (dev_machine only — paired with service targets in
# the top-level Makefile that install systemd units + tracked configs from
# configs/<tool>/. The binary alone is registered here; service wiring lives
# in Makefile.)
# =============================================================================

# dozzle — single static linux_amd64 binary; default `v$(version)` tag.
$(eval $(call EGET_TOOL,dozzle,$(DOZZLE_VERSION),amir20/dozzle))
```

- [ ] **Step 4: Post-condition check**

Run from `makefile/`:
```bash
make list MODE=dev | grep -E '^\s+dozzle$'
```
Expected: One line of output (`  dozzle`).

Then exercise the sandbox install (Reference B):
```bash
GITHUB_TOKEN=$GITHUB_TOKEN \
  make -j8 dozzle MODE=prod DEST=/tmp/install-test STAMP=/tmp/install-test-stamps
ls -la /tmp/install-test/dozzle
/tmp/install-test/dozzle --version
```
Expected: Binary exists, executable, prints `10.6.1` (or similar version banner). Clean up: `rm -rf /tmp/install-test /tmp/install-test-stamps`.

- [ ] **Step 5: Commit**

```bash
git add makefile/versions.mk makefile/tools.mk
git commit -m "$(cat <<'EOF'
feat(makefile): add dozzle binary (EGET_TOOL, v10.6.1)

Pins amir20/dozzle in versions.mk and registers it in tools.mk under a
new OBSERVABILITY SERVICES section. The systemd unit + env-file wiring
lands in the next commit (dozzle-service make target).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add Cockpit packages to `packages-optional`

**Files:**
- Modify: `makefile/packages.mk` (extend `LINUX_OPTIONAL_PACKAGES` block)

- [ ] **Step 1: Pre-condition check**

Run: `grep -c cockpit makefile/packages.mk`
Expected: `0`

- [ ] **Step 2: Edit `makefile/packages.mk`**

Locate the `LINUX_OPTIONAL_PACKAGES :=` block (around lines 33-39). Append the cockpit packages with a comment header. The full block becomes:

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

(Add the two new lines at the end; preserve the trailing `\` on every line except the last.)

- [ ] **Step 3: Post-condition check**

Run from repo root:
```bash
cd makefile && make -n MODE=dev packages-optional | grep -oE 'cockpit[a-z-]*' | sort -u
```
Expected: Six lines — `cockpit`, `cockpit-networkmanager`, `cockpit-packagekit`, `cockpit-podman`, `cockpit-storaged`, `cockpit-system`.

Then sanity-check parse:
```bash
make -n MODE=prod provision > /dev/null && echo OK  # MODE=prod: packages is a no-op, must not error
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add makefile/packages.mk
git commit -m "$(cat <<'EOF'
feat(packages): add Cockpit packages to optional dev-only set

cockpit + cockpit-system + cockpit-storaged + cockpit-networkmanager +
cockpit-packagekit + cockpit-podman. Joins the existing LINUX_OPTIONAL_
PACKAGES list (which is already INSTALL_PACKAGES=true gated, i.e. dev-
only). Per-package `|| true` in packages-optional handles RHEL minor
versions where cockpit-podman lives in EPEL vs AppStream.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add `dozzle-service` make target

**Files:**
- Modify: `makefile/Makefile` (add bespoke rule alongside `claude-cli` / `node-runtime`)

- [ ] **Step 1: Pre-condition check**

Run: `cd makefile && make -n dozzle-service MODE=dev 2>&1 | head -1`
Expected: `make: *** No rule to make target 'dozzle-service'.  Stop.`

- [ ] **Step 2: Edit `makefile/Makefile`**

Insert the following block immediately after the `claude-statusline` rule (currently ends around line 165 with `endif`) and before the `include packages.mk` line. The exact code:

```make
# -----------------------------------------------------------------------------
# dozzle-service — install systemd unit + env file, enable + start dozzle.
#   - dev_machine only (recipe body gated on MODE=dev; prod gets a skip msg).
#   - Order-only dep on the dozzle BINARY STAMP (not the `dozzle` phony) —
#     matches the EGET_TOOL stamp-on-stamp invariant from CLAUDE.md.
#     Depending on a phony breaks `make -j` (phonies are always-rebuild,
#     so the order-only semantics get bypassed).
#   - This rule's stamp encodes $(DOZZLE_VERSION); bumping the binary
#     version also re-applies the unit file (in case it changed alongside).
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

```

**Critical:** Recipe lines (the `@printf`, `@$(SUDO)`, etc.) MUST be tab-indented, not spaces — Makefile invariant.

- [ ] **Step 3: Post-condition check**

Run from `makefile/`:
```bash
# dev: dry-run should print the install commands
make -n dozzle-service MODE=dev | grep -E '(install -m|systemctl)'
# prod: must print the skip message
make dozzle-service MODE=prod
```
Expected: dev shows `install -m 0644 ../configs/dozzle/dozzle.env ...`, `systemctl daemon-reload`, etc. Prod prints `dozzle-service is a dev_machine target — skipping (MODE=prod)`.

Also check that the order-only stamp dep parses correctly:
```bash
make -n MODE=dev provision > /dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add makefile/Makefile
git commit -m "$(cat <<'EOF'
feat(makefile): add dozzle-service target (systemd unit + env file)

Bespoke rule alongside claude-cli / node-runtime / claude-statusline.
Installs configs/dozzle/dozzle.{service,env} into /etc/, daemon-reload,
enable --now. Order-only stamp-on-stamp dep on the dozzle binary stamp
(per CLAUDE.md invariant — phony deps break make -j). Dev-only; prod
prints a skip message. Not yet wired into provision — that's the next
commit alongside cockpit-service.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `cockpit-service` make target

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

**Critical:** Tab-indented recipe lines. Double-`$$` is NOT used here because there's no `define` wrapper — these are direct rules, so single `$` is correct.

- [ ] **Step 3: Post-condition check**

Run from `makefile/`:
```bash
make -n cockpit-service MODE=dev | grep -E '(install -m|systemctl enable|firewall-cmd)'
make cockpit-service MODE=prod  # must print skip
make -n MODE=dev provision > /dev/null && echo OK
```
Expected: dev dry-run shows the install + enable + firewall commands; prod prints the skip message; full provision dry-run parses cleanly.

- [ ] **Step 4: Commit**

```bash
git add makefile/Makefile
git commit -m "$(cat <<'EOF'
feat(makefile): add cockpit-service target (socket + firewall + conf)

Bespoke rule, twin to dozzle-service. Installs configs/cockpit/cockpit.conf
into /etc/cockpit/, systemctl enable --now cockpit.socket, opens firewalld
cockpit service if firewalld is active. Runtime rpm -q cockpit check at
the top of the recipe (since packages.mk produces no stamp to order-on);
correct under make -j. Dev-only; prod prints a skip message. Wiring into
provision lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire both services into `provision`, update `make list` + `make help`

**Files:**
- Modify: `makefile/Makefile`

- [ ] **Step 1: Pre-condition check**

Run from `makefile/`:
```bash
make -n MODE=dev provision | grep -E '(dozzle-service|cockpit-service)' && echo FAIL || echo OK
```
Expected: `OK` (services exist as standalone targets after Tasks 4-5, but `provision` doesn't depend on them yet).

- [ ] **Step 2: Extend `provision`'s dev-only deps**

Locate the existing dev-only deps block (around line 189-192 in `makefile/Makefile`):
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

Locate the existing `list:` recipe (around line 206-211):
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

In the `help:` recipe (around line 216-246), locate the "Tool installs (scope-aware via MODE):" block. Add two new lines under it, after `make claude-cli`:

```make
	@echo "  make dozzle-service   install dozzle systemd unit + start service (dev only)"
	@echo "  make cockpit-service  install cockpit.conf + enable socket + open firewall (dev only)"
```

The full block becomes:
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

- [ ] **Step 5: Post-condition check**

Run all of Reference A from the top of this plan:
```bash
cd makefile
make list MODE=dev | grep -E '^\s+dozzle$'                # in scope-tools
make list MODE=dev | grep -E 'dozzle-service'             # in new services block
make -n MODE=dev  provision | grep -E '(dozzle-service|cockpit-service)' | wc -l
make -n MODE=prod provision | grep -E '(dozzle-service|cockpit-service)' && echo FAIL || echo OK
make help | grep -E '(dozzle-service|cockpit-service)' | wc -l
```
Expected: scope-tools grep finds `dozzle`; services-block grep finds `dozzle-service` and `cockpit-service`; dev provision dry-run shows 2+ matches (the targets fire); prod provision shows `OK` (no matches); help shows 2 matches.

- [ ] **Step 6: Commit**

```bash
git add makefile/Makefile
git commit -m "$(cat <<'EOF'
feat(makefile): wire dozzle-service + cockpit-service into provision

Both join provision's dev-only deps. Adds a new 'services' block to
make list and two new lines to make help. After this commit, plain
`make dev` on a clean host installs Dozzle (binary + systemd unit,
localhost-bound) and Cockpit (dnf packages + socket + firewalld).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update `README.html` (user-facing surface)

**Files:**
- Modify: `README.html`

The CLAUDE.md invariant: "When changing user-facing surface, update `README.html` ... in the same commit, then append a row to `CLAUDE_CHANGELOG.md`." We're batching the README + CLAUDE.md + CLAUDE_CHANGELOG.md into the next two tasks since they're all docs.

- [ ] **Step 1: Pre-condition check**

Run: `grep -c -i 'dozzle\|cockpit' README.html`
Expected: `0`

- [ ] **Step 2: Add a new "Web admin" tool-card to the toolbelt**

Locate the existing "Containers" tool-card in `README.html` (starts around line 714 with `data-cat="containers"`, ends around line 752 with `</article>`). Immediately after that closing `</article>` and before the "Data / SQL" article that follows, insert:

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
                                    data-tip="Real-time Docker log viewer (localhost:8080, SSH-tunnel to access)"
                                    >dozzle<span class="sr-only">
                                        — real-time Docker log viewer
                                        (localhost:8080, SSH-tunnel to
                                        access)</span
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

The `cat-containers` / `data-cat="containers"` classification keeps the new card behaving with the existing toolbelt filter (containers/devops grouping). If the toolbelt filter has a "services" or "admin" category already, use that instead — search for `data-cat=` near the toolbelt to confirm. Otherwise containers is the closest fit.

- [ ] **Step 3: Add two troubleshooting accordion entries**

Locate the troubleshooting section (`<section id="troubleshooting">`, around line 2538). Inside it, after the existing `<details>` entries but inside the section, add two new `<details>` blocks. The exact structure mirrors existing entries — search for an existing `<details>` with a `<summary>` to copy the markup pattern. Insert (replacing `<EXISTING_TS_ENTRY_PATTERN>` once you confirm the exact tag attributes used by neighbors):

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
                            <strong>Dozzle service starts but shows no
                                containers</strong>
                        </summary>
                        <p>
                            Dozzle reads
                            <code>/var/run/docker.sock</code>; if Docker
                            isn't installed or the socket is missing,
                            you'll see an empty UI. The
                            <code>make dozzle-service</code> target installs
                            and starts Dozzle regardless (its systemd unit
                            <code>Wants=docker.service</code>, not
                            <code>Requires=</code>), so the service stays
                            up while you sort Docker out. Once Docker is
                            running, Dozzle auto-reconnects — no restart
                            needed.
                        </p>
                    </details>

```

If the existing troubleshooting entries use a different filter-data attribute (e.g. `data-ts-cat="..."`), copy whatever attribute pattern the neighboring entries use so the troubleshooting filter still includes the new entries.

- [ ] **Step 4: Add daily-workflows mentions**

Locate `<section id="daily">` (around line 2185). Inside it, after the existing chezmoi / `cz*` aliases content but before the next `<h3>`, add a new subsection. Pick an insertion point that keeps the section's reading flow — most natural is at the END of the section as a new `<h3>` with both services in one block:

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
                            <strong>Dozzle</strong> — bound to localhost
                            for safety; SSH-tunnel to view:
                            <code>ssh -L 8080:localhost:8080 &lt;host&gt;</code>,
                            then
                            <code>http://localhost:8080</code> on your
                            workstation. Real-time Docker container logs,
                            no Docker required at install time (Dozzle
                            stays up + auto-connects once Docker starts).
                        </li>
                    </ul>

```

Also update the TOC if entries are auto-generated by README.js (they typically are based on `<h3 id=...>`). If TOC is manually maintained, locate `<ol id="toc-list">` (line ~68) and add a matching entry.

- [ ] **Step 5: Post-condition check (visual + grep)**

Run:
```bash
grep -c -i 'dozzle' README.html        # >= 4 (toolbelt + troubleshooting + daily x 2)
grep -c -i 'cockpit' README.html       # >= 4 (toolbelt + troubleshooting + daily + at least one more)
grep -c 'href="docs/README/README.css"' README.html  # 1 (asset path intact)
grep -c 'src="docs/README/README.js"'   README.html  # 1
```

Then open `README.html` in a browser (`xdg-open README.html` or copy to a host with a GUI):
- The new "Web admin" tool-card renders with two chips (dozzle, cockpit), tooltips work on hover
- Troubleshooting accordion's filter input finds the two new entries when searching "cockpit" or "dozzle"
- Daily workflows shows the new services subsection

If the toolbelt filter UI doesn't show the new card, double-check `data-cat="containers"` matches the filter's option set (use a sibling card's value).

- [ ] **Step 6: Commit (deferred to Task 8)**

Do NOT commit yet — Task 8 batches README.html + CLAUDE.md + CLAUDE_CHANGELOG.md into one commit so the CLAUDE_CHANGELOG row references the README update in the same commit (per the existing changelog convention).

---

## Task 8: Update `CLAUDE.md` + `CLAUDE_CHANGELOG.md`

**Files:**
- Modify: `CLAUDE.md`
- Modify: `CLAUDE_CHANGELOG.md`

- [ ] **Step 1: Add a row to the "Where things are documented" table in `CLAUDE.md`**

Locate the existing table (under the heading "Where things are documented"). Add a new row at the bottom of that table:

```markdown
| Dozzle + Cockpit web admin (dev_machine only) | `README.html` §stack > Web admin card; §troubleshooting; §daily-services |
```

- [ ] **Step 2: Add a new load-bearing invariant in `CLAUDE.md`**

Locate the "Load-bearing invariants" section. Add this new bullet at the end of the list (so it doesn't disturb existing numbered references):

```markdown
- **`configs/` is sudo-installed to `/etc/`, NOT chezmoi-managed.** Files under `configs/<tool>/` are deployed by paired `<tool>-service` make targets (see `makefile/Makefile`) via `sudo install -m 0644 ../configs/<tool>/<file> /etc/<dest>`. Chezmoi continues to own `$HOME` exclusively — don't try to migrate `configs/` files under `chezmoi/`. The pattern exists because chezmoi has no facility for system-scope (`/etc/`) destinations. Currently used by `dozzle-service` (`configs/dozzle/dozzle.service` + `.env`) and `cockpit-service` (`configs/cockpit/cockpit.conf`). To add a new system service, create a `configs/<tool>/` directory and a matching `<tool>-service` bespoke rule in `makefile/Makefile`.
```

- [ ] **Step 3: Add three new "Files Claude should be careful with" entries**

Locate the "Files Claude should be careful with" section. Add these three bullets at the end:

```markdown
- **`configs/dozzle/dozzle.service`** — systemd unit deployed by `dozzle-service` make target into `/etc/systemd/system/`. Hand-editing the deployed copy on a host is futile — the next `make dozzle-service MODE=dev` run overwrites it. Edits belong in this tracked file; a re-run of the target picks them up via the version-stamped re-trigger (bumping `DOZZLE_VERSION` in `versions.mk`, or `make clean-dozzle-service` to force).
- **`configs/dozzle/dozzle.env`** — env vars consumed by `EnvironmentFile=` in the unit; deployed to `/etc/dozzle/dozzle.env`. Same hand-edit-vs-tracked-edit caveat as the unit file. `DOZZLE_ADDR=127.0.0.1:8080` is load-bearing — flipping it to `0.0.0.0:8080` exposes the unauthenticated log viewer on the LAN. If you change it, also uncomment `DOZZLE_AUTH_PROVIDER=simple` and create `/etc/dozzle/users.yml` (bcrypt-hashed) — Dozzle has no auth otherwise.
- **`configs/cockpit/cockpit.conf`** — INI consumed by `cockpit-ws`; deployed to `/etc/cockpit/cockpit.conf`. Currently minimal (only `LoginTitle` + `MaxStartups`); `Origins` is left as a commented worked-example. If you uncomment `Origins`, every hostname you'll reach Cockpit from must be listed — Cockpit rejects cross-origin connections by default.
```

- [ ] **Step 4: Append to the "Quick verification" section in `CLAUDE.md`**

Locate the "Quick verification" section. Add these new bullets at the end of the bulleted list (preserving the existing list style):

```markdown
- `cd makefile && make list MODE=dev` — `dozzle` appears under scope-tools; `services` block lists `dozzle-service` + `cockpit-service`.
- `cd makefile && make -n MODE=dev provision | grep -E '(dozzle|cockpit)'` — both new service targets fire (4+ matched lines).
- `cd makefile && make -n MODE=prod provision | grep -E '(dozzle-service|cockpit-service)'` — no matches (services are dev-only).
- On a real dev_machine after `make dev`: `systemctl status dozzle.service cockpit.socket` shows both active; `ss -tlnp | grep -E ':(8080|9090)'` shows 8080 on `127.0.0.1` and 9090 on `::/0`; `curl -sI http://127.0.0.1:8080 | head -1` returns `HTTP/1.1 200 OK`.
```

- [ ] **Step 5: Append a row to `CLAUDE_CHANGELOG.md`**

Locate the bottom of the table in `CLAUDE_CHANGELOG.md` (after the last existing row — the one about docs/README/ relocation). Append one new row, following the existing single-line-per-row convention:

```markdown
| Added Dozzle (real-time Docker log viewer, `EGET_TOOL` binary + tracked systemd unit + env file, localhost-bound) and Cockpit (web admin console, dnf packages + tracked `cockpit.conf` + firewalld open) to `dev_machine` provisioning. New top-level `configs/` directory for sudo-installed `/etc/` files (chezmoi owns `$HOME` only); paired `dozzle-service` + `cockpit-service` bespoke make targets join `provision`'s dev-only deps. Cockpit packages (`cockpit cockpit-system cockpit-storaged cockpit-networkmanager cockpit-packagekit cockpit-podman`) added to `LINUX_OPTIONAL_PACKAGES`. | **Yes** | New "Web admin" tool-card under `#stack > toolbelt` (chips for dozzle + cockpit, tagged `data-cat="containers"`). Two new troubleshooting entries: Cockpit PAM password requirement, Dozzle empty UI when Docker isn't running. New `#daily > daily-services` subsection with the `https://host:9090` (Cockpit) and `ssh -L 8080:localhost:8080` (Dozzle) access patterns. CLAUDE.md gains the new `configs/` load-bearing invariant, three new file-care entries (dozzle.service, dozzle.env, cockpit.conf), and four new verification recipe lines. |
```

- [ ] **Step 6: Post-condition check**

Run:
```bash
grep -c 'configs/' CLAUDE.md                # >= 4 (table row + invariant + 3 file-care + verify)
grep -c -i 'dozzle\|cockpit' CLAUDE.md      # >= 6
grep -c 'Dozzle' CLAUDE_CHANGELOG.md        # 1 (the new row)

# Spec-coverage cross-check: every section in the spec is now reflected somewhere
for section in \
  "DOZZLE_VERSION" \
  "EGET_TOOL.*dozzle" \
  "cockpit-system cockpit-storaged" \
  "dozzle-service" \
  "cockpit-service" \
  "configs/dozzle" \
  "configs/cockpit" \
  "Web admin" \
; do
  echo -n "$section: "
  git grep -l -E "$section" -- ':!docs/superpowers' | head -3 | tr '\n' ',' || echo "(missing!)"
  echo
done
```
Expected: every section listed has at least one hit outside the design/plan docs.

- [ ] **Step 7: Commit (batches Task 7 + Task 8)**

```bash
git add README.html CLAUDE.md CLAUDE_CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: Dozzle + Cockpit user-facing surface (README/CLAUDE/CHANGELOG)

README.html: new 'Web admin' tool-card with dozzle + cockpit chips,
two new troubleshooting entries (Cockpit PAM password requirement,
Dozzle empty UI without Docker), new #daily-services subsection
covering https://host:9090 and the SSH-tunnel pattern for Dozzle.

CLAUDE.md: new 'configs/' load-bearing invariant (sudo-installed /etc/
files, NOT chezmoi-managed), three new file-care entries for the
tracked service configs, four new verification recipes.

CLAUDE_CHANGELOG.md: one new row capturing the full surface change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Final cross-check (no new commits)

- [ ] **Step 1: Replay all of Reference A (dry-run + listing checks)**

```bash
cd makefile
make list MODE=dev | grep -E '^\s+dozzle$'
make -n MODE=dev provision | grep -E '(dozzle-service|cockpit-service)' | wc -l   # >= 2
make -n MODE=prod provision | grep -E '(dozzle-service|cockpit-service)'          # empty
make -n MODE=dev provision > /dev/null
make -n MODE=prod provision > /dev/null
make help | grep -E '(dozzle-service|cockpit-service)' | wc -l                    # 2
```
All must pass.

- [ ] **Step 2: Replay Reference B (sandbox binary install)**

```bash
GITHUB_TOKEN=$GITHUB_TOKEN \
  make -j8 dozzle MODE=prod DEST=/tmp/install-test STAMP=/tmp/install-test-stamps
/tmp/install-test/dozzle --version | grep -q '10.6.1'
rm -rf /tmp/install-test /tmp/install-test-stamps
```

- [ ] **Step 3: File-integrity check on shell scripts and configs**

```bash
# No CRLF endings introduced
file configs/dozzle/dozzle.service configs/dozzle/dozzle.env configs/cockpit/cockpit.conf
# Expected: each line says "ASCII text" or "UTF-8 Unicode text" — NEVER "with CRLF line terminators"

# No accidental mode flips on existing shell scripts
git ls-files --stage scripts/ makefile/lib/ | awk '$1 != "100755"' | grep -v '\.md$\|README'
# Expected: empty (only LF-only scripts; if any non-755 appears, repair via git update-index --chmod=+x)
```

- [ ] **Step 4: Reference D — README asset paths intact**

```bash
grep -c 'href="docs/README/README.css"' README.html  # 1
grep -c 'src="docs/README/README.js"'   README.html  # 1
```
If either is 0, an edit broke the asset references — re-check Task 7's diff.

- [ ] **Step 5: Manual browser check (cannot be automated)**

Open `README.html` in a browser:
- Confirm the new "Web admin" tool-card renders with both chips and tooltips
- Confirm troubleshooting filter finds both new entries when typing "dozzle" or "cockpit"
- Confirm the new `#daily-services` subsection is reachable from the TOC

- [ ] **Step 6: Real dev_machine end-to-end test (Reference C — REQUIRES an actual dev_machine host)**

On a real dev host that's already running this repo's `make dev`:
```bash
cd ~/.local/share/chezmoi
git pull
cd makefile
sudo make MODE=dev dozzle-service cockpit-service

systemctl status dozzle.service cockpit.socket
ss -tlnp | grep -E ':(8080|9090)'
sudo firewall-cmd --list-services | grep -q cockpit && echo "firewall ok"
journalctl -u dozzle -n 20 --no-pager
curl -sI  http://127.0.0.1:8080 | head -1
curl -skI https://127.0.0.1:9090 | head -1
```

All success-criteria from Reference C should pass. If any fails, do NOT amend the existing commits — instead, file a follow-up fix commit with a clear message.

---

## Self-review (executed at plan-write time, not at execution time)

**1. Spec coverage:**
- Spec §1 (version pin) → Task 2 ✓
- Spec §2 (tool registration) → Task 2 ✓
- Spec §3 (package additions) → Task 3 ✓
- Spec §4 (configs/ tree + file contents) → Task 1 ✓
- Spec §5 (make targets + provision wiring) → Tasks 4, 5, 6 ✓
- Spec §6 (make list + make help) → Task 6 ✓
- Spec §7 (README + CLAUDE.md + CHANGELOG) → Tasks 7, 8 ✓
- Spec §8 (verification recipes) → embedded in every task + Task 9 ✓

**2. Placeholder scan:** No "TODO" / "TBD" / "implement later" in the plan body. Every code block is the literal content to write. The one parameter that was a placeholder in the spec (`DOZZLE_VERSION`) is resolved to `10.6.1` at plan-write time.

**3. Type consistency:** Make-variable names (`DOZZLE_VERSION`, `STAMP`, `SUDO`, `DEST`), target names (`dozzle`, `dozzle-service`, `cockpit-service`), and file paths (`/etc/dozzle/dozzle.env`, `/etc/cockpit/cockpit.conf`, `/etc/systemd/system/dozzle.service`) are identical everywhere they appear.

**4. Test ordering:** Each task has a pre-condition check ("failing test"), then implementation, then a post-condition check ("passing test"), then commit — five-step TDD pattern adapted for Make/shell work.

**5. Commit cadence:** 7 implementation commits total (Tasks 1, 2, 3, 4, 5, 6, 7+8 batched). No commit straddles unrelated changes; README + CLAUDE.md + CHANGELOG are intentionally batched since they're all part of the same user-facing-surface contract per CLAUDE.md.
