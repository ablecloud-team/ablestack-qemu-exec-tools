#!/usr/bin/env python3
"""Non-destructive transport smoke: only creates bounded, disposable guest processes."""
import argparse
import base64
import json
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--vm", required=True)
parser.add_argument("--os", choices=["linux", "windows"], required=True)
args = parser.parse_args()
mode = "-l" if args.os == "linux" else "-d"
exe = "/usr/bin/vm_exec"

def ps(script):
    prefix = "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false);"
    return [r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand",
            base64.b64encode((prefix + script).encode("utf-16le")).decode()]

def run(name, command, options=()):
    started = time.monotonic()
    done = subprocess.run([exe, mode, args.vm, "--json", "--timeout", "10", *options, "--", *command],
                          capture_output=True, text=True, timeout=15)
    result = json.loads(done.stdout)
    print(json.dumps({"test": name, "hostExit": done.returncode, "elapsed": round(time.monotonic()-started, 3),
                      "result": result}, ensure_ascii=False), flush=True)
    return done.returncode, result

text = '한글 공백 quote" dollar$ backslash\\'
command = ["/bin/echo", text] if args.os == "linux" else ps("[Console]::Write('" + text + "');")
rc, r = run("unicode-argv", command)
assert rc == 0 and r["state"] == "SUCCEEDED" and r["stdout_raw"].rstrip("\r\n") == text
command = ["/bin/sh", "-c", "printf stdout-marker; printf stderr-marker >&2; exit 7"] if args.os == "linux" else ps("[Console]::Write('stdout-marker');[Console]::Error.Write('stderr-marker');exit 7")
rc, r = run("nonzero-stderr", command)
assert rc == 0 and r["state"] == "FAILED" and r["exit_code"] == 7 and r["stderr"] == "stderr-marker"
if args.os == "linux":
    rc, r = run("own-process-signal", ["/bin/sh", "-c", "kill -TERM $$"])
    assert rc == 0 and r["signal"] == 15 and r["exit_code"] is None
else:
    rc, r = run("direct-cmd", [r"C:\Windows\System32\cmd.exe", "/c", "echo direct-marker"])
    assert rc == 0 and "direct-marker" in r["stdout_raw"]
command = ["/bin/sleep", "2"] if args.os == "linux" else ps("Start-Sleep -Seconds 2")
rc, r = run("deadline-unknown", command, ["--timeout", "0.5"])
assert rc == 3 and r["state"] == "UNKNOWN" and r["guest_exec_pid"] is not None
time.sleep(3)
query = json.dumps({"execute":"guest-exec-status","arguments":{"pid":r["guest_exec_pid"]}})
status = json.loads(subprocess.check_output(["virsh","qemu-agent-command",args.vm,"--timeout","3",query], text=True))
assert status["return"]["exited"] is True
print(json.dumps({"test":"timed-out-guest-reaped","exited":True}), flush=True)
command = ["/bin/sh","-c","head -c 4096 /dev/zero | tr '\\000' x"] if args.os == "linux" else ps("[Console]::Write(('x' * 4096));")
rc, r = run("output-bound", command, ["--max-output-bytes", "128"])
assert rc == 3 and r["error"]["code"] == "OUTPUT_LIMIT"
print(json.dumps({"status":"PASS","vm":args.vm,"os":args.os,"tests":6}),flush=True)
