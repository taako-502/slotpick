import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class VersionTests(unittest.TestCase):
    def test_first_release_choices(self):
        self.assertEqual(release.bumped_version("0.1.0", [], "patch"), "0.1.1")
        self.assertEqual(release.bumped_version("0.1.0", [], "minor"), "0.2.0")
        self.assertEqual(release.bumped_version("0.1.0", [], "major"), "1.0.0")

    def test_latest_tag_is_compared_numerically(self):
        self.assertEqual(release.bumped_version("0.1.0", ["v0.9.9", "v0.10.2", "v0.2.0"], "patch"), "0.10.3")

    def test_prereleases_and_unrelated_tags_are_ignored(self):
        self.assertEqual(release.bumped_version("0.1.0", ["nightly", "v3.0.0-beta.1", "v01.2.3"], "minor"), "0.2.0")

    def test_project_version_is_a_floor(self):
        self.assertEqual(release.bumped_version("2.0.0", ["v1.5.0"], "patch"), "2.0.1")

    def test_rejects_invalid_inputs(self):
        for value in ["1.2", "01.2.3", "1.2.3;echo hello", "-1.2.3"]:
            with self.assertRaises(ValueError):
                release.parse_version(value)
        with self.assertRaises(ValueError):
            release.bumped_version("0.1.0", [], "other")


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.previous = Path.cwd()
        self.addCleanup(os.chdir, self.previous)
        os.chdir(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release Tests")
        self.git("config", "user.email", "tests@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        Path("SlotPick.xcodeproj").mkdir()
        Path("SlotPick.xcodeproj/project.pbxproj").write_text('MARKETING_VERSION = "0.1.0";\n')
        self.git("add", ".")
        self.git("commit", "-qm", "Initial")
        self.git("init", "--bare", "-q", "remote.git")
        self.git("remote", "add", "origin", str(Path("remote.git").resolve()))

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()

    def test_plan_does_not_modify_repository(self):
        self.assertEqual(release.plan("patch", "100"), "0.1.1")
        self.assertEqual(self.git("tag", "--list"), "")

    def test_retry_reuses_its_tag_even_after_newer_releases(self):
        self.git("tag", "-a", "v0.1.1", "-m", release.marker("100", "patch"))
        self.git("tag", "v1.0.0")
        self.assertEqual(release.plan("patch", "100"), "0.1.1")
        self.assertEqual(release.plan("patch", "101"), "1.0.1")

    def test_retry_refuses_changed_source_commit(self):
        self.git("tag", "-a", "v0.1.1", "-m", release.marker("100", "patch"))
        self.git("commit", "--allow-empty", "-qm", "New source")
        with self.assertRaisesRegex(ValueError, "another commit"):
            release.plan("patch", "100")

    def test_inconsistent_project_versions_fail(self):
        Path("SlotPick.xcodeproj/project.pbxproj").write_text('MARKETING_VERSION = "0.1.0"; MARKETING_VERSION = "0.2.0";')
        with self.assertRaisesRegex(ValueError, "consistent"):
            release.plan("patch", "100")

    def test_missing_assets_cannot_create_tag(self):
        with self.assertRaisesRegex(ValueError, "Missing release asset"):
            release.publish("0.1.1", "patch", "100", ".")
        self.assertEqual(self.git("tag", "--list"), "")

    def test_failed_upload_resumes_draft_without_another_bump(self):
        assets = Path("assets"); assets.mkdir()
        dmg = assets / "SlotPick-0.1.1.dmg"
        dmg.write_bytes(b"fixture: a previously validated DMG")
        checksum = assets / "SlotPick-0.1.1.dmg.sha256"
        checksum.write_text(hashlib.sha256(dmg.read_bytes()).hexdigest() + "  " + dmg.name + "\n")
        state = {"release": None, "fail_upload": True, "commands": []}
        real_command = release.command

        def command(*args):
            if args[0] != "gh":
                return real_command(*args)
            state["commands"].append(args[2])
            if args[2] == "create":
                self.assertIn("--draft", args)
                state["release"] = {"draft": True, "assets": [], "html_url": "https://example.invalid/release"}
            elif args[2] == "upload":
                self.assertTrue(state["release"]["draft"])
                if state["fail_upload"]:
                    raise RuntimeError("Simulated network failure")
                state["release"]["assets"] = [{"name": p.name, "size": p.stat().st_size} for p in [dmg, checksum]]
            elif args[2] == "edit":
                self.assertEqual(len(state["release"]["assets"]), 2)
                state["release"]["draft"] = False
            else:
                self.fail(f"Unexpected network command: {args}")
            return ""

        with patch.object(release, "command", side_effect=command), patch.object(release, "get_release", side_effect=lambda tag: state["release"]):
            with self.assertRaisesRegex(RuntimeError, "network failure"):
                release.publish("0.1.1", "patch", "100", assets)
            self.assertTrue(state["release"]["draft"])
            self.assertEqual(release.plan("patch", "100"), "0.1.1")
            state["fail_upload"] = False
            release.publish("0.1.1", "patch", "100", assets)
            self.assertFalse(state["release"]["draft"])
            self.assertEqual(self.git("tag", "--list"), "v0.1.1")
            uploads = state["commands"].count("upload")
            release.publish("0.1.1", "patch", "100", assets)
            self.assertEqual(state["commands"].count("upload"), uploads)


if __name__ == "__main__":
    unittest.main()
