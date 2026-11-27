// Ctrl-click on a Markdown file in a terminal: read it rendered, in a pane beside that
// terminal. Works for files on other machines too (the pane reads them there).
import { run } from "herdr";

function resolvePath(link, source) {
  if (link.path) return link.path;
  let raw = (link.raw ?? "").replace(/^file:\/\/[^/]*/, "");
  if (!link.raw?.startsWith("file:")) raw = raw.replace(/(?::\d+(?:[:-]\d+)?|#L\d+(?:-L?\d+)?)$/, "");
  if (!raw) return null;
  if (raw.startsWith("/") || /^[A-Za-z]:[\\/]/.test(raw)) return raw;
  if (raw.startsWith("~") || !source.cwd) return null;
  const out = [];
  for (const part of `${source.cwd}/${raw}`.split("/")) {
    if (part === "." || (part === "" && out.length)) continue;
    if (part === "..") { if (out.length > 1) out.pop(); continue; }
    out.push(part);
  }
  return out.join("/") || "/";
}

export function handleLink({ link, source }) {
  if (link.kind !== "file") return "pass";
  const file = resolvePath(link, source);
  if (!file) return "pass";
  const args = { direction: "right", mod: "markdown", props: { file, on: source.machine ?? null } };
  if (source.pane) args.pane = source.pane;
  run("pane.split", args);
  return "handled";
}
