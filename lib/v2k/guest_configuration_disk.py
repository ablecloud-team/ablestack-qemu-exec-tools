#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Private libguestfs appliance. Never opens a handed-off image."""
import json, os, re, struct, subprocess, tempfile
from pathlib import Path


class Disk:
    def __init__(self, path, fmt="qcow2", readonly=True):
        self.path = path
        self.fmt = fmt
        self.readonly = readonly
        self.pid = None

    def __enter__(self):
        args = ["guestfish", "--listen", "--format=" + self.fmt, "-a", self.path]
        if self.readonly:
            args.insert(1, "--ro")
        # The forked listener retains descriptors; PIPE communicate would wait for its lifetime.
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            subprocess.run(
                args,
                env={**os.environ, "LIBGUESTFS_BACKEND": "direct"},
                stdout=output,
                stderr=errors,
                timeout=60,
                check=True,
            )
            output.seek(0)
            text = output.read(65536).decode()
        match = re.search(r"GUESTFISH_PID=(\d+)", text)
        if not match:
            raise ValueError("GUESTFS_SESSION_UNAVAILABLE")
        self.pid = match.group(1)
        try:
            self.call("run")
        except Exception:
            self.__exit__()
            raise
        return self

    def __exit__(self, *args):
        if self.pid:
            try:
                if not self.readonly:
                    self.call("sync")
                self.call("exit")
            except Exception:
                pass

    def call(self, method, *args, binary=False):
        result = subprocess.run(
            ["guestfish", "--remote=" + self.pid, method, *map(str, args)],
            capture_output=True,
            timeout=180,
        )
        if result.returncode:
            raise ValueError("GUESTFS_" + method.upper().replace("-", "_") + "_FAILED")
        return result.stdout if binary else result.stdout.decode().strip()

    def lines(self, method, *args):
        return self.call(method, *args).splitlines()

    def inspect(self, allow_whole_filesystem=False):
        if allow_whole_filesystem:
            try:
                fs_type = self.call("vfs-type", "/dev/sda")
            except ValueError:
                fs_type = ""
            if fs_type in ("ext4", "xfs"):
                fs_uuid = self.call("vfs-uuid", "/dev/sda").lower()
                if not fs_uuid:
                    raise ValueError("DATA_IDENTITY_UNSUPPORTED")
                return {"identity": "fs:" + fs_uuid, "partitions": [], "filesystem": fs_type}
        kind = self.call("part-get-parttype", "/dev/sda")
        parts = []
        for block in re.findall(
            r"\[\d+\] = \{(.*?)\}", self.call("part-list", "/dev/sda"), re.S
        ):
            props = dict(re.findall(r"(\w+):\s*(\d+)", block))
            number = int(props["part_num"])
            start = int(props["part_start"])
            size = int(props["part_size"])
            guid = (
                self.call("part-get-gpt-guid", "/dev/sda", number).lower().strip("{}")
                if kind == "gpt"
                else ""
            )
            parts.append(
                {"guid": guid, "offset": start, "size_bytes": size, "number": number}
            )
        if kind == "gpt":
            identity = "gpt:" + self.call(
                "part-get-disk-guid", "/dev/sda"
            ).lower().strip("{}")
        elif kind == "msdos":
            raw = self.call("pread-device", "/dev/sda", 4, 440, binary=True)
            identity = "mbr:" + format(struct.unpack("<I", raw[:4])[0], "08x")
        else:
            raise ValueError("DATA_IDENTITY_UNSUPPORTED")
        return {"identity": identity, "partitions": parts}

    def mount_root(self):
        roots = self.lines("inspect-os")
        if len(roots) != 1:
            raise ValueError("ROOT_IDENTITY_AMBIGUOUS")
        root = roots[0]
        os_kind = self.call("inspect-get-type", root)
        mounts = []
        for line in self.lines("inspect-get-mountpoints", root):
            point, device = line.split(": ", 1)
            mounts.append((point, device))
        for point, device in sorted(mounts, key=lambda x: len(x[0])):
            if os_kind == "windows" and not self.readonly:
                state = self.call("ntfs-3g-probe", "true", device)
                if state != "0":
                    raise ValueError("WINDOWS_CLEAN_SHUTDOWN_REQUIRED_NTFS_" + state)
            self.call("mount-ro" if self.readonly else "mount", device, point)
        return root, os_kind

    def read(self, path):
        return self.call("cat", path)

    def exists(self, path):
        return self.call("exists", path) == "true"

    def write(self, path, content, mode="0600"):
        if self.readonly:
            raise ValueError("READONLY_GUESTFS_SESSION")
        self.call("mkdir-p", str(Path(path).parent))
        with tempfile.NamedTemporaryFile() as f:
            f.write(content.encode())
            f.flush()
            self.call("upload", f.name, path)
        self.call("chmod", mode, path)

    def upload(self, source, target):
        if self.readonly:
            raise ValueError("READONLY_GUESTFS_SESSION")
        self.call("mkdir-p", str(Path(target).parent))
        self.call("upload", source, target)


def image_inspect(manifest):
    result = []
    for disk in manifest["disks"]:
        with Disk(
            disk["transfer"]["target_path"], manifest["target"].get("format", "qcow2")
        ) as image:
            result.append(image.inspect(manifest.get("source", {}).get("guest_configuration", {}).get("os") == "linux"))
    return result
