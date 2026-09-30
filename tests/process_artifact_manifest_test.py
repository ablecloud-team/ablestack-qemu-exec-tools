# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership. The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.
import tempfile
import unittest
from pathlib import Path
from scripts.process_artifact_manifest import TARGETS, write_manifest


class ProcessArtifactManifestTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.version = "validation-1"
        for index, (_, _, pattern) in enumerate(TARGETS):
            path = self.root / pattern.format(version=self.version)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("iso-%d" % index).encode())

    def tearDown(self):
        self.directory.cleanup()

    def test_manifest_identifies_every_iso_and_checksums(self):
        data = write_manifest(self.root, "a" * 40, "123", self.version)
        self.assertEqual(6, len(data["artifacts"]))
        self.assertEqual("10.2", data["artifacts"][3]["versions"][0])
        self.assertEqual(6, len((self.root / "SHA256SUMS").read_text().splitlines()))
        self.assertIn('"workflowRunId": "123"', (self.root / "manifest.json").read_text())

    def test_packages_are_hashed_and_missing_type_fails_closed(self):
        packages = self.root / "packages"
        for kind in ("rpm", "deb", "msi"):
            target = packages / kind / ("sample." + kind)
            target.parent.mkdir(parents=True)
            target.write_bytes(kind.encode())
        data = write_manifest(self.root, "a" * 40, "123", self.version, packages)
        self.assertEqual({"rpm", "deb", "msi"}, {item["type"] for item in data["packages"]})
        self.assertTrue(all(len(item["sha256"]) == 64 for item in data["packages"]))
        (packages / "msi/sample.msi").unlink()
        with self.assertRaisesRegex(ValueError, "missing msi package"):
            write_manifest(self.root, "a" * 40, "123", self.version, packages)

    def test_missing_iso_fails_closed(self):
        (self.root / TARGETS[0][2].format(version=self.version)).unlink()
        with self.assertRaisesRegex(ValueError, "missing or unsafe ISO"):
            write_manifest(self.root, "a" * 40, "123", self.version)

    def test_unexpected_iso_fails_closed(self):
        (self.root / "rocky/untracked.iso").write_bytes(b"other")
        with self.assertRaisesRegex(ValueError, "unexpected ISO"):
            write_manifest(self.root, "a" * 40, "123", self.version)


if __name__ == "__main__":
    unittest.main()
