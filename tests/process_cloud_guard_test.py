#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
import fcntl, os, stat, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
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
if __name__=='__main__':unittest.main()
