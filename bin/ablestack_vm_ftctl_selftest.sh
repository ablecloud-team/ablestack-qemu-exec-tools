#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_BASE="${ROOT_DIR}/lib"

# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/common.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/config.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/logging.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/libvirt_wrap.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/state.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/profile.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/inventory.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/cluster.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/blockcopy.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/standby.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/xcolo.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/fencing.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/failover.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/verify.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/orchestrator.sh"

SELFTEST_ROOT_DEFAULT="${ROOT_DIR}/build/ftctl_selftest"
SELFTEST_ROOT="${FTCTL_SELFTEST_ROOT:-${SELFTEST_ROOT_DEFAULT}}"
SELFTEST_CONFIG="${SELFTEST_ROOT}/ftctl-test.conf"

selftest_info() {
  printf '[SELFTEST] %s\n' "$*"
}

selftest_fail() {
  printf '[SELFTEST][FAIL] %s\n' "$*" >&2
  exit 1
}

selftest_assert_eq() {
  local got="${1-}"
  local expect="${2-}"
  local msg="${3-assert_eq failed}"
  [[ "${got}" == "${expect}" ]] || selftest_fail "${msg}: got='${got}' expect='${expect}'"
}

selftest_assert_file_contains() {
  local path="${1-}"
  local needle="${2-}"
  grep -q -- "${needle}" "${path}" || selftest_fail "missing '${needle}' in ${path}"
}

selftest_prepare_config_file() {
  mkdir -p "${SELFTEST_ROOT}"
  cat > "${SELFTEST_CONFIG}" <<EOF
FTCTL_RUN_DIR="${SELFTEST_ROOT}/run"
FTCTL_LOG_DIR="${SELFTEST_ROOT}/log"
FTCTL_EVENTS_LOG="${SELFTEST_ROOT}/log/events.log"
FTCTL_STATE_DIR="${SELFTEST_ROOT}/state"
FTCTL_PROFILE_DIR="${SELFTEST_ROOT}/profiles"
FTCTL_CLUSTER_CONFIG="${SELFTEST_ROOT}/cluster.conf"
FTCTL_CLUSTER_DIR="${SELFTEST_ROOT}/cluster.d"
FTCTL_CLUSTER_HOSTS_DIR="${SELFTEST_ROOT}/cluster.d/hosts"
FTCTL_BLOCKCOPY_TARGET_BASE_DIR="${SELFTEST_ROOT}/blockcopy"
FTCTL_XML_BACKUP_DIR="${SELFTEST_ROOT}/xml"
EOF
}

selftest_reset_env() {
  rm -rf "${SELFTEST_ROOT}"
  selftest_prepare_config_file
  ftctl_config_init_defaults
  ftctl_config_load_file "${SELFTEST_CONFIG}"
  ftctl_config_finalize_paths
  ftctl_ensure_runtime_dirs
  FTCTL_DRY_RUN="1"
}

selftest_run_lint() {
  local files=(
    "bin/ablestack_vm_ftctl.sh"
    "bin/ablestack_vm_ftctl_selftest.sh"
    "lib/ftctl/common.sh"
    "lib/ftctl/config.sh"
    "lib/ftctl/logging.sh"
    "lib/ftctl/libvirt_wrap.sh"
    "lib/ftctl/state.sh"
    "lib/ftctl/profile.sh"
    "lib/ftctl/inventory.sh"
    "lib/ftctl/cluster.sh"
    "lib/ftctl/blockcopy.sh"
    "lib/ftctl/standby.sh"
    "lib/ftctl/xcolo.sh"
    "lib/ftctl/fencing.sh"
    "lib/ftctl/failover.sh"
    "lib/ftctl/verify.sh"
    "lib/ftctl/orchestrator.sh"
    "completions/ablestack_vm_ftctl"
  )
  selftest_info "running bash -n"
  bash -n "${files[@]}"
  if command -v shellcheck >/dev/null 2>&1; then
    selftest_info "running shellcheck"
    shellcheck "${files[@]}"
  else
    selftest_info "shellcheck not found, skipping"
  fi
}

selftest_case_cluster_cli() {
  selftest_reset_env
  selftest_info "cluster config CLI"

  bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" config init-cluster \
    --config "${SELFTEST_CONFIG}" \
    --cluster-name demo-cluster \
    --local-host-id host-01 >/dev/null

  bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" config host-upsert \
    --config "${SELFTEST_CONFIG}" \
    --host-id host-01 \
    --role primary \
    --management-ip 10.0.0.11 \
    --libvirt-uri qemu+ssh://host-01/system \
    --blockcopy-ip 172.16.10.11 \
    --xcolo-control-ip 172.16.20.11 \
    --xcolo-data-ip 172.16.30.11 >/dev/null

  selftest_assert_file_contains "${SELFTEST_ROOT}/cluster.conf" "FTCTL_CLUSTER_NAME=\"demo-cluster\""
  selftest_assert_file_contains "${SELFTEST_ROOT}/cluster.d/hosts/host-01.conf" "FTCTL_HOST_MANAGEMENT_IP=\"10.0.0.11\""
}

selftest_case_blockcopy_and_standby() {
  selftest_reset_env
  selftest_info "blockcopy/standby dry-run"

  local vm="demo"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  ftctl_state_init_vm "${vm}"
  mkdir -p "${bundle}"

  cat > "${bundle}/standby.xml" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <uuid>1234</uuid>
  <devices>
    <disk type='file' device='disk'>
      <source file='/var/lib/libvirt/images/${vm}.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
  </devices>
</domain>
EOF

  ftctl_state_set "${vm}" \
    "standby_xml_seed=${bundle}/standby.xml" \
    "primary_persistence=no"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/var/lib/libvirt/images/${vm}.qcow2|/mirror/${vm}-vda.qcow2|qcow2|running|yes
EOF

  ftctl_standby_prepare "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "prepared-transient" "standby prepare"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "/mirror/${vm}-vda.qcow2"

  ftctl_standby_activate "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "start-dry-run" "standby activate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "standby activate side"
}

selftest_case_reconcile_and_fencing() {
  selftest_reset_env
  selftest_info "reconcile/fencing state machine"

  local vm="vm1"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_FENCING_POLICY="manual-block"
  FTCTL_PROFILE_FENCING_SSH_USER="root"

  cat > "${SELFTEST_ROOT}/cluster.conf" <<EOF
FTCTL_CLUSTER_NAME="demo"
FTCTL_LOCAL_HOST_ID="host-01"
EOF
  cat > "${SELFTEST_ROOT}/cluster.d/hosts/host-02.conf" <<EOF
FTCTL_HOST_ID="host-02"
FTCTL_HOST_ROLE="secondary"
FTCTL_HOST_MANAGEMENT_IP="10.0.0.12"
FTCTL_HOST_LIBVIRT_URI="qemu+ssh://peer/system"
FTCTL_HOST_BLOCKCOPY_REPLICATION_IP="172.16.10.12"
FTCTL_HOST_XCOLO_CONTROL_IP="172.16.20.12"
FTCTL_HOST_XCOLO_DATA_IP="172.16.30.12"
EOF

  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "mode=ha" "transport_state=lost" "protection_state=degraded"

  ftctl_blockcopy_refresh_and_classify() { return 12; }
  ftctl_profile_load_vm() { :; }
  ftctl_profile_apply_cli() { :; }
  ftctl_profile_validate() { :; }
  ftctl_orchestrator_probe_peer() { printf -v "$1" '%s' 'host-02'; printf -v "$2" '%s' '10.0.0.12'; printf -v "$3" '%s' 'reachable'; }
  ftctl_blockcopy_rearm() { ftctl_state_set "$1" "protection_state=rearming" "transport_state=rearm_pending" "last_rearm_ts=$(ftctl_now_iso8601)"; }

  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "transient_loss" "reconcile grace window"

  ftctl_state_set "${vm}" \
    "transport_state=lost" \
    "transport_loss_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "rearm_pending" "reconcile rearm"

  FTCTL_PROFILE_FENCING_POLICY="manual-block"
  ftctl_failover_request "${vm}" "manual" || true
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "required" "manual fencing required"
  ftctl_fencing_manual_confirm "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "manual-fenced" "manual fencing confirm"
}

selftest_case_xcolo_and_xml() {
  selftest_reset_env
  selftest_info "x-colo dry-run and XML commandline"

  local vm="ftvm"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  mkdir -p "${bundle}"
  cat > "${bundle}/primary.xml" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <devices>
    <disk type='file' device='disk'>
      <source file='/var/lib/libvirt/images/${vm}.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
  </devices>
</domain>
EOF
  cp "${bundle}/primary.xml" "${bundle}/standby.xml"
  cat > "$(ftctl_state_path "${vm}")" <<EOF
vm=${vm}
primary_xml_backup=${bundle}/primary.xml
standby_xml_seed=${bundle}/standby.xml
primary_persistence=yes
EOF
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/var/lib/libvirt/images/${vm}.qcow2|/mirror/${vm}-vda.qcow2|qcow2|running|yes
EOF

  ftctl_profile_reset
  FTCTL_PROFILE_MODE="ft"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT="tcp:10.10.10.21:9000"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.10.20.21:9999"
  FTCTL_PROFILE_XCOLO_MIGRATE_URI="tcp:10.10.20.21:9998"
  FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE="parent0"
  FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE="colo-disk0"
  FTCTL_PROFILE_XCOLO_NBD_NODE="nbd0"
  FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="2000"
  FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY="-incoming;defer"
  FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY="-S;-msg;timestamp=on"
  FTCTL_PROFILE_FENCING_SSH_USER="root"
  ftctl_profile_validate "${vm}"
  ftctl_state_set "${vm}" "mode=ft" "active_side=primary"

  ftctl_xcolo_plan_protect "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "colo_running" "xcolo protect"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "xcolo transport"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "qemu:commandline"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "qemu:commandline"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "/mirror/${vm}-vda.qcow2"

  ftctl_xcolo_failover "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "xcolo failover side"
}

selftest_main() {
  selftest_run_lint
  selftest_case_cluster_cli
  selftest_case_blockcopy_and_standby
  selftest_case_reconcile_and_fencing
  selftest_case_xcolo_and_xml
  selftest_info "all checks passed"
}

selftest_main "$@"
