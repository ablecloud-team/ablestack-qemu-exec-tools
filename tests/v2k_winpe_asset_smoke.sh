#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/v2k_winpe_asset_smoke.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/engine.sh"

install_root="${WORK_DIR}/install"
payload_root="${install_root}/winpe"
mkdir -p "${payload_root}"

versioned_iso="${payload_root}/winpe-ablestack-v2k-v0.9.4-amd64.iso"
printf '%s\n' "versioned WinPE payload v0.9.4" > "${versioned_iso}"
versioned_sha="$(sha256sum "${versioned_iso}" | awk '{print $1}')"
jq -nc \
  --arg filename "$(basename "${versioned_iso}")" \
  --arg sha256 "${versioned_sha}" \
  '{schema:1,filename:$filename,sha256:$sha256,architecture:"amd64",package_version:"0.9.4"}' \
  > "${payload_root}/current.json"
ln -s "winpe/winpe-ablestack-v2k-v0.9.3-amd64.iso" "${install_root}/winpe.iso"

export V2K_WINPE_INSTALL_ROOT="${install_root}"
resolved="$(v2k_resolve_winpe_iso "")"
[[ "${resolved}" == "${versioned_iso}" ]] || {
  echo "[ERR] RPM metadata did not override a stale compatibility link: ${resolved}" >&2
  exit 1
}

if v2k_resolve_winpe_iso "${WORK_DIR}/explicit-missing.iso" >/dev/null 2>&1; then
  echo "[ERR] invalid explicit WinPE path silently fell back to installed media" >&2
  exit 1
fi

override_iso="${WORK_DIR}/operator-override.iso"
printf '%s\n' "operator override" > "${override_iso}"
export V2K_WINPE_ISO="${override_iso}"
resolved="$(v2k_resolve_winpe_iso "")"
[[ "${resolved}" == "${override_iso}" ]] || {
  echo "[ERR] valid V2K_WINPE_ISO did not take precedence: ${resolved}" >&2
  exit 1
}
unset V2K_WINPE_ISO

jq '.sha256 = ("0" * 64)' "${payload_root}/current.json" \
  > "${payload_root}/current.json.tmp"
mv -f "${payload_root}/current.json.tmp" "${payload_root}/current.json"
if v2k_resolve_winpe_iso "" >/dev/null 2>&1; then
  echo "[ERR] metadata checksum mismatch silently fell back to another ISO" >&2
  exit 1
fi

rm -f "${payload_root}/current.json"
second_iso="${payload_root}/winpe-ablestack-v2k-v0.9.3-amd64.iso"
printf '%s\n' "legacy WinPE payload v0.9.3" > "${second_iso}"
if v2k_resolve_winpe_iso "" >/dev/null 2>&1; then
  echo "[ERR] multiple legacy WinPE payloads were resolved ambiguously" >&2
  exit 1
fi

rm -f "${second_iso}"
resolved="$(v2k_resolve_winpe_iso "")"
[[ "${resolved}" == "${versioned_iso}" ]] || {
  echo "[ERR] the only legacy WinPE payload was not resolved: ${resolved}" >&2
  exit 1
}

stable_sha="$(sha256sum "${versioned_iso}" | awk '{print $1}')"
v2k_verify_preflight_iso_unchanged \
  "WinPE" "${versioned_iso}" "${versioned_iso}" "${stable_sha}"
printf '%s\n' "changed after preflight" >> "${versioned_iso}"
if v2k_verify_preflight_iso_unchanged \
    "WinPE" "${versioned_iso}" "${versioned_iso}" "${stable_sha}" \
    >/dev/null 2>&1; then
  echo "[ERR] WinPE mutation after preflight was not detected" >&2
  exit 1
fi

manifest="${WORK_DIR}/manifest.json"
jq -nc \
  '{source:{vm:{guestFamily:"windowsGuest"}},target:{provider:"libvirt"}}' \
  > "${manifest}"
shutdown_marker="${WORK_DIR}/shutdown-called"
empty_install_root="${WORK_DIR}/empty-install"
mkdir -p "${empty_install_root}"
export V2K_MANIFEST="${manifest}"
export V2K_WINPE_INSTALL_ROOT="${empty_install_root}"

v2k_event() { return 0; }
v2k_load_runtime_flags_from_manifest() { return 0; }
v2k_restore_runtime_env_from_workdir() { return 0; }
v2k_maybe_force_cleanup() { return 0; }
v2k_vmware_vm_poweroff() {
  : > "${shutdown_marker}"
  return 0
}

set +e
(
  v2k_cmd_cutover --shutdown poweroff
) >/dev/null 2>&1
cutover_rc=$?
set -e
if [[ "${cutover_rc}" -ne 71 ]]; then
  echo "[ERR] missing WinPE preflight returned rc=${cutover_rc}, expected 71" >&2
  exit 1
fi
if [[ -e "${shutdown_marker}" ]]; then
  echo "[ERR] VMware shutdown ran before WinPE asset preflight succeeded" >&2
  exit 1
fi

echo "[OK] v2k versioned WinPE metadata, strict overrides, fallback, and preflight integrity"
