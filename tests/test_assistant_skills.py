import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "assistant_skills", Path(__file__).parents[1] / "scripts/link-assistant-skills.py"
)
skills = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skills)


class AssistantSkillTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.source = self.root / "canonical/skills"
        self.source.mkdir(parents=True)

    def create_skill(self, name):
        directory = self.source / name
        directory.mkdir()
        (directory / "SKILL.md").write_text("Canonical skill content, never copied.\n")
        return directory

    def test_discovery_is_idempotent_and_tracks_live_checkout_changes(self):
        self.create_skill("first")
        self.assertEqual(len(skills.link_skills(self.source, self.home)), 2)
        self.assertEqual(skills.link_skills(self.source, self.home), [])
        self.create_skill("second")
        shutil.rmtree(self.source / "first")
        skills.link_skills(self.source, self.home)
        for assistant in skills.ASSISTANTS:
            directory = self.home / f".{assistant}/skills"
            self.assertFalse((directory / "first").is_symlink())
            self.assertTrue((directory / "second").is_symlink())
            self.assertEqual((directory / "second").resolve(), self.source / "second")

    def test_conflict_in_second_assistant_prevents_all_changes(self):
        self.create_skill("personal")
        conflict = self.home / ".codex/skills/personal"
        conflict.mkdir(parents=True)
        (conflict / "keep").write_text("unmanaged")
        with self.assertRaisesRegex(RuntimeError, "unmanaged"):
            skills.link_skills(self.source, self.home)
        self.assertFalse((self.home / ".claude").exists())
        self.assertEqual((conflict / "keep").read_text(), "unmanaged")

    def test_preserves_system_plugins_and_unrelated_symlinks(self):
        self.create_skill("personal")
        for assistant in skills.ASSISTANTS:
            directory = self.home / f".{assistant}/skills"
            (directory / ".system").mkdir(parents=True)
            (directory / "plugin-skill").mkdir()
            (directory / "other").symlink_to(self.root / "unrelated")
        skills.link_skills(self.source, self.home)
        for assistant in skills.ASSISTANTS:
            directory = self.home / f".{assistant}/skills"
            self.assertTrue((directory / ".system").is_dir())
            self.assertTrue((directory / "plugin-skill").is_dir())
            self.assertTrue((directory / "other").is_symlink())

    def test_dry_run_and_non_skills_do_not_create_files(self):
        self.create_skill("personal")
        self.create_skill(".hidden")
        (self.source / "notes").mkdir()
        (self.source / "README.md").write_text("not a skill")
        self.assertEqual(len(skills.link_skills(self.source, self.home, True)), 2)
        self.assertFalse(self.home.exists())

    def test_missing_source_and_symlinked_destination_are_rejected(self):
        with self.assertRaises(RuntimeError):
            skills.link_skills(self.root / "missing", self.home)
        self.create_skill("personal")
        (self.home / ".claude").mkdir(parents=True)
        (self.home / ".claude/skills").symlink_to(self.source)
        with self.assertRaises(RuntimeError):
            skills.link_skills(self.source, self.home)
        self.assertFalse((self.home / ".codex").exists())


if __name__ == "__main__":
    unittest.main()
