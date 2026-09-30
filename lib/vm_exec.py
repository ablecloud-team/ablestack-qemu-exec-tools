#!/usr/bin/env python3
"""Bounded QGA transport with root-only standalone process.list; mutations remain disabled."""
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
import binascii
import concurrent.futures
import csv
import fcntl
import io
import json
import math
import os
import selectors
import shlex
import signal
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path

MAX_OUTPUT = 1024 * 1024
MAX_REQUEST = 65536
MAX_JOBS = 128


class ExecError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def strict_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def constant(_):
        raise ValueError("non-finite number")
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


def dumps(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))


def secure_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ExecError("BUSY", "unsafe admission directory")
    return os.open(str(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


class Admission:
    """Inherited slot FD prevents a surviving virsh from freeing admission early."""
    def __enter__(self):
        root = Path(os.environ.get("VM_EXEC_RUNTIME_DIR", "/run/ablestack-vm-exec"))
        directory = secure_directory(root)
        try:
            for index in range(8):
                fd = os.open("slot-%d.lock" % index, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=directory)
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
                    os.close(fd)
                    raise ExecError("BUSY", "unsafe admission slot")
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    os.close(fd)
                    continue
                self.fd = fd
                return self
            raise ExecError("BUSY", "all eight execution slots are occupied")
        finally:
            os.close(directory)

    def __exit__(self, *_):
        # No explicit LOCK_UN: a still-alive child owns the same open description.
        os.close(self.fd)


def bounded_process(argv, deadline, limit, slot_fd):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ExecError("DEADLINE_EXCEEDED", "execution deadline exceeded")
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True, pass_fds=(slot_fd,))
    except OSError as error:
        raise ExecError("HOST_TOOL_MISSING", "unable to start virsh") from error
    buffers = [bytearray(), bytearray()]
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ, 0)
    selector.register(proc.stderr, selectors.EVENT_READ, 1)
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ExecError("DEADLINE_EXCEEDED", "QGA RPC deadline exceeded")
            for key, _ in selector.select(min(remaining, 0.1)):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                index = key.data
                buffers[index].extend(chunk)
                if len(buffers[index]) > (limit if index == 0 else 4096):
                    raise ExecError("OUTPUT_LIMIT", "QGA transport output exceeded its bound")
        try:
            rc = proc.wait(timeout=max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired as error:
            raise ExecError("DEADLINE_EXCEEDED", "QGA RPC did not exit") from error
        if rc:
            # Never relay untrusted virsh stderr containing guest commands/secrets.
            raise ExecError("QGA_UNREACHABLE", "virsh returned a nonzero status")
        return bytes(buffers[0])
    finally:
        selector.close()
        # Kill the process group even if the leader exited but left descendants.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            # Child inherits admission FD. It cannot silently free capacity.
            pass
        proc.stdout.close()
        proc.stderr.close()


def rpc(vm, request, deadline, rpc_timeout, slot_fd, max_output):
    rpc_deadline = min(deadline, time.monotonic() + rpc_timeout)
    raw = bounded_process(
        ["virsh", "-c", "qemu:///system", "qemu-agent-command", vm,
         "--timeout", str(max(1, math.ceil(rpc_deadline - time.monotonic()))), dumps(request)],
        rpc_deadline, 2 * max_output + 65536, slot_fd)
    try:
        value = strict_json(raw.decode("utf-8"))
    except (ValueError, UnicodeError) as error:
        raise ExecError("INVALID_RESPONSE", "QGA returned invalid JSON") from error
    if not isinstance(value, dict):
        raise ExecError("INVALID_RESPONSE", "QGA response is not an object")
    if "error" in value:
        raise ExecError("QGA_ERROR", "QGA rejected the request")
    if not isinstance(value.get("return"), dict):
        raise ExecError("INVALID_RESPONSE", "QGA return value is not an object")
    return value["return"]


def parse_table(text, headers):
    lines = [line.rstrip("\r") for line in text.splitlines() if line.strip() and set(line.strip()) != {"="}]
    if len(lines) < 2:
        return []
    if headers:
        columns = headers.split(",")
        start = next((n for n, line in enumerate(lines) if columns[0].strip().split()[0] in line), None)
        if start is None:
            return []
        output = []
        for line in lines[start + 1:]:
            offset = 0
            row = {}
            for column in columns:
                row[column.strip()] = line[offset:offset + len(column)].strip()
                offset += len(column)
            output.append(row)
        return output
    columns = lines[0].split()
    return [dict(zip(columns, line.split())) for line in lines[1:]]


def parse_csv(text):
    rows = list(csv.reader(io.StringIO(text)))
    start = next((n for n, row in enumerate(rows) if row and "PDH-CSV" in row[0]), None)
    if start is None:
        return []
    headers = ["timestamp"] + rows[start][1:]
    return [dict(zip(headers, row)) for row in rows[start + 1:] if len(row) == len(headers)]


def execute(vm, command, options):
    result = {"command": options["mode"] + " " + " ".join(command), "parsed": {},
              "stdout_raw": "", "stderr": "", "exit_code": None, "signal": None,
              "guest_exec_pid": None, "state": "UNKNOWN", "error": None,
              "out_truncated": False, "err_truncated": False, "encoding_loss": False}
    deadline = time.monotonic() + options["timeout"]
    dispatched = False
    try:
        request = {"execute": "guest-exec", "arguments": {
            "path": command[0], "arg": command[1:], "capture-output": True}}
        if len(dumps(request).encode("utf-8")) > MAX_REQUEST:
            raise ExecError("INVALID_ARGUMENT", "guest-exec request exceeds 64 KiB")
        with Admission() as slot:
            dispatched = True
            reply = rpc(vm, request, deadline, options["rpc_timeout"], slot.fd, options["max_output"])
            pid = reply.get("pid")
            if type(pid) is not int or pid <= 0:
                raise ExecError("INVALID_RESPONSE", "guest-exec PID is missing or invalid")
            result["guest_exec_pid"] = pid
            delay = 0.25
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ExecError("DEADLINE_EXCEEDED", "guest completion deadline exceeded")
                time.sleep(min(delay, remaining))
                reply = rpc(vm, {"execute": "guest-exec-status", "arguments": {"pid": pid}},
                            deadline, options["rpc_timeout"], slot.fd, options["max_output"])
                if type(reply.get("exited")) is not bool:
                    raise ExecError("INVALID_RESPONSE", "guest-exec-status lacks a boolean exited")
                if not reply["exited"]:
                    delay = min(delay * 2, 1)
                    continue
                exit_code, exit_signal = reply.get("exitcode"), reply.get("signal")
                valid_exit = type(exit_code) is int and 0 <= exit_code <= 4294967295 and exit_signal is None
                valid_signal = type(exit_signal) is int and 1 <= exit_signal <= 255 and exit_code is None
                if not (valid_exit or valid_signal):
                    raise ExecError("INVALID_RESPONSE", "expected exactly one of exitcode or signal")
                result["exit_code"], result["signal"] = exit_code, exit_signal
                decoded = []
                for field in ("out", "err"):
                    encoded = reply.get(field + "-data", "")
                    truncated = reply.get(field + "-truncated", False)
                    if not isinstance(encoded, str) or type(truncated) is not bool:
                        raise ExecError("INVALID_RESPONSE", "invalid output metadata")
                    try:
                        data = base64.b64decode(encoded, validate=True)
                    except (ValueError, binascii.Error) as error:
                        raise ExecError("INVALID_RESPONSE", "invalid output base64") from error
                    if len(data) > options["max_output"]:
                        raise ExecError("OUTPUT_LIMIT", "decoded output exceeds its bound")
                    decoded.append(data)
                    result[field + "_truncated"] = truncated
                if sum(map(len, decoded)) > options["max_output"]:
                    raise ExecError("OUTPUT_LIMIT", "combined output exceeds its bound")
                result["stdout_raw"], result["stderr"] = [data.decode("utf-8", errors="replace") for data in decoded]
                result["encoding_loss"] = any(data.decode("utf-8", errors="replace").encode("utf-8") != data for data in decoded)
                result["state"] = "SUCCEEDED" if exit_code == 0 else "FAILED"
                if result["out_truncated"] or result["err_truncated"]:
                    result["state"] = "FAILED"
                    result["error"] = {"code": "OUTPUT_LIMIT", "message": "QGA truncated captured output"}
                if options["out"]:
                    # Byte-exact output, no appended newline or binary/NUL loss.
                    Path(options["out"]).write_bytes(decoded[0])
                if options["csv"]:
                    result["parsed"] = parse_csv(result["stdout_raw"])
                elif options["table"]:
                    result["parsed"] = parse_table(result["stdout_raw"], options["headers"])
                return result
    except ExecError as error:
        result["state"] = "UNKNOWN" if dispatched else "FAILED"
        result["error"] = {"code": error.code, "message": str(error)}
    except OSError:
        result["state"] = "FAILED"
        result["error"] = {"code": "HOST_IO_ERROR", "message": "unable to access local execution files"}
    return result


def parse_cli(args):
    if not args or args[0] in ("-h", "--help"):
        print("Usage: vm_exec -l|-w|-d VM [options] -- EXECUTABLE [ARG ...]\n"
              "Options: --json --csv --table --headers TEXT --out FILE --exit-code\n"
              "         --file FILE --parallel --timeout SECONDS --rpc-timeout SECONDS\n"
              "         --max-output-bytes BYTES\n"
              "Modes label the guest OS; none implicitly invokes a shell.\n"
              "Process protocol: --process-protocol 1.0 --request-json PRIVATE_FILE")
        return None
    aliases = {"--linux": "-l", "--windows": "-w", "--direct": "-d"}
    mode = aliases.get(args[0], args[0])
    if mode not in ("-l", "-w", "-d") or len(args) < 2 or not args[1] or args[1].startswith("-"):
        raise ValueError("expected OS mode and VM name/UUID")
    vm = args[1]
    options = {"mode": mode, "json": False, "csv": False, "table": False, "headers": "",
               "out": "", "file": "", "exit_code": False, "parallel": False,
               "timeout": 30.0, "rpc_timeout": 3.0, "max_output": MAX_OUTPUT}
    flags = {"--json": "json", "--csv": "csv", "--table": "table",
             "--exit-code": "exit_code", "--parallel": "parallel"}
    values = {"--out": "out", "-o": "out", "--file": "file", "-f": "file", "--headers": "headers",
              "--timeout": "timeout", "--rpc-timeout": "rpc_timeout", "--max-output-bytes": "max_output"}
    command = []
    index = 2
    while index < len(args):
        arg = args[index]
        if arg == "--":
            command.extend(args[index + 1:])
            break
        if arg in flags:
            options[flags[arg]] = True
        elif arg in values:
            index += 1
            if index >= len(args):
                raise ValueError("option requires a value: " + arg)
            options[values[arg]] = args[index]
        else:
            command.append(arg)
        index += 1
    for key, maximum in (("timeout", 90), ("rpc_timeout", 3)):
        options[key] = float(options[key])
        if not math.isfinite(options[key]) or not 0.1 <= options[key] <= maximum:
            raise ValueError("invalid " + key)
    options["max_output"] = int(options["max_output"])
    if not 1 <= options["max_output"] <= MAX_OUTPUT:
        raise ValueError("output limit must be 1..1048576")
    if options["csv"] and options["table"]:
        raise ValueError("--csv and --table are mutually exclusive")
    if options["headers"] and not options["table"]:
        raise ValueError("--headers requires --table")
    if options["headers"] and any(not column.strip() for column in options["headers"].split(",")):
        raise ValueError("table headers must not contain empty columns")
    if options["parallel"] and (not options["file"] or options["out"]):
        raise ValueError("--parallel requires --file and cannot share --out")
    if options["file"]:
        if command:
            raise ValueError("--file cannot be combined with a command")
        with open(options["file"], "rb") as handle:
            data = handle.read(MAX_REQUEST + 1)
        if len(data) > MAX_REQUEST:
            raise ValueError("command file exceeds 64 KiB")
        commands = [shlex.split(line, comments=True) for line in data.decode("utf-8").splitlines()]
        commands = [line for line in commands if line]
        if not 1 <= len(commands) <= MAX_JOBS:
            raise ValueError("command file must contain 1..128 commands")
    else:
        if not command or not command[0]:
            raise ValueError("executable is required")
        commands = [command]
    return vm, commands, options


def canonical_uuid(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("invalid canonical UUID")


def process_protocol(args):
    cloud_guard = None
    action_context = None
    if len(args) == 8 and args[4] == "--cloud-action-context" and args[6:] == ["--cloud-action-guard-fd", "9"]:
        action_context = args[5]
        args = args[:4]
    if len(args) == 6 and args[4:] == ["--cloud-read-guard-fd", "9"]:
        cloud_guard = 9
        args = args[:4]
    if len(args) != 4 or args[0] != "--process-protocol" or args[2] != "--request-json":
        raise ValueError("expected --process-protocol VERSION --request-json PRIVATE_FILE")
    fd = os.open(args[3], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("request must be an owned 0600 regular file")
        raw = handle.read(MAX_REQUEST + 1)
    if len(raw) > MAX_REQUEST:
        raise ValueError("request exceeds 64 KiB")
    request = strict_json(raw.decode("utf-8"))
    if not isinstance(request, dict):
        raise ValueError("request must be an object")
    canonical_uuid(request.get("requestId"))
    authority = request.get("authority")
    if not isinstance(authority, dict) or set(authority) != {"vmUuid", "hostUuid", "placementGeneration"}:
        raise ValueError("invalid authority")
    canonical_uuid(authority["vmUuid"])
    canonical_uuid(authority["hostUuid"])
    generation = authority["placementGeneration"]
    if not isinstance(generation, str) or not generation.isascii() or not generation.isdigit() or len(generation) > 20:
        raise ValueError("invalid placement generation")
    base = {"schemaVersion", "kind", "requestId", "authority", "budgetMs"}
    kind = request.get("kind")
    if kind == "readRequest":
        expected = base | {"operation", "operationId"}
        if request.get("operation") not in ("capability.get", "process.list", "operation.get"):
            raise ValueError("unsupported read operation")
        if request["operation"] == "operation.get":
            canonical_uuid(request.get("operationId"))
        elif request.get("operationId") is not None:
            raise ValueError("unexpected operationId")
    elif kind == "actionRequest":
        expected = base | {"operationId", "action", "identity", "snapshotId", "observedAt", "service"}
        canonical_uuid(request.get("operationId"))
        canonical_uuid(request.get("snapshotId"))
        action = request.get("action")
        if action not in ("process.terminate", "process.kill", "service.restart"):
            raise ValueError("unsupported action")
        identity = request.get("identity")
        if not isinstance(identity, dict) or set(identity) != {"vmUuid", "bootId", "pid", "startTicks"}:
            raise ValueError("invalid process identity")
        if identity["vmUuid"] != authority["vmUuid"]:
            raise ValueError("cross-VM identity")
        if not isinstance(identity["bootId"], str) or not 1 <= len(identity["bootId"]) <= 256:
            raise ValueError("invalid boot identity")
        if type(identity["pid"]) is not int or not 1 <= identity["pid"] <= 4294967295:
            raise ValueError("invalid process PID")
        ticks = identity["startTicks"]
        if not isinstance(ticks, str) or not ticks.isascii() or not ticks.isdigit() or not 1 <= len(ticks) <= 20:
            raise ValueError("invalid process start ticks")
        from datetime import datetime
        observed = request.get("observedAt")
        if not isinstance(observed, str) or not observed.endswith("Z"):
            raise ValueError("observedAt must be UTC")
        datetime.fromisoformat(observed[:-1] + "+00:00")
        service = request.get("service")
        if action == "service.restart":
            if not isinstance(service, dict) or set(service) != {"manager", "name", "configurationHash"}:
                raise ValueError("restart requires service identity")
            if service["manager"] not in ("systemd", "scm") or not isinstance(service["name"], str) or not 1 <= len(service["name"]) <= 256:
                raise ValueError("invalid service identity")
            digest = service["configurationHash"]
            if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                raise ValueError("invalid service configuration hash")
        elif service is not None:
            raise ValueError("unexpected service target")
        if action != "service.restart" and type(request.get("budgetMs")) is int and request["budgetMs"] > 15000:
            raise ValueError("termination budget exceeds 15 seconds")
    else:
        raise ValueError("unsupported request kind")
    if set(request) != expected:
        raise ValueError("unexpected or missing request fields")
    if type(request.get("budgetMs")) is not int or not 1 <= request["budgetMs"] <= (10000 if kind == "readRequest" else 90000):
        raise ValueError("invalid budget")
    if args[1] == '1.0' and request.get('schemaVersion') == '1.0' and kind == 'readRequest' and request['operation'] == 'process.list':
        try:
            import process_list_host
        except ImportError:
            pass
        else:
            print(dumps(process_list_host.run(request, sys.modules[__name__], cloud_guard)))
            return 0
    if args[1] == '1.0' and request.get('schemaVersion') == '1.0' and (kind == 'actionRequest' or request.get('operation') == 'operation.get'):
        try:
            import process_action_host
        except ImportError:
            pass
        else:
            print(dumps(process_action_host.run(request, sys.modules[__name__], action_context)))
            return 0
    code = "UNSUPPORTED_VERSION" if args[1] != "1.0" or request.get("schemaVersion") != "1.0" else "HOST_TOOL_MISSING"
    print(dumps({"schemaVersion": "1.0", "kind": "failure", "requestId": request["requestId"],
                 "authority": authority, "error": {"code": code, "message":
                 "Unsupported process protocol version" if code == "UNSUPPORTED_VERSION" else
                 "Process adapter is missing from the host package", "retryMode": "NONE"}}))
    return 0


def main(args=None):
    args = sys.argv[1:] if args is None else args
    try:
        if args and args[0] == "--process-protocol":
            return process_protocol(args)
        parsed = parse_cli(args)
        if parsed is None:
            return 0
        vm, commands, options = parsed
    except (ValueError, OSError, UnicodeError) as error:
        print("vm_exec: " + str(error), file=sys.stderr)
        return 2
    if options["parallel"]:
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=4)
        results = pool.map(lambda command: execute(vm, command, options), commands)
    else:
        pool = None
        results = (execute(vm, command, options) for command in commands)
    rc = 0
    try:
        for result in results:
            if options["json"]:
                print(dumps(result), flush=True)
            else:
                print("===== " + result["command"] + " STDOUT =====")
                print(result["stdout_raw"], end="")
                print("\n===== STDERR =====")
                print(result["stderr"], end="")
                if options["exit_code"]:
                    print("\nExit Code: " + str(result["exit_code"]) + "; signal: " + str(result["signal"]))
                if result["error"]:
                    print("\nvm_exec: " + result["error"]["code"], file=sys.stderr)
            if result["error"] or result["state"] == "UNKNOWN":
                rc = 3
    finally:
        if pool:
            pool.shutdown(wait=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
