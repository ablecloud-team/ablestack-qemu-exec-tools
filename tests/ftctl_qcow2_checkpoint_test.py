#!/usr/bin/env python3

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "lib" / "ftctl" / "qcow2_checkpoint.py"
SPEC = importlib.util.spec_from_file_location("qcow2_checkpoint", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class Args:
    plan = "plan-uuid"
    sequence = 17
    checkpoint_ref = "ftctl:plan-uuid:run-uuid:17"
    device = "vda"


class Qcow2CheckpointTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "replica.qcow2"
        self.source.write_bytes(b"source")
        self.output = self.root / "ftctl-dr-test-run-vda.qcow2"
        self.args = Args()
        self.args.source = str(self.source)
        self.args.storage_root = str(self.root)
        self.args.output = str(self.output)

    def tearDown(self):
        self.temp.cleanup()

    def fake_run(self, command, **kwargs):
        executable = Path(command[0]).name
        if executable == "qemu-img" and command[1] == "info":
            return mock.Mock(returncode=0, stdout=json.dumps({"format": "qcow2", "virtual-size": 4096}), stderr="")
        if executable == "cp":
            Path(command[-1]).write_bytes(b"qcow2")
            return mock.Mock(returncode=0, stdout="", stderr="")
        if executable == "qemu-img" and command[1] == "create":
            Path(command[-1]).write_bytes(b"qcow2")
            return mock.Mock(returncode=0, stdout="", stderr="")
        if executable == "qemu-img" and command[1] in ("check", "compare"):
            return mock.Mock(returncode=0, stdout="", stderr="")
        if executable == "virt-inspector":
            return mock.Mock(
                returncode=0,
                stdout=("<operatingsystems><operatingsystem><name>linux</name>"
                        "<mountpoints><mountpoint dev='/dev/sda1'>/</mountpoint></mountpoints>"
                        "</operatingsystem></operatingsystems>"),
                stderr="",
            )
        if executable == "guestfish":
            return mock.Mock(returncode=0, stdout="/dev/sda1: /\n", stderr="")
        if executable == "virt-cat":
            return mock.Mock(returncode=0, stdout="/dev/mapper/rl-root / xfs defaults 0 0\n", stderr="")
        if executable == "virt-ls":
            return mock.Mock(returncode=0, stdout="vmlinuz\n", stderr="")
        raise AssertionError(command)

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_seals_probes_and_creates_overlay(self, run_mock, _which):
        run_mock.side_effect = self.fake_run
        result = MODULE.execute(self.args)

        self.assertEqual("SEALED", result["checkpointSealState"])
        self.assertEqual("PASSED", result["checkpointIntegrityState"])
        self.assertEqual(17, result["checkpointSequence"])
        self.assertTrue(Path(result["checkpointPath"]).is_file())
        self.assertTrue(self.output.is_file())
        self.assertFalse(any(Path(result["checkpointPath"]).parent.glob(".probe-*.qcow2")))

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_reuses_only_matching_immutable_checkpoint(self, run_mock, _which):
        run_mock.side_effect = self.fake_run
        first = MODULE.execute(self.args)
        self.output.unlink()
        second = MODULE.execute(self.args)
        self.assertFalse(first["checkpointReused"])
        self.assertTrue(second["checkpointReused"])

        metadata = Path(second["checkpointMetadataPath"])
        data = json.loads(metadata.read_text(encoding="utf-8"))
        data["checkpointSequence"] = 18
        metadata.write_text(json.dumps(data), encoding="utf-8")
        self.output.unlink()
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH", context.exception.code)

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_probe_failure_does_not_publish_test_overlay(self, run_mock, _which):
        def failing_run(command, **kwargs):
            if Path(command[0]).name == "virt-inspector":
                return mock.Mock(returncode=1, stdout="", stderr="filesystem is inconsistent")
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = failing_run
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", context.exception.code)
        self.assertFalse(self.output.exists())

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_rejects_checkpoint_that_differs_from_drained_target(self, run_mock, _which):
        def mismatched_run(command, **kwargs):
            if Path(command[0]).name == "qemu-img" and command[1] == "compare":
                return mock.Mock(returncode=1, stdout="Content mismatch at offset 69632", stderr="")
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = mismatched_run
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_CONTENT_MISMATCH", context.exception.code)
        checkpoint_dir = self.root / ".ftctl-dr-checkpoints" / self.args.plan / str(self.args.sequence)
        self.assertFalse((checkpoint_dir / "vda.qcow2").exists())
        self.assertFalse(self.output.exists())

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_rejects_separate_boot_filesystem_mount_failure(self, run_mock, _which):
        def failing_run(command, **kwargs):
            if Path(command[0]).name == "virt-cat":
                return mock.Mock(
                    returncode=0,
                    stdout="/dev/mapper/rl-root / xfs defaults 0 0\n",
                    stderr="some filesystems could not be mounted: Structure needs cleaning",
                )
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = failing_run
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", context.exception.code)
        self.assertFalse(self.output.exists())

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_windows_probe_mounts_ntfs_root_and_reads_system_hive(self, run_mock, _which):
        guestfish_inputs = []

        def windows_run(command, **kwargs):
            if Path(command[0]).name == "virt-inspector":
                return mock.Mock(
                    returncode=0,
                    stdout=("<operatingsystems><operatingsystem><name>windows</name>"
                            "<root>/dev/sda3</root></operatingsystem></operatingsystems>"),
                    stderr="",
                )
            if Path(command[0]).name == "guestfish":
                guestfish_inputs.append(kwargs.get("input", ""))
                return mock.Mock(returncode=0, stdout="", stderr="")
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = windows_run
        result = MODULE.execute(self.args)

        self.assertEqual("PASSED", result["checkpointIntegrityState"])
        self.assertEqual(1, len(guestfish_inputs))
        self.assertIn("ntfs-3g -o ro /dev/sda3", guestfish_inputs[0])
        self.assertIn("Windows/System32/config/SYSTEM", guestfish_inputs[0])

    @mock.patch.object(MODULE.subprocess, "run")
    def test_unsupported_guest_filesystem_driver_is_not_reported_as_corruption(self, run_mock):
        run_mock.return_value = mock.Mock(
            returncode=1,
            stdout="",
            stderr="libguestfs: error: mount: unsupported filesystem type",
        )

        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.strict_guest_command(["guestfish", "--ro"])

        self.assertEqual("DR_TEST_CHECKPOINT_GUEST_FS_DRIVER_UNAVAILABLE", context.exception.code)

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE, "writable_holders", return_value=["pid=4242 command=qemu-kvm fd=17"])
    def test_rejects_checkpoint_while_canonical_target_is_writable(self, _holders, _which):
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_WRITER_NOT_DRAINED", context.exception.code)
        self.assertIn("qemu-kvm", str(context.exception))
        self.assertFalse(self.output.exists())

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_offline_reuses_seal_without_reading_mutated_replica(self, run_mock, _which):
        run_mock.side_effect = self.fake_run
        first = MODULE.execute(self.args)
        self.output.unlink()
        self.source.write_bytes(b"partial-next-cycle")
        run_mock.reset_mock()
        self.args.existing_only = True
        result = MODULE.execute(self.args)
        self.assertEqual(first["checkpointPath"], result["checkpointPath"])
        commands = [call.args[0] for call in run_mock.call_args_list]
        self.assertFalse(any(Path(cmd[0]).name == "cp" or cmd[1] == "compare" for cmd in commands))

    def test_offline_does_not_create_missing_seal(self):
        self.args.existing_only = True
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_SEALED_CHECKPOINT_MISSING", context.exception.code)
        self.assertFalse(self.output.exists())

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_offline_set_failure_preserves_sealed_manifest(self, run_mock, _which):
        run_mock.side_effect = self.fake_run
        request = self.checkpoint_set_request()
        first = MODULE.execute_set(request)
        manifest = Path(first["checkpointSetManifestPath"])
        previous = manifest.read_bytes()
        for disk in request["disks"]:
            Path(disk["output"]).unlink()
        request["existingOnly"] = True
        with mock.patch.object(MODULE, "create_overlay", side_effect=MODULE.CheckpointError("TEST", "failure")):
            with self.assertRaises(MODULE.CheckpointError):
                MODULE.execute_set(request)
        self.assertEqual(previous, manifest.read_bytes())

    def checkpoint_set_request(self, disk_count=2):
        disks = []
        for index in range(disk_count):
            source = self.source if index == 0 else self.root / f"replica-data-{index}.qcow2"
            if index > 0:
                source.write_bytes(f"data-{index}".encode("ascii"))
            disks.append({
                "device": f"vd{chr(ord('a') + index)}",
                "source": str(source),
                "storageRoot": str(self.root),
                "output": str(self.root / f"test-disk-{index}.qcow2"),
                "sizeBytes": 4096 * (index + 1),
            })
        return {
            "plan": self.args.plan,
            "sequence": self.args.sequence,
            "checkpointRef": self.args.checkpoint_ref,
            "evidencePath": str(self.root / "evidence" / "inspection.json"),
            "disks": disks,
        }

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_multidisk_set_probe_attaches_all_disks_before_publish(self, run_mock, _which):
        inspector_commands = []

        def multidisk_run(command, **kwargs):
            if Path(command[0]).name == "virt-inspector":
                inspector_commands.append(command)
                return mock.Mock(
                    returncode=0,
                    stdout=("<operatingsystems><operatingsystem><name>linux</name>"
                            "<mountpoints>"
                            "<mountpoint dev='/dev/ubuntu-vg/ubuntu-lv'>/</mountpoint>"
                            "<mountpoint dev='/dev/vg_data/lv_data'>/DATA</mountpoint>"
                            "<mountpoint dev='/dev/sda2'>/boot</mountpoint>"
                            "</mountpoints></operatingsystem></operatingsystems>"),
                    stderr="",
                )
            if Path(command[0]).name == "virt-cat":
                return mock.Mock(
                    returncode=0,
                    stdout=("/dev/ubuntu-vg/ubuntu-lv / ext4 defaults 0 1\n"
                            "/dev/vg_data/lv_data /DATA xfs defaults 0 2\n"),
                    stderr="",
                )
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = multidisk_run
        result = MODULE.execute_set(self.checkpoint_set_request())

        self.assertEqual("PASSED", result["checkpointIntegrityState"])
        self.assertEqual(2, len(result["records"]))
        self.assertEqual(2, inspector_commands[0].count("-a"))
        self.assertIn(".probe-", " ".join(str(item) for item in inspector_commands[0]))
        self.assertTrue(all(Path(record["path"]).exists() for record in result["records"]))
        self.assertTrue(Path(result["checkpointSetManifestPath"]).is_file())

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_checkpoint_set_supports_all_mapped_disks_without_fixed_limit(self, run_mock, _which):
        inspector_commands = []

        def all_disk_run(command, **kwargs):
            if Path(command[0]).name == "virt-inspector":
                inspector_commands.append(command)
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = all_disk_run
        request = self.checkpoint_set_request(disk_count=8)
        result = MODULE.execute_set(request)

        self.assertEqual(8, len(result["records"]))
        self.assertEqual(8, inspector_commands[0].count("-a"))
        manifest = json.loads(Path(result["checkpointSetManifestPath"]).read_text(encoding="utf-8"))
        self.assertEqual(8, len(manifest["disks"]))
        self.assertEqual(
            [disk["device"] for disk in request["disks"]],
            [record["device"] for record in result["records"]],
        )

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_checkpoint_set_discards_all_four_disks_when_middle_disk_fails(self, run_mock, _which):
        def failing_middle_disk(command, **kwargs):
            if (Path(command[0]).name == "qemu-img" and command[1] == "compare"
                    and any(str(item).endswith("replica-data-2.qcow2") for item in command)):
                return mock.Mock(returncode=1, stdout="Content mismatch", stderr="")
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = failing_middle_disk
        request = self.checkpoint_set_request(disk_count=4)

        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute_set(request)

        self.assertEqual("DR_TEST_CHECKPOINT_CONTENT_MISMATCH", context.exception.code)
        checkpoint_dir = self.root / ".ftctl-dr-checkpoints" / self.args.plan / str(self.args.sequence)
        self.assertFalse(any(checkpoint_dir.glob("*.qcow2")))
        self.assertFalse(any(Path(disk["output"]).exists() for disk in request["disks"]))

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_multidisk_set_rejects_missing_required_data_mount(self, run_mock, _which):
        def missing_data_run(command, **kwargs):
            if Path(command[0]).name == "virt-inspector":
                return mock.Mock(
                    returncode=0,
                    stdout=("<operatingsystems><operatingsystem><name>linux</name>"
                            "<mountpoints><mountpoint dev='/dev/sda2'>/</mountpoint>"
                            "</mountpoints></operating-system></operatingsystems>"
                            .replace("operating-system", "operatingsystem")),
                    stderr=("libguestfs: error: /dev/mapper/vg_data-lv_data: No such file or directory\n"
                            "virt-inspector: some filesystems could not be mounted (ignored)"),
                )
            if Path(command[0]).name == "virt-cat":
                return mock.Mock(
                    returncode=0,
                    stdout=("/dev/ubuntu-vg/ubuntu-lv / ext4 defaults 0 1\n"
                            "/dev/vg_data/lv_data /DATA xfs defaults 0 2\n"),
                    stderr="",
                )
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = missing_data_run
        request = self.checkpoint_set_request()
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute_set(request)

        self.assertEqual("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", context.exception.code)
        self.assertIn("/DATA", str(context.exception))
        self.assertFalse(any(Path(item["output"]).exists() for item in request["disks"]))

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_multidisk_set_allows_missing_nofail_mount(self, run_mock, _which):
        def nofail_run(command, **kwargs):
            if Path(command[0]).name == "virt-inspector":
                return mock.Mock(
                    returncode=0,
                    stdout=("<operatingsystems><operatingsystem><name>linux</name>"
                            "<mountpoints><mountpoint dev='/dev/sda2'>/</mountpoint>"
                            "</mountpoints></operatingsystem></operatingsystems>"),
                    stderr="virt-inspector: some filesystems could not be mounted (ignored)",
                )
            if Path(command[0]).name == "virt-cat":
                return mock.Mock(
                    returncode=0,
                    stdout=("/dev/sda2 / ext4 defaults 0 1\n"
                            "UUID=optional /OPTIONAL xfs defaults,nofail 0 2\n"),
                    stderr="",
                )
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = nofail_run
        result = MODULE.execute_set(self.checkpoint_set_request())
        self.assertEqual("PASSED", result["checkpointIntegrityState"])

    @mock.patch.object(MODULE.subprocess, "run")
    def test_guest_error_summary_excludes_large_success_stdout(self, run_mock):
        run_mock.return_value = mock.Mock(
            returncode=0,
            stdout="<xml>" + ("package-description" * 50000) + "</xml>",
            stderr="some filesystems could not be mounted",
        )
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.strict_guest_command(["virt-inspector", "-a", "root.qcow2"])
        self.assertEqual("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", context.exception.code)
        self.assertLessEqual(len(str(context.exception)), MODULE.MAX_ERROR_MESSAGE_CHARS)
        self.assertNotIn("package-description", str(context.exception))


if __name__ == "__main__":
    unittest.main()
