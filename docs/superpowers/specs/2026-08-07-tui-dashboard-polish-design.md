# TUI Dashboard & Navigation Polish — Design

**Date:** 2026-08-07
**Status:** Approved (post-v1 enhancement to the shipped workstation TUI)

## Goal

Three user-requested improvements to the merged v1 TUI: arrow-key navigation,
a live Health quadrant on the Dashboard (closing the recorded as-built delta),
and a full-bleed equal-quadrant Dashboard layout.

## 1. Arrow-key navigation

- **Dashboard card grid:** `←→↑↓` move focus between the four cards. Grid walk
  is positional over the 2×2 layout (provision top-left, dotfiles top-right,
  fleet bottom-left, health bottom-right): left/right move within a row,
  up/down within a column; no wrapping. When the dashboard becomes the active
  panel, the first card is auto-focused so arrows work immediately. Enter on a
  focused card opens its panel (unchanged).
- **Panel cycling:** `ctrl+left` / `ctrl+right` on `WorkstationApp` cycle to
  the previous/next panel in `PANELS` order, wrapping at the ends. Bound at the
  app level; ctrl-modified arrows are not consumed by DataTables, so cycling
  works from every panel including focused tables. Native bare-arrow table
  navigation is untouched.
- **Surfaces updated:** HelpScreen global-keys list and README §tui keys table
  gain both bindings; the global key bar is unchanged (already dense — help
  documents the full set).

## 2. Live Health quadrant

- **No `Summary` model change.** The app's existing `_load_summary` thread
  worker also gathers a health rollup and `_apply_summary` passes it to the
  dashboard alongside the summary.
- **Rollup contents** (all data via existing injectables — no new subprocess
  paths):
  - Per-check line from `load_cache(self.health_cache_path)`: one themed glyph
    per registry check (doctor/updates/invariants/templates) — ✓ green ok,
    ✗ red failed, — dim never-ran.
  - Services summary via `services_reader` ONLY when the context allows
    (has_systemctl and not is_wsl and mode == "dev"): `N/4 active`; otherwise
    the muted gating reason (mirrors the Health panel's precedence).
  - Interop state via `interop_reader` only when `is_wsl`.
- **Injection:** the rollup pieces ride the existing `services_reader` /
  `interop_reader` / `health_cache_path` app parameters — dashboard tests
  construct the app exactly like health-panel tests do. A small
  `HealthRollup` dataclass/pydantic model (app-layer or core — implementer's
  documented choice) carries the three parts to the card renderer.
- **Card behavior:** remains a focusable jump target (Enter → Health panel);
  renders markup-safe (all dynamic fragments are fixed-vocabulary states —
  check ids, state words — but summaries from cache are `escape()`d or
  glyph-only to keep the markup-inert discipline).

## 3. Full-bleed equal quadrants

- CSS only: `DashboardPanel { height: 1fr; }`, `#cards { height: 1fr;
  grid-size: 2 2; grid-rows: 1fr 1fr; grid-columns: 1fr 1fr; }` with the
  existing gutter; `.card { height: 100%; }` (fills its cell). The
  `#dashboard-warnings` block keeps auto height below the grid so reader
  warnings never vanish; when there are no warnings it renders empty and the
  grid takes the full area.
- Result: four equal cells filling the content region at any terminal size.

## Error handling

Unchanged patterns: cache read is never-raise core; provider failures surface
as the existing header/warnings paths; the health card shows — glyphs when the
cache is empty rather than erroring.

## Testing

Pilot tests: card arrow-walk (each direction + no-wrap edges + auto-focus on
panel entry), ctrl+left/right cycling incl. wrap and from-within-a-table,
health-card content (cached results render glyphs; empty cache renders —;
services line gated per context). Existing 168 tests stay green unchanged
(dashboard summary_text/test assertions may need the health-card plain text
updated — allowed, minimal).

## Docs

README §tui: keys table gains the two bindings; Dashboard block's Health-card
sentence updated to describe the live rollup. CLAUDE_CHANGELOG row. The spec's
as-built-deltas bullet about the static health card gets a follow-up note
("closed by the dashboard-polish change, 2026-08-07").
