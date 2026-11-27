#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Bind PC device IDs to PE data-plane IDs without size/array-order inference."""
import argparse,json,sys
from pathlib import Path

def enrich(m,pe):
 if pe.get('uuid','').lower()!=m['source']['vm']['uuid'].lower():raise ValueError('SOURCE_VM_IDENTITY_MISMATCH')
 data=[d for d in pe.get('vm_disk_info',[]) if not d.get('is_cdrom') and not d.get('is_empty')]
 if len(data)!=len(m['disks']):raise ValueError('SOURCE_DISK_COUNT_CHANGED')
 used=set()
 for d in m['disks']:
  c=d['controller'];matches=[]
  for item in data:
   a=item.get('disk_address',{})
   if a.get('device_uuid') and a['device_uuid'] not in [d['disk_id'],d['device_key']]:continue
   if a.get('device_bus','').lower()!=c['kind'] or int(a.get('device_index',-1))!=int(c['unit']):continue
   if int(item.get('size',-1))!=int(d['size_bytes']):continue
   matches.append(item)
  if len(matches)!=1:raise ValueError('SOURCE_DISK_IDENTITY_AMBIGUOUS')
  item=matches[0];a=item['disk_address'];backing=a.get('vmdisk_uuid','')
  if not backing or backing in used:raise ValueError('SOURCE_VDISK_IDENTITY_AMBIGUOUS')
  used.add(backing);old=d.get('nutanix',{}).get('pe_vdisk_uuid')
  if old and old!=backing:raise ValueError('SOURCE_VDISK_IDENTITY_CHANGED')
  d.setdefault('nutanix',{}).update({'vdisk_uuid':backing,'pe_vdisk_uuid':backing,'pe_device_uuid':a.get('device_uuid',''),'pe_live_path':a.get('ndfs_filepath',''),'storage_container_ext_id':item.get('storage_container_uuid','')})
 m['source']['pe_disk_identity_verified']=True
 return m

def data_index(m,index):
 if not m.get('source',{}).get('pe_disk_identity_verified'):return index
 wanted={d['nutanix']['pe_vdisk_uuid'] for d in m['disks']}
 found=set(index.get('disks',{}))&wanted
 if found!=wanted:raise ValueError('SNAPSHOT_DATA_DISK_IDENTITY_MISSING')
 index['disks']={k:v for k,v in index['disks'].items() if k in wanted};index['disk_count']=len(wanted)
 return index

def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['enrich','filter']);p.add_argument('--manifest',required=True);a=p.parse_args();m=json.loads(Path(a.manifest).read_text());raw=json.load(sys.stdin);print(json.dumps(enrich(m,raw) if a.action=='enrich' else data_index(m,raw)))
if __name__=='__main__':
 try:main()
 except (ValueError,KeyError) as e:print(str(e),file=sys.stderr);sys.exit(44)
