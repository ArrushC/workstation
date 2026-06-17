# rsyslog-service — design

**Date:** 2026-06-17
**Status:** approved (design); implementation pending

## Goal

Add `rsyslog` to the toolbelt as a **managed, dev-only systemd service** that
deploys a tracked local-facility log-routing drop-in. Funnels the eight custom
`local0`–`local7` syslog facilities into one easy-to-tail file so scripts can
emit dedicated logs with `logger -p local0.info "…"`.

## Decisions (from brainstorming)

| Question | Choice |
|---|---|
| Integration level | **Managed service** — bespoke `rsyslog-service` target, not just an optional package |
| Config | **Tracked drop-in** with content-hash stamp (auto-redeploy on edit) |
| Config purpose | **Local file routing** — `local0..local7 → /var/log/workstation.log` |
| WSL | **Skip on WSL** — matches cockpit/dozzle/docker (host logging is the Windows side's job) |

Scope is forced dev-only regardless: prod has no sudo and `INSTALL_PACKAGES=false`,
so a root-owned logging daemon can't be installed there.

## Patterns reused

- **`cockpit-service`** — dnf-package service: the recipe sanity-checks
  `rpm -q rsyslog` and errors (pointing at `make packages`) rather than
  installing the package itself; package lives in `LINUX_OPTIONAL_PACKAGES`.
  Cannot depend on the `packages` phony (would break `make -j`); relies on
  `provision` ordering + the rpm sanity-check.
- **`wsl-config`** — content-hash stamp (`RSYSLOG_CONF_SHA`) so editing the
  tracked drop-in auto-redeploys; no `versions.mk` pin (dnf-versioned, like
  cockpit/docker).

## Changes

1. **`configs/rsyslog/30-workstation.conf`** (new; LF, 0644) → installed to
   `/etc/rsyslog.d/30-workstation.conf`:

   ```
   # 30-workstation.conf — managed by `workstation` (make MODE=dev rsyslog-service).
   # Routes the eight custom local syslog facilities into one easy-to-tail file.
   # Emit to it from any script:  logger -p local0.info "hello"
   # `& stop` keeps these out of the stock /var/log/messages (no duplicates).
   local0,local1,local2,local3,local4,local5,local6,local7.*    /var/log/workstation.log
   & stop
   ```

2. **`makefile/Makefile`** — new `rsyslog-service` target after `cockpit-service`:
   - `MODE=dev` gate; `IS_WSL=true` → skip message; non-dev → "dev_machine target" message.
   - `RSYSLOG_CONF_SHA := $(shell sha256sum ../configs/rsyslog/30-workstation.conf | cut -c1-12)`.
   - Recipe: sanity-check `rpm -q rsyslog` (error → run `packages` first) →
     `install -m 0644` the drop-in → `systemctl enable rsyslog` +
     `systemctl restart rsyslog` (restart applies the drop-in) → stamp.
   - `clean-rsyslog-service`: rm the drop-in, restart rsyslog, wipe stamps.

3. **Wiring:**
   - `provision:` dev-only line → append `rsyslog-service`.
   - `packages.mk` `LINUX_OPTIONAL_PACKAGES` → add `rsyslog` (near the log tools).
   - `DOCTOR_ROWS += bespoke|rsyslog-service|-`.
   - `help` target → one line for `make rsyslog-service`.

4. **`makefile/lib/doctor.sh`** — `rsyslog-service)` health case (WSL skip /
   `svc_active rsyslog` / package-present-but-inactive / missing) + header
   comment component list updated.

5. **Docs:**
   - `README.html` — document the new dev_machine service (the dev-only-services
     enumeration + a services tool-card / §stack mention): `/var/log/workstation.log`,
     `logger -p local0.*` usage, `make rsyslog-service`.
   - `CLAUDE_CHANGELOG.md` — append a row.
   - `CLAUDE.md` + `docs/claude/file-care.md` — add `rsyslog-service` /
     `configs/rsyslog/` to the "configs/ → /etc/ via paired make targets" invariant.

## Out of scope / non-goals

- No remote forwarding or collector/listener (no network, no firewalld step).
- No `versions.mk` pin. No new `check-invariants.sh` mechanical check (the config
  is not a shell script — none of the LF+0755/shellcheck/BOM/pin/sentinel shapes apply).
- No prod or WSL deployment.

## Verification

- `make -n MODE=dev rsyslog-service` (dry-run wiring), `make -n MODE=prod rsyslog-service`
  (skip message), and on a WSL host the skip branch.
- `make lint MODE=prod` (`check-invariants.sh` + shellcheck/shfmt/gitleaks) clean.
- `make doctor MODE=dev` shows the new `rsyslog-service` row.
- Confirm `configs/rsyslog/30-workstation.conf` is LF (`file` must not say CRLF).
