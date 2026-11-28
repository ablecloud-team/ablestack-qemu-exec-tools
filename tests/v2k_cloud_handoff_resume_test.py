#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""CLI retries must not touch an image after Mold may have taken ownership."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class HandoffResume(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='v2k-sealed-retry-');self.addCleanup(self.tmp.cleanup);self.work=Path(self.tmp.name)
        self.path=self.work/'manifest.json'
        self.document={'source':{'vm':{'name':'fixture','guestFamily':'windowsGuest','cpu':2,'memory_mb':2048}},'target':{'provider':'ablestack-cloud','storage':{'type':'file'}},'disks':[{'transfer':{'cloud_allocation':{'request_id':'stable-request'}}}], 'runtime':{'cloud':{'checkpoint':{'root_volume_id':'root','vm_id':'vm','complete':True}}},'phases':{'init':{'done':True},'base_sync':{'done':True},'final_sync':{'done':True}}}
        self.path.write_text(json.dumps(self.document))
    def shell(self,code,args=()):
        env={**os.environ,'REPO':str(ROOT),'V2K_WORKDIR':str(self.work),'V2K_MANIFEST':str(self.path),'GOVC_USERNAME':'fixture','GOVC_PASSWORD':'fixture-secret','GOVC_URL':'https://source.invalid','BASHRCSOURCED':'1'}
        prefix='export V2K_ROOT_DIR="$REPO" V2K_LIB_DIR="$REPO/lib/v2k"; source "$REPO/lib/v2k/engine.sh"; source "$REPO/lib/v2k/orchestrator.sh"; v2k_event() { :; }; v2k_compat_bootstrap_env() { :; }; v2k_compat_resolve_profile() { :; }; v2k_load_runtime_flags_from_manifest() { :; }; v2k_restore_runtime_env_from_workdir() { :; }; '
        return subprocess.run(['bash','-euo','pipefail','-c',prefix+code,'test',*args],env=env,capture_output=True,text=True)
    def test_low_level_transfers_and_snapshot_stop_before_remote_or_image_work(self):
        commands=['v2k_transfer_base_all "$V2K_MANIFEST" 1','v2k_transfer_base_one "$V2K_MANIFEST" 0 server thumb vm snap /dev/null','v2k_transfer_patch_all "$V2K_MANIFEST" incr 1 65536 4194304','v2k_transfer_patch_one "$V2K_MANIFEST" final 0 server thumb vm snap snap 65536 4194304 /dev/null','v2k_cmd_snapshot incr']
        for command in commands:
            with self.subTest(command=command):
                result=self.shell(command)
                self.assertEqual(result.returncode,44,result.stderr);self.assertIn('CLOUD_TARGET_SEALED',result.stderr)
    def test_import_request_alone_closes_source_writes(self):
        self.document['runtime']['cloud']['checkpoint']={};self.path.write_text(json.dumps(self.document))
        result=self.shell('v2k_transfer_base_all "$V2K_MANIFEST" 1')
        self.assertEqual(result.returncode,44,result.stderr)
    def test_malformed_manifest_does_not_reopen_source_writes(self):
        self.path.write_text('{"runtime":')
        result=self.shell('v2k_transfer_base_all "$V2K_MANIFEST" 1')
        self.assertEqual(result.returncode,44,result.stderr)

    def test_cutover_reconciles_and_marks_done_without_guest_preparation(self):
        code = r"""v2k_vmware_snapshot_create() { echo unsafe-snapshot >&2; return 77; }; v2k_transfer_patch_all() { echo unsafe-write >&2; return 77; }; v2k_cloud_windows_winpe_bootstrap() { echo unsafe-bootstrap >&2; return 77; }; v2k_cloud_target_cutover() { printf '%s' '{"provider":"ablestack-cloud","started":true,"vm_id":"vm"}'; }; v2k_cmd_cutover --start"""
        result=self.shell(code)
        self.assertEqual(result.returncode,0,result.stderr);self.assertNotIn('unsafe-',result.stderr)
        self.assertTrue(json.loads(self.path.read_text())['phases']['cutover']['done'])
    def test_run_skips_incremental_loop_and_source_snapshot_on_reentry(self):
        code = r"""migration_cloud_allocation_check_manifest() { :; }; migration_cloud_allocation_allow_copy() { :; }; v2k_cmd_snapshot() { echo unsafe-snapshot >&2; return 77; }; v2k_cmd_sync() { echo unsafe-sync >&2; return 77; }; v2k_cmd_cleanup() { :; }; v2k_cloud_target_cutover() { printf '%s' '{"provider":"ablestack-cloud","started":true,"vm_id":"vm"}'; }; v2k_cmd_run_foreground --vm fixture --vcenter source.invalid --username fixture --password fixture-secret --split full --kvm-vm-policy define-and-start --keep-workdir"""
        result=self.shell(code)
        self.assertEqual(result.returncode,0,result.stderr);self.assertNotIn('unsafe-',result.stderr)
        self.assertTrue(json.loads(self.path.read_text())['phases']['cutover']['done'])

if __name__=='__main__':unittest.main(verbosity=2)
