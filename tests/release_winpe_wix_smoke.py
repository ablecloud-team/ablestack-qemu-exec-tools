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
    "if-no-files-found: error",
    "No MSI artifacts found in the msi-package workflow artifact.",
    "Stage required WinPE ISO into release tree",
    "SHA256SUMS was not found beside the WinPE ISO.",
    "sha256sum -c SHA256SUMS",
    "Required WinPE ISO was not found in workflow artifacts.",
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
    "source_ref: ${{ github.sha }}",
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

print("[OK] release WinPE generation and MSI failure guards")
