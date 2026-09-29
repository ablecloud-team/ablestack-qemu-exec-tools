"""Approved guest adapter hashes, retained across independent host upgrades."""
# Copyright 2026 ABLECLOUD. Apache-2.0.
import json
import os
from pathlib import Path
import re
import stat


CATALOG = Path(__file__).parent / "process" / "guest_adapter_compat.json"
FILES = {
    "windows-read": ("ProcessList.ps1", "AbleProcessIdentity.dll"),
    "windows-action": ("ProcessAction.ps1", "AbleProcessAction.dll", "AbleProcessIdentity.dll"),
    "rocky-read": ("process_list_linux.py", "process-read-launcher"),
    "ubuntu-read": ("process_list_linux.py",),
    "linux-action": ("process_action_linux.py", "process-action-launcher"),
}
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
IDENTIFIER = re.compile(r"[a-z0-9][a-z0-9._-]{0,79}\Z")


def supported_windows(osinfo):
    """Accept the Windows releases carried by the multi-OS guest ISO."""
    if osinfo.get("id") not in ("mswindows", "windows"):
        return False
    version = osinfo.get("version-id")
    variant = osinfo.get("variant-id")
    pretty = osinfo.get("pretty-name", "")
    if variant == "server" or "Windows Server" in pretty:
        return version in ("2019", "2022", "2025") or (
            version in (None, "10.0") and any(
                "Windows Server " + release in pretty for release in ("2019", "2022", "2025")
            )
        )
    if variant in ("client", "desktop", "workstation") or "Windows 11" in pretty:
        return version == "11" or (version in (None, "10.0") and "Windows 11" in pretty)
    return False


def _unique_pairs(pairs):
    result = []
    for pair in pairs:
        if pair not in result:
            result.append(pair)
    return tuple(result)


def _object_without_duplicates(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("Duplicate guest adapter catalog key")
        value[key] = item
    return value


def approved(profile, path=CATALOG):
    """Return complete hash tuples, never independent per-file allowlists."""
    if profile not in FILES:
        raise ValueError("Unknown guest adapter profile")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        code_owner = Path(__file__).stat().st_uid
        if not stat.S_ISREG(info.st_mode) or info.st_uid != code_owner or info.st_mode & 0o022 or info.st_nlink != 1:
            raise ValueError("Unsafe guest adapter catalog")
        with os.fdopen(fd, "rb", closefd=False) as handle:
            raw = handle.read(65537)
        if len(raw) > 65536:
            raise ValueError("Guest adapter catalog too large")
    finally:
        os.close(fd)
    value = json.loads(raw, object_pairs_hook=_object_without_duplicates)
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "protocolVersion", "bundles"}:
        raise ValueError("Invalid guest adapter catalog")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1 or value["protocolVersion"] != "1.0":
        raise ValueError("Unsupported guest adapter catalog")
    bundles = value["bundles"]
    if not isinstance(bundles, list) or not 1 <= len(bundles) <= 128:
        raise ValueError("Invalid guest adapter bundles")
    identifiers = set()
    selected = []
    for entry in bundles:
        if not isinstance(entry, dict) or set(entry) != {"id", "profile", "sha256"}:
            raise ValueError("Invalid guest adapter bundle")
        identifier = entry["id"]
        kind = entry["profile"]
        hashes = entry["sha256"]
        if not isinstance(identifier, str) or not IDENTIFIER.fullmatch(identifier) or identifier in identifiers:
            raise ValueError("Invalid guest adapter bundle ID")
        identifiers.add(identifier)
        if kind not in FILES or not isinstance(hashes, dict) or set(hashes) != set(FILES[kind]):
            raise ValueError("Invalid guest adapter file set")
        pair = tuple(hashes[name] for name in FILES[kind])
        if not all(isinstance(digest, str) and SHA256.fullmatch(digest) for digest in pair):
            raise ValueError("Invalid guest adapter digest")
        if kind == profile:
            selected.append(pair)
    result = _unique_pairs(selected)
    if not result:
        raise ValueError("No approved guest adapter for " + profile)
    return result
