import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bootstrap = load("bootstrap", "bootstrap-repos.py")
selector = load("selector", "home-config.py")
RUN = subprocess.run


class HostSelectionTests(unittest.TestCase):
    registry = {
        "default": {"hostnames": [], "environments": ["linux", "wsl", "nixos"]},
        "laptop-wsl": {"hostnames": ["toplap123"], "environments": ["wsl"]},
        "laptop-ubuntu": {"hostnames": ["toplap123"], "environments": ["linux"]},
    }

    def test_unknown_host_defaults_on_every_environment(self):
        for environment in ["linux", "wsl", "nixos"]:
            self.assertEqual(selector.select_profile(self.registry, "brand-new-machine", environment), "default")

    def test_same_hostname_selects_wsl_and_native(self):
        self.assertEqual(selector.select_profile(self.registry, "TopLap123.example", "wsl"), "laptop-wsl")
        self.assertEqual(selector.select_profile(self.registry, "TopLap123", "linux"), "laptop-ubuntu")

    def test_explicit_unknown_profile_is_an_error(self):
        with self.assertRaises(ValueError):
            selector.select_profile(self.registry, "whatever", "linux", "typo")


class GpuDriverLinkTests(unittest.TestCase):
    def setup_generation(self, root):
        package = root / "store/gpu"
        (package / "bin").mkdir(parents=True)
        (package / "lib/tmpfiles.d").mkdir(parents=True)
        (package / "bin/non-nixos-gpu-setup").touch()
        (root / "gen/home-path/bin").mkdir(parents=True)
        (root / "gen/home-path/bin/non-nixos-gpu-setup").symlink_to(package / "bin/non-nixos-gpu-setup")
        return root / "gen", package / "lib/tmpfiles.d/non-nixos-gpu.conf"

    def test_stale_link_runs_setup_only_on_enabled_hosts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            generation, wanted = self.setup_generation(root)
            link = root / "non-nixos-gpu.conf"
            link.symlink_to(root / "old.conf")
            (root / "enabled").touch()
            with patch.object(selector, "GPU_LINK", link), patch.object(selector.subprocess, "run") as run:
                selector.link_gpu_drivers(generation, root / "missing")
                run.assert_not_called()
                selector.link_gpu_drivers(generation, root / "enabled")
                run.assert_called_once_with(["sudo", str(generation / "home-path/bin/non-nixos-gpu-setup")], check=True)
                link.unlink()
                link.symlink_to(wanted)
                run.reset_mock()
                selector.link_gpu_drivers(generation, root / "enabled")
                run.assert_not_called()


class RepositorySafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.source = self.root / "source"
        self.git("init", "-b", "main", str(self.source))
        self.git("-C", str(self.source), "config", "user.name", "Test")
        self.git("-C", str(self.source), "config", "user.email", "test@example.invalid")
        (self.source / "file").write_text("pinned\n")
        self.git("-C", str(self.source), "add", "file")
        self.git("-C", str(self.source), "commit", "-m", "Pinned")
        self.revision = subprocess.check_output(["git", "-C", str(self.source), "rev-parse", "HEAD"], text=True).strip()
        self.entry = {"path": "skamensky/example", "url": "git@github.com:skamensky/example.git",
                      "branch": "main", "revision": self.revision}
        self.target = self.home / "repos/skamensky/example"

    def git(self, *args):
        return RUN(["git", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def local_clone(self, command, **kwargs):
        if command[:3] == ["git", "clone", "--no-checkout"]:
            result = RUN(command[:3] + [str(self.source), command[-1]], **kwargs)
            self.git("-C", command[-1], "remote", "set-url", "origin", self.entry["url"])
            return result
        return RUN(command, **kwargs)

    def test_clone_is_pinned_and_idempotent_preserving_dirty_branch(self):
        (self.source / "file").write_text("new upstream\n")
        self.git("-C", str(self.source), "commit", "-am", "Later upstream")
        with patch.object(bootstrap.subprocess, "run", side_effect=self.local_clone):
            bootstrap.bootstrap([self.entry], self.home)
        head = subprocess.check_output(["git", "-C", str(self.target), "rev-parse", "HEAD"], text=True).strip()
        self.assertEqual(head, self.revision)
        self.git("-C", str(self.target), "switch", "-c", "unfinished-work")
        (self.target / "file").write_text("uncommitted work\n")
        (self.target / "untracked").write_text("keep me\n")
        before = subprocess.check_output(["git", "-C", str(self.target), "status", "--porcelain"])
        bootstrap.bootstrap([self.entry], self.home)
        self.assertEqual(before, subprocess.check_output(["git", "-C", str(self.target), "status", "--porcelain"]))
        self.assertEqual((self.target / "file").read_text(), "uncommitted work\n")
        self.assertEqual(subprocess.check_output(["git", "-C", str(self.target), "branch", "--show-current"], text=True).strip(), "unfinished-work")

    def test_existing_non_repository_is_never_replaced(self):
        self.target.mkdir(parents=True)
        (self.target / "important").write_text("keep")
        with self.assertRaises(RuntimeError):
            bootstrap.bootstrap([self.entry], self.home)
        self.assertEqual((self.target / "important").read_text(), "keep")

    def test_wrong_origin_is_rejected_without_changes(self):
        self.target.parent.mkdir(parents=True)
        self.git("clone", str(self.source), str(self.target))
        with self.assertRaises(RuntimeError):
            bootstrap.bootstrap([self.entry], self.home)
        self.assertEqual((self.target / "file").read_text(), "pinned\n")

    def test_worktree_is_preserved(self):
        self.target.parent.mkdir(parents=True)
        self.git("-C", str(self.source), "remote", "add", "origin", self.entry["url"])
        self.git("-C", str(self.source), "worktree", "add", "--detach", str(self.target))
        bootstrap.bootstrap([self.entry], self.home)
        self.assertTrue((self.target / ".git").is_file())

    def test_failed_clone_leaves_no_final_or_staging_checkout(self):
        other = dict(self.entry, path="skamensky/other", url="git@github.com:skamensky/other.git")
        attempted = []
        def fail(command, **kwargs):
            if command[:2] == ["git", "clone"]:
                attempted.append(command[-2])
                self.assertIn("GlobalKnownHostsFile=/pinned", kwargs["env"]["GIT_SSH_COMMAND"])
                raise subprocess.CalledProcessError(1, command)
            return RUN(command, **kwargs)
        with patch.object(bootstrap.subprocess, "run", side_effect=fail), patch.dict(bootstrap.os.environ, clear=False) as env:
            env.pop("GIT_SSH_COMMAND", None)
            with self.assertRaisesRegex(RuntimeError, "skamensky/example, skamensky/other.*GitHub SSH access"):
                bootstrap.bootstrap([self.entry, other], self.home, known_hosts=Path("/pinned"))
        self.assertEqual(attempted, [self.entry["url"], other["url"]])
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.iterdir()), [])

    def test_dry_run_does_not_create_directories(self):
        bootstrap.bootstrap([self.entry], self.home, dry_run=True)
        self.assertFalse((self.home / "repos").exists())

    def test_invalid_paths_and_revisions_rejected_before_any_clone(self):
        for invalid in ["../escape", "/absolute", "owner/repo/extra"]:
            with self.assertRaises(ValueError):
                bootstrap.bootstrap([self.entry, dict(self.entry, path=invalid)], self.home)
        with self.assertRaises(ValueError):
            bootstrap.bootstrap([dict(self.entry, revision="main")], self.home)
        self.assertFalse((self.home / "repos").exists())


if __name__ == "__main__":
    unittest.main()
