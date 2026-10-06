"""Exercise packaging failure boundaries with fake Apple tools; no credentials/network."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


FAKE_TOOL = r'''
import json, os, pathlib, plistlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["FAKE_ROOT"])
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "xcodebuild" and "-exportArchive" in args:
    app = pathlib.Path(args[args.index("-exportPath") + 1]) / "SlotPick.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.2.2", "CFBundleVersion": "5"}))
    (app / "Contents/MacOS/SlotPick").touch()
elif name == "ditto":
    if "-c" in args:
        pathlib.Path(args[-1]).write_bytes(b"archive")
    else:
        shutil.copytree(args[-2], args[-1])
elif name == "hdiutil":
    if args[0] == "create":
        pathlib.Path(args[-1]).write_bytes(b"dmg")
        (root / "staging").write_text(args[args.index("-srcfolder") + 1])
    elif args[0] == "attach":
        shutil.copytree((root / "staging").read_text(), args[args.index("-mountpoint") + 1], symlinks=True)
elif name == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        suffix = pathlib.Path(args[2]).suffix
        status = "Invalid" if os.environ.get("REJECT_SUFFIX") == suffix else "Accepted"
        print(json.dumps({"status": status, "id": "fake-submission"}))
    elif args[:2] == ["stapler", "staple"] and args[-1].endswith(".dmg"):
        with open(args[-1], "ab") as dmg:
            dmg.write(b"-stapled")
elif name == "spctl" and os.environ.get("FAIL_GATEKEEPER"):
    sys.exit(1)
elif name == "python3":
    if args[0] == "scripts/appcast.py":
        pathlib.Path(args[args.index("--output") + 1]).write_text("test feed")
    else:
        os.execv(os.environ["REAL_PYTHON"], [os.environ["REAL_PYTHON"], *args])
'''


@unittest.skipUnless(sys.platform == "darwin", "Packaging uses macOS PlistBuddy")
class NotarizedDmgTests(unittest.TestCase):
    def package(self, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bins = root / "bin"
            bins.mkdir()
            for name in ("xcodebuild", "codesign", "ditto", "hdiutil", "xcrun", "lipo", "spctl", "python3"):
                tool = bins / name
                tool.write_text(f"#!{sys.executable}\n" + FAKE_TOOL)
                tool.chmod(0o755)
            env = os.environ | {
                "PATH": str(bins) + os.pathsep + os.environ["PATH"],
                "FAKE_ROOT": str(root), "REAL_PYTHON": sys.executable,
                "CODE_SIGN_IDENTITY": "A" * 40, "APPLE_TEAM_ID": "ABCDE12345",
                "SIGNING_KEYCHAIN": "fake-keychain", "NOTARYTOOL_PROFILE": "fake-profile",
                "RUNNER_TEMP": str(root), **overrides,
            }
            output = root / "output"
            result = subprocess.run([
                "bash", str(Path(__file__).resolve().parents[1] / "build-dmg.sh"),
                "0.2.2", "5", str(output),
            ], env=env, text=True, capture_output=True)
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            files = {path.name: path.read_bytes() for path in output.iterdir()}
            return result, calls, files

    def test_rejected_app_or_dmg_never_produces_release_assets(self):
        for suffix in (".zip", ".dmg"):
            with self.subTest(suffix=suffix):
                result, calls, files = self.package(REJECT_SUFFIX=suffix)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Notarization failed", result.stderr)
                self.assertEqual(files, {})
                self.assertFalse(any(call[:2] == ["python3", "scripts/appcast.py"] for call in calls))

    def test_gatekeeper_failure_never_produces_release_assets(self):
        result, _, files = self.package(FAIL_GATEKEEPER="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, {})

    def test_success_signs_final_stapled_dmg_only_after_verification(self):
        result, calls, files = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files["SlotPick-0.2.2.dmg"], b"dmg-stapled")
        self.assertIn("appcast.xml", files)
        notarizations = [call for call in calls if call[:3] == ["xcrun", "notarytool", "submit"]]
        self.assertEqual([Path(call[3]).suffix for call in notarizations], [".zip", ".dmg"])
        verification = max(i for i, call in enumerate(calls) if call[0] == "spctl")
        feed = next(i for i, call in enumerate(calls) if call[:2] == ["python3", "scripts/appcast.py"])
        self.assertLess(verification, feed)
