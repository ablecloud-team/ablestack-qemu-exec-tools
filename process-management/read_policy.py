#!/usr/bin/env python3
"""Root-only transactional install/remove of the confined read-only collector."""
# Copyright 2026 ABLECLOUD. Apache-2.0.
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile

ROOT=Path('/var/lib/ablestack-process-read')
TARGET=Path('/usr/libexec/ablestack-qemu-exec-tools/process')
MODULE='ablestack_process_read'
FILES={'process-read-launcher':(0o755,'ablestack_process_read_exec_t'),
       'process_list_linux.py':(0o644,'ablestack_process_read_data_t')}

def run(*args):
    result=subprocess.run(args,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=90)
    if result.returncode: raise RuntimeError('Policy command failed: '+args[0]+' '+result.stderr[:512])
    return result.stdout

def digest(data):return hashlib.sha256(data).hexdigest()

def secure(path,directory=False):
    info=path.lstat()
    if (not stat.S_ISDIR(info.st_mode) if directory else not stat.S_ISREG(info.st_mode)) or info.st_uid!=0 or info.st_mode&0o022:
        raise RuntimeError('Unsafe administrator path: '+str(path))
    return info

def parents(path):
    for parent in reversed(path.parents):
        secure(parent,True)
    secure(path,True)

def save(path,data,mode=0o600):
    if path.exists() or path.is_symlink():secure(path)
    fd,name=tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as out:out.write(data);out.flush();os.fsync(out.fileno())
        os.chmod(name,mode);os.replace(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)

def mapping(name):return re.escape(str(TARGET/name))

def local_mappings():
    return {line.split()[0]:line.split()[-1] for line in run('semanage','fcontext','-l','-C').splitlines() if line.startswith('/')}

def modules():return {line.split()[0] for line in run('semodule','-l').splitlines() if line.split()}

def write_state(state):save(ROOT/'state.json',json.dumps(state,sort_keys=True).encode())

def restore(state):
    if set(state.get('files',{}))!=set(FILES):raise RuntimeError('Invalid recovery state')
    # Never overwrite edits made after installation. Pending operations also
    # permit the original bytes, since an interrupted install may be partial.
    for name,entry in state['files'].items():
        p=TARGET/name
        if p.exists() or p.is_symlink():
            secure(p)
            allowed={entry['installedHash']}
            if state['phase']!='installed' and entry['original'] is not None:allowed.add(digest(base64.b64decode(entry['original'])))
            if digest(p.read_bytes()) not in allowed:raise RuntimeError('Newer administrator edit: '+name)
    state['phase']='restoring';write_state(state)
    known=local_mappings()
    for name,(_,label) in FILES.items():
        pattern=mapping(name)
        if pattern in known:
            if ':'+label+':' not in known[pattern]:raise RuntimeError('Conflicting administrator mapping')
            run('semanage','fcontext','-d',pattern)
    for name,entry in state['files'].items():
        p=TARGET/name
        if entry['original'] is None:p.unlink(missing_ok=True)
        else:save(p,base64.b64decode(entry['original']),entry['originalMode']);run('restorecon',str(p))
    if MODULE in modules():run('semodule','-r',MODULE)
    (ROOT/'state.json').unlink()

def apply(payload):
    inputs={name:(payload/name).read_bytes() for name in FILES}
    policy=(payload/(MODULE+'.cil')).read_bytes()
    state_path=ROOT/'state.json'
    if state_path.exists():
        secure(state_path);old=json.loads(state_path.read_bytes())
        same=old['phase']=='installed' and old['policyHash']==digest(policy) and all(old['files'][n]['installedHash']==digest(inputs[n]) for n in FILES)
        if same:
            for name in FILES:
                secure(TARGET/name)
                if digest((TARGET/name).read_bytes())!=old['files'][name]['installedHash']:raise RuntimeError('Newer administrator edit: '+name)
            if MODULE not in modules():raise RuntimeError('Managed policy module missing; restore then apply')
            known=local_mappings()
            for name,(_,label) in FILES.items():
                if ':'+label+':' not in known.get(mapping(name),''):raise RuntimeError('Managed mapping changed; administrator review required')
                run('restorecon',str(TARGET/name))
            return 'UNCHANGED'
        restore(old)
    known=local_mappings()
    if MODULE in modules():raise RuntimeError('Existing unmanaged policy module')
    if any(re.fullmatch(pattern,str(TARGET/n)) for pattern in known for n in FILES):raise RuntimeError('Existing administrator mapping')
    entries={}
    for name in FILES:
        p=TARGET/name
        info=secure(p) if p.exists() or p.is_symlink() else None
        entries[name]={'original':base64.b64encode(p.read_bytes()).decode() if info else None,'originalMode':stat.S_IMODE(info.st_mode) if info else None,'installedHash':digest(inputs[name])}
    state={'version':1,'phase':'installing','policyHash':digest(policy),'files':entries}
    write_state(state)
    try:
        save(ROOT/(MODULE+'.cil'),policy)
        run('semodule','-i',str(ROOT/(MODULE+'.cil')))
        for name,(mode,label) in FILES.items():
            save(TARGET/name,inputs[name],mode)
            run('semanage','fcontext','-a','-t',label,mapping(name))
            run('restorecon',str(TARGET/name))
        state['phase']='installed';write_state(state)
        return 'INSTALLED'
    except Exception as error:
        try:restore(state)
        except Exception as recovery:raise RuntimeError('ROLLBACK_REQUIRED: '+str(recovery)) from error
        raise RuntimeError('Install failed; original collector restored') from error

def main():
    parser=argparse.ArgumentParser();group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--apply',action='store_true');group.add_argument('--restore',action='store_true')
    parser.add_argument('--payload',type=Path,default=Path(__file__).resolve().parent)
    args=parser.parse_args()
    if os.geteuid()!=0:raise RuntimeError('Root required')
    ROOT.mkdir(mode=0o700,exist_ok=True);parents(ROOT)
    if ROOT.stat().st_mode&0o077:raise RuntimeError('Unsafe state directory')
    TARGET.mkdir(mode=0o755,parents=True,exist_ok=True);parents(TARGET)
    fd=os.open(ROOT/'install.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        secure(ROOT/'install.lock');fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if args.apply:status=apply(args.payload)
        elif (ROOT/'state.json').exists():
            secure(ROOT/'state.json');restore(json.loads((ROOT/'state.json').read_bytes()));status='RESTORED'
        else:status='NOT_INSTALLED'
        print(json.dumps({'status':status,'profile':'confined-process-read','featureReady':False}))
    finally:os.close(fd)

if __name__=='__main__':
    try:main()
    except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired) as error:
        print(json.dumps({'status':'CHECK_FAILED','featureReady':False,'error':str(error)}));raise SystemExit(4)
