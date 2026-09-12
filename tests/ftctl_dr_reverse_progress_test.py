#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information.
"""Real extent copies must identify the reverse operation and aggregate disks."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("extent", ROOT / "lib/ftctl/dr_extent_patch.py")
extent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extent)

class ReverseProgressTest(unittest.TestCase):
    def test_full_and_delta_multidisk_identity_and_readback(self):
        for mode, length in [("FULL_REVERSE_SEED", 8192), ("REVERSE_FINAL", 4096)]:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source, target, progress = [root / n for n in ("source", "target", "progress")]
                source.write_bytes(b"A" * 8192)
                target.write_bytes(b"B" * 8192)
                samples = []
                original = extent.write_progress
                def capture(path, value):
                    samples.append(dict(value))
                    original(path, value)
                with patch.object(extent, "write_progress", capture):
                    for disk in range(2):
                        metrics = extent.copy_extents(str(source), str(target), [{"offset": 0, "length": length}],
                            4096, verify=True, progress_json=str(progress), progress_base_bytes=disk * length,
                            progress_disk_index=disk, progress_total_bytes=2 * length, progress_disk_count=2,
                            progress_plan_uuid="plan", progress_run_uuid="parent-run", progress_cycle_sequence=185,
                            progress_mode=mode, progress_direction="KVM_TO_VMWARE", progress_final_disk=disk == 1)
                        self.assertEqual(length, metrics["verifiedBytes"])
                        if disk == 0:
                            self.assertEqual(50, samples[-1]["percent"])
                            self.assertEqual("COPYING", samples[-1]["state"])
                self.assertEqual("COMPLETE", samples[-1]["state"])
                self.assertEqual(100, samples[-1]["percent"])
                self.assertEqual(2 * length, samples[-1]["verifiedBytes"])
                self.assertTrue(all(s["runUuid"] == "parent-run" and s["planUuid"] == "plan" and
                                    s["cycleSequence"] == 185 and s["direction"] == "KVM_TO_VMWARE" and
                                    s["mode"] == mode and s["diskCount"] == 2 for s in samples))
                self.assertEqual(b"A" * length, target.read_bytes()[:length])

if __name__ == "__main__":
    unittest.main()
