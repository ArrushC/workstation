// Opens a file or folder in Zed on this computer, wherever it lives: a path on this
// computer as it is, one in the WSL distro with `zed --wsl <distro>`, one on an SSH
// machine as `ssh://user@host/path` (Zed's remote projects). Zed's CLI returns at once.
import { exec, hc } from "herdr";

// "wsl.exe -d AlmaLinux-9 -e sh -c" (herdr-core's --via for a WSL distro) -> "AlmaLinux-9".
const WSL = /^(?:\S*[\\/])?wsl(?:\.exe)?\s.*?(?:-d|--distribution)\s+(\S+)/i;

// How herdr-core reaches `machine`: { wsl } or { ssh: "user@host" }. Null: unknown.
export async function reach(machine) {
  const r = await hc(["machine", "ls", "--json"]);
  if (r.code !== 0) throw new Error(r.stderr.trim() || "hc machine ls failed");
  const found = (JSON.parse(r.stdout).machines ?? []).find((m) => m.name === machine);
  if (!found) return null;
  const wsl = WSL.exec(found.target ?? "");
  if (wsl) return { wsl: wsl[1] };
  return found.via ? null : { ssh: found.target };
}

// Zed's arguments for `path` (absolute there) on `machine` (null: this computer).
export function zedArgs(path, how, line, column) {
  const at = line ? `:${line}${column ? `:${column}` : ""}` : "";
  if (!how) return [`${path}${at}`];
  if (how.wsl) return ["--wsl", how.wsl, `${path}${at}`];
  return [`ssh://${how.ssh}${path.startsWith("/") ? "" : "/"}${encodeURI(path)}${at}`];
}

export async function openInZed({ path, on, line, column }) {
  const how = on ? await reach(on) : null;
  if (on && !how) throw new Error(`Zed can't reach the machine ${on}: only SSH machines and WSL distros`);
  if (on && !path.startsWith("/")) throw new Error(`not an absolute path on ${on}: ${path}`);
  const r = await exec("zed", zedArgs(path, how, line, column), { timeout: 20000 });
  if (r.code !== 0) throw new Error((r.stderr || r.stdout).trim() || `zed exited ${r.code}`);
}

// A clicked path as an absolute one: Herdr's own answer, else the text against the
// terminal's folder (remote paths come unresolved). Null when it can't be told.
export function resolvePath(link, source) {
  if (link.path) return link.path;
  let raw = (link.raw ?? "").replace(/^file:\/\/[^/]*/, "");
  if (!link.raw?.startsWith("file:")) raw = raw.replace(/(?::\d+(?:[:-]\d+)?|#L\d+(?:-L?\d+)?)$/, "");
  if (!raw) return null;
  if (raw.startsWith("/") || /^[A-Za-z]:[\\/]/.test(raw)) return raw;
  if (raw.startsWith("~")) return null;
  if (!source.cwd) return null;
  const parts = `${source.cwd}/${raw}`.split("/"), out = [];
  for (const part of parts) {
    if (part === "." || (part === "" && out.length)) continue;
    if (part === "..") { if (out.length > 1) out.pop(); continue; }
    out.push(part);
  }
  return out.join("/") || "/";
}
