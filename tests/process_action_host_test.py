#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
import copy,importlib.util,json,os,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'lib'),str(ROOT/'process-management')]
import process_action_host as host
import action_policy_plain as installer
class Guards(unittest.TestCase):
 def test_standalone_never_dispatches(self):
  r={'kind':'actionRequest','schemaVersion':'1.0','requestId':'x','authority':{}}
  with patch.object(os,'geteuid',return_value=0):self.assertEqual(host.run(r,None)['error']['code'],'PERMISSION_DENIED')
 def test_windows_path_has_no_control_characters(self):
  import ast
  tree=ast.parse((ROOT/'lib/process_action_host.py').read_text())
  paths=[n.value for n in ast.walk(tree) if isinstance(n,ast.Constant) and isinstance(n.value,str) and 'powershell.exe' in n.value]
  self.assertEqual(len(paths),1);self.assertFalse(any(ord(c)<32 for c in paths[0]))
 def test_reservation_symlink_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp)/'context';p.symlink_to('/etc/passwd')
   with self.assertRaises(OSError):host.context({},p)
 def test_install_upgrade_rollback_retains_previous_manifest(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);state=root/'state';target=root/'target';payload=root/'payload'
   for p in (state,target,payload):p.mkdir()
   for name in installer.FILES:(payload/name).write_bytes(b'first')
   with patch.object(installer,'ROOT',state),patch.object(installer,'TARGET',target),patch.object(installer,'ensure_directory'):
    installer.apply(payload);before=(state/'plain-state.json').read_bytes()
    for name in installer.FILES:(payload/name).write_bytes(b'second')
    real=installer.save;failed=False
    def save(path,data,mode=0o600):
     nonlocal failed
     if path.parent==target and not failed:failed=True;raise OSError('disk failure')
     return real(path,data,mode)
    with patch.object(installer,'save',side_effect=save):
     with self.assertRaises(OSError):installer.apply(payload)
    self.assertEqual(before,(state/'plain-state.json').read_bytes())
    for name in installer.FILES:self.assertEqual((target/name).read_bytes(),b'first')
    installer.apply(payload)
    for name in installer.FILES:self.assertEqual((target/name).read_bytes(),b'second')
if __name__=='__main__':unittest.main()
