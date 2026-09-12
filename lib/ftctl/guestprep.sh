#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ---------------------------------------------------------------------

ftctl_guestprep_v2k_lib_dir() {
  local candidates=(
    "${FTCTL_LIB_BASE:-}/v2k"
    "${ROOT_DIR:-}/lib/v2k"
    "/usr/local/lib/ablestack-qemu-exec-tools/v2k"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "${candidate}" && -f "${candidate}/engine.sh" && -f "${candidate}/target_libvirt.sh" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

ftctl_guestprep_resolve_winpe_iso() {
  local v2k_dir="${1-}" requested="${FTCTL_DR_WINPE_ISO-}"
  [[ -n "${v2k_dir}" && -f "${v2k_dir}/engine.sh" ]] || return 1
  env V2K_LIB_DIR="${v2k_dir}" \
    V2K_WINPE_INSTALL_ROOT="${V2K_WINPE_INSTALL_ROOT:-/usr/share/ablestack/v2k}" \
    bash -c 'source "$1/engine.sh"; v2k_resolve_winpe_iso "$2"' \
      _ "${v2k_dir}" "${requested}"
}

ftctl_guestprep_write_manifest() {
  local session_path="${1-}" manifest_path="${2-}" test_domain_name="${3-}" run_path="${4-}"
  local tool output="" rc=0 error_code="" error_message=""
  tool="$(ftctl_guestprep_manifest_tool || true)"
  [[ -n "${tool}" ]] || return 47
  output="$(python3 "${tool}" build-test \
    --session "${session_path}" \
    --domain "${test_domain_name}" \
    --output "${manifest_path}" 2>&1)" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    error_code="$(jq -r 'select(type == "object") | .errorCode // empty' <<<"${output}" 2>/dev/null || true)"
    error_message="$(jq -r 'select(type == "object") | .message // empty' <<<"${output}" 2>/dev/null || true)"
    if [[ -n "${run_path}" && -f "${run_path}" ]]; then
      ftctl_dr_runtime_path_set "${run_path}" \
        "guest_manifest_error_code=${error_code}" \
        "guest_manifest_error_message=${error_message}" \
        "guest_manifest_exit_code=${rc}" \
        "updated_at=$(ftctl_now_iso8601)" || true
    fi
    [[ -z "${output}" ]] || printf '%s\n' "${output}" >&2
    return "${rc}"
  fi
  return 0
}

ftctl_guestprep_preflight_fail() {
  local run_path="${1-}" error_code="${2-DR_GUEST_PREP_RUNTIME_UNAVAILABLE}"
  local error_message="${3-Guest preparation preflight failed}" rc="${4-47}"
  if [[ -n "${run_path}" && -f "${run_path}" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "guest_preflight_state=ERROR" \
      "guest_preflight_error_code=${error_code}" \
      "guest_preflight_error_message=${error_message}" \
      "updated_at=$(ftctl_now_iso8601)" || true
  fi
  return "${rc}"
}

ftctl_guestprep_conversion_required() {
  local session_path="${1-}" direction source_provider target_provider
  [[ -n "${session_path}" && -r "${session_path}" ]] || return 0
  direction="$(jq -r '(.profile.direction // .profile.mapping.direction // "") | ascii_upcase' "${session_path}" 2>/dev/null || true)"
  source_provider="$(jq -r '(.profile.source.provider // "") | ascii_upcase' "${session_path}" 2>/dev/null || true)"
  target_provider="$(jq -r '(.profile.target.provider // "") | ascii_upcase' "${session_path}" 2>/dev/null || true)"
  if [[ "${direction}" == "KVM_TO_KVM" ]]; then
    return 1
  fi
  if [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "ABLESTACK" ]]; then
    return 1
  fi
  return 0
}

ftctl_guestprep_mark_native_compatibility() {
  local session_path="${1-}" run_path="${2-}" manifest="${3-}" family="${4-unknown}"
  local state_file
  state_file="$(mktemp -t ftctl.dr.guestprep-native.XXXXXX)"
  python3 - "${session_path}" "${state_file}" "${manifest}" "${family}" "$(ftctl_now_iso8601)" <<'PY'
import json, sys
session_path, state_path, manifest, family, now = sys.argv[1:6]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["guestPreparation"] = {
    "state": "SKIPPED",
    "reason": "NATIVE_COMPATIBILITY_PRESERVED",
    "family": family,
    "manifest": manifest,
    "completedAt": now,
}
session["state"] = "TEST_ARTIFACTS_READY"
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":")); fh.write("\n")
with open(state_path, "w", encoding="utf-8") as fh:
    fh.write("guest_prep_state=SKIPPED\n")
    fh.write("guest_prep_reason=NATIVE_COMPATIBILITY_PRESERVED\n")
    fh.write(f"guest_family={family}\n")
    fh.write(f"guestprep_manifest_path={manifest}\n")
PY
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=TEST_ARTIFACTS_READY" \
    "step=test-artifacts-ready" \
    "progress=100" \
    "guest_prep_state=SKIPPED" \
    "guest_prep_reason=NATIVE_COMPATIBILITY_PRESERVED" \
    "guest_family=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guest_family)" \
    "guestprep_manifest_path=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guestprep_manifest_path)" \
    "test_domain_name=" \
    "test_domain_state=" \
    "updated_at=$(ftctl_now_iso8601)"
  rm -f "${state_file}"
}

ftctl_guestprep_preflight_test_session() {
  local session_path="${1-}" run_path="${2-}"
  local tool profile_path inspection family guest_id firmware secure_boot v2k_dir
  local winpe_iso virtio_iso
  if [[ -z "${session_path}" || ! -r "${session_path}" ]]; then
    ftctl_guestprep_preflight_fail "${run_path}" "DR_GUEST_PREP_SESSION_MISSING" \
      "The selected test session is missing or unreadable" 47
    return $?
  fi
  tool="$(ftctl_guestprep_manifest_tool || true)"
  if [[ -z "${tool}" ]]; then
    ftctl_guestprep_preflight_fail "${run_path}" "DR_GUEST_PREP_MANIFEST_TOOL_MISSING" \
      "The guest preparation manifest tool is not installed" 47
    return $?
  fi
  profile_path="$(mktemp -t ftctl.dr.guestprep.profile.XXXXXX)"
  jq -c '.profile // {}' "${session_path}" > "${profile_path}" 2>/dev/null || {
    rm -f "${profile_path}"
    ftctl_guestprep_preflight_fail "${run_path}" "DR_GUEST_PREP_PROFILE_INVALID" \
      "The test session does not contain a valid guest preparation profile" 47
    return $?
  }
  inspection="$(python3 "${tool}" inspect --profile "${profile_path}" 2>/dev/null)" || {
    rm -f "${profile_path}"
    ftctl_guestprep_preflight_fail "${run_path}" "DR_GUEST_OS_UNRESOLVED" \
      "The source guest operating system could not be resolved" 48
    return $?
  }
  rm -f "${profile_path}"

  family="$(jq -r '.guestFamily // empty' <<< "${inspection}" 2>/dev/null || true)"
  guest_id="$(jq -r '.guestId // empty' <<< "${inspection}" 2>/dev/null || true)"
  firmware="$(jq -r '.firmware // empty' <<< "${inspection}" 2>/dev/null || true)"
  secure_boot="$(jq -r '.secureBoot // false' <<< "${inspection}" 2>/dev/null || true)"
  if [[ "${family}" != "linux" && "${family}" != "windows" ]]; then
    ftctl_guestprep_preflight_fail "${run_path}" "DR_GUEST_OS_UNRESOLVED" \
      "The source guest operating system could not be resolved" 48
    return $?
  fi
  if ftctl_guestprep_conversion_required "${session_path}"; then
    v2k_dir="$(ftctl_guestprep_v2k_lib_dir || true)"
    if [[ -z "${v2k_dir}" ]]; then
      ftctl_guestprep_preflight_fail "${run_path}" "DR_GUEST_PREP_V2K_RUNTIME_MISSING" \
        "The required v2k guest preparation runtime is not installed" 47
      return $?
    fi
  fi
  if ftctl_guestprep_conversion_required "${session_path}" && [[ "${family}" == "windows" ]]; then
    winpe_iso="$(ftctl_guestprep_resolve_winpe_iso "${v2k_dir}" 2>/dev/null || true)"
    virtio_iso="${FTCTL_DR_VIRTIO_ISO:-/usr/share/virtio-win/virtio-win.iso}"
    if [[ ! -r "${winpe_iso}" || ! -s "${winpe_iso}" ]]; then
      ftctl_guestprep_preflight_fail "${run_path}" "DR_GUEST_PREP_WINPE_ISO_MISSING" \
        "The Windows guest preparation WinPE ISO is missing or unreadable" 47
      return $?
    fi
    if [[ ! -r "${virtio_iso}" || ! -s "${virtio_iso}" ]]; then
      ftctl_guestprep_preflight_fail "${run_path}" "DR_GUEST_PREP_VIRTIO_ISO_MISSING" \
        "The Windows virtio driver ISO is missing or unreadable" 47
      return $?
    fi
  fi
  ftctl_dr_runtime_path_set "${run_path}" \
    "guest_preflight_state=READY" \
    "guest_preflight_error_code=" \
    "guest_preflight_error_message=" \
    "guest_family=${family}" \
    "guest_id=${guest_id}" \
    "guest_firmware=${firmware}" \
    "guest_secure_boot=${secure_boot}" \
    "updated_at=$(ftctl_now_iso8601)"
}

ftctl_guestprep_detect_family() {
  local manifest_path="${1-}" explicit family root_path storage_type mapped=""
  explicit="$(jq -r '.source.vm.guestFamily // .source.vm.guestId // ""' "${manifest_path}" 2>/dev/null || true)"
  case "${explicit,,}" in
    *windows*) printf 'windows\n'; return 0 ;;
    *linux*|*rhel*|*centos*|*rocky*|*ubuntu*|*debian*|*sles*) printf 'linux\n'; return 0 ;;
  esac

  root_path="$(jq -r '.disks[0].transfer.target_path // ""' "${manifest_path}" 2>/dev/null || true)"
  storage_type="$(jq -r '.target.storage.type // "file"' "${manifest_path}" 2>/dev/null || true)"
  if [[ "${storage_type}" == "rbd" && "${root_path}" == rbd:* ]]; then
    mapped="$(rbd map "${root_path#rbd:}" 2>/dev/null || true)"
    [[ -n "${mapped}" ]] && root_path="${mapped}"
  fi
  family=""
  if command -v virt-inspector >/dev/null 2>&1 && [[ -n "${root_path}" ]]; then
    family="$(virt-inspector -a "${root_path}" 2>/dev/null | python3 -c '
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.stdin).getroot()
    values = " ".join((node.text or "") for node in root.iter() if node.tag in {"type", "distro", "product_name"}).lower()
    print("windows" if "windows" in values else ("linux" if values else ""))
except Exception:
    print("")
' || true)"
  fi
  [[ -n "${mapped}" ]] && rbd unmap "${mapped}" >/dev/null 2>&1 || true
  [[ -n "${family}" ]] || family="unknown"
  printf '%s\n' "${family}"
}

ftctl_guestprep_manifest_tool() {
  local candidates=(
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guestprep_manifest.py"
    "${FTCTL_LIB_BASE:-}/ftctl/guestprep_manifest.py"
    "${ROOT_DIR:-}/lib/ftctl/guestprep_manifest.py"
    "/usr/local/lib/ablestack-qemu-exec-tools/ftctl/guestprep_manifest.py"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "${candidate}" && -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

ftctl_guestprep_validate_provider_objects() {
  local manifest_path="${1-}" count index storage_type locator format
  [[ -n "${manifest_path}" && -f "${manifest_path}" ]] || return 60
  count="$(jq -r '.disks | length' "${manifest_path}" 2>/dev/null || echo 0)"
  [[ "${count}" =~ ^[0-9]+$ && "${count}" -gt 0 ]] || return 62
  for ((index=0; index<count; index++)); do
    storage_type="$(jq -r ".disks[${index}].storage.type // .target.storage.type // empty" "${manifest_path}" 2>/dev/null || true)"
    locator="$(jq -r ".disks[${index}].storage.locator // .disks[${index}].transfer.target_path // empty" "${manifest_path}" 2>/dev/null || true)"
    format="$(jq -r ".disks[${index}].storage.format // .target.format // empty" "${manifest_path}" 2>/dev/null || true)"
    case "${storage_type}" in
      rbd)
        [[ "${locator}" == rbd:* && "${format}" == "raw" ]] || return 63
        command -v rbd >/dev/null 2>&1 || return 65
        rbd info "${locator#rbd:}" >/dev/null 2>&1 || return 64
        ;;
      file)
        [[ "${locator}" == /* && -f "${locator}" ]] || return 64
        if command -v qemu-img >/dev/null 2>&1; then
          qemu-img info "${locator}" >/dev/null 2>&1 || return 64
        fi
        ;;
      *) return 63 ;;
    esac
  done
}

ftctl_guestprep_release_manifest_mappings() {
  local manifest_path="${1-}" mapped temporary
  [[ -n "${manifest_path}" && -f "${manifest_path}" ]] || return 0
  while IFS= read -r mapped; do
    [[ -n "${mapped}" && "${mapped}" == /dev/rbd/* ]] || continue
    if [[ -b "${mapped}" ]]; then
      rbd unmap "${mapped}" >/dev/null 2>&1 || true
    fi
  done < <(jq -r '.runtime.rbd.mapped // {} | to_entries[]? | .value.dev_path // empty' "${manifest_path}" 2>/dev/null || true)
  temporary="${manifest_path}.sanitize.$$"
  if jq 'if .runtime?.rbd? then del(.runtime.rbd.mapped) else . end' "${manifest_path}" > "${temporary}" 2>/dev/null; then
    mv -f "${temporary}" "${manifest_path}"
  else
    rm -f "${temporary}" 2>/dev/null || true
  fi
}

ftctl_guestprep_prepare_artifacts() {
  local session_path="${1-}" run_path="${2-}"
  local artifacts_dir plan run artifact_name manifest v2k_dir family winpe_iso rc=0 state_file execution_mode
  artifacts_dir="$(jq -r '.testArtifacts.path // ""' "${session_path}" 2>/dev/null || true)"
  plan="$(jq -r '.planUuid // ""' "${session_path}" 2>/dev/null || true)"
  run="$(jq -r '.runUuid // ""' "${session_path}" 2>/dev/null || true)"
  [[ -n "${artifacts_dir}" ]] || return 46
  execution_mode="$(jq -r '.profile.policy.testExecutionMode // .request.testExecutionMode // "BOOT"' "${session_path}" 2>/dev/null || echo BOOT)"
  if [[ "${execution_mode}" == "METADATA_ONLY" ]]; then
    python3 - "${session_path}" "$(ftctl_now_iso8601)" <<'PY'
import json, sys
session_path, now = sys.argv[1:3]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["guestPreparation"] = {"state":"SKIPPED", "reason":"METADATA_ONLY", "completedAt":now}
session["state"] = "TEST_ARTIFACTS_READY"
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":")); fh.write("\n")
PY
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=TEST_ARTIFACTS_READY" \
      "step=test-artifacts-ready" \
      "progress=100" \
      "guest_prep_state=SKIPPED" \
      "test_domain_name=" \
      "test_domain_state=" \
      "updated_at=$(ftctl_now_iso8601)"
    return 0
  fi
  artifact_name="ftctl-dr-artifact-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}")"
  artifact_name="${artifact_name:0:62}"
  manifest="${artifacts_dir}/guestprep-manifest.json"
  ftctl_guestprep_write_manifest "${session_path}" "${manifest}" "${artifact_name}" "${run_path}" || return $?
  [[ "$(jq -r '.disks | length' "${manifest}" 2>/dev/null || echo 0)" -gt 0 ]] || return 46

  family="$(ftctl_guestprep_detect_family "${manifest}")"
  if ! ftctl_guestprep_conversion_required "${session_path}"; then
    ftctl_guestprep_mark_native_compatibility "${session_path}" "${run_path}" "${manifest}" "${family}"
    return $?
  fi
  v2k_dir="$(ftctl_guestprep_v2k_lib_dir || true)"
  [[ -n "${v2k_dir}" ]] || return 47
  # Keep diagnostics outside the artifact directory which successful rollback removes.
  (umask 077; : > "${run_path}.guestprep.log")
  case "${family}" in
    linux)
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 V2K_EVENTS_LOG="${run_path}.guestprep.log" \
        bash -c 'source "$1/engine.sh"; v2k_linux_bootstrap_initramfs "$2"' _ "${v2k_dir}" "${manifest}" || rc=$?
      ;;
    windows)
      winpe_iso="$(ftctl_guestprep_resolve_winpe_iso "${v2k_dir}")" || return 47
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 V2K_EVENTS_LOG="${run_path}.guestprep.log" \
        bash -c 'source "$1/engine.sh"; v2k_cloud_windows_winpe_bootstrap "$2" "${FTCTL_DR_VIRTIO_ISO:-/usr/share/virtio-win/virtio-win.iso}" "${FTCTL_DR_WINPE_TIMEOUT:-900}"' \
          _ "${v2k_dir}" "${winpe_iso}" || rc=$?
      ;;
    *) return 48 ;;
  esac
  ftctl_dr_runtime_path_set "${run_path}" "guest_prep_exit_code=${rc}"
  [[ "${rc}" == "0" ]] || return 49

  state_file="$(mktemp -t ftctl.dr.guestprep-artifacts.XXXXXX)"
  python3 - "${session_path}" "${state_file}" "${manifest}" "${family}" "$(ftctl_now_iso8601)" <<'PY'
import json, sys
session_path, state_path, manifest, family, now = sys.argv[1:6]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["guestPreparation"] = {"state":"READY", "family":family, "manifest":manifest, "completedAt":now}
session["state"] = "TEST_ARTIFACTS_READY"
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":")); fh.write("\n")
with open(state_path, "w", encoding="utf-8") as fh:
    fh.write("guest_prep_state=READY\n")
    fh.write(f"guest_family={family}\n")
    fh.write(f"guestprep_manifest_path={manifest}\n")
PY
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=TEST_ARTIFACTS_READY" \
    "step=test-artifacts-ready" \
    "progress=100" \
    "guest_prep_state=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guest_prep_state)" \
    "guest_family=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guest_family)" \
    "guestprep_manifest_path=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guestprep_manifest_path)" \
    "test_domain_name=" \
    "test_domain_state=" \
    "updated_at=$(ftctl_now_iso8601)"
  rm -f "${state_file}"
}

ftctl_guestprep_prepare_and_start() {
  local session_path="${1-}" run_path="${2-}"
  local artifacts_dir plan run domain manifest v2k_dir family winpe_iso validation timeout rc=0 state_file execution_mode
  execution_mode="$(jq -r '.profile.policy.testExecutionMode // .request.testExecutionMode // "BOOT"' "${session_path}" 2>/dev/null || echo BOOT)"
  if [[ "${execution_mode}" == "METADATA_ONLY" ]]; then
    return 0
  fi
  artifacts_dir="$(jq -r '.testArtifacts.path // ""' "${session_path}" 2>/dev/null || true)"
  plan="$(jq -r '.planUuid // ""' "${session_path}" 2>/dev/null || true)"
  run="$(jq -r '.runUuid // ""' "${session_path}" 2>/dev/null || true)"
  [[ -n "${artifacts_dir}" ]] || return 46
  domain="ftctl-dr-test-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}")"
  domain="${domain:0:62}"
  manifest="${artifacts_dir}/guestprep-manifest.json"
  ftctl_guestprep_write_manifest "${session_path}" "${manifest}" "${domain}" "${run_path}" || return $?
  [[ "$(jq -r '.disks | length' "${manifest}" 2>/dev/null || echo 0)" -gt 0 ]] || return 46

  v2k_dir="$(ftctl_guestprep_v2k_lib_dir || true)"
  [[ -n "${v2k_dir}" ]] || return 47
  family="$(ftctl_guestprep_detect_family "${manifest}")"
  if ftctl_guestprep_conversion_required "${session_path}"; then
    case "${family}" in
      linux)
        env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
          bash -c 'source "$1/engine.sh"; v2k_linux_bootstrap_initramfs "$2"' _ "${v2k_dir}" "${manifest}" || rc=$?
        ;;
      windows)
        winpe_iso="$(ftctl_guestprep_resolve_winpe_iso "${v2k_dir}")" || return 47
        env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
          bash -c 'source "$1/engine.sh"; v2k_cloud_windows_winpe_bootstrap "$2" "${FTCTL_DR_VIRTIO_ISO:-/usr/share/virtio-win/virtio-win.iso}" "${FTCTL_DR_WINPE_TIMEOUT:-900}"' \
            _ "${v2k_dir}" "${winpe_iso}" || rc=$?
        ;;
      *) return 48 ;;
    esac
    [[ "${rc}" == "0" ]] || return 49
  fi

  env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" \
    bash -c 'source "$1/engine.sh"; v2k_cutover_prepare_rbd_mappings "$2"; xml="$(v2k_target_generate_libvirt_xml "$2")"; v2k_target_undefine_libvirt "$(jq -r .target.libvirt.name "$2")"; v2k_target_define_libvirt "$xml"; v2k_target_start_vm "$2"' \
    _ "${v2k_dir}" "${manifest}" || return 50

  validation="$(jq -r '.profile.policy.testBootValidationMode // .request.testBootValidationMode // "POWER_STATE_ONLY"' "${session_path}" 2>/dev/null || echo POWER_STATE_ONLY)"
  timeout="$(jq -r '.profile.policy.testBootTimeoutSeconds // .request.testBootTimeoutSeconds // 180' "${session_path}" 2>/dev/null || echo 180)"
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=180
  local deadline=$((SECONDS + timeout)) domain_state=""
  while (( SECONDS < deadline )); do
    domain_state="$(virsh domstate "${domain}" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]' || true)"
    if [[ "${domain_state}" == "running" ]]; then
      if [[ "${validation}" != "QGA_REQUIRED" ]] || virsh qemu-agent-command "${domain}" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
        break
      fi
    fi
    sleep 2
  done
  [[ "${domain_state}" == "running" ]] || return 51
  if [[ "${validation}" == "QGA_REQUIRED" ]]; then
    virsh qemu-agent-command "${domain}" '{"execute":"guest-ping"}' >/dev/null 2>&1 || return 52
  fi

  state_file="$(mktemp -t ftctl.dr.guestprep.XXXXXX)"
  python3 - "${session_path}" "${state_file}" "${manifest}" "${domain}" "${family}" "${validation}" "$(ftctl_now_iso8601)" <<'PY'
import json, sys
session_path, state_path, manifest, domain, family, validation, now = sys.argv[1:8]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["guestPreparation"] = {"state":"READY", "family":family, "manifest":manifest, "completedAt":now}
session["testDomain"] = {"state":"RUNNING", "name":domain, "validationMode":validation, "validatedAt":now}
session["state"] = "TEST_RUNNING"
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":")); fh.write("\n")
with open(state_path, "w", encoding="utf-8") as fh:
    fh.write("guest_prep_state=READY\n")
    fh.write(f"guest_family={family}\n")
    fh.write(f"guestprep_manifest_path={manifest}\n")
    fh.write(f"test_domain_name={domain}\n")
    fh.write("test_domain_state=RUNNING\n")
    fh.write(f"test_boot_validation_mode={validation}\n")
PY
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=TEST_RUNNING" \
    "step=test-boot-validated" \
    "progress=100" \
    "guest_prep_state=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guest_prep_state)" \
    "guest_family=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guest_family)" \
    "guestprep_manifest_path=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guestprep_manifest_path)" \
    "test_domain_name=$(ftctl_dr_runtime_state_get_from_path "${state_file}" test_domain_name)" \
    "test_domain_state=RUNNING" \
    "test_boot_validation_mode=$(ftctl_dr_runtime_state_get_from_path "${state_file}" test_boot_validation_mode)" \
    "updated_at=$(ftctl_now_iso8601)"
  rm -f "${state_file}"
}

ftctl_guestprep_prepare_cutover_target() {
  local profile_file="${1-}" run_path="${2-}" workdir="${3-}" status_path="${4-}" restore_point="${5-}"
  local manifest v2k_dir family winpe_iso rc=0 plan run disk_map restore_points tool build_result validate_result manifest_sha256
  mkdir -p "${workdir}"
  manifest="${workdir}/cutover-manifest.json"
  plan="$(ftctl_dr_runtime_state_get_from_path "${run_path}" plan)"
  run="$(ftctl_dr_runtime_state_get_from_path "${run_path}" run)"
  [[ -n "${plan}" ]] || plan="$(jq -r '.planUuid // empty' "${profile_file}" 2>/dev/null || true)"
  [[ -n "${run}" ]] || run="$(jq -r '.runUuid // empty' "${profile_file}" 2>/dev/null || true)"
  disk_map="$(ftctl_dr_ablestack_disk_map_path "${plan}")"
  restore_points="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  tool="$(ftctl_guestprep_manifest_tool || true)"
  [[ -n "${tool}" ]] || return 65
  if build_result="$(python3 "${tool}" build \
    --profile "${profile_file}" \
    --disk-map "${disk_map}" \
    --restore-points "${restore_points}" \
    --status "${status_path}" \
    --selector "${restore_point}" \
    --plan "${plan}" \
    --run "${run}" \
    --output "${manifest}" 2>&1)"; then
    :
  else
    rc=$?
    ftctl_dr_runtime_path_set "${run_path}" \
      "error_message=$(jq -r '.message // "cutover manifest build failed"' <<< "${build_result}" 2>/dev/null || echo 'cutover manifest build failed')" || true
    return "${rc}"
  fi
  if validate_result="$(python3 "${tool}" validate --manifest "${manifest}" 2>&1)"; then
    :
  else
    rc=$?
    ftctl_dr_runtime_path_set "${run_path}" \
      "error_message=$(jq -r '.message // "cutover manifest validation failed"' <<< "${validate_result}" 2>/dev/null || echo 'cutover manifest validation failed')" || true
    return "${rc}"
  fi
  if ftctl_guestprep_validate_provider_objects "${manifest}"; then
    :
  else
    rc=$?
    case "${rc}" in
      62) validate_result="target disk map contains no usable disks" ;;
      63) validate_result="target disk provider locator is invalid" ;;
      64) validate_result="target disk provider object is absent or unreadable" ;;
      65) validate_result="target disk provider tool is unavailable" ;;
      *) validate_result="target disk provider validation failed" ;;
    esac
    ftctl_dr_runtime_path_set "${run_path}" "error_message=${validate_result}" || true
    return "${rc}"
  fi

  ftctl_dr_runtime_path_set "${run_path}" \
    "manifest_schema_version=$(jq -r '.schemaVersion // empty' "${manifest}")" \
    "manifest_sha256=$(jq -r '.sha256 // empty' <<< "${build_result}")" \
    "guestprep_checkpoint_sequence=$(jq -r '.checkpointSequence // 0' <<< "${build_result}")" \
    "target_disk_count=$(jq -r '.diskCount // 0' <<< "${build_result}")" || true
  v2k_dir="$(ftctl_guestprep_v2k_lib_dir || true)"
  [[ -n "${v2k_dir}" ]] || return 65
  family="$(ftctl_guestprep_detect_family "${manifest}")"
  case "${family}" in
    linux)
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${workdir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
        bash -c 'source "$1/engine.sh"; v2k_linux_bootstrap_initramfs "$2"' _ "${v2k_dir}" "${manifest}" || rc=$?
      ;;
    windows)
      winpe_iso="$(ftctl_guestprep_resolve_winpe_iso "${v2k_dir}")" || return 47
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${workdir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
        bash -c 'source "$1/engine.sh"; v2k_cloud_windows_winpe_bootstrap "$2" "${FTCTL_DR_VIRTIO_ISO:-/usr/share/virtio-win/virtio-win.iso}" "${FTCTL_DR_WINPE_TIMEOUT:-900}"' \
          _ "${v2k_dir}" "${winpe_iso}" || rc=$?
      ;;
    *) return 61 ;;
  esac
  ftctl_guestprep_release_manifest_mappings "${manifest}"
  [[ "${rc}" == "0" ]] || return 49
  manifest_sha256="$(sha256sum "${manifest}" 2>/dev/null | awk '{print $1}')"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=CUTOVER_READY" \
    "step=guest-preparation-completed" \
    "progress=90" \
    "guest_prep_state=READY" \
    "guest_family=${family}" \
    "guestprep_manifest_path=${manifest}" \
    "manifest_sha256=${manifest_sha256}" \
    "target_promotion_state=CUTOVER_READY" \
    "target_power_state=POWERED_OFF" \
    "updated_at=$(ftctl_now_iso8601)"
}
