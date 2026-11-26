#!/usr/bin/env python3
"""Actual v2k/n2k cutover functions with a stateful Mold protocol fixture."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
FAKE=r"""import json,sys,uuid,os
from pathlib import Path
root=Path(os.environ['CASE']);file=root/'mold.json'
state=json.loads(file.read_text()) if file.exists() else {'offerings':[],'volumes':{},'jobs':{},'vm':{},'calls':[]}
api=sys.argv[1];p=json.loads(sys.argv[2]);state['calls'].append({'api':api,'params':p})
def result(name,data):return {name+'response':data}
def job(data):
    id=str(uuid.uuid4());state['jobs'][id]=data;return {'jobid':id}
if api=='getVolumeAllocationCapabilities':
    methods={'off':'import-adopt-off','falloc':'import-adopt-falloc','full':'import-copy-qemu-preallocation-full'}
    if p['allocationformat']=='qcow2':methods['metadata']='import-copy-qemu-preallocation-metadata'
    out=result(api.lower(),{'volumeallocationcapability':{'contractversion':1,'supported':os.environ.get('BAD_CAP')!='1','backend':'GFS2','operation':'import','storageid':'pool','allocationformat':p['allocationformat'],'agentpolicies':methods}})
elif api=='listStoragePools':out=result(api.lower(),{'storagepool':[{'id':'pool','type':'SharedMountPoint','scope':'CLUSTER','path':str(root/'target'),'state':'Up'}]})
elif api=='listServiceOfferings':out=result(api.lower(),{'serviceoffering':[{'id':'offering','cpuspeed':1000}]})
elif api=='listDiskOfferings':
    values=[v for v in state['offerings'] if all(v.get(k)==p[k] for k in ['id','name','storagetype'] if k in p)]
    out=result(api.lower(),{'diskoffering':values})
elif api=='createDiskOffering':
    value={**p,'id':str(uuid.uuid4()),'iscustomized':True,'state':'Active','tags':''}
    if 'allocationpolicy' in p:value['allocation']={'contractversion':'1','policyorigin':'explicit','requestedpolicy':p['allocationpolicy'],'requestedformat':p['allocationformat']}
    state['offerings'].append(value);out=result(api.lower(),{'diskoffering':value})
elif api=='listVolumesForImport':out=result(api.lower(),{'volume':[{'path':p.get('path'),'fullpath':p.get('path'),'name':Path(p.get('path','disk')).name,'format':'QCOW2'}]})
elif api=='importVolume':
    id=p['allocationrequestid'];policy=p['allocationpolicy'];fmt=p['allocationformat'];copy=policy in ['metadata','full']
    allocation={'contractversion':'1','requestedpolicy':policy,'requestedformat':fmt,'policyorigin':'explicit','fixedpolicy':policy,'effectivepolicy':policy,'actualformat':fmt,'evidence':'verified','appliedbackend':'GFS2','appliedoperation':'copy' if copy else 'import','appliedmethod':('qemu-preallocation-' if copy else 'import-adopt-')+policy,'evidencescope':'creation-or-copy-time' if copy else 'import-time','importrequestid':id,'importidentity':'0'*64,'importpool':'pool','importverifiedat':'2026-11-26T00:00:00Z','importstrategy':'copy' if copy else 'adopt','observedallocatedbytes':'1075838976'}
    allocation['importpath']=id if copy else Path(p['path']).name
    value={'id':id,'name':p['name'],'path':id if copy else Path(p['path']).name,'state':'Ready','type':'DATADISK','size':1073741824,'storageid':'pool','cachemode':'writeback','allocation':allocation}
    state['volumes'][id]=value;out=result(api.lower(),job({'volume':value}))
elif api=='queryAsyncJobResult':out=result(api.lower(),{'jobstatus':1,'jobresult':state['jobs'][p['jobid']]})
elif api=='deployVirtualMachineForVolume':
    id='vm';nic={'networkid':'network','macaddress':'52:54:00:87:00:01','isdefault':True}
    state['vm']={'id':id,'state':'Stopped','nic':[nic]};state['volumes'][p['volumeid']]['virtualmachineid']=id;state['volumes'][p['volumeid']]['deviceid']=0;state['volumes'][p['volumeid']]['type']='ROOT'
    out=result(api.lower(),job({'virtualmachine':state['vm']}))
elif api=='listVirtualMachines':out=result(api.lower(),{'virtualmachine':[state['vm']]})
elif api=='listVolumes':out=result(api.lower(),{'volume':[state['volumes'][p['id']]]})
elif api=='updateVolume':
    value=state['volumes'][p['id']];value['type']=p['type'];out=result(api.lower(),{'volume':value})
elif api=='attachVolume':
    value=state['volumes'][p['id']];value['virtualmachineid']=p['virtualmachineid'];value['deviceid']=p.get('deviceid');out=result(api.lower(),job({'volume':value}))
elif api=='verifyImportedVolumeAllocation':
    value=json.loads(json.dumps(state['volumes'][p['id']]))
    if os.environ.get('BAD_FINAL')=='1':value['allocation']['effectivepolicy']='off'
    out=result(api.lower(),{'volume':value})
elif api=='startVirtualMachine':
    state['vm']['state']='Running';out=result(api.lower(),job({'virtualmachine':state['vm']}))
else:raise RuntimeError('Unexpected API '+api)
file.write_text(json.dumps(state));print(json.dumps(out))
"""

SHELL=r"""
export V2K_ROOT_DIR="$REPO" V2K_LIB_DIR="$REPO/lib/v2k" V2K_WORKDIR="$CASE"
export N2K_ROOT_DIR="$REPO" N2K_LIB_DIR="$REPO/lib/n2k" N2K_WORKDIR="$CASE"
source "$REPO/lib/$TOOL/engine.sh"
v2k_cloud_api_get() { python3 "$CASE/fake.py" "$4" "$5"; }
n2k_cloud_api_get() { python3 "$CASE/fake.py" "$4" "$5"; }
"${TOOL}_cloud_target_cutover" "$CASE/manifest.json" 0 1 1 https://mold.invalid fixture-key fixture-secret ''
"""

class Handoff(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='mold-allocation-test-');self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
    def run_cutover(self,tool,policy='falloc',fmt='qcow2',copy=False,bad_cap=False,bad_final=False):
        case=self.root/(tool+'-'+policy+fmt+str(len(list(self.root.iterdir()))));case.mkdir();(case/'target').mkdir();(case/'fake.py').write_text(FAKE)
        disks=[{'disk_id':'scsi0:'+str(i),'size_bytes':1073741824,'controller':{'kind':'scsi','type':'VirtualLsiLogicSASController'},'transfer':{'base_done':True,'target_path':str(case/'target'/('disk'+str(i)+'.'+fmt))}} for i in range(2)]
        manifest={'source':{'vm':{'name':'fixture','cpu':1,'memory_mb':1024,'firmware':'bios','nics':[{'key':'nic0','label':'nic0','mac':'52:54:00:87:00:01'}]}},'target':{'provider':'ablestack-cloud','format':fmt,'storage':{'type':'file','preallocation':policy,'preallocation_source':'cli'},'dst_root':str(case/'target'),'cloud':{'endpoint':'https://mold.invalid','zone_id':'zone','service_offering_id':'offering','network_ids':['network'],'storage_id':'pool','name':'fixture','allocation_allow_copy':copy}},'disks':disks}
        (case/'manifest.json').write_text(json.dumps(manifest))
        env={**os.environ,'REPO':str(ROOT),'CASE':str(case),'TOOL':tool,'BAD_CAP':str(int(bad_cap)),'BAD_FINAL':str(int(bad_final))}
        r=subprocess.run(['bash','-euo','pipefail','-c',SHELL],env=env,text=True,capture_output=True,timeout=60)
        state=json.loads((case/'mold.json').read_text()) if (case/'mold.json').exists() else {'calls':[]}
        return r,state,json.loads((case/'manifest.json').read_text())
    def test_policy_lasts_through_both_actual_cutover_functions(self):
        for tool in ['v2k','n2k']:
            for fmt,modes in [('qcow2',['off','metadata','falloc','full']),('raw',['off','falloc','full'])]:
                for mode in modes:
                    with self.subTest(tool=tool,format=fmt,policy=mode):
                        r,state,manifest=self.run_cutover(tool,mode,fmt,copy=mode in ['metadata','full'])
                        self.assertEqual(r.returncode,0,r.stdout+'\n'+r.stderr)
                        self.assertEqual(state['vm']['state'],'Running')
                        creates=[c['params'] for c in state['calls'] if c['api']=='createDiskOffering']
                        self.assertEqual(len(creates),1);self.assertNotIn('provisioningtype',creates[0]);self.assertEqual(creates[0]['allocationpolicy'],mode)
                        imports=[c['params'] for c in state['calls'] if c['api']=='importVolume']
                        self.assertEqual(len(imports),2)
                        for request in imports:
                            self.assertEqual(request['allocationpolicy'],mode);self.assertEqual(request['allocationformat'],fmt);self.assertEqual(request['allocationcontractversion'],1)
                        self.assertTrue(manifest['runtime']['cloud']['allocation']['verified'])
                        self.assertTrue(manifest['runtime']['cloud']['checkpoint']['allocation_verified'])
                        calls=[c['api'] for c in state['calls']]
                        self.assertEqual(calls.count('verifyImportedVolumeAllocation'),2)
                        self.assertNotIn('updateVolume',calls)
                        self.assertLess(max(i for i,c in enumerate(calls) if c=='verifyImportedVolumeAllocation'),calls.index('startVirtualMachine'))
    def test_failure_blocks_start_and_cannot_claim_complete(self):
        for tool in ['v2k','n2k']:
            r,state,manifest=self.run_cutover(tool,bad_final=True)
            self.assertNotEqual(r.returncode,0)
            self.assertNotIn('startVirtualMachine',[c['api'] for c in state['calls']])
            self.assertFalse(manifest['runtime']['cloud']['checkpoint']['complete'])
            self.assertFalse(manifest['runtime']['cloud']['checkpoint']['allocation_verified'])
    def test_missing_capability_or_copy_approval_precedes_mutation(self):
        for tool in ['v2k','n2k']:
            for kw in [{'bad_cap':True},{'policy':'metadata','copy':False},{'policy':'full','copy':False}]:
                r,state,_=self.run_cutover(tool,**kw);self.assertNotEqual(r.returncode,0)
                self.assertFalse(any(c['api'] in ['importVolume','deployVirtualMachineForVolume','createDiskOffering','startVirtualMachine'] for c in state['calls']))
    def test_helper_bundles_match(self):
        self.assertEqual((ROOT/'lib/v2k/cloud_allocation.sh').read_bytes(),(ROOT/'lib/n2k/cloud_allocation.sh').read_bytes())

if __name__=='__main__':unittest.main(verbosity=2)
