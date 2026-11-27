#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
import json,subprocess,uuid,hashlib
from pathlib import Path
def cmd(args):return subprocess.check_output(args,text=True,timeout=15).strip()
os_info=dict(line.split('=',1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
interfaces=[{'ifname':v['ifname'],'mac':v.get('address','').lower(),'admin_up':'UP' in v['flags']} for v in json.loads(cmd(['ip','-j','address'])) if v.get('link_type')=='ether' and v['ifname']!='lo']
root_uuid=cmd(['findmnt','-n','-o','UUID','/'])
os_id=os_info["ID"].strip('"')
configs=[]
active=set()
qga={}
if os_id=='rocky':
 active={line.split(':')[1] for line in cmd(['nmcli','-t','-f','NAME,UUID,TYPE,DEVICE','connection','show','--active']).splitlines() if ':802-3-ethernet:' in line}
 import configparser
 pkg=subprocess.run(['rpm','-q','--qf','%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}','qemu-guest-agent'],text=True,capture_output=True,timeout=15)
 if pkg.returncode==0:
  verified=subprocess.run(['rpm','-V','qemu-guest-agent'],text=True,capture_output=True,timeout=30)
  policy=Path('/etc/sysconfig/qemu-ga')
  qga={'installed':True,'package':pkg.stdout,'rpm_verified':verified.returncode==0,'policy_sha256':hashlib.sha256(policy.read_bytes()).hexdigest() if policy.is_file() else ''}

paths=sorted(Path('/etc/NetworkManager/system-connections').glob('*.nmconnection')) if os_id=='rocky' else sorted(Path('/etc/netplan').glob('*.yaml'))
# A dormant ifcfg file is not the active NetworkManager connection.
# Active profiles must resolve uniquely to captured keyfiles below.
for path in paths:
 content=path.read_text()
 if os_id!='rocky':
  import yaml
  document=yaml.safe_load(content)
 else:document={}
 def check(value):
  if isinstance(value,dict):
   if any(k.lower() in ['password','auth','access-points','private-key','pre-shared-key'] for k in value):raise ValueError('NETWORK_CONFIG_UNSUPPORTED')
   for v in value.values():check(v)
  elif isinstance(value,list):
   for v in value:check(v)
 check(document);item={'path':str(path),'sha256':hashlib.sha256(content.encode()).hexdigest(),'content':content}
 if os_id=='rocky':
  cfg=configparser.ConfigParser(interpolation=None);cfg.read_string(content);item['active']=cfg.get('connection','uuid',fallback='') in active
 configs.append(item)
if os_id=='rocky':
 selected=[item for item in configs if item.get('active')]
 if len(selected)!=len(active) or not active:raise ValueError('NETWORK_CONFIG_UNSUPPORTED')
print(json.dumps({'qga':qga,'configs':configs,'os':'linux' ,'os_id':os_info['ID'].strip('"'),'os_version':os_info['VERSION_ID'].strip('"'),'capture_id':str(uuid.uuid4()),'boot_id':Path('/proc/sys/kernel/random/boot_id').read_text().strip(),'root_fs_uuid':root_uuid,'interfaces':interfaces}))
