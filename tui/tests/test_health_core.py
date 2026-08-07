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
