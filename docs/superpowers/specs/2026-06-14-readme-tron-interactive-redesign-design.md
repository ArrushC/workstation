# README.html — "Tron / digital frontier" interactive 3D redesign

**Date:** 2026-06-14
**Scope:** `README.html` + `docs/README/README.css` + `docs/README/README.js` (the self-contained
trio) + a `CLAUDE_CHANGELOG.md` row. No Make/bootstrap/chezmoi/versions changes — pure docs.
**Status:** Direction, palette, grid intensity, interaction set, and dense-content readability all
confirmed by the user via the brainstorming visual companion (2026-06-14). Awaiting spec review
before writing the implementation plan.

## Goal

Transform the user-facing reference (`README.html`) from the current **"Terminal, Elevated"** dark
developer doc into an **animated, 3D, Tron-style "digital frontier"** — a neon vector world the
reader can move through and play with. Deep-void background, a glowing perspective grid horizon,
cyan + orange neon edges, real 3D depth/parallax, and a rich, hand-written interaction layer that
makes the page feel alive and "pinnable." This is a full visual + motion overhaul of the three
files, **not** a content rewrite. Every section, anchor, and existing behavior survives; the page
still opens from `file://` with zero external dependencies.

## Decisions (user-confirmed 2026-06-14, via live mockups)

1. **Direction: animated 3D "Tron."** Neon grid, dark void, glowing vector edges, depth + motion.
   (Chosen over holographic-glass, mission-control-isometric, tactile-keycaps, and living-grid
   directions shown side-by-side.)
2. **Palette: Cyan + Orange (classic Tron).** Cyan `#67f0ff` primary, orange `#ffa24d` secondary.
   (Chosen over Cyan+Lime and Repo-Blue+Lime, toggled live.)
3. **Grid: Immersive.** The grid is bright and full-bleed — but sits **behind a scrim** in content
   regions so prose keeps full contrast (readability confirmed on a dense-content mockup: tool
   chips + machine table + callout + troubleshooting row).
4. **Interactivity: everything ("all").** The full interaction menu is in scope (see "Interaction
   engine" below): mouse-parallax world, cursor light-trail + reticle, click energy pulses / grid
   ripples, 3D pointer-tilt on cards everywhere, scroll-as-camera, section boot-on-scroll, a
   first-load boot/"system online" intro, a Konami "derez" easter egg, and opt-in ambient SFX.

## Relationship to the prior redesign

This **supersedes the visual layer** of `2026-06-13-readme-redesign-design.md` ("Terminal,
Elevated"), which is what currently ships. We keep that redesign's **structure, IA, anchors, and
the 11 JS behaviors** as the foundation and re-skin + heavily extend them. The earlier spec's
preservation contract (anchors, content, behaviors, file-care) still holds verbatim and is repeated
below — nothing it protected may regress.

## Non-goals / constraints (must hold)

- **Stays the trio.** `README.html` + `docs/README/README.css` + `docs/README/README.js`. **No new
  asset files**, no external JS/CSS/font deps beyond the existing Google Fonts `@import` (IBM Plex
  Mono/Sans). No build step. No WebGL library, no Three.js — **all 3D/animation is hand-written CSS
  3D + 2D `<canvas>` + vanilla JS**. Opens correctly from `file://` on disk.
- **All 18 section `#anchor` ids preserved** (CLAUDE.md and in-page links route to them):
  `#intro #stack #toolbelt #machines #layout #setup #setup-config #setup-linux #setup-windows`
  `#setup-wsl #setup-wezterm #prompt-keys #completion #hosts #daily #daily-services #adding`
  `#troubleshooting`. Section **content** is preserved (toolbelt chips, tables, trees, steps,
  troubleshooting entries, keybind tables, quickstart one-liners, etc.).
- **All 11 current JS behaviors preserved** (may be refactored/renamed internally, but feature + UX
  kept): (1) 3-state theme toggle → `localStorage["readme-theme"]`; (2) copy-to-clipboard on every
  `<pre>`; (3) `#` heading anchors on `main h2/h3/h4[id]`; (4) scroll-spy TOC (IntersectionObserver
  → `.active` + `aria-current`); (5) global search (`<mark>` highlight, `.dimmed` sections,
  `li.hidden`, `#toc-search-meta` count); (6) `/` focuses search, `Esc` clears/blurs; (7) toolbelt
  filter (`#tool-filter` → `.tool-card.dimmed`, `.chip.match-hit`, `#tool-filter-meta`);
  (8) troubleshooting filter (`#ts-filter` → `[data-ts]`, `#ts-count`); (9) mobile TOC collapse
  (`#toc-collapse-ctrl`, `.mobile-collapsed`, `aria-expanded`); (10) scroll-progress bar
  (`--scroll-progress` on `#scroll-progress`, rAF-throttled); (11) hero typed-animation
  (`.term[data-typed]`). **Behavior 11 is subsumed into the new boot sequence (behavior 12).**
- **File care:** these three are plain UTF-8, **LF**, no BOM (NOT in the PowerShell BOM set, NOT in
  the 0755 shell-script set). Preserve UTF-8 glyphs (`✓ ✗ — ❯ ◐ ▸ ↗`). Keep mode `100644`. No CRLF.
- **No path changes:** CSS stays `docs/README/README.css`, JS `docs/README/README.js`, referenced by
  the same relative `<link>`/`<script>` tags.
- **`prefers-reduced-motion: reduce` is a hard requirement** — it disables *all* parallax, canvas
  FX, tilt, boot intro, scroll-camera, section de-rez, the custom cursor, and caret/glow animation,
  leaving a fully static, fully readable Tron-styled page. No motion, no `<canvas>` rAF loop.
- **Performance budget:** one shared `requestAnimationFrame` scheduler for all live FX; canvas work
  paused when the tab is hidden (`visibilitychange`) and when the hero/section is offscreen
  (IntersectionObserver); pointer handlers throttled to rAF; `devicePixelRatio` capped at 2;
  particle/ripple/trail counts capped. Heavy pointer FX (parallax, trail, reticle, tilt) **auto-off
  on coarse/touch pointers** (`matchMedia('(pointer: fine)')`) and on reduced-motion.
- **CLAUDE_CHANGELOG.md row** appended (user-facing surface changed → required by CLAUDE.md).

## Design system

### Palette tokens (CSS custom properties)

Three theme scopes kept exactly as today: `:root,[data-theme="dark"]`,
`@media (prefers-color-scheme: light) [data-theme="auto"]`, and `[data-theme="light"]`.

**Dark — "the Grid" (default, full Tron):**
- Void: `--void #04070d`, `--void-2 #070c14`; surfaces `--surface #0a121b`, `--surface-2 #0e1822`,
  `--surface-3 #122231` (semi-opaque variants for glass: `rgba(8,15,24,.6–.85)`).
- Lines/borders: `--border #1d3140`, `--border-soft #15242f`, `--grid-line rgba(103,240,255,.16)`
  (content) / `--grid-line-hot rgba(103,240,255,.34)` (hero immersive).
- Text: `--text #dbeefb`, `--text-soft #b8cadb`, `--muted #7f93a6`, `--muted-2 #5f7488`.
- **Cyan accent:** `--c1 #67f0ff`, `--c1-deep #0bb6d6`, `--c1-glow rgba(103,240,255,.5)`.
- **Orange accent:** `--c2 #ffa24d`, `--c2-deep #ff7a18`, `--c2-glow rgba(255,150,60,.5)`.
- Semantics (kept for category coding / states, tuned into the neon language):
  `--ok #5fe39a`, `--warn #ffd166`, `--bad #ff6b6b`, `--linux #5ec8ff`, `--windows #c79bff`,
  `--teal #62e0d8`, `--pink #ff9485`.
- Depth: `--glow-sm/-md/-lg` (neon box-shadows), `--shadow` (deep black drop for layering),
  radii `--r-sm 6 / --r 10 / --r-lg 14`, `--maxw ~64rem` prose measure.

**Light — "daylight grid" (restrained, accessible variant):** Tron is dark-native; light mode is a
deliberately calmer translation so contrast/AA holds and glow doesn't turn to haze on white.
- Cool-pale void `--void #eef2f6`, surfaces `#ffffff`; faint `--grid-line rgba(20,40,60,.06)`.
- **Glow is suppressed** (accents render as solid edges, not blooms). Accents darkened for AA on
  white: cyan→`--c1 #0a86ab`/`--c1-deep #06637f`, orange→`--c2 #c2410c`/`--c2-deep #9a3412`.
  Text `--text #10202b`. The grid horizon becomes a faint static rule; the floor is low-opacity.
- This is the known light-mode risk area (the old "lime on cream"); we verify AA in both themes.

**Fonts:** `--mono` IBM Plex Mono (display, headings, labels, code, chips, terminal), `--sans` IBM
Plex Sans (prose). `--display` = mono.

### The Grid / atmosphere (page chrome)

- **Global background:** a fixed, full-viewport layer (`position:fixed; inset:0; z-index:-1;
  pointer-events:none`) holding (a) a deep radial void gradient, (b) the **neon perspective grid**
  (two repeating-linear-gradients on a `rotateX`-perspective plane, masked to fade at the horizon,
  background-position animated to scroll toward the viewer), (c) a faint starfield, (d) ambient
  cyan/orange radial glows. In content regions a **scrim** (`linear-gradient` darken) sits between
  the grid and the text so prose keeps contrast.
- **Horizon line:** a glowing cyan rule with bloom where grid meets void; gentle opacity pulse.
- **Scroll-progress bar:** thin top bar, `cyan→orange` gradient as a "light trail," width driven by
  the existing `--scroll-progress` JS.
- **An FX `<canvas>`** overlay (fixed, `pointer-events:none`, above background, below content) hosts
  the cursor light-trail, click ripples/pulses, and grid-ripple shockwaves.

### Layout

- Two-column `.layout` (sticky sidebar ~`260px` + `minmax(0,1fr)` main), centered, max ~`1280px`.
- **Sidebar `.toc`** as a "system console": neon brand mark, search field with a `/` keycap, a
  **numbered** contents list; the active scroll-spy item gets a glowing cyan **light-rail** on its
  left edge that slides between items. Keeps `#toc-collapse-ctrl`, `#toc-search-meta`, `.toc-search`,
  `#global-search`, `.kbd-hint` ids/classes.
- **Main** with `--maxw` prose measure on text blocks; grids/cards/tables may go wider.
- **Control cluster** (top-right, where the theme toggle is today): **theme** (`◐ ☀ ☾`, behavior 1),
  **motion/FX** on/off, and **sound** on/off — the latter two new, persisted to `localStorage`,
  with `prefers-reduced-motion` forcing FX off and `aria-pressed` state.

## Component language (all re-skinned to the neon-vector system)

Every component below keeps its existing class/id hooks (search/filter/anchor/scroll-spy contracts)
and gains: a thin neon edge, a deep drop-shadow for layering, HUD corner brackets where it suits,
and pointer-tilt (desktop, motion-on).

- **Hero (`header#intro`):** the centerpiece scene — perspective grid floor + horizon + spinning
  **identity disc** (concentric glowing rings, rotateX-tilted, with a rotating scan arc), the neon
  **terminal window** (`.term[data-typed]`: black-glass, glowing border, corner brackets, an energy
  sweep across the top, the `❯ make MODE=dev provision` command + `✓` output lines + caret), the
  glow `workstation` title with breathing bloom + `dev env` tag, and the CTA buttons as vector
  outlines that fill with light on hover. **Directly beneath**, the existing Linux/Windows
  quickstart one-liners stay as real `<pre>` blocks (copy-buttons attach) — restyled, not removed.
  The hero participates in mouse-parallax + the boot intro.
- **Section markers:** each `<section>`'s `<h2>` becomes a `NN // TITLE` HUD marker (mono numbered
  chip + glowing heading + a neon rule filling the row). Decorative number via CSS counter; the
  `<h2 id>` + text stay for scroll-spy + anchors.
- **Stack / tool cards (`.stack-card`, `.tool-card.cat-*`):** black-glass panels, category-colored
  neon edge, mono uppercase labels, emoji `.ico`. Pointer-tilt + glare + nearest-edge glow.
  Preserve `data-cat`, `data-tip`, `.match-hit`, `.sr-only`, `#toolbelt-grid`, `#tool-filter`,
  `#tool-filter-meta`.
- **Chips:** neon **keycap** pills (mono, glass, 2px bottom edge) that energize (fill + glow + lift)
  on hover. Keep `.chip`, `.chip small` sub-tags `(dnf)/(pip)/(ins)/(built-in)`, `.match-hit`.
- **Callouts / badges / notes:** `.callout` = glass card with a glowing left bar + `ⓘ`; `.badge
  .dev/.prod` as neon keycaps (dev=cyan, prod=orange); `.note`/`.note-row` muted mono.
- **Code blocks (`<pre>`):** terminal chrome (dots + optional corner brackets), the injected
  `.copy-btn` top-right as a neon keycap, mono body, horizontal scroll. Existing inline `<span>`
  token coloring only — no new syntax highlighter.
- **Tables:** glowing mono uppercase headers (orange), thin cyan row rules, rounded glass container;
  rows light up with a cyan left-edge on hover. Reads like a HUD readout.
- **Repo layout tree (`.tree` `details/summary`):** neon connector guides, glowing carets, `.note`
  annotations kept.
- **Flow steps (`.flow .step` + `.arrow`):** numbered neon `.num` tokens, glowing arrows.
- **Tabs (`.tabs` radio + panels):** terminal segmented control with a glowing active segment; keep
  the CSS-only radio mechanism + `panel-dev`/`panel-prod`/`ar-panel-*` ids/classes.
- **Troubleshooting (`<details data-ts>`):** HUD summaries with a rotating glowing caret; keep
  `#ts-filter`, `#ts-count`, `.checklist` `::before` glyphs.

## Interaction engine (new behaviors 12–21, progressive enhancement)

All of the following are **additive, capability-gated, and share one rAF scheduler**. Master gates,
checked once and on change: `prefers-reduced-motion` (off → none of 12–19 run; static page),
`matchMedia('(pointer: fine)')` (coarse/touch → pointer FX 13–16 + reticle off), the **motion/FX
toggle**, and `document.hidden` (pause loop). Each keeps the page usable if it silently no-ops.

12. **Boot / "system online" intro (first load, subsumes behavior 11).** On load (motion on): the
    grid "powers on" (lines draw in + horizon ignites), the title de-rezzes in, and the hero
    terminal **types** the `make` command and streams the `✓` lines (the old behavior-11 animation,
    now the finale). Total ≤ ~2.2s. **Skippable** — any click/scroll/keydown jumps to the final
    state. Reserves layout height (no shift), never blocks scroll/input, runs **once per page load**.
    Reduced-motion / JS-off → fully-rendered static hero immediately.
13. **Mouse-parallax world.** Pointer position drives multi-depth translation of grid / horizon /
    disc / starfield (and a subtle camera feel), plus a 3D tilt of the hero terminal toward the
    cursor. rAF-applied, eased.
14. **Cursor light-trail + reticle.** A canvas Tron light-ribbon streaks behind the pointer and
    fades; a subtle neon **reticle** augments (does not replace) the native cursor. The native
    cursor and text/`input` carets stay fully functional; reticle hidden over text selection where
    it would distract. Auto-off on touch + reduced-motion + FX-off.
15. **Click energy pulses + grid ripples.** Pointer-down emits a neon shockwave ring (+ orange
    sparks) at the click point, and a ripple that travels across the **global grid**. Capped count,
    pooled.
16. **3D pointer-tilt on panels everywhere.** Delegated handler: any `.tilt` card/panel rotates
    toward the cursor with a tracking glare + nearest-edge glow; resets on leave. Desktop + motion
    only.
17. **Scroll-as-camera.** Scroll offset parallaxes the global grid/horizon so the reader "flies"
    through the frontier. Shares the existing scroll listener / rAF with the progress bar; must not
    fight smooth-scroll anchor jumps or scroll-spy.
18. **Section boot-on-scroll (de-rez in).** An IntersectionObserver adds `.booted` as each
    `<section>` enters the viewport → a brief de-rez/power-on reveal (clip/scanline + fade). Runs
    once per section; reduced-motion → sections simply present. Must not alter scroll-spy
    (which uses its own observer) or anchor targets.
19. **Konami "derez" easter egg.** The `↑↑↓↓←→←→ b a` sequence triggers a playful full-page derez/
    reassemble animation. Pure delight; no functional impact; reduced-motion → no-op.
20. **Ambient SFX engine (opt-in).** Synthesized via **Web Audio** (oscillators/noise — *no audio
    asset files*, stays self-contained). Subtle hum/blip on hover/click/boot. **Off by default**,
    behind the **sound toggle**, persisted to `localStorage`; only ever starts after a user gesture
    (no autoplay). Independent of the motion toggle.
21. **FX/sound preferences + global guards.** The motion/FX and sound toggles (control cluster),
    their `localStorage` persistence, `aria-pressed` state, the `prefers-reduced-motion` /
    `pointer:fine` / `visibilitychange` gates, and the single shared rAF scheduler that all live FX
    subscribe to (so there is never more than one loop).

## Accessibility

- **Reduced-motion** fully honored (above) — static, readable, no canvas loop.
- **Contrast in both themes** ≥ WCAG AA for body/UI text; the dark Grid keeps text on scrimmed
  surfaces, the light variant suppresses glow and darkens accents. Verify the light-mode accent/
  orange-on-white pairs explicitly.
- **Keyboard:** all interactive elements reachable; visible `:focus-visible` neon rings; the new
  toggles are real buttons with labels + `aria-pressed`. `/` and `Esc` behaviors unchanged.
- **No seizure risk:** glows *breathe* (slow opacity), no high-frequency strobe; the boot intro and
  derez are brief, single-shot, and reduced-motion-exempt. Click sparks are small and sparse.
- Preserve `.sr-only` text, `aria-current`, `aria-expanded`, `aria-label`s. The decorative
  canvas/grid layers are `aria-hidden` + `pointer-events:none`.
- The custom reticle never blocks selection, links, inputs, or the real cursor; it is purely
  additive and off on touch.

## Information architecture

Unchanged: `intro → stack (+toolbelt) → machines → layout → setup (config/linux/windows/wsl/wezterm/
prompt-keys/completion) → hosts → daily (+daily-services) → adding → troubleshooting`. No reordering
or merging; copy edited only for clarity where a line is awkward; technical facts unchanged.

## Responsive / mobile

- ≤900px: sidebar collapses via the existing `#toc-collapse-ctrl` + `.mobile-collapsed`; single
  main column; grids reflow to 1–2 cols. The hero scene stays legible (font clamps; the disc/parallax
  scale down). **Pointer FX (parallax, trail, reticle, tilt) are off on touch** — the grid still
  animates ambiently and sections still boot on scroll (motion permitting). Touch targets ≥44px.

## Files to touch

1. **`README.html`** — restructured markup for the hero scene (grid/horizon/disc/canvas hooks),
   HUD section markers, glass cards/chips/callouts/tables/tree/steps/tabs/troubleshooting, the
   control cluster (theme + motion + sound). Anchors + content + the 11 behavior hooks preserved.
   `<head>` keeps the same `<link>`/`<script>` refs; `<noscript>` notice updated.
2. **`docs/README/README.css`** — the bulk: new token set (dark Grid + light daylight variant),
   the fixed grid/atmosphere layers, every component re-skinned, glow/depth system, focus rings,
   full `prefers-reduced-motion` block.
3. **`docs/README/README.js`** — keep behaviors 1–11 (refactor to new selectors as needed) and add
   the interaction engine (12–21) as small, isolated subsystems behind capability gates, all driven
   by one shared rAF scheduler + a tiny preferences module.
4. **`CLAUDE_CHANGELOG.md`** — append a row (user-facing surface changed).

## Implementation phases (for the plan)

1. **Tokens + theme**: dark Grid + light daylight variants; verify both render.
2. **Atmosphere**: fixed grid/horizon/starfield/glow layers + scrim + FX canvas scaffolding (static
   first).
3. **Hero scene** markup/CSS (disc, neon terminal, glow title, CTAs, quickstart panel).
4. **Components**: section markers, cards, chips, callouts, code, tables, tree, steps, tabs,
   troubleshooting — re-skin; keep all hooks.
5. **Preserve behaviors 1–11** against the new markup; re-verify each.
6. **Interaction engine 12–21**: shared rAF + prefs module → parallax → trail/reticle → ripples/
   pulses → tilt → scroll-camera → section-boot → boot intro → konami → SFX. Capability gates first.
7. **A11y + perf + fallbacks**: reduced-motion block, touch gating, tab-hidden pause, contrast pass.
8. **Verification + changelog**.

## Verification plan

- **Render** dark + light, desktop (1440) + mobile (390) via headless Edge; eyeball every section
  type. Confirm light-mode AA (cyan/orange on white). Confirm the scrim keeps dense content legible.
- **Anchors:** grep all 18 `#anchor` ids still exist; click-through TOC + hero jump links.
- **Behaviors 1–11:** manually exercise each (theme cycle persists; copy on a `<pre>`; `#` anchors;
  scroll-spy active state; `/`→highlight/dim + count; `Esc` clears; toolbelt filter; troubleshooting
  filter; ≤900px TOC collapse; scroll-progress fills; hero terminal types).
- **Behaviors 12–21:** mouse-parallax + trail + reticle (desktop); click pulse/ripple; card tilt;
  scroll-camera; section de-rez; boot intro plays once + is skippable + reserves height; konami
  derez; SFX only after gesture + only when toggled on; motion toggle kills all FX; sound toggle
  persists.
- **Reduced-motion:** with `prefers-reduced-motion: reduce`, confirm **zero** canvas loop / parallax
  / tilt / boot / cursor, static readable page, theme + filters still work.
- **Perf:** no jank scrolling a long page; canvas pauses on hidden tab; FX off on emulated touch;
  CPU returns to idle when the pointer stops.
- **File hygiene:** `file README.html docs/README/README.*` → no CRLF; `git ls-files --stage` →
  `100644`; UTF-8 glyphs intact. Works opened directly from `file://` (no new console errors).

## Risks

- **Performance** (biggest): many live systems on a long doc. Mitigate — one rAF, IntersectionObserver
  gating, tab-hidden pause, capped particles, DPR≤2, touch/reduced-motion off-paths, `will-change`
  used sparingly.
- **Readability under the immersive grid.** Mitigate — content scrim + scrimmed glass surfaces;
  validated on a dense mockup; AA contrast pass in both themes.
- **Light-mode legibility** (glow→haze, neon-on-white). Mitigate — separate restrained daylight
  token set, glow suppressed, accents darkened, explicit AA check.
- **Selector drift** between new HTML and the 11 preserved behaviors. Mitigate — the hook list above
  is the contract; behaviors 1–11 re-verified explicitly post-reskin.
- **Motion sensitivity / overwhelm.** Mitigate — reduced-motion exemption, a user motion toggle,
  breathing (not strobing) glows, brief single-shot boot/derez.
- **Custom cursor usability.** Mitigate — augment (not replace) the native cursor; off on touch;
  never blocks selection/inputs/links; covered by the motion toggle.
- **Scope creep into content rewrites.** Mitigate — anchors + content frozen; copy edits only for
  clarity.

## Open decisions surfaced for review (defaults chosen; veto at spec review)

1. **Light mode kept** as a restrained "daylight grid" variant (vs. dark-only). Default: **keep it**
   (the 3-state toggle is a preserved behavior; accessibility benefits).
2. **Custom cursor = augment** (reticle overlay + native cursor) rather than fully replacing the
   system cursor. Default: **augment** (safer for a reading doc).
3. **SFX = synthesized Web Audio, off by default, gesture-gated.** Default: **in, but opt-in** (keeps
   the trio self-contained; no audio files).
4. **Boot intro runs once per page load** and is skippable. Default: **once + skippable** (re-opening
   a pinned tab won't replay endlessly within a session navigation; a fresh load replays briefly).
