#!/usr/bin/env python3
"""Q1 regression tests: real child processes with a fake virsh, no VM required."""
# Copyright 2026 ABLECLOUD
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import base64
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("vm_exec", ROOT / "lib/vm_exec.py")
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
FAKE = r"""#!/usr/bin/env python3
import base64,json,os,sys,time,subprocess
from pathlib import Path
case=os.environ.get("CASE","ok")
request=json.loads(sys.argv[-1])
with open(os.environ["TRACE"],"a") as f:
    f.write(json.dumps(request)+"\n")
if case=="hang":
    time.sleep(5)
elif case=="flood":
    sys.stdout.write("x"*4000000);sys.stdout.flush()
elif case=="badjson":
    print("{not-json")
elif case=="qgaerror":
    print(json.dumps({"error":{"class":"GenericError","desc":"not allowed"}}))
elif case=="launch-lost" and request["execute"]=="guest-exec":
    sys.exit(1)
elif request["execute"]=="guest-exec":
    print(json.dumps({"return":{"pid":9001}}))
else:
    result={"exited":True,"exitcode":0,"out-data":base64.b64encode("한글 quote \" $HOME \\ newline\n".encode()).decode()}
    if case=="forever":result={"exited":False}
    if case=="nonzero":result={"exited":True,"exitcode":7}
    if case=="signal":result={"exited":True,"signal":15}
    if case=="null-exit":result={"exited":True,"exitcode":None}
    if case=="invalid-base64":result["out-data"]="????"
    if case=="truncated":result["out-truncated"]=True
    if case=="huge-decoded":result["out-data"]=base64.b64encode(b"x"*1025).decode()
    if case=="binary":result["out-data"]=base64.b64encode(b"\x00\xfftail\n\n").decode()
    if case=="bool-exited":result["exited"]="true"
    if case=="table":result["out-data"]=base64.b64encode(b"USER PID\nroot 12\n").decode()
    if case=="csv":result["out-data"]=base64.b64encode(b'"PDH-CSV 4.0","counter"\n"now","12"\n').decode()
    print(json.dumps({"return":result}))
"""

class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        fake = self.path / "virsh"
        fake.write_text(FAKE)
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.path) + ":" + os.environ["PATH"],
                        VM_EXEC_RUNTIME_DIR=str(self.path / "runtime"), TRACE=str(self.path / "trace"))
        self.command = ROOT / "bin/vm_exec.sh"

    def run_vm(self, *args, case="ok", command=None):
        return subprocess.run(["bash", str(command or self.command), "-l", "test-vm", "--json",
                               "--timeout", "2", *args],
                              env=dict(self.env, CASE=case), capture_output=True, text=True, timeout=8)

    def test_argv_and_legacy_fields(self):
        args = ["/path with space/tool", "한글", 'quote"line\n', "$HOME", "--json", ""]
        run = self.run_vm("--", *args)
        self.assertEqual(run.returncode, 0, run.stderr)
        result = json.loads(run.stdout)
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["guest_exec_pid"], 9001)
        self.assertEqual(result["state"], "SUCCEEDED")
        requests = [json.loads(line) for line in (self.path / "trace").read_text().splitlines()]
        self.assertEqual(requests[0]["arguments"]["path"], args[0])
        self.assertEqual(requests[0]["arguments"]["arg"], args[1:])

    def test_all_mode_aliases(self):
        for mode in ("-w", "-d", "--linux", "--windows", "--direct"):
            run = subprocess.run(["bash", str(self.command), mode, "test-vm", "cmd.exe", "--json"],
                                 env=self.env, capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(json.loads(run.stdout)["exit_code"], 0)

    def test_known_guest_failure_and_signal(self):
        for case, code, sig in (("nonzero", 7, None), ("signal", None, 15)):
            run = self.run_vm("/bin/true", case=case)
            self.assertEqual(run.returncode, 0)
            result = json.loads(run.stdout)
            self.assertEqual((result["exit_code"], result["signal"], result["state"]), (code, sig, "FAILED"))

    def test_malformed_and_lost_responses_never_succeed(self):
        for case in ("badjson", "qgaerror", "launch-lost", "null-exit", "invalid-base64", "bool-exited"):
            with self.subTest(case=case):
                run = self.run_vm("/bin/true", case=case)
                self.assertEqual(run.returncode, 3)
                self.assertNotEqual(json.loads(run.stdout)["state"], "SUCCEEDED")

    def test_deadline_retains_pid_without_relaunch(self):
        started = time.monotonic()
        run = self.run_vm("--timeout", "0.8", "/bin/sleep", "3", case="forever")
        self.assertLess(time.monotonic() - started, 2)
        result = json.loads(run.stdout)
        self.assertEqual((run.returncode, result["state"], result["guest_exec_pid"]), (3, "UNKNOWN", 9001))
        requests = [json.loads(line) for line in (self.path / "trace").read_text().splitlines()]
        self.assertEqual(sum(r["execute"] == "guest-exec" for r in requests), 1)

    def test_hung_rpc_is_bounded(self):
        started = time.monotonic()
        run = self.run_vm("--rpc-timeout", "0.2", "/bin/true", case="hang")
        self.assertEqual(run.returncode, 3)
        self.assertLess(time.monotonic() - started, 2)

    def test_output_limits(self):
        for case in ("flood", "huge-decoded", "truncated"):
            run = self.run_vm("--max-output-bytes", "1024", "/bin/true", case=case)
            result = json.loads(run.stdout)
            self.assertEqual(run.returncode, 3)
            self.assertEqual(result["error"]["code"], "OUTPUT_LIMIT")

    def test_byte_exact_output(self):
        output = self.path / "guest.out"
        run = self.run_vm("--out", str(output), "/bin/true", case="binary")
        self.assertEqual(run.returncode, 0)
        self.assertEqual(output.read_bytes(), b"\x00\xfftail\n\n")
        self.assertTrue(json.loads(run.stdout)["encoding_loss"])

    def test_legacy_table_and_csv(self):
        for case, option, expected in (("table", "--table", [{"USER": "root", "PID": "12"}]),
                                       ("csv", "--csv", [{"timestamp": "now", "counter": "12"}])):
            run = self.run_vm(option, "/bin/true", case=case)
            self.assertEqual(json.loads(run.stdout)["parsed"], expected)

    def test_script_parallel_ndjson(self):
        script = self.path / "commands"
        script.write_text('/bin/echo "hello world"\n/bin/true\n# comment\n')
        run = self.run_vm("--file", str(script), "--parallel")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len([json.loads(line) for line in run.stdout.splitlines()]), 2)

    def test_input_rejected_before_dispatch(self):
        for args in (("--timeout", "nan", "/bin/true"), ("--out",), ("--parallel", "/bin/true"),
                     ("--headers", "a", "/bin/true"), ("--max-output-bytes", "0", "/bin/true"),
                     ("--table", "--headers", " ,PID", "/bin/true")):
            run = self.run_vm(*args)
            self.assertEqual(run.returncode, 2, run.stderr)
        self.assertFalse((self.path / "trace").exists())

    def test_admission_limit_and_release(self):
        previous = os.environ.get("VM_EXEC_RUNTIME_DIR")
        os.environ["VM_EXEC_RUNTIME_DIR"] = self.env["VM_EXEC_RUNTIME_DIR"]
        slots = []
        try:
            for _ in range(8):
                slots.append(engine.Admission().__enter__())
            run = self.run_vm("/bin/true")
            self.assertEqual(json.loads(run.stdout)["error"]["code"], "BUSY")
            self.assertFalse((self.path / "trace").exists())
        finally:
            for slot in slots:
                slot.__exit__()
            if previous is None:
                del os.environ["VM_EXEC_RUNTIME_DIR"]
            else:
                os.environ["VM_EXEC_RUNTIME_DIR"] = previous
        self.assertEqual(self.run_vm("/bin/true").returncode, 0)

    def test_install_layouts_without_legacy_common(self):
        for layout, library in (("rpm", "usr/libexec/ablestack-qemu-exec-tools"),
                                ("deb", "usr/libexec/ablestack-qemu-exec-tools"),
                                ("make", "usr/local/lib/ablestack-qemu-exec-tools")):
            target = self.path / layout
            binary = target / ("usr/bin/vm_exec" if layout in ("rpm", "deb") else "usr/local/bin/vm_exec")
            binary.parent.mkdir(parents=True)
            lib = target / library
            lib.mkdir(parents=True)
            shutil.copy2(self.command, binary)
            shutil.copy2(ROOT / "lib/vm_exec.py", lib / "vm_exec.py")
            run = self.run_vm("/bin/true", command=binary)
            self.assertEqual(run.returncode, 0, run.stderr)

    def test_protocol_guard_has_no_virsh_side_effect(self):
        # Exercise a package missing its protocol adapter, not the fully
        # implemented source adapter which correctly starts host admission.
        prefix = self.path / 'missing-adapter'
        binary = prefix / 'usr/bin/vm_exec'
        library = prefix / 'usr/libexec/ablestack-qemu-exec-tools'
        binary.parent.mkdir(parents=True)
        library.mkdir(parents=True)
        shutil.copy2(self.command, binary)
        shutil.copy2(ROOT / 'lib/vm_exec.py', library / 'vm_exec.py')
        req = {"schemaVersion": "1.0", "kind": "readRequest",
               "requestId": "33333333-3333-4333-8333-333333333333",
               "authority": {"vmUuid": "11111111-1111-4111-8111-111111111111",
                             "hostUuid": "22222222-2222-4222-8222-222222222222",
                             "placementGeneration": "42"},
               "operation": "process.list", "operationId": None, "budgetMs": 5000}
        path = self.path / "request"
        path.write_text(json.dumps(req))
        path.chmod(0o600)
        for version in ("1.0", "2.0"):
            run = subprocess.run(["bash", str(binary), "--process-protocol", version,
                                  "--request-json", str(path)], env=self.env,
                                 capture_output=True, text=True, timeout=3)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(json.loads(run.stdout)["error"]["code"],
                             "HOST_TOOL_MISSING" if version == "1.0" else "UNSUPPORTED_VERSION")
        self.assertFalse((self.path / "trace").exists())
        path.chmod(0o644)
        run = subprocess.run(["bash", str(binary), "--process-protocol", "1.0",
                              "--request-json", str(path)], env=self.env, capture_output=True)
        self.assertEqual(run.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
