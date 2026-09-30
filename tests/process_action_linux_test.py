#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
import copy,errno,importlib.util,json,os,signal,subprocess,tempfile,time,unittest,uuid
from pathlib import Path
from unittest.mock import patch
path=Path(__file__).resolve().parents[1]/'lib/process/process_action_linux.py'
spec=importlib.util.spec_from_file_location('action',path);a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
class Actions(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.children=[]
 def tearDown(self):
  for p in self.children:
   if p.poll() is None:p.kill()
   p.wait()
   if p.stdout:p.stdout.close()
  self.tmp.cleanup()
 def child(self,ignore=False):
  p=subprocess.Popen(['/usr/bin/python3','-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print("ready",flush=True);time.sleep(60)'],stdout=subprocess.PIPE) if ignore else subprocess.Popen(['/usr/bin/sleep','60'])
  self.children.append(p)
  if ignore:p.stdout.readline()
  else:time.sleep(.02)
  return p
 def request(self,p,action='process.kill',budget=1000):
  return {'schemaVersion':'1.0','kind':'actionRequest','requestId':str(uuid.uuid4()),'authority':{'vmUuid':'11111111-1111-4111-8111-111111111111','hostUuid':'22222222-2222-4222-8222-222222222222','placementGeneration':'42'},'operationId':str(uuid.uuid4()),'action':action,'identity':{'vmUuid':'11111111-1111-4111-8111-111111111111','bootId':a.boot(),'pid':p.pid,'startTicks':a.identity(p.pid)[1]},'snapshotId':str(uuid.uuid4()),'observedAt':a.stamp(),'service':None,'budgetMs':budget}
 def test_kill_verified_and_duplicate_does_not_signal(self):
  p=self.child();r=self.request(p);first=a.run(r,self.root);self.assertEqual(first['state'],'SUCCEEDED');p.wait()
  with patch.object(a.signal,'pidfd_send_signal',side_effect=AssertionError('replayed')):self.assertEqual(a.run(r,self.root),first)
 def test_normal_term(self):
  p=self.child();self.assertEqual(a.run(self.request(p,'process.terminate'),self.root)['postcondition'],'TARGET_EXITED')
 def test_legacy_proc_pidfd_term_and_kill_are_verified(self):
  for action in ('process.terminate','process.kill'):
   p=self.child();r=self.request(p,action)
   with patch.object(a.os,'pidfd_open',side_effect=OSError(errno.ENOSYS,'not backported')):
    value=a.run(r,self.root)
   self.assertEqual('SUCCEEDED',value['state']);p.wait()
 def test_legacy_proc_pidfd_rejects_stale_ticks_without_dispatch(self):
  p=self.child();r=self.request(p);r['identity']['startTicks']='1';real=a.signal.pidfd_send_signal;sent=[]
  def send(fd,sig,*args):
   sent.append(sig);return real(fd,sig,*args)
  with patch.object(a.os,'pidfd_open',side_effect=OSError(errno.ENOSYS,'not backported')),patch.object(a.signal,'pidfd_send_signal',side_effect=send):
   self.assertEqual('STALE_IDENTITY',a.run(r,self.root)['error']['code'])
  self.assertEqual([0],sent);self.assertIsNone(p.poll())
 def test_legacy_descriptor_does_not_follow_numeric_pid_reuse(self):
  p=self.child()
  with patch.object(a.os,'pidfd_open',side_effect=OSError(errno.ENOSYS,'not backported')):fd,pollable=a.open_target(p.pid)
  try:
   p.kill();p.wait()
   # A missing pinned task is exited even if a numeric-PID reader claims a live replacement.
   with patch.object(a,'identity',return_value=('replacement','999',1,'S')):
    self.assertTrue(a.target_exited(fd,pollable))
   with self.assertRaises(ProcessLookupError):a.signal.pidfd_send_signal(fd,signal.SIGTERM)
  finally:os.close(fd)
 def test_permission_denied_does_not_trigger_legacy_fallback(self):
  with patch.object(a.os,'pidfd_open',side_effect=PermissionError),patch.object(a.os,'open',side_effect=AssertionError('unsafe fallback')):
   with self.assertRaises(PermissionError):a.open_target(42)
 def test_kernel_without_pidfd_signal_fails_closed(self):
  p=self.child();r=self.request(p)
  with patch.object(a.os,'pidfd_open',side_effect=OSError(errno.ENOSYS,'missing')),patch.object(a.signal,'pidfd_send_signal',side_effect=OSError(errno.ENOSYS,'missing')):
   value=a.run(r,self.root)
  self.assertEqual('UNSUPPORTED_ACTION',value['error']['code']);self.assertIsNone(p.poll())
 def test_proc_exe_readlink_is_not_required(self):
  p=self.child();r=self.request(p)
  with patch.object(a.Path,'resolve',side_effect=PermissionError('ptrace denied')):
   self.assertEqual(a.run(r,self.root)['state'],'SUCCEEDED')
 def test_protected_process_name_still_blocks_signal(self):
  p=self.child();r=self.request(p);original=a.identity
  def protected(pid):
   value=original(pid)
   return ('qemu-ga',*value[1:]) if pid==p.pid else value
  with patch.object(a,'identity',side_effect=protected):
   self.assertEqual(a.run(r,self.root)['error']['code'],'PROTECTED_TARGET')
  self.assertIsNone(p.poll())
 def test_pre_dispatch_access_denial_is_not_stale_identity(self):
  p=self.child();r=self.request(p)
  with patch.object(a,'identity',side_effect=PermissionError('proc denied')):
   value=a.run(r,self.root)
  self.assertEqual(value['error']['code'],'PERMISSION_DENIED')
  self.assertIsNone(p.poll())
 def test_exited_process_is_stale_identity(self):
  p=self.child();r=self.request(p);p.terminate();p.wait()
  self.assertEqual(a.run(r,self.root)['error']['code'],'STALE_IDENTITY')
 def test_stale_ticks_never_signal(self):
  p=self.child();r=self.request(p);r['identity']['startTicks']='1';self.assertEqual(a.run(r,self.root)['error']['code'],'STALE_IDENTITY');self.assertIsNone(p.poll())
 def test_protected_pid_one(self):
  p=self.child();r=self.request(p);r['identity']['pid']=1;self.assertEqual(a.run(r,self.root)['error']['code'],'PROTECTED_TARGET')
 def test_boot_change(self):
  p=self.child();r=self.request(p);r['identity']['bootId']='linux:'+str(uuid.uuid4());self.assertEqual(a.run(r,self.root)['state'],'FAILED');self.assertIsNone(p.poll())
 def test_request_conflict(self):
  p=self.child();r=self.request(p);a.run(r,self.root);r['action']='process.terminate';self.assertEqual(a.run(r,self.root)['error']['code'],'REQUEST_CONFLICT')
 def test_duplicate_request_different_operation_rejected(self):
  p=self.child();r=self.request(p);a.run(r,self.root);r['operationId']=str(uuid.uuid4());self.assertEqual(a.run(r,self.root)['error']['code'],'REQUEST_CONFLICT')
 def test_unknown_blocks_then_read_only_reconcile(self):
  p=self.child(True);r=self.request(p,'process.terminate',150);value=a.run(r,self.root);self.assertEqual(value['state'],'UNKNOWN');self.assertIsNone(p.poll())
  other=self.request(self.child());self.assertEqual(a.run(other,self.root)['error']['code'],'BUSY')
  p.kill();p.wait();query={k:r[k] for k in ('schemaVersion','requestId','authority','operationId','budgetMs')};query.update(kind='readRequest',operation='operation.get')
  with patch.object(a.signal,'pidfd_send_signal',side_effect=AssertionError('replayed')):self.assertEqual(a.run(query,self.root)['state'],'SUCCEEDED')
 def test_crash_window_not_replayed(self):
  p=self.child();r=self.request(p)
  with patch.object(a.signal,'pidfd_send_signal',side_effect=OSError('lost')):self.assertEqual(a.run(r,self.root)['state'],'UNKNOWN')
  with patch.object(a.signal,'pidfd_send_signal',side_effect=AssertionError('replayed')):self.assertEqual(a.run(r,self.root)['state'],'UNKNOWN')
  self.assertIsNone(p.poll())
 def test_epoch_and_binding(self):
  p=self.child();r=self.request(p);a.run(r,self.root);r['authority']['placementGeneration']='41';self.assertEqual(a.run(r,self.root)['error']['code'],'STALE_AUTHORITY')
 def test_symlink_journal_denied(self):
  (self.root/'journal.json').symlink_to('/etc/passwd')
  with self.assertRaises(OSError):a.run(self.request(self.child()),self.root)
 def test_guest_clock_is_not_snapshot_authority(self):
  r=self.request(self.child());r['observedAt']='2000-01-01T00:00:00Z';self.assertEqual(a.run(r,self.root)['state'],'SUCCEEDED')
 def test_strict_input(self):
  with self.assertRaises(ValueError):a.strict('{"a":1,"a":2}')
  r=self.request(self.child());r['identity']['startTicks']=123
  with self.assertRaises(ValueError):a.validate(r)
 def test_lost_response_reopen_journal_does_not_dispatch(self):
  p=self.child();r=self.request(p);a.run(r,self.root)
  reopened=importlib.util.module_from_spec(spec);spec.loader.exec_module(reopened)
  with patch.object(reopened.signal,'pidfd_send_signal',side_effect=AssertionError('replayed')):self.assertEqual(reopened.run(r,self.root)['state'],'SUCCEEDED')
 def test_reboot_cannot_reconcile_unknown(self):
  p=self.child(True);r=self.request(p,'process.terminate',100);self.assertEqual(a.run(r,self.root)['state'],'UNKNOWN');p.kill();p.wait()
  q={k:r[k] for k in ('schemaVersion','requestId','authority','operationId','budgetMs')};q.update(kind='readRequest',operation='operation.get')
  with patch.object(a,'boot',return_value='linux:'+str(uuid.uuid4())):self.assertEqual(a.run(q,self.root)['state'],'UNKNOWN')
 def test_query_persists_new_epoch(self):
  p=self.child();r=self.request(p);a.run(r,self.root)
  q={k:copy.deepcopy(r[k]) for k in ('schemaVersion','requestId','authority','operationId','budgetMs')};q.update(kind='readRequest',operation='operation.get');q['authority']['placementGeneration']='43';a.run(q,self.root)
  self.assertEqual(a.run(r,self.root)['error']['code'],'STALE_AUTHORITY')
 def test_service_transient_rejected_before_control(self):
  p=self.child();r=self.request(p,'service.restart');r['service']={'manager':'systemd','name':'fixture.service','configurationHash':'0'*64}
  props={'Id':'fixture.service','MainPID':str(p.pid),'Transient':'yes'}
  with patch.object(a,'props',return_value=props),patch.object(a,'config_hash',return_value='0'*64):self.assertEqual(a.run(r,self.root)['error']['code'],'UNSUPPORTED_ACTION')
 def test_unknown_operation_is_not_execution_proof(self):
  r=self.request(self.child());q={k:r[k] for k in ('schemaVersion','requestId','authority','operationId','budgetMs')};q.update(kind='readRequest',operation='operation.get');self.assertEqual(a.run(q,self.root)['error']['code'],'NOT_FOUND')
if __name__=='__main__':unittest.main()
