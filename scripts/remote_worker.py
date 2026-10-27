"""Standard-library worker; the SSH helper supplies KING_REMOTE_REQUEST_B64."""
import base64
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import getpass
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
import uuid

TAIL_BYTES = 65536
TERMINAL = {"finished", "completed", "completed_with_failures", "failed", "error", "interrupted", "cancelled", "exited"}
BENCHMARKS = {"scripts.launch_regime_benchmark": "regime", "scripts.launch_windows_benchmark": "windows"}


def absolute(value, field):
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise ValueError(field + " must be an explicit absolute path")
    return Path(value).resolve()


def read_json(path):
    try:
        if path.stat().st_size > 2 * 1024 * 1024:
            return {"state": "too_large", "path": str(path)}
        value = json.loads(path.read_text(encoding="utf-8-sig"))
        return {"state": "ok", "path": str(path), "value": value}
    except FileNotFoundError:
        return {"state": "missing", "path": str(path)}
    except (ValueError, OSError) as exc:
        return {"state": "unavailable", "path": str(path), "reason": str(exc)}


def tail(path, lines_count=20):
    try:
        with path.open("rb") as stream:
            stream.seek(0, 2)
            size = stream.tell()
            start = max(0, size - TAIL_BYTES)
            stream.seek(start)
            lines = stream.read(TAIL_BYTES).decode("utf-8", errors="replace").splitlines()
        if start and lines:
            lines = lines[1:]
        return {"state": "ok", "path": str(path), "lines": lines[-lines_count:], "truncated": bool(start)}
    except FileNotFoundError:
        return {"state": "missing", "path": str(path), "lines": []}
    except OSError as exc:
        return {"state": "unavailable", "path": str(path), "reason": str(exc), "lines": []}


def process_state(pid, expected_created=None, kernel=None):
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return {"pid": pid, "alive": None, "reason": "invalid_pid"}
    if kernel is None:
        if os.name != "nt":
            return {"pid": pid, "alive": None, "reason": "Windows API unavailable"}
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.GetExitCodeProcess.restype = wintypes.BOOL
        kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        kernel.GetProcessTimes.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        error = ctypes.get_last_error()
        return {"pid": pid, "alive": False if error == 87 else None, "winerror": error}
    try:
        code = wintypes.DWORD()
        if not kernel.GetExitCodeProcess(handle, ctypes.byref(code)):
            return {"pid": pid, "alive": None, "winerror": ctypes.get_last_error()}
        times = [wintypes.FILETIME() for _ in range(4)]
        created = None
        if kernel.GetProcessTimes(handle, *[ctypes.byref(item) for item in times]):
            created = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
        result = {"pid": pid, "alive": code.value == 259, "exit_code": code.value, "created_filetime": created,
                  "pid_identity": "unverified_pid_match" if expected_created is None else "matched" if created == expected_created else "unknown"}
        if expected_created is not None and created is not None and created != expected_created:
            result.update(alive=False, observed_alive=code.value == 259, pid_identity="pid_reused")
        return result
    finally:
        kernel.CloseHandle(handle)


def object_value(record):
    value = record.get("value") if record.get("state") == "ok" else None
    return value if isinstance(value, dict) else {}


def launch_record_path(value):
    path = absolute(value, "launch_record")
    return path / "launch.json" if path.is_dir() else path


def status(request):
    launch_path = launch_record_path(request["launch_record"]) if request.get("launch_record") else None
    if not request.get("run_directory") and launch_path is None:
        raise ValueError("run_directory or launch_record is required")
    launch = read_json(launch_path) if launch_path else {"state": "not_supplied"}
    known = object_value(launch)
    run_value = request.get("run_directory") or known.get("run_directory") or known.get("run_path")
    if not run_value and launch_path:
        lines = tail(launch_path.parent / "launch.log", TAIL_BYTES)["lines"]
        run_value = next((line[len("RUN_DIRECTORY "):].strip() for line in reversed(lines) if line.startswith("RUN_DIRECTORY ")), None)
    run = absolute(run_value, "run_directory") if run_value else None
    unavailable = {"state": "run_directory_not_yet_resolved"}
    launcher = read_json(run / "launcher_status.json") if run else dict(unavailable)
    results = read_json(run / "results" / "status.json") if run else dict(unavailable)
    config = read_json(run / "config.json") if run else dict(unavailable)
    cfg = object_value(config)
    selected = {key: cfg[key] for key in ("task", "intervals", "seeds", "workers", "evaluation_workers", "protocol_version") if key in cfg}
    if isinstance(cfg.get("neural"), dict):
        selected["neural_trials"] = cfg["neural"].get("n_trials")
    config.pop("value", None)
    config["selected"] = selected
    records = [object_value(launcher), object_value(launch)]
    pids = {item[key] for item in records for key in ("pid", "launcher_pid") if isinstance(item.get(key), int) and not isinstance(item[key], bool) and item[key] > 0}
    processes = [process_state(pid, known.get("pid_created_filetime") if pid == known.get("pid") else None) for pid in sorted(pids)]
    terminal = all(object_value(item).get("status") in TERMINAL for item in (launcher, results))
    stopped = bool(processes) and all(item["alive"] is False for item in processes)
    lines_count = max(1, min(20, int(request.get("tail_lines", 20))))
    logs = [tail(run / "console.log", lines_count)] if run else []
    if request.get("log_path"):
        logs.append(tail(absolute(request["log_path"], "log_path"), lines_count))
    elif request.get("launch_record"):
        logs.append(tail(launch_record_path(request["launch_record"]).parent / "launch.log", lines_count))
    return {"ok": True, "action": "status", "phase": "initializing" if run is None else "observed",
            "run_directory": str(run) if run else None, "launcher": launcher,
            "results": results, "configuration": config, "launch_record": launch, "processes": processes,
            "terminal_status_reported": terminal, "verified_stopped": stopped,
            "safe_to_collect": terminal and stopped, "logs": logs,
            "note": "PIDs can be reused; missing/unreadable state or inaccessible processes are not completion evidence."}


def identity(arguments):
    try:
        module = arguments[arguments.index("-m") + 1]
    except (ValueError, IndexError):
        return None
    if module not in BENCHMARKS:
        return None
    try:
        experiment = arguments[arguments.index("--experiment") + 1]
    except (ValueError, IndexError):
        experiment = "smoke"
    return BENCHMARKS[module], experiment


def active_record(record):
    data = object_value(record)
    if data.get("status") in TERMINAL:
        return None
    pids = [data[key] for key in ("pid", "launcher_pid") if isinstance(data.get(key), int)]
    states = [process_state(pid, data.get("pid_created_filetime") if pid == data.get("pid") else None) for pid in pids]
    if any(item["alive"] is True for item in states):
        return {"state": "active", "record": record["path"], "processes": states}
    if data.get("status") not in TERMINAL and (not states or any(item["alive"] is None for item in states)):
        return {"state": "uncertain", "record": record["path"], "processes": states}
    return None


def duplicates(repo, arguments):
    requested = identity(arguments)
    for path in sorted((repo / ".local" / "ssh-jobs").glob("*/launch.json")):
        record = read_json(path)
        data = object_value(record)
        if data.get("arguments") == arguments or (requested and identity(data.get("arguments", [])) == requested):
            active = active_record(record)
            if active:
                return active
    if requested:
        for path in sorted((repo / "runs").glob("*/manifest.json")):
            manifest = object_value(read_json(path))
            experiment = manifest.get("experiment")
            expected = "regime-" + requested[1] if requested[0] == "regime" else requested[1]
            if experiment != expected:
                continue
            record = read_json(path.parent / "launcher_status.json")
            active = active_record(record)
            if active:
                active["run_directory"] = str(path.parent)
                return active
    return None


def environment_check(repo):
    record = read_json(repo / ".deployment" / "environment.json")
    if record["state"] == "missing":
        return record
    data = object_value(record)
    if not data.get("python") or not data.get("lock_sha256"):
        raise ValueError("Environment record unavailable or missing python/lock_sha256")
    if os.path.normcase(str(Path(data["python"]).resolve())) != os.path.normcase(str(Path(sys.executable).resolve())):
        raise ValueError("Worker interpreter differs from the locked environment")
    lock = repo / "requirements-windows.lock.txt"
    if hashlib.sha256(lock.read_bytes()).hexdigest() != data["lock_sha256"]:
        raise ValueError("Dependency lock changed; do not launch before explicit environment repair")
    return {"state": "verified", "path": record["path"], "lock_sha256": data["lock_sha256"]}


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def launch(request):
    repo = absolute(request.get("repo"), "repo")
    if not repo.is_dir() or os.name != "nt":
        raise ValueError("Detached launch requires an existing repo on Windows")
    import msvcrt
    jobs = repo / ".local" / "ssh-jobs"
    jobs.mkdir(parents=True, exist_ok=True)
    with (jobs / ".launch.lock").open("a+b") as guard:
        if guard.tell() == 0:
            guard.write(b"\0")
            guard.flush()
        guard.seek(0)
        try:
            msvcrt.locking(guard.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise RuntimeError("Another launch request holds this repository's launch lock") from exc
        try:
            return launch_locked(request)
        finally:
            guard.seek(0)
            msvcrt.locking(guard.fileno(), msvcrt.LK_UNLCK, 1)


def launch_locked(request):
    repo = absolute(request.get("repo"), "repo")
    arguments = request.get("arguments")
    if not isinstance(arguments, list) or not arguments or not all(isinstance(item, str) and "\0" not in item for item in arguments):
        raise ValueError("arguments must be a nonempty array of strings")
    environment = environment_check(repo)
    duplicate = duplicates(repo, arguments)
    if duplicate:
        return {"ok": True, "action": "launch", "started": False, "duplicate": duplicate}
    job = repo / ".local" / "ssh-jobs" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "_" + uuid.uuid4().hex[:8])
    job.mkdir(parents=True, exist_ok=False)
    record_path = job / "launch.json"
    record = {"status": "preparing", "created_at_utc": datetime.now(timezone.utc).isoformat(),
              "repo": str(repo), "python": sys.executable, "arguments": arguments, "environment": environment}
    write_json(record_path, record)
    env = dict(os.environ, PYTHONUTF8="1", PYTHONUNBUFFERED="1")
    env.pop("KING_REMOTE_REQUEST_B64", None)
    try:
        with (job / "launch.log").open("ab", buffering=0) as log:
            process = subprocess.Popen([sys.executable, *arguments], cwd=str(repo), stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT, close_fds=True, env=env,
                                       creationflags=0x01000000 | 0x00000008 | 0x00000200)
        record.update(status="launched", pid=process.pid, pid_created_filetime=process_state(process.pid).get("created_filetime"))
        write_json(record_path, record)
    except OSError as exc:
        record.update(status="failed", error=str(exc))
        write_json(record_path, record)
        raise RuntimeError("Detached launch failed; no weaker launch fallback was attempted: " + str(exc)) from exc
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        for line in tail(job / "launch.log")["lines"]:
            if line.startswith("RUN_DIRECTORY "):
                record["run_directory"] = line[len("RUN_DIRECTORY "):].strip()
        if record.get("run_directory") or process.poll() is not None:
            break
        time.sleep(0.1)
    if process.poll() is not None:
        record.update(status="exited", exit_code=process.returncode)
    write_json(record_path, record)
    return {"ok": True, "action": "launch", "started": True, "launch_record": str(record_path),
            "log_path": str(job / "launch.log"), **record,
            "verification_required": "Use a new SSH session to check native PID and run statuses before claiming detached execution."}


def main(request):
    if not isinstance(request, dict):
        raise ValueError("Request must be a JSON object")
    action = request.get("action")
    if action == "info":
        return {"ok": True, "action": action, "platform": platform.platform(), "username": getpass.getuser(),
                "hostname": platform.node(), "python": sys.executable, "python_version": platform.python_version(), "logical_cpus": os.cpu_count()}
    if action == "status":
        return status(request)
    if action == "launch":
        return launch(request)
    raise ValueError("Unknown action; expected info, status or launch")


if __name__ == "__main__":
    try:
        request = json.loads(base64.b64decode(os.environ["KING_REMOTE_REQUEST_B64"], validate=True).decode("utf-8"))
        print(json.dumps(main(request), ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": type(exc).__name__, "message": str(exc)}, ensure_ascii=False))
        raise SystemExit(1)
