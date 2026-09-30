"""Cloud-reserved action transport. No standalone mutation of Cloud VMs."""
# Copyright 2026 ABLECLOUD. Apache-2.0.
import base64,datetime as dt,fcntl,json,os,stat,time,uuid
from pathlib import Path
from process_list_host import RUNTIME_ROOT,inherited_guard,parent_alive,failure
from guest_adapter_compat import approved, linux_read_profile, supported_windows

def context(request,path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as handle:
        info=os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or stat.S_IMODE(info.st_mode)!=0o600 or info.st_nlink!=1:raise ValueError('unsafe reservation')
        raw=handle.read(65537)
    if len(raw)>65536:raise ValueError('reservation limit')
    import vm_exec
    value=vm_exec.strict_json(raw.decode())
    if set(value)!={'schemaVersion','authority','requestId','operationId','lifecycleFenceHeld','ownerPid','ownerStartTicks','hostBootId','expiresMonotonicNs'}:raise ValueError('reservation fields')
    if value['schemaVersion']!='1.0' or value['authority']!=request['authority'] or value['requestId']!=request['requestId'] or value['operationId']!=request['operationId'] or value['lifecycleFenceHeld'] is not True:raise ValueError('reservation mismatch')
    pid=value['ownerPid']
    if type(pid) is not int or pid<=1:raise ValueError('owner')
    # The root Agent must be the live ancestor holding the parent channel.
    ancestor=os.getppid();seen=set()
    while ancestor>1 and ancestor!=pid and ancestor not in seen:
        seen.add(ancestor);text=Path('/proc',str(ancestor),'stat').read_text();ancestor=int(text[text.rindex(')')+2:].split()[1])
    if ancestor!=pid or Path('/proc',str(pid)).stat().st_uid!=0:raise ValueError('reservation owner')
    text=Path('/proc',str(pid),'stat').read_text()
    if text[text.rindex(')')+2:].split()[19]!=value['ownerStartTicks'] or Path('/proc/sys/kernel/random/boot_id').read_text().strip()!=value['hostBootId']:raise ValueError('owner generation')
    remaining=(int(value['expiresMonotonicNs'])-time.monotonic_ns())/1e9
    if not 0<remaining<=95:raise ValueError('expired reservation')
    parent_alive();return remaining

def unknown(request):
    now=dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
    return dict(schemaVersion='1.0',kind='actionResult',requestId=request['requestId'],authority=request['authority'],operationId=request['operationId'],action=request['action'],identity=request['identity'],service=request['service'],state='UNKNOWN',effect='MAY_HAVE_RUN',submittedAt=now,completedAt=None,guestExecPid=None,guestExitCode=None,postcondition='NOT_CHECKED',error=dict(code='RESULT_UNKNOWN',message='Action completion unknown; query only',retryMode='READ_ONLY'))

def validate_result(value,request):
    if not isinstance(value,dict) or value.get('schemaVersion')!='1.0' or value.get('authority',{}).get('vmUuid')!=request['authority']['vmUuid']:raise ValueError('guest identity')
    if value.get('kind')=='failure':
        if set(value)!={'schemaVersion','kind','requestId','authority','error'} or value['requestId']!=request['requestId'] or value['authority']!=request['authority']:raise ValueError('failure identity')
        error=value['error']
        if set(error)!={'code','message','retryMode'} or error['code'] not in ('PERMISSION_DENIED','STALE_AUTHORITY','REQUEST_CONFLICT','BUSY','STALE_SNAPSHOT','NOT_FOUND','CHECK_FAILED'):raise ValueError('failure')
        return
    fields={'schemaVersion','kind','requestId','authority','operationId','action','identity','service','state','effect','submittedAt','completedAt','guestExecPid','guestExitCode','postcondition','error'}
    if set(value)!=fields or value['kind']!='actionResult' or value['operationId']!=request['operationId']:raise ValueError('action result')
    if request['kind']=='actionRequest' and any(value[k]!=request[k] for k in ('requestId','authority','action','identity','service')):raise ValueError('request mismatch')
    state=value['state'];error=value['error']
    if state=='SUCCEEDED':
        expected='SERVICE_RESTART_VERIFIED' if value['action']=='service.restart' else 'TARGET_EXITED'
        if value['effect']!='VERIFIED' or value['postcondition']!=expected or error is not None or value['guestExitCode'] not in (None,0) or value['completedAt'] is None:raise ValueError('unverified success')
    elif state=='UNKNOWN':
        if value['effect']!='MAY_HAVE_RUN' or value['postcondition']!='NOT_CHECKED' or value['completedAt'] is not None or not error or error.get('code')!='RESULT_UNKNOWN' or error.get('retryMode')!='READ_ONLY':raise ValueError('unsafe unknown')
    elif state=='FAILED':
        if value['effect'] not in ('NOT_STARTED','MAY_HAVE_RUN') or value['postcondition']!='NOT_CHECKED' or value['completedAt'] is None or not error:raise ValueError('failure evidence')
    else:raise ValueError('unexpected pending reply')
    i=value['identity']
    if set(i)!={'vmUuid','bootId','pid','startTicks'} or i['vmUuid']!=request['authority']['vmUuid'] or type(i['pid']) is not int or not 1<=i['pid']<=4294967295 or not isinstance(i['startTicks'],str) or not i['startTicks'].isascii() or not i['startTicks'].isdigit() or len(i['startTicks'])>20:raise ValueError('target identity')
    for name in ('submittedAt','completedAt'):
        if value[name] is not None:
            if not isinstance(value[name],str) or not value[name].endswith('Z'):raise ValueError('timestamp')
            dt.datetime.fromisoformat(value[name].replace('Z','+00:00'))


def run(request,transport,reservation=None):
    if os.geteuid()!=0:return failure(request,'PERMISSION_DENIED','Root execution context required')
    action=request['kind']=='actionRequest'
    if action and reservation is None:return failure(request,'PERMISSION_DENIED','Cloud lifecycle reservation is required; standalone mutation is disabled')
    vm=request['authority']['vmUuid'];lock=None;slot=None;dispatched=False
    try:
        root=RUNTIME_ROOT;locks=root/'locks'
        for directory in (root,locks):
            directory.mkdir(mode=0o700,exist_ok=True)
            info=directory.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o077:raise ValueError('unsafe directory')
        if action:
            remaining=context(request,reservation)
            lock=inherited_guard(9,locks/(vm+'.lock'))
        else:
            remaining=min(10,request['budgetMs']/1000)
            lock=os.open(locks/(vm+'.lock'),os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600);fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        deadline=time.monotonic()+min(remaining,request['budgetMs']/1000)
        lease=root/vm
        if lease.is_symlink():raise ValueError('unsafe lease')
        lease.mkdir(mode=0o700,exist_ok=True)
        info=lease.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o077:raise ValueError('unsafe lease')
        marker=lease/('q5-'+request['operationId']+'.json')
        # C5 keeps its own durable reservation outside this directory. Only this
        # operation's unresolved marker may be queried under the exclusive lock.
        if any(p!=marker for p in lease.iterdir()):return failure(request,'BUSY','Another operation lease exists')
        if action and marker.exists():return unknown(request)
        def host(*args):return transport.bounded_process(['virsh','-c','qemu:///system',*args],deadline,65536,lock).decode().strip()
        matches=[line.split(maxsplit=1)[1] for line in host('list','--all','--uuid','--name').splitlines() if len(line.split(maxsplit=1))==2 and line.split(maxsplit=1)[0]==vm]
        if len(matches)!=1:return failure(request,'STALE_AUTHORITY','Domain absent')
        domain=matches[0]
        if host('domuuid',domain)!=vm or host('domstate',domain)!='running':return failure(request,'STALE_AUTHORITY','Domain changed')
        if host('domjobinfo',domain).split()!=['Job','type:','None'] or transport.strict_json(host('qemu-monitor-command',domain,'{"execute":"query-block-jobs"}')).get('return')!=[]:return failure(request,'BUSY','Domain job active or unknown')
        # Four active host action slots. Unresolved VM markers survive process exit.
        if action:
            capacity=root/'action-slots';os.close(transport.secure_directory(capacity))
            for index in range(4):
                fd=os.open(capacity/str(index),os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
                try:
                    info=os.fstat(fd)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_mode&0o077 or info.st_nlink!=1:os.close(fd);raise ValueError('unsafe slot')
                    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);slot=fd;break
                except BlockingIOError:os.close(fd)
            if slot is None:return failure(request,'BUSY','Action capacity exhausted')
        with transport.Admission() as admission:osinfo=transport.rpc(domain,{'execute':'guest-get-osinfo'},deadline,3,admission.fd,65536)
        guest=dict(request,budgetMs=max(1,int((deadline-time.monotonic())*1000)-300))
        encoded=base64.b64encode(transport.dumps(guest).encode()).decode()
        family=osinfo.get('id');version=osinfo.get('version-id');arch=osinfo.get('machine')
        linux=linux_read_profile(osinfo) is not None
        windows=supported_windows(osinfo)
        if arch not in ('x86_64','x86-64','amd64') or not (linux or windows):return failure(request,'TOOLS_REQUIRED','OS unsupported')
        if linux:
            bundles=approved('linux-action')
            script="import os,hashlib,sys;p='/usr/libexec/ablestack-qemu-exec-tools/process/';h=hashlib.sha256(open(p+'process_action_linux.py','rb').read()).hexdigest();x=p+'process-action-launcher';y=hashlib.sha256(open(x,'rb').read()).hexdigest();(h,y) in "+repr(bundles)+" or sys.exit(3);os.execv(x,[x,'--request-base64','"+encoded+"'])"
            command=['/usr/bin/python3','-I','-c',script]
        else:
            bundles=approved('windows-action')
            choices='@('+','.join("'"+':'.join(pair)+"'" for pair in bundles)+')'
            # Module auto-loading during Get-FileHash can emit localized CLIXML
            # progress to stderr before the adapter sets its stream preferences.
            # Establish the wire format first; retain strict UTF-8 validation of
            # both streams instead of accepting a lossy transport result.
            script=r"$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);$p='C:\Program Files\ABLESTACK Process Tools';$h=@('ProcessAction.ps1','AbleProcessAction.dll','AbleProcessIdentity.dll') | ForEach-Object {(Get-FileHash -LiteralPath (Join-Path $p $_)).Hash.ToLowerInvariant()};$approved="+choices+";if($approved -notcontains ($h -join ':')){exit 3};& (Join-Path $p 'ProcessAction.ps1') -RequestBase64 '"+encoded+"'"
            command=[r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()]
        if action:
            context(request,reservation)
            fd=os.open(marker,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'w') as out:out.write(transport.dumps({'operationId':request['operationId'],'authority':request['authority'],'requestId':request['requestId']}));out.flush();os.fsync(out.fileno())
            directory=os.open(lease,os.O_RDONLY|os.O_DIRECTORY);os.fsync(directory);os.close(directory)
            dispatched=True
        options={'mode':'-l','timeout':max(.001,deadline-time.monotonic()),'rpc_timeout':3,'max_output':1048576,'headers':None,'out':'','csv':False,'table':False}
        reply=transport.execute(domain,command,options)
        if reply['state']!='SUCCEEDED' or reply['exit_code']!=0 or reply['encoding_loss'] or reply['out_truncated']:return unknown(request) if action else failure(request,'CHECK_FAILED','Journal query unavailable')
        value=transport.strict_json(reply['stdout_raw'])
        validate_result(value,request)
        if host('domuuid',domain)!=vm or host('domstate',domain)!='running':return unknown(request) if action else failure(request,'STALE_AUTHORITY','Domain changed')
        if value.get('kind')=='actionResult':
            if value.get('operationId')!=request['operationId'] or action and any(value.get(k)!=request[k] for k in ('requestId','authority','action','identity','service')):raise ValueError('guest result mismatch')
            if value.get('state') in ('SUCCEEDED','FAILED') and marker.exists():marker.unlink()
        elif value.get('kind')=='failure' and value.get('requestId')==request['requestId']:
            if action and marker.exists():marker.unlink()
        else:raise ValueError('guest result kind')
        return value
    except BlockingIOError:return failure(request,'BUSY','Operation lock busy')
    except (OSError,ValueError,KeyError,TypeError,transport.ExecError):return unknown(request) if action and dispatched else failure(request,'CHECK_FAILED','Process operation unavailable')
    finally:
        if slot is not None:os.close(slot)
        if lock is not None:os.close(lock)
