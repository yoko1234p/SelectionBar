#!/usr/bin/env python3
"""Exercise handoff files in a temporary folder with the app launcher stubbed."""
import os
import shlex
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


class EdgeNotesHandoffTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="selectionbar-edgenotes-test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "Handoff"
        self.directory.mkdir(mode=0o700)
        self.source = (Path(__file__).resolve().parent.parent / "Extensions/EdgeNotes.popclipext/send.sh").read_text()

    def run_handoff(self, payload, launcher="/usr/bin/true"):
        source = self.source.replace(
            'handoff_dir="${HOME:?}/Library/Application Support/DeskTools Handoff"',
            "handoff_dir=" + shlex.quote(str(self.directory)),
        ).replace('/usr/bin/open -b local.pakwingho.edgenotes "$handoff_file"', launcher)
        script = self.root / "send.sh"
        script.write_text(source)
        return subprocess.run(["/bin/sh", str(script)], input=payload, capture_output=True, timeout=5, cwd=self.root)

    def test_text_is_exact_and_private_without_interpreting_selection(self):
        payload = '中文 日本語 한국어\n"quotes" $(touch SHOULD_NOT_RUN) `id` & <tag>\n'.encode()
        result = self.run_handoff(payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        files = list(self.directory.iterdir())
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].read_bytes(), payload)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.root / "SHOULD_NOT_RUN").exists())

    def test_empty_and_oversized_payloads_leave_no_file(self):
        self.assertEqual(self.run_handoff(b"").returncode, 0)
        result = self.run_handoff(b"a" * 1_000_001)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("最多 1 MB", result.stderr.decode())
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_failed_launch_removes_undelivered_file(self):
        self.assertNotEqual(self.run_handoff(b"undelivered", "/usr/bin/false").returncode, 0)
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_cleanup_removes_only_our_payloads_older_than_one_day(self):
        old = self.directory / "SelectionBar.old.edgetext"
        fresh = self.directory / "SelectionBar.fresh.edgetext"
        other = self.directory / "other.edgetext"
        for file in [old, fresh, other]:
            file.write_bytes(b"retained fixture")
        for file in [old, other]:
            os.utime(file, (time.time() - 30 * 3600,) * 2)
        os.utime(fresh, (time.time() - 23 * 3600,) * 2)
        self.assertEqual(self.run_handoff(b"new").returncode, 0)
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())
        self.assertTrue(other.exists())


if __name__ == "__main__":
    unittest.main()
