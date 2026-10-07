---
name: project-directory-accounts-sssd
description: On atc-cache-dev10 (RHEL 8.10) the user account comes from SSSD, not /etc/passwd — usermod/chsh can't change the login shell (use sss_override), and static musl binaries can't resolve the username (pueued crash-looped until conda:pueue, #36).
metadata:
  type: project
---

Some hosts take accounts from a directory (SSSD/AD/LDAP): `grep -c "^$USER:" /etc/passwd` is 0 while `getent -s sss passwd $USER` returns the user. Found on `atc-cache-dev10` (RHEL 8.10, subscribed) on 2026-10-07.

Consequences seen there:
- `sudo usermod -s` fails ("user ... does not exist in /etc/passwd", exit 6) and `chsh` can't work either; `bootstrap.sh`'s `set_login_shell` hides that error. The user set zsh with a per-host SSSD override: `sudo sss_override user-add "$USER" -s /usr/bin/zsh && sudo systemctl restart sssd` (sssd-tools). `getent passwd` then shows zsh, so `set_login_shell` sees it as done.
- Static musl binaries look users up in /etc/passwd only (no NSS), so anything needing the username fails. pueued crash-looped ("Unable to detect the username for the current user", `systemctl --user is-active` = `activating`, mise status `stopped`). Fixed by `conda:pueue` (glibc, NSS) instead of upstream's musl assets (#36). Reproduce without such a host: an Alma container user known only via `nss_wrapper` (LD_PRELOAD, NSS_WRAPPER_PASSWD) and absent from /etc/passwd.
- `journalctl --user` has no user journal there ("No journal files were found"); run the daemon in the foreground with `-vv` to see why a user unit fails.

**How to apply:** when choosing a musl asset to meet the EL8 glibc floor ([[project-verify-tool-bumps-at-runtime]]), check whether the tool looks up the current user (sockets named after `$USER`, `whoami`-style calls); if so prefer a glibc build (conda-forge) over musl. Related: [[feedback-sudo-not-passwordless]].
