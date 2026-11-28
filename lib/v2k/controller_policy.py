#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Versioned source identity and target disk-driver policy. Standard library only."""
import argparse
import copy
import hashlib
import json
import re
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

VERSION=1
DETAIL='migration.disk.controller.plan'

def fail(message):
    raise ValueError('DISK_CONTROLLER_POLICY: '+message)

def kind(value):
    v=str(value or '').lower()
    if 'sata' in v or 'ahci' in v:return 'sata'
    if 'ide' in v:return 'ide'
    if any(x in v for x in ['scsi','lsilogic','buslogic','paravirtual']):return 'scsi'
    return 'unknown'

def letter(index):
    value='';index+=1
    while index:
        index,digit=divmod(index-1,26);value=chr(97+digit)+value
    return value

def select_inventory(document,root_id=''):
    d=copy.deepcopy(document);disks=d.get('disks',[])
    if not disks:fail('source has no disks')
    ids=[str(x.get('disk_id','')) for x in disks]
    keys=[str(x.get('device_key','')) for x in disks]
    if any(not x for x in ids+keys) or len(set(ids))!=len(ids) or len(set(keys))!=len(keys):fail('source disk IDs and device keys must be unique')
    addresses=[]
    for x in disks:
        c=x.setdefault('controller',{});k=kind(c.get('kind') or c.get('type'));c['kind']=k
        if k=='unknown':fail('source controller unknown for '+str(x['disk_id']))
        if not re.fullmatch(k+r'\d+:\d+',x['disk_id']):fail('source controller address does not match disk identity')
        addresses.append((k,c.get('bus'),c.get('unit')))
    if len(set(addresses))!=len(addresses):fail('duplicate source controller address')
    evidence=d.get('controller_plan',{})
    boot_keys=[str(x) for x in evidence.get('boot_device_keys',[])]
    if root_id:
        matches=[x for x in disks if root_id in [str(x['disk_id']),str(x['device_key'])]]
        selection='operator'
    elif boot_keys:
        matches=[x for k in boot_keys for x in disks if str(x['device_key'])==k][:1]
        selection='explicit_boot_device'
        if not matches:fail('explicit source boot disk is absent; select --root-disk-id')
    else:
        matches=[x for x in disks if re.fullmatch(r'[Hh]ard disk 1',str(x.get('label','')))]
        selection='source_disk_label'
        if len(matches)!=1:
            kinds={x['controller']['kind'] for x in disks}
            if len(disks)==1:matches=disks;selection='single_disk'
            elif len(kinds)==1:
                candidates=sorted(disks,key=lambda x:(int(x['controller'].get('bus',0)),int(x['controller'].get('unit',0))))
                matches=candidates[:1];selection='controller_address_inferred'
            else:fail('mixed-controller boot disk ambiguous; select --root-disk-id')
    if len(matches)!=1:fail('root selector must match exactly one stable disk ID or device key')
    root=matches[0];ordered=[root]+[x for x in disks if x is not root]
    for index,x in enumerate(ordered):x['role']='root' if index==0 else 'data'
    d['disks']=ordered
    d['controller_plan']={'version':VERSION,'status':'passed','root_selection':selection,'root':{'disk_id':root['disk_id'],'device_key':str(root['device_key'])},'boot_device_keys':boot_keys}
    return d

def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True)
def digest(value):return hashlib.sha256(canonical(value).encode()).hexdigest()

def build(manifest,policy='auto'):
    if policy not in ['auto','sata','virtio-scsi','preserve']:fail('unknown target driver policy')
    source=[]
    for i,x in enumerate(manifest['disks']):
        c=x['controller'];source.append({'index':i,'disk_id':x['disk_id'],'device_key':str(x.get('device_key','')),'kind':c['kind'],'bus':int(c.get('bus',0)),'unit':int(c.get('unit',0)),'size_bytes':int(x['size_bytes']),'role':'root' if i==0 else 'data'})
    if not source or any(x['kind'] not in ['ide','sata','scsi'] for x in source):fail('unsupported source controller')
    if policy=='preserve' and any(x['kind']!='sata' for x in source):
        fail('preserve requires a qualified native controller model; version 1 supports native SATA only, use auto or an explicit conversion')
    mapped=[('sata' if x['kind'] in ['ide','sata'] else 'scsi') if policy=='auto' else ('scsi' if policy=='virtio-scsi' else 'sata') for x in source]
    if len(set(mapped[1:]))>1:mapped[1:]=['scsi']*len(mapped[1:])
    disks=[dict(x,target={'bus':mapped[i],'model':'virtio-scsi' if mapped[i]=='scsi' else 'ahci','device':'sd'+letter(i)}) for i,x in enumerate(source)]
    plan={'version':VERSION,'policy':policy,'machine':'q35','firmware':manifest.get('source',{}).get('vm',{}).get('firmware') or 'bios','root_selection':manifest.get('source',{}).get('controller_plan',{}).get('root_selection','legacy'),'source_vm_uuid':manifest.get('source',{}).get('vm',{}).get('uuid',''),'disks':disks}
    if plan['firmware'] not in ['bios','efi']:fail('unsupported source firmware')
    plan['hash']=digest(plan)
    return plan

def verify(manifest):
    plan=manifest.get('target',{}).get('disk_controller_plan')
    if not plan:return None
    if plan!=build(manifest,plan.get('policy')):fail('frozen source identity or target driver policy changed; use a new workdir')
    return plan

def prepare(manifest,policy='auto'):
    d=copy.deepcopy(manifest);old=d.get('target',{}).get('disk_controller_plan')
    if old:
        verify(d)
        if policy!=old['policy']:fail('target controller policy already frozen')
        return d
    plan=build(d,policy);d.setdefault('target',{})['disk_controller_plan']=plan
    effective={'root':plan['disks'][0]['target']['bus'],'data':plan['disks'][1]['target']['bus'] if len(plan['disks'])>1 else ''}
    d['target'].setdefault('cloud',{})['disk_controller_plan']={'status':'passed','version':VERSION,'source':{'root':plan['disks'][0]['kind'],'data_kinds':sorted({x['kind'] for x in plan['disks'][1:]})},'effective':effective,'contract_hash':plan['hash'],'override_reason':'versioned_driver_policy'}
    return d

def validate_xml(manifest,xml):
    plan=verify(manifest)
    if not plan:return
    tree=ET.fromstring(xml);typ=tree.find('./os/type')
    if typ is None or 'q35' not in typ.get('machine',''):fail('final machine differs from planned q35')
    disks=[x for x in tree.findall('./devices/disk') if x.get('device')=='disk']
    if len(disks)!=len(plan['disks']):fail('final disk count differs')
    for item,expected,actual in zip(manifest['disks'],plan['disks'],disks):
        target=actual.find('target');driver=actual.find('driver');src=actual.find('source')
        if target is None or target.get('bus')!=expected['target']['bus'] or target.get('dev')!=expected['target']['device']:fail('final target disk bus/device differs')
        fmt=manifest['target'].get('format','qcow2') if manifest['target']['storage']['type']=='file' else 'raw'
        if driver is None or driver.get('type')!=fmt:fail('final disk image format differs')
        path=item['transfer']['target_path']
        if manifest['target']['storage']['type']=='file' and (src is None or src.get('file')!=path):fail('final disk path differs')
    for bus in {x['target']['bus'] for x in plan['disks']}:
        if not any(x.get('type')==bus and (bus!='scsi' or x.get('model')=='virtio-scsi') for x in tree.findall('./devices/controller')):fail('final controller model missing')

def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['inventory','prepare','validate','params','disk','xml']);p.add_argument('--manifest');p.add_argument('--root',default='');p.add_argument('--policy',default='auto');p.add_argument('--index',type=int,default=0);p.add_argument('--xml');a=p.parse_args()
    if a.action=='inventory':value=select_inventory(json.load(sys.stdin),a.root)
    else:
        path=Path(a.manifest);d=json.loads(path.read_text())
        if a.action=='prepare':value=prepare(d,a.policy)
        elif a.action=='validate':verify(d);return
        elif a.action=='params':
            plan=verify(d);value={} if not plan else {**({'details[0].UEFI':'SECURE' if d.get('source',{}).get('vm',{}).get('secure_boot') else 'LEGACY'} if plan['firmware']=='efi' else {'details[0].BIOS':'LEGACY'}),'details[0].'+DETAIL:canonical(plan),'details[0].kvm.guest.os.machine.type':plan['machine'],'details[0].rootDiskController':plan['disks'][0]['target']['bus'],**({'details[0].dataDiskController':plan['disks'][1]['target']['bus']} if len(plan['disks'])>1 else {})}
            vm=d.get('source',{}).get('vm',{})
            if plan and (d.get('source',{}).get('guest_configuration',{}).get('os')=='windows' or vm.get('guestFamily')=='windowsGuest' or str(vm.get('guest_id','')).lower().startswith('win')):
                value.update({'details[0].kvm.pcie.topology.profile':'q35-windows-16-v1','details[0].kvm.pcie.topology.version':'1'})
        elif a.action=='disk':value=verify(d)['disks'][a.index]['target']
        elif a.action=='xml':validate_xml(d,Path(a.xml).read_text());return
    print(json.dumps(value,separators=(',',':'),ensure_ascii=True))

if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,IndexError) as error:print(str(error),file=sys.stderr);sys.exit(44)
