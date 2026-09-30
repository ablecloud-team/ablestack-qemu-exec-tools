#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
import sys,json,base64,fcntl,os,stat,copy
from pathlib import Path
from action_policy import ROOT,TARGET,FILES,ensure_directory,secure,save,digest

def apply(payload):
 state_path=ROOT/'plain-state.json'
 if state_path.exists():secure(state_path)
 old=json.loads(state_path.read_text()) if state_path.exists() else {'phase':'installed','files':{}}
 prior=copy.deepcopy(old)
 before={}
 for name,(mode,_) in FILES.items():
  p=TARGET/name
  if p.exists() or p.is_symlink():secure(p)
  data=p.read_bytes() if p.exists() else None
  entry=old['files'].get(name)
  if entry and data is not None:
   allowed={entry['installedHash']}
   if old['phase']!='installed' and entry['original'] is not None:allowed.add(digest(base64.b64decode(entry['original'])))
   if digest(data) not in allowed:raise RuntimeError('Administrator edit')
  before[name]=(data,stat.S_IMODE(p.stat().st_mode) if data is not None else mode)
  if entry is None:old['files'][name]={'original':base64.b64encode(data).decode() if data is not None else None,'originalMode':before[name][1]}
  old['files'][name]['installedHash']=digest((payload/name).read_bytes())
 old['phase']='installing';save(state_path,json.dumps(old,sort_keys=True).encode())
 try:
  for name,(mode,_) in FILES.items():save(TARGET/name,(payload/name).read_bytes(),mode)
  ensure_directory(Path('/var/lib/ablestack-process-actions'),0o700)
  old['phase']='installed';save(state_path,json.dumps(old,sort_keys=True).encode())
 except Exception:
  for name,(data,mode) in before.items():
   if data is None:(TARGET/name).unlink(missing_ok=True)
   else:save(TARGET/name,data,mode)
  save(state_path,json.dumps(prior,sort_keys=True).encode());raise
 return 'INSTALLED; action journal preserved'
if __name__=='__main__':
 if os.geteuid()!=0:raise SystemExit(2)
 payload=Path(sys.argv[1]);ensure_directory(ROOT,0o700);ensure_directory(TARGET,0o755)
 fd=os.open(ROOT/'install.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
 try:
  secure(ROOT/'install.lock');fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);print(apply(payload))
 finally:os.close(fd)
