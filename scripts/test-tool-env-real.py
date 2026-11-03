"""Install and exercise the committed locks in a temporary directory only."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

spec = importlib.util.spec_from_file_location("tool_env", Path(__file__).with_name("tool-env.py"))
env = importlib.util.module_from_spec(spec)
spec.loader.exec_module(env)

with tempfile.TemporaryDirectory(prefix="workstation-env-check-") as temp:
    root = Path(temp)
    os.environ["UV_CACHE_DIR"] = str(root / "uv-cache")
    os.environ["npm_config_cache"] = str(root / "npm-cache")
    python = env.mise_which("python")
    uv = env.mise_which("uv")
    node = env.mise_which("node")
    for kind, runtime in [("python", python), ("lsp", node)]:
        generation = env.install(kind, root / kind, root / "bin", runtime, uv)
        assert generation == env.install(kind, root / kind, root / "bin", runtime, uv)
    env.run([root / "bin" / ("wpy.cmd" if env.WINDOWS else "wpy"), "-c", "import duckdb, polars, textual; print('Python imports OK')"], shell=env.WINDOWS)
    # Initialize in an empty project: TypeScript must be found beside the server,
    # not accidentally through this workstation's old global npm installation.
    project = root / "empty-project"
    project.mkdir()
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "processId": None, "rootUri": project.as_uri(), "capabilities": {}}},
        {"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": None},
        {"jsonrpc": "2.0", "method": "exit"},
    ]
    clean = dict(os.environ)
    clean.pop("NODE_PATH", None)
    with subprocess.Popen([node, generation / "node_modules/typescript-language-server/lib/cli.mjs", "--stdio"],
                          cwd=project, env=clean, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE) as proc:
        timer = threading.Timer(45, proc.kill)
        timer.start()

        def send(message):
            body = json.dumps(message).encode()
            proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
            proc.stdin.flush()

        def receive(ident):
            while True:
                headers = {}
                while True:
                    line = proc.stdout.readline()
                    if not line:
                        raise AssertionError((proc.poll(), proc.stderr.read()))
                    if line == b"\r\n":
                        break
                    key, value = line.decode().split(":", 1)
                    headers[key.lower()] = value.strip()
                message = json.loads(proc.stdout.read(int(headers["content-length"])))
                if message.get("id") == ident:
                    assert "error" not in message, message
                    return message

        try:
            send(messages[0])
            assert "capabilities" in receive(1)["result"]
            send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
            send(messages[1])
            receive(2)
            send(messages[2])
            proc.communicate(timeout=10)
            assert proc.returncode == 0, proc.returncode
        finally:
            timer.cancel()
            if proc.poll() is None:
                proc.kill()
    print("TypeScript server initializes without project/global TypeScript")
print("PASS: locked installs, repeated install, Python launchers and TypeScript initialization")
