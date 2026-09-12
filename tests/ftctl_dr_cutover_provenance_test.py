#!/usr/bin/env python3
"""A selected durable restore point wins over stale runtime counters."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class CutoverProvenanceTest(unittest.TestCase):
    def test_explicit_latest_and_final_selection_ignore_stale_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "profile").write_text(json.dumps({"direction": "VMWARE_TO_KVM"}))
            records = []
            for sequence in (54, 182, 183):
                checkpoint = root / str(sequence)
                checkpoint.write_text(json.dumps({"state": "TARGET_READY", "targetDurableAt": "2026-09-11T00:00:00Z"}))
                records.append({"planUuid": "plan", "runUuid": "producer", "checkpointSequence": sequence,
                                "checkpoint": str(checkpoint), "checkpointRef": f"ftctl:plan:producer:{sequence}"})
            (root / "records").write_text("\n".join(json.dumps(row) for row in records))
            (root / "status").write_text("checkpoint_sequence=54\nlatest_completed_checkpoint_sequence=182\n")
            script = 'source "$1/lib/ftctl/dr_runtime.sh"; d="$2"; ftctl_dr_runtime_default_restore_points_path() { echo "$d/records"; }; ftctl_dr_runtime_select_cutover_checkpoint plan new-run "$d/profile" "$3" "$d/status" "$d/proof"'
            for selector, expected in (("ftctl:plan:182", 182), ("54", 54), ("", 183), ("ftctl:plan:producer:183", 183)):
                result = subprocess.run(["bash", "-c", script, "test", str(ROOT), str(root), selector], capture_output=True, text=True)
                self.assertEqual(0, result.returncode, result.stderr)
                proof = json.loads((root / "proof").read_text())
                self.assertEqual(expected, proof["checkpointSequence"])
                self.assertEqual(f"ftctl:plan:producer:{expected}", proof["checkpointRef"])
                self.assertEqual(hashlib.sha256((root / str(expected)).read_bytes()).hexdigest(), proof["pathSha256"])
            result = subprocess.run(["bash", "-c", script, "test", str(ROOT), str(root), "999"], capture_output=True, text=True)
            self.assertEqual(44, result.returncode)

if __name__ == "__main__":
    unittest.main()
