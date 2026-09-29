# Copyright 2026 ABLECLOUD. Apache-2.0.
import tempfile
import unittest
from pathlib import Path

from scripts.process_guest_iso_manifest import TARGETS, write_manifest


class ProcessGuestIsoManifestTest(unittest.TestCase):
    def test_exactly_four_isos_and_checksums(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for family in TARGETS:
                (root / ("ABLESTACK-Tools-%s-test.iso" % family)).write_bytes(family.encode())
            manifest = write_manifest(root, "a" * 40, "123", "test")
            self.assertEqual(4, len(manifest["artifacts"]))
            self.assertEqual(["12", "13"], TARGETS["debian"])
            self.assertEqual(4, len((root / "SHA256SUMS").read_text().splitlines()))
            (root / "extra.iso").write_bytes(b"unexpected")
            with self.assertRaisesRegex(ValueError, "Unexpected ISO"):
                write_manifest(root, "a" * 40, "123", "test")

    def test_missing_iso_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "Missing or unsafe ISO"):
                write_manifest(temporary, "a" * 40, "123", "test")


if __name__ == "__main__":
    unittest.main()
