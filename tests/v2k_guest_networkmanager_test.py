#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib/v2k"))
from guest_configuration_networkmanager import validate_keyfiles, supported_linux
import guest_configuration as policy


class NetworkManager(unittest.TestCase):
    def fixture(self):
        text = "[connection]\nid=ens192\nuuid=317aedaa-ddfd-353e-855a-54729459b53a\ntype=ethernet\ninterface-name=ens192\n[ethernet]\n[ipv4]\nmethod=auto\n[ipv6]\nmethod=auto\naddr-gen-mode=eui64\n[proxy]\n"
        return (
            [
                {
                    "path": "/etc/NetworkManager/system-connections/ens192.nmconnection",
                    "content": text,
                }
            ],
            [{"mac": "00:50:56:39:91:01", "key": 4000}],
            [{"mac": "00:50:56:39:91:01", "ifname": "ens192"}],
        )

    def test_mac_binding_and_udev_name_keep_original_identity(self):
        files, nics, observed = self.fixture()
        result = validate_keyfiles(files, nics, observed)
        self.assertIn("mac-address=" + nics[0]["mac"], result["files"][0]["content"])
        self.assertIn("Name=ens192", result["generated_files"][0]["content"])
        self.assertEqual(
            result["interfaces"][0]["profile_uuid"],
            "317aedaa-ddfd-353e-855a-54729459b53a",
        )
        self.assertTrue(result["interfaces"][0]["config"]["dhcp4"])
        self.assertTrue(result["interfaces"][0]["config"]["accept-ra"])

    def test_static_dual_stack_routes_dns_mtu_are_retained(self):
        files, nics, observed = self.fixture()
        files[0]["content"] = (
            files[0]["content"]
            .replace("[ethernet]", "[ethernet]\nmtu=1450")
            .replace("method=auto", "method=manual", 1)
            .replace(
                "[ipv6]",
                "address1=192.0.2.10/24\ngateway=192.0.2.1\ndns=192.0.2.53;\ndns-search=example.test;\nroute1=198.51.100.0/24,192.0.2.2,42\n[ipv6]",
            )
            .replace("addr-gen-mode=eui64", "address1=2001:db8::10/64")
        )
        result = validate_keyfiles(files, nics, observed)
        cfg = result["interfaces"][0]["config"]
        self.assertEqual(cfg["addresses"], ["192.0.2.10/24", "2001:db8::10/64"])
        self.assertEqual(
            next(r for r in cfg["routes"] if r["to"] == "198.51.100.0/24")["metric"], 42
        )
        self.assertEqual(cfg["nameservers"]["search"], ["example.test"])
        self.assertEqual(cfg["mtu"], 1450)

    def test_duplicate_profile_for_nic_is_not_guessed(self):
        files, nics, observed = self.fixture()
        with self.assertRaisesRegex(ValueError, "AMBIGUOUS"):
            validate_keyfiles(files * 2, nics, observed)

    def test_missing_nic_is_not_guessed(self):
        files, nics, observed = self.fixture()
        nics.append({"mac": "00:50:56:39:91:02"})
        with self.assertRaisesRegex(ValueError, "AMBIGUOUS"):
            validate_keyfiles(files, nics, observed)

    def test_explicit_incompatible_mac_is_rejected(self):
        files, nics, observed = self.fixture()
        files[0]["content"] = files[0]["content"].replace(
            "[ethernet]", "[ethernet]\nmac-address=00:50:56:39:91:ff"
        )
        with self.assertRaisesRegex(ValueError, "AMBIGUOUS"):
            validate_keyfiles(files, nics, observed)

    def test_topology_auth_or_unobserved_policy_is_rejected(self):
        files, nics, observed = self.fixture()
        for extra in [
            "[802-1x]\npassword=example",
            "[bridge]\n",
            "[ipv4]\nmethod=shared",
            "[match]\ndriver=vmxnet3",
            "[ethernet]\ncloned-mac-address=random",
        ]:
            with self.subTest(extra=extra), self.assertRaises((ValueError, KeyError)):
                validate_keyfiles(
                    [dict(files[0], content=files[0]["content"] + extra)],
                    nics,
                    observed,
                )

    def test_source_capture_rejects_credentials(self):
        files, nics, observed = self.fixture()
        files[0]["content"] += "# password=fixture\n"
        capture = {
            "source_vm_uuid": "source",
            "capture_id": "capture",
            "os": "linux",
            "os_id": "rocky",
            "os_version": "9.7",
            "configs": files,
            "interfaces": observed,
        }
        with self.assertRaisesRegex(ValueError, "CONTAINS_CREDENTIALS"):
            policy.validate_capture(capture, "source")

    def test_path_traversal_is_rejected(self):
        files, nics, observed = self.fixture()
        files[0]["path"] = "/etc/NetworkManager/system-connections/../bad.nmconnection"
        with self.assertRaisesRegex(ValueError, "UNSUPPORTED"):
            validate_keyfiles(files, nics, observed)

    def test_multiple_nics_use_mac_not_list_order(self):
        files, nics, observed = self.fixture()
        files.append(
            {
                "path": "/etc/NetworkManager/system-connections/ens224.nmconnection",
                "content": files[0]["content"]
                .replace("ens192", "ens224")
                .replace("317aedaa", "417aedaa"),
            }
        )
        nics.append({"mac": "00:50:56:39:91:02"})
        observed.insert(0, {"mac": nics[1]["mac"], "ifname": "ens224"})
        result = validate_keyfiles(files, nics, observed)
        self.assertEqual(
            [n["ifname"] for n in result["interfaces"]], ["ens192", "ens224"]
        )
        self.assertEqual(result["interfaces"][1]["mac"], nics[1]["mac"])

    def test_only_qualified_os_versions_are_enabled(self):
        for os_id, version, expected in [
            ("rocky", "9.7", True),
            ("rocky", "9.8", False),
            ("rhel", "9.7", False),
            ("ubuntu", "22.04", True),
        ]:
            self.assertEqual(
                supported_linux({"os_id": os_id, "os_version": version}), expected
            )

    def test_fresh_qga_only_adds_required_file_methods(self):
        import runpy

        module = runpy.run_path(
            str(
                Path(__file__).resolve().parents[1]
                / "lib/v2k/guest-config/rocky-qga-policy.py"
            )
        )
        text = 'FILTER_RPC_ARGS="--allow-rpcs=guest-ping,guest-info"\n'
        result = module["configure"](text)
        for method in module["FILES"]:
            self.assertIn(method, result)
        self.assertNotIn("guest-exec", result)
        with self.assertRaises(ValueError):
            module["configure"]('FILTER_RPC_ARGS="--block-rpcs=guest-exec"\n')


if __name__ == "__main__":
    unittest.main()
