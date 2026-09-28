# Copyright 2026 ABLECLOUD. Apache-2.0.
import copy
import importlib.util
import json
import os
import types
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path); value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
guest=module('guest',ROOT/'lib/process/process_list_linux.py')
host=module('host',ROOT/'lib/process_list_host.py')
REQUEST={'schemaVersion':'1.0','kind':'readRequest','requestId':'33333333-3333-4333-8333-333333333333','authority':{'vmUuid':'11111111-1111-4111-8111-111111111111','hostUuid':'22222222-2222-4222-8222-222222222222','placementGeneration':'3'},'operation':'process.list','operationId':None,'budgetMs':3000}
BOOT='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'

def proc_stat(pid=42,ticks='9007199254740993',name='worker (한글)',cpu_ticks=0):
    fields=['S','1']+['0']*17+[ticks,'0','5']
    fields[11]=str(cpu_ticks)
    return str(pid)+' ('+name+') '+' '.join(fields)

class CollectorTests(unittest.TestCase):
    def fixture(self,path):
        (path/'sys/kernel/random').mkdir(parents=True)
        (path/'sys/kernel/random/boot_id').write_text(BOOT)
        (path/'42').mkdir(); (path/'42/stat').write_text(proc_stat())
    def test_service_hash_ignores_runtime_but_tracks_command(self):
        first={'ExecStart':'{ path=/usr/bin/app ; argv[]=/usr/bin/app --flag ; ignore_errors=no ; start_time=[a] ; stop_time=[n/a] ; pid=42 ; code=(null) ; status=0/0 }'}
        second={'ExecStart':first['ExecStart'].replace('[a]','[b]').replace('pid=42','pid=99')}
        self.assertEqual(guest.service_configuration(first),guest.service_configuration(second))
        second['ExecStart']=second['ExecStart'].replace('--flag','--changed')
        self.assertNotEqual(guest.service_configuration(first),guest.service_configuration(second))
    def test_denied_service_query_retains_rows_as_partial(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path)
            with patch.object(guest,'service_map',side_effect=PermissionError):value=guest.collect(REQUEST,path)
            self.assertEqual(value['status'],'PARTIAL');self.assertEqual(len(value['processes']),1)
            self.assertEqual(value['processes'][0]['services'],[])
    def test_large_population_stops_at_wire_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path)
            for pid in range(43,3043):
                (path/str(pid)).mkdir();(path/str(pid)/'stat').write_text(proc_stat(pid=pid,name='한글'*80))
            value=guest.collect(REQUEST,path,{})
            self.assertEqual(value['status'],'PARTIAL');self.assertTrue(value['truncated'])
            self.assertLessEqual(len(guest.compact(value).encode()),1048576)
            host.validate_snapshot(value,REQUEST)
    def test_stat_name_and_lossless_ticks(self):
        row=guest.stat_record(proc_stat())
        self.assertEqual(row[1],'worker (한글)');self.assertEqual(row[4],'9007199254740993');self.assertEqual(row[5],5)
    def test_snapshot_identity_privacy_and_service_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path)
            services={42:[{'manager':'systemd','name':'worker.service','configurationHash':'a'*64}]}
            value=guest.collect(REQUEST,path,services)
            self.assertEqual(value['status'],'OK');self.assertEqual(value['totalKnown'],1)
            row=value['processes'][0];self.assertEqual(row['allowedActions'],[]);self.assertEqual(row['cpuPercent'],0.0)
            self.assertEqual(row['services'],services[42]);self.assertNotIn('commandLine',row)
            host.validate_snapshot(value,REQUEST)
    def test_cpu_delta_uses_same_pid_start_and_elapsed_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path);original=Path.read_bytes;reads=[]
            def read(p,*a,**kw):
                if p.name=='stat':
                    reads.append(1)
                    return proc_stat(cpu_ticks=0 if len(reads)==1 else 20).encode()
                return original(p,*a,**kw)
            with patch.object(Path,'read_bytes',read): value=guest.collect(REQUEST,path,{})
            cpu=value['processes'][0]['cpuPercent']
            self.assertIsNotNone(cpu);self.assertGreater(cpu,0)
            host.validate_snapshot(value,REQUEST)

    def test_first_missing_cpu_sample_is_null(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path);original=Path.read_bytes;reads=[]
            def read(p,*a,**kw):
                if p.name=='stat':
                    reads.append(1)
                    if len(reads)==1: raise FileNotFoundError()
                return original(p,*a,**kw)
            with patch.object(Path,'read_bytes',read): value=guest.collect(REQUEST,path,{})
            self.assertIsNone(value['processes'][0]['cpuPercent'])
            host.validate_snapshot(value,REQUEST)

    def test_host_cpu_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path);value=guest.collect(REQUEST,path,{})
            for cpu in (None,0,0.0,1.25,250.5):
                good=copy.deepcopy(value);good['processes'][0]['cpuPercent']=cpu
                host.validate_snapshot(good,REQUEST)
            for cpu in (True,False,-0.1,float('nan'),float('inf'),'1.25',[],{}):
                bad=copy.deepcopy(value);bad['processes'][0]['cpuPercent']=cpu
                with self.assertRaises(ValueError):host.validate_snapshot(bad,REQUEST)

    def test_vanished_or_denied_process_is_partial(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path);(path/'43').mkdir()
            value=guest.collect(REQUEST,path,{})
            self.assertEqual(value['status'],'PARTIAL');self.assertIsNone(value['totalKnown']);self.assertEqual(len(value['processes']),1)
    def test_reused_pid_excluded(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path);original=Path.read_bytes;reads=[]
            def read(p,*a,**kw):
                if p.name=='stat': reads.append(1);return proc_stat(ticks=str(len(reads))).encode()
                return original(p,*a,**kw)
            with patch.object(Path,'read_bytes',read): value=guest.collect(REQUEST,path,{})
            self.assertEqual(value['processes'],[]);self.assertEqual(value['status'],'PARTIAL')
    def test_output_bound_preserves_complete_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path)
            value=guest.collect(REQUEST,path,{},max_wire=1100)
            self.assertTrue(value['truncated']);self.assertEqual(value['status'],'PARTIAL')
            self.assertLess(len(guest.compact(value).encode()),1100);json.loads(guest.compact(value))
    def test_row_limit(self):
        value=guest.new_snapshot(REQUEST,'linux:'+BOOT);size=0
        with patch.object(guest,'MAX_ROWS',2):
            for n in range(3): size,fits=guest.add_row(value,{'pid':n},size)
        self.assertFalse(fits);self.assertEqual(len(value['processes']),2);self.assertTrue(value['truncated'])
    def test_reject_extra_fields_and_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path);value=guest.collect(REQUEST,path,{})
            for key,data in [('allowedActions',['process.kill']),('commandLine','secret')]:
                bad=copy.deepcopy(value);bad['processes'][0][key]=data
                with self.assertRaises(ValueError):host.validate_snapshot(bad,REQUEST)
    def test_reject_wrong_vm_and_duplicate_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);self.fixture(path);value=guest.collect(REQUEST,path,{})
            bad=copy.deepcopy(value);bad['processes']*=2
            with self.assertRaises(ValueError):host.validate_snapshot(bad,REQUEST)
            bad=copy.deepcopy(value);bad['processes'][0]['identity']['vmUuid']=BOOT
            with self.assertRaises(ValueError):host.validate_snapshot(bad,REQUEST)

@unittest.skipUnless(os.geteuid()==0,'root guard ownership tests')
class HostGuardTests(unittest.TestCase):
    def transport(self,state='UNKNOWN'):
        class Admission:
            def __enter__(self):self.fd=1;return self
            def __exit__(self,*_):pass
        class Error(Exception):pass
        def bounded(argv,*_):
            op=argv[3]
            return {'list':REQUEST['authority']['vmUuid']+' vm-name','domuuid':REQUEST['authority']['vmUuid'],'domstate':'running','domjobinfo':'Job type: None','qemu-monitor-command':'{"return":[]}' }[op].encode()
        return types.SimpleNamespace(bounded_process=bounded,Admission=Admission,ExecError=Error,strict_json=json.loads,dumps=json.dumps,rpc=lambda *a:{'id':'ubuntu','version-id':'26.04','machine':'x86_64'},execute=lambda *a:{'state':state,'guest_exec_pid':321,'exit_code':2,'encoding_loss':False,'out_truncated':False})
    def test_unknown_preserves_lease_and_blocks_next_read(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(host,'RUNTIME_ROOT',Path(tmp)):
            result=host.run(REQUEST,self.transport())
            self.assertEqual(result['error']['code'],'CHECK_FAILED')
            leases=list((Path(tmp)/REQUEST['authority']['vmUuid']).iterdir())
            self.assertEqual(len(leases),1);self.assertEqual(json.loads(leases[0].read_text())['guestExecPid'],321)
            self.assertEqual(host.run(REQUEST,self.transport())['error']['code'],'BUSY')
    def test_known_failure_releases_lease(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(host,'RUNTIME_ROOT',Path(tmp)):
            result=host.run(REQUEST,self.transport('FAILED'))
            self.assertEqual(result['error']['code'],'CHECK_FAILED')
            self.assertEqual(list((Path(tmp)/REQUEST['authority']['vmUuid']).iterdir()),[])
    def test_active_lock_is_busy(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(host,'RUNTIME_ROOT',Path(tmp)):
            locks=Path(tmp)/'locks';locks.mkdir(mode=0o700)
            with (locks/(REQUEST['authority']['vmUuid']+'.lock')).open('w') as handle:
                host.fcntl.flock(handle,host.fcntl.LOCK_EX|host.fcntl.LOCK_NB)
                self.assertEqual(host.run(REQUEST,self.transport())['error']['code'],'BUSY')

if __name__=='__main__':unittest.main()
