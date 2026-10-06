import base64
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from appcast import SPARKLE, make_feed


class AppcastTests(unittest.TestCase):
    def test_feed_matches_release_and_uses_internal_build_number(self):
        signature = base64.b64encode(bytes(range(64))).decode()
        root = ET.fromstring(make_feed("0.2.0", "42", 1234, signature))
        item = root.find("channel/item")
        self.assertEqual(item.find(f"{{{SPARKLE}}}version").text, "42")
        self.assertEqual(item.find(f"{{{SPARKLE}}}shortVersionString").text, "0.2.0")
        self.assertEqual(item.find(f"{{{SPARKLE}}}minimumSystemVersion").text, "14.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.attrib["url"], "https://github.com/taako-502/slotpick/releases/download/v0.2.0/SlotPick-0.2.0.dmg")
        self.assertEqual(enclosure.attrib["length"], "1234")
        self.assertEqual(enclosure.attrib[f"{{{SPARKLE}}}edSignature"], signature)

    def test_rejects_invalid_release_metadata(self):
        signature = base64.b64encode(bytes(64)).decode()
        for version, build, size, sig in [
            ("../bad", "42", 1, signature), ("0.2.0", "0", 1, signature),
            ("0.2.0", "42", 0, signature), ("0.2.0", "42", 1, "bad"),
        ]:
            with self.subTest(version=version, build=build, size=size, signature=sig):
                with self.assertRaises(ValueError):
                    make_feed(version, build, size, sig)
