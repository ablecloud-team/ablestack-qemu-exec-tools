#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Prepare only private stopped clones, before the first import UUID exists."""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
from guest_configuration import atomic, build, canonical, fail, verify, seal
from guest_configuration_disk import Disk, image_inspect
from guest_configuration_assets import resolve_appliance, file_sha
from guest_configuration_networkmanager import config_path
from guest_configuration_rocky_assets import payloads as rocky_payloads
from guest_configuration_windows_drivers import payloads as windows_driver_payloads

WINDOWS_ROOT = (
    "/usr/share/ablestack/v2k/guest-config/windows"
    if Path(
        "/usr/share/ablestack/v2k/guest-config/windows/guest-agent/qemu-ga-x86_64.msi"
    ).is_file()
    else "/usr/share/virtio-win"
)


def require_unsealed(manifest):
    checkpoint = manifest.get("runtime", {}).get("cloud", {}).get("checkpoint", {})
    if (
        checkpoint.get("root_volume_id")
        or checkpoint.get("vm_id")
        or checkpoint.get("data_volumes")
        or any(
            d.get("transfer", {}).get("cloud_allocation", {}).get("request_id")
            for d in manifest["disks"]
        )
    ):
        fail("CLOUD_TARGET_SEALED")


def payloads(directory, expected_version="22.04"):
    path = Path(directory)
    m = json.loads((path / "assets.json").read_text())
    if (
        m.get("os") != "ubuntu"
        or m.get("os_version") != expected_version
        or m.get("arch") != "amd64"
        or m.get("provenance")
        not in ["signed-inrelease", "official-https-index-sha256"]
    ):
        fail("GUEST_CONFIG_PAYLOAD_UNQUALIFIED")
    out = []
    for f in m["files"]:
        p = path / f["file"]
        if (
            p.parent != path
            or not re.fullmatch("[A-Za-z0-9+_.~-]+\.deb", p.name)
            or hashlib.sha256(p.read_bytes()).hexdigest() != f["sha256"]
        ):
            fail("GUEST_CONFIG_PAYLOAD_HASH_MISMATCH")
        out.append(p)
    if not out:
        fail("GUEST_CONFIG_PAYLOAD_MISSING")
    return out, m


def ubuntu_asset_directory(version):
    return os.environ.get("V2K_GUEST_CONFIG_UBUNTU_ASSETS", "/usr/share/ablestack/v2k/guest-config/" + ("ubuntu24" if version == "24.04" else "ubuntu22"))


def preflight(manifest):
    require_unsealed(manifest)
    if (
        manifest["target"].get("provider") != "ablestack-cloud"
        or manifest["target"]["storage"]["type"] != "file"
        or manifest["target"].get("format") != "qcow2"
    ):
        fail("GUEST_CONFIG_TARGET_UNSUPPORTED")
    for name in ["guestfish", "virt-customize"]:
        if not shutil.which(name):
            fail("FIRSTBOOT_CAPABILITY_MISSING")
    source = manifest["source"]["vm"]
    windows = manifest["source"].get("guest_configuration", {}).get("os") == "windows" or source.get("guestFamily") == "windowsGuest" or source.get(
        "guest_id", ""
    ).lower().startswith("win")
    if windows:
        if manifest["source"].get("pc"):
            windows_driver_payloads()
        appliance = Path(
            os.environ.get(
                "V2K_GUEST_CONFIG_APPLIANCE",
                "/usr/share/ablestack/v2k/guest-config/appliance",
            )
        )
        if not (appliance / "assets.json").is_file():
            fail("GUEST_CONFIG_NTFS_APPLIANCE_REQUIRED")
        info = json.loads(
            (appliance / "assets.json").read_text(errors="surrogateescape")
        )
        if (
            info.get("version") != "1.58.1"
            or info.get("archive_sha256")
            != "6779ce3fc820a28c1607729892e53a1ba418be4480f52e0457bb381eab408a72"
        ):
            fail("GUEST_CONFIG_APPLIANCE_UNQUALIFIED")
        for name in ["kernel", "initrd", "root"]:
            if file_sha(appliance / name) != info["files"][name]:
                fail("GUEST_CONFIG_APPLIANCE_HASH_MISMATCH")
        # Scope to this preparation process; never replace the host's appliance.
        os.environ["LIBGUESTFS_PATH"] = str(appliance)
        native = Path(
            os.environ.get(
                "V2K_GUEST_CONFIG_NATIVE",
                "/usr/share/ablestack/v2k/guest-config/native",
            )
        )
        if not (native / "assets.json").is_file():
            fail("GUEST_CONFIG_NATIVE_TOOLS_REQUIRED")
        metadata = json.loads((native / "assets.json").read_text())
        if (
            metadata.get("version") != "1.58.1"
            or metadata.get("arch") != "x86_64"
            or metadata.get("source_sha256")
            != "1b8e5b4ef43e86302c3cedcb6fbc014be5bca5e85ca2875ef17c3cf67c671180"
        ):
            fail("GUEST_CONFIG_NATIVE_UNQUALIFIED")
        for name in ["bin/guestfish", "lib/libguestfs.so.0"]:
            if (
                hashlib.sha256((native / name).read_bytes()).hexdigest()
                != metadata["files"][name]
            ):
                fail("GUEST_CONFIG_NATIVE_HASH_MISMATCH")
        os.environ["PATH"] = (
            str(native / "bin") + os.pathsep + os.environ.get("PATH", "")
        )
        os.environ["LD_LIBRARY_PATH"] = str(native / "lib")
        version = subprocess.check_output(
            ["virt-customize", "--version"], text=True, timeout=15
        )
        if not re.search(r"\b1\.52\.2\b", version):
            fail("FIRSTBOOT_VERSION_UNQUALIFIED")
        firstboot = Path(os.environ.get("VIRT_TOOLS_DATA_DIR", "/usr/share/virt-tools"))
        if not any(
            (firstboot / name).is_file() for name in ["rhsrvany.exe", "pvvxsvc.exe"]
        ):
            fail("FIRSTBOOT_CAPABILITY_MISSING")
        msi = (
            Path(os.environ.get("V2K_GUEST_CONFIG_VIRTIO_ROOT", WINDOWS_ROOT))
            / "guest-agent/qemu-ga-x86_64.msi"
        )
        if not msi.is_file():
            fail("GUEST_AGENT_PAYLOAD_MISSING")
        metadata = msi.parent.parent / "assets.json"
        if (
            metadata.is_file()
            and hashlib.sha256(msi.read_bytes()).hexdigest()
            != json.loads(metadata.read_text())["files"][
                "guest-agent/qemu-ga-x86_64.msi"
            ]
        ):
            fail("GUEST_AGENT_PAYLOAD_HASH_MISMATCH")
    else:
        os_id = manifest["source"].get("guest_configuration", {}).get("os_id")
        captured = manifest["source"].get("guest_configuration", {})
        existing_qga = captured.get("qga", {})
        if os_id == "rocky" and existing_qga.get("installed"):
            if not existing_qga.get("rpm_verified") or not re.fullmatch("[a-f0-9]{64}", existing_qga.get("policy_sha256", "")):
                fail("EXISTING_QGA_POLICY_REQUIRES_REVIEW")
        elif os_id == "rocky":
            if captured.get("os_version") != "9.7":
                fail("GUEST_AGENT_PAYLOAD_MISSING")
            rocky_payloads(
                os.environ.get(
                    "V2K_GUEST_CONFIG_ROCKY_ASSETS",
                    "/usr/share/ablestack/v2k/guest-config/rocky97",
                )
            )
        elif os_id == "ubuntu":
            payloads(
                ubuntu_asset_directory(captured.get("os_version", "22.04")), captured.get("os_version", "22.04")
            )
        elif not any(
            (Path(os.environ.get(var, default)) / "assets.json").is_file()
            for var, default in [
                (
                    "V2K_GUEST_CONFIG_UBUNTU_ASSETS",
                    "/usr/share/ablestack/v2k/guest-config/ubuntu22",
                ),
                (
                    "V2K_GUEST_CONFIG_ROCKY_ASSETS",
                    "/usr/share/ablestack/v2k/guest-config/rocky97",
                ),
            ]
        ):
            fail("GUEST_AGENT_PAYLOAD_MISSING")


def normalize_capture(capture):
    capture = json.loads(json.dumps(capture))
    if capture["os"] == "windows":
        for disk in capture["disks"]:
            for part in disk["partitions"]:
                paths = []
                for p in part["access_paths"]:
                    if not re.fullmatch(r"[A-Za-z]:\\+", p):
                        fail("ACCESS_PATH_UNSUPPORTED")
                    paths.append(p[0].upper() + ":" + chr(92))
                part["access_paths"] = paths
    return capture


def prepare(manifest_path):
    # Hash and upload the same immutable bytes, even across an operator upgrade.
    with tempfile.TemporaryDirectory(prefix="v2k-guest-config-payload-") as temp:
        snapshot = Path(temp)
        for source in (Path(__file__).parent / "guest-config").iterdir():
            if source.is_file() and source.suffix in [
                ".py",
                ".ps1",
                ".cmd",
                ".service",
                ".path",
                ".timer",
                ".cil",
            ]:
                (snapshot / source.name).write_bytes(source.read_bytes())
        return _prepare(manifest_path, snapshot)


def _prepare(manifest_path, payload):
    path = Path(manifest_path)
    m = json.loads(path.read_text())
    preflight(m)
    capture = normalize_capture(m["source"]["guest_configuration"])
    root_path = m["disks"][0]["transfer"]["target_path"]
    fmt = m["target"]["format"]
    if m["target"].get("guest_configuration_plan"):
        plan = verify(m["target"]["guest_configuration_plan"])
        if (
            plan["source_capture_id"] != capture["capture_id"]
            or plan["controller_plan_hash"]
            != m["target"]["disk_controller_plan"]["hash"]
        ):
            fail("GUEST_CONFIG_FROZEN_PLAN_CHANGED")
    else:
        inspection = image_inspect(m)
        configs = []
        with Disk(root_path, fmt) as image:
            root, kind = image.mount_root()
            if kind != capture["os"]:
                fail("GUEST_OS_IDENTITY_MISMATCH")
            if kind == "linux":
                os_release = dict(
                    line.split("=", 1)
                    for line in image.read("/etc/os-release").splitlines()
                    if "=" in line
                )
                if (
                    os_release.get("ID", "").strip('"') != capture["os_id"]
                    or os_release.get("VERSION_ID", "").strip('"')
                    != capture["os_version"]
                ):
                    fail("GUEST_OS_IDENTITY_MISMATCH")
                root_uuid = image.call("vfs-uuid", root).lower()
                if root_uuid != capture["root_fs_uuid"].lower():
                    fail("ROOT_IDENTITY_MISMATCH")
                inspection[0]["identity"] = "fs:" + root_uuid
                for file in capture.get("configs", []):
                    p = file["path"]
                    if (
                        not config_path(p, capture["os_id"])
                        or image.read(p) != file["content"].strip()
                    ):
                        fail("SOURCE_CONFIG_CHANGED")
                    configs.append({"path": p, "content": file["content"], **({"active": file["active"]} if "active" in file else {})})
                if not configs:
                    fail("SOURCE_CONFIG_REQUIRED")
        plan = build(m, capture, inspection, configs)
        plan["helper_sha256"] = hashlib.sha256(
            (
                payload
                / ("linux-helper.py" if plan["os"] == "linux" else "windows-helper.ps1")
            ).read_bytes()
        ).hexdigest()
        if plan.get("os_id") == "rocky":
            plan["network_preparer_sha256"] = hashlib.sha256((payload / "prepare-networkmanager.py").read_bytes()).hexdigest()
        plan = verify(seal(plan))
        m["target"]["guest_config_operation_id"] = plan["operation_id"]
        m["target"]["guest_configuration_plan"] = plan
        m.setdefault("runtime", {}).setdefault("guest_configuration", {}).update(
            {
                "status": "PLANNED",
                "plan_hash": plan["hash"],
                "operation_id": plan["operation_id"],
            }
        )
        atomic(path, m)
    if (
        hashlib.sha256(
            (
                payload
                / ("linux-helper.py" if plan["os"] == "linux" else "windows-helper.ps1")
            ).read_bytes()
        ).hexdigest()
        != plan["helper_sha256"]
    ):
        fail("GUEST_HELPER_FROZEN_VERSION_CHANGED")
    if plan.get("network_preparer_sha256") and hashlib.sha256((payload / "prepare-networkmanager.py").read_bytes()).hexdigest() != plan["network_preparer_sha256"]:
        fail("GUEST_NETWORK_HELPER_FROZEN_VERSION_CHANGED")
    base = (
        "/var/lib/ablestack-v2k/guest-config"
        if plan["os"] == "linux"
        else "/ProgramData/ABLECLOUD/V2K/GuestConfig"
    )
    with Disk(root_path, fmt, False) as image:
        image.mount_root()
        if (
            image.exists(base + "/plan.json")
            and json.loads(image.read(base + "/plan.json")) != plan
        ):
            fail("GUEST_CONFIG_PREPARATION_CONFLICT")
        image.write(base + "/plan.json", canonical(plan))
        if plan["os"] == "linux":
            # QGA creates binding files with its own mode; keep the entire exchange private.
            image.call("chmod", "0700", base)
            for file in plan["network"]["files"]:
                backup = base + "/backup/" + Path(file["path"]).name
                original = next(
                    v["content"]
                    for v in capture["configs"]
                    if v["path"] == file["path"]
                )
                current = image.read(file["path"])
                if current not in [original.strip(), file["content"].strip()]:
                    fail("NETWORK_CONFIG_OWNERSHIP_CONFLICT")
                if image.exists(backup) and image.read(backup) != original.strip():
                    fail("NETWORK_BACKUP_OWNERSHIP_CONFLICT")
                if not image.exists(backup):
                    image.write(backup, original)
                image.write(file["path"], file["content"])
            for file in plan["network"].get("generated_files", []):
                if (
                    image.exists(file["path"])
                    and image.read(file["path"]) != file["content"].strip()
                ):
                    fail("NETWORK_CONFIG_OWNERSHIP_CONFLICT")
                image.write(file["path"], file["content"], "0644")
            config = "/etc/cloud/cloud.cfg.d/99-v2k-preserve-network.cfg"
            content = "network: {config: disabled}\n"
            if image.exists(config) and image.read(config) != content.strip():
                fail("NETWORK_CONFIG_OWNERSHIP_CONFLICT")
            image.write(config, content)
            image.upload(str(payload / "linux-helper.py"), base + "/helper.py")
            image.call("chmod", "0700", base + "/helper.py")
            image.upload(str(payload / "prepare-networkmanager.py"), base + "/prepare-networkmanager.py")
            image.call("chmod", "0700", base + "/prepare-networkmanager.py")
            image.upload(
                str(payload / "v2k-guest-config.service"),
                "/etc/systemd/system/v2k-guest-config.service",
            )
            image.call("chmod", "0644", "/etc/systemd/system/v2k-guest-config.service")
            image.upload(str(payload / "v2k-guest-config.timer"), "/etc/systemd/system/v2k-guest-config.timer")
            image.call("chmod", "0644", "/etc/systemd/system/v2k-guest-config.timer")
            image.write(
                "/etc/systemd/system/v2k-guest-config.path",
                (payload / "v2k-guest-config.path")
                .read_text()
                .replace("@OPERATION_ID@", plan["operation_id"]),
                "0644",
            )
            rocky = plan.get("os_id") == "rocky"
            if rocky:
                image.upload(str(payload / "ablestack_v2k_guest_config.cil"), base + "/ablestack_v2k_guest_config.cil")
                existing = capture.get("qga", {})
                if existing.get("installed"):
                    if not existing.get("rpm_verified") or hashlib.sha256(image.read("/etc/sysconfig/qemu-ga").encode()).hexdigest() != existing.get("policy_sha256"):
                        # guestfish read strips the trailing newline: compare exact file checksum.
                        if not existing.get("rpm_verified") or image.call("checksum", "sha256", "/etc/sysconfig/qemu-ga") != existing.get("policy_sha256"):
                            fail("EXISTING_QGA_POLICY_REQUIRES_REVIEW")
                    files=[];asset_info={"existing_vendor_qga":existing}
                else:
                    files, asset_info = rocky_payloads(os.environ.get("V2K_GUEST_CONFIG_ROCKY_ASSETS", "/usr/share/ablestack/v2k/guest-config/rocky97"))
            else:
                files, asset_info = payloads(
                    ubuntu_asset_directory(capture["os_version"]), capture["os_version"]
                )
            if image.exists("/usr/sbin/qemu-ga") or image.exists("/usr/bin/qemu-ga"):
                for cfg in [
                    "/etc/qemu/qemu-ga.conf",
                    "/etc/default/qemu-guest-agent",
                    "/etc/sysconfig/qemu-ga",
                ]:
                    if image.exists(cfg) and (
                        "guest-file-" in image.read(cfg) or "RPC" in image.read(cfg)
                    ):
                        if not (rocky and cfg == "/etc/sysconfig/qemu-ga" and capture.get("qga", {}).get("rpm_verified")):
                            fail("EXISTING_QGA_POLICY_REQUIRES_REVIEW")
                install = False
                if rocky:
                    image.upload(str(payload / "rocky-qga-policy.py"), base + "/rocky-qga-policy.py")
            else:
                install = True
                if rocky:
                    image.upload(
                        str(payload / "rocky-qga-policy.py"),
                        base + "/rocky-qga-policy.py",
                    )
                for f in files:
                    image.upload(str(f), base + "/payload/" + f.name)
            plan_assets = asset_info
        else:
            if image.exists("/Program Files/qemu-ga/qemu-ga.exe") or image.exists(
                "/Program Files (x86)/qemu-ga/qemu-ga.exe"
            ):
                fail("EXISTING_QGA_POLICY_REQUIRES_REVIEW")
            image.upload(
                str(
                    Path(os.environ.get("V2K_GUEST_CONFIG_VIRTIO_ROOT", WINDOWS_ROOT))
                    / "guest-agent/qemu-ga-x86_64.msi"
                ),
                base + "/payload/qemu-ga-x86_64.msi",
            )
            image.upload(str(payload / "windows-helper.ps1"), base + "/helper.ps1")
            image.upload(
                str(payload / "windows-bootstrap.ps1"), base + "/bootstrap.ps1"
            )
            driver_info = None
            if m["source"].get("pc"):
                driver_files, driver_info = windows_driver_payloads()
                for driver in driver_files:
                    image.upload(str(driver), base + "/payload/vioserial/" + driver.name)
            plan_assets = {
                "qga_msi_sha256": hashlib.sha256(
                    (
                        Path(
                            os.environ.get("V2K_GUEST_CONFIG_VIRTIO_ROOT", WINDOWS_ROOT)
                        )
                        / "guest-agent/qemu-ga-x86_64.msi"
                    ).read_bytes()
                ).hexdigest()
            }
            if driver_info:
                plan_assets["serial_driver"] = driver_info
    with Disk(root_path, fmt) as image:
        image.mount_root()
        name = "helper.py" if plan["os"] == "linux" else "helper.ps1"
        if image.call("checksum", "sha256", base + "/" + name) != plan["helper_sha256"]:
            fail("GUEST_HELPER_STAGING_HASH_MISMATCH")
    args = ["virt-customize", "--no-network", "--format", fmt, "-a", root_path]
    if plan["os"] == "linux":
        if install and plan.get("os_id") == "rocky":
            args += [
                "--run-command",
                "rpm -Uvh --replacepkgs /var/lib/ablestack-v2k/guest-config/payload/*.rpm",
                "--run-command",
                "python3 /var/lib/ablestack-v2k/guest-config/rocky-qga-policy.py",
            ]
        elif install:
            # Suppress daemon start in the isolated appliance; enable for the real boot.
            script = 'set -e\np=/usr/sbin/policy-rc.d\nsaved=/var/lib/ablestack-v2k/guest-config/policy-rc.d.saved\nif test -e "$p"; then cp -p "$p" "$saved"; fi\nprintf \'#!/bin/sh\\nexit 101\\n\' > "$p"\nchmod 755 "$p"\nrc=0\ndpkg -i /var/lib/ablestack-v2k/guest-config/payload/*.deb || rc=$?\nif test -e "$saved"; then cp -p "$saved" "$p"; else rm -f "$p"; fi\nexit "$rc"\n'
            args += ["--run-command", script]
        if plan.get("os_id") == "rocky" and not install:
            args += ["--run-command", "rpm -V qemu-guest-agent && python3 /var/lib/ablestack-v2k/guest-config/rocky-qga-policy.py"]
        if plan.get("os_id") == "rocky":
            # Label only owned files. Keep SELinux enforcing and the source fstab/LVM identities.
            args += [
                "--run-command",
                "semodule -i /var/lib/ablestack-v2k/guest-config/ablestack_v2k_guest_config.cil",
                "--run-command",
                "restorecon -RF /var/lib/ablestack-v2k /etc/NetworkManager/system-connections /etc/systemd/network /etc/systemd/system/v2k-guest-config.* /etc/cloud/cloud.cfg.d/99-v2k-preserve-network.cfg",
                "--run-command",
                "systemctl preset qemu-guest-agent.service",
            ]
        else:
            args += ["--run-command", "netplan generate"]
        args += [
            "--run-command",
            "systemctl enable v2k-guest-config.service v2k-guest-config.path v2k-guest-config.timer",
        ]
    else:
        args += ["--firstboot", str(payload / "windows-firstboot.cmd")]
    subprocess.run(
        args,
        check=True,
        timeout=900,
        env={**os.environ, "LIBGUESTFS_BACKEND": "direct"},
    )
    m["target"]["guest_configuration_plan"] = plan
    m.setdefault("runtime", {}).setdefault("guest_configuration", {}).update(
        {
            "status": "STAGED",
            "plan_hash": plan["hash"],
            "operation_id": plan["operation_id"],
            "payload": plan_assets,
        }
    )
    atomic(path, m)
    return plan


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["preflight", "prepare"])
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()
    if args.action == "preflight":
        preflight(json.loads(Path(args.manifest).read_text()))
        print('{"supported":true}')
    else:
        print(canonical(prepare(args.manifest)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(
            (
                "GUEST_CONFIGURATION_PREPARATION: " + str(error)
                if isinstance(error, ValueError)
                else "GUEST_CONFIGURATION_PREPARATION: " + type(error).__name__
            ),
            file=sys.stderr,
        )
        sys.exit(44)
