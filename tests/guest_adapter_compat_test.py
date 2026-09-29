#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
"""An upgrade or migration may change hosts, but never approve mixed payloads."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from guest_adapter_compat import CATALOG, approved


class GuestAdapterCompatibilityTests(unittest.TestCase):
    def test_old_and_new_windows_bundle_are_approved_as_complete_pairs(self):
        read = approved('windows-read')
        action = approved('windows-action')
        self.assertGreaterEqual(len(read), 2)
        self.assertGreaterEqual(len(action), 2)
        old = ('8bc4ad8d2e1ab0e572c90c071f71d4b79de8d04cc75aea938a1daf235c37ef75',
               'ef2e96391d0973ff56d0bbf9ad0ea573eb0049aef9b59cf47d73846103f0324a')
        installed = (old[0], 'e9e405c166eb95b2b6d529b3e66c06a5a0806e9a6464646771c2547b0cbee32f')
        self.assertIn(old, read)
        self.assertIn(installed, read)
        self.assertNotIn((old[0], '0' * 64), read)
        self.assertIn(('1f46fb58d6d1215854378080df0c4bba1bc75f96fb379d8abbbd59cd185b72be',
                       'efff2affe6776ee4049793e7e2d27ea94cc7afab93352d05ad747fad0cd5651b',
                       installed[1]), action)

    def test_linux_families_and_action_have_approved_bundles(self):
        self.assertTrue(approved('rocky-read'))
        self.assertTrue(approved('ubuntu-read'))
        self.assertTrue(approved('linux-action'))

    def test_catalog_tamper_or_partial_file_set_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'catalog.json'
            value = json.loads(CATALOG.read_text())
            value['bundles'][0]['sha256'].pop('AbleProcessIdentity.dll')
            target.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                approved('windows-read', target)
            target.write_text(CATALOG.read_text())
            os.chmod(target, 0o666)
            with self.assertRaises(ValueError):
                approved('windows-read', target)
            os.chmod(target, 0o600)
            target.write_text(CATALOG.read_text().replace('"schemaVersion": 1,', '"schemaVersion": 1, "schemaVersion": 1,', 1))
            with self.assertRaises(ValueError):
                approved('windows-read', target)
            target.unlink()
            target.symlink_to(CATALOG)
            with self.assertRaises(OSError):
                approved('windows-read', target)


if __name__ == '__main__':
    unittest.main()
