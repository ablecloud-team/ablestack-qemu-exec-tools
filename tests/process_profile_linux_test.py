#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
import importlib.util,json,os,subprocess,tempfile,unittest,uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
def module(name):
 spec=importlib.util.spec_from_file_location(name,ROOT/'lib/process'/ (name+'.py'));value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
p=module('process_profile_linux');a=module('process_action_linux');p.ACTION=a
class Profiles(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(dir='/var/lib',prefix='able-profile-test-');self.base=Path(self.temp.name);self.directory=self.base/'profiles';self.directory.mkdir(mode=0o700)
  self.children=[];self.id=str(uuid.uuid4());self.vm=str(uuid.uuid4());self.argv=[str(20000+os.getpid())]
  child=self.child();self.binding=dict(vmUuid=self.vm,bootId=a.boot(),pid=child.pid,startTicks=a.identity(child.pid)[1])
  self.unit=b'[Service]\nType=simple\n';self.definition=dict(schemaVersion='1.0',id=self.id,version=1,vmUuid=self.vm,displayName='fixture',executable='/usr/bin/sleep',executableHash=p.digest(Path('/usr/bin/sleep').read_bytes()),argv=self.argv,cwd='/var/lib',account='root',environmentRef=None,supervisor=dict(manager='systemd',name='ableprofile-'+self.id+'.service',configurationHash=p.digest(self.unit),effectiveHash=p.effective({})),verification='identity-and-running')
  a.save(self.directory/(self.id+'.json'),self.definition);a.save(self.base/('profile-'+self.id+'.binding.json'),self.binding)
  self.patchers=[patch.object(a,'props',return_value={}),patch.object(p,'BASE',self.base),patch.object(p,'PROFILES',self.directory)]
  regular=p.regular
  self.patchers.append(patch.object(p,'regular',side_effect=lambda path,*args:self.unit if str(path).startswith('/etc/systemd/system/ableprofile-') else regular(path,*args)))
  for patcher in self.patchers:patcher.start()
  self.request=dict(schemaVersion='1.1',kind='actionRequest',requestId=str(uuid.uuid4()),operationId=str(uuid.uuid4()),snapshotId=str(uuid.uuid4()),authority=dict(vmUuid=self.vm,hostUuid=str(uuid.uuid4()),placementGeneration='1'),identity=self.binding,observedAt=a.stamp(),service=None,budgetMs=5000,action='process.restart',profile=dict(id=self.id,version=1,definitionHash=p.digest((self.directory/(self.id+'.json')).read_bytes())))
 def child(self):
  child=subprocess.Popen(['/usr/bin/sleep',*self.argv]);self.children.append(child);return child
 def tearDown(self):
  for patcher in reversed(self.patchers):patcher.stop()
  for child in self.children:
   if child.poll() is None:child.kill()
   child.wait()
  self.temp.cleanup()
 def test_registered_identity_metadata_omits_argument_values(self):
  value=p.list_profiles(self.request);self.assertEqual(value['profiles'][0]['identity'],self.binding);self.assertNotIn('argv',value['profiles'][0]);self.assertEqual(value['profiles'][0]['argumentCount'],1)
 def test_unregistered_scope_and_definition_changes_never_signal(self):
  for field,value in [('id',str(uuid.uuid4())),('version',2),('definitionHash','0'*64)]:
   with self.subTest(field=field):
    request=json.loads(json.dumps(self.request));request['profile'][field]=value
    with patch.object(a.signal,'pidfd_send_signal',side_effect=AssertionError('mutation')):
     with self.assertRaises((ValueError,OSError,a.Rejected)):p.checked(request)
 def test_cross_vm_profile_rejected(self):
  with self.assertRaises(ValueError):p.load(self.id,str(uuid.uuid4()))
 def test_symlink_binding_and_writable_definition_rejected(self):
  path=p.paths(self.id)[1];path.unlink();path.symlink_to('/etc/passwd')
  with self.assertRaises((ValueError,OSError)):p.load(self.id,self.vm)
  path.unlink();a.save(path,self.binding);os.chmod(p.paths(self.id)[0],0o666)
  with self.assertRaises(ValueError):p.load(self.id,self.vm)
 def test_duplicate_process_rejected_before_signal(self):
  self.child()
  with self.assertRaises(a.Rejected):p.checked(self.request)
 def execute(self,fail=False):
  record={'stage':'reserved','result':a.result(self.request)};writes=[];new=[None]
  def props(*args):return {'ActiveState':'inactive','MainPID':'0'} if new[0] is None else {'ActiveState':'active','MainPID':str(new[0].pid),'InvocationID':'new'}
  def control(*args,**kw):
   if not fail:new[0]=self.child()
   return SimpleNamespace(returncode=1 if fail else 0)
  with patch.object(a,'props',side_effect=props),patch.object(p.subprocess,'run',side_effect=control):p.run(self.request,record,lambda:writes.append(json.loads(json.dumps(record))),__import__('time').monotonic()+5)
  return record,writes,new[0]
 def test_actual_old_exit_new_identity_and_stable_binding(self):
  record,writes,new=self.execute();self.assertEqual(record['result']['state'],'SUCCEEDED');self.assertEqual(record['result']['progress']['oldProcess'],'EXITED');self.assertNotEqual(record['result']['progress']['newIdentity']['pid'],self.binding['pid']);self.assertIsNotNone(self.children[0].poll());self.assertIsNone(new.poll());self.assertEqual(p.load(self.id,self.vm)[1],record['result']['progress']['newIdentity']);self.assertTrue(any(w['stage']=='profile-start-intent' for w in writes))
 def test_start_failure_is_terminal_partial_with_old_exit(self):
  record,_,_=self.execute(True);self.assertEqual(record['result']['state'],'PARTIAL');self.assertEqual(record['result']['effect'],'PARTIAL');self.assertEqual(record['result']['progress'],dict(oldProcess='EXITED',newProcess='NOT_RUNNING',newIdentity=None));self.assertIsNotNone(self.children[0].poll())
 def test_stopped_crash_recovers_partial_without_start(self):
  self.children[0].terminate();self.children[0].wait();record={'stage':'profile-stopped','result':a.result(self.request)}
  with patch.object(p.subprocess,'run',side_effect=AssertionError('replay')):self.assertEqual(p.reconcile(record,lambda:None)['state'],'PARTIAL')
 def test_old_protocol_rejects_profile_action(self):
  self.request['schemaVersion']='1.0'
  with self.assertRaises(ValueError):a.validate(self.request)
if __name__=='__main__':unittest.main()
