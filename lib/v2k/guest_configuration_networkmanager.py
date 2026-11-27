#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Conservative Rocky 9.7 NetworkManager Ethernet keyfile adapter."""
import configparser
import hashlib
import io
import ipaddress
import re
import uuid


def fail(reason):
    raise ValueError(reason)


def supported_linux(capture):
    return (
        capture.get("os_id") == "ubuntu"
        and str(capture.get("os_version", "")).startswith(("22.04", "24.04"))
    ) or (capture.get("os_id") == "rocky" and capture.get("os_version") in ("9.7", "9.9"))


def config_path(path, os_id):
    pattern = (
        r"/etc/NetworkManager/system-connections/[A-Za-z0-9_. -]+\.nmconnection"
        if os_id == "rocky"
        else r"/etc/netplan/[A-Za-z0-9_.-]+\.yaml"
    )
    return bool(re.fullmatch(pattern, path))


def parse_keyfile(text):
    cfg = configparser.ConfigParser(interpolation=None, delimiters=("=",), strict=True)
    cfg.optionxform = str
    try:
        cfg.read_string(text)
    except configparser.Error:
        fail("NETWORK_CONFIG_UNSUPPORTED")
    if cfg.defaults() or set(cfg.sections()) - {
        "connection",
        "ethernet",
        "802-3-ethernet",
        "ipv4",
        "ipv6",
        "proxy",
    }:
        fail("NETWORK_CONFIG_UNSUPPORTED")
    connection = cfg["connection"]
    if connection.get("type") not in ("ethernet", "802-3-ethernet") or connection.get(
        "autoconnect", "true"
    ).lower() not in ("true", "yes", "1"):
        fail("NETWORK_CONFIG_UNSUPPORTED")
    if set(connection) - {
        "id",
        "uuid",
        "type",
        "interface-name",
        "autoconnect",
        "autoconnect-priority",
        "timestamp",
        "zone",
        "metered",
        "permissions",
    } or connection.get("permissions", ""):
        fail("NETWORK_CONFIG_UNSUPPORTED")
    try:
        uuid.UUID(connection["uuid"])
    except (KeyError, ValueError):
        fail("NETWORK_CONFIG_UNSUPPORTED")
    eth = [s for s in ("ethernet", "802-3-ethernet") if cfg.has_section(s)]
    if len(eth) > 1:
        fail("NETWORK_CONFIG_UNSUPPORTED")
    section = eth[0] if eth else "ethernet"
    if not eth:
        cfg.add_section(section)
    if set(cfg[section]) - {"mac-address", "mtu", "auto-negotiate"}:
        fail("NETWORK_CONFIG_UNSUPPORTED")
    if cfg.has_section("proxy") and dict(cfg["proxy"]):
        fail("NETWORK_CONFIG_UNSUPPORTED")
    for family in (4, 6):
        name = "ipv" + str(family)
        if not cfg.has_section(name):
            fail("NETWORK_CONFIG_UNSUPPORTED")
        values = cfg[name]
        if values.get("method") not in ("auto", "manual", "disabled"):
            fail("NETWORK_CONFIG_UNSUPPORTED")
        if values.get("method") == "manual" and not any(
            re.fullmatch(r"address[1-9][0-9]*", k) for k in values
        ):
            fail("NETWORK_CONFIG_UNSUPPORTED")
        allowed = {
            "method",
            "gateway",
            "dns",
            "dns-search",
            "ignore-auto-dns",
            "ignore-auto-routes",
            "never-default",
            "may-fail",
            "route-metric",
            "addr-gen-mode",
        }
        if any(
            k not in allowed and not re.fullmatch(r"(?:address|route)[1-9][0-9]*", k)
            for k in values
        ):
            fail("NETWORK_CONFIG_UNSUPPORTED")
    return cfg, section


def validate_keyfiles(configs, source_nics, observed):
    known = {n["mac"].lower(): n for n in source_nics}
    selected = {}
    files = []
    generated = []
    profile_ids = set()
    active_marked = any("active" in file for file in configs)
    for file in configs:
        if active_marked and file.get("active") is not True:
            continue
        if not config_path(file["path"], "rocky"):
            fail("NETWORK_CONFIG_UNSUPPORTED")
        cfg, eth = parse_keyfile(file["content"])
        conn = cfg["connection"]
        mac = cfg[eth].get("mac-address", "").lower()
        name = conn.get("interface-name", "")
        candidates = [
            n
            for n in observed
            if n["mac"].lower() in known
            and (not name or n["ifname"] == name)
            and (not mac or n["mac"].lower() == mac)
        ]
        if len(candidates) != 1:
            fail("NIC_MAPPING_AMBIGUOUS")
        nic = candidates[0]
        mac = nic["mac"].lower()
        name = nic["ifname"]
        if (
            mac in selected
            or conn["uuid"] in profile_ids
            or not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", name)
            or name == "lo"
        ):
            fail("NIC_MAPPING_AMBIGUOUS")
        profile_ids.add(conn["uuid"])
        conn["interface-name"] = name
        cfg[eth]["mac-address"] = mac
        intent = {
            "dhcp4": cfg["ipv4"]["method"] == "auto",
            "dhcp6": False,
            "accept-ra": cfg["ipv6"]["method"] == "auto",
            "addresses": [],
            "routes": [],
        }
        if cfg[eth].get("mtu"):
            mtu = int(cfg[eth]["mtu"])
            if not 68 <= mtu <= 65535:
                fail("NETWORK_CONFIG_UNSUPPORTED")
            intent["mtu"] = mtu
        dns = []
        search = []
        for family in (4, 6):
            values = cfg["ipv" + str(family)]
            for key, value in values.items():
                if re.fullmatch(r"address[1-9][0-9]*", key):
                    parts = value.split(",")
                    address = ipaddress.ip_interface(parts[0])
                    if address.version != family:
                        fail("NETWORK_CONFIG_UNSUPPORTED")
                    intent["addresses"].append(str(address))
                    if len(parts) > 1 and parts[1]:
                        intent["routes"].append(
                            {
                                "to": "default",
                                "via": str(ipaddress.ip_address(parts[1])),
                            }
                        )
                    if len(parts) > 2:
                        fail("NETWORK_CONFIG_UNSUPPORTED")
                if re.fullmatch(r"route[1-9][0-9]*", key):
                    parts = value.split(",")
                    dst = ipaddress.ip_network(parts[0], strict=False)
                    if dst.version != family or len(parts) > 3:
                        fail("NETWORK_CONFIG_UNSUPPORTED")
                    route = {"to": "default" if dst.prefixlen == 0 else str(dst)}
                    if len(parts) > 1 and parts[1]:
                        route["via"] = str(ipaddress.ip_address(parts[1]))
                    if len(parts) > 2 and parts[2]:
                        route["metric"] = int(parts[2])
                    intent["routes"].append(route)
            if values.get("gateway") and values.get(
                "never-default", "false"
            ).lower() not in ("true", "yes", "1"):
                intent["routes"].append(
                    {
                        "to": "default",
                        "via": str(ipaddress.ip_address(values["gateway"])),
                    }
                )
            dns.extend(
                str(ipaddress.ip_address(v))
                for v in values.get("dns", "").split(";")
                if v
            )
            search.extend(v for v in values.get("dns-search", "").split(";") if v)
        if dns or search:
            intent["nameservers"] = {"addresses": dns, "search": search}
        selected[mac] = {
            "mac": mac,
            "ifname": name,
            "source_device_key": str(
                known[mac].get("device_key", known[mac].get("key", ""))
            ),
            "renderer": "NetworkManager",
            "profile_uuid": conn["uuid"],
            "config": intent,
        }
        out = io.StringIO()
        cfg.write(out, space_around_delimiters=False)
        files.append(
            {
                "path": file["path"],
                "before_hash": hashlib.sha256(file["content"].encode()).hexdigest(),
                "content": out.getvalue(),
            }
        )
        generated.append(
            {
                "path": "/etc/systemd/network/10-v2k-" + mac.replace(":", "") + ".link",
                "content": "[Match]\nMACAddress="
                + mac
                + "\n\n[Link]\nNamePolicy=\nName="
                + name
                + "\nMACAddressPolicy=none\n",
            }
        )
    if set(selected) != set(known) or not known:
        fail("NIC_MAPPING_AMBIGUOUS")
    return {
        "adapter": "networkmanager-keyfile",
        "interfaces": list(selected.values()),
        "files": files,
        "generated_files": generated,
        "cloud_init_network_only_disabled": True,
    }
