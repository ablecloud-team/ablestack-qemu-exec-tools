#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/v2k_cutover_integrity_smoke"

cleanup() {
  rm -rf "${WORK_DIR}"
}

for cmd in bash jq mount; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: ${cmd}" >&2
    exit 2
  }
done

trap cleanup EXIT
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/mnt"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/engine.sh"

v2k_event() {
  return 0
}
export V2K_JSON_OUT=1

captured_output=""
captured_rc=0
v2k_linux_bootstrap_run_event "test_failure" captured_output captured_rc -- \
  bash -c 'printf "xfs metadata error" >&2; exit 23'
[[ "${captured_rc}" -eq 23 ]] || {
  echo "[ERR] bootstrap command rc was masked: ${captured_rc}" >&2
  exit 1
}
[[ "${captured_output}" == *"xfs metadata error"* ]] || {
  echo "[ERR] bootstrap command stderr was lost: ${captured_output}" >&2
  exit 1
}

nbd_command_log="${WORK_DIR}/qemu-nbd.args"
mock_nbd_size=107374182400
# shellcheck disable=SC2317
qemu-nbd() {
  printf '%s\n' "$*" >> "${nbd_command_log}"
}
# shellcheck disable=SC2317
blockdev() {
  [[ "${1:-}" == "--getsize64" ]] || return 2
  printf '%s\n' "${mock_nbd_size}"
}

v2k_linux_bootstrap_connect_nbd "/dev/rbd3" "raw" "/dev/nbd8"
grep -Fx -- \
  "--connect=/dev/nbd8 --format=raw --cache=none /dev/rbd3" \
  "${nbd_command_log}" >/dev/null || {
    echo "[ERR] raw bootstrap did not pass the explicit qemu-nbd format" >&2
    cat "${nbd_command_log}" >&2
    exit 1
  }

v2k_linux_bootstrap_connect_nbd "${WORK_DIR}/root.qcow2" "qcow2" "/dev/nbd9"
grep -Fx -- \
  "--connect=/dev/nbd9 --format=qcow2 --cache=none ${WORK_DIR}/root.qcow2" \
  "${nbd_command_log}" >/dev/null || {
    echo "[ERR] qcow2 bootstrap did not pass the explicit qemu-nbd format" >&2
    cat "${nbd_command_log}" >&2
    exit 1
  }

if v2k_linux_bootstrap_connect_nbd "/dev/rbd3" "auto" "/dev/nbd10"; then
  echo "[ERR] unsupported bootstrap image format was accepted" >&2
  exit 1
fi

unset -f qemu-nbd blockdev

format_manifest="${WORK_DIR}/format-manifest.json"
cat > "${format_manifest}" <<'JSON'
{
  "target": {
    "format": "raw",
    "storage": {"type": "rbd"}
  }
}
JSON

bootstrap_call=""
v2k_require_linux_bootstrap_deps() {
  return 0
}
v2k_linux_bootstrap_prepare_root_input() {
  printf -v "$2" '%s' "/dev/rbd3"
  printf -v "$3" '%s' ""
}
v2k_linux_bootstrap_one() {
  bootstrap_call="$1|$2"
}

v2k_linux_bootstrap_initramfs "${format_manifest}"
[[ "${bootstrap_call}" == "/dev/rbd3|raw" ]] || {
  echo "[ERR] manifest target format was not propagated to Linux bootstrap: ${bootstrap_call}" >&2
  exit 1
}

unset -f \
  v2k_require_linux_bootstrap_deps \
  v2k_linux_bootstrap_prepare_root_input \
  v2k_linux_bootstrap_one

set +e
v2k_linux_bootstrap_mount_robust \
  "/dev/v2k-device-does-not-exist" "${WORK_DIR}/mnt" "ro"
mount_rc=$?
set -e
[[ "${mount_rc}" -ne 0 ]] || {
  echo "[ERR] failed mount was reported as success" >&2
  exit 1
}

manifest="${WORK_DIR}/manifest.json"
cat > "${manifest}" <<'JSON'
{
  "source": {
    "vm": {
      "cpu": 4,
      "memory_mb": 8192,
      "firmware": "bios",
      "secure_boot": false
    }
  },
  "target": {
    "cloud": {
      "cpu_speed": "1000"
    }
  },
  "runtime": {},
  "disks": [
    {
      "size_bytes": 107374182400,
      "controller": {"type": "VirtualLsiLogicController"},
      "cbt": {
        "enabled": true,
        "base_change_id": "*",
        "last_change_id": "change-1"
      }
    }
  ]
}
JSON

v2k_select_bootstrap_fallback \
  "${manifest}" "linux_bootstrap" 80 "test bootstrap failure" "sata"

jq -e '
  .runtime.bootstrap_fallback.enabled == true
  and .runtime.bootstrap_fallback.bus == "sata"
  and (.bootstrap_fallback | not)
' "${manifest}" >/dev/null || {
  echo "[ERR] SATA fallback was not persisted at the canonical runtime path" >&2
  cat "${manifest}" >&2
  exit 1
}

deploy_params="$(v2k_cloud_target_source_deploy_params_json "${manifest}")"
jq -e '."details[0].rootDiskController" == "sata"' <<<"${deploy_params}" >/dev/null || {
  echo "[ERR] Cloud deploy properties did not consume SATA fallback" >&2
  printf '%s\n' "${deploy_params}" >&2
  exit 1
}

complete_coverage='{
  "coverage": {
    "mode": "delta",
    "complete": true,
    "start_offset": 0,
    "end_offset": 107374182400,
    "disk_capacity": 107374182400,
    "pages": 2
  },
  "areas": []
}'
incomplete_coverage='{
  "coverage": {
    "mode": "delta",
    "complete": false,
    "start_offset": 0,
    "end_offset": 53687091200,
    "disk_capacity": 107374182400,
    "pages": 1
  },
  "areas": []
}'

v2k_validate_cbt_coverage "${complete_coverage}" 107374182400 || {
  echo "[ERR] complete CBT coverage was rejected" >&2
  exit 1
}
if v2k_validate_cbt_coverage "${incomplete_coverage}" 107374182400; then
  echo "[ERR] incomplete CBT coverage was accepted" >&2
  exit 1
fi

coverage_record='{
  "mode": "delta",
  "complete": true,
  "start_offset": 0,
  "end_offset": 107374182400,
  "disk_capacity": 107374182400,
  "pages": 2,
  "phase": "final",
  "new_change_id": "change-2"
}'
v2k_manifest_advance_cbt_change_ids \
  "${manifest}" 0 "change-1" "change-2" "${coverage_record}"

jq -e '
  .disks[0].cbt.base_change_id == "change-1"
  and .disks[0].cbt.last_change_id == "change-2"
  and .disks[0].cbt.last_coverage.complete == true
  and .disks[0].cbt.last_coverage.new_change_id == .disks[0].cbt.last_change_id
' "${manifest}" >/dev/null || {
  echo "[ERR] changeId and coverage were not committed together" >&2
  cat "${manifest}" >&2
  exit 1
}

echo "[OK] v2k cutover error propagation, CBT gate, and SATA fallback integrity"
