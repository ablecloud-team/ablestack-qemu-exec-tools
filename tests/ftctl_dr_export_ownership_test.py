import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("ownership", Path(__file__).resolve().parents[1] / "lib/ftctl/dr_export_ownership.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OwnershipTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.profile = self.root / "profile.json"

    def gate(self, host, generation, operation):
        self.profile.write_text(json.dumps({"request": {} if generation is None else {"exportGeneration": generation}}))
        return module.gate(str(self.root / host), operation, str(self.profile))

    def scoped(self, generation, operation, scope="plan", direction="REVERSE", disks=None):
        self.profile.write_text(json.dumps({"request": {"exportGeneration": generation,
            "exportAuthorityScope": scope, "exportDirection": direction}, "mapping": {"disks": disks or []}}))
        return module.gate(str(self.root / "scoped"), operation, str(self.profile))

    def test_reverse_scope_ack_and_direction_replay(self):
        self.scoped(2, "STOP")
        self.scoped(3, "START")
        ack = module.acknowledgment(self.root / "scoped")
        self.assertEqual((2, "plan", "REVERSE"), (ack["ownershipProtocol"], ack["exportAuthorityScope"], ack["exportDirection"]))
        self.assertEqual(3, self.scoped(3, "START"))
        with self.assertRaisesRegex(ValueError, "SCOPE_MISMATCH"):
            self.scoped(3, "START", direction="FORWARD")
        with self.assertRaisesRegex(ValueError, "SCOPE_MISMATCH"):
            self.scoped(4, "STOP", scope="other")
        self.scoped(4, "STOP")
        with self.assertRaisesRegex(ValueError, "STALE_GENERATION"):
            self.scoped(3, "START")

    def test_same_generation_cannot_change_disk_resource(self):
        self.scoped(2, "STOP")
        self.scoped(3, "START", disks=[{"device":"sda","sourceDiskRef":"one"}])
        with self.assertRaisesRegex(ValueError, "RESOURCE_MISMATCH"):
            self.scoped(3, "START", disks=[{"device":"sda","sourceDiskRef":"two"}])

    def test_legacy_forward_tombstone_migrates_to_scoped_reverse(self):
        self.gate("scoped", 10, "STOP")
        self.scoped(12, "STOP")
        self.scoped(13, "START")
        with self.assertRaises(ValueError):
            self.gate("scoped", 14, "START")

    def test_transfer_rejects_late_start_and_stop(self):
        for host in ("old", "new"):
            self.gate(host, 2, "STOP")
        self.gate("old", 3, "START")
        for host in ("old", "new"):
            self.gate(host, 4, "STOP")
        self.gate("new", 5, "START")
        for host, generation, operation in (("old", 3, "START"), ("new", 4, "STOP")):
            with self.assertRaises(ValueError):
                self.gate(host, generation, operation)
        self.assertEqual(5, self.gate("new", 5, "START"))

    def test_reboot_cannot_restore_old_profile(self):
        self.gate("old", 2, "START")
        self.gate("old", 4, "STOP")
        with self.assertRaises(ValueError):
            self.gate("old", 2, "START")
        self.assertEqual(4, self.gate("old", 4, "STOP"))

    def test_legacy_transition_only_before_management(self):
        self.assertEqual(0, self.gate("old", None, "START"))
        self.gate("old", 2, "STOP")
        with self.assertRaises(ValueError):
            self.gate("old", None, "START")
        self.assertEqual(2, self.gate("old", None, "STOP"))
        self.gate("old", 3, "START")
        with self.assertRaises(ValueError):
            self.gate("old", None, "STOP")

    def test_same_generation_conflict_and_invalid_values(self):
        self.gate("old", 2, "STOP")
        for generation in (2, 1, 0, -1, "3", True):
            with self.assertRaises(ValueError):
                self.gate("old", generation, "START")

    def test_corrupt_tombstone_fails_closed(self):
        self.gate("old", 2, "STOP")
        (self.root / "old/ownership.json").write_text("broken")
        with self.assertRaises(ValueError):
            self.gate("old", 3, "START")

    def test_missing_manifest_recovers_devices_from_persistent_profile(self):
        root = self.root / "old"
        root.mkdir()
        (root / "profile.json").write_text(json.dumps({"mapping": {"disks": [{"device": "sda"}]}}))
        result = module.records("plan-a", str(root), "", str(root/"missing"))
        self.assertEqual(1, len(result))
        self.assertEqual("/run/ablestack-vm-ftctl/nbd-plana-sda.pid", result[0]["pidFile"])

    def test_corrupt_manifest_and_other_plan_fail_closed(self):
        path = self.root / "exports.json"
        path.write_text("broken")
        with self.assertRaises(ValueError):
            module.records("plan-a", str(self.root), "", str(path))
        path.write_text(json.dumps({"planUuid": "different", "exports": []}))
        with self.assertRaises(ValueError):
            module.records("plan-a", str(self.root), "", str(path))

    def test_other_process_unit_is_never_authorized(self):
        path = self.root / "exports.json"
        path.write_text(json.dumps({"exports": [{"device": "sda", "unitName": "other.service"}]}))
        with self.assertRaises(ValueError):
            module.records("plan-a", str(self.root), "", str(path))


if __name__ == "__main__":
    unittest.main()
