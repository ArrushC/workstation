# WezTerm in-window notices (status-bar flash) — design

**Date:** 2026-07-18
**Status:** approved (user-selected scope: all four call sites + unify Copied!; PR #98 merged as plumbing)

## Problem

The tracked WezTerm config gave feedback through OS-level toasts
(`window:toast_notification()`): "Config reloaded", the CTRL+SHIFT+F5
reconnect gate, the CTRL+SHIFT+O scrollback bail, and the dump-failure error.
Two defects surfaced 2026-07-18: the reload toast's seen-marker died on every
config reload (fixed in #97, `wezterm.GLOBAL`), and then ALL config toasts
turned out to be silently undeliverable — the portable-zip install had no
registered AppUserModelId (fixed in #98, bootstrap `Invoke-WeztermToastAppId`).
The user prefers in-window feedback anyway — a herdr-style TUI toast rather
than the Windows notification center.

## Constraint that shapes the design

WezTerm's Lua API has **no floating-overlay primitive**. herdr paints toast
boxes because it owns its whole screen; a WezTerm config can only draw on the
surfaces WezTerm exposes:

- the status strip (left/right status) — the only non-intrusive flashable surface;
- modal overlays (InputSelector etc.) — steal focus, need dismissal; wrong tool;
- `pane:inject_output` — would corrupt running apps; never.

The config already contains the right pattern: the "📋 Copied!" badge
(status.lua) — a colored, timed message in the right-status slot, rendered
instantly and self-clearing. This design generalizes it.

## Decisions

1. **Scope: all four OS-toast call sites convert** to the in-window flash, and
   the Copied! badge is **unified** into the same mechanism (its first
   consumer). Zero `toast_notification` calls remain in the config.
2. **PR #98 (AUMID registration) merged as-is.** It still gates a separate,
   real channel: OSC 9/777 escape-toasts from remote/background programs (the
   `notification_handling` channel from #96) route through the same Windows
   backend and fail silently without the registration. The #98 README/CLAUDE.md
   wording is trued up in this change so it no longer claims the config's own
   toasts depend on it.

## Design

### Interface (status.lua)

```lua
M.flash(window, pane, text, level, secs?)   -- level ∈ 'info' | 'warn' | 'error'
```

- Colors are mapped **inside** status.lua — info=green, warn=peach, error=red —
  matching the established accent language (green success, peach attention,
  red error). Callers never plumb hex values; the visual language cannot drift.
- Default durations: info 2s (Copied! precedent), warn 3.5s, error 5s;
  explicit `secs` overrides. Last-writer-wins per window (copied_at precedent).

### Mechanics

- `copied_at` becomes `notice = {}` (window-id → `{ text, fg, expires }`),
  plus a `NOTICE_LEVELS` table for the color/duration mapping.
- The render branch reuses the center-pad-to-normal-width trick so short
  notices don't shift the tab bar; longer notices render wider for their few
  seconds (accepted).
- `flash()` re-renders the right status immediately (the 'copied' handler's
  existing behavior) — no waiting for the ~1s tick.
- State stays **module-local deliberately** (2026-07-18 reload-state audit
  rationale): notices live for seconds — too ephemeral for a reload to
  plausibly intersect — and the one reload-adjacent notice ("Config reloaded")
  is set by the NEW Lua VM after the reload completes, so it never needs to
  survive one. The in-file comment records this so it isn't "fixed" into
  `wezterm.GLOBAL` later.

### Call-site conversions

| Site | Was (OS toast) | Becomes |
|---|---|---|
| keys.lua reload handler | `toast_notification('WezTerm', 'Config reloaded', nil, 1500)` | `flash(window, pane, 'Config reloaded', 'info')` — #97's GLOBAL seen-marker untouched |
| actions.lua reconnect gate | "Current pane is not a configured SSH domain — nothing to reconnect" | `flash(…, 'Not a configured SSH domain — nothing to reconnect', 'warn')` |
| actions.lua scrollback bail | "Zellij owns scrollback in SSH tabs — use its search there" | `flash(…, 'Zellij owns scrollback in SSH tabs — search there', 'warn')` |
| actions.lua dump failure | "Scrollback dump failed: <err>" | `flash(…, 'Scrollback dump failed: ' .. err, 'error')` |
| status.lua 'copied' handler | (already in-window) | `flash(…, '📋 Copied!', 'info')` — mechanism's first consumer |

The `copied` EmitEvent bridge stays: `act.Multiple` chains have no callback
context, so they still emit the event; only the handler body changes.

### Doc truth-ups (same change)

- README §setup-windows WezTerm card: the AUMID sentence rewords to the
  channels it actually serves post-conversion (OSC 9/777 escape-toasts +
  future `toast_notification` callers); config feedback is now in-window.
- CLAUDE.md Windows-installs invariant: same truth-up.
- `wezterm.lua` module map + affected in-file comments mention notices.
- CLAUDE_CHANGELOG row.

## Rejected alternatives

- **Left-status flash** — in the retro bar the left status renders before the
  tabs; a flash shoves the tab row sideways (the exact layout jump the badge's
  center-padding exists to avoid).
- **Tab-title flash / modal overlay** — fights `format-tab-title` ownership;
  modal steals focus and needs dismissal.
- **Dual-channel (flash + OS toast)** — declined by user; more noise.

## Verification

- luaparse SYNTAX OK on status/keys/actions/wezterm modules; `make lint MODE=prod`.
- Live (Windows, after merge + sync): CTRL+SHIFT+R → green "Config reloaded"
  in the status slot; CTRL+SHIFT+F5 in a WSL tab → peach gate notice; copy a
  selection → badge unchanged; CTRL+SHIFT+O in an SSH tab → peach Zellij
  notice.
