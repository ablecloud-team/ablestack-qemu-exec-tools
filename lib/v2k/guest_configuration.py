#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Versioned guest intent. No passwords, remote commands or disk-number identity."""
import argparse
import copy
import difflib
import hashlib
import json
import os
import sys
from pathlib import Path
import re
import uuid

VERSION = 1
MAX_BYTES = 65536
ROOTS = {
    "linux": "/var/lib/ablestack-v2k/guest-config",
    "windows": r"C:\ProgramData\ABLECLOUD\V2K\GuestConfig",
}


def fail(reason):
    raise ValueError(reason)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def seal(value):
    result = copy.deepcopy(value)
    result.pop("hash", None)
    result["hash"] = digest(result)
    if len(canonical(result).encode()) > MAX_BYTES:
        fail("GUEST_CONFIG_PLAN_TOO_LARGE")
    return result


def verify(plan):
    if (
        not isinstance(plan, dict)
        or plan.get("version") != VERSION
        or plan.get("policy") != "preserve"
        or plan.get("os") not in ROOTS
    ):
        fail("GUEST_CONFIG_PLAN_INVALID")
    uuid.UUID(plan["operation_id"])
    uuid.UUID(plan["source_vm_uuid"])
    if plan != seal(plan) or not re.fullmatch(
        "[a-f0-9]{64}", plan.get("controller_plan_hash", "")
    ):
        fail("GUEST_CONFIG_PLAN_HASH_MISMATCH")
    if not plan.get("root_identity") or not plan.get("source_capture_id"):
        fail("SOURCE_CONFIG_REQUIRED")
    if plan["os"] == "linux":
        seen = set()
        names = set()
        for nic in plan["network"]["interfaces"]:
            mac = nic["mac"].lower()
            name = nic["ifname"]
            if (
                not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac)
                or mac in seen
                or name in names
                or not re.fullmatch("[a-zA-Z0-9_.-]{1,15}", name)
                or name == "lo"
            ):
                fail("NIC_MAPPING_AMBIGUOUS")
            seen.add(mac)
            names.add(name)
        if not seen:
            fail("NIC_MAPPING_AMBIGUOUS")
    else:
        ids = set()
        guids = set()
        letters = set()
        for disk in plan["windows"]["disks"]:
            if (
                disk["source_disk_id"] in ids
                or not isinstance(disk["online"], bool)
                or not isinstance(disk["read_only"], bool)
            ):
                fail("DATA_IDENTITY_MISMATCH")
            ids.add(disk["source_disk_id"])
            for part in disk["partitions"]:
                key = part.get("guid") or str(part.get("offset"))
                if key in guids:
                    fail("DATA_IDENTITY_MISMATCH")
                guids.add(key)
                for access in part.get("access_paths", []):
                    if not re.fullmatch(r"[D-Z]:\\", access) or access in letters:
                        fail("ACCESS_PATH_CONFLICT")
                    letters.add(access)
    return plan


def validate_network(configs, source_nics, observed):
    import yaml

    allowed = {"version", "renderer", "ethernets"}
    known = {n["mac"].lower(): n for n in source_nics}
    selected = {}
    out = []
    for file in configs:
        document = yaml.safe_load(file["content"])
        network = document.get("network", {})
        if set(network) - allowed or network.get("version") != 2:
            fail("NETWORK_CONFIG_UNSUPPORTED")
        renderer = network.get("renderer", "networkd")
        if renderer not in ["networkd", "NetworkManager"]:
            fail("NETWORK_CONFIG_UNSUPPORTED")
        for name, value in network.get("ethernets", {}).items():
            if not isinstance(value, dict) or set(value) & {
                "access-points",
                "auth",
                "password",
                "macaddress",
                "openvswitch",
                "networkmanager",
                "activation-mode",
            }:
                fail("NETWORK_CONFIG_UNSUPPORTED")
            match = value.get("match", {})
            mac = str(match.get("macaddress", "")).lower()
            candidates = [
                n
                for n in observed
                if n["mac"].lower() in known
                and (n["ifname"] == name or (mac and n["mac"].lower() == mac))
            ]
            if not candidates and mac in known:
                candidates = [{"mac": mac, "ifname": value.get("set-name", name)}]
            if (
                not candidates
                and len(known) == 1
                and sum(
                    len(
                        yaml.safe_load(c["content"])
                        .get("network", {})
                        .get("ethernets", {})
                    )
                    for c in configs
                )
                == 1
            ):
                candidates = [
                    {"mac": next(iter(known)), "ifname": value.get("set-name", name)}
                ]
            if len(candidates) != 1:
                fail("NIC_MAPPING_AMBIGUOUS")
            mac = candidates[0]["mac"].lower()
            ifname = candidates[0]["ifname"]
            if mac in selected:
                fail("NIC_MAPPING_AMBIGUOUS")
            if value.get("set-name") and value["set-name"] != ifname:
                fail("NIC_MAPPING_AMBIGUOUS")
            value["match"] = {"macaddress": mac}
            value["set-name"] = ifname
            selected[mac] = {
                "mac": mac,
                "ifname": ifname,
                "source_device_key": str(
                    known[mac].get("device_key", known[mac].get("key", ""))
                ),
                "renderer": value.get("renderer", renderer),
                "config": copy.deepcopy(value),
            }
        out.append(
            {
                "path": file["path"],
                "before_hash": hashlib.sha256(file["content"].encode()).hexdigest(),
                "content": yaml.safe_dump(document, sort_keys=False),
            }
        )
    if set(selected) != set(known):
        fail("NIC_MAPPING_AMBIGUOUS")
    return {
        "interfaces": list(selected.values()),
        "files": out,
        "cloud_init_network_only_disabled": True,
    }


def build(manifest, capture, inspected, configs=()):
    ctl = manifest["target"]["disk_controller_plan"]
    os_kind = capture["os"]
    if capture.get("source_vm_uuid") != manifest["source"]["vm"][
        "uuid"
    ] or not capture.get("capture_id"):
        fail("SOURCE_CONFIG_REQUIRED")
    plan = {
        "version": 1,
        "policy": "preserve",
        "operation_id": manifest["target"].get("guest_config_operation_id")
        or str(uuid.uuid4()),
        "source_vm_uuid": capture["source_vm_uuid"],
        "source_capture_id": capture["capture_id"],
        "controller_plan_hash": ctl["hash"],
        "os": os_kind,
        "root_identity": inspected[0]["identity"],
        "root_source_disk_id": manifest["disks"][0]["disk_id"],
        "helper_version": 1,
    }
    plan.update(
        {
            "source_boot_id": capture.get("boot_id"),
            "source_collected_at": capture.get("collected_at"),
            "os_version": (
                capture.get("os_version")
                if os_kind == "linux"
                else capture.get("build")
            ),
        }
    )
    if os_kind == "linux":
        if capture.get("os_id") != "ubuntu" or not capture.get(
            "os_version", ""
        ).startswith("22.04"):
            fail("GUEST_OS_UNSUPPORTED")
        plan["network"] = validate_network(
            configs, manifest["source"]["vm"]["nics"], capture.get("interfaces", [])
        )
    else:
        if capture.get("build") != "20348":
            fail("GUEST_OS_UNSUPPORTED")
        root = [d for d in capture["disks"] if d["is_boot"]]
        if (
            len(root) != 1
            or root[0]["identity"].lower() != inspected[0]["identity"].lower()
        ):
            fail("DATA_IDENTITY_MISMATCH")
        data = []
        for source, local in zip(manifest["disks"][1:], inspected[1:]):
            matches = [
                d
                for d in capture["disks"]
                if d["identity"].lower() == local["identity"].lower()
                and d["size_bytes"] == source["size_bytes"]
            ]
            if (
                len(matches) != 1
                or matches[0].get("is_boot")
                or matches[0].get("is_clustered")
                or matches[0].get("partition_style") not in ["GPT", "MBR"]
            ):
                fail("DATA_IDENTITY_MISMATCH")
            disk = copy.deepcopy(matches[0])
            disk["source_disk_id"] = source["disk_id"]
            disk.pop("number", None)
            if {p.get("guid") or str(p.get("offset")) for p in disk["partitions"]} != {
                p.get("guid") or str(p.get("offset")) for p in local["partitions"]
            }:
                fail("DATA_IDENTITY_MISMATCH")
            data.append(disk)
        plan["windows"] = {
            "san_policy": capture["san_policy"],
            "disks": data,
            "source_cdrom_letters": capture.get("cdrom_letters", []),
            "reserved_letters": capture.get("reserved_letters", []),
        }
    return verify(seal(plan))


def validate_capture(capture, source_uuid):
    if capture.get("source_vm_uuid") != source_uuid or not capture.get("capture_id"):
        fail("SOURCE_CONFIG_REQUIRED")

    def check(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if re.search(
                    r"(?i)password|passwd|secret|credential|token|api[_-]?key|private[_-]?key|^auth$",
                    key,
                ):
                    fail("SOURCE_CONFIG_CONTAINS_CREDENTIALS")
                check(item)
        elif isinstance(value, list):
            for item in value:
                check(item)

    check(capture)
    if capture.get("os") == "linux":
        if capture.get("os_id") != "ubuntu" or not str(
            capture.get("os_version", "")
        ).startswith("22.04"):
            fail("GUEST_OS_UNSUPPORTED")
        import yaml

        for file in capture.get("configs", []):
            text = file.get("content", "")
            if re.search(
                r"(?i)\b(password|passwd|secret|credential|token|api[_-]?key|private[_ -]?key|auth)\b",
                text,
            ):
                fail("SOURCE_CONFIG_CONTAINS_CREDENTIALS")
            try:
                check(yaml.safe_load(text))
            except yaml.YAMLError:
                fail("SOURCE_CONFIG_INVALID")
    elif capture.get("os") != "windows" or str(capture.get("build")) != "20348":
        fail("GUEST_OS_UNSUPPORTED")
    return capture


def preview_capture(manifest):
    capture = validate_capture(
        manifest["source"]["guest_configuration"], manifest["source"]["vm"]["uuid"]
    )
    print(
        "Guest configuration candidate (final clone identities are checked before import):"
    )
    if capture["os"] == "linux":
        result = validate_network(
            capture["configs"], manifest["source"]["vm"]["nics"], capture["interfaces"]
        )
        for nic in result["interfaces"]:
            print("  NIC " + nic["mac"] + " -> " + nic["ifname"])
        originals = {f["path"]: f["content"] for f in capture["configs"]}
        for file in result["files"]:
            before = originals[file["path"]].splitlines(keepends=True)
            after = file["content"].splitlines(keepends=True)
            print(
                "".join(
                    difflib.unified_diff(
                        before,
                        after,
                        fromfile=json.dumps(file["path"]),
                        tofile="prepared clone",
                    )
                ),
                end="",
            )
    else:
        print("  Global SAN policy remains " + capture["san_policy"])
        for disk in capture["disks"]:
            if disk["is_boot"]:
                continue
            print(
                "  DATA "
                + json.dumps(
                    {
                        "identity": disk["identity"],
                        "online": disk["online"],
                        "read_only": disk["read_only"],
                        "access_paths": [
                            p
                            for part in disk["partitions"]
                            for p in part["access_paths"]
                        ],
                    }
                )
            )


def atomic(path, value):
    temp = path.with_name(path.name + ".guest-config.tmp")
    temp.write_text(json.dumps(value, ensure_ascii=True))
    temp.chmod(0o600)
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action", choices=["validate", "params", "validate-capture", "preview"]
    )
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()
    m = json.loads(Path(args.manifest).read_text())
    if args.action == "validate-capture":
        validate_capture(json.load(sys.stdin), m["source"]["vm"]["uuid"])
        return
    if args.action == "preview":
        preview_capture(m)
        return
    plan = m["target"]["guest_configuration_plan"]
    verify(plan)
    if args.action == "params":
        print(
            json.dumps(
                {"details[0].migration.guest.config.plan": canonical(plan)},
                separators=(",", ":"),
            )
        )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError) as error:
        raise SystemExit("GUEST_CONFIGURATION: " + str(error))
