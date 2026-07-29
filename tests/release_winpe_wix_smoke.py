#!/usr/bin/env python3
"""Static smoke checks for release WinPE and Windows MSI build guards."""

from pathlib import Path
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"[FAIL] {message}", file=sys.stderr)
    raise SystemExit(1)


def read_utf8(relative_path: str) -> str:
    path = ROOT / relative_path
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        fail(f"{relative_path} is not valid UTF-8: {exc}")
    if "\ufffd" in text:
        fail(f"{relative_path} contains a Unicode replacement character")
    return text


product_path = ROOT / "windows/msi/Product.wxs"
read_utf8("windows/msi/Product.wxs")
try:
    ET.parse(product_path)
except ET.ParseError as exc:
    fail(f"windows/msi/Product.wxs is not valid XML: {exc}")

build_script = read_utf8("windows/msi/build-msi.ps1")
for required in (
    "if ($LASTEXITCODE -ne 0)",
    "Test-Path -LiteralPath $outMsi",
    "Remove-Item -LiteralPath $outMsi",
):
    if required not in build_script:
        fail(f"build-msi.ps1 is missing failure guard: {required}")

makefile = read_utf8("Makefile")
windows_target = makefile.split("\nwindows:\n", 1)[1].split("\n\n", 1)[0]
if "|| echo" in windows_target:
    fail("Makefile windows target still masks a missing MSI")
if "windows/msi/out/*.msi" not in windows_target:
    fail("Makefile windows target does not require an MSI output")

workflow = read_utf8(".github/workflows/build.yml")
for required in (
    "workflow_call:",
    "source_ref:",
    "use_prebuilt_winpe:",
    "winpe_artifact_name:",
    "build-winpe:",
    "uses: ./.github/workflows/build-winpe-core.yml",
    "artifact_name: ${{ inputs.winpe_artifact_name }}",
    "needs: [build-winpe]",
    "inputs.use_prebuilt_winpe || needs.build-winpe.result == 'success'",
    "Stage generated WinPE ISO into V2K RPM source",
    "Expected exactly one staged WinPE ISO",
    'EXPECTED_NAME="winpe-ablestack-v2k-${WINPE_SUFFIX}-amd64.iso"',
    "if-no-files-found: error",
    "No MSI artifacts found in the msi-package workflow artifact.",
    "Stage required WinPE ISO into release tree",
    "SHA256SUMS was not found beside the WinPE ISO.",
    "sha256sum -c SHA256SUMS",
    "Required WinPE artifact directory was not found",
    "RPM-installed WinPE ISO metadata/link/checksum validation failed.",
    "Expected exactly 12 GitHub Release assets",
):
    if required not in workflow:
        fail(f"build.yml is missing release guard: {required}")
if "workflow_run:" in workflow:
    fail("build.yml still uses the obsolete cross-run release trigger")
if "github.event.workflow_run" in workflow:
    fail("build.yml still depends on workflow_run event metadata")

release_job = workflow.split("\n  release:\n", 1)[1]
for dependency in (
    "build-rpm",
    "build-hangctl-rpm",
    "build-ftctl-rpm",
    "build-deb",
    "build-windows",
    "build-v2k-rpm",
    "build-n2k-rpm",
):
    result_guard = f"needs['{dependency}'].result == 'success'"
    if result_guard not in release_job:
        fail(f"release job is missing dependency result guard: {result_guard}")
if "always() &&" not in release_job:
    fail("release job does not bypass the skipped build-winpe ancestor")

winpe_workflow = read_utf8(".github/workflows/build-winpe-core.yml")
for required in (
    "source_ref:",
    "ref: ${{ inputs.source_ref != '' && inputs.source_ref || github.ref }}",
    "[System.IO.File]::WriteAllText(",
    '"$hash  $file`n"',
    "[System.Text.Encoding]::ASCII",
):
    if required not in winpe_workflow:
        fail(f"build-winpe-core.yml is missing portable checksum output: {required}")
if 'Out-File -Encoding ascii -Force $sum' in winpe_workflow:
    fail("build-winpe-core.yml still writes SHA256SUMS with a Windows newline")

tag_workflow = read_utf8(".github/workflows/build-winpe-release.yml")
for required in (
    "tags:",
    '- "v*"',
    "contents: write",
    "actions: read",
    "source_ref: ${{ github.sha }}",
    "iso_suffix: ${{ github.ref_name }}",
    "needs: [build]",
    "uses: ./.github/workflows/build.yml",
    "release_tag: ${{ github.ref_name }}",
    "publish_release: true",
    "use_prebuilt_winpe: true",
    "winpe_artifact_name: ${{ needs.build.outputs.artifact_name }}",
):
    if required not in tag_workflow:
        fail(f"build-winpe-release.yml is missing unified tag release wiring: {required}")
if "\n  attach:\n" in tag_workflow:
    fail("tag workflow still creates a partial WinPE-only GitHub Release")
if "softprops/action-gh-release" in tag_workflow:
    fail("tag workflow must delegate the single final publication to build.yml")
if 'iso_suffix: ""' in tag_workflow:
    fail("tag workflow still creates an unversioned WinPE ISO")
if 'WINPE_ISO_FILE="$(ls -1 "${WINPE_SRC_DIR}"/*.iso' in workflow:
    fail("Tools ISO installer still selects and copies a second WinPE payload")

v2k_spec = read_utf8("rpm/ablestack_v2k.spec")
for required in (
    "with_winpe=1 requires exactly one staged WinPE ISO",
    "winpe/SHA256SUMS",
    "current.json",
    'ln -s "winpe/${winpe_name}"',
    "%posttrans",
    "Installed WinPE ISO, metadata, checksum, and compatibility link are inconsistent.",
    "/usr/share/ablestack/v2k/winpe.iso",
):
    if required not in v2k_spec:
        fail(f"ablestack_v2k.spec is missing WinPE ownership guard: {required}")
if "find /usr/share/ablestack/v2k/winpe" in v2k_spec:
    fail("ablestack_v2k.spec still selects the first installed WinPE ISO dynamically")

print("[OK] release WinPE generation and MSI failure guards")
