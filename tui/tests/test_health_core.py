import subprocess
import time
from pathlib import Path

from workstation_tui.core.health import (
    CHECKS,
    check_available,
    check_command,
    load_cache,
    read_services,
    read_wsl_interop,
    save_cache,
)
from workstation_tui.core.models import CheckResult, HostContext

CTX = HostContext(
    os="linux", is_wsl=True, group="dev_machine", mode="dev",
    has_make=True, has_chezmoi=True, has_systemctl=True, has_sudo=True,
)


def test_registry_has_the_four_checks() -> None:
    assert [c.check_id for c in CHECKS] == [
        "doctor", "check-updates", "invariants", "templates",
    ]


def test_availability_rules(tmp_path: Path) -> None:
    no_make = CTX.model_copy(update={"has_make": False})
    windows = CTX.model_copy(update={"os": "windows", "has_make": False})
    doctor = CHECKS[0]
    invariants = CHECKS[2]
    assert check_available(doctor, CTX) is None
    assert check_available(doctor, no_make) is not None
    assert check_available(invariants, CTX) is None
    assert check_available(invariants, windows) is not None


def test_check_commands(tmp_path: Path) -> None:
    doctor_cmd = check_command(tmp_path, CHECKS[0], "prod")
    assert doctor_cmd[-2:] == ["doctor", "MODE=prod"]
    inv_cmd = check_command(tmp_path, CHECKS[2], "prod")
    assert inv_cmd[0] == "bash"
    assert inv_cmd[1].endswith("scripts/check-invariants.sh")


def test_cache_round_trip_and_corruption(tmp_path: Path) -> None:
    cache = tmp_path / "sub" / "health.json"
    results = {
        "doctor": CheckResult(check_id="doctor", ok=True, summary="31/31 ok",
                              finished_at=time.time(), returncode=0),
    }
    save_cache(cache, results)
    loaded = load_cache(cache)
    assert loaded["doctor"].ok is True
    assert load_cache(tmp_path / "missing.json") == {}
    cache.write_text("{corrupt")
    assert load_cache(cache) == {}


def test_read_services_mapping() -> None:
    def fake_run(cmd, **kwargs):
        rc = 0 if "docker" in cmd else 3
        return subprocess.CompletedProcess(cmd, rc, stdout="", stderr="")

    states = read_services(run=fake_run)
    assert states["docker"] == "active"
    assert states["dozzle"] == "inactive"

    def raising_run(cmd, **kwargs):
        raise FileNotFoundError("systemctl")

    assert set(read_services(run=raising_run).values()) == {"unknown"}


def test_read_wsl_interop_states(tmp_path: Path, monkeypatch) -> None:
    import workstation_tui.core.health as health_mod

    p = tmp_path / "WSLInterop"
    monkeypatch.setattr(health_mod, "_INTEROP_PATH", p)
    assert read_wsl_interop() == "absent"
    p.write_text("enabled\n")
    assert read_wsl_interop() == "enabled"
    p.write_text("disabled\n")
    assert read_wsl_interop() == "disabled"


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
    assert rollup.services == "n/a on WSL"
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
    assert rollup.services == "dev-machine-only"
    assert calls == ["services"]

    # No systemctl (non-WSL dev) → its reason, reader still not called again.
    ctx = CTX.model_copy(update={"is_wsl": False, "has_systemctl": False})
    rollup = build_health_rollup(cache, ctx, services_reader, lambda: "enabled")
    assert rollup.services == "systemctl not available"
    assert calls == ["services"]
