// "Open this folder in Zed" (the palette), or one file for another mod:
// openOverlay({ mod: "zed", kind: "popup", props: { file, on, line } }). It opens Zed
// and closes itself; a failure stays as a toast.
import { View, div } from "gpui-kit";
import { spaces, panes, focused, props, closeOverlay, notify, theme, checking } from "herdr";
import { openInZed } from "./open.js";

function here() {
  const space = spaces().find((s) => s.active), f = focused();
  const pane = f?.pane ? panes().find((p) => p.pane === f.pane) : null;
  return { path: pane?.cwd || f?.cwd || space?.folder, on: space?.machine ?? null };
}

export default class Zed extends View {
  init(initial, cx) {
    if (checking()) return;
    const given = initial?.file ? initial : props() ?? {};
    const target = given?.file ? { path: given.file, on: given.on ?? null, line: given.line } : here();
    this.label = target.path ?? "";
    cx.spawn(async () => {
      try {
        if (!target.path) throw new Error("no folder to open");
        await openInZed(target);
      } catch (error) {
        notify({ title: "Open in Zed failed", body: String(error.message ?? error), level: "error" });
      }
      closeOverlay(props().overlay);
    });
  }

  render() {
    const t = theme();
    return div().w_full().px(14).py(12).bg(t.popover).text_size(12.5).text_color(t.muted).truncate().child(`Opening ${this.label} in Zed…`);
  }
}
