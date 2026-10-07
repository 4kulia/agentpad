#!/usr/bin/env python3
"""Offline tests; execute only release.sh's feed generation, never signing."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agentpad-appcast-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        (self.root / "dist").mkdir()
        self.notes = self.root / "release notes.md"
        self.notes.write_text("## Changes\n\nA **bold** change with `**literal** <code>`.\nNext line.\n\n- First & safe\n- Second\n  continued\n\n## Install or update\n\nOmit installation.\n- Omit download.\n\n## Fixes\n\nKeep this section.\n<script>bad()</script> ]]>\n", encoding="utf-8")

    def generate(self, notes=True, attributes='sparkle:edSignature="fixture-signature" length="123"'):
        source = (ROOT / "scripts/release.sh").read_text()
        # Both the legacy heredoc and the new helper are exercised through the
        # actual release entry point, with no release/signing steps preceding it.
        block = source[source.index('DMG_URL='):source.index('echo "==> Gatekeeper assessment"')]
        env = os.environ.copy()
        env.pop("AGENTPAD_RELEASE_NOTES", None)
        env.update(VERSION="1.1.5", DMG="dist/AgentPad-v1.1.5.dmg", ED_ATTRS=attributes)
        if notes:
            env["AGENTPAD_RELEASE_NOTES"] = str(self.notes)
        return subprocess.run(["bash", "-eu", "-c", block], cwd=self.root, env=env, capture_output=True, text=True)

    def testEmbeddedHTMLAndSafeMarkdown(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = self.root / "dist/appcast.xml"
        subprocess.run(["xmllint", "--nonet", "--noout", str(feed)], check=True)
        item = ET.parse(feed).find("channel/item")
        self.assertIsNone(item.find(SPARKLE + "releaseNotesLink"))
        markup = item.findtext("description")
        self.assertIsNotNone(markup)
        for expected in ["<h3>Changes</h3>", "<strong>bold</strong>", "<code>**literal** &lt;code&gt;</code>",
                         "<ul><li>First &amp; safe</li><li>Second continued</li></ul>", "<h3>Fixes</h3>",
                         "&lt;script&gt;bad()&lt;/script&gt;", "prefers-color-scheme:dark"]:
            self.assertIn(expected, markup)
        self.assertNotIn("Install or update", markup)
        self.assertNotIn("Omit", markup)
        self.assertIn("<![CDATA[", feed.read_text())
        self.assertEqual(item.find("enclosure").attrib[SPARKLE + "edSignature"], "fixture-signature")
        self.assertEqual(item.find("enclosure").attrib["length"], "123")

    def testLegacyLinkWithoutVariable(self):
        self.assertEqual(self.generate(notes=False).returncode, 0)
        item = ET.parse(self.root / "dist/appcast.xml").find("channel/item")
        self.assertIsNone(item.find("description"))
        self.assertEqual(item.findtext(SPARKLE + "releaseNotesLink"), "https://github.com/4kulia/agentpad/releases/tag/v1.1.5")

    def testMissingNotesFailInsteadOfSilentlyPublishingALink(self):
        self.notes.unlink()
        self.assertNotEqual(self.generate().returncode, 0)

    def testReleaseRejectsMalformedXML(self):
        self.assertNotEqual(self.generate(attributes='sparkle:edSignature="broken').returncode, 0)

    def testInstallHeadingAtStartIsDropped(self):
        self.notes.write_text("## Install or update\n\nOmit everything.\n", encoding="utf-8")
        result = subprocess.run(["python3", "-I", str(ROOT / "scripts/notes2html.py"), str(self.notes)], capture_output=True, text=True, check=True)
        self.assertIn("<body></body>", result.stdout)


if __name__ == "__main__":
    unittest.main()
