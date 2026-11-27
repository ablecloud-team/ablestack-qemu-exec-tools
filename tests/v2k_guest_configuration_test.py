#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
import copy, importlib.util, json, os, subprocess, sys, tempfile, unittest, uuid
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib/v2k"))
import guest_configuration as policy
from guest_configuration_prepare import require_unsealed, normalize_capture


class GuestConfiguration(unittest.TestCase):
    def network(self):
        files = [
            {
                "path": "/etc/netplan/50-cloud-init.yaml",
                "content": "network:\n  version: 2\n  ethernets:\n    ens192:\n      dhcp4: true\n      mtu: 1450\n",
            }
        ]
        nics = [{"mac": "00:50:56:39:90:01", "device_key": "4000"}]
        observed = [{"ifname": "ens192", "mac": nics[0]["mac"]}]
        return files, nics, observed

    def test_netplan_preserves_semantics_and_uses_stable_mac(self):
        files, nics, observed = self.network()
        result = policy.validate_network(files, nics, observed)
        config = result["interfaces"][0]["config"]
        self.assertEqual(config["match"], {"macaddress": nics[0]["mac"]})
        self.assertEqual(config["set-name"], "ens192")
        self.assertTrue(config["dhcp4"])
        self.assertEqual(config["mtu"], 1450)

    def test_vmware_driver_match_is_replaced(self):
        files, nics, observed = self.network()
        files[0]["content"] += "      match:\n        driver: vmxnet3\n"
        self.assertEqual(
            policy.validate_network(files, nics, observed)["interfaces"][0]["config"][
                "match"
            ],
            {"macaddress": nics[0]["mac"]},
        )

    def test_ambiguous_network_cannot_be_guessed_by_order(self):
        files, nics, observed = self.network()
        nics.append({"mac": "00:50:56:39:90:02", "device_key": "4001"})
        with self.assertRaises(ValueError):
            policy.validate_network(files, nics, [])

    def test_auth_and_unsupported_topology_are_rejected(self):
        files, nics, observed = self.network()
        for tail in ["  bridges: {}\n", "  wifis: {}\n"]:
            with self.assertRaises(ValueError):
                policy.validate_network(
                    [dict(files[0], content=files[0]["content"] + tail)], nics, observed
                )

    def windows(self):
        source = str(uuid.uuid4())
        root = "gpt:" + str(uuid.uuid4())
        data = "gpt:" + str(uuid.uuid4())
        part = str(uuid.uuid4())
        m = {
            "source": {"vm": {"uuid": source}},
            "target": {"disk_controller_plan": {"hash": "a" * 64}},
            "disks": [
                {"disk_id": "scsi0:0", "size_bytes": 100},
                {"disk_id": "scsi0:1", "size_bytes": 200},
            ],
        }
        cap = {
            "os": "windows",
            "build": "20348",
            "source_vm_uuid": source,
            "capture_id": str(uuid.uuid4()),
            "san_policy": "OfflineShared",
            "disks": [
                {
                    "is_boot": False,
                    "identity": data,
                    "size_bytes": 200,
                    "partition_style": "GPT",
                    "online": True,
                    "read_only": False,
                    "partitions": [
                        {
                            "guid": part,
                            "offset": 1048576,
                            "size_bytes": 199,
                            "access_paths": ["E:" + chr(92)],
                        }
                    ],
                },
                {
                    "is_boot": True,
                    "identity": root,
                    "size_bytes": 100,
                    "partition_style": "GPT",
                    "online": True,
                    "read_only": False,
                    "partitions": [],
                },
            ],
        }
        inspected = [
            {"identity": root, "partitions": []},
            {
                "identity": data,
                "partitions": [{"guid": part, "offset": 1048576, "size_bytes": 199}],
            },
        ]
        cap["network"] = json.loads((ROOT / "tests/fixtures/v2k/windows-network.json").read_text())
        mac = cap["network"]["interfaces"][0]["source_mac"]
        m["source"]["vm"]["nics"] = [{"mac": mac, "key": "4000"}]
        m["target"]["cloud"] = {"nic_mappings": [{"mac": mac, "source_key": "4000", "network_id": "22222222-2222-4222-8222-222222222222"}]}
        return m, cap, inspected

    def test_windows_identity_does_not_depend_on_number_or_old_serial(self):
        m, cap, inspected = self.windows()
        cap["disks"][0].update(number=97, source_serial="vmware-serial")
        p = policy.build(m, cap, inspected)
        self.assertEqual(p["windows"]["disks"][0]["source_disk_id"], "scsi0:1")
        self.assertNotIn("number", p["windows"]["disks"][0])
        self.assertEqual(p["windows"]["san_policy"], "OfflineShared")

    def test_intentionally_offline_readonly_is_preserved(self):
        m, cap, inspected = self.windows()
        cap["disks"][0].update(online=False, read_only=True)
        p = policy.build(m, cap, inspected)
        self.assertFalse(p["windows"]["disks"][0]["online"])
        self.assertTrue(p["windows"]["disks"][0]["read_only"])

    def test_changed_source_identity_and_plan_are_rejected(self):
        m, cap, inspected = self.windows()
        p = policy.build(m, cap, inspected)
        p["windows"]["disks"][0]["online"] = False
        with self.assertRaises(ValueError):
            policy.verify(p)
        inspected[1]["identity"] = "gpt:" + str(uuid.uuid4())
        with self.assertRaises(ValueError):
            policy.build(m, cap, inspected)

    def test_import_attempt_blocks_offline_preparation(self):
        m, cap, inspection = self.windows()
        m["disks"][0]["transfer"] = {"cloud_allocation": {"request_id": "owned"}}
        with self.assertRaisesRegex(ValueError, "CLOUD_TARGET_SEALED"):
            require_unsealed(m)

    def test_windows_drive_paths_are_normalized_without_fixed_letter(self):
        value = {
            "os": "windows",
            "disks": [{"partitions": [{"access_paths": ["F:" + chr(92) * 2]}]}],
        }
        self.assertEqual(
            normalize_capture(value)["disks"][0]["partitions"][0]["access_paths"],
            ["F:" + chr(92)],
        )

    def test_static_ipv4_ipv6_dns_routes_and_mtu_are_preserved(self):
        files, nics, observed = self.network()
        files[0][
            "content"
        ] += "      addresses: [192.0.2.10/24, '2001:db8::10/64']\n      routes: [{to: default, via: 192.0.2.1}]\n      nameservers: {addresses: [192.0.2.53], search: [example.test]}\n"
        value = policy.validate_network(files, nics, observed)["interfaces"][0][
            "config"
        ]
        self.assertEqual(value["addresses"], ["192.0.2.10/24", "2001:db8::10/64"])
        self.assertEqual(value["routes"], [{"to": "default", "via": "192.0.2.1"}])
        self.assertEqual(value["nameservers"]["search"], ["example.test"])

    def test_multiple_nics_map_by_mac_with_reordered_probe(self):
        files, nics, observed = self.network()
        nics.append({"mac": "00:50:56:39:90:02", "device_key": "4001"})
        files[0][
            "content"
        ] += '    ens224:\n      match: {macaddress: "00:50:56:39:90:02"}\n      dhcp6: true\n'
        observed.insert(0, {"ifname": "ens224", "mac": nics[1]["mac"]})
        result = policy.validate_network(files, nics, observed)["interfaces"]
        self.assertEqual(
            {n["ifname"]: n["mac"] for n in result},
            {"ens192": nics[0]["mac"], "ens224": nics[1]["mac"]},
        )

    def test_duplicate_guid_cannot_be_disambiguated_by_disk_order(self):
        m, capture, inspection = self.windows()
        capture["disks"].append(copy.deepcopy(capture["disks"][0]))
        with self.assertRaisesRegex(ValueError, "DATA_IDENTITY_MISMATCH"):
            policy.build(m, capture, inspection)

    def test_folder_mount_is_explicitly_unsupported_in_v1(self):
        capture = {
            "os": "windows",
            "disks": [
                {"partitions": [{"access_paths": ["C:" + chr(92) + "mount" + chr(92)]}]}
            ],
        }
        with self.assertRaisesRegex(ValueError, "ACCESS_PATH_UNSUPPORTED"):
            normalize_capture(capture)

    def test_root_uuid_checkpoint_and_data_import_seal_preparation(self):
        for checkpoint in [
            {"vm_id": "owned"},
            {"root_volume_id": "owned"},
            {"data_volumes": {"1": {"id": "owned"}}},
        ]:
            m, _, _ = self.windows()
            m["runtime"] = {"cloud": {"checkpoint": checkpoint}}
            with self.assertRaisesRegex(ValueError, "CLOUD_TARGET_SEALED"):
                require_unsealed(m)

    def shell(self, body):
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("V2K_SOURCE_GUEST")
            and not k.startswith("V2K_GUEST_CONFIG")
        }
        return subprocess.run(
            [
                "bash",
                "-euc",
                'source "$1"; ' + body,
                "test",
                str(ROOT / "lib/v2k/guest_configuration.sh"),
            ],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def test_preview_requires_no_guest_authentication(self):
        value = self.shell(
            'v2k_guest_config_wizard ablestack-cloud /nonexistent 1 1; printf "%s" "$V2K_GUEST_CONFIG_POLICY"'
        )
        self.assertEqual(value.returncode, 0, value.stderr)
        self.assertEqual(value.stdout, "preserve")

    def test_unattended_preserve_stops_before_run_without_guest_auth(self):
        value = self.shell("v2k_guest_config_wizard ablestack-cloud /nonexistent 1 0")
        self.assertEqual(value.returncode, 44)
        self.assertIn("SOURCE_CONFIG_REQUIRED", value.stderr)

    def test_explicit_off_needs_no_guest_auth(self):
        value = self.shell(
            'V2K_GUEST_CONFIG_POLICY=off; v2k_guest_config_wizard ablestack-cloud /nonexistent 1 0; printf "%s" "$V2K_GUEST_CONFIG_POLICY"'
        )
        self.assertEqual(value.returncode, 0, value.stderr)
        self.assertEqual(value.stdout, "off")

    def test_interactive_guest_secret_is_only_kept_in_runtime_environment(self):
        value = self.shell(
            'v2k_interactive_has_tty(){ return 0; }; v2k_interactive_select_tsv(){ echo preserve; }; v2k_interactive_prompt_text(){ echo fixture-user; }; v2k_interactive_prompt_secret(){ echo fixture-secret; }; v2k_guest_config_wizard ablestack-cloud /nonexistent 0 0; test -n "$V2K_SOURCE_GUEST_PASSWORD"; printf "%s" "$V2K_SOURCE_GUEST_USER"'
        )
        self.assertEqual(value.returncode, 0, value.stderr)
        self.assertEqual(value.stdout, "fixture-user")
        self.assertNotIn("fixture-secret", value.stdout + value.stderr)

    def test_preview_does_not_consume_a_password_fd(self):
        value = self.shell(
            'exec 9<<<fixture-secret; V2K_SOURCE_GUEST_PASSWORD_FD=9; v2k_guest_config_wizard ablestack-cloud /nonexistent 1 1; IFS= read -r remaining <&9; test "$remaining" = fixture-secret'
        )
        self.assertEqual(value.returncode, 0, value.stderr)

    def test_source_desired_state_never_persists_authentication_fields(self):
        m, capture, _ = self.windows()
        capture["credentials"] = {"password": "fixture-secret"}
        with self.assertRaisesRegex(ValueError, "CONTAINS_CREDENTIALS"):
            policy.validate_capture(capture, m["source"]["vm"]["uuid"])

    def test_source_network_comments_cannot_hide_a_password(self):
        capture = {
            "source_vm_uuid": "source",
            "capture_id": "capture",
            "os": "linux",
            "os_id": "ubuntu",
            "os_version": "22.04",
            "configs": [
                {"content": "# password: fixture-secret\nnetwork: {version: 2}"}
            ],
        }
        with self.assertRaisesRegex(ValueError, "CONTAINS_CREDENTIALS"):
            policy.validate_capture(capture, "source")

    def test_timeout_is_rejected_before_source_work(self):
        for value in ["0", "1801", "invalid"]:
            self.assertEqual(
                self.shell("v2k_guest_config_timeout_validate " + value).returncode, 44
            )
        self.assertEqual(
            self.shell("v2k_guest_config_timeout_validate 600").returncode, 0
        )

    def test_sealed_guest_policy_cannot_be_waived(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "manifest.json"
            path.write_text(
                json.dumps({"target": {"guest_configuration_plan": {"version": 1}}})
            )
            body = (
                "v2k_cloud_handoff_started(){ return 0; }; V2K_GUEST_CONFIG_POLICY=off; v2k_guest_config_frozen_options "
                + str(path)
            )
            self.assertEqual(self.shell(body).returncode, 44)

    def test_fresh_verified_observation_clears_previous_channel_error(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = Path(temp) / "manifest.json"
            response = Path(temp) / "response.json"
            manifest.write_text(
                json.dumps(
                    {
                        "target": {
                            "guest_configuration_plan": {
                                "version": 1,
                                "hash": "plan",
                                "operation_id": "operation",
                            }
                        },
                        "runtime": {
                            "cloud": {"checkpoint": {"vm_id": "vm"}},
                            "guest_configuration": {
                                "status": "UNKNOWN",
                                "reason": "GUEST_CHANNEL_UNAVAILABLE",
                                "payload": {"retained": True},
                            },
                        },
                    }
                )
            )
            response.write_text(
                json.dumps(
                    {
                        "reconcilemigratedguestconfigurationresponse": {
                            "migrationguestconfiguration": {
                                "contractversion": 1,
                                "supported": True,
                                "id": "vm",
                                "planhash": "plan",
                                "operationid": "operation",
                                "status": "VERIFIED",
                                "verified": True,
                            }
                        }
                    }
                )
            )
            script = (
                'v2k_guest_config_python(){ return 0; }; v2k_cloud_api_get(){ cat "'
                + str(response)
                + '"; }; v2k_guest_config_reconcile "'
                + str(manifest)
                + '" endpoint key secret bind'
            )
            result = self.shell(script)
            self.assertEqual(result.returncode, 0, result.stderr)
            actual = json.loads(manifest.read_text())["runtime"]["guest_configuration"]
            self.assertEqual(actual["status"], "VERIFIED")
            self.assertNotIn("reason", actual)
            self.assertTrue(actual["payload"]["retained"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
