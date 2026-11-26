# Lists Claude Code's saved sessions on this machine as JSON, newest first. Run by the
# sessions mod (`python3 -c <this file>`), here or on the space's machine. Reads only
# the start and end of each transcript: they can be hundreds of megabytes.
# Python 3.6+ (EL8's /usr/bin/python3), standard library only.
import glob, json, os, sys

LIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 80
HEAD, TAIL = 64 * 1024, 512 * 1024


def lines(path, size):
    with open(path, "rb") as f:
        chunks = [f.read(HEAD)]
        if size > HEAD:
            f.seek(max(HEAD, size - TAIL))
            chunks.append(f.read(TAIL))
    for chunk in chunks:
        for raw in chunk.split(b"\n"):
            if not raw.startswith(b"{"):
                continue
            try:
                yield json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                continue


def prompt(entry):
    message = entry.get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        content = " ".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    if not isinstance(content, str):
        return ""
    text = " ".join(content.split())
    return "" if text.startswith("<") or text.startswith("Caveat:") else text[:160]


def describe(path):
    st = os.stat(path)
    custom = ai = first = cwd = branch = ""
    for entry in lines(path, st.st_size):
        kind = entry.get("type")
        if kind == "custom-title":
            custom = entry.get("customTitle") or entry.get("title") or custom
        elif kind == "ai-title":
            ai = entry.get("aiTitle") or ai
        elif kind == "user" and not first and not entry.get("isMeta") and not entry.get("isSidechain"):
            first = prompt(entry)
        if entry.get("cwd"):
            cwd = entry["cwd"]
            branch = entry.get("gitBranch") or branch
    return {
        "id": os.path.basename(path)[:-6],
        "title": custom or ai or first or "(no title)",
        "cwd": cwd,
        "branch": branch,
        "at": int(st.st_mtime * 1000),
        "size": st.st_size,
    }


root = os.path.join(os.path.expanduser("~"), ".claude", "projects")
paths = glob.glob(os.path.join(root, "*", "*.jsonl"))
paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
out = []
for path in paths[:LIMIT]:
    try:
        item = describe(path)
    except (OSError, ValueError):
        continue
    if item["cwd"]:
        out.append(item)
sys.stdout.write(json.dumps({"sessions": out, "total": len(paths)}))
