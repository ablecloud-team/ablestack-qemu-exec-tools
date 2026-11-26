#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Observe prepared network configuration without network access or arbitrary RPC."""
import hashlib,ipaddress,json,os,subprocess,time,uuid
from pathlib import Path

ROOT=Path('/var/lib/ablestack-v2k/guest-config')
def command(args):return subprocess.check_output(args,text=True,timeout=15).strip()
def atomic(name,value):
    path=ROOT/name;temp=path.with_suffix('.tmp');temp.write_text(json.dumps(value,separators=(',',':')));temp.chmod(0o600);temp.replace(path)
def binding(plan):
    path=ROOT/('binding-'+plan['operation_id']+'.json');commit=path.with_suffix('.commit')
    if not path.exists() or not commit.exists():return None,None
    data=path.read_bytes();check=json.loads(commit.read_text());sha=hashlib.sha256(data).hexdigest()
    if check.get('sha256')!=sha or check.get('bytes')!=len(data) or len(data)>65536:return None,None
    value=json.loads(data)
    if value.get('operation_id')!=plan['operation_id'] or value.get('plan_hash')!=plan['hash'] or value.get('source_vm_uuid')!=plan['source_vm_uuid']:raise ValueError('GUEST_BINDING_MISMATCH')
    actual=str(uuid.UUID(Path('/sys/class/dmi/id/product_uuid').read_text().strip()))
    if actual!=str(uuid.UUID(value['vm_uuid'])):raise ValueError('GUEST_VM_IDENTITY_MISMATCH')
    if 'fs:'+command(['findmnt','-n','-o','UUID','/']).lower()!=plan['root_identity'].lower():raise ValueError('ROOT_IDENTITY_MISMATCH')
    return value,sha
def observe(plan,bind):
    actual={v['ifname']:v for v in json.loads(command(['ip','-j','address']))};macs={n['mac'].lower() for n in bind['nics']};result=[]
    routes=json.loads(command(['ip','-j','-4','route','show','table','all']))+json.loads(command(['ip','-j','-6','route','show','table','all']))
    for want in plan['network']['interfaces']:
        name=want['ifname'];item=actual.get(name)
        if item is None or item.get('address','').lower()!=want['mac'] or want['mac'] not in macs or 'UP' not in item['flags']:raise ValueError('NIC_CONFIGURATION_MISMATCH')
        cfg=want['config'];addresses={a['local']+'/'+str(a['prefixlen']) for a in item['addr_info']};global_addresses=[a for a in item['addr_info'] if a.get('scope')=='global']
        if not all(str(ipaddress.ip_interface(a)) in addresses for a in cfg.get('addresses',[])):raise ValueError('NIC_STATIC_ADDRESS_MISMATCH')
        for version in [4,6]:
            if cfg.get('dhcp'+str(version)) and not any(a['family']==('inet' if version==4 else 'inet6') and (a.get('dynamic') or a.get('valid_life_time',4294967295)!=4294967295) for a in global_addresses):raise ValueError('NIC_DHCP_LEASE_PENDING')
        if cfg.get('mtu') and item['mtu']!=cfg['mtu']:raise ValueError('NIC_MTU_MISMATCH')
        for route in cfg.get('routes',[]):
            if not any(v.get('dev')==name and v.get('dst','default')==route['to'] and (not route.get('via') or v.get('gateway')==route['via']) for v in routes):raise ValueError('NIC_ROUTE_MISMATCH')
        nameservers=cfg.get('nameservers',{})
        if nameservers:
            if want['renderer']=='networkd':dns=command(['resolvectl','dns',name]);domains=command(['resolvectl','domain',name])
            else:dns=command(['nmcli','-g','IP4.DNS,IP6.DNS','device','show',name]);domains=command(['nmcli','-g','IP4.DOMAIN,IP6.DOMAIN','device','show',name])
            if not all(value in dns.split() for value in nameservers.get('addresses',[])) or not all(value in domains.split() for value in nameservers.get('search',[])):raise ValueError('NIC_DNS_MISMATCH')
        result.append({'mac':want['mac'],'ifname':name,'addresses':sorted(addresses),'mtu':item['mtu'],'status':'VERIFIED'})
    return {'status':'VERIFIED','interfaces':result}
def main():
    plan=json.loads((ROOT/'plan.json').read_text());assert hashlib.sha256(Path(__file__).read_bytes()).hexdigest()==plan['helper_sha256'];boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip();deadline=time.monotonic()+600;last='';verified=False
    while time.monotonic()<deadline:
        bind=None;sha=None
        try:
            bind,sha=binding(plan)
            if bind is None:time.sleep(2);continue
            if sha==last and verified:time.sleep(2);continue
            net=observe(plan,bind);report={'version':1,'operation_id':plan['operation_id'],'plan_hash':plan['hash'],'vm_uuid':bind['vm_uuid'],'binding_sha256':sha,'boot_scope':bind['boot_scope'],'boot_id':boot,'root_identity':plan['root_identity'],'helper_sha256':plan['helper_sha256'],'status':'VERIFIED','network':net,'windows':{'status':'NOT_APPLICABLE'},'mutations':[]}
            atomic('report.json',report);atomic('journal.json',{'version':1,'operation_id':plan['operation_id'],'verified':True,'plan_hash':plan['hash']});last=sha;verified=True
        except Exception as error:
            if bind is not None:
                atomic('report.json',{'version':1,'operation_id':plan['operation_id'],'plan_hash':plan['hash'],'vm_uuid':bind['vm_uuid'],'binding_sha256':sha,'boot_scope':bind['boot_scope'],'boot_id':boot,'root_identity':plan['root_identity'],'status':'PENDING' if not verified else 'DRIFT','reason':str(error) if isinstance(error,ValueError) else type(error).__name__})
            time.sleep(2)
if __name__=='__main__':main()
