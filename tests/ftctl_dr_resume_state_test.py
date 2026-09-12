#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ResumeStateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)

    def shell(self, body):
        script = r'''set -euo pipefail
source "$1/lib/ftctl/state.sh"
source "$1/lib/ftctl/dr_runtime.sh"
source "$1/lib/ftctl/dr_scheduler.sh"
cd "$2"
FTCTL_DR_CONTROL_PROTOCOL_VERSION=2
FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC=5
ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_now_iso8601() { echo now; }
ftctl_dr_scheduler_control_path() { echo "$PWD/control"; }
ftctl_dr_scheduler_lock_acquire() { :; }
ftctl_dr_scheduler_lock_release() { :; }
''' + body
        return subprocess.run(["bash", "-c", script, "test", str(ROOT), str(self.path)], capture_output=True, text=True)

    def test_initial_start_and_restart_preserve_generation(self):
        r = self.shell('ftctl_dr_scheduler_initialize_control plan run; ftctl_dr_scheduler_initialize_control plan other; cat control')
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn('1\n1\n', r.stdout)
        self.assertIn('owner_run=run', r.stdout)

    def test_existing_pause_stop_and_run_are_not_rewritten(self):
        for command in ['pause', 'stop', 'run']:
            original = 'generation=12\ncommand='+command+'\nowner_run=operator\n'
            (self.path/'control').write_text(original)
            r = self.shell('ftctl_dr_scheduler_initialize_control plan new')
            self.assertEqual(0, r.returncode, r.stderr)
            self.assertEqual(original, (self.path/'control').read_text())

    def test_pause_arriving_while_acquiring_lock_wins(self):
        r = self.shell('''ftctl_dr_scheduler_lock_acquire() { printf 'generation=3\ncommand=pause\n' > control; }
ftctl_dr_scheduler_initialize_control plan new
cat control''')
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn('command=pause', r.stdout)

    def test_corrupt_existing_control_is_not_reset(self):
        (self.path/'control').write_text('generation=bad\ncommand=pause\n')
        self.assertNotEqual(0, self.shell('ftctl_dr_scheduler_initialize_control plan new').returncode)
        self.assertIn('generation=bad', (self.path/'control').read_text())

    def test_new_source_assignment_clears_only_local_target_suppression(self):
        (self.path/'control').write_text('generation=12\ncommand=stop\nreason=remote-source-target-suppressed\nowner_run=\n')
        r=self.shell('ftctl_dr_scheduler_restore_source_role_control plan new-source; cat control')
        self.assertEqual(0,r.returncode,r.stderr)
        self.assertIn('generation=13',r.stdout)
        self.assertIn('command=run',r.stdout)
        self.assertIn('owner_run=new-source',r.stdout)

    def test_source_assignment_preserves_operator_and_lifecycle_intent(self):
        for command,reason,owner in [('pause','dr-sync-pause','operator'),('stop','dr-sync-stop','operator'),('stop','remote-source-target-suppressed','operator'),('stop','release','operator')]:
            original=f'generation=12\ncommand={command}\nreason={reason}\nowner_run={owner}\n'
            (self.path/'control').write_text(original)
            r=self.shell('ftctl_dr_scheduler_restore_source_role_control plan new-source')
            self.assertEqual(0,r.returncode,r.stderr)
            self.assertEqual(original,(self.path/'control').read_text())

    def test_remote_mold_coordinator_recovery_entry_restores_local_suppression(self):
        for action in ['dr-sync-start', 'dr-sync-recover']:
            (self.path/'control').write_text('generation=12\ncommand=stop\nreason=remote-source-target-suppressed\nowner_run=\n')
            # Stop at the next action phase: this exercises real profile/role
            # dispatch without starting a storage mover in a unit test.
            setup = 'ftctl_dr_runtime_save_profile() { :; }; ftctl_dr_runtime_record_worker_role() { :; }; ftctl_dr_runtime_action_state() { return 91; }; '
            r=self.shell(setup+'ftctl_dr_runtime_action '+action+' plan fresh profile coordinator')
            self.assertEqual(91,r.returncode,r.stderr)
            self.assertIn('command=run',(self.path/'control').read_text())
            self.assertIn('owner_run=fresh',(self.path/'control').read_text())

    def fixture(self, **changes):
        checkpoint = dict(planUuid='plan', sequence=42, state='TARGET_READY', targetDurableAt='now')
        checkpoint.update(changes)
        (self.path/'checkpoint.json').write_text(json.dumps(checkpoint))
        (self.path/'status').write_text('latest_completed_checkpoint_sequence=42\nlatest_completed_checkpoint_path='+str(self.path/'checkpoint.json')+'\nlatest_completed_checkpoint_ref=ftctl:plan:producer:42\nbaseline_state=LOCAL_DURABLE\nsource_disk_map_path=map\nstate=SUCCEEDED\nrun=old\n')
        (self.path/'run').write_text('run=new\nstate=RUNNING\n')

    def test_resume_inherits_baseline_without_terminal_identity(self):
        self.fixture()
        r = self.shell('ftctl_dr_runtime_inherit_resume_checkpoint plan run status; ftctl_dr_scheduler_cycle_type 43 ABLESTACK run ABLESTACK plan; cat run')
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn('incremental', r.stdout)
        self.assertIn('run=new', r.stdout)
        self.assertNotIn('SUCCEEDED', r.stdout)
        self.assertIn('source_disk_map_path=map', r.stdout)

    def test_foreign_incomplete_or_stale_checkpoint_is_not_inherited(self):
        for changes in [dict(planUuid='other'), dict(sequence=41), dict(state='FAILED'), dict(targetDurableAt='')]:
            self.fixture(**changes)
            r = self.shell('ftctl_dr_runtime_inherit_resume_checkpoint plan run status; ftctl_dr_scheduler_cycle_type 43 ABLESTACK run ABLESTACK plan')
            self.assertEqual(0, r.returncode, r.stderr)
            self.assertEqual('full-seed', r.stdout.strip())

    def test_invalid_baseline_is_not_resurrected(self):
        self.fixture()
        s=(self.path/'status').read_text().replace('LOCAL_DURABLE', 'INVALID')
        (self.path/'status').write_text(s)
        r=self.shell('ftctl_dr_runtime_inherit_resume_checkpoint plan run status; cat run')
        self.assertEqual(0,r.returncode,r.stderr)
        self.assertNotIn('latest_completed_checkpoint_sequence',r.stdout)

if __name__ == '__main__':
    unittest.main()
