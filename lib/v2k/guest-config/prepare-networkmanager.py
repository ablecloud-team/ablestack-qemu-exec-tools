#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Apply the bound source's active keyfile once; preserve later user changes."""
import configparser,hashlib,importlib.util,json,os,re,subprocess,time
from pathlib import Path
ROOT=Path('/var/lib/ablestack-v2k/guest-config')
def digest(data):return hashlib.sha256(data).hexdigest()
def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True)
def run(args):return subprocess.check_output(args,text=True,timeout=35).strip()
def keyfile(text):
 p=configparser.ConfigParser(interpolation=None,delimiters=('=',),strict=True);p.optionxform=str;p.read_string(text)
 out={s:dict(p[s]) for s in p.sections()};out.get('connection',{}).pop('timestamp',None);return out

def retired_ifcfg(text,mac,name):
 if '# Created by cloud-init automatically' not in text:raise ValueError('INACTIVE_IFCFG_REQUIRES_REVIEW')
 values={}
 for line in text.splitlines():
  if not line.strip() or line.lstrip().startswith('#'):continue
  if not re.fullmatch(r'[A-Z0-9_]+=[A-Za-z0-9_.:/-]+',line):raise ValueError('INACTIVE_IFCFG_REQUIRES_REVIEW')
  key,value=line.split('=',1)
  if key in values:raise ValueError('INACTIVE_IFCFG_REQUIRES_REVIEW')
  values[key]=value
 if set(values)-{'AUTOCONNECT_PRIORITY','BOOTPROTO','DEVICE','DHCPV6C','HWADDR','IPV6INIT','ONBOOT','TYPE','USERCTL'} or values.get('BOOTPROTO')!='dhcp' or values.get('TYPE')!='Ethernet' or values.get('DEVICE')!=name or values.get('HWADDR','').lower()!=mac or values.get('ONBOOT') not in ['yes','no']:
  raise ValueError('INACTIVE_IFCFG_REQUIRES_REVIEW')
 return re.sub(r'^ONBOOT=yes$', 'ONBOOT=no',text,flags=re.M)

def write(path,data):
 path.parent.mkdir(parents=True,exist_ok=True);temp=path.with_name(path.name+'.n2k-network-tmp')
 if path.is_symlink() or temp.is_symlink():raise ValueError('NETWORK_CONFIG_OWNERSHIP_CONFLICT')
 with temp.open('wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
 temp.chmod(0o600);temp.replace(path)

def main():
 plan=json.loads((ROOT/'plan.json').read_text())
 if plan.get('os')!='linux' or plan.get('network',{}).get('adapter')!='networkmanager-keyfile':return
 unsigned=dict(plan);unsigned.pop('hash',None)
 if digest(canonical(unsigned).encode())!=plan['hash']:raise ValueError('GUEST_CONFIG_PLAN_HASH_MISMATCH')
 if plan.get('network_preparer_sha256') and digest(Path(__file__).read_bytes())!=plan['network_preparer_sha256']:raise ValueError('GUEST_NETWORK_HELPER_HASH_MISMATCH')
 journal=ROOT/'journal.json'
 if journal.exists():
  j=json.loads(journal.read_text())
  if j.get('verified') and j.get('operation_id')==plan['operation_id'] and j.get('plan_hash')==plan['hash']:return
 spec=importlib.util.spec_from_file_location('bound_guest',ROOT/'helper.py');helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
 if digest((ROOT/'helper.py').read_bytes())!=plan['helper_sha256']:raise ValueError('GUEST_HELPER_HASH_MISMATCH')
 deadline=time.monotonic()+90;bind=None
 while time.monotonic()<deadline:
  bind,_=helper.binding(plan)
  if bind:break
  time.sleep(1)
 if not bind:raise ValueError('GUEST_BINDING_PENDING')
 nics=json.loads(run(['ip','-j','address']));mapping={n['ifname']:n.get('address','').lower() for n in nics}
 state_path=ROOT/'network-preparation.json';state=json.loads(state_path.read_text()) if state_path.exists() else {'version':1,'operation_id':plan['operation_id'],'plan_hash':plan['hash'],'files':{}}
 if state.get('operation_id')!=plan['operation_id'] or state.get('plan_hash')!=plan['hash']:raise ValueError('NETWORK_CONFIG_OWNERSHIP_CONFLICT')
 for nic in plan['network']['interfaces']:
  name=nic['ifname'];mac=nic['mac'];uid=nic['profile_uuid']
  if mapping.get(name)!=mac or mac not in {n['mac'].lower() for n in bind['nics']}:raise ValueError('NIC_MAPPING_AMBIGUOUS')
  expected=[f for f in plan['network']['files'] if keyfile(f['content']).get('connection',{}).get('uuid')==uid]
  if len(expected)!=1:raise ValueError('NIC_MAPPING_AMBIGUOUS')
  path=Path(expected[0]['path'])
  if path.is_symlink() or keyfile(path.read_text())!=keyfile(expected[0]['content']):raise ValueError('NETWORK_CONFIG_OWNERSHIP_CONFLICT')
  for file in Path('/etc/sysconfig/network-scripts').glob('ifcfg-*'):
   text=file.read_text()
   if not re.search(r'^HWADDR='+re.escape(mac)+r'$',text,re.M|re.I):continue
   after=retired_ifcfg(text,mac,name);key=str(file)
   if key in state['files']:
    if digest(file.read_bytes()) not in [state['files'][key]['before_sha256'],state['files'][key]['after_sha256']]:raise ValueError('NETWORK_CONFIG_OWNERSHIP_CONFLICT')
   elif after!=text:
    backup=ROOT/'backup'/('inactive-'+file.name)
    if backup.exists() and backup.read_text()!=text:raise ValueError('NETWORK_BACKUP_OWNERSHIP_CONFLICT')
    write(backup,text.encode());state['files'][key]={'before_sha256':digest(text.encode()),'after_sha256':digest(after.encode()),'backup':str(backup)};write(state_path,canonical(state).encode())
   if after!=text:write(file,after.encode())
  run(['nmcli','connection','reload'])
  actual=run(['nmcli','-g','GENERAL.CON-UUID','device','show',name])
  if actual!=uid:run(['nmcli','connection','up','uuid',uid,'ifname',name])
 state['applied']=True;write(state_path,canonical(state).encode())
if __name__=='__main__':main()
