#!/usr/bin/env bash
# ---------------------------------------------------------------------
# End-to-end smoke test for installer-managed v2k compatibility profiles.
# This test uses sample profile wrappers plus canned govc JSON fixtures.
# ---------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="${ROOT_DIR}/tests/fixtures/v2k/compat"
BUILD_DIR="${TMPDIR:-/tmp}/v2k_compat_installer_runtime_smoke"
COMPAT_ROOT="${BUILD_DIR}/compat-root"
WORK_ROOT="${BUILD_DIR}/work"
DST_ROOT="${BUILD_DIR}/dst"
LIB_MIRROR_ROOT="${ROOT_DIR}/lib/ablestack-qemu-exec-tools"
LIB_MIRROR_V2K="${LIB_MIRROR_ROOT}/v2k"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
  local cmds=(bash jq python3)
  local c
  for c in "${cmds[@]}"; do
    has_cmd "${c}" || {
      echo "[ERR] Missing command: ${c}" >&2
      exit 2
    }
  done
}

prepare_repo_runtime_layout() {
  mkdir -p "${LIB_MIRROR_ROOT}"
  rm -rf "${LIB_MIRROR_V2K}"
  if ! ln -s ../v2k "${LIB_MIRROR_V2K}" 2>/dev/null; then
    cp -a "${ROOT_DIR}/lib/v2k" "${LIB_MIRROR_V2K}"
  fi
}

cleanup_repo_runtime_layout() {
  if [[ -L "${LIB_MIRROR_V2K}" ]]; then
    rm -f "${LIB_MIRROR_V2K}"
  elif [[ -d "${LIB_MIRROR_V2K}" ]]; then
    rm -rf "${LIB_MIRROR_V2K}"
  fi
  rmdir "${LIB_MIRROR_ROOT}" 2>/dev/null || true
}

assert_file_contains() {
  local path="$1" pattern="$2"
  grep -F "${pattern}" "${path}" >/dev/null 2>&1 || {
    echo "[ERR] Missing pattern in ${path}: ${pattern}" >&2
    exit 1
  }
}

assert_manifest_values() {
  local manifest="$1" expected_profile="$2"
  jq -e --arg profile "${expected_profile}" --arg root "${COMPAT_ROOT}" '
    .source.compat.selected_profile == $profile
    and .source.compat.requested_profile == "auto"
    and (.source.compat.tools.govc_bin == ($root + "/" + $profile + "/bin/govc"))
    and (.source.compat.tools.python_bin == ($root + "/" + $profile + "/venv/bin/python3"))
    and (.source.compat.tools.vddk_libdir == ($root + "/" + $profile + "/vddk"))
  ' "${manifest}" >/dev/null
}

run_case() {
  local version="$1" expected_profile="$2" compat_mode="${3:-explicit}"
  local safe_version="${version//./_}"
  local workdir="${WORK_ROOT}/${safe_version}"
  local dst="${DST_ROOT}/${safe_version}"
  local cred="${workdir}/govc.env"
  local call_log="${workdir}/govc.calls.log"
  local manifest="${workdir}/manifest.json"
  local -a init_args=(
    --workdir "${workdir}"
    init
    --vm "demo-vm"
    --vcenter "vc.example.local"
    --dst "${dst}"
    --cred-file "${cred}"
  )

  rm -rf "${workdir}" "${dst}"
  mkdir -p "${workdir}" "${dst}"

  cat > "${cred}" <<EOF
GOVC_URL=https://vc.example.local/sdk
GOVC_USERNAME=administrator@vsphere.local
GOVC_PASSWORD=dummy-password
GOVC_INSECURE=1
EOF

  export V2K_COMPAT_ROOT="${COMPAT_ROOT}"
  export V2K_COMPAT_TEST_ABOUT_VERSION="${version}"
  export V2K_COMPAT_TEST_VM_INFO_JSON_FILE="${FIXTURE_DIR}/vm.info.json"
  export V2K_COMPAT_TEST_DEVICE_INFO_JSON_FILE="${FIXTURE_DIR}/device.info.json"
  export V2K_COMPAT_TEST_HOST_INFO_JSON_FILE="${FIXTURE_DIR}/host.info.json"
  export V2K_COMPAT_TEST_CALL_LOG="${call_log}"
  export V2K_VDDK_THUMBPRINT="AA:BB:CC:DD"
  unset V2K_COMPAT_SELECTED_PROFILE V2K_GOVC_BIN V2K_PYTHON_BIN VDDK_LIBDIR V2K_COMPAT_DETECTED_VCENTER_VERSION

  if [[ "${compat_mode}" == "explicit" ]]; then
    init_args+=( --compat-profile auto )
  fi

  bash "${ROOT_DIR}/bin/ablestack_v2k.sh" "${init_args[@]}" >/dev/null

  [[ -f "${manifest}" ]] || {
    echo "[ERR] Manifest not created: ${manifest}" >&2
    exit 1
  }
  [[ -f "${call_log}" ]] || {
    echo "[ERR] govc call log not created: ${call_log}" >&2
    exit 1
  }

  assert_manifest_values "${manifest}" "${expected_profile}" || {
    echo "[ERR] Manifest compat metadata mismatch for version=${version}" >&2
    jq '.source.compat' "${manifest}" >&2
    exit 1
  }

  assert_file_contains "${call_log}" "${COMPAT_ROOT}/${expected_profile}/bin/govc"
  assert_file_contains "${call_log}" "about -json"
  assert_file_contains "${call_log}" "vm.info -json demo-vm"
  assert_file_contains "${call_log}" "device.info -json -vm demo-vm"
  assert_file_contains "${call_log}" "host.info -json -host host-11"

  echo "[OK] version=${version} profile=${expected_profile} compat_mode=${compat_mode}"
}

main() {
  require_cmds
  trap cleanup_repo_runtime_layout EXIT
  prepare_repo_runtime_layout

  rm -rf "${BUILD_DIR}"
  mkdir -p "${COMPAT_ROOT}" "${WORK_ROOT}" "${DST_ROOT}"

  bash "${ROOT_DIR}/bin/v2k_test_install.sh" \
    --skip-install \
    --install-sample-profiles \
    --install-profile all \
    --compat-root "${COMPAT_ROOT}" \
    --no-profiled >/dev/null

  run_case "6.0.0" "vsphere60"
  run_case "6.7.0" "vsphere67"
  run_case "8.0.1" "vsphere80"
  run_case "8.0.1" "vsphere80" "implicit"

  echo "[OK] installer-runtime smoke test passed"
}

main "$@"
