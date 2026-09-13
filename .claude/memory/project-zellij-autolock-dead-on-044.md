---
name: project-zellij-autolock-dead-on-044
description: zellij-autolock is broken on zellij 0.44.x and unmaintained — do not re-propose it; Ctrl+g is the working substitute
metadata:
  type: project
---

`zellij-autolock` (fresh2dev) does **not** work on the fleet's pinned zellij
0.44.3. Tested end-to-end 2026-08-31: the `.wasm` loads, config parses, and
permissions can be granted, but it logs `No command detected.` forever and never
switches to Locked mode.

**Why:** the root cause is upstream, not the plugin's packaging. zellij 0.44.3
does not expose a shell pane's foreground command at all — with **stock** zellij
config and Helix running, `zellij action list-panes` still reports
`terminal_0  terminal  Pane #1`. The plugin cannot read what zellij never
publishes. Confirmed by its own open issue #18 ("Fails to trigger/detect commands
in Zellij 0.44.0 (`No command detected.`)") and open PR #21; last commit
2025-01-13.

**How to apply:** don't re-propose it (or any zellij plugin) without first
testing against the pinned zellij and checking the plugin's last commit date. Two
extra traps found while evaluating: plugins need a one-time **interactive**
permission grant recorded in `~/.cache/zellij/permissions.kdl`, keyed by the
plugin's **absolute path** — a genuine fleet-deployment problem, since that path
differs per host; and `zellij setup --check` says "Well defined" for a config
whose plugin is completely non-functional. The built-in `Ctrl+g` Locked mode is
the working substitute for the Helix/zellij Ctrl-key conflicts and is documented
in README §daily-zellij. Re-test only if a release newer than 0.2.2 appears. **Judge any plugin load by the LOG** — `/tmp/zellij-<uid>/zellij-log/zellij.log` says `Loaded plugin '<name>'` or `No such file` with the paths tried; `zellij action dump-layout` echoes the configured location string either way (that is how the zjstatus first cut, installed to `~/.config/zellij/plugins/` which zellij never searches, passed review on 2026-09-13). Relative `file:` plugins resolve against `/usr/share/zellij/plugins`, then the data dir `~/.local/share/zellij/plugins` (`zellij setup --check` → `[PLUGIN DIR]`).
Relates to [[project-verify-tool-bumps-at-runtime]].
