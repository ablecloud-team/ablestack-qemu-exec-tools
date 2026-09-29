"""Bounded root-only process.list bridge with standalone or inherited Cloud read guard."""
# Copyright 2026 ABLECLOUD. Apache-2.0.
import base64
import datetime as dt
import fcntl
import json
import math
import os
import re
import select
from pathlib import Path
import stat
import time
import uuid
from guest_adapter_compat import approved, supported_windows


RUNTIME_ROOT=Path('/run/ablestack-vm-operations')

def failure(request, code, message):
    return {'schemaVersion':'1.0', 'kind':'failure', 'requestId':request['requestId'],
            'authority':request['authority'], 'error':{'code':code,'message':message,'retryMode':'READ_ONLY'}}


def validate_snapshot(result, request):
    if result.get('requestId') != request['requestId'] or result.get('authority') != request['authority']:
        raise ValueError('guest envelope mismatch')
    if result.get('schemaVersion') != '1.0': raise ValueError('guest version mismatch')
    if result.get('kind') == 'failure':
        if result.get('error', {}).get('code') != 'CHECK_FAILED': raise ValueError('unexpected guest failure')
        return
    expected={'schemaVersion','kind','requestId','authority','snapshotId','bootId','observedAt','expiresAt','status','truncated','totalKnown','processes'}
    if set(result) != expected or result['kind'] != 'snapshot': raise ValueError('unexpected snapshot fields')
    if str(uuid.UUID(result['snapshotId'])) != result['snapshotId']: raise ValueError('invalid snapshot ID')
    if result['status'] not in ('OK','PARTIAL') or type(result['truncated']) is not bool: raise ValueError('invalid status')
    if result['truncated'] and result['status'] != 'PARTIAL': raise ValueError('truncation without partial')
    if not isinstance(result['processes'],list) or len(result['processes']) > 10000: raise ValueError('invalid rows')
    if not isinstance(result['bootId'],str) or not re.fullmatch(r'(linux:[0-9a-f-]{36}|windows:[0-9]{1,20})',result['bootId']): raise ValueError('invalid boot identity')
    seen=set()
    for row in result['processes']:
        if set(row) != {'identity','ppid','name','owner','state','memoryBytes','cpuPercent','services','allowedActions'}: raise ValueError('unexpected row fields')
        identity=row['identity']
        if set(identity) != {'vmUuid','bootId','pid','startTicks'}: raise ValueError('invalid identity fields')
        if identity['vmUuid'] != request['authority']['vmUuid'] or identity['bootId'] != result['bootId']: raise ValueError('mixed identity')
        if type(identity['pid']) is not int or not 1 <= identity['pid'] <= 4294967295: raise ValueError('invalid PID')
        ticks=identity['startTicks']
        if not isinstance(ticks,str) or not ticks.isascii() or not ticks.isdigit() or len(ticks)>20: raise ValueError('invalid ticks')
        key=identity['pid']
        if key in seen: raise ValueError('duplicate identity')
        seen.add(key)
        if row['allowedActions'] != []: raise ValueError('unimplemented action advertised')
        cpu = row['cpuPercent']
        if cpu is not None and (type(cpu) not in (int, float) or cpu < 0 or (type(cpu) is float and not math.isfinite(cpu))): raise ValueError('invalid CPU percent')
        for name in ('name','state'):
            if not isinstance(row[name],str) or not 1<=len(row[name])<=256: raise ValueError('invalid text')
        if row['owner'] is not None and (not isinstance(row['owner'],str) or len(row['owner'])>256): raise ValueError('invalid owner')
        for name, bound in (('ppid',4294967295),('memoryBytes',9007199254740991)):
            if row[name] is not None and (type(row[name]) is not int or not 0<=row[name]<=bound): raise ValueError('invalid numeric field')
        if not isinstance(row['services'],list) or len(row['services'])>128: raise ValueError('invalid service mapping')
        for service in row['services']:
            if set(service) != {'manager','name','configurationHash'}: raise ValueError('unexpected service fields')
            if service['manager'] not in ('scm','systemd') or not isinstance(service['name'],str) or not 1<=len(service['name'])<=256: raise ValueError('invalid service')
            digest=service['configurationHash']
            if not isinstance(digest,str) or len(digest)!=64 or any(c not in '0123456789abcdef' for c in digest): raise ValueError('invalid service hash')
    if result['totalKnown'] is not None and (type(result['totalKnown']) is not int or result['totalKnown']<len(seen)): raise ValueError('invalid total')


def parent_alive():
    if not stat.S_ISFIFO(os.fstat(0).st_mode): raise ValueError('Cloud parent pipe required')
    poller=select.poll(); poller.register(0,select.POLLHUP|select.POLLERR|select.POLLIN)
    if poller.poll(0): raise ValueError('Cloud parent channel closed or unexpected input')


def inherited_guard(fd, path):
    if fd != 9 or os.geteuid()!=0: raise ValueError('Invalid Cloud guard')
    parent_alive()
    info=os.fstat(fd); actual=path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022 or info.st_nlink!=1 or (info.st_dev,info.st_ino)!=(actual.st_dev,actual.st_ino): raise ValueError('Invalid guard descriptor')
    # A separate open must conflict, while this inherited open-file description
    # must already own the lock. Environment variables cannot bypass the guard.
    probe=os.open(path,os.O_RDWR|os.O_NOFOLLOW)
    try:
        try: fcntl.flock(probe,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: pass
        else: raise ValueError('Parent guard is not held')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    finally: os.close(probe)
    return os.dup(fd)


def run(request, transport, cloud_guard=None):
    if os.geteuid()!=0: return failure(request,'HOST_TOOL_MISSING','Root process collector required')
    deadline=time.monotonic()+min(5,request['budgetMs']/1000)
    vm=request['authority']['vmUuid']; lock=None
    def host(*args):
        if cloud_guard is not None: parent_alive()
        return transport.bounded_process(['virsh','-c','qemu:///system',*args],deadline,65536,lock).decode().strip()
    try:
        root=RUNTIME_ROOT; locks=root/'locks'
        for path in (root,locks):
            path.mkdir(mode=0o700,exist_ok=True)
            info=path.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o077: raise ValueError('unsafe guard directory')
        lock=inherited_guard(cloud_guard,locks/(vm+'.lock')) if cloud_guard is not None else os.open(locks/(vm+'.lock'),os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_NONBLOCK,0o600)
        info=os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022 or info.st_nlink!=1: raise ValueError('unsafe guard lock')
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        lease=root/vm
        if lease.is_symlink() or (lease.exists() and any(lease.iterdir())): return failure(request,'BUSY','Existing VM operation lease')
        matches=[line.split(maxsplit=1)[1] for line in host('list','--all','--uuid','--name').splitlines() if line.split(maxsplit=1)[0]==vm and len(line.split(maxsplit=1))==2]
        if len(matches)!=1: return failure(request,'STALE_AUTHORITY','Domain identity unavailable')
        domain=matches[0]
        if host('domuuid',domain)!=vm or host('domstate',domain)!='running': return failure(request,'STALE_AUTHORITY','Domain not running on this host')
        if host('domjobinfo',domain).split()!=['Job','type:','None']: return failure(request,'BUSY','Domain job active or unknown')
        if transport.strict_json(host('qemu-monitor-command',domain,'{"execute":"query-block-jobs"}')).get('return')!=[]: return failure(request,'BUSY','Block job active or unknown')
        with transport.Admission() as slot:
            osinfo=transport.rpc(domain,{'execute':'guest-get-osinfo'},deadline,3,slot.fd,65536)
        family=osinfo.get('id',''); version=osinfo.get('version-id',''); arch=osinfo.get('machine','')
        linux=(family=='rocky' and version in ('9.6','9.7','9.8','10.2')) or (family=='ubuntu' and version in ('22.04','24.04','26.04'))
        windows=supported_windows(osinfo)
        if arch not in ('x86_64','x86-64','amd64') or not (linux or windows): return failure(request,'TOOLS_REQUIRED','OS adapter unsupported')
        if cloud_guard is not None:
            parent_alive()
            rates=root/'read-rate';rates.mkdir(mode=0o700,exist_ok=True)
            info=rates.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o077: raise ValueError('unsafe rate directory')
            rate=rates/(vm+'.json')
            if rate.exists():
                if rate.is_symlink() or not stat.S_ISREG(rate.lstat().st_mode): raise ValueError('unsafe rate file')
                last=float(rate.read_text())
                if 0 <= time.monotonic()-last < 5: return failure(request,'BUSY','VM read rate limit')
            fd=os.open(rate,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'w') as handle: handle.write(str(time.monotonic()))
        remaining=deadline-time.monotonic()
        if remaining<0.5: return failure(request,'CHECK_FAILED','Observation budget exhausted')
        guest=dict(request,budgetMs=max(1,min(3000,int((remaining-0.3)*1000))))
        encoded=base64.b64encode(transport.dumps(guest).encode()).decode()
        if linux:
            profile='rocky-read' if family=='rocky' else 'ubuntu-read'
            bundles=approved(profile)
            script="import hashlib,runpy,sys,os;p='/usr/libexec/ablestack-qemu-exec-tools/process/process_list_linux.py';h=hashlib.sha256(open(p,'rb').read()).hexdigest();"
            if family=='rocky':
                script+="x='/usr/libexec/ablestack-qemu-exec-tools/process/process-read-launcher';y=hashlib.sha256(open(x,'rb').read()).hexdigest();(h,y) in "+repr(bundles)+" or sys.exit(3);os.execv(x,[x,'--request-base64','"+encoded+"'])"
            else:
                script+="(h,) in "+repr(bundles)+" or sys.exit(3);sys.argv=[p,'--request-base64','"+encoded+"'];runpy.run_path(p,run_name='__main__')"
            command=['/usr/bin/python3','-I','-c',script]
        else:
            bundles=approved('windows-read')
            choices='@('+','.join("'"+':'.join(pair)+"'" for pair in bundles)+')'
            script="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$p='C:\\Program Files\\ABLESTACK Process Tools\\ProcessList.ps1';$raw=(Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant();$native=(Get-FileHash -LiteralPath (Join-Path (Split-Path $p) 'AbleProcessIdentity.dll')).Hash.ToLowerInvariant();$approved="+choices+";if($approved -notcontains ($raw+':'+$native)){$sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($p).Replace([string][char]13+[char]10,[string][char]10))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};if($approved -notcontains ($hash+':'+$native)){exit 3}};& $p -RequestBase64 '"+encoded+"'"
            command=['C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()]
        options={'mode':'-l','timeout':remaining,'rpc_timeout':3,'max_output':1048576,'headers':None,'out':'','csv':False,'table':False}
        # Persist before dispatch: host crash or ambiguous guest-exec must block
        # another observer until an operator/C4 reconciles guest completion.
        lease.mkdir(mode=0o700,exist_ok=True)
        marker=lease/('q4-read-'+request['requestId']+'.json')
        marker_fd=os.open(marker,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(marker_fd,'w') as handle:
            json.dump({'kind':'q4-read-lease','requestId':request['requestId'],'vmUuid':vm,'guestExecPid':None},handle)
            handle.flush();os.fsync(handle.fileno())
        if cloud_guard is not None: parent_alive()
        result=transport.execute(domain,command,options)
        if result['state']=='UNKNOWN':
            with marker.open('w') as handle:
                json.dump({'kind':'q4-read-lease','requestId':request['requestId'],'vmUuid':vm,'guestExecPid':result.get('guest_exec_pid')},handle)
                handle.flush();os.fsync(handle.fileno())
            return failure(request,'CHECK_FAILED','Guest completion unknown; observation lease retained for reconciliation')
        marker.unlink()
        if result['state']!='SUCCEEDED' or result['exit_code']!=0 or result['encoding_loss'] or result['out_truncated']:
            return failure(request,'CHECK_FAILED','Guest adapter execution failed, unavailable or incomplete')
        snapshot=transport.strict_json(result['stdout_raw'])
        validate_snapshot(snapshot,request)
        if host('domuuid',domain)!=vm or host('domstate',domain)!='running': return failure(request,'STALE_AUTHORITY','Domain changed during observation')
        if snapshot['kind']=='snapshot':
            now=dt.datetime.now(dt.timezone.utc)
            snapshot['observedAt']=now.isoformat(timespec='milliseconds').replace('+00:00','Z')
            snapshot['expiresAt']=(now+dt.timedelta(seconds=10)).isoformat(timespec='milliseconds').replace('+00:00','Z')
        return snapshot
    except BlockingIOError: return failure(request,'BUSY','VM observation already running')
    except (OSError,ValueError,KeyError,TypeError,transport.ExecError):
        return failure(request,'CHECK_FAILED','Process observation unavailable')
    finally:
        if lock is not None: os.close(lock)
