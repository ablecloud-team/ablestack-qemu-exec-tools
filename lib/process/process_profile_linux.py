#!/usr/bin/env python3
"""Administrator-provisioned restart profiles; no collected-command replay."""
# Copyright 2026 ABLECLOUD. Apache-2.0.
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import signal
import stat
import subprocess
import time
import tempfile
import uuid

BASE=Path('/var/lib/ablestack-process-actions')
PROFILES=BASE/'profiles'

def adapter():
    if 'ACTION' in globals():return ACTION
    spec=importlib.util.spec_from_file_location('fixed_action',str(Path(__file__).with_name('process_action_linux.py')))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

def regular(path,private=True):
    # Resolve every administrator-controlled ancestor, rejecting symlinks and writes.
    path=Path(path)
    if not path.is_absolute():raise ValueError('absolute path required')
    for parent in reversed(path.parents):
        info=parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022:raise ValueError('unsafe ancestor')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_mode& (0o077 if private else 0o022) or info.st_nlink!=1:raise ValueError('unsafe profile file')
        data=bytearray()
        while True:
            part=os.read(fd,65536)
            if not part:break
            data.extend(part)
            if len(data)>(65536 if private else 64*1024*1024):raise ValueError('profile file limit')
        return bytes(data)
    finally:os.close(fd)

def digest(data):return hashlib.sha256(data).hexdigest()
def save_bytes(path,data):
    # Supervisor and EnvironmentFile are bytes, not JSON journal values.
    a=adapter()
    if path.exists() or path.is_symlink():a.secure(path)
    fd,name=tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as out:out.write(data);out.flush();os.fsync(out.fileno())
        os.replace(name,path)
        parent=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(parent)
        finally:os.close(parent)
    finally:
        if os.path.exists(name):os.unlink(name)

def paths(identifier):
    if str(uuid.UUID(identifier))!=identifier:raise ValueError('profile ID')
    return PROFILES/(identifier+'.json'),BASE/('profile-'+identifier+'.binding.json')

def load(identifier,vm):
    a=adapter();path,binding=paths(identifier);raw=regular(path);p=a.strict(raw.decode())
    a.fields(p,'schemaVersion id version vmUuid displayName executable executableHash argv cwd account environmentRef supervisor verification')
    if p['schemaVersion']!='1.0' or p['id']!=identifier or p['vmUuid']!=vm or type(p['version']) is not int or not 1<=p['version']<=2147483647:raise ValueError('profile scope/version')
    a.canonical(vm)
    if not isinstance(p['displayName'],str) or not 1<=len(p['displayName'])<=80 or any(ord(c)<32 for c in p['displayName']):raise ValueError('profile label')
    if not isinstance(p['argv'],list) or len(p['argv'])>32 or any(not isinstance(s,str) or len(s)>1024 or any(ord(c)<32 for c in s) for s in p['argv']):raise ValueError('argv')
    if p['verification']!='identity-and-running' or not isinstance(p['account'],str):raise ValueError('verification/account')
    pwd.getpwnam(p['account'])
    if digest(regular(p['executable'],False))!=p['executableHash']:raise ValueError('executable changed')
    if not Path(p['cwd']).is_absolute() or not Path(p['cwd']).is_dir():raise ValueError('cwd')
    cwd=Path(p['cwd']).lstat();uid=pwd.getpwnam(p['account']).pw_uid
    if not stat.S_ISDIR(cwd.st_mode) or cwd.st_uid not in (0,uid) or cwd.st_mode&0o022:raise ValueError('unsafe cwd')
    for name in ('executable','cwd','account'):
        if not isinstance(p[name],str) or len(p[name])>1024 or any(ord(c)<32 for c in p[name]):raise ValueError('profile path/account')
    if p['environmentRef'] is not None:
        if not isinstance(p['environmentRef'],str) or len(p['environmentRef'])>1024 or any(ord(c)<32 for c in p['environmentRef']):raise ValueError('environment reference')
        regular(p['environmentRef'])
    a.fields(p['supervisor'],'manager name configurationHash effectiveHash')
    unit=p['supervisor']['name']
    if p['supervisor']['manager']!='systemd' or unit!='ableprofile-'+identifier+'.service':raise ValueError('supervisor')
    if digest(regular('/etc/systemd/system/'+unit,False))!=p['supervisor']['configurationHash']:raise ValueError('supervisor changed')
    live=a.props(unit,time.monotonic()+2)
    if live.get('LoadState')!='loaded' or live.get('CanStart')!='yes' or live.get('WorkingDirectory')!=p['cwd'] or live.get('User')!=p['account'] or live.get('Type')!='simple' or live.get('Restart')!='no':raise ValueError('invalid loaded supervisor')
    if effective(live)!=p['supervisor']['effectiveHash']:raise ValueError('loaded supervisor changed')
    b=a.strict(regular(binding).decode());a.fields(b,'vmUuid bootId pid startTicks')
    if b['vmUuid']!=vm:raise ValueError('binding scope')
    return p,b,digest(raw)

def effective(value):
    a=adapter()
    command=re.sub(r'( ; ignore_errors=(?:yes|no)) ; start_time=.*?(?= \})',r'\1',value.get('ExecStart',''))
    return digest(a.compact(dict(command=command,account=value.get('User',''),cwd=value.get('WorkingDirectory',''),environmentRef=value.get('EnvironmentFiles',''),inlineEnvironment=value.get('Environment',''),restart=value.get('Restart',''),type=value.get('Type',''),killMode=value.get('KillMode',''))).encode())

def public(p,b,h):
    return dict(id=p['id'],version=p['version'],definitionHash=h,displayName=p['displayName'],executable=p['executable'],argumentCount=len(p['argv']),cwd=p['cwd'],account=p['account'],environmentRef=p['environmentRef'],supervisor=p['supervisor']['manager'],verification=p['verification'],identity=b)

def list_profiles(r):
    values=[]
    if PROFILES.exists():
        adapter().secure(PROFILES,True)
        names=sorted(PROFILES.glob('*.json'))
        if len(names)>32:raise ValueError('profile capacity')
        for path in names:
            try:
                p,b,h=load(path.stem,r['authority']['vmUuid']);values.append(public(p,b,h))
            except (ValueError,OSError,KeyError):
                # An invalid profile never becomes executable or silently approved.
                values.append(dict(id=path.stem,available=False))
    return dict(schemaVersion='1.1',kind='profiles',requestId=r['requestId'],authority=r['authority'],profiles=values)

def matches(p,pid):
    try:
        raw=Path('/proc',str(pid),'cmdline').read_bytes()
        uid=next(line.split()[1] for line in Path('/proc',str(pid),'status').read_text().splitlines() if line.startswith('Uid:'))
        return raw.split(b'\0')[:-1]==[os.fsencode(x) for x in [p['executable'],*p['argv']]] and int(uid)==pwd.getpwnam(p['account']).pw_uid
    except (FileNotFoundError,ProcessLookupError):return False

def duplicates(p,exclude):
    # Refuse uncertain/oversized inventories instead of creating duplicate workloads.
    names=[x.name for x in Path('/proc').iterdir() if x.name.isdigit()]
    if len(names)>4096:raise ValueError('process capacity')
    return any(int(name)!=exclude and matches(p,int(name)) for name in names)

def checked(r):
    a=adapter();p,b,h=load(r['profile']['id'],r['authority']['vmUuid'])
    if r['profile']!={'id':p['id'],'version':p['version'],'definitionHash':h}:raise a.Rejected('PROFILE_CHANGED')
    if b!=r['identity'] or not matches(p,b['pid']) or duplicates(p,b['pid']):raise a.Rejected('STALE_IDENTITY')
    return p,b,h

def progress(v,old,new,identity=None):v['progress']=dict(oldProcess=old,newProcess=new,newIdentity=identity)

def completed(record,persist,identity):
    a=adapter();v=record['result'];v.update(state='SUCCEEDED',effect='VERIFIED',completedAt=a.stamp(),guestExitCode=0,postcondition='PROFILE_RESTART_VERIFIED',error=None)
    progress(v,'EXITED','RUNNING',identity);record['stage']='profile-complete';persist();return v

def partial(record,persist):
    a=adapter();v=record['result'];v.update(state='PARTIAL',effect='PARTIAL',completedAt=a.stamp(),postcondition='OLD_EXITED_NEW_NOT_STARTED',error=dict(code='START_FAILED',message='Old process exited; new process did not start',retryMode='NONE'))
    progress(v,'EXITED','NOT_RUNNING');record['stage']='profile-partial';persist();return v

def run(r,record,persist,deadline):
    a=adapter();p,b,h=checked(r);fd,pollable=a.target(r)
    try:
        unit=p['supervisor']['name'];before=a.props(unit,deadline)
        if before.get('ActiveState') not in ('inactive','failed','active') or before.get('MainPID','0') not in ('0',str(b['pid'])):raise a.Rejected('BUSY')
        record['oldInvocation']=before.get('InvocationID');record['profileDefinition']=r['profile'];record['stage']='profile-stop-intent';a.unknown(record['result']);progress(record['result'],'RUNNING','NOT_ATTEMPTED');persist()
        # If already controlled by the dedicated supervisor, stop it before signaling.
        if before.get('MainPID')==str(b['pid']):
            subprocess.run(['/usr/bin/systemctl','stop','--no-block','--',unit],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=3,check=True)
        else:signal.pidfd_send_signal(fd,signal.SIGTERM)
        while not a.target_exited(fd,pollable,.05):a.expired(deadline)
        record['stage']='profile-stopped';progress(record['result'],'EXITED','NOT_ATTEMPTED');persist()
        p2,_,h2=load(p['id'],r['authority']['vmUuid'])
        if h2!=h or duplicates(p,0):return partial(record,persist)
        record['stage']='profile-start-intent';progress(record['result'],'EXITED','UNKNOWN');persist()
        start=subprocess.run(['/usr/bin/systemctl','start','--no-block','--',unit],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=min(3,max(.01,deadline-time.monotonic())))
        record['stage']='profile-start-returned';persist()
        if start.returncode:
            current=a.props(unit,deadline)
            if current.get('ActiveState') in ('inactive','failed') and current.get('MainPID','0')=='0' and not duplicates(p,0):return partial(record,persist)
            raise a.Rejected('RESULT_UNKNOWN')
        while True:
            a.expired(deadline);current=a.props(unit,deadline)
            if current.get('ActiveState')=='failed' and current.get('MainPID','0')=='0' and not duplicates(p,0):return partial(record,persist)
            pid=int(current.get('MainPID','0'))
            if pid and current.get('ActiveState')=='active' and matches(p,pid) and not duplicates(p,pid):
                _,ticks,_,state=a.identity(pid)
                if state not in ('Z','X') and (pid,ticks)!=(b['pid'],b['startTicks']):
                    # Require a stable live identity, not a momentarily spawned child.
                    time.sleep(.25);again=a.props(unit,deadline)
                    if again.get('MainPID')!=str(pid) or again.get('ActiveState')!='active':continue
                    fresh=dict(vmUuid=b['vmUuid'],bootId=a.boot(),pid=pid,startTicks=ticks)
                    record['newIdentity']=fresh;persist();a.save(paths(p['id'])[1],fresh)
                    return completed(record,persist,fresh)
            time.sleep(.05)
    finally:os.close(fd)

def reconcile(record,persist):
    # Observe durable intent and supervisor state. Never repeat stop or start.
    a=adapter();v=record['result'];a.unknown(v)
    try:
        p,_,h=load(v['profile']['id'],v['authority']['vmUuid'])
        if h!=v['profile']['definitionHash'] or v['identity']['bootId']!=a.boot():return v
        try:
            _,ticks,_,state=a.identity(v['identity']['pid'])
            old_exited=ticks!=v['identity']['startTicks'] or state in ('Z','X')
        except (FileNotFoundError,ProcessLookupError):old_exited=True
        if not old_exited:return v
        progress(v,'EXITED','UNKNOWN' if 'start' in record['stage'] else 'NOT_ATTEMPTED')
        if record['stage'] in ('profile-stop-intent','profile-stopped'):return partial(record,persist)
        if record['stage']=='profile-start-returned' or record.get('newIdentity'):
            current=a.props(p['supervisor']['name'],time.monotonic()+2);pid=int(current.get('MainPID','0'))
            if current.get('ActiveState')=='failed' and current.get('MainPID','0')=='0' and not duplicates(p,0):return partial(record,persist)
            if pid and current.get('ActiveState')=='active' and current.get('InvocationID')!=record.get('oldInvocation') and matches(p,pid) and not duplicates(p,pid):
                _,ticks,_,state=a.identity(pid)
                if state not in ('Z','X') and (pid,ticks)!=(v['identity']['pid'],v['identity']['startTicks']):
                    i=dict(vmUuid=v['identity']['vmUuid'],bootId=a.boot(),pid=pid,startTicks=ticks)
                    recorded=record.get('newIdentity')
                    if recorded is None or recorded==i:
                        a.save(paths(p['id'])[1],i);record['newIdentity']=i;return completed(record,persist,i)
    except (OSError,ValueError,TimeoutError,subprocess.SubprocessError):pass
    finally:persist()
    return v

def quote(s):return '"'+s.replace('\\','\\\\').replace('"','\\"').replace('%','%%')+'"'

def provision(description,pid):
    if os.geteuid()!=0:raise ValueError('administrator required')
    a=adapter();p=a.strict(Path(description).read_text());a.fields(p,'id version vmUuid displayName executable argv cwd account environmentRef verification')
    a.canonical(p['id']);a.canonical(p['vmUuid'])
    if type(p['version']) is not int or not 1<=p['version']<=2147483647 or p['verification']!='identity-and-running' or not isinstance(p['displayName'],str) or not 1<=len(p['displayName'])<=80 or any(ord(c)<32 for c in p['displayName']) or not isinstance(p['argv'],list) or len(p['argv'])>32 or any(not isinstance(s,str) or len(s)>1024 or any(ord(c)<32 for c in s) for s in p['argv']) or not isinstance(p['cwd'],str) or any(ord(c)<32 for c in p['cwd']) or not Path(p['cwd']).is_absolute() or not Path(p['cwd']).is_dir():raise ValueError('profile fields')
    if p['executable'] in ('/usr/bin/python3','/bin/sh','/usr/bin/bash') or Path(p['executable']).name in a.PROTECTED:raise ValueError('protected/interpreter executable')
    p['schemaVersion']='1.0';p['executableHash']=digest(regular(p['executable'],False))
    b=dict(vmUuid=p['vmUuid'],bootId=a.boot(),pid=pid,startTicks=a.identity(pid)[1])
    if os.readlink('/proc/'+str(pid)+'/exe')!=p['executable'] or not matches(p,pid):raise ValueError('binding executable/account/argv mismatch')
    BASE.mkdir(mode=0o700,exist_ok=True);a.secure(BASE,True)
    if p['environmentRef'] is not None:
        original=regular(p['environmentRef']);p['environmentRef']=str(BASE/('profile-'+p['id']+'.env'));save_bytes(Path(p['environmentRef']),original)
    unit='ableprofile-'+p['id']+'.service'
    # Only the administrator provisioning CLI writes a supervisor definition.
    text='[Unit]\nDescription=ABLESTACK registered process profile\n[Service]\nType=simple\nRestart=no\nUser='+p['account']+'\nWorkingDirectory='+p['cwd'].replace('%','%%')+'\nExecStart='+ ' '.join(quote(x) for x in [p['executable'],*p['argv']])+'\n'
    for name in ('executable','cwd','account'):
        if not isinstance(p[name],str) or len(p[name])>1024 or any(ord(c)<32 for c in p[name]):raise ValueError('profile path/account')
    if p['environmentRef'] is not None:
        if not isinstance(p['environmentRef'],str) or len(p['environmentRef'])>1024 or any(ord(c)<32 for c in p['environmentRef']):raise ValueError('environment reference')
        regular(p['environmentRef']);text+='EnvironmentFile='+quote(p['environmentRef'])+'\n'
    path=Path('/etc/systemd/system')/unit
    save_bytes(path,text.encode())
    if Path('/usr/sbin/restorecon').exists():subprocess.run(['/usr/sbin/restorecon',str(path)],check=True,timeout=10)
    subprocess.run(['/usr/bin/systemctl','daemon-reload'],check=True,timeout=10)
    p['supervisor']=dict(manager='systemd',name=unit,configurationHash=digest(text.encode()),effectiveHash=effective(a.props(unit,time.monotonic()+5)))
    BASE.mkdir(mode=0o700,exist_ok=True);a.secure(BASE,True);PROFILES.mkdir(mode=0o700,exist_ok=True);a.secure(PROFILES,True)
    a.save(paths(p['id'])[0],p);a.save(paths(p['id'])[1],b)
    # Apply the existing confined action-state label to new administrative files.
    if Path('/usr/sbin/restorecon').exists():subprocess.run(['/usr/sbin/restorecon','-RF',str(BASE)],check=True,timeout=10)
    load(p['id'],p['vmUuid']);print('Profile registered; Cloud registration and approval are required')

if __name__=='__main__':
    cli=argparse.ArgumentParser();cli.add_argument('--register',required=True);cli.add_argument('--bind-pid',required=True,type=int);args=cli.parse_args()
    provision(args.register,args.bind_pid)
