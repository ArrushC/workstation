// Ctrl-click on a path in a terminal on another machine: open it in Zed here, at its
// line. A path on this computer keeps Herdr's own opener.
import { notify } from "herdr";
import { openInZed, resolvePath } from "./open.js";

export async function handleLink({ link, source }) {
  if (link.kind !== "file" || !source.machine) return "pass";
  const path = resolvePath(link, source);
  if (!path) return "pass";
  try {
    await openInZed({ path, on: source.machine, line: link.line, column: link.column });
  } catch (error) {
    notify({ title: "Open in Zed failed", body: String(error.message ?? error), level: "error" });
  }
  return "handled";
}
