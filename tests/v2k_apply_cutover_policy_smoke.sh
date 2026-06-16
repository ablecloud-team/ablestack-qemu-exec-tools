#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="${TMPDIR:-/tmp}/v2k_apply_cutover_policy_smoke"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: $1" >&2
    exit 2
  }
}

cleanup() {
  rm -rf "${WORK_ROOT}"
}

require_cmd jq
trap cleanup EXIT
rm -rf "${WORK_ROOT}"
mkdir -p "${WORK_ROOT}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/orchestrator.sh"

v2k_valid_target_provider() { return 0; }
v2k_source_kv_env() { return 0; }
v2k_compat_bootstrap_env() { return 0; }
v2k_compat_resolve_profile() { return 0; }
v2k_manifest_split_is_done() { return 0; }
v2k_manifest_is_windows() { return 0; }
v2k_manifest_runtime_set() { return 0; }
v2k_manifest_phase_done() { return 0; }
v2k_event() { return 0; }
v2k_event_storage_snapshot() { return 0; }
v2k_emit_progress_event() { return 0; }
v2k_cmd_cleanup() { return 0; }
v2k_cmd_init() { return 0; }
v2k_cmd_cbt() { return 0; }
v2k_cmd_snapshot() { return 0; }
v2k_cmd_sync() { return 0; }
v2k_cmd_incr_sync() { return 0; }
v2k_cmd_cutover() {
  printf '%s\n' "$@" > "${V2K_TEST_CUTOVER_ARGS_FILE}"
}

write_phase2_manifest() {
  local manifest="$1"
  cat > "${manifest}" <<'JSON'
{
  "source": {
    "vm": {
      "guestFamily": "windowsGuest"
    }
  },
  "runtime": {
    "split": {
      "phase1": {
        "done": true
      }
    },
    "sync_within_deadline": true
  }
}
JSON
}

run_case() {
  local name="$1"
  local cutover_args="${2:-}"
  local workdir="${WORK_ROOT}/${name}"
  mkdir -p "${workdir}"
  write_phase2_manifest "${workdir}/manifest.json"
  : > "${workdir}/govc.env"
  : > "${workdir}/vddk.cred"

  export V2K_WORKDIR="${workdir}"
  export V2K_MANIFEST="${workdir}/manifest.json"
  export V2K_RUN_ID="${name}"
  export V2K_TEST_CUTOVER_ARGS_FILE="${workdir}/cutover.args"

  local -a args=(
    --foreground
    --vm win-vm
    --vcenter vc.example.local
    --username administrator
    --password dummy
    --dst /tmp/v2k-target
    --split phase2
    --target-provider ablestack-cloud
    --no-incr
    --shutdown guest
  )
  [[ -z "${cutover_args}" ]] || args+=(--cutover-args "${cutover_args}")

  v2k_cmd_run_foreground "${args[@]}"
}

run_case apply "--apply"
apply_args="$(cat "${WORK_ROOT}/apply/cutover.args")"
grep -qx -- "--winpe-bootstrap" <<<"${apply_args}" || {
  echo "[ERR] v2k --apply should still enable WinPE bootstrap for Windows" >&2
  printf '%s\n' "${apply_args}" >&2
  exit 1
}
grep -qx -- "--apply" <<<"${apply_args}" || {
  echo "[ERR] v2k --apply was not forwarded to cutover" >&2
  printf '%s\n' "${apply_args}" >&2
  exit 1
}
if grep -qx -- "--start" <<<"${apply_args}"; then
  echo "[ERR] v2k --apply must not be converted to --start" >&2
  printf '%s\n' "${apply_args}" >&2
  exit 1
fi

run_case default ""
default_args="$(cat "${WORK_ROOT}/default/cutover.args")"
grep -qx -- "--winpe-bootstrap" <<<"${default_args}" || {
  echo "[ERR] default Windows cutover should enable WinPE bootstrap" >&2
  printf '%s\n' "${default_args}" >&2
  exit 1
}
grep -qx -- "--start" <<<"${default_args}" || {
  echo "[ERR] default Windows cutover should still auto-start" >&2
  printf '%s\n' "${default_args}" >&2
  exit 1
}

echo "[OK] v2k apply cutover policy preserves WinPE without auto-start"
