#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
class ProducerIdentityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        (self.d / 'map').write_text(json.dumps(dict(planUuid='plan', runUuid='new-control', disks=[])))
    def shell(self, extra):
        script = r'''set -euo pipefail
source "$1/lib/ftctl/dr_ablestack.sh"
source "$1/lib/ftctl/dr_checkpoint.sh"
cd "$2"
ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_now_iso8601() { echo now; }
ftctl_dr_ablestack_disk_map_path() { echo "$PWD/map"; }
ftctl_dr_ablestack_manifest_path() { echo "$PWD/manifest"; }
ftctl_dr_ablestack_checkpoint_path() { echo "$PWD/checkpoint"; }
ftctl_dr_ablestack_prepare_cycle_disk_map() { :; }
ftctl_dr_ablestack_site_agent_transport_load() { return 1; }
ftctl_dr_ablestack_remote_transport_load() { return 1; }
ftctl_dr_ablestack_full_seed_once() {
  ftctl_dr_ablestack_write_manifest "$4" records "$5" seed
  ftctl_dr_ablestack_write_checkpoint "$4" "$5" "$6" TARGET_READY now now 0 FULL_SEED FULL_SEED false 1 "" "${10}"
}
''' + extra
        return subprocess.run(['bash','-c',script,'test',str(ROOT),str(self.d)],capture_output=True,text=True)
    def test_live_worker_producer_wins_over_new_control_run(self):
        for kind in ['full-seed','full-reseed','incremental']:
            r = self.shell('ftctl_dr_ablestack_replication_cycle plan old-worker profile 42 '+kind)
            self.assertEqual(0,r.returncode,r.stderr)
            for name in ['manifest','checkpoint']:
                self.assertEqual('old-worker',json.loads((self.d/name).read_text())['runUuid'])
            self.assertEqual('new-control',json.loads((self.d/'map').read_text())['runUuid'])
    def test_profile_refresh_after_vm_migration_does_not_relabel_producer(self):
        r=self.shell('ftctl_dr_ablestack_prepare_cycle_disk_map() { printf \'%s\' \'{"planUuid":"plan","runUuid":"relocated-control","source":{"hostUuid":"different-host"},"disks":[]}\' > "$3"; }\nftctl_dr_ablestack_replication_cycle plan producer-before-migration profile 43 incremental')
        self.assertEqual(0,r.returncode,r.stderr)
        self.assertEqual('producer-before-migration',json.loads((self.d/'checkpoint').read_text())['runUuid'])
        self.assertEqual('different-host',json.loads((self.d/'map').read_text())['source']['hostUuid'])
    def test_missing_worker_resume_and_function_scope(self):
        r=self.shell('ftctl_dr_ablestack_replication_cycle plan new-control profile 42 full-seed; test -z "${FTCTL_DR_PRODUCER_RUN_UUID:-}"')
        self.assertEqual(0,r.returncode,r.stderr)
        self.assertEqual('new-control',json.loads((self.d/'checkpoint').read_text())['runUuid'])
    def test_delayed_ack_uses_completed_producer_after_profile_change(self):
        r=self.shell('ftctl_dr_ablestack_replication_cycle plan old-worker profile 42 full-seed')
        self.assertEqual(0,r.returncode,r.stderr)
        pending={'request':{'planUuid':'plan','producerRunUuid':'old-worker','checkpointSequence':42},'output':'manifest\t'+str(self.d/'checkpoint'),'schedulerCycleType':'full-seed'}
        (self.d/'pending').write_text(json.dumps(pending))
        r=self.shell('ftctl_dr_checkpoint_resume_context pending PENDING FULL_RESEED newer-control 43')
        self.assertEqual(0,r.returncode,r.stderr)
        self.assertEqual('full-seed\tfalse',r.stdout.strip())
    def test_rejected_evidence_requires_new_owner_and_preserves_durable(self):
        (self.d/'pending').write_text(json.dumps({'request':{'planUuid':'plan','producerRunUuid':'old','checkpointSequence':42}}))
        (self.d/'checkpoint-committed.json').write_text('durable')
        for args in ['other new','plan old','plan ""']:
            self.assertNotEqual(0,self.shell('ftctl_dr_checkpoint_abandon_invalid pending '+args).returncode)
            self.assertTrue((self.d/'pending').exists())
        r=self.shell('ftctl_dr_checkpoint_abandon_invalid pending plan recovery')
        self.assertEqual(0,r.returncode,r.stderr)
        self.assertFalse((self.d/'pending').exists())
        self.assertEqual(1,len(list(self.d.glob('pending.rejected-*'))))
        self.assertEqual('durable',(self.d/'checkpoint-committed.json').read_text())
if __name__=='__main__': unittest.main()
