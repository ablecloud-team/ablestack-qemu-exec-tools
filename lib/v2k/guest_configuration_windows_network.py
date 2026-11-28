#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Windows network intent shared by VMware and Nutanix migration collectors."""
import copy
import ipaddress
import re
import uuid
from pathlib import Path

FEATURE = "windows-network-ipv4-v1"


def vmware_uuid_matches(expected, observed):
    """Windows WMI may render pre-2.6 SMBIOS UUID fields in the other byte order."""
    expected, observed = uuid.UUID(expected), uuid.UUID(observed)
    return observed in (expected, uuid.UUID(bytes_le=expected.bytes))


def error(reason="WINDOWS_NETWORK_UNSUPPORTED"):
    raise ValueError(reason)


def mac(value):
    value = str(value).lower()
    if not re.fullmatch(r"[0-9a-f][02468ace](?::[0-9a-f]{2}){5}", value) or value == "00:00:00:00:00:00":
        error("NIC_MAPPING_AMBIGUOUS")
    return value


def ipv4(value):
    address = ipaddress.IPv4Address(value)
    if address.is_multicast or address.is_unspecified or address.is_loopback or address.is_link_local or int(address) == 0xffffffff:
        error()
    return str(address)


def validate(network):
    """Validate intent, not a live lease; reject unknown fields rather than drop them."""
    if not isinstance(network, dict) or set(network) != {"adapter", "version", "interfaces"} or network.get("adapter") != "windows-nettcpip" or network.get("version") != 1:
        error("SOURCE_CONFIG_REQUIRED")
    nics = network["interfaces"]
    if not isinstance(nics, list) or not 1 <= len(nics) <= 8:
        error("NIC_MAPPING_AMBIGUOUS")
    seen, guids, pnp_ids, addresses = set(), set(), set(), set()
    for nic in nics:
        required = {"source_mac", "source_interface_guid", "source_pnp_id", "admin_enabled", "ipv4", "default_routes", "interface_metric", "dns"}
        optional = {"source_nic_id", "target_mac", "target_network_uuid"}
        if not isinstance(nic, dict) or not required <= set(nic) or set(nic) - required - optional:
            error()
        m = mac(nic["source_mac"])
        guid = str(uuid.UUID(nic["source_interface_guid"]))
        pnp = nic["source_pnp_id"]
        if m in seen or guid in guids or not isinstance(pnp, str) or not re.fullmatch(r"[A-Za-z0-9_&.{}\\#-]{1,256}", pnp) or pnp.lower() in pnp_ids or nic["admin_enabled"] is not True:
            error("NIC_MAPPING_AMBIGUOUS")
        seen.add(m); guids.add(guid); pnp_ids.add(pnp.lower())
        if "target_mac" in nic and mac(nic["target_mac"]) != m:
            error("NIC_MAPPING_AMBIGUOUS")
        if "target_network_uuid" in nic:
            uuid.UUID(nic["target_network_uuid"])
        if "source_nic_id" in nic and (not isinstance(nic["source_nic_id"], str) or not 1 <= len(nic["source_nic_id"]) <= 128):
            error("NIC_MAPPING_AMBIGUOUS")
        intent = nic["ipv4"]
        if set(intent) != {"dhcp", "addresses"} or type(intent["dhcp"]) is not bool or not isinstance(intent["addresses"], list) or len(intent["addresses"]) > 8:
            error()
        if intent["dhcp"] != (len(intent["addresses"]) == 0):
            error()
        subnets = []
        for a in intent["addresses"]:
            if set(a) != {"address", "prefix_length", "skip_as_source"} or type(a["prefix_length"]) is not int or not 1 <= a["prefix_length"] <= 32 or type(a["skip_as_source"]) is not bool:
                error()
            ip = ipv4(a["address"])
            subnet = ipaddress.IPv4Network(f'{ip}/{a["prefix_length"]}', strict=False)
            if ip in addresses or (a["prefix_length"] <= 30 and ipaddress.IPv4Address(ip) in [subnet.network_address, subnet.broadcast_address]):
                error("WINDOWS_NETWORK_CONFLICT")
            addresses.add(ip); subnets.append(subnet)
        if not intent["dhcp"] and all(a["skip_as_source"] for a in intent["addresses"]):
            error()
        metric = nic["interface_metric"]
        if set(metric) != {"automatic", "value"} or type(metric["automatic"]) is not bool or (metric["automatic"] and metric["value"] is not None) or (not metric["automatic"] and (type(metric["value"]) is not int or not 1 <= metric["value"] <= 9999)):
            error()
        routes = nic["default_routes"]
        if not isinstance(routes, list) or len(routes) > 1 or (intent["dhcp"] and routes):
            error()
        for route in routes:
            if set(route) != {"next_hop", "route_metric", "persistent"} or route["persistent"] is not True or type(route["route_metric"]) is not int or not 0 <= route["route_metric"] <= 65535:
                error()
            gateway = ipaddress.IPv4Address(ipv4(route["next_hop"]))
            if not any(gateway in subnet for subnet in subnets) or str(gateway) in addresses:
                error()
        dns = nic["dns"]
        if set(dns) != {"mode", "servers"} or dns["mode"] not in ["static", "dhcp", "none"] or not isinstance(dns["servers"], list) or len(dns["servers"]) > 8:
            error()
        if (dns["mode"] == "static") != bool(dns["servers"]) or (dns["mode"] == "dhcp" and not intent["dhcp"]):
            error()
        if len({ipv4(s) for s in dns["servers"]}) != len(dns["servers"]):
            error()
    if sum(bool(n["default_routes"]) for n in nics) > 1:
        error()  # Multiple default routes need an independently qualified adapter.
    return network


def build(manifest, capture):
    network = copy.deepcopy(validate(capture.get("network")))
    source = manifest["source"]["vm"]["nics"]
    mappings = manifest["target"].get("cloud", {}).get("nic_mappings", [])
    known = {mac(n.get("mac", "")): n for n in source}
    mapped = {mac(n.get("mac", "")): n for n in mappings}
    selected = {n["source_mac"] for n in network["interfaces"]}
    if len(known) != len(source) or len(mapped) != len(mappings) or set(known) != selected or set(mapped) != selected:
        error("NIC_MAPPING_AMBIGUOUS")
    for n in network["interfaces"]:
        m = n["source_mac"]
        n["source_nic_id"] = str(known[m].get("uuid") or known[m].get("device_key") or known[m].get("key") or mapped[m]["source_key"])
        n["target_mac"] = m
        n["target_network_uuid"] = mapped[m]["network_id"]
    return validate(network)


def source_script(directory):
    """Compose only fixed, read-only source code; credentials are never interpolated."""
    directory = Path(directory) / "guest-config"
    script = (directory / "source-windows.ps1").read_text(encoding="utf-8-sig")
    marker = "# @WINDOWS_NETWORK_READ@"
    if script.count(marker) != 1:
        error("SOURCE_GUEST_PROBE_UNQUALIFIED")
    return script.replace(marker, (directory / "windows-network-read.ps1").read_text(encoding="utf-8-sig"))
