#!/usr/bin/env python3
"""Create a signed Sparkle feed for the verified release DMG."""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

from release import parse_version

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def make_feed(version, build, size, signature):
    parse_version(version)
    if not build.isdecimal() or int(build) < 1 or size < 1:
        raise ValueError("Invalid build number or archive size")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid Ed25519 signature")
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "SlotPick Updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"SlotPick {version}"
    ET.SubElement(item, "link").text = f"https://github.com/taako-502/slotpick/releases/tag/v{version}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/taako-502/slotpick/releases/download/v{version}/SlotPick-{version}.dmg",
        "type": "application/octet-stream", "length": str(size),
        f"{{{SPARKLE}}}edSignature": signature,
    })
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--sign-tool", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    secret = os.environ.get("SPARKLE_PRIVATE_KEY")
    signing_args = [str(args.sign_tool), "-p"]
    if secret:
        signing_args.extend(["--ed-key-file", "-"])
    else:
        signing_args.extend(["--account", "slotpick-updates"])
    signing_args.append(str(args.archive))
    result = subprocess.run(signing_args, input=secret, text=True, capture_output=True, timeout=120)
    if result.returncode != 0:
        raise RuntimeError("Update signing failed; check the signing key and Keychain access")
    signature = result.stdout.strip()
    subprocess.run([
        "swift", str(Path(__file__).with_name("verify-update.swift")),
        info["SUPublicEDKey"], signature, str(args.archive),
    ], check=True)
    args.output.write_bytes(make_feed(
        info["CFBundleShortVersionString"], info["CFBundleVersion"],
        args.archive.stat().st_size, signature,
    ))


if __name__ == "__main__":
    main()
