// Resume a Claude Code session: a dialog listing the saved sessions on the shown space's
// machine (this computer, a WSL distro or an SSH host), newest first, the ones started in
// this folder on top. Type to filter, Up/Down and Enter (or a click) opens the session in
// a new tab of this space, in the folder it was started in: `claude --resume <id>`.
// The list comes from list.py, run there with that machine's python (it reads
// ~/.claude/projects; nothing is written).
import { View, div } from "gpui-kit";
import { v_flex, h_flex, InputState, Input, ScrollHandle } from "gpui-base";
import { spaces, panes, focused, exec, run, theme, props, closeOverlay, appHome, window, checking } from "herdr";
import * as fs from "fs/promises";

const ROW = 46;

function ago(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 1) return "now";
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  return d < 30 ? `${d}d ago` : `${Math.floor(d / 30)}mo ago`;
}

const norm = (path) => (path ?? "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();

export default class Sessions extends View {
  init(_props, cx) {
    this.all = []; this.total = 0; this.filter = ""; this.at = 0; this.state = "loading"; this.error = "";
    this.scroll = ScrollHandle.new();
    this.handle = cx.focus_handle();
    const space = spaces().find((s) => s.active), f = focused();
    const pane = f?.pane ? panes().find((p) => p.pane === f.pane) : null;
    this.space = space?.id ?? null;
    this.on = space?.machine ?? null;
    this.cwd = norm(pane?.cwd || f?.cwd || space?.folder);
    this.input = InputState.new({ placeholder: "Filter by title or folder…" });
    this.input.on("change", (_e, cx) => { this.filter = this.input.value(); this.at = 0; this.scroll.scroll_to_item(0); cx.notify(); });
    this.input.on("submit", () => this.open(this.rows()[this.at]));
    if (checking()) return;
    this.input.focus();
    cx.timer.after(400, () => this.input.focus());
    cx.spawn(async (cx) => {
      try {
        const script = await fs.readFile(`${appHome()}/mods/sessions/list.py`, "utf8");
        // This computer's python is `python` on Windows; everywhere else python3.
        const python = !this.on && window()?.platform === "windows" ? "python" : "python3";
        const r = await exec(python, ["-c", script, "80"], { on: this.on, timeout: 30000 });
        if (r.code !== 0) throw new Error((r.stderr || r.stdout).trim().split("\n").pop() || `${python} exited ${r.code}`);
        const data = JSON.parse(r.stdout);
        this.all = data.sessions ?? []; this.total = data.total ?? this.all.length; this.state = "ready";
      } catch (error) {
        this.state = "error"; this.error = String(error.message ?? error);
      }
      cx.notify();
    });
  }

  close() { closeOverlay(props().overlay); }

  // Sessions of this folder first, each group newest first (list.py's order).
  rows() {
    const f = this.filter.trim().toLowerCase();
    const shown = f ? this.all.filter((s) => `${s.title} ${s.cwd} ${s.branch}`.toLowerCase().includes(f)) : this.all;
    const here = (s) => norm(s.cwd) === this.cwd;
    return [...shown.filter(here), ...shown.filter((s) => !here(s))];
  }

  open(session) {
    if (!session) return;
    this.close();
    const args = { folder: session.cwd, argv: ["claude", "--resume", session.id] };
    if (this.space) args.space = this.space;
    run("tab.new", args);
  }

  render() {
    const t = theme(), rows = this.rows(), now = Date.now();
    this.at = Math.max(0, Math.min(this.at, rows.length - 1));
    const where = this.on ?? "this computer";
    const row = (s, i) => {
      const on = i === this.at, here = norm(s.cwd) === this.cwd;
      return h_flex().id(`session-${s.id}`).h(ROW).flex_none().mx(4).px(10).gap(10).items_center().rounded(7).cursor_pointer()
        .when(on, (el) => el.bg(t.hover)).hover((st) => st.bg(t.hover))
        .on_click(() => this.open(s))
        .child(v_flex().flex_1().min_w(0).gap(1)
          .child(div().truncate().text_color(t.foreground).child(s.title))
          .child(h_flex().gap(6).items_center().text_size(11.5).text_color(t.muted)
            .when(here, (el) => el.child(div().flex_none().px(5).rounded(4).bg(t.selected).text_color(t.foreground).text_size(10.5).child("this folder")))
            .child(div().min_w(0).truncate().child(s.branch && s.branch !== "HEAD" ? `${s.cwd} \u00b7 ${s.branch}` : s.cwd))))
        .child(div().flex_none().text_size(11.5).text_color(t.dim).child(ago(now - s.at)));
    };
    return v_flex().id("sessions").track_focus(this.handle).size_full().min_h(0).p(18).gap(10).bg(t.popover).text_size(13)
      .on_key_down((e, cx) => {
        if (e.key === "escape") return this.close();
        if (!rows.length) return;
        if (e.key === "down") this.at = (this.at + 1) % rows.length;
        else if (e.key === "up") this.at = (this.at + rows.length - 1) % rows.length;
        else return;
        this.scroll.scroll_to_item(this.at);
        cx.stop_propagation();
        cx.notify();
      })
      .child(h_flex().items_center().gap(8)
        .child(div().text_size(15).font_semibold().text_color(t.foreground).child("Resume a Claude Code session"))
        .child(div().flex_1().min_w(0).truncate().text_size(11.5).text_color(t.dim).child(`on ${where}`))
        .child(div().id("sessions-esc").px(6).py(2).rounded(5).text_size(11).text_color(t.dim).cursor_pointer().hover((s) => s.bg(t.hover).text_color(t.foreground)).on_click(() => this.close()).child("Esc")))
      .child(h_flex().h(36).flex_none().px(10).items_center().rounded(9).border_1().border_color(t.accent).bg(t.background)
        .child(Input.new(this.input).flex_1().h_full().text_size(12.8).text_color(t.foreground)))
      .child(v_flex().id("sessions-list").flex_1().min_h(0).overflow_y_scrollbar().track_scroll(this.scroll)
        .when(this.state === "loading", (el) => el.child(div().p(10).text_color(t.dim).child(`Reading the sessions on ${where}…`)))
        .when(this.state === "error", (el) => el.child(div().p(10).text_color(t.blocked).child(`Couldn't list the sessions on ${where}: ${this.error}`)))
        .when(this.state === "ready" && !rows.length, (el) => el.child(div().p(10).text_color(t.dim).child(this.all.length ? "No session matches." : "No saved Claude Code sessions here.")))
        .children(this.state === "ready" ? rows.map(row) : []))
      .when(this.state === "ready" && this.total > this.all.length, (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(`The ${this.all.length} most recent of ${this.total}.`)));
  }
}
