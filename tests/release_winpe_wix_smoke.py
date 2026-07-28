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
    "build-winpe:",
    "uses: ./.github/workflows/build-winpe-core.yml",
    'artifact_name: "winpe-iso-validation"',
    "needs: [build-winpe]",
    "Stage generated WinPE ISO into V2K RPM source",
    "if-no-files-found: error",
    "No MSI artifacts found in the msi-package workflow artifact.",
    "Stage required WinPE ISO into release tree",
    "Required WinPE ISO was not found in release assets or workflow artifacts.",
):
    if required not in workflow:
        fail(f"build.yml is missing release guard: {required}")

winpe_workflow = read_utf8(".github/workflows/build-winpe-core.yml")
for required in (
    "[System.IO.File]::WriteAllText(",
    '"$hash  $file`n"',
    "[System.Text.Encoding]::ASCII",
):
    if required not in winpe_workflow:
        fail(f"build-winpe-core.yml is missing portable checksum output: {required}")
if 'Out-File -Encoding ascii -Force $sum' in winpe_workflow:
    fail("build-winpe-core.yml still writes SHA256SUMS with a Windows newline")

print("[OK] release WinPE generation and MSI failure guards")
