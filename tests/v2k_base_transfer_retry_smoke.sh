#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/v2k-base-transfer-retry.XXXXXX")"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

for cmd in bash jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: ${cmd}" >&2
    exit 2
  }
done

mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/logs"
for cmd in rbd qemu-img nbdcopy nbdkit; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK_DIR}/bin/${cmd}"
  chmod 755 "${WORK_DIR}/bin/${cmd}"
done
export PATH="${WORK_DIR}/bin:${PATH}"

export V2K_ROOT_DIR="${ROOT_DIR}"
export V2K_LIB_DIR="${ROOT_DIR}/lib/v2k"
export V2K_WORKDIR="${WORK_DIR}"
export V2K_RUN_ID="retry smoke/01"
export V2K_JSON_OUT=1
export V2K_DRY_RUN=0
export V2K_BASE_NFC_RETRIES=2
export V2K_BASE_RETRY_DELAY_SECONDS=0
export V2K_RBD_SPARSE=0
export VDDK_LIBDIR="${WORK_DIR}/vddk"
export VDDK_USER="smoke-user"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/transfer_base.sh"

event_log="${WORK_DIR}/events.log"
operation_log="${WORK_DIR}/operations.log"
run_string_log="${WORK_DIR}/run-strings.log"
runner_mode="retry_then_success"
runner_attempts=0
canonical_exists=0

v2k_event() {
  printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${5:-{}}" >> "${event_log}"
}
v2k_compat_vddk_child_env_prefix() {
  printf '%s\n' "env -u LD_LIBRARY_PATH"
}
v2k_compat_nbdkit_bin() {
  printf '%s\n' "${WORK_DIR}/bin/nbdkit"
}
v2k_compat_nbdkit_vddk_plugin() {
  printf '%s\n' "vddk"
}
v2k_compat_vddk_ld_library_path() {
  printf '%s\n' "${VDDK_LIBDIR}"
}
v2k_compat_vddk_config_file() {
  printf '%s\n' "${WORK_DIR}/vddk.conf"
}
v2k_rbd_exists() {
  local uri="$1"
  [[ "${uri}" == "rbd:pool/canonical" && "${canonical_exists}" -eq 1 ]]
}
v2k_rbd_ensure_image() {
  printf 'prepare|%s|%s\n' "$1" "$2" >> "${operation_log}"
}
v2k_transfer_base_rbd_remove_staging() {
  printf 'remove|%s\n' "$1" >> "${operation_log}"
}
v2k_transfer_base_rbd_publish() {
  printf 'publish|%s|%s\n' "$1" "$2" >> "${operation_log}"
  return 0
}
v2k_transfer_base_run_vddk() {
  local attempt_log="$1"
  local run_str="$2"
  runner_attempts=$((runner_attempts + 1))
  printf '%s\n' "${run_str}" >> "${run_string_log}"
  case "${runner_mode}" in
    retry_then_success)
      if [[ "${runner_attempts}" -eq 1 ]]; then
        printf '%s\n' \
          'NFC_NETWORK_ERROR: NfcNetTcpRead: Connection reset by peer' \
          >> "${attempt_log}"
        return 9
      fi
      printf '%s\n' 'transfer complete' >> "${attempt_log}"
      return 0
      ;;
    non_retryable)
      printf '%s\n' 'VDDK authentication failed' >> "${attempt_log}"
      return 8
      ;;
    *)
      echo "[ERR] unexpected runner mode: ${runner_mode}" >&2
      return 99
      ;;
  esac
}
sleep() {
  printf 'sleep|%s\n' "$1" >> "${operation_log}"
}

write_manifest() {
  local manifest="$1"
  jq -n '{
    run: {run_id: "retry smoke/01"},
    target: {
      format: "raw",
      storage: {type: "rbd"}
    },
    runtime: {
      sync_issues: [],
      last_error: {code: 0, reason: "", details: {}, ts: ""}
    },
    disks: [{
      disk_id: "scsi0:0",
      vmdk: {path: "[datastore1] vm/disk.vmdk"},
      size_bytes: 107374182400,
      transfer: {
        target_path: "rbd:pool/canonical",
        base_done: false,
        last_error: {code: 0, reason: "", details: {}, ts: ""}
      }
    }]
  }' > "${manifest}"
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -F -- "${needle}" "${file}" >/dev/null || {
    echo "[ERR] expected '${needle}' in ${file}" >&2
    cat "${file}" >&2
    exit 1
  }
}

manifest="${WORK_DIR}/manifest.json"
write_manifest "${manifest}"
: > "${event_log}"
: > "${operation_log}"
: > "${run_string_log}"

v2k_transfer_base_one \
  "${manifest}" 0 "vcenter.example" "AA:BB" "vm-42" "snapshot-7" \
  "${WORK_DIR}/password"

[[ "$(wc -l < "${run_string_log}")" -eq 2 ]] || {
  echo "[ERR] transient NFC failure was not retried exactly once" >&2
  cat "${run_string_log}" >&2
  exit 1
}
[[ "$(jq -r '.disks[0].transfer.base_done' "${manifest}")" == "true" ]] || {
  echo "[ERR] successful staged transfer did not mark base_done" >&2
  exit 1
}
[[ "$(grep -c '^publish|' "${operation_log}")" -eq 1 ]] || {
  echo "[ERR] staging image was not published exactly once" >&2
  cat "${operation_log}" >&2
  exit 1
}
[[ "$(grep -c '\.v2k-stage-' "${run_string_log}")" -eq 2 ]] || {
  echo "[ERR] each transfer attempt did not use its own staging RBD" >&2
  cat "${run_string_log}" >&2
  exit 1
}
[[ "$(grep -c -- '-n -S "4M"' "${run_string_log}")" -eq 2 ]] || {
  echo "[ERR] staged RBD transfer did not preserve qemu-img no-create sparse flags" >&2
  cat "${run_string_log}" >&2
  exit 1
}
assert_contains "transfer_retry_scheduled" "${event_log}"
assert_contains "rbd_staging_published" "${event_log}"
assert_contains "sleep|0" "${operation_log}"
assert_contains "publish|rbd:pool/canonical.v2k-stage-retry_smoke_01-d0-" "${operation_log}"

runner_mode="non_retryable"
runner_attempts=0
canonical_exists=0
write_manifest "${manifest}"
: > "${event_log}"
: > "${operation_log}"
: > "${run_string_log}"
set +e
v2k_transfer_base_one \
  "${manifest}" 0 "vcenter.example" "AA:BB" "vm-42" "snapshot-7" \
  "${WORK_DIR}/password"
transfer_rc=$?
set -e
[[ "${transfer_rc}" -eq 8 ]] || {
  echo "[ERR] non-retryable transfer returned ${transfer_rc}, expected 8" >&2
  exit 1
}
[[ "$(wc -l < "${run_string_log}")" -eq 1 ]] || {
  echo "[ERR] non-retryable failure was retried" >&2
  cat "${run_string_log}" >&2
  exit 1
}
[[ "$(jq -r '.disks[0].transfer.base_done' "${manifest}")" == "false" ]] || {
  echo "[ERR] failed transfer incorrectly marked base_done" >&2
  exit 1
}
[[ "$(jq -r '.runtime.last_error.code' "${manifest}")" -eq 8 ]] || {
  echo "[ERR] transfer failure code was not persisted" >&2
  cat "${manifest}" >&2
  exit 1
}
[[ "$(jq -r '.runtime.last_error.reason' "${manifest}")" == "base_transfer_failed" ]] || {
  echo "[ERR] non-retryable failure reason was not persisted" >&2
  cat "${manifest}" >&2
  exit 1
}
assert_contains "disk_failed" "${event_log}"

runner_attempts=0
canonical_exists=1
write_manifest "${manifest}"
: > "${event_log}"
: > "${operation_log}"
: > "${run_string_log}"
set +e
v2k_transfer_base_one \
  "${manifest}" 0 "vcenter.example" "AA:BB" "vm-42" "snapshot-7" \
  "${WORK_DIR}/password"
transfer_rc=$?
set -e
[[ "${transfer_rc}" -eq 73 ]] || {
  echo "[ERR] existing canonical RBD returned ${transfer_rc}, expected 73" >&2
  exit 1
}
[[ ! -s "${run_string_log}" ]] || {
  echo "[ERR] transfer started despite an existing canonical target" >&2
  cat "${run_string_log}" >&2
  exit 1
}
[[ "$(jq -r '.runtime.last_error.reason' "${manifest}")" == "rbd_target_already_exists" ]] || {
  echo "[ERR] existing target refusal was not persisted" >&2
  cat "${manifest}" >&2
  exit 1
}

retryable_log="${WORK_DIR}/retryable.log"
printf '%s\n' 'NfcNetTcpSetError: Broken pipe' > "${retryable_log}"
v2k_transfer_base_retryable_nfc_log "${retryable_log}" || {
  echo "[ERR] NFC transport failure was not classified as retryable" >&2
  exit 1
}
printf '%s\n' 'VDDK authentication failed' > "${retryable_log}"
if v2k_transfer_base_retryable_nfc_log "${retryable_log}"; then
  echo "[ERR] authentication failure was classified as retryable" >&2
  exit 1
fi

echo "[OK] v2k base transfer staging, NFC retry, and fail-closed publish"
