# Copyright 2026 ABLECLOUD. Apache-2.0.
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('policy',Path(__file__).resolve().parents[1]/'process-management/read_policy.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.target=self.root/'target';self.state=self.root/'state';self.payload=self.root/'payload'
        for path in (self.target,self.state,self.payload):path.mkdir(mode=0o700)
        self.modules=set();self.mappings={};self.fail=False
        for name in p.FILES:(self.payload/name).write_bytes(('new-'+name).encode())
        (self.payload/(p.MODULE+'.cil')).write_bytes(b'policy')
        self.original=self.target/'process_list_linux.py';self.original.write_bytes(b'original');self.original.chmod(0o640)
        for attribute,value in [('ROOT',self.state),('TARGET',self.target),('run',self.run_command)]:
            mock=patch.object(p,attribute,value);mock.start();self.addCleanup(mock.stop)
    def run_command(self,*args):
        if args==('semodule','-l'):return '\n'.join(self.modules)
        if args[:2]==('semodule','-i'):self.modules.add(p.MODULE)
        if args[:2]==('semodule','-r'):self.modules.discard(p.MODULE)
        if args==('semanage','fcontext','-l','-C'):return '\n'.join(k+' all files system_u:object_r:'+v+':s0' for k,v in self.mappings.items())
        if args[:3]==('semanage','fcontext','-a'):
            if self.fail:self.fail=False;raise RuntimeError('injected failure')
            self.mappings[args[-1]]=args[-2]
        if args[:3]==('semanage','fcontext','-d'):self.mappings.pop(args[-1])
        return ''
    def state_data(self):return json.loads((self.state/'state.json').read_bytes())
    def test_install_idempotency_restore(self):
        self.assertEqual(p.apply(self.payload),'INSTALLED');self.assertEqual(p.apply(self.payload),'UNCHANGED')
        p.restore(self.state_data());self.assertEqual(self.original.read_bytes(),b'original')
        self.assertEqual(self.original.stat().st_mode&0o777,0o640)
        self.assertFalse((self.target/'process-read-launcher').exists());self.assertFalse(self.modules);self.assertFalse(self.mappings)
    def test_failed_install_rolls_back(self):
        self.fail=True
        with self.assertRaisesRegex(RuntimeError,'original collector restored'):p.apply(self.payload)
        self.assertEqual(self.original.read_bytes(),b'original');self.assertFalse(self.modules);self.assertFalse(self.mappings)
        self.assertFalse((self.state/'state.json').exists())
    def test_new_admin_file_not_overwritten(self):
        p.apply(self.payload);self.original.write_bytes(b'admin-edit')
        with self.assertRaisesRegex(RuntimeError,'administrator edit'):p.restore(self.state_data())
        self.assertEqual(self.original.read_bytes(),b'admin-edit');self.assertIn(p.MODULE,self.modules)
    def test_unmanaged_module_rejected(self):
        self.modules.add(p.MODULE)
        with self.assertRaisesRegex(RuntimeError,'unmanaged'):p.apply(self.payload)
        self.assertEqual(self.original.read_bytes(),b'original')
    def test_existing_mapping_rejected(self):
        self.mappings[p.mapping('process-read-launcher')]='admin_t'
        with self.assertRaisesRegex(RuntimeError,'administrator mapping'):p.apply(self.payload)
        self.assertFalse(self.modules)
    def test_symlink_rejected(self):
        self.original.unlink();self.original.symlink_to(self.payload/'process_list_linux.py')
        with self.assertRaisesRegex(RuntimeError,'Unsafe'):p.apply(self.payload)
        self.assertFalse(self.modules)
    def test_updated_payload_retains_original_restore_point(self):
        p.apply(self.payload);(self.payload/'process_list_linux.py').write_bytes(b'updated')
        p.apply(self.payload);self.assertEqual(self.original.read_bytes(),b'updated')
        p.restore(self.state_data());self.assertEqual(self.original.read_bytes(),b'original')
    def test_pending_install_can_restore_original_bytes(self):
        p.apply(self.payload);state=self.state_data();state['phase']='installing';self.original.write_bytes(b'original')
        p.restore(state);self.assertEqual(self.original.read_bytes(),b'original')
    def test_policy_no_mutating_service_or_qga_proc_grants(self):
        policy=(Path(__file__).resolve().parents[1]/'process-management/ablestack_process_read.cil').read_text()
        self.assertNotIn('(service (start',policy);self.assertNotIn('(service (stop',policy)
        self.assertNotIn('(allow virt_qemu_ga_t domain',policy)
        self.assertNotIn('(capability',policy);self.assertNotIn('ptrace',policy)

if __name__=='__main__':unittest.main()
