# README.html — "Terminal, elevated" UI/UX redesign

**Date:** 2026-06-13
**Scope:** `README.html` + `docs/README/README.css` + `docs/README/README.js` (the self-contained
trio) + a `CLAUDE_CHANGELOG.md` row. No Make/bootstrap/chezmoi/versions changes — pure docs.
**Status:** Approved — direction and the one open decision (hero motion) confirmed by the user via
structured options (2026-06-13). Awaiting spec review before writing the implementation plan.

## Goal

Redesign the look and feel of the user-facing reference (`README.html`) from the current — already
competent — "Terminal Refined" developer doc into a higher-craft **"terminal, elevated"** treatment:
a living command-line hero, stronger spacing/rhythm, depth/layering, refined components, and subtle
motion. Dark-first, keeping the repo's existing identity. This is a full visual + IA overhaul of the
three files, **not** a content rewrite.

## Decisions (user-confirmed 2026-06-13)

1. **Direction: "Evolve the terminal look."** Keep the mono/terminal DNA and dark-first identity;
   push the craft hard. (Chosen over "clean dev-tool docs" and "bold editorial".)
2. **Scope: "Full overhaul."** Free to restructure markup per-component, refine layout/IA, and
   rewrite copy *where it improves clarity* — but **every `#anchor` and all section content stays**,
   and the three-file structure stays. (Chosen over "pure paint" and "reskin + targeted rebuild".)
   Copy churn is deliberately minimised: same words unless a change clearly helps.
3. **Hero motion: typed animation.** On load the `make MODE=dev provision` command "types" itself
   and the `✓` output lines stream in sequentially, then settle with a blinking caret. **Always**
   falls back to the fully-rendered static state under `prefers-reduced-motion` and when JS is off.

## Non-goals / constraints (must hold)

- **Stays the `README.html` + `docs/README/README.css` + `docs/README/README.js` trio.** No new
  asset files, no external JS/CSS deps beyond the existing Google Fonts `@import` (IBM Plex
  Mono/Sans). No build step. Opens correctly from `file://` on disk.
- **All existing `#anchor` ids preserved** (CLAUDE.md and in-page links route to them):
  `#intro #stack #toolbelt #machines #layout #setup #setup-config #setup-linux #setup-windows`
  `#setup-wsl #setup-wezterm #prompt-keys #completion #hosts #daily #daily-services #adding`
  `#troubleshooting`. Section **content** is preserved (toolbelt chips, tables, trees, steps,
  troubleshooting entries, keybind tables, etc.).
- **All 10 current JS behaviors preserved** (may be refactored, but feature + UX kept):
  1. 3-state theme toggle (auto/light/dark) persisted to `localStorage["readme-theme"]`.
  2. Copy-to-clipboard button injected on every `<pre>` (`.copy-btn` / `.copied`).
  3. `#` heading-anchor links injected on `main h2/h3/h4[id]` (`.heading-anchor`).
  4. Scroll-spy TOC (`nav.toc a` gets `.active` + `aria-current`; IntersectionObserver).
  5. Global search: highlight matches (`<mark>`), dim non-matching sections (`.dimmed`), hide
     their TOC entries (`li.hidden`), live count in `#toc-search-meta`.
  6. Keyboard: `/` focuses search, `Esc` clears the focused search/filter or blurs.
  7. Toolbelt filter (`#tool-filter` → `.tool-card.dimmed`, `.chip.match-hit`, `#tool-filter-meta`).
  8. Troubleshooting filter (`#ts-filter` → `[data-ts]` `hidden`/`open`, `#ts-count`).
  9. Mobile TOC collapse (`#toc-collapse-ctrl`, `.mobile-collapsed`, `aria-expanded`).
  10. Scroll-progress bar driving `--scroll-progress` (rAF-throttled).
  Plus **one new behavior (11): hero typed-animation** (progressive enhancement — see below).
- **File care:** these three are plain UTF-8, **LF**, no BOM (they are NOT in the BOM set, which is
  PowerShell-only, nor the 0755 set, which is shell scripts). Preserve UTF-8 glyphs (`✓ ✗ — ❯ ◐`).
  Keep mode `100644`. No CRLF.
- **No README→docs path changes:** CSS stays at `docs/README/README.css`, JS at
  `docs/README/README.js`, referenced by the same relative `<link>`/`<script>` tags.

## Design system

### Tokens (CSS custom properties, dark-first; light + auto overrides kept)
Evolve the existing palette rather than replace it — same hues, slightly tuned, plus a few new
tokens. Three theme scopes preserved: `:root,[data-theme="dark"]`, `@media (prefers-color-scheme:
light) [data-theme="auto"]`, and `[data-theme="light"]`.

- **Surfaces (dark):** `--bg #0a0d12`, `--bg-soft #0d1117`, `--surface #11161e`,
  `--surface-2 #161c25`, `--surface-3 #1d2530`; `--border #2a323e`, `--border-soft #1c2330`.
- **Text:** `--text #e8eef5`, `--text-soft #c4cdd9`, `--muted #8893a4`, `--muted-2 #6b7585`.
- **Accents:** `--accent #6bb6ff` (+ `--accent-hover`, `--accent-soft`, `--accent-deep`),
  `--hot #d4ff5a` (lime), semantic `--linux #5aa9ff` / `--windows #b88dff`,
  `--ok #5fd87a`, `--warn #f1bf65`, `--bad #ff7676`, `--teal #62e0d8`, `--pink #ff9485`.
- **Light:** warm cream (`--bg #fbfaf6`, `--surface #fff`), darker accents (`--accent #1d5fc7`,
  `--hot #3f7d12` so lime stays legible on cream), as in the current sheet.
- **New / tuned:** `--grid-line` (faint background grid), ambient-glow radial gradients (hero),
  `--shadow` / `--shadow-soft` deepened for the dark theme, radii `--r-sm 5 / --r 9 / --r-lg 14`,
  `--maxw ~62rem` prose measure.
- **Fonts:** `--mono` IBM Plex Mono (display, headings, labels, code, chips), `--sans` IBM Plex Sans
  (prose). `--display` = mono.

### Page chrome / atmosphere
- Faint **background grid** (two repeating linear-gradients at `--grid-line`) + very low-opacity
  ambient **radial glows** behind the hero (accent + lime), `position:fixed`, `pointer-events:none`,
  behind content. Subtle; must not hurt prose contrast or light mode.
- **Scroll-progress bar:** thin top bar, `accent→hot` gradient, width driven by `--scroll-progress`
  (keep existing JS; it sets the property on `#scroll-progress`).

### Layout
- Two-column `.layout` (sidebar `248px` + `minmax(0,1fr)` main), centered, max width ~`1240px`.
- **Sidebar `.toc`** sticky full-height: brand mark (mono `workstation` + small logo glyph), search
  field with a `/` keycap affordance and the existing `#global-search` + `.kbd-hint`, then a
  **numbered** contents list (`counter` `decimal-leading-zero`), nested sub-items kept. Active link:
  `--accent-soft` background + a sliding 3px left accent bar. Hover lift. Keep `#toc-collapse-ctrl`,
  `#toc-search-meta`, `.toc-search` ids/classes.
- **Main** with a `--maxw` prose measure on text blocks; cards/grids may go full width.

## Component specs (all reskinned to one language)

- **Hero (`header#intro`):** mono `h1` `workstation` with a blinking lime caret + `dev env` tag;
  one-line sub. Below it a **terminal-window** block: bar with 3 traffic-light dots,
  `user@workstation: ~/.local/share/chezmoi` title, `DEV ENV` chip; body shows the `❯ make MODE=dev
  provision` command + 3–4 `✓` streaming output lines + a `#` hint line with caret; a dashed-top CTA
  row with **Linux quickstart / Windows quickstart / View on GitHub** buttons. **Directly beneath the
  terminal block**, the two existing first-time-setup one-liners stay as a Linux/Windows **quickstart
  panel** — the existing `.qs-card` content (Linux `bootstrap.sh` + Windows `bootstrap.ps1`,
  `dev`/`prod` badges, sub-copy), restyled, kept as real `<pre>` blocks so copy-buttons attach. The
  "Linux/Windows quickstart" CTA buttons in the terminal scroll to / focus this panel (and `#setup`).
  The one-liners are NOT removed or hidden — the top-of-page copy-paste path is unchanged.
  `.hero-help` jump links kept.
- **Section markers:** each `<section>`'s `<h2>` becomes a `01 — TITLE` marker: a small mono numbered
  chip + the mono heading + a dashed rule filling the row. (Decorative number via CSS counter; the
  `<h2 id>` and its text stay for scroll-spy + anchors.)
- **Stack cards (`.stack-card`):** category-colored left accent edge, mono uppercase `.layer-label`,
  mono `h3` with emoji `.ico`, sans description, hover-lift. Keep classes.
- **Tool cards (`.tool-card.cat-*`) + chips:** category-colored top edge, mono uppercase `h4`; chips
  become **keycap** pills (mono, `surface-3`, 2px bottom border, hover→accent). Preserve `data-cat`,
  `data-tip` tooltips, `.chip small` sub-tags `(dnf)/(pip)/(ins)/(built-in)`, `.match-hit`, `.sr-only`
  text, and the `#toolbelt-grid` / `#tool-filter` / `#tool-filter-meta` ids.
- **Callouts / badges / notes:** `.callout` = surface card with accent left bar + mono `i` glyph;
  `.badge.dev/.prod` keycap-style; `.note` / `.note-row` muted mono. Keep classes.
- **Code blocks (`<pre>`):** terminal chrome (top dots), the existing injected `.copy-btn` repositioned
  top-right, mono body, horizontal scroll. Subtle token coloring via existing inline `<span>`s only
  where already present — no new syntax-highlighter.
- **Tables:** mono headers (uppercase, `muted`), zebra-free with `border-soft` row rules, rounded
  container; the machine-types and keybind tables read like terminal output.
- **Repo layout tree (`.tree`):** keep `details/summary` structure; restyle connectors as faint mono
  guides; keep `.note` annotations.
- **Flow steps (`.flow .step` + `.arrow`):** numbered mono `.num` tokens, `.lbl`/`.note`, accent
  arrows; used in the bootstrap "what it does, in order" sequences.
- **Tabs (`.tabs` radio + `.tab-labels`/`.tab-panels`/`.tab-panel`):** restyle as terminal segmented
  control; keep the CSS-only radio mechanism and `panel-dev`/`panel-prod`/`ar-panel-*` ids/classes.
- **Troubleshooting (`<details data-ts>`):** keycap/terminal-styled summaries with a rotating caret,
  the existing `#ts-filter` + `#ts-count`; `.checklist` items keep their `::before` glyph.
- **Theme toggle (`.theme-toggle` / `#theme-icon`):** restyled square button; same 3-state JS,
  icons `◐ ☀ ☾`.

## New behavior 11 — hero typed animation (progressive enhancement)

- The terminal hero's **full final content lives in the HTML** (so no-JS / reduced-motion / search
  all see real text). On load, if `matchMedia('(prefers-reduced-motion: reduce)')` does **not**
  match, JS: hides the output lines, "types" the command string, then reveals each `✓` line on a
  short stagger, ending with the blinking caret on the final line. If reduced-motion matches or JS
  is absent, everything is visible immediately. Timer/`requestAnimationFrame`-based; no layout shift
  (reserve height). Runs once; never blocks scroll or input.

## Information architecture

Keep the current, logical section order and all anchors:
`intro → stack (+toolbelt) → machines → layout → setup (config/linux/windows/wsl/wezterm/prompt-keys/
completion) → hosts → daily (+daily-services) → adding → troubleshooting`. No reordering or merging
in v1 (full-overhaul latitude is spent on visuals/components, not on moving correct content). Copy is
edited only for clarity/:length where a line is awkward; technical facts unchanged.

## Responsive / mobile

- ≤900px: sidebar collapses via existing `#toc-collapse-ctrl` + `.mobile-collapsed`; single-column
  main; grids reflow to 1–2 cols; terminal hero stays legible (font clamps, horizontal scroll on the
  command line if needed). Touch targets ≥40px. Theme toggle stays reachable.

## Accessibility

- Maintain/improve contrast in **both** themes (lime on cream is the known risk — use `--hot #3f7d12`
  in light). Visible `:focus-visible` rings on all interactive elements (toggle, search, chips,
  TOC links, buttons, copy). `prefers-reduced-motion` disables the hero animation, caret blink,
  hover transforms, and smooth-scroll easing. Preserve `.sr-only` chip descriptions and ARIA
  (`aria-current`, `aria-expanded`, `aria-label`s). Keyboard nav unbroken.

## Files to touch

1. **`README.html`** — restructured markup for hero, section markers, cards, chips, callouts, code,
   tables, tree, steps, tabs, troubleshooting. Anchors + content preserved. `<head>` keeps the same
   `<link>`/`<script>` refs; `<noscript>` notice kept/updated.
2. **`docs/README/README.css`** — the bulk of the work: rewritten token set + every component.
3. **`docs/README/README.js`** — keep all 10 behaviors (refactor as needed to match new selectors)
   + add behavior 11 (hero typed animation w/ reduced-motion guard).
4. **`CLAUDE_CHANGELOG.md`** — append a row (user-facing surface changed → required by CLAUDE.md).

## Verification plan

- **Render** dark + light, desktop (1440) + mobile (390) via headless Edge; eyeball every section
  type (hero, stack, toolbelt, machines table, layout tree, setup steps/tabs, hosts, daily,
  troubleshooting). Confirm light-mode lime/contrast.
- **Anchors:** grep that all listed `#anchor` ids still exist; click-through TOC + hero jump links.
- **JS behaviors 1–11:** manually exercise each (theme cycle persists; copy on a `<pre>`; `#` anchors;
  scroll-spy active state; `/` + type → highlight/dim + count; `Esc` clears; toolbelt filter dims
  cards / highlights chips; troubleshooting filter opens matches; resize ≤900px collapses TOC;
  scroll-progress fills; reduced-motion shows static hero).
- **File hygiene:** `file README.html docs/README/README.*` shows no CRLF; `git ls-files --stage`
  shows `100644`; UTF-8 glyphs intact.
- **Regression sweep:** confirm no broken internal links and that the page works opened directly from
  `file://` (no console errors beyond pre-existing benign ones).

## Risks

- Token/contrast regressions in light mode (mitigate: render + check both themes).
- Drift between new HTML selectors and README.js hooks (mitigate: the selector contract above is the
  checklist; behaviors 1–11 verified explicitly).
- Animation jank / layout shift on the hero (mitigate: reserve height, reduced-motion fallback,
  run-once).
- Scope creep into content rewrites (mitigate: anchors + content frozen; copy edits only for clarity).
