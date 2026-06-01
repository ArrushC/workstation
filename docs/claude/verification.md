# Quick verification

> Claude-internal reference, split out of `CLAUDE.md` to keep it lean. Reach for
> these after a change in the matching area. Grouped roughly by subsystem.

After changes:
- `./scripts/manage-hosts.sh --sync` — regenerates the chezmoi-tracked wezterm sentinel block, no errors.
- `cd makefile && make list MODE=dev` — should show every managed tool grouped by target: 58 scope-tools (incl. `eget` itself), 3 user-tools, plus claude-cli. If a tool isn't listed, its `$(eval $(call …,…))` line in `tools.mk` didn't expand — usually because the `<NAME>_VERSION` variable referenced wasn't defined in `versions.mk`.
- `cd makefile && make -n MODE=prod provision` — dry-run prod. Should print "skipping system packages (MODE=prod, INSTALL_PACKAGES=false)" then the tool installs.
- `cd makefile && make -n MODE=dev provision` — dry-run dev. Should print dnf lines under `sudo`, then EPEL, then optional packages, then tool installs.
- `cd makefile && make help` — top-level targets. Help-only commands don't trigger `scope.mk`'s error-out.
- `cd makefile && make -j8 all MODE=prod DEST=/tmp/install-test HELIX_RUNTIME_DEST=/tmp/helix-rt STAMP=/tmp/install-test-stamps` — full sandbox install. Finishes in 25-30s; `ls /tmp/install-test | wc -l` ≈ 60. Re-run should be a sub-second no-op. **Set `GITHUB_TOKEN`** or eget hits the 60-req/hour unauthenticated limit.
- `./scripts/update-hosts.sh --check --group dev_machine` — prints planned actions without ssh'ing. Should derive `MODE=dev`.
- `./bootstrap.sh` with no flags must error. `./bootstrap.sh --dev --prod` must error. `./bootstrap.sh --full` must error with "use --dev or --prod".
- `./scripts/manage-hosts.sh --add --name t --ip 1.2.3.4 --user u --group foo --skip-confirm` must reject `foo`. PowerShell side (`-Add -Group foo`) must reject the same way.
- `chezmoi diff` on a host — no surprises. Linux: only Linux-targeted paths (dot_zshrc, dot_bashrc, dot_dircolors, dot_config/{starship,helix,zellij}, dot_gitconfig, dot_nbrc) + cross-platform `.ssh/config`. Windows: only AppData/Documents/dot_config/wezterm + cross-platform `.ssh/config`.
- `ssh -G <managed-host> | grep -iE 'serveralive|tcpkeepalive|connecttimeout'` after `chezmoi apply` — confirms keepalive defaults: `serveraliveinterval 30`, `serveralivecountmax 3`, `tcpkeepalive yes`, `connecttimeout 10`.
- WezTerm `CTRL+SHIFT+F5` in SSH tab — spawns new tab against same domain, zellij reattaches. In a local tab — toast "Not an SSH pane — nothing to reconnect".
- `bootstrap.sh --dev` and `--prod` on fresh hosts — idempotent, self-register under matching group.
- `bootstrap.sh --dev` *inside WSL* — no `hosts.conf` changes, prints "Detected WSL — skipping hosts.conf self-registration", final tip is WSL-specific.
- Fresh WSL tab after Windows `chezmoi apply` — `pwd` is `/home/<user>`, not `/mnt/c/...`.
- Inside WSL tab, `CTRL+SHIFT+T` — pre-bootstrap lands in `~`; post-bootstrap (OSC 7 active) `cd /tmp` then new-tab lands in `/tmp`.
- `bootstrap.ps1` on fresh Windows (elevated PowerShell) — choco bootstraps, tracked tools install, chezmoi applies, wezterm picks up deployed config.
- `git diff README.html docs/README/README.css docs/README/README.js` — verify user-facing surface still matches reality. Open in a browser — primitives (tabs, flow chips, accordion filter) must render, not just diff cleanly. If unstyled, the asset paths in `README.html` (`href="docs/README/README.css"`, `src="docs/README/README.js"`) are wrong or the files were moved out of `docs/README/`.
- `cd makefile && make list MODE=dev` — `services` block lists `dozzle-service` + `cockpit-service`. Dozzle is NOT in scope-tools (no EGET_TOOL).
- `cd makefile && make -n MODE=dev provision | grep -E '(dozzle-service|cockpit-service)'` — both targets fire (2+ matched lines).
- `cd makefile && make -n MODE=prod provision | grep -E '(dozzle-service|cockpit-service)'` — no matches (services are dev-only).
- On a real dev_machine after `make dev` (Docker required): `systemctl status dozzle.service cockpit.socket` shows both active; `docker ps --filter name=dozzle --format '{{.Image}}'` shows the pinned tag; `ss -tlnp | grep -E ':(8080|9090)'` shows 8080 on `127.0.0.1` and 9090 on `::/0`; `curl -sI http://127.0.0.1:8080 | head -1` returns `HTTP/1.1 200 OK`.
- `infocmp wezterm | head -1` on every chezmoi-managed host after `cza` — confirms the terminfo entry was tic'd by `run_onchange_install-wezterm-terminfo.sh`. Should print `wezterm|Wez's terminal emulator,`.
- After editing `chezmoi/dot_config/zellij/config.kdl`: stage it **with the `layouts/` dir** into a temp config dir and run `ZELLIJ_CONFIG_DIR=<tmp> zellij setup --check` — must report a clean parse. The file is KDL, so comments are `//`, **never `#`** (a single `#` line fails the *whole* file; zellij then silently falls back to built-in defaults at runtime — theme / keybinds / `scroll_buffer_size` all dropped with no error), and keybinds use **space-separated** modifiers (`bind "Ctrl s"`, not `"Ctrl-s"`) on the pinned zellij 0.40.1. Stage `layouts/dev.kdl` alongside or `default_layout "dev"` raises a spurious `layout was not found`. `scroll_buffer_size` is read at session creation — a running `main` session keeps its old buffer until recreated.
- `fc-list | grep -i 'jetbrainsmono nerd font mono' | wc -l` on every Linux **dev_machine** after `make dev` — should return `6`. WSL hosts deliberately return `0` (font is on the Windows side; the make target no-ops). prod_machine hosts return `0` (font is dev-only).
- After `bootstrap.ps1` on Windows: `(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\JetBrainsMonoNerdFontMono-*.ttf").Count` — should return `6`. `(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts').PSObject.Properties.Name -like 'JetBrainsMonoNerdFontMono-*' | Measure-Object` should also show `Count: 6`.
- Visual smoke test in any post-install WezTerm pane (post `Ctrl+Shift+R` reload): `printf '     \n'` renders folder / home / megaphone / powerline arrow / calendar / github icons crisply — no tofu boxes.
- New WezTerm panes after phase-2 config reload — `echo $TERM` prints `wezterm`. Smooth-gradient awk one-liner renders without banding: `awk 'BEGIN{ for(c=0;c<256;c++){ printf "\033[38;2;%d;%d;%dm█",c,(c+85)%256,(c+170)%256 } print "\033[0m" }'`.
- `tldr tar | head -1` on any host after `cza` — prints the tar page's first line (not "Page cache not found"); confirms the tealdeer cache seed + `auto_update` config landed.
- `man ls | head` in a post-apply shell — renders colorized (bat) when `bat` is on PATH; confirms the `MANPAGER` block. `command -v pkg-config && pkg-config --version` — non-empty version string.
