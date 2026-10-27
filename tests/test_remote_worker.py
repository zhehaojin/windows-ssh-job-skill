"""Local tests: no SSH, external services, real detached jobs or calculations."""
import base64
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

WORKER = Path(__file__).resolve().parents[1] / "scripts" / "remote_worker.py"
SPEC = importlib.util.spec_from_file_location("remote_worker", WORKER)
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


class Kernel:
    """Simulate a 64-bit handle and the documented ctypes output parameters."""
    def __init__(self, exit_code=259, handle=0x123456789, valid=True, created=0x100000002):
        self.exit_code, self.handle, self.valid, self.created = exit_code, handle, valid, created
        self.closed = []

    def OpenProcess(self, access, inherit, pid):
        return self.handle

    def GetExitCodeProcess(self, handle, pointer):
        if handle != self.handle:
            raise AssertionError("Handle was truncated")
        pointer._obj.value = self.exit_code
        return self.valid

    def GetProcessTimes(self, handle, created, exited, kernel, user):
        created._obj.dwLowDateTime = self.created & 0xFFFFFFFF
        created._obj.dwHighDateTime = self.created >> 32
        return True

    def CloseHandle(self, handle):
        self.closed.append(handle)
        return True


class ProcessTests(unittest.TestCase):
    def test_alive_and_identity_with_64_bit_handle(self):
        kernel = Kernel()
        result = worker.process_state(456, kernel=kernel)
        self.assertTrue(result["alive"])
        self.assertEqual(result["created_filetime"], 0x100000002)
        self.assertEqual(result["pid_identity"], "unverified_pid_match")
        self.assertEqual(kernel.closed, [kernel.handle])
        self.assertEqual(worker.process_state(456, 0x100000002, kernel)["pid_identity"], "matched")

    def test_reused_pid_is_not_our_original_process(self):
        result = worker.process_state(456, 7, Kernel())
        self.assertFalse(result["alive"])
        self.assertTrue(result["observed_alive"])
        self.assertEqual(result["pid_identity"], "pid_reused")

    def test_access_failure_is_unknown_and_invalid_pid_is_absent(self):
        with mock.patch.object(worker.ctypes, "get_last_error", return_value=5, create=True):
            self.assertIsNone(worker.process_state(456, kernel=Kernel(handle=0))["alive"])
        with mock.patch.object(worker.ctypes, "get_last_error", return_value=87, create=True):
            self.assertIs(worker.process_state(456, kernel=Kernel(handle=0))["alive"], False)
        self.assertIsNone(worker.process_state(True)["alive"])

    def test_get_exit_code_failure_still_closes_handle(self):
        kernel = Kernel(valid=False)
        with mock.patch.object(worker.ctypes, "get_last_error", return_value=5, create=True):
            self.assertIsNone(worker.process_state(456, kernel=kernel)["alive"])
        self.assertEqual(kernel.closed, [kernel.handle])


class FileAndStatusTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / "results").mkdir()

    def tearDown(self):
        self.directory.cleanup()

    def write(self, relative, value):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_partial_or_missing_json_never_implies_completion(self):
        (self.root / "launcher_status.json").write_text('{"status":', encoding="utf-8")
        self.write("results/status.json", {"status": "completed"})
        result = worker.main({"action": "status", "run_directory": str(self.root)})
        self.assertEqual(result["launcher"]["state"], "unavailable")
        self.assertEqual(result["configuration"]["state"], "missing")
        self.assertFalse(result["terminal_status_reported"])
        self.assertFalse(result["safe_to_collect"])

    def test_terminal_requires_both_state_records_and_stopped_process(self):
        self.write("launcher_status.json", {"status": "finished", "pid": 321})
        self.write("results/status.json", {"status": "completed_with_failures", "failed_models": 2})
        self.write("config.json", {"workers": 96, "seeds": [1], "neural": {"n_trials": 36}, "unrelated": "omit"})
        with mock.patch.object(worker, "process_state", return_value={"alive": None, "pid": 321}):
            self.assertFalse(worker.status({"run_directory": str(self.root)})["safe_to_collect"])
        with mock.patch.object(worker, "process_state", return_value={"alive": False, "pid": 321}):
            result = worker.status({"run_directory": str(self.root)})
        self.assertTrue(result["safe_to_collect"])
        self.assertEqual(result["configuration"]["selected"], {"workers": 96, "seeds": [1], "neural_trials": 36})

    def test_launch_directory_metadata_identity_and_short_tail(self):
        job = self.write("job/launch.json", {"pid": 123, "pid_created_filetime": 7}).parent
        (job / "launch.log").write_text("one\ntwo\nthree\n", encoding="utf-8")
        with mock.patch.object(worker, "process_state", return_value={"pid": 123, "alive": True}) as process:
            result = worker.status({"run_directory": str(self.root), "launch_record": str(job), "tail_lines": 2})
        process.assert_called_once_with(123, 7)
        self.assertEqual(result["logs"][1]["lines"], ["two", "three"])

    def test_launch_record_only_reports_initialization_then_resolves_from_log(self):
        path = self.write("job/launch.json", {"pid": 123, "command": ["python", "task.py"]})
        with mock.patch.object(worker, "process_state", return_value={"pid": 123, "alive": True}):
            result = worker.status({"launch_record": str(path)})
        self.assertEqual(result["phase"], "initializing")
        self.assertIsNone(result["run_directory"])
        self.assertFalse(result["safe_to_collect"])
        self.assertTrue(result["processes"][0]["alive"])
        (path.parent / "launch.log").write_text("RUN_DIRECTORY " + str(self.root) + "\n" + "progress\n" * 30, encoding="utf-8")
        with mock.patch.object(worker, "process_state", return_value={"pid": 123, "alive": True}):
            result = worker.status({"launch_record": str(path.parent)})
        self.assertEqual(result["run_directory"], str(self.root))
        self.assertEqual(result["phase"], "observed")

    def test_run_or_launch_record_must_be_supplied(self):
        with self.assertRaisesRegex(ValueError, "run_directory or launch_record"):
            worker.status({})

    def test_tail_is_bounded_and_recovers_complete_last_lines(self):
        log = self.root / "huge.log"
        log.write_bytes(b"x" * 100000 + b"\n" + b"\n".join(str(i).encode() for i in range(30)))
        result = worker.tail(log)
        self.assertTrue(result["truncated"])
        self.assertEqual(result["lines"], [str(i) for i in range(10, 30)])
        self.assertLess(sum(map(len, result["lines"])), worker.TAIL_BYTES)

    def test_relative_paths_and_unknown_action_fail(self):
        for request in ({"action": "status", "run_directory": "runs/latest"}, {"action": "stop"}):
            with self.assertRaises(ValueError):
                worker.main(request)

    def test_known_live_or_uncertain_run_suppresses_duplicate_launch(self):
        self.write("runs/a/manifest.json", {"experiment": "regime-all"})
        path = self.write("runs/a/launcher_status.json", {"status": "running", "pid": 88})
        arguments = ["-u", "-m", "scripts.launch_regime_benchmark", "--experiment", "all"]
        with mock.patch.object(worker, "process_state", return_value={"pid": 88, "alive": True}), mock.patch.object(worker.subprocess, "Popen") as popen:
            result = worker.launch({"repo": str(self.root), "arguments": arguments})
        self.assertFalse(result["started"])
        self.assertEqual(result["duplicate"]["state"], "active")
        popen.assert_not_called()
        path.write_text("{", encoding="utf-8")
        self.assertEqual(worker.duplicates(self.root, arguments)["state"], "uncertain")

    def test_dead_record_allows_a_new_launch_check(self):
        arguments = ["-m", "task", "a b"]
        self.write(".local/ssh-jobs/a/launch.json", {"status": "launched", "pid": 44, "arguments": arguments})
        with mock.patch.object(worker, "process_state", return_value={"pid": 44, "alive": False}):
            self.assertIsNone(worker.duplicates(self.root, arguments))

    def test_terminal_record_is_not_revived_by_a_reused_live_pid(self):
        arguments = ["-m", "scripts.launch_regime_benchmark", "--experiment", "all"]
        for terminal in ("finished", "failed", "interrupted"):
            with self.subTest(status=terminal):
                self.write(".local/ssh-jobs/a/launch.json", {"status": terminal, "pid": 44, "arguments": arguments})
                self.write("runs/a/manifest.json", {"experiment": "regime-all"})
                self.write("runs/a/launcher_status.json", {"status": terminal, "pid": 45})
                with mock.patch.object(worker, "process_state", return_value={"alive": True}) as process:
                    self.assertIsNone(worker.duplicates(self.root, arguments))
                process.assert_not_called()

    def test_lock_and_interpreter_verification(self):
        content = b"locked==1\n"
        (self.root / "requirements-windows.lock.txt").write_bytes(content)
        record = {"python": sys.executable, "lock_sha256": hashlib.sha256(content).hexdigest()}
        self.write(".deployment/environment.json", record)
        self.assertEqual(worker.environment_check(self.root)["state"], "verified")
        (self.root / "requirements-windows.lock.txt").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "lock changed"):
            worker.environment_check(self.root)
        record["python"] = str(self.root / "another-python.exe")
        self.write(".deployment/environment.json", record)
        with self.assertRaisesRegex(ValueError, "interpreter differs"):
            worker.environment_check(self.root)

    @unittest.skipUnless(os.name == "nt", "Windows-specific detached launch flags")
    def test_concurrent_launch_lock_rejection_starts_nothing(self):
        import msvcrt
        with mock.patch.object(msvcrt, "locking", side_effect=OSError("lock held")), mock.patch.object(worker.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(RuntimeError, "holds this repository's launch lock"):
                worker.launch({"repo": str(self.root), "arguments": ["-m", "task"]})
        popen.assert_not_called()
        self.assertEqual(list((self.root / ".local/ssh-jobs").glob("*/launch.json")), [])

    @unittest.skipUnless(os.name == "nt", "Windows-specific detached launch flags")
    def test_command_array_detachment_metadata_and_env(self):
        arguments = ["-u", "-m", "my_module", "--input", "D:/space dir/a.json", "literal;$(anything)"]
        process = mock.Mock(pid=42, returncode=None)
        process.poll.return_value = None

        def start(command, **kwargs):
            kwargs["stdout"].write(b"RUN_DIRECTORY D:\\new run\n")
            self.assertEqual(command, [sys.executable, *arguments])
            self.assertEqual(kwargs["creationflags"], 0x01000000 | 0x8 | 0x200)
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(kwargs["stderr"], subprocess.STDOUT)
            self.assertTrue(kwargs["close_fds"])
            self.assertNotIn("KING_REMOTE_REQUEST_B64", kwargs["env"])
            return process

        with mock.patch.object(worker.subprocess, "Popen", side_effect=start) as popen, mock.patch.object(worker, "process_state", return_value={"created_filetime": 7}), mock.patch.dict(os.environ, {"KING_REMOTE_REQUEST_B64": "request"}):
            result = worker.launch({"repo": str(self.root), "arguments": arguments})
        popen.assert_called_once()
        record = json.loads(Path(result["launch_record"]).read_text(encoding="utf-8"))
        self.assertEqual(record["pid_created_filetime"], 7)
        self.assertEqual(record["arguments"], arguments)
        self.assertEqual(result["run_directory"], "D:\\new run")
        self.assertIn("new SSH session", result["verification_required"])

    @unittest.skipUnless(os.name == "nt", "Windows-specific detached launch flags")
    def test_breakaway_failure_does_not_fall_back(self):
        with mock.patch.object(worker.subprocess, "Popen", side_effect=OSError("breakaway denied")) as popen:
            with self.assertRaisesRegex(RuntimeError, "no weaker launch fallback"):
                worker.launch({"repo": str(self.root), "arguments": ["-m", "task"]})
        popen.assert_called_once()
        records = list((self.root / ".local/ssh-jobs").glob("*/launch.json"))
        self.assertEqual(len(records), 1)
        self.assertEqual(json.loads(records[0].read_text(encoding="utf-8"))["status"], "failed")


class EntryTests(unittest.TestCase):
    def test_info_entrypoint_json_and_invalid_payload_exit(self):
        env = dict(os.environ, KING_REMOTE_REQUEST_B64=base64.b64encode(json.dumps({"action": "info"}).encode()).decode())
        result = subprocess.run([sys.executable, "-B", str(WORKER)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["python"], sys.executable)
        env["KING_REMOTE_REQUEST_B64"] = "not base64!"
        result = subprocess.run([sys.executable, "-B", str(WORKER)], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
