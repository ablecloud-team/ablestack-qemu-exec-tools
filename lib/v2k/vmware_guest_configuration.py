#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Fixed read-only source probe over VMware Tools; all authentication is stdin."""
import argparse, base64, json, os, shlex, ssl, sys, time, urllib.request
from pathlib import Path
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim


def collect(manifest, auth):
    vm_uuid = manifest["source"]["vm"]["uuid"]
    source = manifest["source"]["vm"]
    windows = source.get("guestFamily") == "windowsGuest" or source.get(
        "guest_id", ""
    ).lower().startswith("win")
    host = (
        manifest["source"]["vcenter"]
        .replace("https://", "")
        .replace("http://", "")
        .split("/")[0]
    )
    context = (
        ssl._create_unverified_context()
        if str(os.environ.get("GOVC_INSECURE", "1")).lower() in ["1", "true"]
        else ssl.create_default_context()
    )
    si = SmartConnect(
        host=host,
        user=auth["vcenter_user"],
        pwd=auth["vcenter_password"],
        sslContext=context,
    )
    created = []
    try:
        content = si.RetrieveContent()
        vm = content.searchIndex.FindByUuid(None, vm_uuid, True, False)
        if (
            vm is None
            or str(vm.runtime.powerState) != "poweredOn"
            or str(vm.guest.toolsRunningStatus) != "guestToolsRunning"
        ):
            raise ValueError("SOURCE_CONFIG_REQUIRED")
        ga = vim.vm.guest.NamePasswordAuthentication(
            username=auth["guest_user"],
            password=auth["guest_password"],
            interactiveSession=False,
        )
        files = content.guestOperationsManager.fileManager
        processes = content.guestOperationsManager.processManager
        script = files.CreateTemporaryFileInGuest(
            vm, ga, "ablecloud-v2k-capture-", ".ps1" if windows else ".py"
        )
        created.append(script)
        output = script + ".json"
        created.append(output)
        data = (
            Path(__file__).parent
            / "guest-config"
            / ("source-windows.ps1" if windows else "source-linux.py")
        ).read_bytes()
        attrs = vim.vm.guest.FileManager.FileAttributes()
        url = files.InitiateFileTransferToGuest(
            vm, ga, script, attrs, len(data), True
        ).replace("://*:", "://" + host + ":")
        urllib.request.urlopen(
            urllib.request.Request(url, data=data, method="PUT"),
            context=context,
            timeout=30,
        ).read()
        if windows:
            command = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
            arguments = (
                '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "'
                + script
                + '" -OutputPath "'
                + output
                + '"'
            )
        else:
            command = "/bin/sh"
            arguments = "-c " + shlex.quote(
                "printf '%s\\n' \"$V2K_CAPTURE_AUTH\" | sudo -S -p '' /usr/bin/python3 "
                + shlex.quote(script)
                + " > "
                + shlex.quote(output)
            )
        spec = vim.vm.guest.ProcessManager.ProgramSpec(
            programPath=command, arguments=arguments
        )
        if not windows:
            spec.envVariables = ["V2K_CAPTURE_AUTH=" + auth["guest_password"]]
        pid = processes.StartProgramInGuest(vm, ga, spec)
        deadline = time.time() + 90
        status = None
        while time.time() < deadline:
            found = processes.ListProcessesInGuest(vm, ga, [pid])
            if found and found[0].endTime is not None:
                status = found[0].exitCode
                break
            time.sleep(1)
        if status != 0:
            raise ValueError("SOURCE_GUEST_PROBE_FAILED")
        transfer = files.InitiateFileTransferFromGuest(vm, ga, output)
        if transfer.size > 1048576:
            raise ValueError("SOURCE_CONFIG_TOO_LARGE")
        url = transfer.url.replace("://*:", "://" + host + ":")
        raw = urllib.request.urlopen(url, context=context, timeout=30).read(1048577)
        result = json.loads(raw.decode("utf-8-sig"))
        result["source_vm_uuid"] = vm_uuid
        result["collected_at"] = int(time.time())
        return result
    finally:
        for path in reversed(created):
            try:
                files.DeleteFileInGuest(vm, ga, path)
            except Exception:
                pass
        Disconnect(si)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()
    auth = json.loads(sys.stdin.readline())
    manifest = json.loads(Path(args.manifest).read_text())
    print(json.dumps(collect(manifest, auth)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # SOAP faults and transfer tickets can contain authentication details.
        print("SOURCE_CONFIG_REQUIRED: " + type(error).__name__, file=sys.stderr)
        sys.exit(44)
