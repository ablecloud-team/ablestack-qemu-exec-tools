#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information.
"""A target-only tracker cannot authorize differential writes to VMware."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class CommonBaselineTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.baseline = self.root / "baseline.json"
        self.base = {"schemaVersion": 1, "state": "LOCAL_DURABLE", "direction": "KVM_TO_VMWARE",
                     "trackerType": "RBD_SNAPSHOT", "origin": "FAILOVER_CUTOVER", "disks": [{"diskIndex": 0}]}

    def decision(self, mode="AUTO"):
        # Fixed path binding avoids function positional argument shadowing.
        script = 'source "$1/lib/ftctl/dr_kvm_vmware.sh"; test_baseline="$2"; ftctl_dr_kvm_vmware_baseline_path() { printf "%s" "$test_baseline"; }; ftctl_dr_kvm_vmware_mode_decision plan FAILBACK_FINAL "$3"'
        return subprocess.run(["bash", "-c", script, "test", str(ROOT), str(self.baseline), mode], capture_output=True, text=True)

    def test_cutover_and_legacy_trackers_require_full_reconciliation(self):
        for tracker in ("RBD_SNAPSHOT", "QCOW2_BITMAP"):
            for verified in (None, False):
                row = dict(self.base, trackerType=tracker)
                if verified is not None:
                    row["commonBaselineVerified"] = verified
                self.baseline.write_text(json.dumps(row))
                result = self.decision()
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn("INITIAL_REVERSE_COMMON_BASELINE_UNVERIFIED", result.stdout)
                self.assertEqual(83, self.decision("REVERSE_FINAL").returncode)

    def test_verified_baseline_allows_delta_and_new_cutover_invalidates_it(self):
        self.baseline.write_text(json.dumps(dict(self.base, commonBaselineVerified=True)))
        self.assertIn("REVERSE_FINAL", self.decision().stdout)
        self.baseline.write_text(json.dumps(dict(self.base, commonBaselineVerified=False)))
        self.assertIn("FULL_REVERSE_SEED", self.decision().stdout)

    def test_failed_or_incomplete_readback_never_commits_common_baseline(self):
        for tracker in ("rbd", "qcow2"):
            for verified, count, succeeds in ((False, 4096, False), (True, 512, False), (True, 4096, True)):
                self.baseline.write_text(json.dumps(self.base))
                before = self.baseline.read_bytes()
                (self.root / "map.json").write_text(json.dumps({"disks": [{"diskIndex": 0, "virtualBytes": 4096}]}))
                (self.root / "rows.json").write_text(json.dumps([{"diskIndex": 0, "diskIdentityHash": "disk", "sourcePool": "rbd", "sourceImage": "vm", "newSnapshot": "next"}]))
                (self.root / "metrics.json").write_text(json.dumps([{"writeVerified": verified, "targetWrittenBytes": count, "verifiedBytes": count if tracker == "rbd" else 0,
                    "transferCompletionVerified": verified, "verificationMethod": "QEMU_BACKUP_COMPLETION"}]))
                command = ('ftctl_kvm_vmware_commit_baseline_and_metrics "$d/map.json" "$d/baseline.json" "$d/rows.json" "$d/metrics.json" "$d/baseline.json" "$d/out.json" FULL_REVERSE_SEED'
                           if tracker == "rbd" else 'ftctl_kvm_vmware_commit_qcow2_baseline_and_metrics "$d/map.json" "$d/baseline.json" "$d/metrics.json" "$d/out.json" FULL_REVERSE_SEED')
                script = 'source "$1/lib/ftctl/dr_kvm_vmware_mover.sh"; d="$2"; ' + command
                result = subprocess.run(["bash", "-c", script, "test", str(ROOT), str(self.root)], capture_output=True, text=True)
                self.assertEqual(succeeds, result.returncode == 0, result.stderr)
                if succeeds:
                    self.assertTrue(json.loads(self.baseline.read_text())["commonBaselineVerified"])
                    evidence = json.loads((self.root / "out.json").read_text())
                    self.assertEqual(tracker == "rbd", evidence["readbackVerified"])
                    self.assertEqual(count if tracker == "rbd" else 0, evidence["readbackVerifiedBytes"])
                    self.assertEqual(count if tracker == "rbd" else 0, evidence["verifiedBytes"])
                else:
                    self.assertEqual(before, self.baseline.read_bytes())

if __name__ == "__main__":
    unittest.main()
