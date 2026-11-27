// A Markdown file, rendered, as a pane: props { file, on } (on: the machine it is on,
// null for this computer). It follows the file: re-read every 3 s while the window
// shows, redrawn only when the text changed. Opened by this mod's link handler
// (ctrl-click a .md path in a terminal) or `pane.split {mod: "markdown", props}`.
import { View, div } from "gpui-kit";
import { v_flex, h_flex, TextView } from "gpui-base";
import { readTextFile, openOverlay, theme, settings, window, props, checking } from "herdr";

export default class Markdown extends View {
  init(initial, cx) {
    // A pane's props come from props(); an overlay's also arrive here.
    const given = initial?.file ? initial : props() ?? {};
    this.file = given?.file ?? null;
    this.on = given?.on ?? null;
    this.text = null; this.error = null; this.raw = false; this.loaded = false;
    if (checking() || !this.file) return;
    this.load(cx);
    cx.timer.every(3000, (cx) => { if (window()?.visible !== false) this.load(cx); });
  }

  load(cx) {
    if (this.reading) return;
    this.reading = true;
    cx.spawn(async (cx) => {
      let text = null, error = null;
      try {
        text = await readTextFile(this.file, { on: this.on });
        if (text === null) error = "No such file (or it is not readable).";
      } catch (e) { error = `Cannot read it (over 1 MiB, not text, or the machine is unreachable): ${e.message ?? e}`; }
      this.reading = false;
      const changed = !this.loaded || text !== this.text || error !== this.error;
      this.loaded = true; this.text = text; this.error = error;
      if (!changed) return;
      cx.notify();
      // The text view lays its text out a frame late: one more draw shows it.
      cx.timer.after(250, (cx) => cx.notify());
    });
  }

  render() {
    const t = theme();
    const name = (this.file ?? "").split(/[\\/]/).pop() || "Markdown";
    const button = (id, label, action, on = false) => div().id(id).h(24).px(8).flex().flex_none().items_center().rounded(6).text_size(11.5).cursor_pointer()
      .bg(on ? t.selected : t.background).text_color(on ? t.foreground : t.muted).hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation()).on_click(action).child(label);
    const note = (text, color) => div().p(16).text_color(color).child(text);
    const mono = settings().font_family ?? "JetBrains Mono";
    // The text view scrolls itself: it needs a box with a definite height around it.
    const body = !this.file ? note("No file: open one with ctrl-click on a .md path in a terminal.", t.dim)
      : this.error ? note(this.error, t.blocked)
      : this.text === null ? note("Loading…", t.dim)
      : this.raw ? div().size_full().px(16).py(10).font_family(mono).text_size(settings().font_size ?? 13)
        .child(TextView.markdown("md-raw", "`````text\n" + this.text.replace(/`````/g, "` ` ` ` `") + "\n`````").selectable(true).scrollable(true).size_full())
      : div().size_full().px(22).py(10).child(TextView.markdown("md-view", this.text).selectable(true).scrollable(true).size_full());
    return v_flex().id("markdown").size_full().min_h(0).bg(t.background).text_color(t.foreground).text_size(14)
      .child(h_flex().h(36).flex_none().px(12).gap(8).items_center().border_b(1).border_color(t.border)
        .child(div().flex_none().font_semibold().text_size(12.5).child(name))
        .child(div().flex_1().min_w(0).truncate().text_size(11.5).text_color(t.dim).child(`${this.on ? `${this.on}: ` : ""}${this.file ?? ""}`))
        .when(Boolean(this.file), (el) => el
          .child(button("md-raw-toggle", "Source", (_e, cx) => { this.raw = !this.raw; cx.notify(); }, this.raw))
          .child(button("md-zed", "Open in Zed", () => openOverlay({ mod: "zed", kind: "popup", props: { file: this.file, on: this.on } })))))
      .child(div().flex_1().min_h(0).w_full().child(body));
  }
}
