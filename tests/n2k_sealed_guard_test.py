#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
import json,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class SealedGuardTest(unittest.TestCase):
 def exercise(self,via_workdir,pending_request):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'manifest.json';p.write_text(json.dumps({'runtime':{'cloud':{'checkpoint':{} if pending_request else {'vm_id':'already-managed'}}},'disks':[{'transfer':{'cloud_allocation':{'request_id':'pending-import'}}}] if pending_request else []}))
   args=['bash',str(ROOT/'bin/ablestack_n2k.sh'), '--workdir' if via_workdir else '--manifest',d if via_workdir else str(p),'sync','final']
   before=p.read_bytes();out=subprocess.run(args,text=True,capture_output=True);self.assertEqual(out.returncode,44,out.stdout+out.stderr);self.assertIn('CLOUD_TARGET_SEALED',out.stderr);self.assertEqual(p.read_bytes(),before)
 def test_managed_manifest_blocks_sync(self):self.exercise(False,False)
 def test_workdir_only_blocks_sync_after_manifest_resolution(self):self.exercise(True,False)
 def test_pending_import_uuid_blocks_sync(self):self.exercise(False,True)
 def test_workdir_pending_import_blocks_sync(self):self.exercise(True,True)
if __name__=='__main__':unittest.main()
