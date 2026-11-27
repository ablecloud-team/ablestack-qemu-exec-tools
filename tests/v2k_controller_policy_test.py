#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Controller source identity, immutable driver policy and actual XML contract."""
import copy
import importlib.util
import json
import os
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('controller_policy',ROOT/'lib/v2k/controller_policy.py');policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)

def inventory(kinds=('scsi','scsi'),labels=True):
    counts={};disks=[]
    types={'ide':'VirtualIDEController','sata':'VirtualAHCIController','scsi':'VirtualLsiLogicSASController'}
    for i,k in enumerate(kinds):
        unit=counts.get(k,0);counts[k]=unit+1
        disks.append({'disk_id':k+'0:'+str(unit),'device_key':str(2000+i),'label':'Hard disk '+str(i+1) if labels else 'custom','size_bytes':1073741824,'controller':{'kind':k,'type':types[k],'bus':0,'unit':unit},'transfer':{'target_path':'/fixture/disk'+str(i)+'.raw'}})
    return {'vm':{'name':'fixture','uuid':'source-uuid','firmware':'bios','nics':[]},'disks':disks}

def manifest(kinds=('scsi','scsi'),mode='auto'):
    inv=policy.select_inventory(inventory(kinds))
    m={'source':{'vm':inv['vm'],'controller_plan':inv['controller_plan']},'disks':inv['disks'],'target':{'provider':'libvirt','format':'raw','storage':{'type':'file'},'libvirt':{'name':'fixture'}}}
    return policy.prepare(m,mode)

class ControllerPolicy(unittest.TestCase):
    def test_all_source_controllers_and_policies(self):
        for source,target in [('ide','sata'),('sata','sata'),('scsi','scsi')]:
            p=manifest((source,source))['target']['disk_controller_plan']
            self.assertEqual({d['target']['bus'] for d in p['disks']},{target});self.assertEqual({d['kind'] for d in p['disks']},{source})
            for mode,bus in [('sata','sata'),('virtio-scsi','scsi')]:self.assertEqual({d['target']['bus'] for d in manifest((source,source),mode)['target']['disk_controller_plan']['disks']},{bus})
        self.assertEqual(manifest(('sata',),'preserve')['target']['disk_controller_plan']['disks'][0]['target']['model'],'ahci')
        for source in ['ide','scsi']:
            with self.assertRaises(ValueError):manifest((source,),'preserve')
    def test_ambiguous_boot_requires_stable_selector(self):
        inv=inventory(('ide','scsi'),False)
        with self.assertRaises(ValueError):policy.select_inventory(inv)
        chosen=policy.select_inventory(inv,'2001');self.assertEqual(chosen['disks'][0]['disk_id'],'scsi0:0');self.assertEqual(chosen['controller_plan']['root_selection'],'operator')
        inv['controller_plan']={'boot_device_keys':['2001']};self.assertEqual(policy.select_inventory(inv)['disks'][0]['device_key'],'2001')
        inv['controller_plan']['boot_device_keys']=['9999']
        with self.assertRaises(ValueError):policy.select_inventory(inv)
    def test_source_identity_rejects_missing_duplicate_or_unknown(self):
        for change in [lambda d:d[1].update(device_key=d[0]['device_key']),lambda d:d[1].update(disk_id=d[0]['disk_id']),lambda d:d[0].update(controller={}),lambda d:d[0].update(disk_id='nvme0:0')]:
            inv=inventory();change(inv['disks'])
            with self.assertRaises(ValueError):policy.select_inventory(inv)
    def test_mixed_data_has_one_explicit_target_bus(self):
        m=manifest(('ide','sata','scsi'));plan=m['target']['disk_controller_plan']
        self.assertEqual([d['target']['bus'] for d in plan['disks']],['sata','scsi','scsi'])
        self.assertEqual(m['target']['cloud']['disk_controller_plan']['source']['data_kinds'],['sata','scsi'])
    def test_resume_freezes_policy_root_and_geometry(self):
        m=manifest();before=copy.deepcopy(m);self.assertEqual(policy.prepare(m),before)
        for mutate in [lambda x:x['disks'].reverse(),lambda x:x['disks'][0].update(size_bytes=2147483648),lambda x:x['disks'][0]['controller'].update(kind='sata')]:
            bad=copy.deepcopy(m);mutate(bad)
            with self.assertRaises(ValueError):policy.verify(bad)
        with self.assertRaises(ValueError):policy.prepare(m,'sata')
    def test_device_names_are_bijective(self):
        self.assertEqual([policy.letter(i) for i in [0,25,26,51,52,255]],['a','z','aa','az','ba','iv'])
    def test_real_renderer_preserves_raw_and_driver_policy(self):
        for kinds in [('ide','ide'),('sata','sata'),('scsi','scsi'),('ide','sata','scsi')]:
            with tempfile.TemporaryDirectory() as tmp:
                p=Path(tmp)/'manifest.json';m=manifest(kinds);p.write_text(json.dumps(m))
                script='source "$1/lib/v2k/controller_policy.sh"; source "$1/lib/v2k/target_libvirt.sh"; _v2k_detect_main_bridge() { :; }; export V2K_WORKDIR="$2"; v2k_target_generate_libvirt_xml "$2/manifest.json"'
                result=subprocess.run(['bash','-euo','pipefail','-c',script,'test',str(ROOT),tmp],capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr);xml=Path(result.stdout.strip()).read_text();policy.validate_xml(m,xml)
                with self.assertRaises(ValueError):policy.validate_xml(m,xml.replace("type='raw'","type='qcow2'"))
                with self.assertRaises(ValueError):policy.validate_xml(m,xml.replace("bus='sata'","bus='ide'").replace("bus='scsi'","bus='ide'"))
    def test_public_parameters_include_canonical_intent(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'manifest.json';p.write_text(json.dumps(manifest(('ide','scsi'))))
            result=subprocess.run(['python3',str(ROOT/'lib/v2k/controller_policy.py'),'params','--manifest',str(p)],capture_output=True,text=True,check=True)
            params=json.loads(result.stdout);plan=json.loads(params['details[0].migration.disk.controller.plan'])
            self.assertEqual(params['details[0].rootDiskController'],'sata');self.assertEqual(params['details[0].dataDiskController'],'scsi');self.assertEqual(plan['disks'][0]['kind'],'ide')
            self.assertEqual(params['details[0].kvm.guest.os.machine.type'],'q35')
            self.assertEqual(params['details[0].BIOS'],'LEGACY')
            for secure in [False,True]:
                m=manifest(('sata','sata'));m['source']['vm'].update(firmware='efi',secure_boot=secure);m['target'].pop('disk_controller_plan');m=policy.prepare(m);p.write_text(json.dumps(m))
                result=subprocess.run(['python3',str(ROOT/'lib/v2k/controller_policy.py'),'params','--manifest',str(p)],capture_output=True,text=True,check=True)
                self.assertEqual(json.loads(result.stdout)['details[0].UEFI'],'SECURE' if secure else 'LEGACY')


    def test_windows_selects_compatible_q35_profile_before_first_start(self):
        for family,guest_id in [('windowsGuest',''),('', 'windows2019srv_64Guest')]:
            with tempfile.TemporaryDirectory() as tmp:
                m=manifest(('scsi','scsi'));m['source']['vm'].update(guestFamily=family,guest_id=guest_id)
                p=Path(tmp)/'manifest.json';p.write_text(json.dumps(m))
                result=subprocess.run(['python3',str(ROOT/'lib/v2k/controller_policy.py'),'params','--manifest',str(p)],capture_output=True,text=True,check=True)
                values=json.loads(result.stdout)
                self.assertEqual(values['details[0].kvm.pcie.topology.profile'],'q35-windows-16-v1')
                self.assertEqual(values['details[0].kvm.pcie.topology.version'],'1')
                self.assertEqual(values['details[0].rootDiskController'],'scsi')

    def test_wizard_real_driver_menu_and_explicit_policy_forwarding(self):
        sys.path.insert(0,str(ROOT/'tests'))
        import image_preallocation_test as image_tests
        fixture=image_tests.Preallocation();fixture.setUp()
        try:
            for answer,expected in [('\n','auto'),('sata\n','sata'),('virtio-scsi\n','virtio-scsi'),('preserve\n','preserve')]:
                result,args,_=fixture.wizard('v2k',('--target-preallocation','falloc'),tty='1',selection=answer)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('target disk driver policy:',result.stderr)
                self.assertEqual(args[args.index('--target-disk-controller')+1],expected)
            result,args,_=fixture.wizard('v2k',('--yes','--target-preallocation','falloc','--target-disk-controller','virtio-scsi','--root-disk-id','2000'))
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(args[args.index('--root-disk-id')+1],'2000')
            self.assertEqual(args[args.index('--target-disk-controller')+1],'virtio-scsi')
        finally:fixture.doCleanups()

    def test_wizard_ambiguous_root_is_selected_before_target_filenames(self):
        sys.path.insert(0,str(ROOT/'tests'))
        import image_preallocation_test as image_tests
        for interactive in [False,True]:
            with tempfile.TemporaryDirectory() as tmp:
                source=inventory(('ide','scsi'),False);source['vm']['nics']=[{'mac':'52:54:00:12:34:56','label':'nic0'}]
                env={**os.environ,'REPO':str(ROOT),'TOOL':'v2k','CASE_DIR':tmp,'TEST_TTY':'1' if interactive else '0','CANCEL':'0','INVENTORY':json.dumps(source)}
                args=['--target-disk-cache','none','--guest-config-policy','off','--vm','fixture','--vcenter','source.invalid','--username','fixture-user','--password','fixture-secret','--target-profile','cloud-filesystem','--split','phase1','--dst',tmp+'/target','--target-preallocation','falloc','--cloud-endpoint','https://cloud.invalid','--cloud-api-key','fixture-key','--cloud-secret-key','fixture-cloud-secret','--cloud-zone-id','zone','--cloud-service-offering-id','offering','--cloud-network-id','network','--cloud-storage-id','pool','--cloud-name','fixture-target']
                if not interactive:args+=['--yes']
                result=subprocess.run(['bash','-euo','pipefail','-c',image_tests.WIZARD,'test',*args],input='2\nvirtio-scsi\n',env=env,capture_output=True,text=True)
                captured=Path(tmp)/'captured'
                if not interactive:
                    self.assertEqual(result.returncode,44,result.stderr);self.assertFalse(captured.exists());continue
                self.assertEqual(result.returncode,0,result.stderr)
                argv=captured.read_bytes().decode().rstrip('\0').split('\0')
                self.assertEqual(argv[argv.index('--root-disk-id')+1],'scsi0:0')
                self.assertEqual(argv[argv.index('--target-disk-controller')+1],'virtio-scsi')
                mapping=json.loads(argv[argv.index('--target-map-json')+1])
                self.assertTrue(mapping['scsi0:0'].endswith('-disk0.qcow2'))
                self.assertTrue(mapping['ide0:0'].endswith('-disk1.qcow2'))

    def test_base_and_patch_share_runtime_credentials_without_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'manifest.json';p.write_text('{"source":{"vddk":{}}}')
            script='source "$1/lib/v2k/transfer_base.sh"; source "$1/lib/v2k/transfer_patch.sh"; export GOVC_USERNAME=fixture GOVC_PASSWORD=runtime-only; unset VDDK_USER VDDK_PASSWORD; v2k_load_vddk_cred_from_manifest "$2/manifest.json"; [[ "$VDDK_USER" == fixture && "$VDDK_PASSWORD" == runtime-only ]]'
            result=subprocess.run(['bash','-euo','pipefail','-c',script,'test',str(ROOT),tmp],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(list(Path(tmp).iterdir()),[p])

if __name__=='__main__':unittest.main(verbosity=2)
