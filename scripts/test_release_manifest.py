#!/usr/bin/env python3
"""python3 scripts/test_release_manifest.py"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from release_manifest import ASSETS, OPTIONAL  # noqa: E402

SCRIPT = Path(__file__).parent / "release_manifest.py"


def run(folder, tag="v1.2.3"):
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(folder), tag, "150"],
        capture_output=True,
        text=True,
    )


class ReleaseManifest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        for name in ASSETS.values():
            (self.dir / name).write_bytes(b"x")

    def test_lists_every_platform(self):
        r = run(self.dir)
        self.assertEqual(r.returncode, 0, r.stderr)
        m = json.loads(r.stdout)
        self.assertEqual(set(m["assets"]), set(ASSETS))
        self.assertEqual(m["version"], "1.2.3")
        self.assertEqual(m["build"], 150)

    def test_release_can_go_out_without_macos(self):
        (self.dir / ASSETS["macos"]).unlink()
        r = run(self.dir)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("macos", json.loads(r.stdout)["assets"])
        self.assertIn("missing release file", r.stderr)

    def test_other_platforms_are_still_required(self):
        for platform, name in ASSETS.items():
            if platform in OPTIONAL:
                continue
            (self.dir / name).unlink()
            self.assertEqual(run(self.dir).returncode, 1, platform)
            (self.dir / name).write_bytes(b"x")

    def test_bad_tag_is_rejected(self):
        self.assertEqual(run(self.dir, tag="latest").returncode, 2)


if __name__ == "__main__":
    unittest.main()
