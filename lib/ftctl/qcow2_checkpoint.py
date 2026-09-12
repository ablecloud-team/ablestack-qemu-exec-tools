#!/usr/bin/env python3
"""Seal and validate immutable SharedMountPoint qcow2 DR checkpoints."""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from argparse import Namespace
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree


class CheckpointError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


MAX_ERROR_MESSAGE_CHARS = 4096


def compact_error_detail(value, limit=MAX_ERROR_MESSAGE_CHARS):
    text = " ".join(str(value or "").split())
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 24)].rstrip() + " ... [detail truncated]"


def safe_component(value):
    text = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(value or "")).strip("-.")
    if not text:
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", "empty checkpoint path component")
    return text[:96]


def require_tool(name):
    path = shutil.which(name)
    if not path:
        raise CheckpointError("DR_TEST_CHECKPOINT_INSPECTOR_UNAVAILABLE", f"required tool is unavailable: {name}")
    return path


def run(command, *, input_text=None):
    result = subprocess.run(
        command,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "command failed").strip()
        raise CheckpointError("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", detail)
    return result.stdout


def fsync_path(path):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0))
    except OSError:
        if os.name == "nt" and Path(path).is_dir():
            return
        raise
    try:
        try:
            os.fsync(fd)
        except OSError:
            if os.name != "nt":
                raise
    finally:
        os.close(fd)


def canonical_under(path, root, *, must_exist=False):
    root_path = Path(root).resolve(strict=True)
    path_obj = Path(path).resolve(strict=must_exist)
    try:
        path_obj.relative_to(root_path)
    except ValueError as exc:
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_CONTRACT_INVALID",
            f"path escapes SharedMountPoint root: {path_obj}",
        ) from exc
    return path_obj, root_path


def contract_digest(metadata):
    canonical = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def image_info(qemu_img, path, *, force_share=False):
    command = [qemu_img, "info", "--output=json"]
    if force_share:
        command.append("--force-share")
    command.append(str(path))
    try:
        return json.loads(run(command))
    except (ValueError, CheckpointError) as exc:
        if isinstance(exc, CheckpointError):
            raise
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", f"invalid qemu-img info for {path}") from exc


def check_image(qemu_img, path):
    result = subprocess.run(
        [qemu_img, "check", "-q", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "qemu-img check failed").strip()
        raise CheckpointError("DR_TEST_CHECKPOINT_QCOW2_INVALID", detail)


def compare_images(qemu_img, source, source_format, checkpoint):
    result = subprocess.run(
        [qemu_img, "compare", "-f", str(source_format or "qcow2"), "-F", "qcow2",
         str(source), str(checkpoint)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "checkpoint differs from drained target").strip()
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTENT_MISMATCH", detail)


def writable_holders(path):
    expected = path.resolve(strict=True)
    holders = []
    proc_root = Path("/proc")
    if not proc_root.is_dir():
        return holders
    for process in proc_root.iterdir():
        if not process.name.isdigit():
            continue
        try:
            descriptors = list((process / "fd").iterdir())
        except OSError:
            continue
        for descriptor in descriptors:
            try:
                if descriptor.resolve(strict=True) != expected:
                    continue
                flags_text = (process / "fdinfo" / descriptor.name).read_text(encoding="utf-8")
                flags_line = next((line for line in flags_text.splitlines() if line.startswith("flags:")), "")
                flags = int(flags_line.split()[1], 8) if flags_line else 0
                if flags & os.O_ACCMODE not in (os.O_WRONLY, os.O_RDWR):
                    continue
                command = (process / "comm").read_text(encoding="utf-8").strip()
                holders.append(f"pid={process.name} command={command or 'unknown'} fd={descriptor.name}")
            except (OSError, ValueError):
                continue
    return holders


def ensure_source_quiescent(source):
    holders = writable_holders(source)
    if holders:
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_WRITER_NOT_DRAINED",
            "drained target still has writable holders: " + "; ".join(holders[:4]),
        )


def strict_guest_result(result, *, allow_mount_warnings=False):
    stderr = (result.stderr or "").strip()
    stdout = (result.stdout or "").strip()
    diagnostic = stderr or (stdout if result.returncode != 0 else "")
    lowered = "\n".join(part for part in (stderr, stdout if result.returncode != 0 else "") if part).lower()
    unavailable_markers = (
        "unsupported filesystem type",
        "unknown filesystem type",
        "ntfs-3g: not found",
        "mount.ntfs: not found",
    )
    unsafe_markers = (
        "structure needs cleaning",
        "mount exited with status",
        "input/output error",
        "filesystem is inconsistent",
    )
    if not allow_mount_warnings:
        unsafe_markers += ("some filesystems could not be mounted",)
    if any(marker in lowered for marker in unavailable_markers):
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_GUEST_FS_DRIVER_UNAVAILABLE",
            compact_error_detail(diagnostic or "guest filesystem driver is unavailable"),
        )
    if result.returncode != 0 or any(marker in lowered for marker in unsafe_markers):
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT",
            compact_error_detail(diagnostic or "guest filesystem inspection failed"),
        )
    return result.stdout


def strict_guest_command(command, *, input_text=None, allow_mount_warnings=False):
    result = subprocess.run(
        command,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return strict_guest_result(result, allow_mount_warnings=allow_mount_warnings)


def windows_root_device(inspection_root):
    device = str(inspection_root.findtext(".//root") or "").strip()
    if not re.fullmatch(r"/dev/[A-Za-z0-9._/+:-]+", device):
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT",
            "Windows root filesystem device could not be determined",
        )
    return device


def disk_arguments(paths):
    arguments = []
    for path in paths:
        arguments.extend(["-a", str(path)])
    return arguments


def probe_windows_root(guestfish, probes, inspection_root):
    device = windows_root_device(inspection_root)
    mountpoint = "/tmp/ftctl-windows-root"
    shell = (
        "set -eu; "
        f"rm -rf {shlex.quote(mountpoint)}; mkdir -p {shlex.quote(mountpoint)}; "
        f"/usr/bin/ntfs-3g -o ro {shlex.quote(device)} {shlex.quote(mountpoint)}; "
        f"test -f {shlex.quote(mountpoint + '/Windows/System32/config/SYSTEM')}; "
        f"umount {shlex.quote(mountpoint)}; rmdir {shlex.quote(mountpoint)}"
    )
    script = "run\ndebug sh " + json.dumps(shell) + "\n"
    strict_guest_command([guestfish, "--ro", *disk_arguments(probes)], input_text=script)


def required_local_mounts(fstab):
    mounts = []
    local_prefixes = ("/dev/", "UUID=", "LABEL=", "PARTUUID=", "PARTLABEL=")
    network_filesystems = {"nfs", "nfs4", "cifs", "smb3", "sshfs", "9p", "ceph", "glusterfs"}
    for raw_line in str(fstab or "").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 4:
            continue
        source, mountpoint, filesystem, options = fields[:4]
        option_set = {item.strip().lower() for item in options.split(",")}
        if mountpoint in ("none", "swap") or filesystem.lower() == "swap":
            continue
        if {"nofail", "noauto", "_netdev", "x-systemd.automount"} & option_set:
            continue
        if filesystem.lower() in network_filesystems or source.startswith("//"):
            continue
        if not source.startswith(local_prefixes):
            continue
        mounts.append((source, mountpoint.replace("\\040", " ")))
    return mounts


def load_sealed(args, *, probe=True):
    """Read immutable evidence; never manufacture a checkpoint from mutable data."""
    source, root = canonical_under(args.source, args.storage_root, must_exist=True)
    directory = root / ".ftctl-dr-checkpoints" / safe_component(args.plan) / str(int(args.sequence))
    checkpoint = directory / (safe_component(args.device) + ".qcow2")
    metadata_path = checkpoint.with_suffix(".json")
    try:
        metadata = json.loads(metadata_path.read_text())
    except (OSError, ValueError) as exc:
        raise CheckpointError("DR_TEST_SEALED_CHECKPOINT_MISSING", "requested immutable target checkpoint is absent") from exc
    expected = {"planUuid": args.plan, "checkpointSequence": int(args.sequence),
                "checkpointRef": args.checkpoint_ref, "device": args.device, "sourcePath": str(source)}
    digest = dict(metadata)
    supplied = digest.pop("contractSha256", None)
    if supplied != contract_digest(digest) or any(metadata.get(k) != v for k, v in expected.items()):
        raise CheckpointError("DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH", "immutable checkpoint identity does not match request")
    canonical_under(checkpoint, root, must_exist=True)
    qemu_img = require_tool("qemu-img")
    ensure_source_quiescent(checkpoint)
    check_image(qemu_img, checkpoint)
    if probe:
        probe_checkpoint(qemu_img, checkpoint, directory)
    return checkpoint, metadata_path, metadata, True


def seal(args, *, probe=True):
    qemu_img = require_tool("qemu-img")
    copy_tool = require_tool("cp")
    source, root = canonical_under(args.source, args.storage_root, must_exist=True)
    if not source.is_file():
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", f"target file does not exist: {source}")

    plan = safe_component(args.plan)
    sequence = int(args.sequence)
    if sequence <= 0:
        raise CheckpointError("DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH", "checkpoint sequence must be positive")
    device = safe_component(args.device)
    checkpoint_dir = root / ".ftctl-dr-checkpoints" / plan / str(sequence)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = checkpoint_dir / f"{device}.qcow2"
    metadata_path = checkpoint.with_suffix(".json")

    ensure_source_quiescent(source)
    fsync_path(source)
    fsync_path(source.parent)
    source_info = image_info(qemu_img, source, force_share=False)
    if source_info.get("format") != "qcow2":
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_CONTRACT_INVALID",
            f"SharedMountPoint checkpoint source must be qcow2, got {source_info.get('format') or 'unknown'}",
        )
    source_stat = source.stat()
    expected = {
        "version": 2,
        "planUuid": args.plan,
        "checkpointSequence": sequence,
        "checkpointRef": args.checkpoint_ref,
        "device": args.device,
        "sourcePath": str(source),
        "sourceFormat": source_info.get("format"),
        "virtualSize": source_info.get("virtual-size"),
        "sourceFileSize": source_stat.st_size,
        "sourceMtimeNs": source_stat.st_mtime_ns,
    }
    expected["contractSha256"] = contract_digest(expected)

    if checkpoint.exists() or metadata_path.exists():
        if not checkpoint.is_file() or not metadata_path.is_file():
            raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", "partial immutable checkpoint exists")
        with metadata_path.open("r", encoding="utf-8") as handle:
            actual = json.load(handle)
        if actual != expected:
            raise CheckpointError("DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH", "immutable checkpoint metadata does not match request")
        check_image(qemu_img, checkpoint)
        compare_images(qemu_img, source, source_info.get("format"), checkpoint)
        if probe:
            probe_checkpoint(qemu_img, checkpoint, checkpoint_dir)
        return checkpoint, metadata_path, expected, True

    fd, temp_name = tempfile.mkstemp(prefix=f".{device}.", suffix=".tmp", dir=checkpoint_dir)
    os.close(fd)
    os.unlink(temp_name)
    temp_path = Path(temp_name)
    metadata_temp = metadata_path.with_name(f".{metadata_path.name}.{os.getpid()}.tmp")
    try:
        copy_command = ([qemu_img, "convert", "-f", "qcow2", "-O", "qcow2", str(source), str(temp_path)]
                        if source_info.get("backing-filename") else
                        [copy_tool, "--reflink=auto", "--sparse=always", "--", str(source), str(temp_path)])
        result = subprocess.run(
            copy_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise CheckpointError(
                "DR_TEST_CHECKPOINT_SEAL_FAILED",
                (result.stderr or result.stdout or "qcow2 container copy failed").strip(),
            )
        check_image(qemu_img, temp_path)
        compare_images(qemu_img, source, source_info.get("format"), temp_path)
        if probe:
            probe_checkpoint(qemu_img, temp_path, checkpoint_dir)
        fsync_path(temp_path)
        os.replace(temp_path, checkpoint)
        with metadata_temp.open("w", encoding="utf-8") as handle:
            json.dump(expected, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(metadata_temp, metadata_path)
        fsync_path(checkpoint_dir)
    finally:
        if temp_path.exists():
            temp_path.unlink()
        if metadata_temp.exists():
            metadata_temp.unlink()
    return checkpoint, metadata_path, expected, False


def create_overlay(qemu_img, backing, output):
    # GC and overlay creation share the target storage lock across workers.
    from dr_checkpoint_store import overlay_guard
    with overlay_guard(backing, output):
        return _create_overlay(qemu_img, backing, output)


def _create_overlay(qemu_img, backing, output):
    if output.exists():
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", f"test artifact already exists: {output}")
    result = subprocess.run(
        [qemu_img, "create", "-f", "qcow2", "-F", "qcow2", "-b", str(backing), str(output)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise CheckpointError("DR_TEST_MATERIALIZATION_FAILED", (result.stderr or result.stdout).strip())
    check_image(qemu_img, output)


def write_probe_evidence(path, command, result):
    if not path:
        return
    evidence = Path(path)
    evidence.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "command": [str(item) for item in command],
        "returnCode": result.returncode,
        "stdout": result.stdout or "",
        "stderr": result.stderr or "",
    }
    temporary = evidence.with_name(f".{evidence.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, evidence)
    fsync_path(evidence.parent)


def probe_checkpoint_set(qemu_img, checkpoints, checkpoint_dir, evidence_path=None):
    virt_inspector = require_tool("virt-inspector")
    guestfish = require_tool("guestfish")
    virt_cat = require_tool("virt-cat")
    virt_ls = require_tool("virt-ls")
    probes = []
    try:
        for index, checkpoint in enumerate(checkpoints):
            probe = checkpoint_dir / f".probe-{os.getpid()}-{index}.qcow2"
            create_overlay(qemu_img, checkpoint, probe)
            probes.append(probe)
        inspect_command = [virt_inspector, *disk_arguments(probes)]
        inspect_result = subprocess.run(
            inspect_command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        write_probe_evidence(evidence_path, inspect_command, inspect_result)
        inspection = strict_guest_result(inspect_result, allow_mount_warnings=True)
        try:
            root = ElementTree.fromstring(inspection)
            operating_systems = root.findall(".//operatingsystem")
        except ElementTree.ParseError as exc:
            raise CheckpointError("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", "invalid virt-inspector output") from exc
        if len(operating_systems) != 1:
            raise CheckpointError(
                "DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT",
                f"expected one bootable operating system, discovered {len(operating_systems)}",
            )
        operating_system = operating_systems[0]
        guest_name = str(operating_system.findtext("name") or "").lower()
        if guest_name == "windows":
            probe_windows_root(guestfish, probes, operating_system)
        else:
            fstab = strict_guest_command(
                [virt_cat, *disk_arguments(probes), "/etc/fstab"],
                allow_mount_warnings=True,
            )
            discovered_mounts = {
                str(item.text or "").strip()
                for item in operating_system.findall(".//mountpoint")
                if str(item.text or "").strip()
            }
            missing_mounts = [
                (source, mountpoint)
                for source, mountpoint in required_local_mounts(fstab)
                if mountpoint not in discovered_mounts
            ]
            if missing_mounts:
                source, mountpoint = missing_mounts[0]
                raise CheckpointError(
                    "DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT",
                    f"required local mount {mountpoint} ({source}) was not resolved from the checkpoint disk set",
                )
        if guest_name == "linux":
            strict_guest_command(
                [virt_ls, *disk_arguments(probes), "-l", "/boot"],
                allow_mount_warnings=True,
            )
    finally:
        for probe in probes:
            if probe.exists():
                probe.unlink()


def probe_checkpoint(qemu_img, checkpoint, checkpoint_dir):
    probe_checkpoint_set(qemu_img, [checkpoint], checkpoint_dir)


def checkpoint_set_manifest(checkpoints, metadata, plan, sequence, checkpoint_ref):
    payload = {
        "version": 1,
        "planUuid": plan,
        "checkpointSequence": sequence,
        "checkpointRef": checkpoint_ref,
        "disks": [
            {
                "device": item["device"],
                "checkpointPath": str(checkpoint),
                "contractSha256": item["contractSha256"],
            }
            for checkpoint, item in zip(checkpoints, metadata)
        ],
    }
    payload["contractSha256"] = contract_digest(payload)
    return payload


def execute_set(request):
    plan = str(request.get("plan") or "")
    sequence = int(request.get("sequence") or 0)
    checkpoint_ref = str(request.get("checkpointRef") or "")
    disks = request.get("disks")
    evidence_path = str(request.get("evidencePath") or "")
    if not plan or sequence <= 0 or not checkpoint_ref or not isinstance(disks, list) or not disks:
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", "checkpoint set request is incomplete")
    devices = [str(item.get("device") or "") for item in disks if isinstance(item, dict)]
    outputs = [str(item.get("output") or "") for item in disks if isinstance(item, dict)]
    if len(devices) != len(disks) or len(set(devices)) != len(devices) or len(set(outputs)) != len(outputs):
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", "checkpoint set disk identities are not unique")

    storage_roots = []
    for disk in disks:
        source, storage_root = canonical_under(
            disk.get("source"), disk.get("storageRoot"), must_exist=True)
        ensure_source_quiescent(source)
        storage_roots.append(storage_root)
    common_root = storage_roots[0]
    if any(storage_root != common_root for storage_root in storage_roots):
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", "checkpoint set spans multiple storage roots")

    qemu_img = require_tool("qemu-img")
    checkpoints = []
    metadata_paths = []
    metadata = []
    reused = []
    created_outputs = []
    newly_sealed = []
    set_manifest_path = None
    published_manifest = False
    try:
        for disk in disks:
            args = Namespace(
                plan=plan,
                sequence=sequence,
                checkpoint_ref=checkpoint_ref,
                device=disk.get("device"),
                source=disk.get("source"),
                storage_root=disk.get("storageRoot"),
                output=disk.get("output"),
            )
            checkpoint, metadata_path, expected, was_reused = (load_sealed if request.get("existingOnly") is True else seal)(args, probe=False)
            checkpoints.append(checkpoint)
            metadata_paths.append(metadata_path)
            metadata.append(expected)
            reused.append(was_reused)
            if not was_reused:
                newly_sealed.append((checkpoint, metadata_path))

        checkpoint_dir = common_root / ".ftctl-dr-checkpoints" / safe_component(plan) / str(sequence)
        probe_checkpoint_set(qemu_img, checkpoints, checkpoint_dir, evidence_path=evidence_path)

        set_manifest = checkpoint_set_manifest(checkpoints, metadata, plan, sequence, checkpoint_ref)
        set_manifest_path = checkpoint_dir / "checkpoint-set.json"
        if request.get("existingOnly") is True:
            if not set_manifest_path.is_file():
                raise CheckpointError("DR_TEST_SEALED_CHECKPOINT_MISSING", "sealed disk set manifest is missing")
            if json.loads(set_manifest_path.read_text(encoding="utf-8")) != set_manifest:
                raise CheckpointError("DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH", "sealed disk set differs from request")
        else:
            temporary_manifest = set_manifest_path.with_name(f".{set_manifest_path.name}.{os.getpid()}.tmp")
            with temporary_manifest.open("w", encoding="utf-8") as handle:
                json.dump(set_manifest, handle, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_manifest, set_manifest_path)
            fsync_path(checkpoint_dir)
            published_manifest = True

        records = []
        for disk, checkpoint, metadata_path, expected, was_reused in zip(
                disks, checkpoints, metadata_paths, metadata, reused):
            output = Path(str(disk.get("output") or ""))
            create_overlay(qemu_img, checkpoint, output)
            created_outputs.append(output)
            records.append({
                "device": disk.get("device"),
                "source": disk.get("source"),
                "sizeBytes": disk.get("sizeBytes") or 0,
                "state": "CREATED",
                "type": "qcow2-checkpoint-overlay",
                "path": str(output),
                "storageRoot": str(Path(str(disk.get("storageRoot") or "")).resolve(strict=True)),
                "ownedByFtctl": True,
                "checkpointPath": str(checkpoint),
                "checkpointMetadataPath": str(metadata_path),
                "checkpointSetManifestPath": str(set_manifest_path),
                "checkpointEvidencePath": evidence_path,
                "checkpointSequence": expected["checkpointSequence"],
                "checkpointRef": expected["checkpointRef"],
                "checkpointContractSha256": expected["contractSha256"],
                "checkpointSetContractSha256": set_manifest["contractSha256"],
                "checkpointSealState": "SEALED",
                "checkpointIntegrityState": "PASSED",
                "checkpointReused": was_reused,
            })
        return {
            "state": "CREATED",
            "type": "qcow2-checkpoint-set",
            "checkpointSequence": sequence,
            "checkpointRef": checkpoint_ref,
            "checkpointSetManifestPath": str(set_manifest_path),
            "checkpointSetContractSha256": set_manifest["contractSha256"],
            "checkpointIntegrityState": "PASSED",
            "records": records,
        }
    except Exception:
        for output in created_outputs:
            if output.exists():
                output.unlink()
        if published_manifest and set_manifest_path and set_manifest_path.exists():
            set_manifest_path.unlink()
        for checkpoint, metadata_path in newly_sealed:
            if checkpoint.exists():
                checkpoint.unlink()
            if metadata_path.exists():
                metadata_path.unlink()
        raise


def execute(args):
    checkpoint, metadata_path, metadata, reused = (load_sealed if getattr(args, "existing_only", False) else seal)(args)
    qemu_img = require_tool("qemu-img")
    output, root = canonical_under(args.output, args.storage_root, must_exist=False)
    output.parent.mkdir(parents=True, exist_ok=True)
    create_overlay(qemu_img, checkpoint, output)
    return {
        "state": "CREATED",
        "type": "qcow2-checkpoint-overlay",
        "path": str(output),
        "storageRoot": str(root),
        "ownedByFtctl": True,
        "checkpointPath": str(checkpoint),
        "checkpointMetadataPath": str(metadata_path),
        "checkpointSequence": metadata["checkpointSequence"],
        "checkpointRef": metadata["checkpointRef"],
        "checkpointContractSha256": metadata["contractSha256"],
        "checkpointSealState": "SEALED",
        "checkpointIntegrityState": "PASSED",
        "checkpointReused": reused,
    }


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--existing-only", action="store_true")
    parser.add_argument("--set-request")
    parser.add_argument("--plan")
    parser.add_argument("--sequence", type=int)
    parser.add_argument("--checkpoint-ref")
    parser.add_argument("--device")
    parser.add_argument("--source")
    parser.add_argument("--storage-root")
    parser.add_argument("--output")
    return parser.parse_args()


def main():
    try:
        args = parse_args()
        if args.set_request:
            if args.set_request == "-":
                request = json.load(sys.stdin)
            else:
                with open(args.set_request, "r", encoding="utf-8") as handle:
                    request = json.load(handle)
            result = execute_set(request)
        else:
            required = (args.plan, args.sequence, args.checkpoint_ref, args.device,
                        args.source, args.storage_root, args.output)
            if any(value is None for value in required):
                raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", "single-disk checkpoint request is incomplete")
            result = execute(args)
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except CheckpointError as exc:
        print(json.dumps({"state": "FAILED", "errorCode": exc.code,
                          "errorMessage": compact_error_detail(exc)}, sort_keys=True), file=sys.stderr)
        return 46
    except Exception as exc:  # keep an actionable structured failure at the Agent boundary
        print(json.dumps({"state": "FAILED", "errorCode": "DR_TEST_CHECKPOINT_SEAL_FAILED",
                          "errorMessage": compact_error_detail(exc)}, sort_keys=True), file=sys.stderr)
        return 46


if __name__ == "__main__":
    sys.exit(main())
