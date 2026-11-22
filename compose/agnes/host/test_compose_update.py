import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("compose-update.sh")
FAKE = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["EVENTS"], "a") as f:
    f.write(json.dumps([name, args, os.getcwd()]) + "\\n")
if name == "git":
    if args == ["rev-parse", "--show-toplevel"]: print(os.environ["AGNES_OPS_ROOT"])
    elif args == ["rev-parse", "--absolute-git-dir"]: print(os.environ["AGNES_OPS_ROOT"] + "/.git")
    elif args == ["branch", "--show-current"]: print(os.environ.get("BRANCH", "main"))
    elif args[0] == "status": print(os.environ.get("DIRTY", ""), end="")
    elif args == ["rev-parse", "--short", "HEAD"]: print("abc1234")
    elif args[0] == "pull" and os.environ.get("FAIL_PULL"): sys.exit(1)
elif name == "sops":
    if os.environ.get("FAIL_DECRYPT"): sys.exit(1)
    print("SECRET=test-value")
elif name == "docker":
    if "config" in args and os.environ.get("FAIL_CONFIG"): sys.exit(1)
    if "ps" in args and "-q" in args and not os.environ.get("EMPTY_PROJECT"): print("existing-container")
    if "pull" in args and os.environ.get("FAIL_IMAGE_PULL"): sys.exit(1)
'''


class ComposeUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        (self.repo / ".git").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("git", "docker", "sops"):
            executable = self.bin / name
            executable.write_text(FAKE)
            executable.chmod(0o755)
        # macOS doesn't ship flock; a fake suffices for command-order tests.
        # Lock contention itself is tested against real flock on Agnes.
        lock = self.bin / "flock"
        lock.write_text("#!/bin/sh\nexit 0\n")
        lock.chmod(0o755)
        self.events = self.root / "events"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        AGNES_OPS_ROOT=str(self.repo),
                        AGNES_SOPS_BIN=str(self.bin / "sops"), EVENTS=str(self.events))
        self.stack = self.add_stack("paperless")

    def add_stack(self, name):
        stack = self.repo / "compose" / "agnes" / name
        stack.mkdir(parents=True)
        (stack / "compose.yaml").write_text("services: {}\n")
        return stack

    def run_script(self, *args, **env):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env | env,
                              capture_output=True, text=True)

    def calls(self):
        if not self.events.exists():
            return []
        return [json.loads(line) for line in self.events.read_text().splitlines()]

    def assert_no_mutations(self):
        for name, args, _ in self.calls():
            self.assertFalse(name == "git" and "pull" in args)
            self.assertFalse(name == "docker" and any(a in args for a in ("up", "pull", "restart", "down")))

    def test_default_is_check(self):
        result = self.run_script("paperless")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_mutations()
        self.assertFalse((self.stack / ".env").exists())

    def test_encrypted_check_preserves_live_environment(self):
        (self.stack / "secrets.env").write_text("encrypted")
        (self.stack / ".env").write_text("SECRET=old-value\n")
        result = self.run_script("--check", "paperless")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.stack / ".env").read_text(), "SECRET=old-value\n")
        self.assertNotIn("test-value", result.stdout + result.stderr)
        self.assert_no_mutations()
        config = next(args for name, args, _ in self.calls() if name == "docker" and "config" in args)
        self.assertFalse(Path(config[config.index("--env-file") + 1]).exists())

    def test_dirty_checkout_rejected(self):
        self.assertNotEqual(self.run_script("--apply", "paperless", DIRTY=" M tracked").returncode, 0)
        self.assert_no_mutations()

    def test_wrong_branch_rejected(self):
        self.assertNotEqual(self.run_script("--apply", "paperless", BRANCH="other").returncode, 0)
        self.assert_no_mutations()

    def test_unmanaged_stack_rejected(self):
        for stack in ("immich", "../apophis", "pad"):
            self.assertNotEqual(self.run_script("--apply", stack).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_validation_failure_never_applies(self):
        self.assertNotEqual(self.run_script("--check", "paperless", FAIL_CONFIG="1").returncode, 0)
        self.assert_no_mutations()

    def test_decryption_failure_preserves_environment(self):
        (self.stack / "secrets.env").write_text("encrypted")
        (self.stack / ".env").write_text("old")
        self.assertNotEqual(self.run_script("--apply", "paperless", FAIL_DECRYPT="1").returncode, 0)
        self.assertEqual((self.stack / ".env").read_text(), "old")
        self.assertFalse(any(name == "docker" for name, _, _ in self.calls()))

    def test_initial_deployment_rejected(self):
        self.assertNotEqual(self.run_script("--check", "paperless", EMPTY_PROJECT="1").returncode, 0)
        self.assert_no_mutations()

    def test_apply_orders_validation_pull_and_up(self):
        (self.stack / "secrets.env").write_text("encrypted")
        result = self.run_script("--apply", "paperless")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        git_pull = next(i for i, (n, a, _) in enumerate(calls) if n == "git" and "pull" in a)
        validate = next(i for i, (n, a, _) in enumerate(calls) if n == "docker" and "config" in a)
        pull = next(i for i, (n, a, _) in enumerate(calls) if n == "docker" and "pull" in a)
        up = next(i for i, (n, a, _) in enumerate(calls) if n == "docker" and "up" in a)
        self.assertLess(git_pull, validate)
        self.assertLess(validate, pull)
        self.assertLess(pull, up)
        self.assertIn("--wait", calls[up][1])
        self.assertEqual((self.stack / ".env").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.stack / ".env").read_text(), "SECRET=test-value\n")
        self.assertTrue(all(Path(cwd).resolve() == self.stack.resolve()
                            for n, _, cwd in calls if n == "docker"))

    def test_image_pull_failure_does_not_run_up(self):
        self.assertNotEqual(self.run_script("--apply", "paperless", FAIL_IMAGE_PULL="1").returncode, 0)
        self.assertFalse(any(n == "docker" and "up" in a for n, a, _ in self.calls()))

    def test_git_pull_failure_does_not_touch_docker(self):
        self.assertNotEqual(self.run_script("--apply", "paperless", FAIL_PULL="1").returncode, 0)
        self.assertFalse(any(n == "docker" for n, _, _ in self.calls()))


if __name__ == "__main__":
    unittest.main()
