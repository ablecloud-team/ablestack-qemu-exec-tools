#!/usr/bin/env python3
import argparse
import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "qcow2_bitmap_backup", ROOT / "lib" / "ftctl" / "qcow2_bitmap_backup.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FakeClient:
    def __init__(self, bitmap=None):
        self.calls = []
        self.bitmap = bitmap
        self.query_jobs_count = 0

    def execute(self, command, arguments=None):
        self.calls.append((command, arguments))
        if command == "query-named-block-nodes":
            node = {
                "node-name": "libvirt-2-format",
                "drv": "qcow2",
                "active": True,
                "file": "/mnt/glue-gfs/source",
                "image": {"filename": "/mnt/glue-gfs/source"},
            }
            if self.bitmap is not None:
                node["dirty-bitmaps"] = [self.bitmap]
            return [node]
        if command == "query-jobs":
            self.query_jobs_count += 1
            return [{
                "id": "job-1", "status": "concluded",
                "current-progress": 1048576, "total-progress": 1048576,
            }]
        return {}


def args(mode, progress_path):
    return argparse.Namespace(
        domain="i-2-13-VM", source_path="/mnt/glue-gfs/source",
        target_host="10.10.31.2", target_port=12000, target_export="dr-sda",
        bitmap="ftctl-dr-plan-sda", mode=mode, job_id="job-1",
        target_node="ftctl-target-sda", virtual_size=1048576, timeout=2,
        poll_interval=0, granularity=65536, bandwidth_limit_mbps=0,
        progress_path=progress_path, cycle_sequence=7, disk_index=0, disk_count=1,
        aggregate_total_bytes=0, aggregate_completed_bytes=0,
        plan_uuid="plan-1", run_uuid="run-1",
        uri="qemu:///system", virsh="virsh", preserve_bitmap=False,
    )


class Qcow2BitmapBackupTest(unittest.TestCase):
    def test_missing_domain_is_a_runtime_error_not_an_nbd_error(self):
        class MissingDomainClient:
            def execute(self, command, arguments=None):
                raise MODULE.BackupError("failed to get domain")

        with self.assertRaises(MODULE.SourceRuntimeUnavailable):
            MODULE.run_backup(args("full", ""), MissingDomainClient())

    def test_full_seed_creates_persistent_bitmap_before_backup(self):
        with tempfile.TemporaryDirectory() as temp:
            client = FakeClient()
            progress_path = pathlib.Path(temp) / "progress.json"
            result = MODULE.run_backup(args("full", str(progress_path)), client)
            progress = json.loads(progress_path.read_text(encoding="utf-8"))

        commands = [command for command, _ in client.calls]
        self.assertLess(commands.index("block-dirty-bitmap-add"), commands.index("blockdev-backup"))
        backup = next(value for command, value in client.calls if command == "blockdev-backup")
        self.assertEqual("full", backup["sync"])
        self.assertNotIn("bitmap", backup)
        self.assertEqual("FULL_RESEED", result["mode"])
        self.assertEqual(2, progress["schemaVersion"])
        self.assertEqual("plan-1", progress["planUuid"])
        self.assertEqual("run-1", progress["runUuid"])

    def test_incremental_uses_existing_bitmap_and_clears_on_success_only(self):
        with tempfile.TemporaryDirectory() as temp:
            client = FakeClient({"name": "ftctl-dr-plan-sda", "count": 4096, "recording": True})
            result = MODULE.run_backup(args("incremental", str(pathlib.Path(temp) / "progress.json")), client)

        backup = next(value for command, value in client.calls if command == "blockdev-backup")
        self.assertEqual("incremental", backup["sync"])
        self.assertEqual("ftctl-dr-plan-sda", backup["bitmap"])
        self.assertEqual("on-success", backup["bitmap-mode"])
        self.assertEqual(4096, result["changedBytes"])
        self.assertEqual(4096, result["bytesProcessed"])
        self.assertNotIn("block-dirty-bitmap-clear", [command for command, _ in client.calls])

    def test_offline_incremental_uses_a_working_bitmap_and_preserves_the_baseline(self):
        with tempfile.TemporaryDirectory() as temp:
            client = FakeClient({"name": "ftctl-dr-plan-sda", "count": 4096, "recording": True})
            values = args("incremental", str(pathlib.Path(temp) / "progress.json"))
            values.preserve_bitmap = True
            result = MODULE.run_backup(values, client)

        backup = next(value for command, value in client.calls if command == "blockdev-backup")
        self.assertEqual("on-success", backup["bitmap-mode"])
        self.assertNotEqual("ftctl-dr-plan-sda", backup["bitmap"])
        merge = next(value for command, value in client.calls if command == "block-dirty-bitmap-merge")
        self.assertEqual("ftctl-dr-plan-sda", merge["bitmaps"][0]["name"])
        self.assertEqual(4096, result["changedBytes"])
        self.assertEqual(4096, result["targetWrittenBytes"])

    def test_inconsistent_bitmap_is_rejected_before_target_attach(self):
        client = FakeClient({"name": "ftctl-dr-plan-sda", "inconsistent": True})
        with self.assertRaises(MODULE.BackupError):
            MODULE.run_backup(args("incremental", ""), client)
        self.assertNotIn("blockdev-add", [command for command, _ in client.calls])

    def test_incremental_without_bitmap_requires_full_reseed(self):
        client = FakeClient()
        with self.assertRaises(MODULE.BaselineUnavailable):
            MODULE.run_backup(args("incremental", ""), client)
        self.assertNotIn("blockdev-add", [command for command, _ in client.calls])

    def test_full_seed_progress_is_aggregate_and_zero_based_for_multiple_disks(self):
        with tempfile.TemporaryDirectory() as temp:
            values = args("full", str(pathlib.Path(temp) / "progress.json"))
            values.disk_index = 1
            values.disk_count = 2
            values.aggregate_total_bytes = 3 * 1048576
            values.aggregate_completed_bytes = 2 * 1048576
            client = FakeClient()
            MODULE.run_backup(values, client)
            progress = json.loads(pathlib.Path(values.progress_path).read_text(encoding="utf-8"))

        self.assertEqual(3 * 1048576, progress["bytesTotal"])
        self.assertEqual(3 * 1048576, progress["bytesProcessed"])
        self.assertEqual(100, progress["percent"])
        self.assertEqual(1, progress["diskIndex"])
        self.assertEqual(2, progress["diskCount"])
        self.assertEqual("COMPLETED", progress["state"])
        self.assertTrue(progress["transferCompletionVerified"])
        self.assertFalse(progress["readbackVerified"])
        self.assertEqual(0, progress["verifiedBytes"])
        self.assertEqual(0, progress["readbackVerifiedBytes"])

    def test_non_final_full_seed_disk_does_not_publish_cycle_completion(self):
        with tempfile.TemporaryDirectory() as temp:
            values = args("full", str(pathlib.Path(temp) / "progress.json"))
            values.disk_index = 0
            values.disk_count = 2
            values.aggregate_total_bytes = 2 * 1048576
            client = FakeClient()
            MODULE.run_backup(values, client)
            progress = json.loads(pathlib.Path(values.progress_path).read_text(encoding="utf-8"))

        self.assertEqual(50, progress["percent"])
        self.assertEqual("COPYING", progress["state"])


if __name__ == "__main__":
    unittest.main()
