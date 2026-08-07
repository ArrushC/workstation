# TUI Dashboard & Navigation Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Arrow-key navigation (dashboard card grid walk + ctrl+←/→ panel cycling), a live Health quadrant fed from the health cache/services/interop readers, and a full-bleed equal-quadrant dashboard layout.

**Architecture:** A pure `build_health_rollup()` in `core/health.py` (Textual-free, fully injectable) produces a `HealthRollup` model; the app's existing `_load_summary` thread worker builds it and `_apply_summary` hands it to the dashboard. Arrow navigation is a positional 2×2 walk on `Card` bindings; panel cycling is two app-level ctrl bindings. Layout is CSS-only.

**Tech Stack:** Python ≥3.14, Textual 8.x, pydantic v2, pytest + pytest-asyncio, uv.

**Spec:** `docs/superpowers/specs/2026-08-07-tui-dashboard-polish-design.md`.

## Global Constraints

- Branch: `feat/tui-dashboard-polish` (created off main; spec committed). Push after every commit. PR targets main.
- No textual import under `core/`. Established rendering discipline: dynamic text markup-inert (the rollup renders fixed-vocabulary states + themed glyphs only).
- Native table arrow navigation untouched; bare arrows gain NO app-level bindings.
- Suite enters at 168 passed; env-independent (inject everything).
- Pre-commit invariant hook stays green; never `--no-verify`. Conventional-commit subjects as given.

---

### Task 1: Health rollup core + live quadrant + full-bleed layout

**Files:**
- Modify: `tui/src/workstation_tui/core/models.py` (append), `tui/src/workstation_tui/core/health.py` (append)
- Modify: `tui/src/workstation_tui/app/app.py` (`_load_summary`/`_apply_summary`)
- Modify: `tui/src/workstation_tui/app/panels/dashboard.py` (CSS + `update_health`)
- Test: `tui/tests/test_health_core.py` (append), `tui/tests/test_dashboard.py` (append/adjust)

**Interfaces:**
- `HealthRollup(BaseModel)` in models.py: `checks: dict[str, bool | None]` (True ok / False failed / None never-ran, keyed by check_id), `services: str` (e.g. `"3/4 active"` or a gating reason), `interop: str | None` (None when not WSL).
- `health.build_health_rollup(cache: dict[str, CheckResult], ctx: HostContext, services_reader: Callable[[], dict[str, str]], interop_reader: Callable[[], str]) -> HealthRollup` — checks from `CHECKS` order; services: gated FIRST (is_wsl → `"services n/a on WSL"`; not has_systemctl → `"systemctl not available"`; mode != "dev" → `"services are dev-machine-only"`), only calls `services_reader` when ungated (closing the phase-6 deferred wasted-subprocess minor at the core level); interop only read when `ctx.is_wsl`. Never raises.
- `DashboardPanel.update_health(r: HealthRollup) -> None` — renders the health card: heading, one glyph-per-check line (✓ green / ✗ red / — dim, labels doctor/updates/invariants/templates), services line, interop line (when present). Card stays a jump target; plain text mirrors for `summary_text()`.
- `_load_summary` additionally builds the rollup (cache via `load_cache(self.health_cache_path)`, ctx from the freshly-built summary.context, the app's reader injectables); `_apply_summary(summary, rollup)` passes it through (sole caller updated).
- CSS: `DashboardPanel { height: 1fr; padding: 1 1; }`, `#cards { height: 1fr; grid-size: 2 2; grid-rows: 1fr 1fr; grid-columns: 1fr 1fr; grid-gutter: 1 2; }`, `.card { height: 100%; padding: 1 2; ... }` (background/border unchanged).

- [ ] **Step 1: Write the failing core tests** (append to `tui/tests/test_health_core.py`):

```python
def test_build_health_rollup_states_and_gating() -> None:
    import time as _time

    from workstation_tui.core.health import build_health_rollup
    from workstation_tui.core.models import CheckResult

    cache = {
        "doctor": CheckResult(check_id="doctor", ok=True, summary="ok",
                              finished_at=_time.time(), returncode=0),
        "invariants": CheckResult(check_id="invariants", ok=False, summary="bad",
                                  finished_at=_time.time(), returncode=1),
    }
    calls: list[str] = []

    def services_reader():
        calls.append("services")
        return {"docker": "active", "dozzle": "active",
                "cockpit": "inactive", "rsyslog": "active"}

    # WSL dev context → services gated, reader NOT called, interop read.
    rollup = build_health_rollup(cache, CTX, services_reader, lambda: "enabled")
    assert rollup.checks == {"doctor": True, "check-updates": None,
                             "invariants": False, "templates": None}
    assert rollup.services == "services n/a on WSL"
    assert rollup.interop == "enabled"
    assert calls == []

    # Non-WSL dev context → live services count, no interop.
    ctx = CTX.model_copy(update={"is_wsl": False})
    rollup = build_health_rollup(cache, ctx, services_reader, lambda: "enabled")
    assert rollup.services == "3/4 active"
    assert rollup.interop is None
    assert calls == ["services"]

    # Prod context → dev-only reason, reader still not called again.
    ctx = CTX.model_copy(update={"is_wsl": False, "mode": "prod"})
    rollup = build_health_rollup(cache, ctx, services_reader, lambda: "enabled")
    assert rollup.services == "services are dev-machine-only"
    assert calls == ["services"]
```

- [ ] **Step 2: Write the failing dashboard tests** (append to `tui/tests/test_dashboard.py`; adjust any existing assertion on the old static health text):

```python
async def test_health_card_renders_rollup(tmp_path) -> None:
    import time as _time

    from workstation_tui.core.health import save_cache
    from workstation_tui.core.models import CheckResult

    save_cache(tmp_path / "health.json", {
        "doctor": CheckResult(check_id="doctor", ok=True, summary="31/31 ok",
                              finished_at=_time.time(), returncode=0),
    })
    app = WorkstationApp(
        summary_provider=fake_provider,
        health_cache_path=tmp_path / "health.json",
        interop_reader=lambda: "enabled",
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        text = app.query_one("#dashboard").summary_text()
        assert "doctor" in text
        assert "enabled" in text          # interop (FAKE_SUMMARY is WSL)
        assert "n/a on WSL" in text       # services gating reason


async def test_cards_fill_area_equally() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test(size=(100, 40)) as pilot:
        await pilot.pause()
        cards = list(app.query(".card"))
        assert len(cards) == 4
        widths = {c.region.width for c in cards}
        heights = {c.region.height for c in cards}
        assert len(widths) == 1, f"unequal widths: {widths}"
        assert len(heights) == 1, f"unequal heights: {heights}"
        # full-bleed: the grid claims most of the content height
        grid = app.query_one("#cards")
        assert grid.region.height >= 30
```

- [ ] **Step 3: Verify failures, implement per the Interfaces block.** `update_summary` no longer writes the health card (delete its static block — `update_health` owns the card); `on_mount`'s loading state keeps all four cards. `_apply_summary(summary, rollup)` calls both `update_summary` and `update_health`. Glyph line built from theme `M` colors: `✓` green / `✗` red / `—` overlay0, label after each glyph, joined with ` · `; services/interop lines muted-labeled. All state words are fixed vocabulary — markup-safe by construction; keep the card's plain mirror in sync.

- [ ] **Step 4: Run to verify pass** — full suite (REAL count; expect 170: 168 + 3 new − 1 if an old health-text assertion was folded rather than kept... report the true number). **Step 5: Commit** `feat(tui): live dashboard health quadrant + full-bleed equal card grid`, push.

---

### Task 2: Arrow-key navigation

**Files:**
- Modify: `tui/src/workstation_tui/app/panels/dashboard.py` (Card bindings + panel walk + auto-focus)
- Modify: `tui/src/workstation_tui/app/app.py` (ctrl bindings + cycle action + dashboard auto-focus on switch)
- Modify: `tui/src/workstation_tui/app/widgets/help_screen.py` (global keys)
- Test: `tui/tests/test_arrow_nav.py`

**Interfaces:**
- `Card.BINDINGS` gains `left/right/up/down` → `action_move("left"|…)` → `DashboardPanel.move_focus(from_card_id, direction)`: positional walk over `CARD_TARGETS` order as a 2×2 grid (index = row*2+col; provision TL, dotfiles TR, fleet BL, health BR); moves focus to the neighbor; no wrapping (edge presses keep focus).
- `DashboardPanel.focus_first_card()` — focuses `#card-provision`.
- `WorkstationApp.BINDINGS` gains `("ctrl+left", "cycle_panel(-1)", "Prev panel")` and `("ctrl+right", "cycle_panel(1)", "Next panel")`; `action_cycle_panel(delta: int)` — current panel index in `PANELS`, `switch_panel(PANELS[(idx + delta) % len(PANELS)][0])`.
- `switch_panel` calls `focus_first_card()` when the target is `dashboard`; `WorkstationApp.on_mount` focuses the first card after the initial refresh kick (dashboard is the initial panel).
- HelpScreen global-keys section gains `←→↑↓ — move between dashboard cards` and `ctrl+←/→ — previous/next panel`.

- [ ] **Step 1: Write the failing tests** — `tui/tests/test_arrow_nav.py`:

```python
from workstation_tui.app.app import WorkstationApp
from tests.test_app_shell import fake_provider


def make_app() -> WorkstationApp:
    return WorkstationApp(summary_provider=fake_provider)


async def test_dashboard_auto_focuses_first_card() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.focused is not None and app.focused.id == "card-provision"


async def test_arrow_walk_moves_between_cards() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("right")
        assert app.focused.id == "card-dotfiles"
        await pilot.press("down")
        assert app.focused.id == "card-health"
        await pilot.press("left")
        assert app.focused.id == "card-fleet"
        await pilot.press("up")
        assert app.focused.id == "card-provision"
        await pilot.press("left")            # edge: no wrap
        assert app.focused.id == "card-provision"
        await pilot.press("up")              # edge: no wrap
        assert app.focused.id == "card-provision"


async def test_ctrl_arrows_cycle_panels_with_wrap() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("ctrl+right")
        assert app.query_one("#content").current == "provision"
        await pilot.press("ctrl+left")
        assert app.query_one("#content").current == "dashboard"
        await pilot.press("ctrl+left")       # wrap backwards
        assert app.query_one("#content").current == "health"
        await pilot.press("ctrl+right")      # wrap forwards
        assert app.query_one("#content").current == "dashboard"


async def test_ctrl_arrows_work_from_focused_table() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("ctrl+right")
        assert app.query_one("#content").current == "dotfiles"


async def test_enter_still_opens_focused_card() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("right")
        await pilot.press("enter")
        assert app.query_one("#content").current == "dotfiles"
```

(NOTE: `make_app` relies on Task 1's app defaults — `summary_provider` fake keeps everything else inert; no runner interaction occurs in these tests.)

- [ ] **Step 2: Verify failures, implement per the Interfaces block.** Returning to the dashboard via `1`/click/ctrl-cycling re-focuses the first card (single code path: `switch_panel`).

- [ ] **Step 3: Run to verify pass** — full suite (REAL count; expect Task-1 count + 5). **Step 4: Commit** `feat(tui): arrow-key card walk + ctrl+arrow panel cycling`, push.

---

### Task 3: Docs + gate + PR

**Files:**
- Modify: `README.html` (§tui keys table + Dashboard block), `CLAUDE_CHANGELOG.md`, `docs/superpowers/specs/2026-08-05-workstation-tui-design.md` (deltas follow-up note)

- [ ] **Step 1:** README §tui: keys table gains `←→↑↓` (dashboard cards) + `ctrl+←/→` (panel cycling) rows; Dashboard block's health-card sentence now describes the live rollup (checks glyphs, services count/reason, interop). CLAUDE_CHANGELOG row: `| TUI dashboard polish: arrow-key card walk + ctrl+arrow panel cycling, live health quadrant, full-bleed equal card grid | Yes | §tui keys table + Dashboard block updated |`. Spec `2026-08-05-...-design.md` as-built-deltas health-card bullet gains `(closed by the dashboard-polish change, 2026-08-07)`.

- [ ] **Step 2: Gate**

```bash
make -C makefile lint MODE=prod && make -C makefile tui-test MODE=prod && bash scripts/check-templates.sh
```

- [ ] **Step 3: Commit + PR** — `docs: dashboard-polish keys + health-card truth-up`; PR `feat(tui): dashboard polish — arrow nav, live health quadrant, full-bleed grid` to main; `gh pr checks --watch`. Hand to the user (visual smoke: full-bleed grid + arrow feel).
