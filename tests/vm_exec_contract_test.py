#!/usr/bin/env python3
"""Consume the pinned Cloud C1 fixture bundle; never contact a VM."""
import argparse
import importlib.util
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--contract-dir", required=True, type=Path)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location("c1", args.contract_dir / "verify.py")
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
cases = json.loads((args.contract_dir / "fixtures.json").read_text())
count = 0
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "request.json"
    for case in cases:
        request = case["payload"]
        if request["kind"] not in ("readRequest", "actionRequest"):
            continue
        path.write_text(json.dumps(request))
        path.chmod(0o600)
        run = subprocess.run(["bash", str(ROOT / "bin/vm_exec.sh"),
                              "--process-protocol", request["schemaVersion"], "--request-json", str(path)],
                             capture_output=True, text=True, timeout=3)
        if case["valid"] or case["name"] == "reject-version":
            assert run.returncode == 0, (case["name"], run.stderr)
            result = json.loads(run.stdout)
            contract.validate(result)
            assert result["error"]["code"] == ("HOST_TOOL_MISSING" if case["valid"] else "UNSUPPORTED_VERSION")
        else:
            assert run.returncode == 2, (case["name"], run.stdout, run.stderr)
        count += 1
print("PASS: %d C1 request fixtures; responses conform; Q4/Q5 remain disabled" % count)
