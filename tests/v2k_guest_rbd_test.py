#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""KRBD preparation must fail closed before touching an unowned or managed image."""
import copy
import json
import sys
import tempfile
import unittest
import subprocess
import os
import shlex
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib/v2k'))
import guest_configuration_rbd as rbd
import guest_configuration_prepare as prep
import controller_policy


class RbdPreparation(unittest.TestCase):
    def setUp(self):
        self.m = {'run': {'run_id': 'job'}, 'source': {'vm': {'uuid': 'source'}},
                  'target': {'provider': 'ablestack-cloud', 'format': 'raw', 'storage': {'type': 'rbd', 'rbd_access_mode': 'krbd'}},
                  'disks': [{'disk_id': 'disk', 'size_bytes': 1048576, 'transfer': {'target_path': 'rbd:rbd/owned', 'base_done': True}}]}
        self.receipt = {'version': 1, 'run_id': 'job', 'source_vm_uuid': 'source', 'source_disk_id': 'disk',
                        'uri': 'rbd:rbd/owned', 'image_id': 'image', 'size_bytes': 1048576, 'scope': 'pre-handoff-only'}
        self.m['disks'][0]['transfer']['rbd_image'] = copy.deepcopy(self.receipt)

    def cli(self, *args):
        if args[0] == 'info': return json.dumps({'id': 'image', 'size': 1048576})
        if args[:2] == ('image-meta', 'get'): return json.dumps(self.receipt)
        raise AssertionError('Unexpected metadata command '+str(args))

    def test_image_id_size_and_owner_are_not_inferred_from_name(self):
        with patch.object(rbd, 'rbd', side_effect=self.cli):
            self.assertEqual(rbd.verify_identity(self.m, 0), self.receipt)
            for field, value in [('image_id', 'other'), ('run_id', 'other'), ('uri', 'rbd:rbd/other')]:
                m = copy.deepcopy(self.m); m['disks'][0]['transfer']['rbd_image'][field] = value
                with self.assertRaisesRegex(ValueError, 'OWNERSHIP_CONFLICT'): rbd.verify_identity(m, 0)

    def test_missing_receipt_and_incomplete_copy_cannot_open_disk(self):
        for transfer in [{'target_path': 'rbd:rbd/owned', 'base_done': True}, {'target_path': 'rbd:rbd/owned', 'rbd_image': self.receipt}]:
            m=copy.deepcopy(self.m);m['disks'][0]['transfer']=transfer
            with patch.object(rbd, 'rbd') as command:
                with self.assertRaisesRegex(ValueError, 'OWNERSHIP_REQUIRED'): rbd.verify_identity(m,0)
                command.assert_not_called()

    def test_handoff_seal_precedes_even_readonly_image_access(self):
        for checkpoint in [{'root_volume_id':'root'}, {'root_import_job_id':'pending'}, {'deploy_job_id':'pending'}, {'vm_id':'vm'}, {'data_volumes':{'1':{'id':'data'}}}]:
            m=copy.deepcopy(self.m);m['runtime']={'cloud':{'checkpoint':checkpoint}}
            with patch.object(rbd,'rbd') as command:
                with self.assertRaisesRegex(ValueError,'CLOUD_TARGET_SEALED'):rbd.identity(m,0)
                command.assert_not_called()

    def test_rbd_uri_cannot_embed_credentials_options_or_snapshot(self):
        for uri in ['rbd:rbd/image:conf=/etc/x','rbd:rbd/image@snap','rbd:rbd/ns/image','rbd:../image','rbd:rbd/image;rm']:
            with self.assertRaises(ValueError):rbd.spec(uri)

    def test_preflight_preserves_krbd_constraint_and_file_scope(self):
        with patch.object(prep.shutil,'which',return_value='/tool'):
            m=copy.deepcopy(self.m);m['target']['storage']['rbd_access_mode']='librbd'
            with self.assertRaisesRegex(ValueError,'ACCESS_MODE_UNSUPPORTED'):prep.preflight(m)
            m=copy.deepcopy(self.m);m['target']['storage']['type']='file'
            with self.assertRaisesRegex(ValueError,'TARGET_UNSUPPORTED'):prep.preflight(m)
            m=copy.deepcopy(self.m);m['disks'].append(copy.deepcopy(m['disks'][0]))
            with self.assertRaisesRegex(ValueError,'DUPLICATE_IMAGE'):prep.preflight(m)

    def test_flush_failure_still_releases_only_owned_mapping(self):
        mapping=rbd.Mapping(self.m,0,readonly=False);mapping.device='/dev/rbd42'
        with patch.object(rbd.subprocess,'run',side_effect=subprocess.CalledProcessError(1,'blockdev')), patch.object(rbd,'rbd') as command:
            with self.assertRaises(subprocess.CalledProcessError):mapping.__exit__()
            command.assert_called_once_with('unmap','/dev/rbd42')
            self.assertIsNone(mapping.device)

    def test_temporary_busy_unmap_retries_without_force(self):
        mapping=rbd.Mapping(self.m,0);mapping.device='/dev/rbd42'
        with patch.object(rbd,'rbd',side_effect=[ValueError('busy'),'']) as command, patch.object(rbd.time,'sleep'):
            mapping.__exit__()
            self.assertEqual(command.call_args_list,[unittest.mock.call('unmap','/dev/rbd42')]*2)
            self.assertIsNone(mapping.device)

    def test_old_frozen_plan_keeps_hash_but_new_plan_binds_krbd(self):
        m=copy.deepcopy(self.m)
        m['disks'][0].update(device_key='1',controller={'kind':'ide','bus':0,'unit':0})
        m=controller_policy.prepare(m)
        self.assertEqual(m['target']['disk_controller_plan']['rbd_access_mode'],'krbd')
        changed=copy.deepcopy(m);changed['target']['storage']['rbd_access_mode']='librbd'
        with self.assertRaisesRegex(ValueError,'frozen'):controller_policy.verify(changed)
        legacy=copy.deepcopy(m);plan=legacy['target']['disk_controller_plan']
        del plan['rbd_access_mode'];del plan['hash'];plan['hash']=controller_policy.digest(plan)
        self.assertEqual(controller_policy.verify(legacy),plan)

    def test_winpe_cannot_adopt_a_preexisting_mapping(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'manifest.json';path.write_text(json.dumps(self.m))
            with patch.object(rbd,'rbd',side_effect=self.cli), patch.object(rbd.Mapping,'_matching_mappings',return_value=[{'device':'/dev/rbd42'}]):
                with self.assertRaisesRegex(ValueError,'IMAGE_BUSY'):rbd.winpe_mappings(path,'winpe-idle')

    def test_winpe_releases_only_recorded_matching_image_id(self):
        m=copy.deepcopy(self.m);m['runtime']={'winpe_krbd_mappings':[{'index':0,'image':self.receipt,'device':'/dev/rbd42'}]}
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'manifest.json';path.write_text(json.dumps(m));read=Path.read_text
            def text(p,*args,**kwargs):
                return 'replaced' if str(p).startswith('/sys/bus/rbd/') else read(p,*args,**kwargs)
            with patch.object(rbd,'rbd',side_effect=self.cli) as command, patch.object(rbd.Mapping,'_matching_mappings',return_value=[{'device':'/dev/rbd42'}]), patch.object(Path,'read_text',text):
                with self.assertRaisesRegex(ValueError,'IDENTITY_MISMATCH'):rbd.winpe_mappings(path,'winpe-release')
                self.assertFalse(any(c.args[0]=='unmap' for c in command.call_args_list))

    def test_real_shell_stage_requires_mold_unmanaged_visibility_before_preparation(self):
        repo=Path(__file__).resolve().parents[1]
        for tool in ['v2k','n2k']:
            for scenario in ['visible','missing','pending-import']:
                with self.subTest(tool=tool,scenario=scenario), tempfile.TemporaryDirectory() as directory:
                    work=Path(directory);m=copy.deepcopy(self.m)
                    m['target'].update(guest_config_policy='preserve',cloud={'endpoint':'http://fixture','storage_id':'pool'})
                    m['target']['storage']['preallocation']='not_applicable'
                    if scenario=='pending-import':m['runtime']={'cloud':{'checkpoint':{'root_import_job_id':'pending'}}}
                    manifest=work/'manifest.json';manifest.write_text(json.dumps(m));calls=work/'calls'
                    lib=repo/'lib'/tool
                    script=f'''set -euo pipefail
export {tool.upper()}_LIB_DIR={shlex.quote(str(lib))}
source {shlex.quote(str(lib/'cloudstack_api.sh'))}
source {shlex.quote(str(lib/'cloud_handoff.sh'))}
source {shlex.quote(str(lib/'target_cloud.sh'))}
source {shlex.quote(str(lib/'guest_configuration.sh'))}
{tool}_cloud_api_get() {{
  echo api >> {shlex.quote(str(calls))}
  [[ "$4" == listVolumesForImport ]]
  if [[ "$SCENARIO" == visible ]]; then
    printf '%s' '{{"listvolumesforimportresponse":{{"volumeforimport":[{{"fullpath":"rbd/owned","format":"raw"}}]}}}}'
  else printf '%s' '{{"listvolumesforimportresponse":{{"volumeforimport":[]}}}}';fi
}}
{tool}_guest_config_python() {{ echo "python $1 $2" >> {shlex.quote(str(calls))}; }}
{tool}_guest_config_stage {shlex.quote(str(manifest))}
'''
                    result=subprocess.run(['bash','-c',script],capture_output=True,text=True,env={**os.environ,'SCENARIO':scenario,'CLOUDSTACK_API_KEY':'fixture-key','CLOUDSTACK_SECRET_KEY':'fixture-secret'})
                    observed=calls.read_text().splitlines() if calls.exists() else []
                    if scenario=='visible':
                        self.assertEqual(result.returncode,0,result.stderr)
                        self.assertEqual(observed,['api','python guest_configuration_prepare.py prepare','python guest_configuration_rbd.py verify'])
                    else:
                        self.assertEqual(result.returncode,44,result.stderr)
                        self.assertFalse(any(x.startswith('python') for x in observed))
                        if scenario=='pending-import':self.assertEqual(observed,[])


if __name__=='__main__':unittest.main(verbosity=2)
