#!/usr/bin/env python3
"""Migration policy, real image and wizard contracts. No external VM is used."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODES = {"qcow2": ("off", "metadata", "falloc", "full"), "raw": ("off", "falloc", "full")}
SIZE = 8 * 1024 * 1024


def shell(script, *, env=None, args=(), data=None, ok=True):
    variables = {**os.environ, "REPO": str(ROOT), **(env or {})}
    result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "test", *args],
                            env=variables, input=data, text=True, capture_output=True, timeout=90)
    if ok and result.returncode:
        raise AssertionError(f"exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


TRANSFER = r'''
export V2K_ROOT_DIR="$REPO" V2K_LIB_DIR="$REPO/lib/v2k" V2K_WORKDIR="$CASE_DIR"
export VDDK_LIBDIR=/tmp
export V2K_RUN_ID=preallocation-test V2K_JSON_OUT=1 V2K_BASE_METHOD="$METHOD"
source "$REPO/lib/v2k/transfer_base.sh"
v2k_event() { :; }
v2k_compat_vddk_child_env_prefix() { printf 'env -u LD_LIBRARY_PATH'; }
v2k_compat_nbdkit_bin() { printf '/usr/bin/true'; }
v2k_compat_nbdkit_vddk_plugin() { printf vddk; }
v2k_compat_vddk_ld_library_path() { printf /tmp; }
v2k_compat_vddk_config_file() { printf /dev/null; }
# Replace only the remote VDDK source. The production create/copy/verify path runs.
v2k_transfer_base_run_vddk() { local uri="$SOURCE_IMAGE"; eval "$2"; }
v2k_transfer_base_one "$MANIFEST" 0 vc.invalid AA vm-1 snap-1 /dev/null
'''


WIZARD = r'''
export V2K_ROOT_DIR="$REPO" V2K_LIB_DIR="$REPO/lib/v2k"
export N2K_ROOT_DIR="$REPO" N2K_LIB_DIR="$REPO/lib/n2k"
export V2K_WORKDIR="$CASE_DIR/work" N2K_WORKDIR="$CASE_DIR/work"
export V2K_MANIFEST="$CASE_DIR/work/manifest.json" N2K_MANIFEST="$CASE_DIR/work/manifest.json"
source "$REPO/lib/$TOOL/engine.sh"
source "$REPO/lib/$TOOL/interactive.sh"
v2k_compat_resolve_profile() { :; }
v2k_vmware_inventory_json() { printf '%s' "$INVENTORY"; }
n2k_nutanix_fetch_vm_inventory() { cat "$REPO/tests/fixtures/n2k/inventory/vm_linux.json"; }
v2k_cloud_target_storage_pool_json() { printf '{"scope":"CLUSTER","path":"%s/target"}' "$CASE_DIR"; }
n2k_cloud_target_storage_pool_json() { printf '{"scope":"CLUSTER","path":"%s/target"}' "$CASE_DIR"; }
v2k_cloud_target_file_storage_path_from_pool() { printf '%s/target' "$CASE_DIR"; }
n2k_cloud_target_file_storage_path_from_pool() { printf '%s/target' "$CASE_DIR"; }
v2k_interactive_has_tty() { [[ "$TEST_TTY" == 1 ]]; }
n2k_interactive_has_tty() { [[ "$TEST_TTY" == 1 ]]; }
v2k_interactive_prompt_confirm() { [[ "$CANCEL" == 0 ]]; }
n2k_interactive_prompt_confirm() { [[ "$CANCEL" == 0 ]]; }
v2k_cmd_run() { printf '%s\0' "$@" > "$CASE_DIR/captured"; }
n2k_cmd_run() { printf '%s\0' "$@" > "$CASE_DIR/captured"; }
"${TOOL}_cmd_wizard" "$@"
'''


class Preallocation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="migration-preallocation-")
        self.addCleanup(self.tmp.cleanup)
        self.case = Path(self.tmp.name)
        self.source = self.case / "source raw image"
        with self.source.open("wb") as out:
            out.truncate(SIZE)
            out.seek(1024 * 1024)
            out.write(bytes(range(256)) * 16)
            out.seek(SIZE - 4096)
            out.write(b"migration-data" * 100)

    def manifest(self, *, mode="falloc", fmt="qcow2", legacy=False, directory=None):
        directory = directory or self.case
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / f"target image.{fmt}"
        storage = {"type": "file"}
        if not legacy:
            storage["preallocation"] = mode
        doc = {"target": {"storage": storage, "format": fmt},
               "source": {"vm": {"name": "fixture"}},
               "disks": [{"disk_id": "disk-0", "size_bytes": SIZE,
                          "vmdk": {"path": str(self.source)},
                          "transfer": {"target_path": str(target), "base_done": False}}]}
        path = directory / "manifest.json"
        path.write_text(json.dumps(doc))
        return path, target

    def test_standalone_package_policy_parity(self):
        self.assertEqual((ROOT / "lib/v2k/preallocation.sh").read_bytes(),
                         (ROOT / "lib/n2k/preallocation.sh").read_bytes())

    def test_policy_matrix_and_invalid_values(self):
        for fmt, modes in MODES.items():
            for mode in (*modes, ""):
                with self.subTest(fmt=fmt, mode=mode):
                    result = shell('source "$REPO/lib/n2k/preallocation.sh"; '
                                   'image_preallocation_resolve file "$FMT" "$MODE" "$EXPLICIT"; '
                                   'printf "%s" "$IMAGE_PREALLOCATION_MODE"',
                                   env={"FMT": fmt, "MODE": mode, "EXPLICIT": str(int(bool(mode)))})
                    self.assertEqual(result.stdout, mode or "falloc")
        for storage, fmt, mode in (("file", "raw", "metadata"), ("rbd", "raw", "falloc"),
                                   ("block", "raw", "full"), ("file", "qcow2", "falloc,cluster_size=1M"),
                                   ("file", "qcow2", ""), ("file", "qcow2", "FALLOC")):
            with self.subTest(storage=storage, mode=mode):
                result = shell('source "$REPO/lib/n2k/preallocation.sh"; '
                               'image_preallocation_resolve "$STORAGE" "$FMT" "$MODE" 1',
                               env={"STORAGE": storage, "FMT": fmt, "MODE": mode}, ok=False)
                self.assertEqual(result.returncode, 2)
        for storage in ("rbd", "block"):
            for explicit in ("0", "1"):
                result = shell('source "$REPO/lib/n2k/preallocation.sh"; '
                               'image_preallocation_resolve "$STORAGE" raw off "$EXPLICIT"; '
                               'test -z "$IMAGE_PREALLOCATION_MODE"',
                               env={"STORAGE": storage, "EXPLICIT": explicit})
                self.assertEqual(result.returncode, 0)

    def test_manifest_legacy_and_change_guards(self):
        manifest, target = self.manifest(legacy=True)
        before = manifest.read_bytes()
        result = shell('source "$REPO/lib/n2k/preallocation.sh"; '
                       'image_preallocation_from_manifest "$MANIFEST"; '
                       'printf "%s/%s" "$IMAGE_PREALLOCATION_MODE" "$IMAGE_PREALLOCATION_SOURCE"',
                       env={"MANIFEST": str(manifest)})
        self.assertEqual(result.stdout, "off/legacy")
        self.assertEqual(before, manifest.read_bytes())
        # A change is allowed only while no disk has started, without a resolver write.
        script = ('source "$REPO/lib/n2k/preallocation.sh"; '
                  'image_preallocation_resolve file qcow2 falloc 1 "$MANIFEST"')
        shell(script, env={"MANIFEST": str(manifest)})
        target.write_text("operator-owned")
        self.assertEqual(shell(script, env={"MANIFEST": str(manifest)}, ok=False).returncode, 2)
        self.assertEqual(target.read_text(), "operator-owned")
        target.unlink()
        doc = json.loads(manifest.read_text())
        doc["disks"][0]["transfer"]["preallocation"] = {"started": True, "created": False}
        manifest.write_text(json.dumps(doc))
        self.assertEqual(shell(script, env={"MANIFEST": str(manifest)}, ok=False).returncode, 2)

    def test_n2k_cli_init_plan_and_help(self):
        for mode in (None, "off", "metadata", "falloc", "full"):
            directory = self.case / str(mode)
            cmd = ["bash", str(ROOT / "bin/ablestack_n2k.sh"), "--workdir", str(directory), "init", "--vm", "fixture",
                   "--pc", "pc.invalid", "--dst", str(directory / "target"),
                   "--inventory-file", str(ROOT / "tests/fixtures/n2k/inventory/vm_linux.json")]
            if mode:
                cmd += ["--target-preallocation", mode]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            doc = json.loads((directory / "manifest.json").read_text())
            self.assertEqual(doc["target"]["storage"]["preallocation"], mode or "falloc")
        result = subprocess.run(["bash", str(ROOT / "bin/ablestack_n2k.sh"), "--json", "plan", "--pc", "pc.invalid",
                                 "--vm", "fixture", "--mode", "manual-disk", "--target-storage", "auto"],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["target"]["preallocation"], "falloc")
        for tool in ("v2k", "n2k"):
            for command in ("init", "run", "wizard", "migrate", "interactive"):
                result = subprocess.run(["bash", str(ROOT / f"bin/ablestack_{tool}.sh"), command, "--help"],
                                        text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--target-preallocation", result.stdout)
                self.assertIn("falloc", result.stdout)

    def test_real_file_copy_all_supported_modes(self):
        for tool, method in (("v2k", "nbdcopy"), ("v2k", "convert"), ("n2k", "convert")):
            for fmt, modes in MODES.items():
                for mode in modes:
                    with self.subTest(tool=tool, method=method, fmt=fmt, mode=mode):
                        directory = self.case / f"{tool}-{method}-{fmt}-{mode}"
                        manifest, target = self.manifest(mode=mode, fmt=fmt, directory=directory)
                        env = {"CASE_DIR": str(directory), "MANIFEST": str(manifest), "METHOD": method,
                               "SOURCE_IMAGE": str(self.source), "TARGET_IMAGE": str(target), "FMT": fmt}
                        if tool == "v2k":
                            shell(TRANSFER, env=env)
                        else:
                            shell('export N2K_ROOT_DIR="$REPO" N2K_LIB_DIR="$REPO/lib/n2k" N2K_WORKDIR="$CASE_DIR"; '
                                  'source "$REPO/lib/n2k/engine.sh"; n2k_event() { :; }; '
                                  'map="$(jq -nc --arg p "$SOURCE_IMAGE" \'{"disk-0":$p}\')"; '
                                  'n2k_transfer_cold_base_one "$MANIFEST" "$map" 0', env=env)
                        compare = subprocess.run(["qemu-img", "compare", "-f", "raw", "-F", fmt,
                                                  str(self.source), str(target)], capture_output=True, text=True)
                        self.assertEqual(compare.returncode, 0, compare.stderr)
                        allocated = target.stat().st_blocks * 512
                        if mode in ("falloc", "full"):
                            self.assertGreaterEqual(allocated, SIZE)
                        else:
                            self.assertLess(allocated, SIZE)
                        state = json.loads(manifest.read_text())["disks"][0]["transfer"]
                        self.assertTrue(state["base_done"])
                        self.assertTrue(state["preallocation"]["verified"])
                        # A completed v2k target is inspected, never re-created on resume.
                        if tool == "v2k":
                            stamp = target.stat().st_mtime_ns
                            shell(TRANSFER, env=env)
                            self.assertEqual(stamp, target.stat().st_mtime_ns)

    def test_dry_run_and_existing_file_do_not_overwrite(self):
        manifest, target = self.manifest()
        env = {"CASE_DIR": str(self.case), "MANIFEST": str(manifest), "METHOD": "convert",
               "SOURCE_IMAGE": str(self.source), "V2K_DRY_RUN": "1"}
        before = manifest.read_bytes()
        shell(TRANSFER, env=env)
        self.assertFalse(target.exists())
        self.assertEqual(before, manifest.read_bytes())
        target.write_text("operator-owned")
        env["V2K_DRY_RUN"] = "0"
        self.assertNotEqual(shell(TRANSFER, env=env, ok=False).returncode, 0)
        self.assertEqual(target.read_text(), "operator-owned")


    def test_allocation_failures_do_not_fallback(self):
        real_qemu = shutil.which("qemu-img")
        for tool in ("v2k", "n2k"):
            for code, reason in ((28, "No space left on device"), (95, "Operation not supported"), (13, "Permission denied")):
                with self.subTest(tool=tool, reason=reason):
                    directory = self.case / f"failure-{tool}-{code}"
                    manifest, target = self.manifest(directory=directory)
                    mocks = directory / "bin"
                    mocks.mkdir()
                    wrapper = mocks / "qemu-img"
                    wrapper.write_text('#!/usr/bin/env bash\n'
                        'printf "%s\\n" "$*" >> "$CASE_DIR/qemu-argv"\n'
                        'if [[ ( "$1" == create && "$*" != *help* ) || "$1" == convert ]]; then\n'
                        f'  printf "%s\\n" "{reason}" >&2; exit {code}\nfi\n'
                        'exec "$REAL_QEMU" "$@"\n')
                    wrapper.chmod(0o755)
                    env = {"PATH": str(mocks) + os.pathsep + os.environ["PATH"], "REAL_QEMU": real_qemu,
                           "CASE_DIR": str(directory), "MANIFEST": str(manifest), "METHOD": "nbdcopy",
                           "SOURCE_IMAGE": str(self.source)}
                    if tool == "v2k":
                        result = shell(TRANSFER, env=env, ok=False)
                    else:
                        result = shell('export N2K_WORKDIR="$CASE_DIR"; source "$REPO/lib/n2k/engine.sh"; '
                            'n2k_event() { :; }; '
                            'map="$(jq -nc --arg p "$SOURCE_IMAGE" \'{"disk-0":$p}\')"; '
                            'n2k_transfer_cold_base_one "$MANIFEST" "$map" 0', env=env, ok=False)
                    self.assertEqual(result.returncode, code, result.stderr)
                    doc = json.loads(manifest.read_text())
                    state = doc["disks"][0]["transfer"]
                    self.assertFalse(state["base_done"])
                    self.assertTrue(state["preallocation"]["started"])
                    self.assertFalse(state["preallocation"]["created"])
                    self.assertEqual(doc["target"]["storage"]["preallocation"], "falloc")
                    self.assertEqual(doc["runtime"]["last_error"]["code"], code)
                    self.assertNotIn("preallocation=off", (directory / "qemu-argv").read_text())
                    self.assertEqual(target.stat().st_size, 0)

    def test_standalone_installed_layout(self):
        for tool in ("v2k", "n2k"):
            prefix = self.case / ("package-" + tool) / "usr/local"
            (prefix / "bin").mkdir(parents=True)
            shutil.copyfile(ROOT / f"bin/ablestack_{tool}.sh", prefix / f"bin/ablestack_{tool}")
            shutil.copytree(ROOT / f"lib/{tool}", prefix / f"lib/ablestack-qemu-exec-tools/{tool}",
                            ignore=shutil.ignore_patterns("__pycache__"))
            result = subprocess.run(["bash", str(prefix / f"bin/ablestack_{tool}"), "wizard", "--help"],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--target-preallocation", result.stdout)

    def test_v2k_init_parser_and_manifest(self):
        for mode in (None, *MODES["qcow2"]):
            directory = self.case / ("init-" + str(mode))
            flags = ["--vm", "fixture", "--vcenter", "vc.invalid", "--dst", str(directory / "target")]
            if mode:
                flags += ["--target-preallocation", mode]
            shell(r'''
export V2K_ROOT_DIR="$REPO" V2K_LIB_DIR="$REPO/lib/v2k" V2K_WORKDIR="$CASE_DIR"
export V2K_MANIFEST="$CASE_DIR/manifest.json" V2K_RUN_ID=init-test V2K_VDDK_THUMBPRINT=AA
unset GOVC_USERNAME GOVC_PASSWORD GOVC_URL VDDK_USER VDDK_PASSWORD
source "$REPO/lib/v2k/engine.sh"
v2k_compat_bootstrap_env() { :; }
v2k_compat_resolve_profile() { :; }
v2k_compat_write_env() { :; }
v2k_vmware_inventory_json() { printf '{"vm":{"name":"fixture","cbt_supported":true},"disks":[{"disk_id":"scsi0:0","device_key":"2000","size_bytes":8388608,"controller":{"kind":"scsi","type":"VirtualLsiLogicSASController"},"vmdk":{"path":"[fixture] disk.vmdk"}}]}'; }
v2k_event() { :; }
v2k_cmd_init "$@"
''', env={"CASE_DIR": str(directory)}, args=flags)
            doc = json.loads((directory / "manifest.json").read_text())
            self.assertEqual(doc["target"]["storage"]["preallocation"], mode or "falloc")


    def test_run_forwards_policy_to_real_init_boundary(self):
        for tool in ("v2k", "n2k"):
            for mode in (None, "metadata"):
                directory = self.case / f"run-{tool}-{mode}"
                flags = ["--foreground", "--vm", "fixture", "--dst", str(directory / "target"),
                         "--vcenter" if tool == "v2k" else "--pc", "source.invalid",
                         "--username", "fixture-user", "--password", "fixture-secret", "--split", "phase1"]
                if mode:
                    flags += ["--target-preallocation", mode]
                script = r'''
export V2K_ROOT_DIR="$REPO" V2K_LIB_DIR="$REPO/lib/v2k" V2K_WORKDIR="$CASE_DIR"
export N2K_ROOT_DIR="$REPO" N2K_LIB_DIR="$REPO/lib/n2k" N2K_WORKDIR="$CASE_DIR"
source "$REPO/lib/$TOOL/engine.sh"
if [[ "$TOOL" == v2k ]]; then source "$REPO/lib/v2k/orchestrator.sh"; fi
v2k_event() { :; }
n2k_event() { :; }
v2k_compat_resolve_profile() { :; }
v2k_compat_bootstrap_env() { :; }
v2k_compat_write_env() { :; }
v2k_cmd_init() { printf '%s\0' "$@" > "$CASE_DIR/argv"; return 77; }
n2k_cmd_init() { mkdir -p "$CASE_DIR"; printf '%s\0' "$@" > "$CASE_DIR/argv"; return 77; }
"${TOOL}_cmd_run" "$@"
'''
                result = shell(script, env={"TOOL": tool, "CASE_DIR": str(directory)}, args=flags, ok=False)
                self.assertNotEqual(result.returncode, 0)
                capture = directory / "argv"
                self.assertTrue(capture.exists(), result.stderr)
                argv = capture.read_bytes().decode().rstrip("\0").split("\0")
                self.assertEqual(argv[argv.index("--target-preallocation") + 1], mode or "falloc")

    def test_background_rejects_invalid_policy_before_worker(self):
        for tool in ("v2k", "n2k"):
            directory = self.case / ("background-" + tool)
            result = shell(r'''
export V2K_ROOT_DIR="$REPO" V2K_LIB_DIR="$REPO/lib/v2k" V2K_WORKDIR="$CASE_DIR"
export N2K_ROOT_DIR="$REPO" N2K_LIB_DIR="$REPO/lib/n2k" N2K_WORKDIR="$CASE_DIR"
source "$REPO/lib/$TOOL/engine.sh"
if [[ "$TOOL" == v2k ]]; then source "$REPO/lib/v2k/orchestrator.sh"; fi
"${TOOL}_cmd_run" --vm fixture --target-format raw --target-preallocation metadata
''', env={"TOOL": tool, "CASE_DIR": str(directory)}, ok=False)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(directory.exists())

    def wizard(self, tool, flags=(), *, tty="0", selection="\n", cancel=False, legacy=False, saved=None, cloud=False):
        directory = self.case / ("wizard-" + str(len(list(self.case.iterdir()))))
        directory.mkdir()
        if legacy or saved:
            path, _ = self.manifest(mode=saved or "off", legacy=legacy, directory=directory / "work")
            doc = json.loads(path.read_text())
            doc["target"].update({"provider": "libvirt", "dst_root": str(directory / "target")})
            doc["source"]["pc"] = "pc.invalid"
            doc["phases"] = {"base_sync": {"done": True}, "phase1": {"done": True}}
            doc["runtime"] = {"split": {"phase1": {"done": True}}}
            path.write_text(json.dumps(doc))
        inventory = {"vm": {"name": "fixture", "nics": [{"mac": "52:54:00:12:34:56", "label": "nic0"}]},
                     "disks": [{"disk_id": "disk-0", "size_bytes": SIZE}]}
        if tool == "v2k":
            inventory["vm"]["firmware"]="bios"
            inventory["disks"][0].update({"disk_id":"scsi0:0","device_key":"2000","controller":{"kind":"scsi","type":"VirtualLsiLogicSASController","bus":0,"unit":0}})
        args = ["--vm", "fixture", "--username", "fixture-user", "--password", "fixture-secret",
                "--split", "phase2" if (legacy or saved) else "phase1", "--dst", str(directory / "target")]
        args += ["--vcenter" if tool == "v2k" else "--pc", "source.invalid"]
        args += ["--target-profile", "cloud-filesystem" if cloud else "libvirt-qcow2"]
        if cloud:
            args += ["--cloud-allocation-copy"]
            args += ["--cloud-endpoint", "https://cloud.invalid", "--cloud-api-key", "fixture-key",
                     "--cloud-secret-key", "fixture-cloud-secret", "--cloud-zone-id", "zone",
                     "--cloud-service-offering-id", "offering", "--cloud-network-id", "network",
                     "--cloud-storage-id", "pool", "--cloud-name", "fixture-target"]
        result = shell(WIZARD, env={"TOOL": tool, "CASE_DIR": str(directory), "INVENTORY": json.dumps(inventory),
                                   "TEST_TTY": tty, "CANCEL": str(int(cancel))}, args=(*args, *flags),
                       data=selection, ok=False)
        captured = directory / "captured"
        argv = captured.read_bytes().decode().rstrip("\0").split("\0") if captured.exists() else []
        return result, argv, directory

    def test_wizard_defaults_explicit_modes_and_real_menu(self):
        for tool in ("v2k", "n2k"):
            with self.subTest(tool=tool, case="yes-default"):
                r, args, _ = self.wizard(tool, ("--yes",))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(args[args.index("--target-preallocation") + 1], "falloc")
                self.assertIn("falloc (default)", r.stderr)
            for mode in MODES["qcow2"]:
                with self.subTest(tool=tool, mode=mode):
                    r, args, _ = self.wizard(tool, ("--yes", "--target-preallocation", mode))
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(args.count("--target-preallocation"), 1)
                    self.assertEqual(args[args.index("--target-preallocation") + 1], mode)
                    self.assertIn(mode + " (cli)", r.stderr)
            for selection, expected in (("\n", "falloc"), ("off\n", "off"), ("metadata\n", "metadata"), ("full\n", "full")):
                r, args, _ = self.wizard(tool, tty="1", selection=selection)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(args[args.index("--target-preallocation") + 1], expected)
                self.assertIn(expected + " (wizard)", r.stderr)

    def test_wizard_print_cancel_legacy_and_conflict(self):
        for tool in ("v2k", "n2k"):
            for legacy, saved in ((False, None), (True, None), (False, "metadata")):
                r, args, directory = self.wizard(tool, ("--print-command",), legacy=legacy, saved=saved)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertFalse(args)
                self.assertIn("--target-preallocation " + (saved or ("off" if legacy else "falloc")), r.stdout)
                self.assertNotIn("fixture-secret", r.stdout)
                self.assertIn("REDACTED", r.stdout)
                if not legacy and not saved:
                    self.assertFalse((directory / "work/manifest.json").exists())
            r, args, _ = self.wizard(tool, ("--yes", "--target-preallocation", "falloc"), legacy=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(args)
            r, args, directory = self.wizard(tool, tty="1", cancel=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse(args)
            self.assertFalse((directory / "work/manifest.json").exists())
            r, args, _ = self.wizard(tool)
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(args)

    def test_wizard_raw_cloud_and_rbd(self):
        for tool in ("v2k", "n2k"):
            for cloud in (False, True):
                r, args, _ = self.wizard(tool, ("--yes", "--target-preallocation", "metadata"), cloud=cloud)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(args[args.index("--target-preallocation") + 1], "metadata")
            r, args, _ = self.wizard(tool, ("--target-format", "raw"), tty="1", selection="\n")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn("metadata (metadata)", r.stderr)
            r, args, _ = self.wizard(tool, ("--yes", "--target-format", "raw", "--target-preallocation", "metadata"))
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(args)
            for storage in ("rbd", "block"):
                r, args, _ = self.wizard(tool, ("--yes", "--target-storage", storage, "--target-format", "raw"))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn("--target-preallocation", args)
                self.assertIn("not_applicable", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
