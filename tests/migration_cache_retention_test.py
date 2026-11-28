#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Cache policy and real cutover failure/retention paths with a stateful Mold fixture."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import mold_preallocation_handoff_test as mold

ROOT = Path(__file__).resolve().parents[1]


class CacheRetention(unittest.TestCase):
    def setUp(self):
        self.fixture = mold.Handoff()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def shell(self, tool, manifest, code, **extra):
        env = {**os.environ, 'TOOL': tool, 'REPO': str(ROOT), 'MANIFEST': str(manifest), **extra}
        return subprocess.run(['bash', '-euo', 'pipefail', '-c',
                               'source "$REPO/lib/$TOOL/disk_cache.sh"; ' + code],
                              env=env, text=True, capture_output=True, timeout=30)

    def test_new_default_override_invalid_and_frozen_legacy(self):
        path = self.fixture.root / 'manifest.json'
        for tool in ['v2k', 'n2k']:
            for mode in ['none', 'writeback']:
                doc = {'target': {'provider': 'ablestack-cloud'}, 'disks': []}
                path.write_text(json.dumps(doc))
                extra = {} if mode == 'none' else {tool.upper() + '_TARGET_DISK_CACHE': mode}
                r = self.shell(tool, path, 'migration_disk_cache_configure "$TOOL" "$MANIFEST" 1', **extra)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(json.loads(path.read_text())['target']['storage']['cache_mode'], mode)
            doc = {'target': {'provider': 'ablestack-cloud'}, 'runtime': {'cloud': {'checkpoint': {'vm_id': 'vm'}}}}
            path.write_text(json.dumps(doc))
            before = path.read_bytes()
            r = self.shell(tool, path, 'migration_disk_cache_value "$TOOL" "$MANIFEST"')
            self.assertEqual(r.stdout, 'writeback', r.stderr)
            r = self.shell(tool, path, 'migration_disk_cache_configure "$TOOL" "$MANIFEST"',
                           **{tool.upper() + '_TARGET_DISK_CACHE': 'none'})
            self.assertEqual(r.returncode, 44, r.stderr)
            self.assertIn('TARGET_CACHE_POLICY_FROZEN', r.stderr)
            self.assertEqual(path.read_bytes(), before)
            r = self.shell(tool, path, 'migration_disk_cache_enum unsafe')
            self.assertEqual(r.returncode, 44)

    def test_actual_wizard_menu_default_and_override_and_libvirt_xml(self):
        for tool in ['v2k', 'n2k']:
            for answer, expected in [('\n', 'none'), ('2\n', 'writeback')]:
                env = {**os.environ, 'REPO': str(ROOT), 'TOOL': tool}
                code = '''source "$REPO/lib/$TOOL/interactive.sh"
source "$REPO/lib/$TOOL/disk_cache.sh"
v2k_interactive_has_tty() { return 0; }
n2k_interactive_has_tty() { return 0; }
migration_disk_cache_wizard "$TOOL" '' 0 0
var="${TOOL^^}_TARGET_DISK_CACHE"; printf '%s' "${!var}"
'''
                r = subprocess.run(['bash', '-euo', 'pipefail', '-c', code], env=env,
                                   input=answer, text=True, capture_output=True, timeout=10)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout, expected)
                self.assertIn('target disk cache:', r.stderr)
                path = self.fixture.root / 'xml.json'
                path.write_text(json.dumps({'target': {'provider': 'libvirt', 'format': 'qcow2', 'storage': {'type': 'file', 'cache_mode': expected}},
                                            'disks': [{'controller': {'kind': 'scsi', 'type': 'VirtualLsiLogicSASController'}, 'transfer': {'target_path': '/fixture/disk.qcow2'}}]}))
                fn = '_v2k_target_disk_xml' if tool == 'v2k' else 'n2k_target_disk_xml'
                r = self.shell(tool, path, 'source "$REPO/lib/$TOOL/target_libvirt.sh"; ' + fn + ' "$MANIFEST" 0')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("cache='" + expected + "'", r.stdout)

    def test_cache_applies_to_all_mold_disks_and_explicit_writeback(self):
        for tool in ['v2k', 'n2k']:
            for mode in ['none', 'writeback']:
                with self.subTest(tool=tool, mode=mode):
                    r, state, doc = self.fixture.run_cutover(tool, cache=mode)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual({v['cachemode'] for v in state['volumes'].values()}, {mode})
                    self.assertEqual(doc['runtime']['cloud']['cache']['verified'], True)
                    self.assertEqual(len(doc['runtime']['cloud']['cache']['volumes']), 2)
                    self.assertIn('None' if mode == 'none' else 'Writeback', state['offerings'][0]['name'])

    def test_explicit_offering_and_missing_or_wrong_volume_cache_fail_closed(self):
        path = self.fixture.root / 'manifest.json'
        path.write_text(json.dumps({'target': {'provider': 'ablestack-cloud', 'storage': {'type': 'rbd', 'cache_mode': 'none'}},
                                    'disks': [{}], 'runtime': {'cloud': {'checkpoint': {'vm_id': 'vm', 'root_volume_id': 'root'}}}}))
        for tool in ['v2k', 'n2k']:
            code = '''source "$REPO/lib/$TOOL/cloud_allocation.sh"
v2k_cloud_api_get() { echo '{"listdiskofferingsresponse":{"diskoffering":[{"id":"explicit","storagetype":"shared","cachemode":"writeback","customized":true}]}}'; }
n2k_cloud_api_get() { v2k_cloud_api_get "$@"; }
migration_cloud_allocation_validate_offering "$TOOL" "$MANIFEST" endpoint key secret explicit shared
'''
            r = self.shell(tool, path, code)
            self.assertEqual(r.returncode, 2, r.stderr)
            for cache in ['', 'writeback', 'none']:
                code = '''v2k_cloud_api_get() { printf '%s' "$RESPONSE"; }
n2k_cloud_api_get() { printf '%s' "$RESPONSE"; }
migration_disk_cache_verify_cloud "$TOOL" "$MANIFEST" endpoint key secret
'''
                response = {'listvolumesresponse': {'volume': [{'id': 'root', 'virtualmachineid': 'vm', 'state': 'Ready', 'deviceid': 0}]}}
                if cache:
                    response['listvolumesresponse']['volume'][0]['cachemode'] = cache
                r = self.shell(tool, path, code, RESPONSE=json.dumps(response))
                self.assertEqual(r.returncode, 0 if cache == 'none' else 78, r.stderr)

    def test_actual_cutover_retains_ids_and_state_on_verification_errors(self):
        for tool in ['v2k', 'n2k']:
            for status, code in [('FAILED', 78), ('DRIFT', 78), ('BOUND', 78), ('API_ERROR', 7)]:
                with self.subTest(tool=tool, status=status):
                    r, state, doc = self.fixture.run_cutover(tool, guest_status=status)
                    self.assertEqual(r.returncode, code, r.stderr)
                    self.assertEqual(state['vm']['state'], 'Running')
                    self.assertEqual(len(state['volumes']), 2)
                    cloud = doc['runtime']['cloud']
                    self.assertFalse(cloud['checkpoint']['complete'])
                    self.assertFalse(cloud['validated'])
                    retained = cloud['retention']
                    self.assertEqual(retained['status'], 'RETAINED_UNVERIFIED')
                    self.assertEqual(retained['exit_code'], code)
                    self.assertEqual(retained['vm_id'], state['vm']['id'])
                    self.assertIn(retained['root_volume_id'], state['volumes'])
                    self.assertEqual(retained['data_volumes']['1']['id'], cloud['checkpoint']['data_volumes']['1']['id'])
                    apis = [c['api'] for c in state['calls']]
                    self.assertFalse(set(apis) & {'stopVirtualMachine', 'destroyVirtualMachine', 'detachVolume', 'deleteVolume', 'expungeVirtualMachine'})
                    if status == 'BOUND':
                        self.assertEqual(doc['runtime']['guest_configuration']['status'], 'TIMED_OUT')
                    # Repair/verification retry uses the very same handoff, without imports/source probes.
                    case = Path(retained['resume']['manifest']).parent
                    before = len(state['calls'])
                    env = {**os.environ, 'REPO': str(ROOT), 'TOOL': tool, 'CASE': str(case), 'GUEST_STATUS': 'VERIFIED'}
                    retry = subprocess.run(['bash', '-euo', 'pipefail', '-c', mold.SHELL], env=env,
                                           text=True, capture_output=True, timeout=60)
                    self.assertEqual(retry.returncode, 0, retry.stderr)
                    after = json.loads((case / 'mold.json').read_text())
                    self.assertEqual(set(after['volumes']), set(state['volumes']))
                    self.assertEqual(after['vm'], state['vm'])
                    self.assertFalse({c['api'] for c in after['calls'][before:]} &
                                     {'importVolume', 'deployVirtualMachineForVolume', 'listVolumesForImport', 'startVirtualMachine'})
                    resumed = json.loads((case / 'manifest.json').read_text())['runtime']['cloud']
                    self.assertEqual(resumed['retention']['status'], 'RESOLVED')
                    self.assertTrue(resumed['checkpoint']['complete'])
                    self.assertTrue(resumed['validated'])
                    self.assertEqual(resumed['retention']['events'][0]['exit_code'], code)

    def test_define_only_and_guest_policy_off_never_claim_verified(self):
        for tool in ['v2k', 'n2k']:
            for options in [{'guest_status': 'VERIFIED', 'define_only': True}, {'guest_off': True}]:
                with self.subTest(tool=tool, options=options):
                    r, state, doc = self.fixture.run_cutover(tool, **options)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(state['vm']['state'], 'Stopped' if options.get('define_only') else 'Running')
                    self.assertFalse(doc['runtime']['cloud']['checkpoint']['complete'])
                    self.assertFalse(doc['runtime']['cloud']['validated'])
                    self.assertEqual(doc['runtime']['cloud']['retention']['status'], 'RETAINED_UNVERIFIED')


if __name__ == '__main__':
    unittest.main(verbosity=2)
