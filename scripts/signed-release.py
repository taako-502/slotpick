#!/usr/bin/env python3
"""Build a notarized release using an isolated, short-lived signing keychain."""
import base64
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
import tempfile


REQUIRED = (
    "DEVELOPER_ID_CERTIFICATE_BASE64", "DEVELOPER_ID_CERTIFICATE_PASSWORD",
    "APPLE_TEAM_ID", "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD",
)


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        # Do not expose command arguments or tool output containing credentials.
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode})")
    return result.stdout


def build(version, build_number, output_dir):
    missing = [name for name in REQUIRED if not os.environ.get(name)]
    if missing:
        raise ValueError("Required release secrets: " + ", ".join(missing))
    team = os.environ["APPLE_TEAM_ID"]
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("APPLE_TEAM_ID must be a 10-character Team ID")
    certificate = base64.b64decode(os.environ[REQUIRED[0]], validate=True)
    original_keychains = shlex.split(run("security", "list-keychains", "-d", "user"))
    with tempfile.TemporaryDirectory(prefix="slotpick-signing-") as directory:
        keychain = str(Path(directory) / "release.keychain-db")
        p12 = Path(directory) / "certificate.p12"
        p12.write_bytes(certificate)
        p12.chmod(0o600)
        password = secrets.token_urlsafe(32)
        created = False
        try:
            run("security", "create-keychain", "-p", password, keychain)
            created = True
            run("security", "set-keychain-settings", "-lut", "7200", keychain)
            run("security", "unlock-keychain", "-p", password, keychain)
            run("security", "import", str(p12), "-k", keychain,
                "-P", os.environ[REQUIRED[1]], "-T", "/usr/bin/codesign")
            p12.unlink()
            run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                "-s", "-k", password, keychain)
            identities = run("security", "find-identity", "-v", "-p", "codesigning", keychain)
            matches = re.findall(
                rf'\b([A-Fa-f0-9]{{40}}) "Developer ID Application: [^"\n]+ \({team}\)"', identities)
            if len(matches) != 1:
                raise ValueError("Certificate must contain exactly one valid Developer ID Application identity for APPLE_TEAM_ID")
            run("security", "list-keychains", "-d", "user", "-s", keychain, *original_keychains)
            run("xcrun", "notarytool", "store-credentials", "slotpick-release", "--keychain", keychain,
                "--apple-id", os.environ["APPLE_ID"], "--team-id", team,
                "--password", os.environ["APPLE_APP_SPECIFIC_PASSWORD"])
            env = os.environ.copy()
            for name in REQUIRED:
                env.pop(name, None)
            env.update(CODE_SIGN_IDENTITY=matches[0], APPLE_TEAM_ID=team,
                       NOTARYTOOL_PROFILE="slotpick-release", SIGNING_KEYCHAIN=keychain)
            result = subprocess.run(
                ["bash", str(Path(__file__).with_name("build-dmg.sh")), version, build_number, output_dir],
                env=env)
            if result.returncode:
                raise RuntimeError("Signed release build failed; no release was published")
        finally:
            if created:
                try:
                    run("security", "list-keychains", "-d", "user", "-s", *original_keychains)
                finally:
                    run("security", "delete-keychain", keychain)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("Usage: signed-release.py VERSION BUILD_NUMBER OUTPUT_DIRECTORY")
        build(*sys.argv[1:])
    except (ValueError, RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
