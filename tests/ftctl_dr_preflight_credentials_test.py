#!/usr/bin/env python3
"""Reverse preflight uses request credentials without changing plan authority."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

LIBRARY = Path(__file__).resolve().parents[1] / "lib/ftctl/dr_kvm_vmware.sh"


class PreflightCredentialsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("rbd", "nbdkit", "qemu-nbd", "nbd-client"):
            path = self.bin / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o700)
        self.govc = self.bin / "govc"
        self.govc.write_text("#!/usr/bin/env python3\n" +
            "import json,os,sys\n" +
            "if os.environ.get('GOVC_PASSWORD') != 'current-test-value':\n" +
            " print('authentication rejected',file=sys.stderr);sys.exit(1)\n" +
            "print(json.dumps({'virtualMachines':[{'config':{'hardware':{'device':[{'key':2000,'backing':{'fileName':'[ds] current.vmdk'},'capacityInBytes':4096}]}}}]}))\n")
        self.govc.chmod(0o700)
        self.mapping = {"disks": [{"device": "2000", "targetVmRef": "vm-1",
            "targetDiskKey": "2000", "targetVmdkPath": "[ds] stale.vmdk",
            "sourcePool": "rbd", "sourceImage": "test", "virtualBytes": 4096}]}
        (self.root / "map.json").write_text(json.dumps(self.mapping))

    def credential(self, value):
        return {"source": {"type": "VCENTER", "endpoint": "https://vcenter.invalid",
            "principal": "test-user", "auth": {"password": value}, "govcPath": str(self.govc)}}

    def probe(self, supplied, cached, include=True, internal=False):
        profile = {"target": {"externalRef": "vm-1"}}
        if include:
            profile["credentials"] = supplied
        (self.root / "profile.json").write_text(json.dumps(profile))
        cache = self.root / "credentials.json"
        if cached is not None:
            cache.write_text(json.dumps({"credentials": cached}))
        before = cache.read_bytes() if cache.exists() else None
        script = r"""
source "$1"
root="$2"
ftctl_dr_runtime_credential_path() { printf '%s/credentials.json' "$root"; }
ftctl_dr_kvm_vmware_canonicalize_profile() { cp "$root/map.json" "$2"; }
ftctl_dr_kvm_vmware_mode_decision() { printf 'ABSENT\tFULL_SEED\tBASELINE_ABSENT\ttrue\n'; }
ftctl_dr_kvm_vmware_baseline_state() { printf ABSENT; }
ftctl_dr_kvm_vmware_qcow2_source_provider() { return 1; }
ftctl__json_escape() { printf '%s' "$1"; }
ftctl_dr_kvm_vmware_reverse_preflight plan "$root/profile.json" FAILBACK_FINAL AUTO 1 "${3-}"
"""
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], TMPDIR=str(self.root))
        result = subprocess.run(["bash", "-c", script, "test", str(LIBRARY), str(self.root), str(cache) if internal else ""],
                                capture_output=True, text=True, env=env)
        self.assertEqual(before, cache.read_bytes() if cache.exists() else None)
        self.assertEqual([], list(self.root.glob("ftctl-reverse-map.*")))
        self.assertNotIn("current-test-value", result.stdout + result.stderr)
        self.assertNotIn("revoked-test-value", result.stdout + result.stderr)
        return result, json.loads(result.stdout)

    def test_current_request_without_runtime_credentials(self):
        result, status = self.probe(self.credential("current-test-value"), None)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(status["ready"])

    def test_current_request_overrides_stale_runtime(self):
        result, status = self.probe(self.credential("current-test-value"), self.credential("revoked-test-value"))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(status["ready"])

    def test_empty_current_request_never_revives_runtime(self):
        result, status = self.probe({}, self.credential("current-test-value"))
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(status["ready"])

    def test_invalid_current_request_never_uses_valid_cache(self):
        result, status = self.probe(self.credential("revoked-test-value"), self.credential("current-test-value"))
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(status["ready"])
        self.assertIn("authentication rejected", result.stderr)

    def test_legacy_profile_without_field_keeps_runtime_compatibility(self):
        result, status = self.probe(None, self.credential("current-test-value"), include=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(status["ready"])

    def test_target_only_request_cannot_fall_back_to_source_cache(self):
        result, status = self.probe({"target": {"type": "MOLD_KVM"}}, self.credential("current-test-value"))
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(status["ready"])


    def test_internal_worker_uses_explicit_owner_only_credentials(self):
        result, status = self.probe("REDACTED", self.credential("current-test-value"), internal=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(status["ready"])

    def test_redacted_external_request_does_not_revive_runtime(self):
        result, status = self.probe("REDACTED", self.credential("current-test-value"))
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(status["ready"])


if __name__ == "__main__":
    unittest.main()
