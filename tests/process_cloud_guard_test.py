#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
import fcntl, json, os, stat, sys, tempfile, unittest, uuid
from pathlib import Path
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'lib'))
import process_list_host as host
class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.path=Path(self.tmp.name)/'guard'
        self.fd=os.open(self.path,os.O_CREAT|os.O_RDWR,0o600)
        self.old=os.dup(0);self.read,self.write=os.pipe();os.dup2(self.read,0)
        os.dup2(self.fd,9)
    def tearDown(self):
        os.dup2(self.old,0)
        for fd in {self.old,self.read,self.write,self.fd,9}:
            try:os.close(fd)
            except OSError:pass
        self.tmp.cleanup()
    def test_inherited_lock_accepted(self):
        fcntl.flock(self.fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        copy=host.inherited_guard(9,self.path);os.close(copy)
    def test_unlocked_descriptor_denied(self):
        with self.assertRaises(ValueError):host.inherited_guard(9,self.path)
    def test_closed_parent_denied(self):
        fcntl.flock(self.fd,fcntl.LOCK_EX);os.close(self.write)
        with self.assertRaises(ValueError):host.inherited_guard(9,self.path)
    def test_unexpected_parent_input_denied(self):
        os.write(self.write,b'x')
        with self.assertRaises(ValueError):host.parent_alive()
    def test_different_inode_denied(self):
        fcntl.flock(self.fd,fcntl.LOCK_EX);other=self.path.with_name('other');other.touch(mode=0o600)
        with self.assertRaises(ValueError):host.inherited_guard(9,other)
    def test_separate_description_denied(self):
        fcntl.flock(self.fd,fcntl.LOCK_EX);separate=os.open(self.path,os.O_RDWR);os.dup2(separate,9)
        try:
            with self.assertRaises(BlockingIOError):host.inherited_guard(9,self.path)
        finally:os.close(separate)
    def test_permissive_guard_denied(self):
        fcntl.flock(self.fd,fcntl.LOCK_EX);os.chmod(self.path,0o666)
        with self.assertRaises(ValueError):host.inherited_guard(9,self.path)
    def read_lease(self, transport, cloud_guard=None):
        request={'requestId':str(uuid.uuid4()),'authority':{'vmUuid':str(uuid.uuid4())}}
        lease=Path(self.tmp.name)/'lease'
        return lease, lambda: host.execute_with_read_lease(request,transport,'domain',['collector'],{},cloud_guard,lease)
    def test_closed_parent_before_dispatch_removes_marker_without_guest_execution(self):
        transport=Mock();lease,execute=self.read_lease(transport,9)
        with patch.object(host,'parent_alive',side_effect=ValueError('parent closed')):
            with self.assertRaises(ValueError):execute()
        transport.execute.assert_not_called()
        self.assertEqual([],list(lease.iterdir()))
    def test_known_completion_cleans_marker(self):
        for state in ('SUCCEEDED','FAILED'):
            transport=Mock();transport.execute.return_value={'state':state}
            lease,execute=self.read_lease(transport)
            self.assertEqual({'state':state},execute())
            self.assertEqual([],list(lease.iterdir()))
    def test_unknown_completion_retains_guest_pid_and_owner(self):
        transport=Mock();transport.execute.return_value={'state':'UNKNOWN','guest_exec_pid':456}
        lease,execute=self.read_lease(transport);execute()
        record=json.loads(next(lease.iterdir()).read_text())
        self.assertEqual(('UNKNOWN',456,os.getpid()),(record['stage'],record['guestExecPid'],record['ownerPid']))
        self.assertTrue(record['ownerStartTicks'].isdigit())
    def test_dispatch_exception_keeps_uncertain_marker(self):
        transport=Mock();transport.execute.side_effect=OSError('response lost')
        lease,execute=self.read_lease(transport)
        with self.assertRaises(OSError):execute()
        self.assertEqual('DISPATCHING',json.loads(next(lease.iterdir()).read_text())['stage'])
if __name__=='__main__':unittest.main()
