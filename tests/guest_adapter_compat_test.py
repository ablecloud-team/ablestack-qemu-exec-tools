#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
"""An upgrade or migration may change hosts, but never approve mixed payloads."""
import json
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from guest_adapter_compat import CATALOG, approved, linux_read_profile, supported_windows
from scripts.append_guest_adapter_compat import hashes


class GuestAdapterCompatibilityTests(unittest.TestCase):
    def test_linux_multi_os_profile_matches_support_matrix(self):
        for family in ('rocky', 'rhel'):
            for version in ('8', '8.10', '9', '9.6', '9.8', '10', '10.2', '10.3'):
                with self.subTest(family=family, version=version):
                    self.assertEqual('rocky-read', linux_read_profile({'id': family, 'version-id': version}))
        for family, versions in (('ubuntu', ('22.04', '24.04', '26.04')), ('debian', ('12', '13'))):
            for version in versions:
                self.assertEqual('ubuntu-read', linux_read_profile({'id': family, 'version-id': version}))
        for family, version in (('rocky', '7.9'), ('rocky', '11'), ('rocky', '8.'), ('rocky', '8x'),
                                ('ubuntu', '20.04'), ('ubuntu', '24.10'), ('debian', '11'), ('debian', '14'),
                                ('centos', '9'), ('rocky', 8), ('rocky', None)):
            with self.subTest(family=family, version=version):
                self.assertIsNone(linux_read_profile({'id': family, 'version-id': version, 'id-like': 'rhel debian'}))

    def test_new_windows_catalog_entry_hashes_exact_script_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            script=b"Write-Output 'test'\r\n"
            (root/'ProcessList.ps1').write_bytes(script)
            (root/'AbleProcessIdentity.dll').write_bytes(b'native')
            value=hashes(root,'windows-read',directory=True)
            self.assertEqual(value['ProcessList.ps1'],hashlib.sha256(script).hexdigest())
            self.assertNotEqual(value['ProcessList.ps1'],hashlib.sha256(script.replace(b'\r\n',b'\n')).hexdigest())

    def test_windows_multi_os_host_gate(self):
        supported = (
            ('11', 'client', 'Windows 11 Pro'),
            ('2019', 'server', 'Windows Server 2019 Standard Evaluation'),
            ('2022', 'server', 'Windows Server 2022 Standard'),
            ('2025', 'server', 'Windows Server 2025 Standard'),
        )
        for version, variant, pretty in supported:
            with self.subTest(version=version):
                self.assertTrue(supported_windows({
                    'id': 'mswindows', 'version-id': version,
                    'variant-id': variant, 'pretty-name': pretty,
                }))
        self.assertTrue(supported_windows({
            'id': 'mswindows', 'version-id': '10.0',
            'pretty-name': 'Microsoft Windows Server 2022',
        }))
        for version, variant, pretty in (
            ('10', 'client', 'Windows 10 Pro'),
            ('2016', 'server', 'Windows Server 2016'),
            ('11', 'server', 'Windows Server 2019'),
        ):
            with self.subTest(unsupported=pretty):
                self.assertFalse(supported_windows({
                    'id': 'mswindows', 'version-id': version,
                    'variant-id': variant, 'pretty-name': pretty,
                }))

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
        repaired = ('e8f7b6f69a7d245753055ac4776559a254f2e0a2f03517a22220a74acd323d05',
                    '2ba9e15e797eebe6ff6f7242a62c8d7fcff7f6eb379005e364241be3b475ffb2')
        self.assertIn(repaired, read)
        self.assertNotIn((repaired[0], installed[1]), read)
        self.assertIn(('1f46fb58d6d1215854378080df0c4bba1bc75f96fb379d8abbbd59cd185b72be',
                       '1cacad12dbc8c25f85d874a6c8e3ba4c0351198201b5ec3f811cf04749a1d565',
                       repaired[1]), action)
        multi_os = ('b64869b5fe0ca9084100c80eea91ed72ab2944f5f8a4b87ec9358b18aefe7c3e',
                    '0a97664f4a104872d4bf0c26cb9cd657e76a98a7bb649a51dbe050081705e391')
        self.assertIn(multi_os, read)
        self.assertNotIn((multi_os[0], repaired[1]), read)
        self.assertIn(('1f46fb58d6d1215854378080df0c4bba1bc75f96fb379d8abbbd59cd185b72be',
                       '4c26bc5fe03c692aed77a35922f325e89f727f0625d60babfba6145473590a36',
                       multi_os[1]), action)
        notice_iso = (multi_os[0], 'ac3a2928f5d8d14262ce1e12f480cefee2d272d87ef3802f43f8d5c8529659f1')
        self.assertIn(notice_iso, read)
        self.assertNotIn((notice_iso[0], repaired[1]), read)
        self.assertIn(('1f46fb58d6d1215854378080df0c4bba1bc75f96fb379d8abbbd59cd185b72be',
                       'c008ac98c5bc8a7cb390dd655ff1546ea6104e54e51c8c78018c0b1a09ab358e',
                       notice_iso[1]), action)

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
