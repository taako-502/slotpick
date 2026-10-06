import base64
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("signed_release", Path(__file__).resolve().parents[1] / "signed-release.py")
signed_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signed_release)


class SignedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.env = dict(zip(signed_release.REQUIRED, (
            base64.b64encode(b"test certificate").decode(), "p12-password",
            "ABCDE12345", "developer@example.invalid", "notary-password",
        )))
        self.calls = []

    def command(self, *args):
        self.calls.append(args)
        if args == ("security", "list-keychains", "-d", "user"):
            return '"/original/login.keychain-db"\n'
        if args[:2] == ("security", "find-identity"):
            return '1) ' + 'A' * 40 + ' "Developer ID Application: Test (ABCDE12345)"'
        return ""

    def test_missing_secrets_stops_before_keychain_changes(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(signed_release, "run") as run:
            with self.assertRaisesRegex(ValueError, "Required release secrets"):
                signed_release.build("0.2.2", "5", "/tmp/output")
            run.assert_not_called()

    def test_build_failure_restores_keychains_and_removes_credentials(self):
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(signed_release, "run", side_effect=self.command), \
                patch.object(signed_release.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as build:
            with self.assertRaisesRegex(RuntimeError, "Signed release build failed"):
                signed_release.build("0.2.2", "5", "/tmp/output")
            child_env = build.call_args.kwargs["env"]
            self.assertEqual(child_env["CODE_SIGN_IDENTITY"], "A" * 40)
            self.assertNotIn("APPLE_APP_SPECIFIC_PASSWORD", child_env)
            self.assertNotIn("DEVELOPER_ID_CERTIFICATE_BASE64", child_env)
        self.assertEqual(self.calls[-2], (
            "security", "list-keychains", "-d", "user", "-s", "/original/login.keychain-db"))
        self.assertEqual(self.calls[-1][:2], ("security", "delete-keychain"))
        self.assertFalse(Path(self.calls[-1][-1]).parent.exists())

    def test_wrong_certificate_stops_before_build_and_cleans_up(self):
        def wrong_identity(*args):
            result = self.command(*args)
            return result.replace("ABCDE12345", "WRONG12345")
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(signed_release, "run", side_effect=wrong_identity), \
                patch.object(signed_release.subprocess, "run") as build:
            with self.assertRaisesRegex(ValueError, "Developer ID Application identity"):
                signed_release.build("0.2.2", "5", "/tmp/output")
            build.assert_not_called()
        self.assertEqual(self.calls[-1][:2], ("security", "delete-keychain"))

    def test_tool_errors_do_not_expose_password_arguments_or_output(self):
        result = subprocess.CompletedProcess([], 1, "sensitive stdout", "sensitive stderr")
        with patch.object(signed_release.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, r"^security failed \(exit 1\)$"):
                signed_release.run("security", "import", "-P", "private-password")
