#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib/v2k"))
import guest_configuration_windows_network as policy


def fixture():
    return json.loads((ROOT / "tests/fixtures/v2k/windows-network.json").read_text())


class WindowsNetworkPolicy(unittest.TestCase):
    def test_vmware_windows_smbios_byte_order_is_bounded(self):
        self.assertTrue(policy.vmware_uuid_matches("4235bf7b-5025-766d-7b3a-a3e8022af333", "7bbf3542-2550-6d76-7b3a-a3e8022af333"))
        self.assertTrue(policy.vmware_uuid_matches("4235bf7b-5025-766d-7b3a-a3e8022af333", "4235bf7b-5025-766d-7b3a-a3e8022af333"))
        self.assertFalse(policy.vmware_uuid_matches("4235bf7b-5025-766d-7b3a-a3e8022af333", "4235bf7b-5025-766d-7b3a-a3e8022af334"))

    def test_static_intent_is_not_a_dhcp_lease(self):
        value = fixture()
        self.assertEqual(policy.validate(value), value)
        nic = value["interfaces"][0]
        nic["ipv4"] = {"dhcp": True, "addresses": []}
        nic["default_routes"] = []
        self.assertEqual(policy.validate(value)["interfaces"][0]["dns"]["mode"], "static")
        nic["dns"] = {"mode": "dhcp", "servers": []}
        policy.validate(value)
        nic["dns"]["servers"] = ["192.0.2.53"]
        with self.assertRaises(ValueError): policy.validate(value)

    def test_unsupported_or_malformed_configuration_is_rejected(self):
        changes = [
            lambda n: n["ipv4"]["addresses"][0].update(prefix_length=33),
            lambda n: n["ipv4"]["addresses"][0].update(address="169.254.1.2"),
            lambda n: n["ipv4"]["addresses"][0].update(address="192.0.2.0"),
            lambda n: n["default_routes"][0].update(next_hop="198.51.100.1"),
            lambda n: n["default_routes"][0].update(persistent=False),
            lambda n: n["dns"].update(servers=["2001:db8::1"]),
            lambda n: n["dns"].update(servers=["192.0.2.53", "192.0.2.53"]),
            lambda n: n.update(source_pnp_id="PCI\\VEN_X*"),
            lambda n: n.update(admin_enabled=False),
            lambda n: n.update(ipv6={}),
        ]
        for change in changes:
            with self.subTest(change=change):
                value=fixture();change(value["interfaces"][0])
                with self.assertRaises((ValueError, TypeError)):policy.validate(value)

    def test_nic_mapping_uses_mac_and_explicit_network(self):
        network = fixture();m=network["interfaces"][0]["source_mac"]
        manifest={"source":{"vm":{"nics":[{"mac":m,"key":"4000"}]}},"target":{"cloud":{"nic_mappings":[{"mac":m,"source_key":"4000","network_id":"22222222-2222-4222-8222-222222222222"}]}}}
        before=copy.deepcopy(network)
        result=policy.build(manifest,{"network":network})
        self.assertEqual(result["interfaces"][0]["source_nic_id"],"4000")
        self.assertEqual(network,before)
        manifest["target"]["cloud"]["nic_mappings"][0]["mac"]="00:50:56:39:90:02"
        with self.assertRaisesRegex(ValueError,"NIC_MAPPING_AMBIGUOUS"):policy.build(manifest,{"network":network})

    def test_fixed_probe_has_explicit_output_mode_and_no_marker(self):
        text=policy.source_script(ROOT/"lib/v2k")
        self.assertNotIn("# @WINDOWS_NETWORK_READ@",text)
        self.assertIn("function Get-V2KWindowsNetwork",text)
        self.assertIn("$OutputMode",text)


if __name__ == "__main__":unittest.main()
