#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Exercise real cleanup against a controlled RBD command boundary."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FailedTestCleanup(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sessions = self.root / 'dr-runtime/plans/plan/test-sessions'
        self.sessions.mkdir(parents=True)
        self.path = self.sessions / 'test-run.json'
        self.session = {'planUuid': 'plan', 'runUuid': 'test-run', 'sessionId': 'plan:test-run',
                        'testArtifacts': {'records': [{'type': 'rbd-clone',
                         'clone': 'rbd:pool/base-ftctl-test-test-run', 'backing': 'rbd:pool/base',
                         'snapshot': 'retained', 'retainedCheckpoint': True}]}}
        self.path.write_text(json.dumps(self.session))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        rbd = self.bin / 'rbd'
        rbd.write_text("#!/bin/bash\nprintf '%s\n' \"$*\" >> \"$FTCTL_RUN_DIR/calls\"\n"
                       "if [[ -f \"$FTCTL_RUN_DIR/fail\" ]]; then exit 16; fi\nexit 0\n")
        rbd.chmod(0o755)

    def cleanup(self, run='test-run'):
        script = r"""
set -eu
source "$1/lib/ftctl/dr_runtime.sh"
ftctl_state_vm_key() { printf '%s' "$1"; }
ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_now_iso8601() { echo 2026-09-10T00:00:00Z; }
ftctl_dr_runtime_state_get_from_path() { :; }
ftctl_dr_runtime_path_set() { :; }
ftctl_dr_runtime_default_restore_points_path() { :; }
ftctl_dr_runtime_cleanup_test_session plan "$2" "$FTCTL_RUN_DIR/run.state" "$FTCTL_RUN_DIR/status.state"
"""
        return subprocess.run(['bash', '-c', script, '_', str(ROOT), run],
                              env={**os.environ, 'FTCTL_RUN_DIR': str(self.root),
                                   'PATH': str(self.bin) + ':' + os.environ['PATH']},
                              capture_output=True, text=True)

    def test_prepublication_failure_cleans_owned_clone(self):
        result = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('rm pool/base-ftctl-test-test-run', (self.root / 'calls').read_text())
        self.assertEqual(json.loads(self.path.read_text())['state'], 'CLEANED')

    def test_failed_removal_preserves_records_for_retry(self):
        (self.root / 'fail').touch()
        before = self.path.read_text()
        self.assertNotEqual(self.cleanup().returncode, 0)
        self.assertEqual(self.path.read_text(), before)
        (self.root / 'fail').unlink()
        (self.sessions / 'active.json').write_text(before)
        self.assertEqual(self.cleanup('cleanup-run').returncode, 0)
        self.assertFalse((self.sessions / 'active.json').exists())
        self.assertEqual(json.loads((self.sessions / 'cleanup-run.json').read_text())['state'], 'CLEANED')

    def test_manual_retry_follows_stale_active_pointer_to_original_records(self):
        active = {key: value for key, value in self.session.items() if key != 'testArtifacts'}
        (self.sessions / 'active.json').write_text(json.dumps(active))
        result = self.cleanup('manual-cleanup')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('rm pool/base-ftctl-test-test-run', (self.root / 'calls').read_text())
        self.assertFalse((self.sessions / 'active.json').exists())

    def test_other_plan_or_nonowned_clone_is_not_removed(self):
        for field, value in [('planUuid', 'other'), ('clone', 'rbd:pool/production')]:
            session = json.loads(json.dumps(self.session))
            if field == 'clone':
                session['testArtifacts']['records'][0][field] = value
            else:
                session[field] = value
            self.path.write_text(json.dumps(session))
            self.assertNotEqual(self.cleanup().returncode, 0)
        self.assertFalse((self.root / 'calls').exists())


if __name__ == '__main__':
    unittest.main()
