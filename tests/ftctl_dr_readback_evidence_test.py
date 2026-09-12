#!/usr/bin/env python3
"""Failed writes and readback mismatches must never produce success evidence."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
spec = importlib.util.spec_from_file_location("extent_patch", Path(__file__).resolve().parents[1] / "lib/ftctl/dr_extent_patch.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ReadbackEvidenceTest(unittest.TestCase):
    def test_write_failure_and_readback_mismatch_are_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory)/"source", Path(directory)/"target"
            source.write_bytes(b"a" * 4096)
            target.write_bytes(b"b" * 4096)
            args = (str(source), str(target), [{"offset": 0, "length": 4096}], 4096)
            with patch.object(module.os, "pwrite", return_value=0):
                with self.assertRaisesRegex(IOError, "short target write"):
                    module.copy_extents(*args, verify=True)
            fsync = os.fsync
            def corrupt(fd):
                fsync(fd)
                os.pwrite(fd, b"x", 0)
            with patch.object(module.os, "fsync", side_effect=corrupt):
                with self.assertRaisesRegex(IOError, "target verification failed"):
                    module.copy_extents(*args, verify=True)
            evidence = module.copy_extents(*args, verify=True)
            self.assertTrue(evidence["writeVerified"])
            self.assertEqual(4096, evidence["verifiedBytes"])

if __name__ == "__main__":
    unittest.main()
