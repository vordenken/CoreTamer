"""Tests for scripts/update_appcast.py. Run with: python3 -m unittest discover -s tests"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from xml.dom import minidom

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
UPDATE_APPCAST = REPOSITORY_ROOT / "scripts" / "update_appcast.py"


def appcast_item(version, beta=False, build=1):
    channel = "<sparkle:channel>beta</sparkle:channel>" if beta else ""
    return f"""
        <item>
            <title>Version {version}</title>
            {channel}
            <enclosure
                url="https://example.com/{version}.dmg"
                sparkle:version="{build}"
                sparkle:shortVersionString="{version}"
                sparkle:edSignature="old-signature"
                length="100"
                type="application/octet-stream"/>
        </item>"""


class UpdateAppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="coretamer-appcast-")
        self.addCleanup(self.directory.cleanup)
        self.appcast = Path(self.directory.name) / "appcast.xml"
        self.changelog = Path(self.directory.name) / "changelog.txt"
        self.changelog.write_text("### Changes\n- Safe & tested\n", encoding="utf-8")

    def write_appcast(self, items):
        self.appcast.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            f"    <channel>\n        <title>CoreTamer Updates</title>{''.join(items)}\n"
            "    </channel>\n</rss>\n",
            encoding="utf-8",
        )

    def run_update(self, channel, tag, version="2.1.0", build=50):
        return subprocess.run(
            [
                sys.executable, str(UPDATE_APPCAST),
                "--appcast", str(self.appcast),
                "--changelog", str(self.changelog),
                "--version", version,
                "--tag", tag,
                "--build", str(build),
                "--channel", channel,
                "--signature", "new-signature",
                "--length", "200",
                "--max-betas", "5",
                "--date", "Mon, 31 Aug 2026 12:00:00 +0000",
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def output(self):
        minidom.parse(str(self.appcast))
        return self.appcast.read_text(encoding="utf-8")

    def test_beta_update_keeps_five_newest_betas_and_every_stable_release(self):
        self.write_appcast(
            [appcast_item(f"2.1.0-beta{n}", beta=True, build=40 + n) for n in range(6, 0, -1)]
            + [appcast_item("2.0.0", build=10), appcast_item("1.0.1", build=5)]
        )
        result = self.run_update("beta", "v2.1.0-beta7")
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.output()
        self.assertEqual(output.count("<sparkle:channel>beta</sparkle:channel>"), 5)
        self.assertIn('sparkle:shortVersionString="2.1.0-beta7"', output)
        self.assertNotIn('sparkle:shortVersionString="2.1.0-beta2"', output)
        self.assertIn('sparkle:shortVersionString="2.0.0"', output)
        self.assertIn('sparkle:shortVersionString="1.0.1"', output)
        self.assertIn("<li>Safe &amp; tested</li>", output)
        self.assertIn("Beta Release", output)
        self.assertIn(
            "https://github.com/vordenken/CoreTamer/releases/download/v2.1.0-beta7/CoreTamer.dmg",
            output,
        )

    def test_stable_promotion_removes_betas_for_that_version_only(self):
        self.write_appcast(
            [
                appcast_item("2.2.0-beta1", beta=True, build=60),
                appcast_item("2.1.0-beta2", beta=True, build=49),
                appcast_item("2.1.0-beta1", beta=True, build=48),
                appcast_item("2.0.0", build=10),
            ]
        )
        result = self.run_update("stable", "v2.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.output()
        self.assertIn('sparkle:shortVersionString="2.1.0"', output)
        self.assertNotIn('sparkle:shortVersionString="2.1.0-beta', output)
        self.assertIn('sparkle:shortVersionString="2.2.0-beta1"', output)
        self.assertIn('sparkle:shortVersionString="2.0.0"', output)

    def test_first_release_into_empty_appcast(self):
        self.write_appcast([])
        result = self.run_update("stable", "v1.0.0", version="1.0.0", build=11)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.output()
        self.assertIn('sparkle:version="11"', output)
        self.assertNotIn("sparkle:channel", output)

    def test_rejects_tag_that_does_not_match_channel(self):
        self.write_appcast([])
        result = self.run_update("stable", "v2.1.0-beta1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match stable version", result.stderr)

    def test_rejects_invalid_version(self):
        self.write_appcast([])
        result = self.run_update("stable", "v2.1", version="2.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid version", result.stderr)


if __name__ == "__main__":
    unittest.main()
