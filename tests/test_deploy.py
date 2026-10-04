"""T1/T2 only: offline checks with simulated arm64, memory, disk and processes."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts" / "deploy.sh"
PINS = {
    "LAUNCHER_REPO": "https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark",
    "LAUNCHER_COMMIT": "fdcd538fbf95fb15b2d6850db9613d22b2c889b8",
    "IMAGE": "ghcr.io/0xsero/deepseek-v4-flash-0731-spark-sparkinfer@sha256:"
             "2e077489a83a0360952828051fe7f7a32c1801e5ce8436d85f7267583d614ff4",
    "MODEL_REPO": "0xSero/deepseek-v4-flash-0731-spark",
    "MODEL_REVISION": "22f28d32b9b29b4352eaa380ff8c2c170b2847ab",
}
TUNABLES = {
    "SERVING_HOST": "127.0.0.1",
    "SERVING_PORT": "8888",
    "MAX_MODEL_LEN": "384000",
    "MAX_NUM_SEQS": "1",
    "MAX_NUM_BATCHED_TOKENS": "8224",
    "GPU_MEMORY_UTILIZATION": "0.94",
    "KV_RECORD": "stock432",
    "MODE": "dspark",
    "VERIFY_MODEL_CHECKSUMS": "1",
    "ABLATE": "0",
}


class DeployOfflineTests(unittest.TestCase):
    def setUp(self):
        # Keep every fixture, including the copied deployment root, in this repo.
        self.temporary = tempfile.TemporaryDirectory(prefix=".test-deploy-", dir=ROOT)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        (self.work / "scripts").mkdir()
        self.script = self.work / "scripts" / "deploy.sh"
        shutil.copy2(SOURCE, self.script)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.meminfo = self.work / "meminfo"
        self.meminfo.write_text("MemAvailable: 134217728 kB\n")
        self.calls = self.work / "calls"
        self.env = dict(os.environ)
        self.env.update({
            "PATH": str(self.bin) + os.pathsep + self.env["PATH"],
            "MEMINFO_PATH": str(self.meminfo),
            "TEST_CALLS": str(self.calls),
            "TEST_ARCH": "aarch64",
            "TEST_EARLYOOM": "1",
            "TEST_DISK_KIB": "230686720",
        })
        stub = """#!/bin/sh
name=${0##*/}
printf '%s %s\\n' "$name" "$*" >> "$TEST_CALLS"
case "$name" in
  uname) printf '%s\\n' "$TEST_ARCH";;
  pgrep) exit "$TEST_EARLYOOM";;
  df)
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n'
    printf 'fixture 500000000 0 %s 0%% .\\n' "$TEST_DISK_KIB";;
  *) printf 'FORBIDDEN: %s\\n' "$name" >&2; exit 99;;
esac
"""
        for name in ("uname", "pgrep", "df", "docker", "git", "curl"):
            executable = self.bin / name
            executable.write_text(stub)
            executable.chmod(0o755)

    def run_deploy(self, *args):
        result = subprocess.run(
            ["bash", str(self.script), *args], cwd=self.work, env=self.env,
            capture_output=True, text=True, timeout=15,
        )
        calls = self.calls.read_text() if self.calls.exists() else ""
        for forbidden in ("docker", "git", "curl"):
            self.assertFalse(any(line.startswith(forbidden + " ")
                                 for line in calls.splitlines()), calls)
        self.assertFalse((self.work / ".deploy").exists())
        return result

    def assert_failure(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_t1_shell_syntax(self):
        result = subprocess.run(["bash", "-n", str(SOURCE)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_t1_embedded_python_syntax(self):
        source = SOURCE.read_text()
        heredocs = re.findall(r"<<'PY'\n(.*?)\nPY\n", source, re.S)
        commands = re.findall(r"python3 -c '\n(.*?)\n'", source, re.S)
        self.assertTrue(heredocs)
        self.assertTrue(commands)
        for code in heredocs + commands:
            compile(code, "deploy.sh embedded Python", "exec")

    def test_t1_removed_legacy_entrypoint_and_flags(self):
        source = SOURCE.read_text()
        for removed in ("exllamav3.server", "TORCH_CUDA_ARCH_LIST", "max-new-tokens",
                        "EXL3_COMMIT", "torch.cuda", "max-seq-len", ".pid"):
            self.assertNotIn(removed, source)

    def test_t1_dry_run_exact_pins_and_tunables(self):
        result = self.run_deploy("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [line for line in result.stdout.splitlines() if "=" in line]
        self.assertEqual(len(lines), len(PINS) + len(TUNABLES))
        self.assertEqual(dict(line.split("=", 1) for line in lines), {**PINS, **TUNABLES})
        self.assertIn("Docker, GPU, pins and readiness were not checked", result.stdout)

    def test_t1_dry_run_host_and_port(self):
        result = self.run_deploy("--dry-run", "--host", "localhost", "--port", "9000")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SERVING_HOST=localhost\n", result.stdout)
        self.assertIn("SERVING_PORT=9000\n", result.stdout)
        self.assertNotIn("WARNING", result.stderr)

    def test_t1_invalid_arguments(self):
        for args in (("--port",), ("--host",), ("--ctx", "384000"),
                     ("--port", "0"), ("--port", "65536"), ("--port", "text")):
            with self.subTest(args=args):
                self.assert_failure(self.run_deploy("--dry-run", *args), "FAIL")

    def test_t1_rejects_wrong_architecture(self):
        self.env["TEST_ARCH"] = "x86_64"
        self.assert_failure(self.run_deploy("--dry-run"), "requires arm64")

    def test_t1_accepts_arm64_spelling(self):
        self.env["TEST_ARCH"] = "arm64"
        result = self.run_deploy("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_t1_disk_gate(self):
        self.env["TEST_DISK_KIB"] = "230686719"
        self.assert_failure(self.run_deploy("--dry-run"), "220 GiB")

    def test_t1_process_check_error_fails_closed(self):
        self.env["TEST_EARLYOOM"] = "2"
        self.assert_failure(self.run_deploy("--dry-run"), "could not check")

    def test_t2_memory_below_threshold_before_docker(self):
        self.meminfo.write_text("MemAvailable: 119852236 kB\n")
        for args in ((), ("--dry-run",)):
            with self.subTest(args=args):
                self.assert_failure(self.run_deploy(*args), "at least 114.3 GiB")

    def test_t2_memory_boundary_passes_offline(self):
        self.meminfo.write_text("MemAvailable: 119852237 kB\n")
        result = self.run_deploy("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_t2_invalid_meminfo_fails_before_docker(self):
        for content in ("", "MemFree: 134217728 kB\n", "MemAvailable: bad kB\n",
                        "MemAvailable: 134217728 MB\n"):
            with self.subTest(content=content):
                self.meminfo.write_text(content)
                self.assert_failure(self.run_deploy(), "valid MemAvailable")

    def test_t2_missing_meminfo_fails_before_docker(self):
        self.meminfo.unlink()
        self.assert_failure(self.run_deploy(), "valid MemAvailable")

    def test_t2_fake_earlyoom_before_docker(self):
        self.env["TEST_EARLYOOM"] = "0"
        for args in ((), ("--dry-run",)):
            with self.subTest(args=args):
                self.assert_failure(self.run_deploy(*args), "earlyoom is running")
        self.assertIn("pgrep -x earlyoom\n", self.calls.read_text())


if __name__ == "__main__":
    unittest.main()
