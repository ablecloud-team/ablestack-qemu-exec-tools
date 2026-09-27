#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
import sys,json,base64
from pathlib import Path
from action_policy import ROOT,TARGET,FILES,ensure_directory,secure,save,digest
if __name__=='__main__':
 import os
 if os.geteuid()!=0:raise SystemExit(2)
 payload=Path(sys.argv[1]);ensure_directory(ROOT,0o700);ensure_directory(TARGET,0o755)
 state_path=ROOT/'plain-state.json'
 old=json.loads(state_path.read_text()) if state_path.exists() else {'files':{}}
 for name,(mode,_) in FILES.items():
  p=TARGET/name
  if p.exists():secure(p)
  if name in old['files'] and p.exists() and digest(p.read_bytes())!=old['files'][name]['installedHash']:raise RuntimeError('Administrator edit')
  if name not in old['files']:old['files'][name]={'original':base64.b64encode(p.read_bytes()).decode() if p.exists() else None}
  old['files'][name]['installedHash']=digest((payload/name).read_bytes())
 save(state_path,old)
 for name,(mode,_) in FILES.items():save(TARGET/name,(payload/name).read_bytes(),mode)
 ensure_directory(Path('/var/lib/ablestack-process-actions'),0o700)
 print('INSTALLED; action journal preserved')
