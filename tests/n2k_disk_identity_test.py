#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'lib/n2k'))
from nutanix_disk_identity import enrich,data_index
class IdentityTest(unittest.TestCase):
 def setUp(self):
  self.m={'source':{'vm':{'uuid':'vm-1'}},'disks':[{'disk_id':'device-'+str(i),'device_key':'device-'+str(i),'size_bytes':8192,'controller':{'kind':'ide','unit':i}} for i in range(2)]}
  self.pe={'uuid':'vm-1','vm_disk_info':[{'size':8192,'disk_address':{'device_uuid':'device-'+str(i),'device_bus':'ide','device_index':i,'vmdisk_uuid':'backing-'+str(i)}} for i in [1,0]]+[{'is_cdrom':True,'size':8192,'disk_address':{'vmdisk_uuid':'iso'}}]}
 def test_equal_size_reordered_disks_use_stable_device_and_controller_identity(self):
  out=enrich(self.m,self.pe);self.assertEqual([d['nutanix']['pe_vdisk_uuid'] for d in out['disks']],['backing-0','backing-1'])
 def test_size_mismatch_blocks(self):
  self.pe['vm_disk_info'][0]['size']=4096
  with self.assertRaises(ValueError):enrich(self.m,self.pe)
 def test_wrong_source_vm_blocks(self):
  self.pe['uuid']='another'
  with self.assertRaises(ValueError):enrich(self.m,self.pe)
 def test_changed_backing_blocks(self):
  enrich(self.m,self.pe);self.pe['vm_disk_info'][0]['disk_address']['vmdisk_uuid']='changed'
  with self.assertRaises(ValueError):enrich(self.m,self.pe)
 def test_snapshot_auxiliary_files_excluded_before_nfs_mount(self):
  m=enrich(self.m,self.pe);out=data_index(m,{'disks':{k:{} for k in ['backing-1','iso','backing-0']}});self.assertEqual(set(out['disks']),{'backing-0','backing-1'})
 def test_missing_snapshot_disk_never_falls_back_by_size(self):
  m=enrich(self.m,self.pe)
  with self.assertRaises(ValueError):data_index(m,{'disks':{'backing-0':{},'iso':{}}})
class WholeFilesystemTest(unittest.TestCase):
 def test_linux_whole_data_filesystem_does_not_require_a_partition_table(self):
  sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'lib/v2k'))
  from guest_configuration_disk import Disk
  disk=Disk('/unused')
  values={'vfs-type':'ext4','vfs-uuid':'data-uuid'}
  disk.call=lambda method,*args:values[method]
  self.assertEqual(disk.inspect(True),{'identity':'fs:data-uuid','partitions':[],'filesystem':'ext4'})
if __name__=='__main__':unittest.main()
