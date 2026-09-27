#!/usr/bin/env python3
"""Fixed Linux actions with pidfd identity and durable, non-replaying journal."""
# Copyright 2026 ABLECLOUD. Apache-2.0.
import base64
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

ROOT=Path('/var/lib/ablestack-process-actions')
PROTECTED={'systemd','init','qemu-ga','sshd','dbus-daemon','dbus-broker','systemd-logind','systemd-udevd','NetworkManager','auditd'}
UNIT_DENY=re.compile(r'^(?:qemu|systemd|dbus|ssh|NetworkManager|network|auditd|polkit|ablestack)[-.@]',re.I)
class Rejected(Exception):
    pass

def compact(value):return json.dumps(value,ensure_ascii=False,allow_nan=False,separators=(',',':'),sort_keys=True)
def strict(raw):
    def pairs(items):
        result={}
        for key,value in items:
            if key in result:raise ValueError('duplicate key')
            result[key]=value
        return result
    return json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite')))
def stamp():return dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
def canonical(value):
    if not isinstance(value,str) or str(uuid.UUID(value))!=value:raise ValueError('UUID')
def fields(value,names):
    if not isinstance(value,dict) or set(value)!=set(names.split()):raise ValueError('fields')
def validate(r):
    if r.get('schemaVersion')!='1.0':raise ValueError('version')
    fields(r['authority'],'vmUuid hostUuid placementGeneration')
    for value in (r['requestId'],r['authority']['vmUuid'],r['authority']['hostUuid']):canonical(value)
    gen=r['authority']['placementGeneration']
    if not isinstance(gen,str) or not re.fullmatch('[0-9]{1,20}',gen):raise ValueError('generation')
    if type(r['budgetMs']) is not int or not 1<=r['budgetMs']<=90000:raise ValueError('budget')
    if r['kind']=='readRequest':
        fields(r,'schemaVersion kind requestId authority operation operationId budgetMs')
        if r['operation']!='operation.get' or r['budgetMs']>10000:raise ValueError('operation')
        canonical(r['operationId']);return
    fields(r,'schemaVersion kind requestId authority operationId action identity snapshotId observedAt service budgetMs')
    if r['kind']!='actionRequest' or r['action'] not in ('process.terminate','process.kill','service.restart'):raise ValueError('action')
    canonical(r['operationId']);canonical(r['snapshotId']);fields(r['identity'],'vmUuid bootId pid startTicks')
    i=r['identity']
    if i['vmUuid']!=r['authority']['vmUuid'] or not isinstance(i['bootId'],str) or not i['bootId'].startswith('linux:'):raise ValueError('identity')
    canonical(i['bootId'][6:])
    if type(i['pid']) is not int or not 1<=i['pid']<=4294967295 or not isinstance(i['startTicks'],str) or not re.fullmatch('[0-9]{1,20}',i['startTicks']):raise ValueError('PID identity')
    if not isinstance(r['observedAt'],str) or not r['observedAt'].endswith('Z'):raise ValueError('time')
    dt.datetime.fromisoformat(r['observedAt'].replace('Z','+00:00'))
    if r['action']=='service.restart':
        fields(r['service'],'manager name configurationHash');s=r['service']
        if s['manager']!='systemd' or not isinstance(s['name'],str) or not re.fullmatch('[A-Za-z0-9_@.:-]{1,248}\.service',s['name']) or s['name'].startswith('-') or not re.fullmatch('[a-f0-9]{64}',s['configurationHash']):raise ValueError('service')
    elif r['service'] is not None or r['budgetMs']>15000:raise ValueError('action fields')
def failure(r,code):return dict(schemaVersion='1.0',kind='failure',requestId=r['requestId'],authority=r['authority'],error=dict(code=code,message='Process operation unavailable',retryMode='READ_ONLY' if code in ('BUSY','NOT_FOUND') else 'NONE'))
def result(r):
    return dict(schemaVersion='1.0',kind='actionResult',requestId=r['requestId'],authority=r['authority'],operationId=r['operationId'],action=r['action'],identity=r['identity'],service=r['service'],state='ACCEPTED',effect='NOT_STARTED',submittedAt=stamp(),completedAt=None,guestExecPid=None,guestExitCode=None,postcondition='NOT_CHECKED',error=None)
def failed(value,code):
    value.update(state='FAILED',effect='NOT_STARTED',completedAt=stamp(),error=dict(code=code,message='Process action rejected',retryMode='NONE'));return value
def unknown(value):
    value.update(state='UNKNOWN',effect='MAY_HAVE_RUN',completedAt=None,postcondition='NOT_CHECKED',error=dict(code='RESULT_UNKNOWN',message='Execution may have occurred; query only',retryMode='READ_ONLY'));return value
def success(value):
    value.update(state='SUCCEEDED',effect='VERIFIED',completedAt=stamp(),guestExitCode=0,postcondition='SERVICE_RESTART_VERIFIED' if value['action']=='service.restart' else 'TARGET_EXITED',error=None);return value

def secure(path,directory=False):
    info=path.lstat()
    if (not stat.S_ISDIR(info.st_mode) if directory else not stat.S_ISREG(info.st_mode)) or info.st_uid!=0 or info.st_mode&0o077 or (not directory and info.st_nlink!=1):raise OSError('Unsafe journal path')
def save(path,value):
    data=compact(value).encode()
    if len(data)>16*1024*1024:raise OSError('Journal capacity')
    if path.exists() or path.is_symlink():secure(path)
    fd,name=tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as out:out.write(data);out.flush();os.fsync(out.fileno())
        os.replace(name,path)
        parent=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY);os.fsync(parent);os.close(parent)
    finally:
        if os.path.exists(name):os.unlink(name)
def boot():return 'linux:'+Path('/proc/sys/kernel/random/boot_id').read_text().strip()
def identity(pid):
    text=Path('/proc',str(pid),'stat').read_text();start=text.index('(');end=text.rindex(')');parts=text[end+2:].split()
    return text[start+1:end],parts[19],int(parts[1]),parts[0]
def expired(deadline):
    if time.monotonic()>=deadline:raise TimeoutError('deadline')
def props(unit,deadline):
    expired(deadline)
    names='Id,MainPID,ExecStart,User,Requires,Wants,CanStart,CanStop,ActiveState,SubState,Type,InvocationID,TriggeredBy,RequiredBy,BoundBy,ConsistsOf'
    # Output is bounded while reading, without temporary files or unbounded communicate().
    import selectors
    p=subprocess.Popen(['/usr/bin/systemctl','show','--no-pager','--property='+names,'--',unit],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env={'PATH':'/usr/bin:/bin','LC_ALL':'C'},start_new_session=True)
    selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ);data=bytearray()
    try:
        while selector.get_map():
            expired(deadline)
            for key,_ in selector.select(.05):
                part=os.read(key.fileobj.fileno(),4096)
                if not part:selector.unregister(key.fileobj);break
                data.extend(part)
                if len(data)>65536:raise ValueError('service output')
        if p.wait(timeout=max(.01,deadline-time.monotonic())):raise ValueError('service query')
    finally:
        selector.close()
        if p.poll() is None:os.killpg(p.pid,signal.SIGKILL)
        p.wait(timeout=.5);p.stdout.close()
    return dict(line.split('=',1) for line in data.decode().splitlines() if '=' in line)
def config_hash(p):
    command=re.sub(r'( ; ignore_errors=(?:yes|no)) ; start_time=.*?(?= \})',r'\1',p.get('ExecStart',''))
    config={'account':p.get('User',''),'canStart':p.get('CanStart')=='yes','canStop':p.get('CanStop')=='yes','command':command,'requires':sorted(p.get('Requires','').split()),'wants':sorted(p.get('Wants','').split())}
    return hashlib.sha256(compact(config).encode()).hexdigest()
def service_check(r,deadline):
    unit=r['service']['name']
    if UNIT_DENY.match(unit):raise Rejected('PROTECTED_TARGET')
    p=props(unit,deadline)
    if p.get('Id')!=unit or p.get('MainPID')!=str(r['identity']['pid']) or config_hash(p)!=r['service']['configurationHash']:raise Rejected('STALE_IDENTITY')
    if p.get('Type') not in ('simple','exec','forking','notify') or p.get('ActiveState')!='active' or p.get('CanStart')!='yes' or p.get('CanStop')!='yes' or not p.get('InvocationID'):raise Rejected('UNSUPPORTED_ACTION')
    # Conservative: dependencies requiring this service or automatic triggers can
    # restart/stop other workloads. Do not infer an impact boundary.
    if any(p.get(k) for k in ('TriggeredBy','RequiredBy','BoundBy','ConsistsOf')):raise Rejected('UNSUPPORTED_ACTION')
    return p

def target(r):
    i=r['identity'];pid=i['pid']
    if i['bootId']!=boot():raise Rejected('STALE_IDENTITY')
    if pid<=1 or pid in (os.getpid(),os.getppid()):raise Rejected('PROTECTED_TARGET')
    ancestor=os.getppid()
    while ancestor>1:
        if ancestor==pid:raise Rejected('PROTECTED_TARGET')
        ancestor=identity(ancestor)[2]
    if not hasattr(os,'pidfd_open') or not hasattr(signal,'pidfd_send_signal'):raise Rejected('UNSUPPORTED_ACTION')
    fd=os.pidfd_open(pid,0)
    try:
        name,ticks,_,state=identity(pid)
        executable=Path('/proc',str(pid),'exe').resolve(strict=True).name
        arguments=Path('/proc',str(pid),'cmdline').read_bytes().split(b'\0')
        if any(Path(os.fsdecode(arg)).name in ('process_list_linux.py','process_action_linux.py','process-read-launcher','process-action-launcher') for arg in arguments if arg):raise Rejected('PROTECTED_TARGET')
        if ticks!=i['startTicks'] or state in ('Z','X'):raise Rejected('STALE_IDENTITY')
        if name in PROTECTED or executable in PROTECTED or executable.startswith(('systemd-','qemu-ga')):raise Rejected('PROTECTED_TARGET')
        if select.select([fd],[],[],0)[0]:raise Rejected('STALE_IDENTITY')
        return fd
    except BaseException:os.close(fd);raise

def action(r,record,persist,deadline):
    fd=target(r)
    try:
        old=service_check(r,deadline) if r['action']=='service.restart' else None
        expired(deadline)
        record['stage']='dispatch-intent';unknown(record['result']);persist()
        if old is None:
            signal.pidfd_send_signal(fd,signal.SIGTERM if r['action']=='process.terminate' else signal.SIGKILL)
            record['stage']='signal-returned';persist()
            while not select.select([fd],[],[],min(.05,max(0,deadline-time.monotonic())))[0]:expired(deadline)
        else:
            unit=r['service']['name']
            # Repeat the configuration/generation check directly before control.
            current=service_check(r,deadline)
            if current['InvocationID']!=old['InvocationID']:raise Rejected('STALE_IDENTITY')
            record['oldInvocation']=old['InvocationID'];record['stage']='stop-intent';persist()
            subprocess.run(['/usr/bin/systemctl','stop','--no-block','--',unit],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=min(3,max(.01,deadline-time.monotonic())),check=True)
            while True:
                expired(deadline);p=props(unit,deadline)
                if p.get('ActiveState')=='inactive' and select.select([fd],[],[],0)[0]:break
                time.sleep(.05)
            record['stage']='stopped';persist()
            if config_hash(p)!=r['service']['configurationHash']:raise Rejected('STALE_IDENTITY')
            record['stage']='start-intent';persist()
            subprocess.run(['/usr/bin/systemctl','start','--no-block','--',unit],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=min(3,max(.01,deadline-time.monotonic())),check=True)
            record['stage']='start-returned';persist()
            while True:
                expired(deadline);p=props(unit,deadline)
                if p.get('ActiveState')=='active' and p.get('MainPID','0')!='0' and p.get('InvocationID') and p['InvocationID']!=old['InvocationID']:
                    _,ticks,_,_=identity(int(p['MainPID']))
                    if (int(p['MainPID']),ticks)!=(r['identity']['pid'],r['identity']['startTicks']) and config_hash(p)==r['service']['configurationHash']:break
                time.sleep(.05)
            record['newIdentity']={'pid':int(p['MainPID']),'startTicks':ticks,'invocation':p['InvocationID']}
        success(record['result']);record['stage']='complete';persist()
    finally:os.close(fd)

def reconcile(record,persist):
    value=record['result']
    if value['state'] not in ('ACCEPTED','RUNNING','UNKNOWN'):return value
    unknown(value)
    # A reboot or a missing dispatch confirmation cannot certify an action.
    if value['identity']['bootId']==boot() and record['stage']=='signal-returned':
        try:
            _,ticks,_,state=identity(value['identity']['pid'])
            exited=ticks!=value['identity']['startTicks'] or state in ('Z','X')
        except FileNotFoundError:exited=True
        if exited:success(value);record['stage']='complete'
    if value['state']=='UNKNOWN' and value['identity']['bootId']==boot() and record['stage']=='start-returned':
        try:
            p=props(value['service']['name'],time.monotonic()+2)
            newpid=int(p.get('MainPID','0'))
            if newpid>0:
                _,ticks,_,_=identity(newpid)
                if p.get('ActiveState')=='active' and p.get('InvocationID') and p['InvocationID']!=record.get('oldInvocation') and (newpid,ticks)!=(value['identity']['pid'],value['identity']['startTicks']) and config_hash(p)==value['service']['configurationHash']:
                    success(value);record['stage']='complete'
        except (OSError,ValueError,TimeoutError,subprocess.SubprocessError):pass
    persist();return value

def run(r,root=ROOT):
    validate(r)
    if os.geteuid()!=0:return failure(r,'PERMISSION_DENIED')
    root.mkdir(mode=0o700,parents=False,exist_ok=True);secure(root,True)
    lock=os.open(root/'lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try:
        secure(root/'lock');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        journal=root/'journal.json'
        if journal.exists() or journal.is_symlink():
            secure(journal)
            if journal.stat().st_size>16*1024*1024:raise OSError('journal size')
            state=strict(journal.read_text())
        else:state={'vmUuid':r['authority']['vmUuid'],'generation':'0','records':{}}
        def persist():save(journal,state)
        if state['vmUuid']!=r['authority']['vmUuid'] or int(r['authority']['placementGeneration'])<int(state['generation']):return failure(r,'STALE_AUTHORITY')
        state['generation']=r['authority']['placementGeneration'];persist()
        records=state['records'];old=records.get(r['operationId'])
        if r['kind']=='readRequest':
            if old is None:return failure(r,'NOT_FOUND')
            return reconcile(old,persist)
        digest=hashlib.sha256(compact({k:r[k] for k in ('action','identity','service','snapshotId','observedAt')}).encode()).hexdigest()
        if old:
            if old['digest']!=digest or old['result']['requestId']!=r['requestId']:return failure(r,'REQUEST_CONFLICT')
            return reconcile(old,persist)
        if any(x['result']['requestId']==r['requestId'] for x in records.values()):return failure(r,'REQUEST_CONFLICT')
        if len(records)>=4096 or any(x['result']['state'] in ('ACCEPTED','RUNNING','UNKNOWN') for x in records.values()):return failure(r,'BUSY')
        observed=dt.datetime.fromisoformat(r['observedAt'].replace('Z','+00:00'))
        age=(dt.datetime.now(dt.timezone.utc)-observed).total_seconds()
        if not 0<=age<=10:return failure(r,'STALE_SNAPSHOT')
        record={'digest':digest,'stage':'reserved','result':result(r)};records[r['operationId']]=record;persist()
        try:action(r,record,persist,time.monotonic()+r['budgetMs']/1000)
        except (Rejected,OSError,ValueError,TimeoutError,subprocess.SubprocessError) as error:
            if record['stage']=='reserved':failed(record['result'],str(error) if isinstance(error,Rejected) else 'STALE_IDENTITY')
            else:unknown(record['result'])
            persist()
        return record['result']
    except BlockingIOError:return failure(r,'BUSY')
    finally:os.close(lock)
def main():
    if len(sys.argv)!=3 or sys.argv[1]!='--request-base64':return 2
    raw=base64.b64decode(sys.argv[2],validate=True)
    if len(raw)>65536:return 2
    r=strict(raw.decode('utf-8'));validate(r)
    # Crash/timeout leaves durable intent. Never turn parent exit into a replay.
    signal.signal(signal.SIGALRM,lambda *_:os._exit(3));signal.setitimer(signal.ITIMER_REAL,r['budgetMs']/1000+1)
    try:print(compact(run(r)))
    finally:signal.setitimer(signal.ITIMER_REAL,0)
    return 0
if __name__=='__main__':
    try:sys.exit(main())
    except (ValueError,KeyError,TypeError,OSError):sys.exit(3)
