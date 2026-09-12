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
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_BASE=""
SELFTEST_INSTALLED_CLI=""

selftest_die_load() {
  printf '[SELFTEST][FAIL] %s\n' "$*" >&2
  exit 1
}

selftest_resolve_lib_base() {
  local c
  local candidates=(
    "${ROOT_DIR}/lib/ablestack-qemu-exec-tools"
    "${ROOT_DIR}/lib"
    "/usr/local/lib/ablestack-qemu-exec-tools"
    "/usr/local/lib"
  )
  for c in "${candidates[@]}"; do
    if [[ -d "${c}/ftctl" ]]; then
      LIB_BASE="${c}"
      return 0
    fi
  done
  selftest_die_load "ftctl library directory not found"
}

selftest_resolve_lib_base

if [[ ! -f "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" ]]; then
  if SELFTEST_INSTALLED_CLI="$(command -v ablestack_vm_ftctl 2>/dev/null)" \
      && [[ -x "${SELFTEST_INSTALLED_CLI}" ]]; then
    :
  else
    SELFTEST_INSTALLED_CLI=""
  fi
fi

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
source "${LIB_BASE}/ftctl/dr_key.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/standby.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/xcolo.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/fencing.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/failover.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/events.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/dr_ablestack.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/dr_vmware.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/dr_kvm_vmware.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/dr_scheduler.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/guestprep.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/dr_runtime.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/verify.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/orchestrator.sh"

if [[ -n "${SELFTEST_INSTALLED_CLI}" ]]; then
  SELFTEST_ROOT_DEFAULT="${TMPDIR:-/tmp}/ftctl_selftest"
else
  SELFTEST_ROOT_DEFAULT="${ROOT_DIR}/build/ftctl_selftest"
fi
SELFTEST_ROOT="${FTCTL_SELFTEST_ROOT:-${SELFTEST_ROOT_DEFAULT}}"
SELFTEST_CONFIG="${SELFTEST_ROOT}/ftctl-test.conf"

selftest_prepare_installed_cli_wrapper() {
  [[ -n "${SELFTEST_INSTALLED_CLI}" ]] || return 0
  ROOT_DIR="${SELFTEST_ROOT}/installed-root"
  mkdir -p "${ROOT_DIR}/bin"
  cat > "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" <<EOF
#!/usr/bin/env bash
exec "${SELFTEST_INSTALLED_CLI}" "\$@"
EOF
  chmod 0755 "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh"
}

selftest_prepare_installed_cli_wrapper

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

selftest_assert_not_eq() {
  local got="${1-}"
  local unexpected="${2-}"
  local msg="${3-assert_not_eq failed}"
  [[ "${got}" != "${unexpected}" ]] || selftest_fail "${msg}: value='${got}'"
}

selftest_assert_file_contains() {
  local path="${1-}"
  local needle="${2-}"
  grep -q -- "${needle}" "${path}" || selftest_fail "missing '${needle}' in ${path}"
}

selftest_assert_file_not_contains() {
  local path="${1-}"
  local needle="${2-}"
  ! grep -q -- "${needle}" "${path}" || selftest_fail "unexpected '${needle}' in ${path}"
}

selftest_assert_contains() {
  local haystack="${1-}"
  local needle="${2-}"
  local msg="${3-assert_contains failed}"
  [[ "${haystack}" == *"${needle}"* ]] || selftest_fail "${msg}: missing '${needle}'"
}

selftest_assert_not_contains() {
  local haystack="${1-}"
  local needle="${2-}"
  local msg="${3-assert_not_contains failed}"
  [[ "${haystack}" != *"${needle}"* ]] || selftest_fail "${msg}: unexpected '${needle}'"
}

selftest_mock_xcolo_primary_channels_ready() {
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_primary_channel_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_channel_mirror_established=yes" \
      "xcolo_channel_compare_established=yes" \
      "xcolo_channel_compare_local_established=yes" \
      "xcolo_channel_compare_out_established=yes" \
      "xcolo_channel_mirror_listen=yes" \
      "xcolo_channel_compare_listen=yes" \
      "xcolo_channel_compare_local_listen=yes" \
      "xcolo_channel_compare_out_listen=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_validate_primary_channel_paths() {
    ftctl_xcolo_capture_primary_channel_state "$1"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_wait_primary_filter_chardev_binding() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_chardev_ready=yes" \
      "xcolo_primary_filter_chardev_reason="
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_chardev_binding_state() {
    local vm="${1-}" phase="${2:-strict}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_chardev_mirror0=yes" \
      "xcolo_primary_chardev_compare1=yes" \
      "xcolo_primary_chardev_compare0=yes" \
      "xcolo_primary_chardev_compare0-0=yes" \
      "xcolo_primary_chardev_compare_out=yes" \
      "xcolo_primary_chardev_compare_out0=yes" \
      "xcolo_primary_filter_chardev_ready=yes" \
      "xcolo_primary_filter_chardev_reason=" \
      "xcolo_primary_filter_chardev_phase=${phase}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_primary_filter_qom_ready() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_qom_ready=yes" \
      "xcolo_primary_filter_qom_reason=" \
      "xcolo_primary_filter_qom_m0_path=/objects/m0" \
      "xcolo_primary_filter_qom_redire0_path=/objects/redire0" \
      "xcolo_primary_filter_qom_redire1_path=/objects/redire1" \
      "xcolo_primary_filter_qom_comp0_path=/objects/comp0"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_filter_qom_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_qom_ready=yes" \
      "xcolo_primary_filter_qom_reason=" \
      "xcolo_primary_filter_qom_m0_path=/objects/m0" \
      "xcolo_primary_filter_qom_redire0_path=/objects/redire0" \
      "xcolo_primary_filter_qom_redire1_path=/objects/redire1" \
      "xcolo_primary_filter_qom_comp0_path=/objects/comp0"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_primary_filter_cmdline_ready() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_cmdline_ready=yes" \
      "xcolo_primary_filter_cmdline_reason=" \
      "xcolo_primary_filter_cmdline_expected_netdev=hostnet0"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_filter_cmdline_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_cmdline_ready=yes" \
      "xcolo_primary_filter_cmdline_reason=" \
      "xcolo_primary_filter_cmdline_expected_netdev=hostnet0"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_topology_audit_ready() {
    local vm="${1-}" secondary_vm="${2:-$1}" phase="${3:-pre_migrate}"
    : "${secondary_vm}"
    ftctl_state_set "${vm}" \
      "xcolo_topology_audit=ok" \
      "xcolo_topology_audit_phase=${phase}" \
      "xcolo_topology_audit_reason=" \
      "xcolo_topology_primary_ready=yes" \
      "xcolo_topology_secondary_ready=yes" \
      "xcolo_secondary_filter_cmdline_ready=yes" \
      "xcolo_secondary_filter_cmdline_reason="
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    local _uri="${1-}" _vm="${2-}" role="${3-}"
    [[ "${role}" == "primary" ]]
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_primary_chardev_markers() {
    return 1
  }
}

selftest_mock_xcolo_primary_role_diagnostics_ok() {
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_runtime_failure_diagnostics() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_debug_dir=${FTCTL_RUN_DIR}/debug/xcolo/$(ftctl_state_vm_key "${vm}")" \
      "xcolo_primary_capability_x_colo=yes" \
      "xcolo_primary_capability_return_path=yes" \
      "xcolo_primary_checkpoint_delay_set=yes"
  }
}

selftest_prepare_config_file() {
  mkdir -p "${SELFTEST_ROOT}"
  selftest_prepare_installed_cli_wrapper
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
    "bin/ablestack_vm_ftctl_dr_rolling_reload.sh"
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
    "lib/ftctl/events.sh"
    "lib/ftctl/dr_ablestack.sh"
    "lib/ftctl/dr_kvm_vmware.sh"
    "lib/ftctl/dr_kvm_vmware_mover.sh"
    "lib/ftctl/dr_vmware.sh"
    "lib/ftctl/dr_scheduler.sh"
    "lib/ftctl/dr_runtime.sh"
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
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
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
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "<name>${vm}-standby</name>"

  ftctl_standby_activate "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "start-dry-run" "standby activate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "standby activate side"
}

selftest_case_libvirt_managed_peer_krbd_map() (
  selftest_reset_env
  selftest_info "libvirt-managed peer krbd map"

  local vm="krbd-standby"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local call_log="${SELFTEST_ROOT}/peer-map-calls.log"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_PROVISIONING_BACKEND="libvirt-managed"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_FENCING_SSH_USER="root"
  ftctl_state_init_vm "${vm}"
  mkdir -p "${bundle}"

  cat > "${bundle}/standby.xml" <<EOF
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

  ftctl_state_set "${vm}" \
    "standby_xml_seed=${bundle}/standby.xml" \
    "primary_persistence=no"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/dev/rbd/rbd/${vm}-source|/dev/rbd/rbd/${vm}-mirror|raw|copy|yes
EOF

  ftctl_standby_prepare "${vm}"

  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() {
    printf -v "$1" '%s' "peer"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    printf 'REMOTE:%s:%s:%s\n' "$1" "$2" "$6" >> "${call_log}"
    printf -v "$3" '%s' ""
    printf -v "$4" '%s' ""
    printf -v "$5" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_virsh() {
    printf 'VIRSH:%s\n' "$*" >> "${call_log}"
    printf -v "$2" '%s' ""
    printf -v "$3" '%s' ""
    printf -v "$4" '%s' "0"
  }

  ftctl_standby_activate "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "running" "libvirt-managed standby activate"
  selftest_assert_file_contains "${call_log}" "rbd map"
  selftest_assert_file_contains "${call_log}" "/dev/rbd/rbd/${vm}-mirror"
  selftest_assert_file_contains "${call_log}" "VIRSH:"
)

selftest_case_standby_activate_already_exists() (
  selftest_reset_env
  selftest_info "standby activate already exists"

  local vm="already-running-standby"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  ftctl_state_init_vm "${vm}"
  mkdir -p "${bundle}"

  cat > "${bundle}/standby.generated.xml" <<EOF
<domain type='kvm'>
  <name>${vm}-standby</name>
</domain>
EOF

  ftctl_state_set "${vm}" \
    "standby_xml_generated=${bundle}/standby.generated.xml" \
    "primary_persistence=no"

  # shellcheck disable=SC2317
  ftctl_standby_map_peer_krbd_paths() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_virsh() {
    printf -v "$2" '%s' ""
    printf -v "$3" '%s' "error: operation failed: domain '${vm}-standby' already exists with uuid 00000000-0000-0000-0000-000000000001"
    printf -v "$4" '%s' "1"
  }

  ftctl_standby_activate "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "running" "already existing standby activate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "already existing standby side"
)

selftest_case_standby_deactivate_uses_generated_domain_name() (
  selftest_reset_env
  selftest_info "standby deactivate uses generated libvirt domain name"

  local vm="standby-generated-name"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local call_log="${SELFTEST_ROOT}/standby-deactivate-generated-name.log"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_MODE="ft"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  ftctl_state_init_vm "${vm}"
  mkdir -p "${bundle}"
  cat > "${bundle}/standby.generated.xml" <<EOF
<domain type='kvm'>
  <name>i-2-222-VM</name>
</domain>
EOF
  ftctl_state_set "${vm}" \
    "secondary_vm_name=${vm}-standby" \
    "standby_xml_generated=${bundle}/standby.generated.xml"

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}" err_var="${3}" rc_var="${4}" cmd="$*"
    printf '%s\n' "${cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' "error: Domain not found"
    printf -v "${rc_var}" '%s' "1"
  }

  ftctl_standby_deactivate "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "stopped" "standby deactivate generated domain"
  selftest_assert_file_contains "${call_log}" "destroy i-2-222-VM"
  selftest_assert_file_contains "${call_log}" "undefine i-2-222-VM"
)

selftest_case_backend_validation() {
  selftest_reset_env
  selftest_info "backend mode validation"

  local vm="backend-vm"
  ftctl_profile_reset
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="shared"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_DOMAIN_PERSISTENCE="yes"
  FTCTL_PROFILE_DISK_MAP="auto"

  if ftctl_profile_validate "${vm}" && ftctl_blockcopy_validate_backend_mode "${vm}"; then
    selftest_fail "shared-blockcopy should reject disk_map=auto"
  fi

  ftctl_profile_reset
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_DOMAIN_PERSISTENCE="yes"
  FTCTL_PROFILE_DISK_MAP="vda=/secondary/${vm}.qcow2"

  if ftctl_profile_validate "${vm}"; then
    selftest_fail "shared-blockcopy should reject secondary-local target storage scope"
  fi

  ftctl_profile_reset
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_SECONDARY_TARGET_DIR="/secondary"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="10.0.0.12"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT="10809"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  FTCTL_PROFILE_DISK_MAP="auto"
  FTCTL_PROFILE_DOMAIN_PERSISTENCE="no"
  ftctl_profile_validate "${vm}"

  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  if ftctl_profile_validate "${vm}" && ftctl_blockcopy_validate_backend_mode "${vm}"; then
    selftest_fail "cloud-managed remote-nbd should reject disk_map=auto"
  fi

  FTCTL_PROFILE_DISK_MAP="vda=relative-target.qcow2"
  ftctl_profile_validate "${vm}"
  ftctl_inventory_collect_vm_disks() {
    local out_array_name="${2}"
    local -n _out_array="${out_array_name}"
    _out_array=("vda|/var/lib/libvirt/images/${vm}.qcow2|qcow2")
  }
  if ftctl_blockcopy_validate_backend_mode "${vm}"; then
    selftest_fail "cloud-managed remote-nbd should reject relative disk map paths"
  fi

  FTCTL_PROFILE_DISK_MAP="vdb=/secondary/${vm}.qcow2"
  if ftctl_blockcopy_validate_backend_mode "${vm}"; then
    selftest_fail "cloud-managed remote-nbd should reject missing target mappings"
  fi

  FTCTL_PROFILE_DISK_MAP="vda=/secondary/${vm}.qcow2"
  ftctl_blockcopy_validate_backend_mode "${vm}"

  # Restore the real inventory function after the focused backend validation stub.
  # shellcheck source=/dev/null
  source "${LIB_BASE}/ftctl/inventory.sh"
  FTCTL_PROFILE_PROVISIONING_BACKEND="libvirt-managed"
  FTCTL_PROFILE_DISK_MAP="auto"

  mkdir -p "${SELFTEST_ROOT}/xml/${vm}"
  cat > "${SELFTEST_ROOT}/xml/${vm}/standby.xml" <<EOF
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
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "standby_xml_seed=${SELFTEST_ROOT}/xml/${vm}/standby.xml" \
    "primary_persistence=no"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/var/lib/libvirt/images/${vm}.qcow2|nbd://10.0.0.12:10809/${vm}-vda|qcow2|running|yes|/secondary/${vm}/vda-${vm}.qcow2
EOF
  ftctl_standby_prepare "${vm}"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "/secondary/${vm}/vda-${vm}.qcow2"

  FTCTL_REMOTE_NBD_PORT_BASE="10809"
  FTCTL_REMOTE_NBD_PORT_COUNT="32"
  FTCTL_REMOTE_NBD_MAX_CONCURRENT="32"
  local chosen_port=""
  ftctl_blockcopy_remote_target_host_user() { printf -v "$1" '%s' '10.0.0.12'; printf -v "$2" '%s' 'root'; }
  ftctl_blockcopy_remote_nbd_active_count() { printf -v "$3" '%s' '0'; }
  ftctl_blockcopy_remote_nbd_port_in_use() { return 1; }
  ftctl_blockcopy_remote_nbd_pick_port "${vm}" "vda" chosen_port
  [[ "${chosen_port}" =~ ^[0-9]+$ ]] || selftest_fail "remote-nbd port not assigned"
  (( chosen_port >= FTCTL_REMOTE_NBD_PORT_BASE && chosen_port < FTCTL_REMOTE_NBD_PORT_BASE + FTCTL_REMOTE_NBD_PORT_COUNT )) || \
    selftest_fail "remote-nbd port out of range"
}

selftest_case_dr_remote_key_connectivity_args() (
  selftest_reset_env
  selftest_info "DR remote key connectivity arguments"

  local vm="i-2-381-VM"
  local uri keyed_uri identity_args existing_key_uri encoded_key_path
  FTCTL_DR_KEY_ROOT="${SELFTEST_ROOT}/ssh/ftctl-dr"
  CLI_VM="${vm}"
  FTCTL_PROFILE_MODE="dr"
  ftctl_dr_key_ensure "${vm}" >/dev/null
  encoded_key_path="$(ftctl_dr_key_uri_query_escape "${FTCTL_DR_KEY_ROOT}/${vm}/id_ed25519")"

  uri="qemu+ssh://root@10.0.0.12:22/system"
  keyed_uri="$(ftctl_dr_key_uri_with_keyfile "${uri}" "${vm}")"
  selftest_assert_eq "${keyed_uri}" "${uri}?no_verify=1&keyfile=${encoded_key_path}" "DR qemu+ssh keyfile URI"

  keyed_uri="$(ftctl_dr_key_uri_with_keyfile "${uri}?no_verify=1" "${vm}")"
  selftest_assert_eq "${keyed_uri}" "${uri}?no_verify=1&keyfile=${encoded_key_path}" "DR qemu+ssh keyfile URI with existing no_verify"

  keyed_uri="$(ftctl_dr_key_uri_with_keyfile "${uri}?transport=ssh" "${vm}")"
  selftest_assert_eq "${keyed_uri}" "${uri}?transport=ssh&no_verify=1&keyfile=${encoded_key_path}" "DR qemu+ssh keyfile URI with existing query"

  existing_key_uri="${uri}?keyfile=/root/.ssh/custom"
  keyed_uri="$(ftctl_dr_key_uri_with_keyfile "${existing_key_uri}" "${vm}")"
  selftest_assert_eq "${keyed_uri}" "${existing_key_uri}&no_verify=1" "existing qemu+ssh keyfile is preserved"

  ftctl_blockcopy_dr_ssh_identity_args identity_args "${vm}"
  selftest_assert_contains "${identity_args}" "-i ${FTCTL_DR_KEY_ROOT}/${vm}/id_ed25519" "DR ssh identity key"
  selftest_assert_contains "${identity_args}" "-o IdentitiesOnly=yes" "DR ssh identities only"

  FTCTL_PROFILE_SECONDARY_URI="${uri}"
  FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE=""
  ftctl_profile_materialize_dr_ssh_keyfile "${vm}"
  selftest_assert_eq "${FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE}" "${FTCTL_DR_KEY_ROOT}/${vm}/id_ed25519" "DR profile keyfile materialized"
  selftest_assert_contains "${FTCTL_PROFILE_SECONDARY_URI}" "no_verify=1" "DR profile URI no_verify materialized"
  selftest_assert_contains "${FTCTL_PROFILE_SECONDARY_URI}" "keyfile=${encoded_key_path}" "DR profile URI keyfile materialized"
)

selftest_case_blockcopy_missing_job_state() (
  selftest_reset_env
  selftest_info "blockcopy missing job state"

  local vm="missing-job-vm"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="shared"
  FTCTL_PROFILE_DISK_MAP="vda=/dev/rbd/rbd/${vm}-mirror"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "protection_state=protected" \
    "transport_state=mirroring" \
    "active_side=primary" \
    "last_error="
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/dev/rbd/rbd/${vm}-source|/dev/rbd/rbd/${vm}-mirror|raw|copy|no
EOF

  # shellcheck disable=SC2317
  ftctl_inventory_collect_vm_disks() {
    local -n _out_array="$2"
    _out_array=("vda|/dev/rbd/rbd/${vm}-source|raw")
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_job_query() {
    printf -v "$3" '%s' "unknown"
    printf -v "$4" '%s' "unknown"
    return 4
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_runtime_mirror_query() {
    printf -v "$3" '%s' "none"
    printf -v "$4" '%s' "unknown"
    return 1
  }

  if ftctl_blockcopy_refresh_vm_jobs "${vm}"; then
    selftest_fail "missing blockjob should fail refresh"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "error" "missing blockjob protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed" "missing blockjob transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "blockcopy_job_missing:vda" "missing blockjob last_error"
)

selftest_case_blockcopy_progress_status() (
  selftest_reset_env
  selftest_info "blockcopy progress status"

  local vm="progress-vm"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "transport_state=copying"
  ftctl_blockcopy_state_write "${vm}" \
    "vda|/dev/source-vda|nbd://10.0.0.12:10827/progress-vm-vda|qcow2|running|no|/secondary/progress-vm/vda.qcow2" \
    "vdb|/dev/source-vdb|/shared/progress-vm/vdb.raw|raw|ready|yes|"

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    printf -v "${out_var}" '%s' '{"return":[{"device":"copy-vda-libvirt-1-storage","offset":5368709120,"len":10737418240,"ready":false,"status":"running","paused":false,"io-status":"ok"},{"device":"copy-vdb-libvirt-2-storage","offset":10737418240,"len":10737418240,"ready":true,"status":"running","paused":false,"io-status":"ok"}]}'
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_blockcopy_progress_refresh_from_qmp "${vm}" "${vm}" "${FTCTL_PROFILE_PRIMARY_URI}" "forward" "mirror" "blockcopy.progress"
  selftest_assert_file_contains "$(ftctl_blockcopy_progress_path "${vm}")" '"percent":75.0'
  selftest_assert_file_contains "$(ftctl_blockcopy_progress_path "${vm}")" '"target":"vda"'
  selftest_assert_file_contains "$(ftctl_blockcopy_progress_path "${vm}")" '"nbd_port":10827'
  selftest_assert_file_contains "$(ftctl_blockcopy_progress_path "${vm}")" '"nbd_endpoint":"10.0.0.12:10827/progress-vm-vda"'
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"event":"blockcopy.progress"'

  local out="" rc=0
  out="$(ftctl_state_print_one "${vm}" "1")"
  selftest_assert_contains "${out}" '"sync_progress"' "status includes sync progress"
  selftest_assert_contains "${out}" '"copied_bytes":16106127360' "status includes copied bytes"
)

selftest_case_shared_xml_reuse_external() (
  selftest_reset_env
  selftest_info "shared XML blockcopy uses reuse-external for existing targets"

  local xml_path="${SELFTEST_ROOT}/shared.xml"
  local args_file="${SELFTEST_ROOT}/virsh.args"
  local out="" err="" rc=0

  cat > "${xml_path}" <<EOF
<disk type='block' device='disk'>
  <driver name='qemu' type='raw'/>
  <source dev='/dev/rbd/rbd/dst'/>
  <target dev='vda' bus='scsi'/>
</disk>
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    shift 5
    printf '%s\n' "$*" > "${args_file}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_blockcopy_start_shared_xml_job "qemu:///system" "vm1" "vda" "unknown" "${xml_path}" out err rc "1"
  selftest_assert_eq "${rc}" "0" "shared xml blockcopy rc"
  selftest_assert_file_contains "${args_file}" "--reuse-external"
)

selftest_case_blockcopy_target_empty_verify() (
  selftest_reset_env
  selftest_info "blockcopy target materialization detects empty RBD target"

  local vm="verify-empty"
  ftctl_state_init_vm "${vm}"

  # shellcheck disable=SC2317
  ftctl_blockcopy_rbd_du_used_bytes_primary() {
    case "${1-}" in
      rbd/source) printf -v "$2" '%s' "4096" ;;
      rbd/dest) printf -v "$2" '%s' "0" ;;
      *) printf -v "$2" '%s' "" ; return 1 ;;
    esac
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_path_head_sha256_primary() {
    return 1
  }

  if ftctl_blockcopy_verify_target_materialized "${vm}" "vda" "/dev/rbd/rbd/source" "/dev/rbd/rbd/dest"; then
    selftest_fail "empty RBD target should fail materialization verification"
  fi
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "target_empty"
)

selftest_case_blockcopy_verify_blocks_mirroring() (
  selftest_reset_env
  selftest_info "blockcopy verify failure blocks protected/mirroring"

  local vm="verify-blocks"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  ftctl_state_init_vm "${vm}"

  # shellcheck disable=SC2317
  ftctl_inventory_collect_vm_disks() {
    local out_array_name="${2}"
    eval "${out_array_name}=(\"vda|/dev/rbd/rbd/source|raw\")"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_resolve_dest() {
    printf '%s\n' "/dev/rbd/rbd/dest"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_job_query() {
    printf -v "$3" '%s' "copy"
    printf -v "$4" '%s' "yes"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_progress_refresh_from_qmp() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_verify_target_materialized() {
    return 21
  }

  if ftctl_blockcopy_refresh_vm_jobs "${vm}"; then
    selftest_fail "verify failure should make refresh fail"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "error" "verify failure protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed" "verify failure transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "blockcopy_target_not_materialized:vda" "verify failure last_error"
)

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
  ftctl_inventory_check_vm() { printf '0 0 ok true running\n'; }
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
  ftctl_state_set "${vm}" "protection_state=protected" "transport_state=mirroring"
  ftctl_failover_request "${vm}" "manual" || true
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "required" "manual fencing required"
  ftctl_fencing_manual_confirm "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "manual-fenced" "manual fencing confirm"

  ftctl_state_set "${vm}" \
    "standby_xml_generated=${SELFTEST_ROOT}/standby.generated.xml" \
    "primary_persistence=no"
  ftctl_failover_request "${vm}" "manual-confirmed"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "manual-fenced" "manual fencing retained"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "start-dry-run" "manual fencing starts standby"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "manual fencing active side"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failed_over" "manual fencing failover complete"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed_over" "manual fencing transport complete"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "manual fencing clears last_error"
}

selftest_case_failover_blocks_copying_transport() (
  selftest_reset_env
  selftest_info "failover blocks non-ready blockcopy"

  local vm="copying-failover"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "protection_state=syncing" \
    "transport_state=copying" \
    "fencing_state=clear"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_FENCING_POLICY="manual-block"
  FTCTL_FAILOVER_SYNC_READY_TIMEOUT_SEC="1"
  # shellcheck disable=SC2317
  ftctl_blockcopy_wait_forward_sync_ready() { return 1; }

  if ftctl_failover_request "${vm}" "manual"; then
    selftest_fail "copying transport should block initial failover"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "clear" "copying failover keeps fencing clear"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "syncing" "copying failover keeps syncing"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "blockcopy_not_ready_for_failover" "copying failover last_error"

  ftctl_state_set "${vm}" "transport_state=mirroring" "last_error="
  ftctl_failover_precheck_blockcopy_ready "${vm}" "ha" "7" "before_fencing" "0"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "failover_ready")" "1" "ready precheck records failover marker"
  ftctl_state_set "${vm}" "transport_state=transient_loss"
  ftctl_failover_precheck_blockcopy_ready "${vm}" "ha" "7" "cloud_prepare" "0"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "marker permits cloud prepare after primary stop"

  ftctl_state_set "${vm}" "failover_ready=" "transport_state=copying"
  ftctl_fencing_manual_confirm "${vm}"
  ftctl_state_set "${vm}" \
    "protection_state=failing_over" \
    "transport_state=copying" \
    "standby_xml_generated=${SELFTEST_ROOT}/standby.generated.xml" \
    "primary_persistence=no"

  if ftctl_failover_request "${vm}" "manual-confirmed"; then
    selftest_fail "copying transport should block fenced failover continuation"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "error" "fenced copying continuation errors"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "blockcopy_not_ready_for_failover" "fenced copying continuation last_error"
)

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
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
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

  local primary_args secondary_args
  primary_args="$(ftctl_xcolo_build_primary_qemu_args)"
  secondary_args="$(ftctl_xcolo_build_secondary_qemu_args)"
  ftctl_xcolo_prepare_block_generated_xmls "${vm}" \
    "${bundle}/primary.xml" "${bundle}/standby.xml" \
    "/var/lib/libvirt/images/${vm}.qcow2" "/mirror/${vm}-vda.qcow2" \
    "qcow2" "${primary_args}" "${secondary_args}"
  ftctl_state_set "${vm}" "protection_state=colo_running" "transport_state=mirroring"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "colo_running" "xcolo protect"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "xcolo transport"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "qemu:commandline"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "<iothreads>1</iothreads>"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" '<iothread id="1"'
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "iothread,id=iothread1"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "filter-mirror,id=m0,netdev=hostnet0,queue=tx,outdev=mirror0,insert=behind,position=tail"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "filter-redirector,id=redire0,netdev=hostnet0,queue=rx,indev=compare_out,insert=behind,position=tail"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "filter-redirector,id=redire1,netdev=hostnet0,queue=rx,outdev=compare0,insert=behind,position=tail"
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "status=off"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0,iothread=iothread1"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=mirror0,host=0.0.0.0,port=9003,server=on,wait=off"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=compare1,host=0.0.0.0,port=9004,server=on,wait=off"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=compare0,host=127.0.0.1,port=9001,server=on,wait=off"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=compare_out,host=127.0.0.1,port=9005,server=on,wait=off"
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=mirror0,host=0.0.0.0,port=9003,server=on,wait=on"
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=compare1,host=0.0.0.0,port=9004,server=on,wait=on"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "qemu:commandline"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "/mirror/${vm}-vda.qcow2"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "socket,id=red0,host="
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "port=9003,reconnect-ms=1000"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "socket,id=red1,host="
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "port=9004,reconnect-ms=1000"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "filter-redirector,id=f1,netdev=hostnet0,queue=tx,indev=red0"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "filter-redirector,id=f2,netdev=hostnet0,queue=rx,outdev=red1"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "filter-rewriter,id=rew0,netdev=hostnet0,queue=all"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "defer"
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "tcp:10.10.20.21:9998"

  ftctl_xcolo_failover "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "xcolo failover side"
}

selftest_case_xcolo_iothread_contract_validation() {
  selftest_reset_env
  selftest_info "x-colo iothread contract validation"

  local vm="ft-iothread"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local bad_xml good_xml
  mkdir -p "${bundle}"
  bad_xml="${bundle}/bad.xml"
  good_xml="${bundle}/good.xml"
  cat > "${bad_xml}" <<'EOF'
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>ft-iothread</name>
  <devices/>
  <qemu:commandline>
    <qemu:arg value='-object'/>
    <qemu:arg value='iothread,id=iothread1'/>
    <qemu:arg value='-object'/>
    <qemu:arg value='colo-compare,id=comp0,iothread=iothread1'/>
  </qemu:commandline>
</domain>
EOF
  if ftctl_xml_validate_xcolo_iothread_contract "${bad_xml}" >/dev/null 2>&1; then
    selftest_fail "opaque qemu:commandline iothread should fail validation"
  fi

  cat > "${good_xml}" <<'EOF'
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>ft-iothread</name>
  <devices/>
  <qemu:commandline>
    <qemu:arg value='-object'/>
    <qemu:arg value='colo-compare,id=comp0,iothread=iothread1'/>
  </qemu:commandline>
</domain>
EOF
  ftctl_xml_ensure_iothread_id "${good_xml}" "1"
  ftctl_xml_validate_xcolo_iothread_contract "${good_xml}"
  selftest_assert_file_contains "${good_xml}" "<iothreads>1</iothreads>"
  selftest_assert_file_contains "${good_xml}" '<iothread id="1"'
}

selftest_case_xcolo_block_xml_preserves_disk_targets() {
  selftest_reset_env
  selftest_info "block-backed FT generated XML preserves disk targets"

  local vm="block-ftvm"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local primary_generated standby_generated duplicate_xml
  mkdir -p "${bundle}"
  cat > "${bundle}/primary.xml" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <devices>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw'/>
      <source dev='/dev/rbd/rbd/${vm}-root'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw'/>
      <source dev='/dev/rbd/rbd/${vm}-data'/>
      <target dev='sdb' bus='scsi'/>
    </disk>
    <interface type='bridge'>
      <mac address='52:54:00:12:34:56'/>
      <source bridge='bridge0'/>
      <target dev='vnet0'/>
      <model type='virtio'/>
      <driver name='vhost' vhost='on' vhostfd='13'/>
    </interface>
    <graphics type='vnc' port='5904' autoport='no' listen='172.16.20.11'>
      <listen type='address' address='172.16.20.11'/>
    </graphics>
  </devices>
</domain>
EOF
  cp "${bundle}/primary.xml" "${bundle}/standby.xml"

  ftctl_profile_reset
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_DISK_MAP="sda=/var/lib/libvirt/images/${vm}-root;sdb=/var/lib/libvirt/images/${vm}-data"
  FTCTL_PROFILE_XCOLO_DISK_MAP_METADATA="sda=/var/lib/libvirt/images/${vm}-root|qcow2|file|file;sdb=/var/lib/libvirt/images/${vm}-data|qcow2|file|file"
  ftctl_xcolo_prepare_block_generated_xmls "${vm}" \
    "${bundle}/primary.xml" "${bundle}/standby.xml" \
    "/dev/rbd/rbd/${vm}-root" "/var/lib/libvirt/images/${vm}-root" \
    "raw" "" ""

  primary_generated="$(ftctl_state_get "${vm}" "primary_xml_generated")"
  standby_generated="$(ftctl_state_get "${vm}" "standby_xml_generated")"
  selftest_assert_file_contains "${primary_generated}" '<target dev="sda" bus="scsi"'
  selftest_assert_file_contains "${primary_generated}" '<target dev="sdb" bus="scsi"'
  selftest_assert_file_contains "${standby_generated}" '<target dev="sda" bus="scsi"'
  selftest_assert_file_contains "${standby_generated}" '<target dev="sdb" bus="scsi"'
  selftest_assert_file_contains "${standby_generated}" '<disk type="file" device="disk"'
  selftest_assert_file_contains "${standby_generated}" '<driver name="qemu" type="qcow2"'
  selftest_assert_file_contains "${standby_generated}" '<source file="/var/lib/libvirt/images/block-ftvm-root"'
  selftest_assert_file_contains "${standby_generated}" '<source file="/var/lib/libvirt/images/block-ftvm-data"'
  python3 - <<'PY' "${primary_generated}" "${standby_generated}"
import sys
import xml.etree.ElementTree as ET

for xml_path in sys.argv[1:]:
    root = ET.parse(xml_path).getroot()
    iface = root.find("./devices/interface")
    if iface is None:
        raise SystemExit(f"missing interface in {xml_path}")
    driver = iface.find("driver")
    if driver is None or driver.get("name") != "qemu":
        raise SystemExit(f"interface driver is not qemu in {xml_path}")
    if driver.get("vhost") is not None or driver.get("vhostfd") is not None:
        raise SystemExit(f"interface driver kept vhost attributes in {xml_path}")

standby_root = ET.parse(sys.argv[2]).getroot()
graphics = standby_root.find("./devices/graphics")
if graphics is None:
    raise SystemExit("missing standby graphics")
if graphics.get("listen") != "0.0.0.0":
    raise SystemExit(f"standby graphics listen was not normalized: {graphics.get('listen')}")
listen = graphics.find("listen")
if listen is None or listen.get("address") != "0.0.0.0":
    raise SystemExit("standby graphics listen child was not normalized")
PY
  selftest_assert_file_contains "${standby_generated}" '/var/lib/libvirt/images/block-ftvm-root'
  selftest_assert_file_contains "${standby_generated}" '/var/lib/libvirt/images/block-ftvm-data'
  if grep -q '/dev/rbd/rbd/block-ftvm-data' "${standby_generated}"; then
    selftest_fail "standby generated XML kept original data disk source"
  fi
  ftctl_xml_validate_unique_disk_targets "${primary_generated}"
  ftctl_xml_validate_unique_disk_targets "${standby_generated}"

  duplicate_xml="${bundle}/duplicate.xml"
  cp "${standby_generated}" "${duplicate_xml}"
  python3 - <<'PY' "${duplicate_xml}"
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
tree = ET.parse(xml_path)
root = tree.getroot()
disks = [d for d in root.find("devices").findall("disk") if d.get("device") == "disk"]
disks[0].find("target").set("dev", "sdb")
tree.write(xml_path, encoding="unicode")
PY
  if ftctl_xml_validate_unique_disk_targets "${duplicate_xml}" >/dev/null 2>&1; then
    selftest_fail "duplicate disk target validator should fail"
  fi
}

selftest_case_xcolo_file_qcow2_uses_cold_conversion_detection() (
  selftest_reset_env
  selftest_info "file-backed qcow2 FT uses cold-conversion detection"

  local vm="file-qcow2-ftvm"
  local kind="" detected_target="" detected_source="" detected_format=""
  local detailed_disks=()

  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
  FTCTL_PROFILE_DISK_MAP="sda=/var/lib/libvirt/images/${vm}-standby-root;sdb=/var/lib/libvirt/images/${vm}-standby-data"

  # shellcheck disable=SC2317
  ftctl_inventory_collect_vm_disks_detailed() {
    local _vm="${1-}"
    local out_array_name="${2}"
    # shellcheck disable=SC2178
    local -n _out_array="${out_array_name}"
    : "${_vm}"
    _out_array=(
      "sda|/var/lib/libvirt/images/${vm}-root|qcow2|file"
      "sdb|/var/lib/libvirt/images/${vm}-data|qcow2|file"
    )
  }

  ftctl_inventory_collect_vm_disks_detailed "${vm}" detailed_disks
  selftest_assert_eq "${detailed_disks[0]-}" "sda|/var/lib/libvirt/images/${vm}-root|qcow2|file" "file qcow2 inventory mock root disk"

  ftctl_xcolo_detect_cold_conversion_ft "${vm}" kind detected_target detected_source detected_format
  selftest_assert_eq "${kind}" "file" "file qcow2 cold conversion kind"
  selftest_assert_eq "${detected_target}" "sda" "file qcow2 cold conversion target"
  selftest_assert_eq "${detected_format}" "qcow2" "file qcow2 cold conversion format"

  if ftctl_xcolo_detect_block_backed_ft "${vm}" kind detected_target detected_source detected_format; then
    selftest_fail "file-backed qcow2 must not be reported as block-backed"
  fi

  FTCTL_PROFILE_DISK_MAP="auto"
  if ftctl_xcolo_detect_cold_conversion_ft "${vm}" kind detected_target detected_source detected_format; then
    selftest_fail "file-backed qcow2 cold conversion must require explicit disk map"
  fi
)

selftest_case_inventory_disk_format_uses_force_share() (
  selftest_reset_env
  selftest_info "inventory disk format detection uses qemu-img force-share"

  local fmt="" call_log="${SELFTEST_ROOT}/inventory-format-force-share.log"

  # shellcheck disable=SC2317
  command() {
    if [[ "${1-}" == "-v" && ( "${2-}" == "qemu-img" || "${2-}" == "jq" ) ]]; then
      return 0
    fi
    builtin command "$@"
  }

  # shellcheck disable=SC2317
  ftctl_cmd_run() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
    shift 4
    : "${_timeout}"
    [[ "${1-}" == "--" ]] && shift
    printf '%s\n' "$*" >> "${call_log}"
    if [[ "$*" == *"qemu-img info --force-share --output=json /var/lib/libvirt/images/no-extension"* ]]; then
      printf -v "${out_var}" '%s' '{"format":"qcow2"}'
      printf -v "${err_var}" '%s' ""
      printf -v "${rc_var}" '%s' "0"
      return 0
    fi
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' "unexpected command"
    printf -v "${rc_var}" '%s' "1"
  }

  ftctl_inventory_detect_disk_format "/var/lib/libvirt/images/no-extension" fmt
  selftest_assert_eq "${fmt}" "qcow2" "force-share qemu-img format detection"
  selftest_assert_file_contains "${call_log}" "qemu-img info --force-share --output=json /var/lib/libvirt/images/no-extension"
)

selftest_case_xcolo_file_qcow2_empty_format_avoids_prebuilt_fallback() (
  selftest_reset_env
  selftest_info "file-backed qcow2 with empty inventory format uses cold conversion, not prebuilt"

  local vm="file-qcow2-empty-format-ftvm"
  local call_log="${SELFTEST_ROOT}/xcolo-empty-format-routing.log"
  local kind="" detected_target="" detected_source="" detected_format=""

  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
  FTCTL_PROFILE_DISK_MAP="sda=/var/lib/libvirt/images/${vm}-standby-root;sdb=/var/lib/libvirt/images/${vm}-standby-data"

  # shellcheck disable=SC2317
  ftctl_inventory_collect_vm_disks_detailed() {
    local _vm="${1-}"
    local out_array_name="${2}"
    # shellcheck disable=SC2178
    local -n _out_array="${out_array_name}"
    : "${_vm}"
    _out_array=(
      "sda|/var/lib/libvirt/images/${vm}-root||file"
      "sdb|/var/lib/libvirt/images/${vm}-data||file"
    )
  }

  # shellcheck disable=SC2317
  ftctl_inventory_detect_disk_format() {
    printf 'FORMAT:%s\n' "${1-}" >> "${call_log}"
    printf -v "${2}" '%s' "qcow2"
  }

  # shellcheck disable=SC2317
  ftctl_xcolo_require_supported_machine_contract() {
    :
  }

  # shellcheck disable=SC2317
  ftctl_xcolo_plan_protect_block_cold_conversion() {
    printf 'COLD:%s\n' "${1-}" >> "${call_log}"
  }

  # shellcheck disable=SC2317
  ftctl_xcolo_plan_protect_prebuilt() {
    printf 'PREBUILT:%s\n' "${1-}" >> "${call_log}"
    return 1
  }

  ftctl_xcolo_detect_cold_conversion_ft "${vm}" kind detected_target detected_source detected_format
  selftest_assert_eq "${kind}" "file" "empty format file qcow2 kind"
  selftest_assert_eq "${detected_target}" "sda" "empty format file qcow2 target"
  selftest_assert_eq "${detected_format}" "qcow2" "empty format file qcow2 detected format"

  ftctl_xcolo_plan_protect "${vm}"
  selftest_assert_file_contains "${call_log}" "FORMAT:/var/lib/libvirt/images/${vm}-root"
  selftest_assert_file_contains "${call_log}" "FORMAT:/var/lib/libvirt/images/${vm}-data"
  selftest_assert_file_contains "${call_log}" "COLD:${vm}"
  selftest_assert_file_not_contains "${call_log}" "PREBUILT:${vm}"
)

selftest_case_xcolo_prebuilt_backup_uses_secondary_vm_name() (
  selftest_reset_env
  selftest_info "prebuilt XCOLO XML backup uses secondary VM name"

  local vm="primary-vm"
  local secondary_vm="i-2-230-VM"
  local call_log="${SELFTEST_ROOT}/xcolo-prebuilt-backup-domain.log"

  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${secondary_vm}"

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
    shift 4
    : "${_timeout}"
    [[ "${1-}" == "--" ]] && shift
    printf '%s\n' "$*" >> "${call_log}"
    printf -v "${out_var}" '%s' "<domain type='kvm'><name>${*: -1}</name><devices/></domain>"
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_xcolo_backup_prebuilt_pair_xml "${vm}"

  selftest_assert_file_contains "${call_log}" "qemu:///system dumpxml --security-info ${vm}"
  selftest_assert_file_contains "${call_log}" "qemu+ssh://peer/system dumpxml --security-info ${secondary_vm}"
  if grep -F "qemu+ssh://peer/system dumpxml --security-info ${vm}" "${call_log}" >/dev/null 2>&1; then
    selftest_fail "prebuilt backup must not query the secondary URI with the primary VM name"
  fi
)

selftest_case_xcolo_cloud_managed_rbd_metadata_inference() {
  selftest_reset_env
  selftest_info "cloud-managed x-colo RBD metadata does not require mapped secondary paths"

  local vm="cloud-rbd-ftvm"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local primary_generated standby_generated
  mkdir -p "${bundle}"
  cat > "${bundle}/primary.xml" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <devices>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw'/>
      <source dev='/dev/rbd/rbd/${vm}-primary-root'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw'/>
      <source dev='/dev/rbd/rbd/${vm}-primary-data'/>
      <target dev='sdb' bus='scsi'/>
    </disk>
    <interface type='bridge'>
      <mac address='52:54:00:12:34:57'/>
      <source bridge='bridge0'/>
      <target dev='vnet0'/>
      <model type='virtio'/>
    </interface>
  </devices>
</domain>
EOF
  cp "${bundle}/primary.xml" "${bundle}/standby.xml"

  ftctl_profile_reset
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_DISK_MAP="sda=/dev/rbd/rbd/${vm}-secondary-root;sdb=/dev/rbd/rbd/${vm}-secondary-data"
  ftctl_state_set "${vm}" \
    "xcolo_storage_symmetry=ok" \
    "xcolo_disk_sda_secondary_layout=block/raw" \
    "xcolo_disk_sdb_secondary_layout=block/raw"

  ftctl_xcolo_prepare_block_generated_xmls "${vm}" \
    "${bundle}/primary.xml" "${bundle}/standby.xml" \
    "/dev/rbd/rbd/${vm}-primary-root" "/dev/rbd/rbd/${vm}-secondary-root" \
    "raw" "" ""

  primary_generated="$(ftctl_state_get "${vm}" "primary_xml_generated")"
  standby_generated="$(ftctl_state_get "${vm}" "standby_xml_generated")"
  selftest_assert_file_contains "${primary_generated}" '<source dev="/dev/rbd/rbd/cloud-rbd-ftvm-primary-root"'
  selftest_assert_file_contains "${standby_generated}" '<source dev="/dev/rbd/rbd/cloud-rbd-ftvm-secondary-root"'
  selftest_assert_file_contains "${standby_generated}" '<source dev="/dev/rbd/rbd/cloud-rbd-ftvm-secondary-data"'
  selftest_assert_file_not_contains "${standby_generated}" 'cloud-rbd-ftvm-primary-root'
  selftest_assert_file_not_contains "${standby_generated}" 'cloud-rbd-ftvm-primary-data'
  ftctl_xml_validate_disk_map_sources "${standby_generated}" "${FTCTL_PROFILE_DISK_MAP}"
}

selftest_case_xcolo_primary_create_maps_rbd_sources() (
  selftest_reset_env
  selftest_info "x-colo primary generated XML maps KRBD sources before create"

  local vm="primary-rbd-create"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local generated_xml="${bundle}/primary.generated.xml"
  local call_log="${SELFTEST_ROOT}/primary-rbd-create-calls.log"
  mkdir -p "${bundle}"
  cat > "${generated_xml}" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <devices>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/${vm}-root'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/${vm}-data'/>
      <target dev='sdb' bus='scsi'/>
    </disk>
  </devices>
</domain>
EOF

  ftctl_blockcopy_krbd_map_local() {
    printf 'MAP:%s\n' "$1" >> "${call_log}"
  }
  ftctl_virsh() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
    shift 4
    : "${_timeout}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    printf 'VIRSH:%s\n' "$*" >> "${call_log}"
  }

  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_XCOLO_QMP_TIMEOUT_SEC="3"
  ftctl_xcolo_create_primary_generated "${vm}" "${generated_xml}"

  selftest_assert_file_contains "${call_log}" "MAP:/dev/rbd/rbd/${vm}-root"
  selftest_assert_file_contains "${call_log}" "MAP:/dev/rbd/rbd/${vm}-data"
  selftest_assert_file_contains "${call_log}" "VIRSH:-- -c qemu:///system create ${generated_xml}"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "primary.rbd-map"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "primary.create_generated"
)

selftest_case_xcolo_runtime_disk_device_replace_is_forbidden() (
  selftest_reset_env
  selftest_info "x-colo forbids runtime protected disk device replacement"

  local call_log="${SELFTEST_ROOT}/xcolo-scsi-replace-calls.log"
  FTCTL_DRY_RUN="1"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_capability_state() {
    if [[ "${3-}" == "return-path" ]]; then
      printf -v "$4" '%s' "no"
    else
      printf -v "$4" '%s' "yes"
    fi
    return 0
  }

  if ftctl_xcolo_attach_secondary_block_graph \
      "standby-vm" "libvirt-3-format" "/tmp/hidden.qcow2" "/tmp/active.qcow2" "scsi0-0-0-0"; then
    selftest_fail "secondary runtime disk replacement must be rejected by default"
  fi
  if ftctl_xcolo_attach_primary_block_graph \
      "primary-vm" "libvirt-3-storage" "/tmp/primary-active.qcow2" "scsi0-0-0-0"; then
    selftest_fail "primary runtime disk replacement must be rejected by default"
  fi

  selftest_assert_file_contains "${call_log}" "secondary.device_replace_forbidden"
  selftest_assert_file_contains "${call_log}" "primary.device_replace_forbidden"
  selftest_assert_file_not_contains "${call_log}" '"execute":"device_del"'
  selftest_assert_file_not_contains "${call_log}" '"execute":"device_add"'
)

selftest_case_xcolo_startup_disk_graph_uses_native_rbd_backend_by_default() (
  selftest_reset_env
  selftest_info "x-colo startup disk graph defaults RBD commandline to native librbd backend"

  local xml_path="${SELFTEST_ROOT}/xcolo-startup-rbd.xml"
  local primary_args="" secondary_args=""
  cat > "${xml_path}" <<'EOF'
<domain type='kvm'>
  <devices>
    <controller type='scsi' index='0' model='virtio-scsi'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
    </controller>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/root'/>
      <target dev='sda' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/data'/>
      <target dev='sdb' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='1'/>
    </disk>
  </devices>
</domain>
EOF

  ftctl_xcolo_build_startup_disk_args "${xml_path}" "primary" \
    "sda|/dev/rbd/rbd/root|raw|/tmp/primary-active-root.qcow2|/dev/rbd/rbd/secondary-root|/tmp/secondary-hidden-root.qcow2|/tmp/secondary-active-root.qcow2;sdb|/dev/rbd/rbd/data|raw|/tmp/primary-active-data.qcow2|/dev/rbd/rbd/secondary-data|/tmp/secondary-hidden-data.qcow2|/tmp/secondary-active-data.qcow2" \
    primary_args
  ftctl_xcolo_build_startup_disk_args "${xml_path}" "secondary" \
    "sda|/dev/rbd/rbd/root|raw|/tmp/primary-active-root.qcow2|/dev/rbd/rbd/secondary-root|/tmp/secondary-hidden-root.qcow2|/tmp/secondary-active-root.qcow2;sdb|/dev/rbd/rbd/data|raw|/tmp/primary-active-data.qcow2|/dev/rbd/rbd/secondary-data|/tmp/secondary-hidden-data.qcow2|/tmp/secondary-active-data.qcow2" \
    secondary_args

  selftest_assert_contains "${primary_args}" "file.driver=rbd,file.pool=rbd,file.image=root" "primary root native librbd backend"
  selftest_assert_contains "${primary_args}" "file.driver=rbd,file.pool=rbd,file.image=data" "primary data native librbd backend"
  selftest_assert_contains "${secondary_args}" "file.driver=rbd,file.pool=rbd,file.image=secondary-root" "secondary root native librbd backend"
  selftest_assert_contains "${secondary_args}" "file.driver=rbd,file.pool=rbd,file.image=secondary-data" "secondary data native librbd backend"
  selftest_assert_contains "${primary_args}" "drive=ftctl-colo-sda,id=scsi0-0-0-0" "primary guest drive keeps source topology id"
  selftest_assert_contains "${secondary_args}" "drive=ftctl-colo-sda,id=scsi0-0-0-0" "secondary guest drive keeps source topology id"
  selftest_assert_contains "${secondary_args}" "file.file.driver=file,file.file.filename=/tmp/secondary-active-root.qcow2" "secondary active qcow2 has explicit file child driver"
  selftest_assert_contains "${secondary_args}" "file.backing.file.driver=file,file.backing.file.filename=/tmp/secondary-hidden-root.qcow2" "secondary hidden qcow2 has explicit file child driver"
  selftest_assert_not_contains "${primary_args}" "driver=nbd,node-name=ftctl-primary-parent-sda-nbd" "primary default must not use local NBD parent adapter"
  selftest_assert_not_contains "${primary_args}" "filename=/dev/rbd/rbd/root" "primary default must not expose KRBD path"
  selftest_assert_not_contains "${secondary_args}" "filename=/dev/rbd/rbd/secondary-root" "secondary default must not expose KRBD path"
)

selftest_case_xcolo_startup_disk_graph_allows_explicit_krbd_backend() (
  selftest_reset_env
  selftest_info "x-colo startup disk graph allows explicit KRBD commandline backend"

  local xml_path="${SELFTEST_ROOT}/xcolo-startup-explicit-krbd.xml"
  local primary_args="" secondary_args="" primary_parent_nbd_map=""
  FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND="krbd"
  cat > "${xml_path}" <<'EOF'
<domain type='kvm'>
  <devices>
    <controller type='scsi' index='0' model='virtio-scsi'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
    </controller>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/root'/>
      <target dev='sda' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
  </devices>
</domain>
EOF

  primary_parent_nbd_map="/dev/rbd/rbd/root|/run/ablestack-vm-ftctl/xcolo-parent-nbd/i-2-test-VM/sda.sock|ftctl-primary-parent-sda"
  ftctl_xcolo_build_startup_disk_args "${xml_path}" "primary" \
    "sda|/dev/rbd/rbd/root|raw|/tmp/primary-active-root.qcow2|/dev/rbd/rbd/secondary-root|/tmp/secondary-hidden-root.qcow2|/tmp/secondary-active-root.qcow2" \
    primary_args "" "${primary_parent_nbd_map}"
  ftctl_xcolo_build_startup_disk_args "${xml_path}" "secondary" \
    "sda|/dev/rbd/rbd/root|raw|/tmp/primary-active-root.qcow2|/dev/rbd/rbd/secondary-root|/tmp/secondary-hidden-root.qcow2|/tmp/secondary-active-root.qcow2" \
    secondary_args

  selftest_assert_contains "${primary_args}" "driver=nbd,node-name=ftctl-primary-parent-sda-nbd,server.type=unix,server.path=/run/ablestack-vm-ftctl/xcolo-parent-nbd/i-2-test-VM/sda.sock,export=ftctl-primary-parent-sda" "primary explicit KRBD local NBD parent adapter backend"
  selftest_assert_not_contains "${primary_args}" "driver=host_device,node-name=ftctl-primary-parent-sda-host,filename=/dev/rbd/rbd/root" "primary explicit KRBD must not expose host_device when adapter map exists"
  selftest_assert_contains "${secondary_args}" "driver=host_device,node-name=ftctl-parent-sda-host,filename=/dev/rbd/rbd/secondary-root" "secondary explicit KRBD host_device backend"
  selftest_assert_contains "${secondary_args}" "file.file.driver=file,file.file.filename=/tmp/secondary-active-root.qcow2" "secondary explicit KRBD active qcow2 has explicit file child driver"
  selftest_assert_contains "${secondary_args}" "file.backing.file.driver=file,file.backing.file.filename=/tmp/secondary-hidden-root.qcow2" "secondary explicit KRBD hidden qcow2 has explicit file child driver"
  selftest_assert_not_contains "${primary_args}" "file=rbd:rbd/root" "primary explicit KRBD must not use librbd URI"
  selftest_assert_not_contains "${secondary_args}" "file=rbd:rbd/secondary-root" "secondary explicit KRBD must not use librbd URI"
)

selftest_case_xcolo_startup_disk_graph_allows_explicit_librbd_backend() (
  selftest_reset_env
  selftest_info "x-colo startup disk graph allows explicit native librbd commandline backend"

  local xml_path="${SELFTEST_ROOT}/xcolo-startup-explicit-librbd.xml"
  local primary_args="" secondary_args=""
  FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND="librbd"
  cat > "${xml_path}" <<'EOF'
<domain type='kvm'>
  <devices>
    <controller type='scsi' index='0' model='virtio-scsi'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
    </controller>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/root'/>
      <target dev='sda' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
  </devices>
</domain>
EOF

  ftctl_xcolo_build_startup_disk_args "${xml_path}" "primary" \
    "sda|/dev/rbd/rbd/root|raw|/tmp/primary-active-root.qcow2|/dev/rbd/rbd/secondary-root|/tmp/secondary-hidden-root.qcow2|/tmp/secondary-active-root.qcow2" \
    primary_args
  ftctl_xcolo_build_startup_disk_args "${xml_path}" "secondary" \
    "sda|/dev/rbd/rbd/root|raw|/tmp/primary-active-root.qcow2|/dev/rbd/rbd/secondary-root|/tmp/secondary-hidden-root.qcow2|/tmp/secondary-active-root.qcow2" \
    secondary_args

  selftest_assert_contains "${primary_args}" "file.driver=rbd,file.pool=rbd,file.image=root" "primary explicit librbd backend"
  selftest_assert_contains "${secondary_args}" "file.driver=rbd,file.pool=rbd,file.image=secondary-root" "secondary explicit librbd backend"
  selftest_assert_not_contains "${primary_args}" "filename=/dev/rbd/rbd/root" "primary explicit librbd must not use KRBD path"
  selftest_assert_not_contains "${secondary_args}" "filename=/dev/rbd/rbd/secondary-root" "secondary explicit librbd must not use KRBD path"
)

selftest_case_xcolo_block_handshake_sets_checkpoint_before_migrate() (
  selftest_reset_env
  selftest_info "x-colo block handshake sets checkpoint delay before primary migrate"

  local call_log="${SELFTEST_ROOT}/xcolo-block-handshake-order.log"
  local filter_line checkpoint_line incoming_line receiver_line migrate_line
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.0.0.2:10809"
  FTCTL_PROFILE_XCOLO_MIGRATE_URI="tcp:10.0.0.2:9998"
  FTCTL_PROFILE_XCOLO_NBD_NODE="nbd0"
  FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="2000"
  selftest_mock_xcolo_primary_channels_ready

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_capability_state() {
    if [[ "${3-}" == "return-path" ]]; then
      printf -v "$4" '%s' "no"
    else
      printf -v "$4" '%s' "yes"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_qmp() {
    local _uri="$1" _vm="$2" payload="$3" out_var="$4" rc_var="$5"
    : "${_uri}${_vm}"
    if [[ "${payload}" == *"query-chardev"* && "${_uri}" == *"qemu+ssh"* ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"label":"red0","frontend-open":true},{"label":"red1","frontend-open":true}]}'
    elif [[ "${payload}" == *"query-chardev"* ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"label":"mirror0","frontend-open":true},{"label":"compare1","frontend-open":true}]}'
    elif [[ "${payload}" == *"query-status"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"running":false,"status":"paused"}}'
    elif [[ "${payload}" == *"query-migrate-parameters"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"x-checkpoint-delay":2000}}'
    elif [[ "${payload}" == *"query-migrate-capabilities"* ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}'
    elif [[ "${payload}" == *"query-migrate"* && "${_uri}" == *"qemu+ssh"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"status":"colo"}}'
    elif [[ "${payload}" == *"query-migrate"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"status":"active"}}'
    elif [[ "${payload}" == *"query-colo-status"* && "${_uri}" == *"qemu+ssh"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"mode":"secondary"}}'
    elif [[ "${payload}" == *"query-colo-status"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"mode":"none"}}'
    else
      printf -v "${out_var}" '%s' '{"return":{}}'
    fi
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_socket_snapshot() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_secondary_startup_materialization_gate() {
    local vm="$1"
    ftctl_state_set "${vm}" "xcolo_secondary_startup_materialization=ok"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_pre_migrate_runtime_topology_gate() {
    local vm="$1"
    ftctl_state_set "${vm}" "xcolo_pre_migrate_topology_gate_state=ok"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_pre_migrate_receiver_ready() {
    local vm="$1"
    printf '%s|%s|%s|%s|%s\n' "colo" "xcolo.pre_migrate_receiver" "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" "mock" >> "${call_log}"
    ftctl_state_set "${vm}" "xcolo_pre_migrate_receiver_ready=ok"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_assert_no_premigrate_filter_mirror_send() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_gate_before_guest_traffic() {
    local vm="$1"
    ftctl_state_set "${vm}" "xcolo_pre_guest_traffic_gate=ready"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_activate_primary_filters_after_migrate() {
    local vm="$1"
    ftctl_state_set "${vm}" \
      "xcolo_primary_net_filters_activation_mode=startup-active" \
      "xcolo_primary_net_filters_activation_order=premigrate-active" \
      "xcolo_primary_net_filters_activated=true" \
      "xcolo_primary_filter_status_pre_migrate=on" \
      "xcolo_primary_filter_status_post_migrate=on"
    return 0
  }

  ftctl_xcolo_execute_handshake_with_nodes "primary-vm" "standby-vm" "parent0"

  selftest_assert_file_contains "${call_log}" "primary.stop_before_filter_attach"
  selftest_assert_file_contains "${call_log}" "primary.migrate_set_parameters.pre_migrate"
  selftest_assert_file_contains "${call_log}" "primary.migrate"
  selftest_assert_file_not_contains "${call_log}" "primary.filter_status_on.redire1"
  selftest_assert_file_not_contains "${call_log}" "primary.filter_status_on.m0"
  selftest_assert_file_not_contains "${call_log}" "primary.filter_status_on.redire0"
  selftest_assert_file_not_contains "${call_log}" "primary.cont_before_migrate"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_checkpoint_delay_ready")" "yes" \
    "primary checkpoint delay pre-migrate gate"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_secondary_migrate_incoming")" "ok" \
    "secondary migrate-incoming accepted"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_net_filters_attached")" "true" \
    "primary net filters attached state"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_net_filters_attach_mode")" "cmdline" \
    "primary net filters startup attach mode"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_net_filters_activation_mode")" "startup-active" \
    "primary net filters activation mode"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_net_filters_activation_order")" "premigrate-active" \
    "primary net filters active before migrate"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_net_filters_activated")" "true" \
    "primary net filters activated"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_filter_status_pre_migrate")" "on" \
    "primary filter status pre-migrate"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_filter_status_post_migrate")" "on" \
    "primary filter status post-migrate"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_pre_guest_traffic_gate")" "ready" \
    "pre guest traffic chardev gate"
  selftest_assert_file_not_contains "${call_log}" "primary.object_add_mirror"
  selftest_assert_file_not_contains "${call_log}" "primary.object_add_colo_compare"
  filter_line="$(grep -n '|primary.stop_before_filter_attach|' "${call_log}" | head -n1 | cut -d: -f1)"
  checkpoint_line="$(grep -n '|primary.migrate_set_parameters.pre_migrate|' "${call_log}" | head -n1 | cut -d: -f1)"
  incoming_line="$(grep -n '|secondary.migrate_incoming|' "${call_log}" | head -n1 | cut -d: -f1)"
  receiver_line="$(grep -n '|xcolo.pre_migrate_receiver|' "${call_log}" | head -n1 | cut -d: -f1)"
  migrate_line="$(grep -n '|primary.migrate|' "${call_log}" | head -n1 | cut -d: -f1)"
  [[ "${filter_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "primary filter attach gate must run before primary.migrate"
  [[ "${checkpoint_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "primary checkpoint delay gate must run before primary.migrate"
  [[ "${incoming_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "secondary migrate-incoming must run before primary.migrate"
  [[ "${incoming_line}" -lt "${receiver_line}" && "${receiver_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "pre-migrate receiver gate must run after migrate-incoming and before primary.migrate"
)

selftest_case_xcolo_multi_disk_handshake_exports_all_disks() (
  selftest_reset_env
  selftest_info "x-colo block handshake exports all mapped disks before primary migrate"

  local call_log="${SELFTEST_ROOT}/xcolo-multi-disk-handshake-order.log"
  local sda_export_line sdb_export_line incoming_line receiver_line migrate_line
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.0.0.2:10809"
  FTCTL_PROFILE_XCOLO_MIGRATE_URI="tcp:10.0.0.2:9998"
  FTCTL_PROFILE_XCOLO_NBD_NODE="nbd0"
  FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="2000"
  selftest_mock_xcolo_primary_channels_ready

  ftctl_state_set "primary-vm" \
    "xcolo_disk_sda_primary_base_node=libvirt-root-storage" \
    "xcolo_disk_sda_primary_base_qdev=scsi0-0-0-0" \
    "xcolo_disk_sda_primary_overlay=/tmp/primary-root-active.qcow2" \
    "xcolo_disk_sda_secondary_base_node=libvirt-root-format" \
    "xcolo_disk_sdb_primary_base_node=libvirt-data-storage" \
    "xcolo_disk_sdb_primary_base_qdev=scsi0-0-0-1" \
    "xcolo_disk_sdb_primary_overlay=/tmp/primary-data-active.qcow2" \
    "xcolo_disk_sdb_secondary_base_node=libvirt-data-format"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_capability_state() {
    if [[ "${3-}" == "return-path" ]]; then
      printf -v "$4" '%s' "no"
    else
      printf -v "$4" '%s' "yes"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_qmp() {
    local _uri="$1" _vm="$2" payload="$3" out_var="$4" rc_var="$5"
    : "${_uri}${_vm}"
    if [[ "${payload}" == *"query-chardev"* && "${_uri}" == *"qemu+ssh"* ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"label":"red0","frontend-open":true},{"label":"red1","frontend-open":true}]}'
    elif [[ "${payload}" == *"query-chardev"* ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"label":"mirror0","frontend-open":true},{"label":"compare1","frontend-open":true}]}'
    elif [[ "${payload}" == *"query-status"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"running":false,"status":"paused"}}'
    elif [[ "${payload}" == *"query-migrate-parameters"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"x-checkpoint-delay":2000}}'
    elif [[ "${payload}" == *"query-migrate-capabilities"* ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}'
    elif [[ "${payload}" == *"query-migrate"* && "${_uri}" == *"qemu+ssh"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"status":"colo"}}'
    elif [[ "${payload}" == *"query-migrate"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"status":"active"}}'
    elif [[ "${payload}" == *"query-colo-status"* && "${_uri}" == *"qemu+ssh"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"mode":"secondary"}}'
    elif [[ "${payload}" == *"query-colo-status"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"mode":"none"}}'
    else
      printf -v "${out_var}" '%s' '{"return":{}}'
    fi
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_socket_snapshot() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_secondary_startup_materialization_gate() {
    local vm="$1"
    ftctl_state_set "${vm}" "xcolo_secondary_startup_materialization=ok"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_pre_migrate_runtime_topology_gate() {
    local vm="$1"
    ftctl_state_set "${vm}" "xcolo_pre_migrate_topology_gate_state=ok"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_pre_migrate_receiver_ready() {
    local vm="$1"
    printf '%s|%s|%s|%s|%s\n' "colo" "xcolo.pre_migrate_receiver" "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" "mock" >> "${call_log}"
    ftctl_state_set "${vm}" "xcolo_pre_migrate_receiver_ready=ok"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_assert_no_premigrate_filter_mirror_send() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_gate_before_guest_traffic() {
    local vm="$1"
    ftctl_state_set "${vm}" "xcolo_pre_guest_traffic_gate=ready"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_activate_primary_filters_after_migrate() {
    local vm="$1"
    ftctl_state_set "${vm}" \
      "xcolo_primary_net_filters_activation_mode=startup-active" \
      "xcolo_primary_net_filters_activation_order=premigrate-active" \
      "xcolo_primary_net_filters_activated=true" \
      "xcolo_primary_filter_status_pre_migrate=on" \
      "xcolo_primary_filter_status_post_migrate=on"
    return 0
  }

  ftctl_xcolo_execute_handshake_with_disk_plan \
    "primary-vm" "standby-vm" \
    "sda|/dev/rbd/rbd/root|raw|block|/var/lib/libvirt/images/root;sdb|/dev/rbd/rbd/data|raw|block|/var/lib/libvirt/images/data"

  selftest_assert_file_contains "${call_log}" "secondary.nbd_server_add.sda"
  selftest_assert_file_contains "${call_log}" "secondary.nbd_server_add.sdb"
  selftest_assert_file_contains "${call_log}" "primary.blockdev_add.sda"
  selftest_assert_file_contains "${call_log}" "primary.blockdev_add.sdb"
  selftest_assert_file_contains "${call_log}" "primary.x_blockdev_change.sda"
  selftest_assert_file_contains "${call_log}" "primary.x_blockdev_change.sdb"
  selftest_assert_file_contains "${call_log}" '"node-name":"nbd0-sda"'
  selftest_assert_file_contains "${call_log}" '"node-name":"nbd0-sdb"'
  selftest_assert_file_contains "${call_log}" '"parent":"ftctl-colo-sda","node":"nbd0-sda"'
  selftest_assert_file_contains "${call_log}" '"parent":"ftctl-colo-sdb","node":"nbd0-sdb"'
  selftest_assert_file_contains "${call_log}" '"device":"libvirt-root-format"'
  selftest_assert_file_contains "${call_log}" '"device":"libvirt-data-format"'
  selftest_assert_file_contains "${call_log}" '"export":"libvirt-root-format"'
  selftest_assert_file_contains "${call_log}" '"export":"libvirt-data-format"'
  selftest_assert_file_contains "${call_log}" "secondary.migrate_incoming"
  selftest_assert_file_not_contains "${call_log}" '"export":"ftctl-colo-sda"'
  selftest_assert_file_not_contains "${call_log}" '"export":"ftctl-colo-sdb"'
  selftest_assert_file_not_contains "${call_log}" "primary.cont_before_migrate"
  selftest_assert_file_contains "${call_log}" "primary.migrate_set_parameters.pre_migrate"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_pre_guest_traffic_gate")" "ready" \
    "multi disk pre guest traffic chardev gate"
  sda_export_line="$(grep -n '|secondary.nbd_server_add.sda|' "${call_log}" | head -n1 | cut -d: -f1)"
  sdb_export_line="$(grep -n '|secondary.nbd_server_add.sdb|' "${call_log}" | head -n1 | cut -d: -f1)"
  incoming_line="$(grep -n '|secondary.migrate_incoming|' "${call_log}" | head -n1 | cut -d: -f1)"
  receiver_line="$(grep -n '|xcolo.pre_migrate_receiver|' "${call_log}" | head -n1 | cut -d: -f1)"
  migrate_line="$(grep -n '|primary.migrate|' "${call_log}" | head -n1 | cut -d: -f1)"
  [[ "${sda_export_line}" -lt "${migrate_line}" && "${sdb_export_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "all disk exports must be added before primary.migrate"
  [[ "${incoming_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "secondary migrate-incoming must run before primary.migrate"
  [[ "${incoming_line}" -lt "${receiver_line}" && "${receiver_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "pre-migrate receiver gate must run after migrate-incoming and before primary.migrate"
)

selftest_case_xcolo_staged_filter_activation_classifies_failed_step() (
  selftest_reset_env
  selftest_info "x-colo staged filter activation records the failed filter step"

  local vm="primary-vm"
  local call_log="${SELFTEST_ROOT}/xcolo-staged-filter-activation.log"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"

  # shellcheck disable=SC2317
  ftctl_xcolo_require_primary_filter_qom_ready() {
    local vm="${1-}" phase="${2-}" expected="${3-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_qom_ready=yes" \
      "xcolo_primary_filter_qom_reason=" \
      "xcolo_primary_filter_qom_phase=${phase}" \
      "xcolo_primary_filter_qom_expected=${expected}"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}" step
    step="$(ftctl_state_get "${vm}" "xcolo_filter_activation_step" 2>/dev/null || true)"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" && "${step}" == "m0" ]]; then
      printf -v "${out_var}" '%s' "failed"
    elif [[ "${uri}" == "${FTCTL_PROFILE_SECONDARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "colo"
    else
      printf -v "${out_var}" '%s' "active"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_error_desc() {
    local out_var="${3}" step
    step="$(ftctl_state_get "${vm}" "xcolo_filter_activation_step" 2>/dev/null || true)"
    if [[ "${step}" == "m0" ]]; then
      printf -v "${out_var}" '%s' "Received invalid message 0x0000 length 0x0000"
    else
      printf -v "${out_var}" '%s' ""
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_SECONDARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "secondary"
    else
      printf -v "${out_var}" '%s' "none"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_primary_channel_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_channel_mirror_established=yes" \
      "xcolo_channel_compare_established=yes" \
      "xcolo_channel_compare_local_established=yes" \
      "xcolo_channel_compare_out_established=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_chardev_binding_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" "xcolo_primary_filter_chardev_ready=yes" "xcolo_primary_filter_chardev_reason="
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_socket_snapshot() {
    return 0
  }

  ftctl_state_set "${vm}" \
    "xcolo_post_migrate_pre_activation_primary_migrate_status=active" \
    "xcolo_post_migrate_pre_activation_secondary_migrate_status=active" \
    "xcolo_post_migrate_pre_activation_primary_colo_mode=none" \
    "xcolo_post_migrate_pre_activation_secondary_colo_mode=none" \
    "xcolo_post_migrate_pre_activation_primary_migrate_error_desc=" \
    "xcolo_post_migrate_pre_activation_secondary_migrate_error_desc=" \
    "xcolo_post_migrate_pre_activation_invalid_message=no" \
    "xcolo_channel_mirror_established=yes" \
    "xcolo_channel_compare_established=yes" \
    "xcolo_channel_compare_local_established=yes" \
    "xcolo_channel_compare_out_established=yes" \
    "xcolo_primary_filter_chardev_ready=no" \
    "xcolo_primary_filter_chardev_reason=mirror0:frontend_closed"

  if ftctl_xcolo_activate_primary_net_filters "${vm}" "selftest" "${vm}-standby"; then
    selftest_fail "staged filter activation should fail when m0 breaks the COLO stream"
  fi

  selftest_assert_file_contains "${call_log}" "primary.filter_status_on.redire1"
  selftest_assert_file_contains "${call_log}" "primary.filter_status_on.m0"
  selftest_assert_file_not_contains "${call_log}" "primary.filter_status_on.redire0"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_net_filters_activation_order")" "redire1,m0,redire0" \
    "staged activation order recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_filter_activation_failed_step")" "m0" \
    "failed activation step recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_protocol_failure_phase")" "filter_activation_m0" \
    "failed activation phase recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "xcolo_filter_activation_m0_broke_colo_stream" \
    "failed activation last_error recorded"
)

selftest_case_xcolo_fast_redire1_gate_allows_secondary_active() (
  selftest_reset_env
  selftest_info "x-colo fast pre-redire1 gate allows secondary active from cached post-migrate state"

  local vm="primary-vm"
  local call_log="${SELFTEST_ROOT}/xcolo-fast-pre-redire1-gate.log"
  : > "${call_log}"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"

  # shellcheck disable=SC2317
  ftctl_xcolo_require_primary_filter_qom_ready() {
    local vm="${1-}"
    ftctl_state_set "${vm}" "xcolo_primary_filter_qom_ready=yes" "xcolo_primary_filter_qom_reason="
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_SECONDARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "active"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_error_desc() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' ""
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_SECONDARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "none"
    fi
    return 0
  }

  ftctl_state_set "${vm}" \
    "xcolo_post_migrate_pre_activation_primary_migrate_status=active" \
    "xcolo_post_migrate_pre_activation_secondary_migrate_status=active" \
    "xcolo_post_migrate_pre_activation_primary_colo_mode=none" \
    "xcolo_post_migrate_pre_activation_secondary_colo_mode=none" \
    "xcolo_post_migrate_pre_activation_primary_migrate_error_desc=" \
    "xcolo_post_migrate_pre_activation_secondary_migrate_error_desc=" \
    "xcolo_post_migrate_pre_activation_invalid_message=no" \
    "xcolo_channel_mirror_established=yes" \
    "xcolo_channel_compare_established=yes" \
    "xcolo_channel_compare_local_established=yes" \
    "xcolo_channel_compare_out_established=yes" \
    "xcolo_primary_filter_chardev_ready=no" \
    "xcolo_primary_filter_chardev_reason=mirror0:frontend_closed"

  ftctl_xcolo_activate_primary_net_filters "${vm}" "selftest" "${vm}-standby"

  selftest_assert_file_contains "${call_log}" "primary.filter_status_on.redire1"
  selftest_assert_file_contains "${call_log}" "primary.filter_status_on.m0"
  selftest_assert_file_contains "${call_log}" "primary.filter_status_on.redire0"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_redire1_gate")" "ready" \
    "fast pre-redire1 gate should pass from cached post-migrate state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_redire1_gate_mode")" "fast_cached_post_migrate" \
    "fast pre-redire1 gate mode recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_redire1_secondary_migrate_status")" "active" \
    "fast pre-redire1 gate accepts secondary active"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_redire1_strict_chardev_deferred")" "yes" \
    "strict chardev readiness is deferred before redire1"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_net_filters_activation_order")" "redire1,m0,redire0" \
    "filter activation order remains staged"
)

selftest_case_xcolo_primary_filter_binding_defers_to_runtime_validation() (
  selftest_reset_env
  selftest_info "x-colo primary filter binding is observed before migrate and deferred to runtime validation"

  local call_log="${SELFTEST_ROOT}/xcolo-filter-binding-defers-runtime.log"
  local rc=0
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.0.0.2:10809"
  FTCTL_PROFILE_XCOLO_MIGRATE_URI="tcp:10.0.0.2:9998"
  FTCTL_PROFILE_XCOLO_NBD_NODE="nbd0"
  FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="2000"
  FTCTL_XCOLO_FILTER_BIND_WAIT_SEC="1"
  FTCTL_XCOLO_FILTER_BIND_INTERVAL_SEC="1"
  selftest_mock_xcolo_primary_channels_ready

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_capability_state() {
    printf -v "$4" '%s' "yes"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_qmp() {
    local _uri="$1" _vm="$2" payload="$3" out_var="$4" rc_var="$5"
    : "${_uri}${_vm}"
    if [[ "${payload}" == *"query-migrate-parameters"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"x-checkpoint-delay":2000}}'
    elif [[ "${payload}" == *"query-migrate-capabilities"* ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}'
    elif [[ "${payload}" == *"query-migrate"* && "${_uri}" == *"qemu+ssh"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"status":"colo"}}'
    elif [[ "${payload}" == *"query-migrate"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"status":"active"}}'
    elif [[ "${payload}" == *"query-colo-status"* && "${_uri}" == *"qemu+ssh"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"mode":"secondary"}}'
    elif [[ "${payload}" == *"query-colo-status"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"mode":"none"}}'
    else
      printf -v "${out_var}" '%s' '{"return":{}}'
    fi
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_observe_primary_filter_chardev_binding() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_chardev_ready=no" \
      "xcolo_primary_filter_chardev_reason=mirror0:frontend_closed,compare0:frontend_closed" \
      "xcolo_primary_filter_chardev_binding_deferred_reason=mirror0:frontend_closed,compare0:frontend_closed"
    ftctl_log_event "colo" "primary.filter_chardev_binding" "defer" "${vm}" "" \
      "reason=mirror0:frontend_closed,compare0:frontend_closed attempts=1 phase=pre_cont"
    return 0
  }

  ftctl_xcolo_execute_handshake_with_nodes "primary-vm" "standby-vm" "parent0" || rc=$?

  selftest_assert_eq "${rc}" "0" "pre-cont incomplete primary filter binding should not block migrate"
  selftest_assert_file_contains "${call_log}" "primary.stop_before_filter_attach"
  selftest_assert_file_not_contains "${call_log}" "primary.cont_before_migrate"
  selftest_assert_file_contains "${call_log}" "primary.migrate"
)

selftest_case_xcolo_premigrate_chardev_binding_accepts_listener_endpoints() (
  selftest_reset_env
  selftest_info "x-colo pre-migrate chardev binding accepts listener-backed closed frontends"

  local vm="xcolo-premigrate-chardev-binding"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  ftctl_state_set "${vm}" \
    "xcolo_channel_mirror_established=no" \
    "xcolo_channel_mirror_listen=yes" \
    "xcolo_channel_compare_established=no" \
    "xcolo_channel_compare_listen=yes" \
    "xcolo_channel_compare_out_established=yes"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp() {
    local out_var="${4}" rc_var="${5}"
    printf -v "${out_var}" '%s' '{"return":[{"label":"mirror0","frontend-open":false},{"label":"compare1","frontend-open":true},{"label":"compare0","frontend-open":false},{"label":"compare0-0","frontend-open":true},{"label":"compare_out","frontend-open":true},{"label":"compare_out0","frontend-open":false}]}'
    printf -v "${rc_var}" '%s' "0"
    return 0
  }

  ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" "pre_migrate" || rc=$?
  selftest_assert_eq "${rc}" "0" "pre-migrate listener-backed chardev binding should pass"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_ready")" \
    "yes" "pre-migrate chardev binding ready"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_chardev_mirror0")" \
    "accepted_closed" "mirror listener endpoint should be accepted"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_chardev_compare0")" \
    "accepted_closed" "compare listener endpoint should be accepted"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_chardev_compare_out0")" \
    "accepted_closed" "compare out loopback endpoint should be accepted"
)

selftest_case_xcolo_strict_chardev_binding_rejects_closed_frontends() (
  selftest_reset_env
  selftest_info "x-colo strict chardev binding still rejects closed frontends"

  local vm="xcolo-strict-chardev-binding"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  ftctl_state_set "${vm}" \
    "xcolo_channel_mirror_established=yes" \
    "xcolo_channel_mirror_listen=yes" \
    "xcolo_channel_compare_established=yes" \
    "xcolo_channel_compare_listen=yes" \
    "xcolo_channel_compare_out_established=yes"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp() {
    local out_var="${4}" rc_var="${5}"
    printf -v "${out_var}" '%s' '{"return":[{"label":"mirror0","frontend-open":false},{"label":"compare1","frontend-open":true},{"label":"compare0","frontend-open":false},{"label":"compare0-0","frontend-open":true},{"label":"compare_out","frontend-open":true},{"label":"compare_out0","frontend-open":false}]}'
    printf -v "${rc_var}" '%s' "0"
    return 0
  }

  ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" || rc=$?
  selftest_assert_eq "${rc}" "1" "strict chardev binding should still fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_ready")" \
    "no" "strict chardev binding not ready"
  selftest_assert_contains "$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_reason")" \
    "mirror0:frontend_closed" "strict reason should include mirror0"
)

selftest_case_xcolo_virtio_vnet_hdr_support() (
  selftest_reset_env
  selftest_info "x-colo virtio net model enables vnet header support"

  local vm="ft-virtio-vnet"
  ftctl_state_set "${vm}" \
    "xcolo_primary_netdev_model=virtio" \
    "xcolo_secondary_netdev_model=virtio" \
    "xcolo_primary_netdev_id=hostnet0" \
    "xcolo_secondary_netdev_id=hostnet0"

  local primary_args secondary_args
  primary_args="$(ftctl_xcolo_build_primary_qemu_args "hostnet0" "${vm}")"
  secondary_args="$(ftctl_xcolo_build_secondary_qemu_args "hostnet0" "${vm}")"

  selftest_assert_contains "${primary_args}" "filter-mirror,id=m0,netdev=hostnet0,queue=tx,outdev=mirror0,insert=behind,position=tail,vnet_hdr_support=on" "primary mirror vnet hdr"
  selftest_assert_contains "${primary_args}" "filter-redirector,id=redire0,netdev=hostnet0,queue=rx,indev=compare_out,insert=behind,position=tail,vnet_hdr_support=on" "primary redirector in vnet hdr"
  selftest_assert_contains "${primary_args}" "filter-redirector,id=redire1,netdev=hostnet0,queue=rx,outdev=compare0,insert=behind,position=tail,vnet_hdr_support=on" "primary redirector out vnet hdr"
  selftest_assert_not_contains "${primary_args}" "status=off" "primary filters must start active"
  selftest_assert_contains "${primary_args}" "socket,id=mirror0,host=0.0.0.0,port=9003,server=on,wait=off" "primary mirror listener wait off"
  selftest_assert_contains "${primary_args}" "socket,id=compare1,host=0.0.0.0,port=9004,server=on,wait=off" "primary compare listener wait off"
  selftest_assert_not_contains "${primary_args}" "socket,id=mirror0,host=0.0.0.0,port=9003,server=on,wait=on" "primary mirror listener must not block"
  selftest_assert_not_contains "${primary_args}" "socket,id=compare1,host=0.0.0.0,port=9004,server=on,wait=on" "primary compare listener must not block"
  selftest_assert_contains "${primary_args}" "colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0,iothread=iothread1,vnet_hdr_support=on" "primary compare vnet hdr"
  selftest_assert_contains "${secondary_args}" "filter-redirector,id=f1,netdev=hostnet0,queue=tx,indev=red0,vnet_hdr_support=on" "secondary tx redirector vnet hdr"
  selftest_assert_contains "${secondary_args}" "filter-redirector,id=f2,netdev=hostnet0,queue=rx,outdev=red1,vnet_hdr_support=on" "secondary rx redirector vnet hdr"
  selftest_assert_contains "${secondary_args}" "filter-rewriter,id=rew0,netdev=hostnet0,queue=all,vnet_hdr_support=on" "secondary rewriter vnet hdr"
  selftest_assert_contains "${secondary_args}" "-incoming;defer" "secondary incoming starts deferred"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support")" "on" "vnet hdr state"
)

selftest_case_xcolo_storage_mismatch_gate() (
  selftest_reset_env
  selftest_info "x-colo blocks storage backend mismatch by default"

  local vm="ft-storage-mismatch"
  ftctl_state_set "${vm}" \
    "xcolo_storage_symmetry=warning" \
    "xcolo_storage_symmetry_reason=sda:primary_block/raw_secondary_file/qcow2" \
    "xcolo_storage_primary_layouts=sda:block/raw" \
    "xcolo_storage_secondary_layouts=sda:file/qcow2"

  local rc=0
  ftctl_xcolo_require_storage_symmetry "${vm}" || rc=$?
  selftest_assert_eq "${rc}" "1" "storage mismatch gate return"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "xcolo_storage_backend_mismatch" "storage mismatch error"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "conversion_stage")" "storage_compatibility_failed" "storage mismatch stage"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_storage_compatibility")" "blocked" "storage mismatch compatibility"
)

selftest_case_xcolo_storage_qcow2_to_librbd_allowed() (
  selftest_reset_env
  selftest_info "x-colo allows file-backed qcow2 primary to RBD secondary with librbd runtime"

  local vm="ft-qcow2-to-rbd"
  local plan="sda|/var/lib/libvirt/images/${vm}.qcow2|qcow2|file|/dev/rbd/rbd/${vm}-standby"
  FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND="librbd"

  ftctl_xcolo_record_storage_symmetry "${vm}" "${plan}"
  ftctl_xcolo_require_storage_symmetry "${vm}"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_storage_symmetry")" "ok" "qcow2 to librbd symmetry"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_storage_compatibility")" "mixed_file_qcow2_to_librbd_rbd" "qcow2 to librbd compatibility"
  selftest_assert_contains "$(ftctl_state_get "${vm}" "xcolo_storage_compatibility_reason")" "sda:mixed_file_qcow2_to_librbd_rbd" "qcow2 to librbd compatibility reason"
)

selftest_case_xcolo_machine_contract_gate() (
  selftest_reset_env
  selftest_info "x-colo rejects q35 and accepts pc-i440fx machine contracts"

  local vm="ft-machine-contract"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}" err_var="${3}" rc_var="${4}"
    shift 4
    [[ "${1-}" == "--" ]] && shift
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    case "$*" in
      *"dumpxml ${vm}"*)
        printf -v "${out_var}" '%s' "<domain type='kvm'><os><type arch='x86_64' machine='q35'>hvm</type></os></domain>"
        ;;
      *)
        printf -v "${out_var}" '%s' ""
        ;;
    esac
  }

  local rc=0
  ftctl_xcolo_require_supported_machine_contract "${vm}" || rc=$?
  selftest_assert_eq "${rc}" "1" "q35 machine contract should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "ft_machine_type_supported")" "no" "q35 machine supported state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "ft_unsupported_machine_type" "q35 machine error"

  ftctl_state_init_vm "${vm}"
  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}" err_var="${3}" rc_var="${4}"
    shift 4
    [[ "${1-}" == "--" ]] && shift
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    case "$*" in
      *"dumpxml ${vm}"*)
        printf -v "${out_var}" '%s' "<domain type='kvm'><os><type arch='x86_64' machine='pc-i440fx-9.2'>hvm</type></os></domain>"
        ;;
      *)
        printf -v "${out_var}" '%s' ""
        ;;
    esac
  }

  rc=0
  ftctl_xcolo_require_supported_machine_contract "${vm}" || rc=$?
  selftest_assert_eq "${rc}" "0" "pc-i440fx machine contract should pass"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "ft_machine_type_supported")" "yes" "pc-i440fx machine supported state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "ft_machine_type_effective")" "pc-i440fx-9.2" "pc-i440fx effective machine"
)

selftest_case_xcolo_filter_qom_hard_gate() (
  selftest_reset_env
  selftest_info "x-colo primary filter QOM topology is a hard pre-migrate gate"

  local vm="primary-vm"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  ftctl_state_set "${vm}" "xcolo_primary_netdev_id=hostnet0"

  # shellcheck disable=SC2317
  ftctl_xcolo_qom_list_names() {
    local path="${3-}" out_var="${4-}"
    case "${path}" in
      /objects)
        printf -v "${out_var}" '%s\n' "type" "m0" "redire0" "redire1" "comp0"
        ;;
      /objects/m0)
        printf -v "${out_var}" '%s\n' "netdev" "queue" "outdev" "status" "insert" "position"
        ;;
      /objects/redire0)
        printf -v "${out_var}" '%s\n' "netdev" "queue" "indev" "outdev" "status" "insert" "position"
        ;;
      /objects/redire1)
        printf -v "${out_var}" '%s\n' "netdev" "queue" "indev" "outdev" "status" "insert" "position"
        ;;
      /objects/comp0)
        printf -v "${out_var}" '%s\n' "primary_in" "secondary_in" "outdev" "iothread"
        ;;
      *)
        printf -v "${out_var}" '%s' ""
        return 1
        ;;
    esac
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_qom_get_property() {
    local path="${3-}" prop="${4-}" out_var="${5-}" prop_value=""
    case "${path}:${prop}" in
      /objects/m0:netdev|/objects/redire0:netdev|/objects/redire1:netdev) prop_value="hostnet0" ;;
      /objects/m0:queue) prop_value="tx" ;;
      /objects/redire0:queue|/objects/redire1:queue) prop_value="rx" ;;
      /objects/m0:outdev) prop_value="mirror0" ;;
      /objects/redire0:indev) prop_value="compare_out" ;;
      /objects/redire0:outdev|/objects/redire1:indev) prop_value="" ;;
      /objects/redire1:outdev) prop_value="compare0" ;;
      /objects/m0:status|/objects/redire0:status|/objects/redire1:status) prop_value="on" ;;
      /objects/m0:insert|/objects/redire0:insert|/objects/redire1:insert) prop_value="behind" ;;
      /objects/m0:position|/objects/redire0:position|/objects/redire1:position) prop_value="tail" ;;
      /objects/comp0:primary_in) prop_value="compare0-0" ;;
      /objects/comp0:secondary_in) prop_value="compare1" ;;
      /objects/comp0:outdev) prop_value="compare_out0" ;;
      /objects/comp0:iothread) prop_value="iothread1" ;;
      *) return 1 ;;
    esac
    printf -v "${out_var}" '%s' "${prop_value}"
  }

  ftctl_xcolo_require_primary_filter_qom_ready "${vm}" "selftest"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_ready")" \
    "yes" "QOM topology ready"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_m0_path")" \
    "/objects/m0" "m0 path discovered"

  # shellcheck disable=SC2317
  ftctl_xcolo_qom_list_names() {
    local path="${3-}" out_var="${4-}"
    case "${path}" in
      /objects)
        printf -v "${out_var}" '%s\n' "type" "m0" "redire0" "redire1"
        ;;
      *)
        printf -v "${out_var}" '%s' ""
        return 1
        ;;
    esac
  }

  if ftctl_xcolo_require_primary_filter_qom_ready "${vm}" "selftest-missing"; then
    selftest_fail "missing comp0 must block pre-migrate QOM gate"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "primary_filter_qom_topology_missing" "missing QOM topology error"
)

selftest_case_xcolo_primary_filter_qmp_order_matches_qemu_doc() (
  selftest_reset_env
  selftest_info "x-colo primary QMP filter attach follows QEMU documented order"

  local vm="primary-vm"
  local call_log="${SELFTEST_ROOT}/xcolo-primary-filter-qmp-order.log"
  local mirror_line redire0_line redire1_line comp0_line
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  ftctl_state_set "${vm}" "xcolo_primary_netdev_id=hostnet0"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_optional() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok_or_exists() {
    local event="${5-}"
    printf '%s\n' "${event}" >> "${call_log}"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_chardev_binding_state() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_require_primary_filter_qom_ready() {
    return 0
  }

  ftctl_xcolo_primary_net_filters_qmp_attach_objects "${vm}" "selftest"

  mirror_line="$(grep -n '^primary.object_add_filter_mirror$' "${call_log}" | head -n1 | cut -d: -f1)"
  redire0_line="$(grep -n '^primary.object_add_redirector_in$' "${call_log}" | head -n1 | cut -d: -f1)"
  redire1_line="$(grep -n '^primary.object_add_redirector_out$' "${call_log}" | head -n1 | cut -d: -f1)"
  comp0_line="$(grep -n '^primary.object_add_colo_compare$' "${call_log}" | head -n1 | cut -d: -f1)"

  [[ -n "${mirror_line}" && -n "${redire0_line}" && -n "${redire1_line}" && -n "${comp0_line}" ]] || \
    selftest_fail "all primary QMP filter object-add events must be present"
  [[ "${mirror_line}" -lt "${redire0_line}" &&
     "${redire0_line}" -lt "${redire1_line}" &&
     "${redire1_line}" -lt "${comp0_line}" ]] || \
    selftest_fail "primary QMP filter object-add order must be m0 redire0 redire1 comp0"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_filter_qmp_attach_order")" \
    "qemu-doc-primary" "primary QMP filter attach order marker"
)

selftest_case_xcolo_primary_netdev_vhost_guard() (
  selftest_reset_env
  selftest_info "x-colo primary runtime rejects vhost-backed netdev"

  local vm="xcolo-vhost-guard"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_primary_netdev_id=hostnet0"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"

  # shellcheck disable=SC2317
  ftctl_cmd_run() {
    local timeout_sec="${1-}" out_var="${2-}" err_var="${3-}" rc_var="${4-}"
    : "${timeout_sec}"
    printf -v "${out_var}" '%s' '-name guest=xcolo-vhost-guard -netdev {"type":"tap","fd":"51","vhost":true,"vhostfd":"57","id":"hostnet0"}'
    printf -v "${err_var}" '%s' ''
    printf -v "${rc_var}" '%s' '0'
  }

  ftctl_xcolo_require_primary_netdev_vhost_off "${vm}" || rc=$?
  selftest_assert_eq "${rc}" "1" "vhost guard should reject vhost-enabled netdev"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_netdev_vhost")" "on" "vhost state on"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "primary_netdev_vhost_enabled" "vhost guard error"

  rc=0
  ftctl_state_set "${vm}" "last_error="
  # shellcheck disable=SC2317
  ftctl_cmd_run() {
    local timeout_sec="${1-}" out_var="${2-}" err_var="${3-}" rc_var="${4-}"
    : "${timeout_sec}"
    printf -v "${out_var}" '%s' '-name guest=xcolo-vhost-guard -netdev {"type":"tap","fd":"51","id":"hostnet0"}'
    printf -v "${err_var}" '%s' ''
    printf -v "${rc_var}" '%s' '0'
  }

  ftctl_xcolo_require_primary_netdev_vhost_off "${vm}" || rc=$?
  selftest_assert_eq "${rc}" "0" "vhost guard should accept qemu userspace netdev"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_netdev_vhost")" "off" "vhost state off"
)

selftest_case_xcolo_baseline_seed_uses_primary_nbd_before_runtime_graph() (
  selftest_reset_env
  selftest_info "x-colo block cold conversion seeds secondary baseline over primary read-only NBD"

  local call_log="${SELFTEST_ROOT}/xcolo-baseline-seed.log"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_FENCING_SSH_USER="root"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.0.0.2:10809"
  FTCTL_REMOTE_NBD_PORT_BASE="10809"
  FTCTL_REMOTE_NBD_PORT_COUNT="64"
  FTCTL_XCOLO_QMP_TIMEOUT_SEC="3"

  # shellcheck disable=SC2317
  ftctl_xcolo_primary_connect_host() {
    printf '%s\n' "10.0.0.1"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() {
    printf -v "$1" '%s' "10.0.0.2"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_krbd_map_local() {
    printf 'MAP:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_cmd_run() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4" pid_file="" arg prev=""
    shift 4
    [[ "${1-}" == "--" ]] && shift
    printf 'LOCAL:%s\n' "$*" >> "${call_log}"
    for arg in "$@"; do
      if [[ "${prev}" == "--pid-file" ]]; then
        pid_file="${arg}"
        break
      fi
      prev="${arg}"
    done
    [[ -n "${pid_file}" ]] && printf '999999\n' > "${pid_file}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" remote_cmd="$6"
    printf 'REMOTE:%s\n' "${remote_cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' "format=qcow2 virtual=12345 actual=4096"
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_xcolo_seed_secondary_baseline_disk \
    "primary-vm" "sda" "/dev/rbd/rbd/root" "raw" "/var/lib/libvirt/images/root.qcow2" "12345"

  selftest_assert_file_contains "${call_log}" "qemu-nbd"
  selftest_assert_file_contains "${call_log}" "--read-only"
  selftest_assert_file_contains "${call_log}" "MAP:/dev/rbd/rbd/root"
  selftest_assert_file_contains "${call_log}" "qemu-img info --force-share --output=json /dev/rbd/rbd/root"
  selftest_assert_file_contains "${call_log}" "--export-name ftctl-xcolo-seed-primary-vm-sda"
  selftest_assert_file_contains "${call_log}" "qemu-img convert -p"
  selftest_assert_file_contains "${call_log}" "nbd://10.0.0.1:"
  selftest_assert_file_contains "${call_log}" "ftctl-xcolo-seed-primary-vm-sda"
  selftest_assert_file_contains "${call_log}" "mv -f --"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_disk_sda_baseline_seeded")" "true" \
    "baseline seed state"
)

selftest_case_xcolo_libvirt_qemu_identity_avoids_local_name_collision() (
  selftest_reset_env
  selftest_info "x-colo libvirt qemu identity returns values to same-named caller locals"

  local qemu_user="" qemu_group="" rc=0
  local missing_user="" missing_group="" missing_rc=0

  # shellcheck disable=SC2317
  getent() {
    case "${1-}:${2-}" in
      passwd:qemu|group:qemu) return 0 ;;
      *) return 1 ;;
    esac
  }
  # shellcheck disable=SC2317
  id() {
    if [[ "${1-}" == "-gn" && "${2-}" == "qemu" ]]; then
      printf '%s\n' "qemu"
      return 0
    fi
    return 1
  }

  FTCTL_LIBVIRT_QEMU_USER="qemu"
  FTCTL_LIBVIRT_QEMU_GROUP="qemu"
  ftctl_xcolo_libvirt_qemu_identity qemu_user qemu_group || rc=$?
  selftest_assert_eq "${rc}" "0" "qemu identity should resolve"
  selftest_assert_eq "${qemu_user}" "qemu" "same-named caller qemu_user should be populated"
  selftest_assert_eq "${qemu_group}" "qemu" "same-named caller qemu_group should be populated"

  # shellcheck disable=SC2317
  getent() {
    return 1
  }
  missing_rc=0
  FTCTL_LIBVIRT_QEMU_USER="missing-user"
  FTCTL_LIBVIRT_QEMU_GROUP="missing-group"
  ftctl_xcolo_libvirt_qemu_identity missing_user missing_group || missing_rc=$?
  selftest_assert_eq "${missing_rc}" "1" "missing qemu identity should fail"
  selftest_assert_eq "${missing_user}" "" "missing qemu user should stay empty"
  selftest_assert_eq "${missing_group}" "" "missing qemu group should stay empty"
)

selftest_case_xcolo_primary_parent_nbd_qemu_user_probe() (
  selftest_reset_env
  selftest_info "x-colo primary parent NBD adapter is probed with the libvirt qemu user"

  local vm="i-2-test-VM" call_log="${SELFTEST_ROOT}/xcolo-parent-nbd-qemu-user.log"
  local fakebin="${SELFTEST_ROOT}/fakebin"
  local rc=0
  mkdir -p "${fakebin}"
  printf '#!/bin/sh\nexit 0\n' > "${fakebin}/qemu-img"
  printf '#!/bin/sh\nexit 0\n' > "${fakebin}/runuser"
  chmod +x "${fakebin}/qemu-img" "${fakebin}/runuser"
  PATH="${fakebin}:${PATH}"
  ftctl_state_init_vm "${vm}"

  # shellcheck disable=SC2317
  ftctl_xcolo_libvirt_qemu_identity() {
    printf -v "$1" '%s' "qemu"
    printf -v "$2" '%s' "qemu"
  }
  # shellcheck disable=SC2317
  ftctl_cmd_run() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
    shift 4
    [[ "${1-}" == "--" ]] && shift
    : "${_timeout}"
    printf 'CMD:%s\n' "$*" >> "${call_log}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_xcolo_probe_parent_nbd_as_qemu_user \
    "${vm}" "sda" "/run/ablestack-vm-ftctl/xcolo-parent-nbd/${vm}/sda.sock" "ftctl-primary-parent-sda"
  selftest_assert_file_contains "${call_log}" "runuser -u qemu -- qemu-img info --force-share nbd+unix:///ftctl-primary-parent-sda?socket=/run/ablestack-vm-ftctl/xcolo-parent-nbd/${vm}/sda.sock"

  # shellcheck disable=SC2317
  ftctl_cmd_run() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
    shift 4
    [[ "${1-}" == "--" ]] && shift
    : "${_timeout}"
    printf 'FAILCMD:%s\n' "$*" >> "${call_log}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' "Permission denied"
    printf -v "${rc_var}" '%s' "1"
  }

  ftctl_xcolo_probe_parent_nbd_as_qemu_user \
    "${vm}" "sda" "/run/ablestack-vm-ftctl/xcolo-parent-nbd/${vm}/sda.sock" "ftctl-primary-parent-sda" || rc=$?
  selftest_assert_eq "${rc}" "1" "qemu-user parent NBD probe failure should fail hard"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "xcolo_primary_parent_nbd_permission_failed" \
    "qemu-user parent NBD probe last_error"
)

selftest_case_xcolo_baseline_seed_maps_cloud_managed_rbd() (
  selftest_reset_env
  selftest_info "x-colo baseline seed maps cloud-managed secondary RBD targets"

  local call_log="${SELFTEST_ROOT}/xcolo-baseline-seed-cloud-rbd.log"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_FENCING_SSH_USER="root"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_XCOLO_QMP_TIMEOUT_SEC="3"

  # shellcheck disable=SC2317
  ftctl_xcolo_primary_connect_host() {
    printf '%s\n' "10.0.0.1"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() {
    printf -v "$1" '%s' "10.0.0.2"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_krbd_map_local() {
    printf 'MAP:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_cmd_run() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4" pid_file="" arg prev=""
    shift 4
    [[ "${1-}" == "--" ]] && shift
    printf 'LOCAL:%s\n' "$*" >> "${call_log}"
    for arg in "$@"; do
      if [[ "${prev}" == "--pid-file" ]]; then
        pid_file="${arg}"
        break
      fi
      prev="${arg}"
    done
    [[ -n "${pid_file}" ]] && printf '999999\n' > "${pid_file}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" remote_cmd="$6"
    printf 'REMOTE:%s\n' "${remote_cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' "format=raw virtual=12345 actual=4096"
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_xcolo_seed_secondary_baseline_disk \
    "primary-vm" "sda" "/dev/rbd/rbd/root" "raw" "/dev/rbd/rbd/secondary-root" "12345"

  selftest_assert_file_contains "${call_log}" "provisioning_backend=cloud-managed"
  selftest_assert_file_contains "${call_log}" "rbd map"
  selftest_assert_file_contains "${call_log}" "rbd/secondary-root"
  selftest_assert_file_contains "${call_log}" "baseline_rbd_map_failed"
  selftest_assert_file_contains "${call_log}" "baseline_rbd_device_missing"
  selftest_assert_file_contains "${call_log}" "rbd unmap"
  selftest_assert_file_contains "${call_log}" 'qemu-img convert -p -f "${source_format}" -O "${target_format}" "${src_uri}" "${seed_dest}"'
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_disk_sda_baseline_seeded")" "true" \
    "cloud-managed RBD baseline seed state"
)

selftest_case_xcolo_secondary_runtime_maps_cloud_managed_rbd() (
  selftest_reset_env
  selftest_info "x-colo secondary runtime maps cloud-managed RBD targets"

  local call_log="${SELFTEST_ROOT}/xcolo-secondary-runtime-rbd.log"
  local xml_path="${SELFTEST_ROOT}/standby.generated.xml"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_FENCING_SSH_USER="root"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND="krbd"

  cat > "${xml_path}" <<EOF
<domain type="kvm">
  <name>standby-vm</name>
  <devices>
    <disk type="block" device="disk">
      <source dev="/dev/rbd/rbd/secondary-root"/>
      <target dev="sda" bus="virtio"/>
    </disk>
    <disk type="block" device="disk">
      <source dev="/dev/rbd/rbd/secondary-data"/>
      <target dev="sdb" bus="virtio"/>
    </disk>
  </devices>
</domain>
EOF

  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() {
    printf -v "$1" '%s' "10.0.0.2"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" remote_cmd="$6"
    printf 'REMOTE:%s\n' "${remote_cmd}" >> "${call_log}"
    case "${remote_cmd}" in
      *"dest=/dev/rbd/rbd/secondary-root"*)
        printf -v "${out_var}" '%s' "sda|/dev/rbd/rbd/secondary-root|/dev/rbd14|1"
        ;;
      *"dest=/dev/rbd/rbd/secondary-data"*)
        printf -v "${out_var}" '%s' "sdb|/dev/rbd/rbd/secondary-data|/dev/rbd15|1"
        ;;
      *"device=/dev/rbd/rbd/secondary-root"*|*"device=/dev/rbd/rbd/secondary-data"*)
        printf -v "${out_var}" '%s' ""
        ;;
      *)
        printf -v "${out_var}" '%s' ""
        ;;
    esac
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_xcolo_prepare_secondary_runtime_rbd "primary-vm" "${xml_path}" \
    "sda|/dev/rbd/rbd/root|raw|block|/dev/rbd/rbd/secondary-root;sdb|/dev/rbd/rbd/data|raw|block|/dev/rbd/rbd/secondary-data"

  selftest_assert_file_contains "${xml_path}" "/dev/rbd/rbd/secondary-root"
  selftest_assert_file_contains "${xml_path}" "/dev/rbd/rbd/secondary-data"
  selftest_assert_file_not_contains "${xml_path}" "/dev/rbd14"
  selftest_assert_file_not_contains "${xml_path}" "/dev/rbd15"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_secondary_runtime_rbd_sda")" \
    "/dev/rbd/rbd/secondary-root|/dev/rbd14|1" "sda runtime RBD state"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_secondary_runtime_rbd_sdb")" \
    "/dev/rbd/rbd/secondary-data|/dev/rbd15|1" "sdb runtime RBD state"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_secondary_runtime_rbd_stable_sda")" \
    "/dev/rbd/rbd/secondary-root" "sda stable RBD state"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_secondary_runtime_rbd_resolved_sda")" \
    "/dev/rbd14" "sda resolved RBD diagnostic"
  selftest_assert_eq "$(ftctl_xcolo_secondary_runtime_disk_source "primary-vm" "sda" "/dev/rbd/rbd/secondary-root")" \
    "/dev/rbd/rbd/secondary-root" "sda runtime source lookup keeps stable path"

  ftctl_xcolo_unmap_secondary_runtime_rbd "primary-vm"
  selftest_assert_file_contains "${call_log}" "rbd unmap"
  selftest_assert_file_contains "${call_log}" "device=/dev/rbd/rbd/secondary-root"
  selftest_assert_file_contains "${call_log}" "device=/dev/rbd/rbd/secondary-data"
)

selftest_case_xcolo_stable_rbd_contract_remaps_cloud_paths() (
  selftest_reset_env
  selftest_info "x-colo stable RBD contract remaps cloud paths at phase gates"

  local call_log="${SELFTEST_ROOT}/xcolo-stable-rbd-contract.log"
  : > "${call_log}"
  FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND="krbd"

  # shellcheck disable=SC2317
  ftctl_blockcopy_krbd_map_local() {
    printf 'LOCAL:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() {
    printf -v "$1" '%s' "10.0.0.2"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_map_remote_krbd_path() {
    printf 'REMOTE:%s:%s:%s\n' "$1" "$2" "$3" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_verify_qemu_rbd_backend_local() {
    printf 'LOCAL_BACKEND:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_verify_qemu_rbd_backend_remote() {
    printf 'REMOTE_BACKEND:%s:%s:%s\n' "$1" "$2" "$3" >> "${call_log}"
  }

  ftctl_xcolo_verify_stable_rbd_contract "primary-vm" \
    "sda|/dev/rbd/rbd/root|raw|block|/dev/rbd/rbd/secondary-root;sdb|/dev/rbd/rbd/data|raw|block|/dev/rbd/rbd/secondary-data" \
    "before_migrate"

  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_before_migrate_rbd_contract_ready")" \
    "yes" "stable RBD contract ready"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_before_migrate_rbd_primary_sda")" \
    "ok:/dev/rbd/rbd/root" "primary stable RBD state"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_before_migrate_rbd_secondary_sdb")" \
    "ok:/dev/rbd/rbd/secondary-data" "secondary stable RBD state"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_before_migrate_rbd_primary_backend_sda")" \
    "ok:/dev/rbd/rbd/root" "primary stable KRBD backend state"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_before_migrate_rbd_secondary_backend_sdb")" \
    "ok:/dev/rbd/rbd/secondary-data" "secondary stable KRBD backend state"
  selftest_assert_file_contains "${call_log}" "LOCAL:/dev/rbd/rbd/root"
  selftest_assert_file_contains "${call_log}" "REMOTE:10.0.0.2:root:/dev/rbd/rbd/secondary-root"
  selftest_assert_file_contains "${call_log}" "LOCAL_BACKEND:/dev/rbd/rbd/root"
  selftest_assert_file_contains "${call_log}" "REMOTE_BACKEND:10.0.0.2:root:/dev/rbd/rbd/secondary-root"
)

selftest_case_xcolo_librbd_contract_does_not_map_primary_krbd() (
  selftest_reset_env
  selftest_info "x-colo librbd RBD contract does not map primary KRBD paths"

  local call_log="${SELFTEST_ROOT}/xcolo-librbd-contract.log"
  : > "${call_log}"
  FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND="librbd"

  # shellcheck disable=SC2317
  ftctl_blockcopy_krbd_map_local() {
    printf 'LOCAL_MAP:%s\n' "$1" >> "${call_log}"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_verify_qemu_librbd_backend_local() {
    printf 'LOCAL_LIBRBD:%s\n' "$1" >> "${call_log}"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() {
    printf -v "$1" '%s' "10.0.0.2"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_map_remote_krbd_path() {
    printf 'REMOTE:%s:%s:%s\n' "$1" "$2" "$3" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_verify_qemu_rbd_backend_remote() {
    printf 'REMOTE_BACKEND:%s:%s:%s\n' "$1" "$2" "$3" >> "${call_log}"
  }

  ftctl_xcolo_verify_stable_rbd_contract "primary-vm" \
    "sda|/dev/rbd/rbd/root|raw|block|/dev/rbd/rbd/secondary-root" \
    "before_primary_create"

  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_before_primary_create_rbd_contract_ready")" \
    "yes" "librbd stable RBD contract ready"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_before_primary_create_rbd_primary_backend_sda")" \
    "ok:rbd" "primary native RBD backend state"
  selftest_assert_file_contains "${call_log}" "LOCAL_LIBRBD:/dev/rbd/rbd/root"
  selftest_assert_file_not_contains "${call_log}" "LOCAL_MAP:/dev/rbd/rbd/root"
)

selftest_case_xcolo_baseline_seed_retries_ssh_transport_failure() (
  selftest_reset_env
  selftest_info "x-colo baseline seed retries transient ssh transport failures"

  local call_log="${SELFTEST_ROOT}/xcolo-baseline-seed-retry.log"
  local copy_attempts="0"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_FENCING_SSH_USER="root"
  FTCTL_XCOLO_BASELINE_SEED_RETRY_ATTEMPTS="2"
  FTCTL_XCOLO_BASELINE_SEED_RETRY_DELAY_1_SEC="0"
  FTCTL_XCOLO_QMP_TIMEOUT_SEC="3"

  # shellcheck disable=SC2317
  ftctl_xcolo_primary_connect_host() {
    printf '%s\n' "10.0.0.1"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() {
    printf -v "$1" '%s' "10.0.0.2"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_krbd_map_local() {
    printf 'MAP:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_cmd_run() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4" pid_file="" arg prev=""
    shift 4
    [[ "${1-}" == "--" ]] && shift
    printf 'LOCAL:%s\n' "$*" >> "${call_log}"
    for arg in "$@"; do
      if [[ "${prev}" == "--pid-file" ]]; then
        pid_file="${arg}"
        break
      fi
      prev="${arg}"
    done
    [[ -n "${pid_file}" ]] && printf '999999\n' > "${pid_file}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" remote_cmd="$6"
    if grep -q 'rm -f --' <<<"${remote_cmd}"; then
      printf 'REMOTE:CLEANUP\n' >> "${call_log}"
      printf -v "${out_var}" '%s' ""
      printf -v "${err_var}" '%s' ""
      printf -v "${rc_var}" '%s' "0"
      return 0
    fi
    copy_attempts=$((copy_attempts + 1))
    printf 'REMOTE:COPY:%s\n' "${copy_attempts}" >> "${call_log}"
    if [[ "${copy_attempts}" == "1" ]]; then
      printf -v "${out_var}" '%s' ""
      printf -v "${err_var}" '%s' "Connection closed by remote host"
      printf -v "${rc_var}" '%s' "255"
      return 0
    fi
    printf -v "${out_var}" '%s' "format=qcow2 virtual=12345 actual=4096"
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_xcolo_seed_secondary_baseline_disk \
    "primary-vm" "sda" "/dev/rbd/rbd/root" "raw" "/var/lib/libvirt/images/root.qcow2" "12345"

  selftest_assert_file_contains "${call_log}" "REMOTE:COPY:1"
  selftest_assert_file_contains "${call_log}" "REMOTE:CLEANUP"
  selftest_assert_file_contains "${call_log}" "REMOTE:COPY:2"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_disk_sda_baseline_seeded")" "true" \
    "baseline seed retry state"
)

selftest_case_xcolo_runtime_validation_blocks_false_positive() (
  selftest_reset_env
  selftest_info "x-colo runtime validation blocks false-positive colo_running"

  local vm="xcolo-guard"
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "false"
    else
      printf -v "${out_var}" '%s' "true"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "running"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "colo"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  if ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby"; then
    selftest_fail "runtime validation should fail when primary is not running"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_not_running" \
    "runtime validation failure reason"
)

selftest_case_xcolo_runtime_validation_reports_primary_migrate_failure() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports terminal primary migration failure"

  local vm="xcolo-primary-failed"
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="5"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "true"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "running"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "failed"
    else
      printf -v "${out_var}" '%s' "active"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  if ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby"; then
    selftest_fail "runtime validation should fail on terminal primary migration failure"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_migrate_failed" \
    "runtime validation terminal failure reason"
)

selftest_case_xcolo_runtime_validation_classifies_repeated_invalid_message() (
  selftest_reset_env
  selftest_info "x-colo runtime validation classifies repeated invalid COLO protocol messages"

  local vm="xcolo-invalid-message"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "xcolo_premigrate_primary_filter_chardev_ready=yes" \
    "xcolo_premigrate_primary_filter_qom_ready=yes" \
    "xcolo_premigrate_primary_filter_cmdline_ready=yes" \
    "xcolo_premigrate_channel_mirror_established=yes" \
    "xcolo_premigrate_channel_compare_established=yes" \
    "xcolo_premigrate_channel_compare_local_established=yes" \
    "xcolo_premigrate_channel_compare_out_established=yes" \
    "xcolo_firewall_ready=yes" \
    "xcolo_storage_symmetry=ok" \
    "xcolo_socket_runtime_captured=yes"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "true"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "paused"
    else
      printf -v "${out_var}" '%s' "running"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "failed"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_error_desc() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "Received invalid message 0x0000 length 0x0000"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_socket_snapshot() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_primary_channel_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_channel_mirror_established=yes" \
      "xcolo_channel_compare_established=yes" \
      "xcolo_channel_compare_local_established=yes" \
      "xcolo_channel_compare_out_established=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_filter_qom_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" "xcolo_primary_filter_qom_ready=yes" "xcolo_primary_filter_qom_reason="
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_filter_cmdline_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" "xcolo_primary_filter_cmdline_ready=yes" "xcolo_primary_filter_cmdline_reason="
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_chardev_binding_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" "xcolo_primary_filter_chardev_ready=yes" "xcolo_primary_filter_chardev_reason="
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_secondary_block_graph_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" "xcolo_secondary_block_graph_ready=yes" "xcolo_secondary_block_graph_reason="
  }

  if ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby"; then
    selftest_fail "runtime validation should fail on repeated invalid COLO protocol message"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_repeated_protocol_invalid_message" \
    "repeated invalid message keeps stable last_error"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_protocol_invalid_message_reason")" \
    "primary_role_not_entered_after_migrate" \
    "repeated invalid message records protocol subreason"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_steady_state_gate")" \
    "failed" \
    "repeated invalid message fails steady-state gate"
)

selftest_case_xcolo_startup_active_failure_classifies_filter_mirror_eperm() (
  selftest_reset_env
  selftest_info "x-colo startup-active failure classifies filter-mirror EPERM"

  local vm="xcolo-filter-mirror-eperm"
  ftctl_state_init_vm "${vm}"

  # shellcheck disable=SC2317
  ftctl_xcolo_collect_runtime_failure_diagnostics() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_socket_snapshot() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_failure_chardev_snapshot() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_failure_primary_chardev_mirror0=present_open" \
      "xcolo_failure_secondary_chardev_red0=present_open"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_policy_snapshot() {
    local vm="${1-}"
    ftctl_state_set "${vm}" "xcolo_policy_snapshot_captured=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_primary_filter_mirror_send_errno() {
    printf '%s\n' "eperm"
  }

  ftctl_xcolo_classify_startup_active_stream_failure "${vm}" "${vm}-standby"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_filter_mirror_send_eperm" \
    "startup-active EPERM last error"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_protocol_invalid_message_reason")" \
    "filter_mirror_send_eperm" \
    "startup-active EPERM protocol reason"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_filter_mirror_send_path")" \
    "primary:m0->mirror0->secondary:red0" \
    "startup-active EPERM path"
)

selftest_case_xcolo_chardev_contract_reports_closed_edges() (
  selftest_reset_env
  selftest_info "x-colo chardev contract reports closed mirror/compare edges"

  local vm="xcolo-chardev-contract"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp() {
    local uri="${1-}" payload="${3-}" out_var="${4}" rc_var="${5}"
    : "${payload}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"label":"mirror0","frontend-open":false},{"label":"compare1","frontend-open":true}]}'
    else
      printf -v "${out_var}" '%s' '{"return":[{"label":"red0","frontend-open":true},{"label":"red1","frontend-open":false}]}'
    fi
    printf -v "${rc_var}" '%s' "0"
    return 0
  }

  ftctl_xcolo_capture_colo_chardev_contract "${vm}" "${vm}-standby" "post_activation_contract" || rc=$?
  selftest_assert_eq "${rc}" "1" "closed chardev contract should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_chardev_contract_ready")" \
    "no" "contract is not ready"
  selftest_assert_contains "$(ftctl_state_get "${vm}" "xcolo_chardev_contract_reason")" \
    "mirror_path_primary_mirror0=present_closed" "contract reason includes primary mirror0"
  selftest_assert_contains "$(ftctl_state_get "${vm}" "xcolo_chardev_contract_reason")" \
    "compare_path_secondary_red1=present_closed" "contract reason includes secondary red1"
  selftest_assert_contains "$(ftctl_state_get "${vm}" "xcolo_chardev_contract_mirror_path")" \
    "mirror0(present_closed)" "mirror path records primary state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_post_activation_contract_chardev_contract_ready")" \
    "no" "phase-specific contract state is persisted"
)

selftest_case_xcolo_pre_guest_gate_warns_closed_chardev_contract() (
  selftest_reset_env
  selftest_info "x-colo pre-guest gate treats closed frontend-open as diagnostic before migrate"

  local vm="xcolo-pre-guest-contract"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_qemu_doc_topology=ok"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_XCOLO_CHARDEV_CONTRACT_WAIT_SEC="1"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp() {
    local uri="${1-}" payload="${3-}" out_var="${4}" rc_var="${5}"
    if [[ "${payload}" == *"query-status"* ]]; then
      printf -v "${out_var}" '%s' '{"return":{"running":false,"status":"paused"}}'
    elif [[ "${payload}" == *"query-chardev"* && "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"label":"mirror0","frontend-open":false},{"label":"compare1","frontend-open":true}]}'
    elif [[ "${payload}" == *"query-chardev"* ]]; then
      printf -v "${out_var}" '%s' '{"return":[{"label":"red0","frontend-open":true},{"label":"red1","frontend-open":false}]}'
    else
      printf -v "${out_var}" '%s' '{"return":{}}'
    fi
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_socket_snapshot() {
    return 0
  }

  ftctl_xcolo_gate_before_guest_traffic "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "0" "pre-guest closed frontend-open should not block migrate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_guest_traffic_gate")" \
    "ready" "pre-guest gate ready"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_guest_traffic_gate_policy")" \
    "qemu_doc_topology_socket" "pre-guest policy"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_qemu_doc_runtime_frontend")" \
    "diagnostic_closed" "pre-guest doc frontend diagnostic classification"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_guest_traffic_frontend_contract")" \
    "diagnostic_closed" "pre-guest frontend diagnostic state"
  selftest_assert_contains "$(ftctl_state_get "${vm}" "xcolo_pre_guest_traffic_gate_reason")" \
    "mirror_path_primary_mirror0=present_closed" "pre-guest reason includes mirror0"
  selftest_assert_contains "$(ftctl_state_get "${vm}" "xcolo_pre_guest_traffic_gate_reason")" \
    "compare_path_secondary_red1=present_closed" "pre-guest reason includes red1"
)

selftest_case_xcolo_runtime_validation_reports_pending_convergence() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports missing colo role without hard failure"

  local vm="xcolo-runtime-pending"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "none"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "10" "runtime validation pending return code"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pending_reason")" \
    "colo_role_not_entered" \
    "runtime validation pending reason"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_runtime_pending_since" >/dev/null 2>&1; echo $?)" \
    "0" \
    "runtime validation records pending start"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" \
    "runtime validation pending keeps last_error clear"
)

selftest_case_xcolo_runtime_validation_times_out_stuck_convergence() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports missing colo role after bounded wait"

  local vm="xcolo-runtime-timeout"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"
  selftest_mock_xcolo_primary_channels_ready
  selftest_mock_xcolo_primary_role_diagnostics_ok
  ftctl_state_set "${vm}" "xcolo_primary_net_filters_attached=true"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "none"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "stuck convergence should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:colo_role_not_entered" \
    "missing colo role failure reason"
)

selftest_case_xcolo_runtime_validation_reports_one_sided_colo_role() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports one-sided secondary colo role"

  local vm="xcolo-runtime-one-sided-role"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"
  selftest_mock_xcolo_primary_channels_ready
  selftest_mock_xcolo_primary_role_diagnostics_ok
  ftctl_state_set "${vm}" "xcolo_primary_net_filters_attached=true"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "one-sided role should fail after bounded wait"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_qemu_colo_role_transition_failed" \
    "one-sided secondary role refined failure reason"
)

selftest_case_xcolo_runtime_validation_refines_missing_primary_colo_capability() (
  selftest_reset_env
  selftest_info "x-colo runtime validation refines missing primary x-colo capability"

  local vm="xcolo-runtime-missing-capability"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')" \
    "xcolo_primary_net_filters_attached=true"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"
  selftest_mock_xcolo_primary_channels_ready

  # shellcheck disable=SC2317
  ftctl_xcolo_collect_runtime_failure_diagnostics() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_debug_dir=${FTCTL_RUN_DIR}/debug/xcolo/$(ftctl_state_vm_key "${vm}")" \
      "xcolo_primary_capability_x_colo=no" \
      "xcolo_primary_capability_return_path=yes" \
      "xcolo_primary_checkpoint_delay_set=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "missing primary x-colo capability should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_colo_capability_missing" \
    "missing primary x-colo capability refined reason"
)

selftest_case_xcolo_runtime_validation_refines_primary_chardev_binding() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports primary role stall ahead of closed chardevs"

  local vm="xcolo-runtime-chardev-binding"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')" \
    "xcolo_primary_net_filters_attached=true"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"
  selftest_mock_xcolo_primary_channels_ready

  # shellcheck disable=SC2317
  ftctl_xcolo_collect_runtime_failure_diagnostics() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_capability_x_colo=yes" \
      "xcolo_primary_capability_return_path=yes" \
      "xcolo_primary_checkpoint_delay_set=yes" \
      "xcolo_primary_filter_chardev_ready=no" \
      "xcolo_primary_filter_chardev_reason=mirror0:frontend_closed" \
      "xcolo_primary_block_graph_ready=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_filter_cmdline_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_cmdline_ready=yes" \
      "xcolo_primary_filter_cmdline_reason="
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_filter_qom_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_qom_ready=unknown" \
      "xcolo_primary_filter_qom_reason=qom_unavailable"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_primary_chardev_binding_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_chardev_ready=no" \
      "xcolo_primary_filter_chardev_reason=mirror0:frontend_closed"
    return 1
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_secondary_block_graph_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_secondary_block_graph_ready=yes" \
      "xcolo_secondary_block_graph_reason="
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "10" "primary role stall should remain observable after bounded wait"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_activation_stalled" \
    "primary role stall should preserve activation-stalled diagnostics"
)

selftest_case_xcolo_runtime_validation_reports_compare_channel_failure() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports missing 9000-series compare channel"

  local vm="xcolo-runtime-channel-missing"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_capture_primary_channel_state() {
    local target_vm="${1-}"
    ftctl_state_set "${target_vm}" \
      "xcolo_channel_mirror_established=yes" \
      "xcolo_channel_compare_established=no" \
      "xcolo_channel_compare_local_established=yes" \
      "xcolo_channel_compare_out_established=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "missing compare channel should fail after bounded wait"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:colo_compare_peer_channel_not_established" \
    "missing compare channel failure reason"
)

selftest_case_xcolo_runtime_validation_accepts_reported_colo_role() (
  selftest_reset_env
  selftest_info "x-colo runtime validation accepts explicit colo role state"

  local vm="xcolo-runtime-role-active"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "primary"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "0" "explicit colo role should validate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_colo_mode")" \
    "primary" \
    "primary colo role recorded"
)

selftest_case_xcolo_runtime_validation_records_optional_qga() (
  selftest_reset_env
  selftest_info "x-colo runtime validation records optional qga without failing"

  local vm="xcolo-runtime-optional-qga"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="optional"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "primary"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_guest_ping() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "no"
    return 1
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "0" "optional qga should not block runtime role success"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_qga")" \
    "no" \
    "optional qga state recorded"
)

selftest_case_xcolo_runtime_validation_requires_primary_qga() (
  selftest_reset_env
  selftest_info "x-colo runtime validation can require primary qga health"

  local vm="xcolo-runtime-required-qga"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="required"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "primary"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_guest_ping() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "no"
    return 1
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "required qga should block runtime success"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_guest_boot_unhealthy" \
    "required qga failure reason"
)

selftest_case_xcolo_runtime_reconcile_marks_steady_after_guest_health_recovers() (
  selftest_reset_env
  selftest_info "x-colo runtime reconcile clears guest-health pending markers after recovery"

  local vm="xcolo-runtime-reconcile-steady"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ft" \
    "protection_state=pairing" \
    "transport_state=establishing" \
    "active_side=primary" \
    "conversion_stage=runtime_converging" \
    "conversion_state=pending" \
    "secondary_vm_name=${vm}-standby" \
    "xcolo_steady_state_gate=pending" \
    "xcolo_pending_reason=primary_guest_health_pending:qga_stabilizing" \
    "xcolo_runtime_pending_since=$(date -d '5 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')" \
    "xcolo_primary_guest_health_qga_success_count=1"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_QGA_POLICY="required"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_POLICY="required"
  FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_STABLE_COUNT="2"
  selftest_mock_xcolo_primary_channels_ready

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "true"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "running"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "colo"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "primary"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_guest_ping() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "yes"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_qmp() {
    local out_var="${4}" rc_var="${5}"
    printf -v "${out_var}" '%s' '{"return":[]}'
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_write_debug_file() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_primary_qemu_log_tail() {
    local out_var="${2}"
    printf -v "${out_var}" '%s' ""
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_verify_checkpoint_delay_after_start() {
    return 0
  }

  ftctl_xcolo_reconcile_pending_runtime "${vm}"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" \
    "colo_running" \
    "runtime reconcile protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" \
    "mirroring" \
    "runtime reconcile transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "conversion_stage")" \
    "handshake_complete" \
    "runtime reconcile conversion stage"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "conversion_state")" \
    "colo_running" \
    "runtime reconcile conversion state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_steady_state_gate")" \
    "ok" \
    "runtime reconcile steady gate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_guest_health_gate")" \
    "ok" \
    "runtime reconcile guest gate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pending_reason")" \
    "" \
    "runtime reconcile clears pending reason"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_runtime_pending_since")" \
    "" \
    "runtime reconcile clears pending since"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_runtime_pending_resolved_by")" \
    "runtime_validate" \
    "runtime reconcile records resolver"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "" \
    "runtime reconcile keeps last_error clear"
)

selftest_case_xcolo_runtime_recovery_preserves_error_reason() (
  selftest_reset_env
  selftest_info "x-colo runtime recovery preserves validation error reason"

  local vm="xcolo-runtime-recover"
  local reason="xcolo_runtime_validation_failed:runtime_convergence_timeout"
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"

  # shellcheck disable=SC2317
  ftctl_standby_deactivate() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}" err_var="${3}" rc_var="${4}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_primary_activate_from_backup() {
    return 0
  }

  ftctl_xcolo_recover_runtime_convergence_failure "${vm}" "${reason}"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "conversion_stage")" \
    "runtime_validation_failed" \
    "runtime recovery marks validation failure stage"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "${reason}" \
    "runtime recovery preserves last_error"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_last_runtime_error")" \
    "${reason}" \
    "runtime recovery preserves sticky runtime error"
)

selftest_case_xcolo_block_handshake_failure_recovers_runtime() (
  selftest_reset_env
  selftest_info "x-colo block handshake failure restores primary and stops secondary"

  local vm="xcolo-handshake-recover"
  local reason="primary_filter_chardev_frontend_incomplete"
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"

  # shellcheck disable=SC2317
  ftctl_standby_deactivate() {
    local target_vm="${1-}"
    ftctl_state_set "${target_vm}" "standby_state=stopped"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}" err_var="${3}" rc_var="${4}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_primary_activate_from_backup() {
    return 0
  }

  ftctl_xcolo_recover_block_handshake_failure "${vm}" "${reason}"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "conversion_stage")" \
    "handshake_failed" \
    "handshake recovery keeps handshake failure stage"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" \
    "primary" \
    "handshake recovery returns active side to primary"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" \
    "stopped" \
    "handshake recovery stops standby runtime"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "${reason}" \
    "handshake recovery preserves original reason"
)

selftest_case_xcolo_error_status_uses_sticky_runtime_error() (
  selftest_reset_env
  selftest_info "x-colo error status emits sticky runtime error when last_error is blank"

  local vm="xcolo-sticky-status"
  local out
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ft" \
    "protection_state=error" \
    "transport_state=failed" \
    "conversion_state=error" \
    "last_error=" \
    "xcolo_last_runtime_error=xcolo_runtime_validation_failed:primary_colo_role_not_entered"

  out="$(ftctl_state_emit_json_one "${vm}" "ok")"
  selftest_assert_contains "${out}" \
    '"last_error":"xcolo_runtime_validation_failed:primary_colo_role_not_entered"' \
    "status json falls back to sticky runtime error"
)

selftest_case_json_and_locking() {
  selftest_reset_env
  selftest_info "json output and lock behavior"

  local vm="json-vm"
  local fakebin="${SELFTEST_ROOT}/bin"
  local out="" rc=0

  mkdir -p "${fakebin}" "${SELFTEST_ROOT}/profiles"
  cat > "${fakebin}/virsh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *" list --name"* ]]; then
  exit 0
fi
if [[ "$*" == *" dominfo json-vm"* ]]; then
  if [[ "$*" == *"qemu:///system"* ]]; then
    printf 'Id: 1\nName: json-vm\n'
    exit 0
  fi
  printf 'Domain not found\n' >&2
  exit 1
fi
if [[ "$*" == *"qemu+ssh://peer/system"* && "$*" == *" domstate json-vm-standby"* ]]; then
  printf 'Domain not found\n' >&2
  exit 1
fi
if [[ "$*" == *"qemu+ssh://peer/system"* && "$*" == *" dominfo json-vm-standby"* ]]; then
  printf 'Domain not found\n' >&2
  exit 1
fi
printf 'unsupported test virsh invocation: %s\n' "$*" >&2
exit 2
EOF
  chmod 0755 "${fakebin}/virsh"

  cat > "${SELFTEST_ROOT}/profiles/${vm}.conf" <<EOF
FTCTL_PROFILE_MODE="ha"
FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
EOF

  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  ftctl_state_init_vm "${vm}"

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" status --config "${SELFTEST_CONFIG}" --vm "${vm}" --json)"
  selftest_assert_contains "${out}" '"command":"status"' "status json command"
  selftest_assert_contains "${out}" '"result":"ok"' "status json result"
  selftest_assert_contains "${out}" "\"vm\":\"${vm}\"" "status json vm"

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" check --config "${SELFTEST_CONFIG}" --vm "${vm}" --json)"
  selftest_assert_contains "${out}" '"command":"check"' "check json command"
  selftest_assert_contains "${out}" '"result":"ok"' "check json result"
  selftest_assert_contains "${out}" '"inventory_result":"warn"' "check json inventory result"
  selftest_assert_contains "${out}" '"primary_rc":0' "check primary rc"
  selftest_assert_contains "${out}" '"peer_rc":1' "check peer rc"

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" health --config "${SELFTEST_CONFIG}" --json)"
  selftest_assert_contains "${out}" '"command":"health"' "health json command"
  selftest_assert_contains "${out}" '"result":"ok"' "health json result"
  selftest_assert_contains "${out}" '"rc":0' "health rc"

  exec 209>"${FTCTL_LOCK_FILE}"
  flock -n 209 || selftest_fail "unable to hold test lock"

  set +e
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" config init-cluster --config "${SELFTEST_CONFIG}" --cluster-name demo --local-host-id host-01 --json)"
  rc=$?
  set -e
  selftest_assert_eq "${rc}" "20" "lock conflict exit code"
  selftest_assert_contains "${out}" '"result":"locked"' "lock conflict json result"

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" status --config "${SELFTEST_CONFIG}" --vm "${vm}" --json)"
  selftest_assert_contains "${out}" '"result":"ok"' "read-only status should ignore lock"

  exec 209>&-
}

selftest_case_check_secondary_active_side() {
  selftest_reset_env
  selftest_info "check accepts cloud-managed secondary runtime domain"

  local vm="failover-vm"
  local secondary_vm="i-2-309-VM"
  local fakebin="${SELFTEST_ROOT}/bin"
  local out="" rc=0

  mkdir -p "${fakebin}" "${SELFTEST_ROOT}/profiles"
  cat > "${fakebin}/virsh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *" list --name"* ]]; then
  exit 0
fi
if [[ "$*" == *"qemu:///system"* && "$*" == *" dominfo failover-vm"* ]]; then
  printf 'Domain not found\n' >&2
  exit 1
fi
if [[ "$*" == *"qemu+ssh://peer/system"* && "$*" == *" domstate i-2-309-VM"* ]]; then
  printf 'running\n'
  exit 0
fi
printf 'unsupported test virsh invocation: %s\n' "$*" >&2
exit 2
EOF
  chmod 0755 "${fakebin}/virsh"

  cat > "${SELFTEST_ROOT}/profiles/${vm}.conf" <<EOF
FTCTL_PROFILE_MODE="ha"
FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
FTCTL_PROFILE_SECONDARY_VM_NAME="${secondary_vm}"
FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
EOF

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" check --config "${SELFTEST_CONFIG}" --vm "${vm}" --secondary-vm-name "${secondary_vm}" --active-side secondary --provisioning-backend cloud-managed --json)"
  selftest_assert_contains "${out}" '"command":"check"' "secondary check json command"
  selftest_assert_contains "${out}" '"inventory_result":"ok"' "secondary check inventory result"
  selftest_assert_contains "${out}" '"primary_rc":1' "secondary check primary rc"
  selftest_assert_contains "${out}" '"peer_rc":0' "secondary check peer rc"
  selftest_assert_contains "${out}" '"peer_domain_expected":true' "secondary check peer expected"
  selftest_assert_contains "${out}" '"standby_domain_state":"running"' "secondary check standby running"
  selftest_assert_contains "${out}" '"provisioning_backend":"cloud-managed"' "secondary check provisioning backend"
}

selftest_case_reconcile_secondary_steady_skips_primary_disks() (
  selftest_reset_env
  selftest_info "reconcile skips primary disk inventory after cloud-managed failover"

  local vm="steady-failover-vm"
  local call_log="${SELFTEST_ROOT}/steady-failover-calls.log"

  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "active_side=secondary" \
    "fencing_state=manual-fenced" \
    "protection_state=failed_over" \
    "transport_state=failed_over" \
    "standby_state=running"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_apply_cli() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_validate() { :; }
  # shellcheck disable=SC2317
  ftctl_cluster_load() { :; }
  # shellcheck disable=SC2317
  ftctl_orchestrator_probe_peer() { printf -v "$1" '%s' 'host-02'; printf -v "$2" '%s' '10.0.0.12'; printf -v "$3" '%s' 'reachable'; }
  # shellcheck disable=SC2317
  ftctl_inventory_check_vm() { printf '1 0 ok true running\n'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_refresh_and_classify() {
    printf 'blockcopy-refresh-called\n' >> "${call_log}"
    return 12
  }

  ftctl_orchestrator_reconcile_one "${vm}"

  [[ ! -f "${call_log}" ]] || selftest_fail "blockcopy refresh should not run after steady failover"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failed_over" "steady failover protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed_over" "steady failover transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "steady failover clears last_error"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"event":"failover.steady"'
  selftest_assert_file_not_contains "${FTCTL_EVENTS_LOG}" 'inventory.disks'
)

selftest_case_reconcile_cloud_managed_reports_failover_candidate() (
  selftest_reset_env
  selftest_info "reconcile reports cloud-managed failover candidate without executing qemu failover"

  local vm="cloud-managed-auto-candidate"

  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=dr" \
    "active_side=primary" \
    "protection_state=protected" \
    "transport_state=mirroring" \
    "fencing_state=clear"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_apply_cli() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_validate() { :; }
  # shellcheck disable=SC2317
  ftctl_cluster_load() { :; }
  # shellcheck disable=SC2317
  ftctl_orchestrator_probe_peer() { printf -v "$1" '%s' 'host-02'; printf -v "$2" '%s' '10.0.0.12'; printf -v "$3" '%s' 'reachable'; }
  # shellcheck disable=SC2317
  ftctl_inventory_check_vm() { printf '1 0 ok true not-defined-expected\n'; }
  # shellcheck disable=SC2317
  ftctl_failover_request() { selftest_fail "cloud-managed automatic candidate must be handled by Cloud, not qemu ftctl"; }

  ftctl_orchestrator_reconcile_one "${vm}"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "protected" "cloud candidate protection state preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "cloud candidate transport state preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "cloud_managed_failover_candidate" "cloud candidate last_error"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "failover_candidate_reason")" "primary_domain_missing" "cloud candidate reason"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"event":"cloud_managed.failover_candidate"'
)

selftest_case_reconcile_defers_manual_fence_pending() (
  selftest_reset_env
  selftest_info "reconcile defers manual fence pending state"

  local vm="manual-fence-pending-vm"
  local call_log="${SELFTEST_ROOT}/manual-fence-pending-calls.log"

  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "active_side=primary" \
    "protection_state=failing_over" \
    "transport_state=mirroring" \
    "fencing_state=required" \
    "failover_ready=1" \
    "last_error=manual_fencing_required"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() {
    printf 'profile-load-called\n' >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_inventory_check_vm() {
    printf 'inventory-called\n' >> "${call_log}"
    printf '1 0 ok true running\n'
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_refresh_and_classify() {
    printf 'blockcopy-refresh-called\n' >> "${call_log}"
    return 12
  }

  ftctl_orchestrator_reconcile_one "${vm}"

  [[ ! -f "${call_log}" ]] || selftest_fail "manual fence pending reconcile should not probe inventory or blockcopy"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failing_over" "manual fence pending protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "manual fence pending transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "required" "manual fence pending fencing state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "manual_fencing_required" "manual fence pending last_error retained"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"event":"reconcile.defer"'
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" 'manual_fence_in_progress'
)

selftest_case_global_reconcile_skips_missing_profile_state() (
  selftest_reset_env
  selftest_info "global reconcile skips stale state without profile"

  local stale_vm="stale-profile-vm"
  local live_vm="live-profile-vm"
  local call_log="${SELFTEST_ROOT}/global-reconcile-calls.log"

  ftctl_state_init_vm "${stale_vm}"
  ftctl_state_set "${stale_vm}" \
    "mode=dr" \
    "protection_state=syncing" \
    "transport_state=copying" \
    "active_side=primary"

  ftctl_state_init_vm "${live_vm}"
  ftctl_state_set "${live_vm}" \
    "mode=dr" \
    "protection_state=syncing" \
    "transport_state=copying" \
    "active_side=primary"

  cat > "$(ftctl_profile_path "${live_vm}")" <<EOF
FTCTL_PROFILE_MODE="dr"
FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://10.0.0.2/system"
FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
FTCTL_PROFILE_SECONDARY_TARGET_DIR="/dev/rbd/rbd/${live_vm}"
FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="10.0.0.2:10809"
EOF

  # shellcheck disable=SC2317
  ftctl_orchestrator_reconcile_one() {
    printf '%s\n' "${1-}" >> "${call_log}"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_orchestrator_check_vm() { return 0; }
  # shellcheck disable=SC2317
  ftctl_local_health() { return 0; }

  ftctl_orchestrator_reconcile "" "0" >/dev/null

  [[ -f "${call_log}" ]] || selftest_fail "global reconcile should process live VM"
  selftest_assert_file_not_contains "${call_log}" "${stale_vm}"
  selftest_assert_file_contains "${call_log}" "${live_vm}"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" 'missing_profile'
)

selftest_case_unprotect_releases_blockcopy_targets() (
  selftest_reset_env
  selftest_info "unprotect releases blockcopy targets"

  local vm="unprotect-release"
  local call_log="${SELFTEST_ROOT}/unprotect-release-calls.log"
  local job_queries=0
  local node_queries=0
  FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC="5"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  ftctl_state_init_vm "${vm}"
  printf '%s\n' '{"inventory_result":"ok"}' > "$(ftctl_state_path "${vm}").check.json"
  printf '%s\n' 'mode=cold-conversion' > "$(ftctl_state_path "${vm}").xcolo"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vdb|/dev/rbd/rbd/${vm}-source|/dev/rbd/rbd/${vm}-mirror|raw|copy|yes
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    local cmd="$*"
    printf '%s\n' "${cmd}" >> "${call_log}"
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    if [[ "${cmd}" == *"query-block-jobs"* ]]; then
      job_queries=$((job_queries + 1))
      if (( job_queries == 1 )); then
        printf -v "${out_var}" '%s' '{"return":[{"device":"vdb"}]}'
      else
        printf -v "${out_var}" '%s' '{"return":[]}'
      fi
      return 0
    fi
    if [[ "${cmd}" == *"query-named-block-nodes"* ]]; then
      node_queries=$((node_queries + 1))
      if (( node_queries == 1 )); then
        printf -v "${out_var}" '%s' '{"return":[{"file":"/dev/rbd/rbd/unprotect-release-mirror"}]}'
      else
        printf -v "${out_var}" '%s' '{"return":[]}'
      fi
      return 0
    fi
    printf -v "${out_var}" '%s' '{"return":{}}'
  }

  local out=""
  out="$(ftctl_state_unprotect_vm "${vm}" 1)"
  selftest_assert_contains "${out}" '"result":"ok"' "unprotect result"
  selftest_assert_contains "${out}" '"block_jobs_cancelled":1' "unprotect cancels job"
  selftest_assert_contains "${out}" '"remote_nbd_required":false' "shared unprotect does not require remote nbd"
  [[ ! -f "$(ftctl_blockcopy_state_path "${vm}")" ]] || selftest_fail "blockcopy state should be removed after release"
  [[ ! -f "$(ftctl_state_path "${vm}").check.json" ]] || selftest_fail "check state should be removed after release"
  [[ ! -f "$(ftctl_state_path "${vm}").xcolo" ]] || selftest_fail "xcolo state should be removed after release"
  selftest_assert_file_contains "${call_log}" "block-job-cancel"
  selftest_assert_file_contains "${call_log}" "query-named-block-nodes"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.block-jobs-released"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.qmp-destinations-released"
)

selftest_case_unprotect_releases_remote_nbd_exports() (
  selftest_reset_env
  selftest_info "unprotect releases remote-nbd exports"

  local vm="unprotect-remote-nbd"
  local call_log="${SELFTEST_ROOT}/unprotect-remote-nbd-calls.log"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC="5"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  ftctl_state_init_vm "${vm}"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vdb|/dev/rbd/rbd/${vm}-source|nbd://10.0.0.12:10823/${vm}-vdb|raw|copy|yes|/var/lib/libvirt/images/${vm}-vdb
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    local cmd="$*"
    printf '%s\n' "${cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' '{"return":[]}'
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_remote_nbd_exports() {
    printf 'stop-remote-nbd:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_wait_remote_nbd_release() {
    printf 'wait-remote-nbd:%s\n' "$1" >> "${call_log}"
  }

  local out=""
  out="$(ftctl_state_unprotect_vm "${vm}" 1)"
  selftest_assert_contains "${out}" '"result":"ok"' "remote-nbd unprotect result"
  selftest_assert_contains "${out}" '"remote_nbd_required":true' "remote-nbd unprotect requires release"
  selftest_assert_contains "${out}" '"remote_nbd_released":true' "remote-nbd unprotect release result"
  selftest_assert_file_contains "${call_log}" "stop-remote-nbd:${vm}"
  selftest_assert_file_contains "${call_log}" "wait-remote-nbd:${vm}"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.remote-nbd-release"
)

selftest_case_unprotect_fails_when_remote_nbd_release_fails() (
  selftest_reset_env
  selftest_info "unprotect fails when remote-nbd release fails"

  local vm="unprotect-remote-nbd-fail"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC="1"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  ftctl_state_init_vm "${vm}"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vdb|/dev/rbd/rbd/${vm}-source|nbd://10.0.0.12:10824/${vm}-vdb|raw|copy|yes|/var/lib/libvirt/images/${vm}-vdb
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    printf -v "${out_var}" '%s' '{"return":[]}'
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_remote_nbd_exports() { :; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_wait_remote_nbd_release() { return 99; }

  local rc=0
  ftctl_state_unprotect_vm "${vm}" 1 >/dev/null 2>&1 || rc=$?
  [[ "${rc}" != "0" ]] || selftest_fail "unprotect should fail when remote-nbd release fails"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "remote_nbd_release_timeout" "remote-nbd release failure last_error"
  [[ -f "$(ftctl_blockcopy_state_path "${vm}")" ]] || selftest_fail "blockcopy state should remain after failed remote-nbd release"
)

selftest_case_unprotect_force_cleanup_warns_when_remote_nbd_release_fails() (
  selftest_reset_env
  selftest_info "unprotect force cleanup warns when remote-nbd release fails"

  local vm="unprotect-remote-nbd-force"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC="1"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  ftctl_state_init_vm "${vm}"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vdb|/dev/rbd/rbd/${vm}-source|nbd://10.0.0.12:10824/${vm}-vdb|raw|copy|yes|/var/lib/libvirt/images/${vm}-vdb
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    printf -v "${out_var}" '%s' '{"return":[]}'
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_remote_nbd_exports() { :; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_wait_remote_nbd_release() { return 99; }

  local out=""
  out="$(ftctl_state_unprotect_vm "${vm}" 1 1)"
  selftest_assert_contains "${out}" '"result":"warn"' "force cleanup warning result"
  selftest_assert_contains "${out}" '"forced":true' "force cleanup forced flag"
  selftest_assert_contains "${out}" '"remote_nbd_released":false' "force cleanup records remote-nbd release failure"
  selftest_assert_contains "${out}" '"remote_nbd_release_failed"' "force cleanup warning details"
  [[ ! -f "$(ftctl_blockcopy_state_path "${vm}")" ]] || selftest_fail "blockcopy state should be removed after forced cleanup"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.force-cleanup-warning"
)

selftest_case_failback_reverse_finalize() (
  selftest_reset_env
  selftest_info "failback reverse finalize"

  local vm="reverse-finalize"
  local call_log="${SELFTEST_ROOT}/reverse-finalize-calls.log"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_FAILBACK_DISK_MAP="source"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "active_side=secondary"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|nbd://10.0.0.12:10820/${vm}-vda|/dev/rbd/rbd/${vm}-root|qcow2|/secondary/${vm}/root.qcow2|1024|1024"

  cat > "$(ftctl_blockcopy_progress_path "${vm}")" <<EOF
{"vm":"${vm}","direction":"reverse","disks":[{"target":"vda","offset":2048,"len":4096,"guest_virtual_size":1024,"target_size":1024}]}
EOF
  ftctl_blockcopy_reverse_cutback_ready "${vm}" || selftest_fail "reverse cutback readiness should accept guest virtual size boundary"

  # shellcheck disable=SC2317
  ftctl_blockcopy_secondary_domain_state() { return 1; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() { printf -v "$1" '%s' '10.0.0.12'; printf -v "$2" '%s' 'root'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_export_addr() { printf -v "$1" '%s' '10.0.0.11'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_nbd_pick_port() { printf -v "$3" '%s' '10821'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_prepare_rbd_target_for_sparse_finalize() {
    printf '%s\n' "PREPARE_SPARSE:$2:$3" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_nbd_prepare_target() {
    printf 'PREPARE:%s:%s:%s:%s:%s\n' "$2" "$3" "$4" "$6" "$7" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" cmd="$6"
    printf '%s\n' "${cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_primary_reverse_nbd_exports() {
    printf '%s\n' "STOP_REVERSE_NBD" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_sparsify_rbd_target_after_finalize() {
    printf '%s\n' "SPARSIFY:$2:$3" >> "${call_log}"
  }

  ftctl_blockcopy_finalize_reverse_sync "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "cutback_ready" "reverse finalize transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "reverse finalize clears error"
  selftest_assert_file_contains "${call_log}" "qemu-img convert -p -n"
  selftest_assert_file_contains "${call_log}" '-S "4k"'
  selftest_assert_file_contains "${call_log}" "SPARSIFY:vda:/dev/rbd/rbd/${vm}-root"
  selftest_assert_file_contains "${call_log}" "nbd://10.0.0.11:10821/${vm}-vda-reverse"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "reverse_sync.finalize"
)

selftest_case_failback_reverse_finalize_uses_rbd_uri_source() (
  selftest_reset_env
  selftest_info "failback reverse finalize uses stable RBD URI source"

  local vm="reverse-finalize-rbd-uri"
  local call_log="${SELFTEST_ROOT}/reverse-finalize-rbd-uri-calls.log"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_FAILBACK_DISK_MAP="source"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "active_side=secondary"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|nbd://10.0.0.12:10820/${vm}-vda|/dev/rbd/rbd/${vm}-root|raw|/dev/rbd/rbd/${vm}-standby-root|1024|1024"

  # shellcheck disable=SC2317
  ftctl_blockcopy_secondary_domain_state() { return 1; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() { printf -v "$1" '%s' '10.0.0.12'; printf -v "$2" '%s' 'root'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_export_addr() { printf -v "$1" '%s' '10.0.0.11'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_nbd_pick_port() { printf -v "$3" '%s' '10821'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_prepare_rbd_target_for_sparse_finalize() { :; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_nbd_prepare_target() {
    printf 'PREPARE:%s:%s:%s:%s:%s\n' "$2" "$3" "$4" "$6" "$7" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" cmd="$6"
    printf '%s\n' "${cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_primary_reverse_nbd_exports() { :; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_sparsify_rbd_target_after_finalize() { :; }

  ftctl_blockcopy_finalize_reverse_sync "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "cutback_ready" "reverse RBD finalize transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "reverse RBD finalize clears error"
  selftest_assert_file_contains "${call_log}" "secondary_path=rbd:rbd/${vm}-standby-root"
  selftest_assert_file_contains "${call_log}" "qemu-img convert -p -n"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "source\":\"rbd:rbd/${vm}-standby-root"
)

selftest_case_failback_shared_reverse_finalize() (
  selftest_reset_env
  selftest_info "failback shared reverse finalize"

  local vm="shared-reverse-finalize"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=failing_back" \
    "transport_state=reverse_sync_ready" \
    "last_error=reverse_sync_pending"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw||1024|1024"

  cat > "$(ftctl_blockcopy_progress_path "${vm}")" <<EOF
{"direction":"reverse","ready":true,"disks":[{"target":"vda","ready":true,"status":"ready","offset":1024,"len":1024,"guest_virtual_size":1024,"target_size":1024}]}
EOF

  # shellcheck disable=SC2317
  ftctl_blockcopy_secondary_domain_state() { return 1; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_local_path_virtual_size_bytes() {
    printf -v "$2" '%s' "1024"
  }

  ftctl_blockcopy_finalize_reverse_sync "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "cutback_ready" "shared reverse finalize transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "shared reverse finalize clears error"
  [[ ! -f "$(ftctl_blockcopy_reverse_state_path "${vm}")" ]] || selftest_fail "shared reverse state should be removed after finalize"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"backend":"shared-blockcopy"'
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "reverse_sync.finalize"
)

selftest_case_dr_remote_failback_maps_reverse_rbd_on_primary() (
  selftest_reset_env
  selftest_info "DR remote-nbd failback maps reverse RBD destinations on primary"

  local vm="dr-remote-reverse-map"
  local call_log="${SELFTEST_ROOT}/dr-remote-reverse-map-calls.log"
  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://root@10.10.32.1:22/system"
  ftctl_state_init_vm "${vm}"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "sda|nbd://10.10.32.1:10816/${vm}-sda|/dev/rbd/rbd/${vm}-source-root|raw|/dev/rbd/rbd/${vm}-standby-root|1024|1024"

  # shellcheck disable=SC2317
  ftctl_blockcopy_krbd_map_local() {
    printf 'PRIMARY_LOCAL_MAP:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_map_remote_krbd_path() {
    printf 'UNEXPECTED_SECONDARY_MAP:%s:%s:%s\n' "$1" "$2" "$3" >> "${call_log}"
    return 9
  }

  ftctl_blockcopy_map_reverse_krbd_destinations "${vm}"
  selftest_assert_file_contains "${call_log}" "PRIMARY_LOCAL_MAP:/dev/rbd/rbd/${vm}-source-root"
  selftest_assert_file_not_contains "${call_log}" "UNEXPECTED_SECONDARY_MAP"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "reverse_sync.primary-rbd-map"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "site\":\"primary"
)

selftest_case_dr_remote_reverse_plan_stores_rbd_uri_source() (
  selftest_reset_env
  selftest_info "DR remote-nbd reverse plan stores stable RBD URI source"

  local vm="dr-remote-reverse-rbd-source"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_FAILBACK_DISK_MAP="source"
  ftctl_state_init_vm "${vm}"
  ftctl_blockcopy_state_write "${vm}" \
    "sda|/dev/rbd/rbd/${vm}-primary-root|nbd://10.10.32.1:10816/${vm}-sda|raw|copy|yes|/dev/rbd/rbd/${vm}-standby-root"

  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() { printf -v "$1" '%s' '10.10.32.1'; printf -v "$2" '%s' 'root'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_path_virtual_size_bytes() {
    [[ "$3" == "rbd:rbd/${vm}-standby-root" ]] || selftest_fail "reverse plan should size stable RBD URI, got $3"
    printf -v "$4" '%s' "1024"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_local_path_virtual_size_bytes() { printf -v "$2" '%s' "1024"; }

  ftctl_blockcopy_prepare_reverse_sync_plan "${vm}"
  selftest_assert_file_contains "$(ftctl_blockcopy_reverse_state_path "${vm}")" "rbd:rbd/${vm}-standby-root|1024|1024"
)

selftest_case_dr_remote_primary_nbd_prepare_maps_unmapped_rbd() (
  selftest_reset_env
  selftest_info "DR remote-nbd primary export maps unmapped source RBD"

  local vm="dr-primary-rbd-export"
  local call_log="${SELFTEST_ROOT}/dr-primary-rbd-export-calls.log"
  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_PRIMARY_URI="qemu+ssh://root@10.10.22.3:22/system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://root@10.10.32.1:22/system"

  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_target_host_user() {
    printf -v "$1" '%s' "10.10.22.3"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_export_addr() {
    printf -v "$1" '%s' "10.10.22.3"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" cmd="$6"
    printf '%s\n' "${cmd}" > "${call_log}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_blockcopy_primary_nbd_prepare_target \
    "${vm}" \
    "sda" \
    "nbd://10.10.32.1:10816/${vm}-sda" \
    "raw" \
    "/dev/rbd/rbd/${vm}-source-root" \
    "${vm}-sda-reverse" \
    "10816"

  selftest_assert_file_contains "${call_log}" 'krbd_spec="rbd/dr-primary-rbd-export-source-root"'
  selftest_assert_file_contains "${call_log}" "rbd map \"\${krbd_spec}\""
  selftest_assert_file_contains "${call_log}" "reverse_primary_rbd_map_failed:/dev/rbd/rbd/dr-primary-rbd-export-source-root"
)

selftest_case_failback_reverse_progress_ready() (
  selftest_reset_env
  selftest_info "failback reverse progress ready"

  local vm="reverse-progress-ready"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://10.0.0.12/system"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=failing_back" \
    "transport_state=reverse_syncing" \
    "secondary_vm_name=${vm}-standby" \
    "last_error=reverse_sync_pending"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw|||"

  # shellcheck disable=SC2317
  ftctl_blockcopy_active_domain_on_secondary() { echo "${vm}-standby"; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_secondary_domain_state() { printf -v "$2" '%s' "running"; return 0; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_reverse_job_query() {
    printf -v "$3" '%s' "unknown"
    printf -v "$4" '%s' "unknown"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_progress_refresh_from_qmp() {
    cat > "$(ftctl_blockcopy_progress_path "${vm}")" <<EOF
{"direction":"reverse","ready":true,"disks":[{"target":"vda","ready":true,"status":"ready","offset":1073741824,"len":1073741824}]}
EOF
  }

  ftctl_blockcopy_refresh_reverse_jobs "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "reverse_sync_ready" "reverse QMP progress ready transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "reverse QMP progress ready clears error"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "reverse_sync.ready"
)

selftest_case_failback_sync_idempotent_when_reverse_ready() (
  selftest_reset_env
  selftest_info "failback-sync is idempotent when reverse sync is ready"

  local vm="reverse-sync-ready-idempotent"
  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=failing_back" \
    "transport_state=reverse_sync_ready" \
    "secondary_vm_name=${vm}-standby" \
    "last_error="
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw|/dev/rbd/rbd/${vm}-standby-root||"

  # shellcheck disable=SC2317
  ftctl_blockcopy_start_reverse_sync() {
    selftest_fail "FAILBACK_SYNC must not restart reverse block jobs once ready"
  }

  ftctl_failback_sync_for_cloud_cutback "${vm}" "manual"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "reverse_sync_ready" "ready failback-sync keeps ready transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "ready failback-sync keeps last_error clear"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"reverse_sync":"already_ready"'
)

selftest_case_failback_sync_recovers_failed_ready_progress() (
  selftest_reset_env
  selftest_info "failback-sync recovers reverse ready progress after failed retry"

  local vm="reverse-sync-failed-ready-progress"
  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=error" \
    "transport_state=reverse_sync_failed" \
    "secondary_vm_name=${vm}-standby" \
    "last_error=reverse_sync_start_failed"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw|/dev/rbd/rbd/${vm}-standby-root||"
  cat > "$(ftctl_blockcopy_progress_path "${vm}")" <<EOF
{"direction":"reverse","ready":true,"disks":[{"target":"vda","ready":true,"status":"ready","offset":1073741824,"len":1073741824}]}
EOF

  # shellcheck disable=SC2317
  ftctl_blockcopy_start_reverse_sync() {
    selftest_fail "FAILBACK_SYNC must recover ready progress instead of restarting block jobs"
  }

  ftctl_failback_sync_for_cloud_cutback "${vm}" "manual"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failing_back" "failed ready progress returns to failing_back"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "reverse_sync_ready" "failed ready progress recovers ready transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "failed ready progress clears last_error"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"reverse_sync":"recovered_ready_from_progress"'
)

selftest_case_reconcile_preserves_cloud_failback_failure() (
  selftest_reset_env
  selftest_info "reconcile preserves cloud failback failure"

  local vm="cloud-failback-failed"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "active_side=secondary" \
    "protection_state=error" \
    "transport_state=reverse_sync_failed" \
    "last_error=reverse_finalize_unsupported_backend:shared-blockcopy" \
    "rearm_count=0"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw|||"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_apply_cli() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_validate() { :; }
  # shellcheck disable=SC2317
  ftctl_cluster_load() { :; }
  # shellcheck disable=SC2317
  ftctl_orchestrator_probe_peer() {
    printf -v "$1" '%s' "peer-1"
    printf -v "$2" '%s' "10.0.0.12"
    printf -v "$3" '%s' "reachable"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_rearm() {
    selftest_fail "cloud-managed failed failback must not auto-rearm"
  }

  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "reverse_sync_failed" "failed failback transport preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "rearm_count")" "0" "failed failback must not increment rearm"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "cloud_failback_failure_preserved"
)

selftest_case_reconcile_waits_for_cloud_failback_after_fence_clear() (
  selftest_reset_env
  selftest_info "reconcile waits for cloud failback command after manual fence release"

  local vm="cloud-failback-await"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "active_side=secondary" \
    "protection_state=failed_over" \
    "transport_state=failed_over" \
    "fencing_state=clear" \
    "rearm_count=0"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_apply_cli() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_validate() { :; }
  # shellcheck disable=SC2317
  ftctl_cluster_load() { :; }
  # shellcheck disable=SC2317
  ftctl_orchestrator_probe_peer() {
    printf -v "$1" '%s' "peer-1"
    printf -v "$2" '%s' "10.0.0.12"
    printf -v "$3" '%s' "reachable"
  }
  # shellcheck disable=SC2317
  ftctl_inventory_check_vm() {
    selftest_fail "cloud-managed failback-ready state must not run inventory before FAILBACK_SYNC"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_rearm() {
    selftest_fail "cloud-managed failback-ready state must not auto-rearm"
  }

  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failed_over" "await command protection preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed_over" "await command transport preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "rearm_count")" "0" "await command must not increment rearm"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "failback.await-command"
)

selftest_case_reconcile_waits_for_cloud_dr_failback_after_fence_clear() (
  selftest_reset_env
  selftest_info "DR reconcile waits for cloud failback command after manual fence release"

  local vm="cloud-dr-failback-await"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=dr" \
    "active_side=secondary" \
    "protection_state=failed_over" \
    "transport_state=failed_over" \
    "fencing_state=clear" \
    "rearm_count=0"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_apply_cli() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_validate() { :; }
  # shellcheck disable=SC2317
  ftctl_cluster_load() { :; }
  # shellcheck disable=SC2317
  ftctl_orchestrator_probe_peer() {
    printf -v "$1" '%s' "peer-1"
    printf -v "$2" '%s' "10.0.0.12"
    printf -v "$3" '%s' "reachable"
  }
  # shellcheck disable=SC2317
  ftctl_inventory_check_vm() {
    selftest_fail "cloud-managed DR failback-ready state must not run inventory before Cloud recovery"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_rearm() {
    selftest_fail "cloud-managed DR failback-ready state must not auto-rearm"
  }

  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failed_over" "DR await command protection preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed_over" "DR await command transport preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "rearm_count")" "0" "DR await command must not increment rearm"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "failback.await-command"
)

selftest_case_failback_reprotect_clears_standby_verify_state() (
  selftest_reset_env
  selftest_info "failback reprotect clears stale standby verification state"

  local vm="failback-standby-state"
  FTCTL_PROFILE_MODE="ha"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=failing_back" \
    "transport_state=cutback_ready" \
    "standby_state=running" \
    "standby_verify_state=running-network-unknown" \
    "standby_domain_state=running" \
    "peer_domain_expected=true"

  # shellcheck disable=SC2317
  ftctl_failback_reprotect_from_primary() {
    ftctl_state_set "$1" \
      "protection_state=protected" \
      "transport_state=mirroring"
  }

  ftctl_failback_reprotect_after_cloud_cutback "${vm}" "selftest"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "primary" "reprotect active side"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "protected" "reprotect protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "reprotect transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "prepared-transient" "reprotect standby state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_verify_state")" "not-defined-expected" "reprotect standby verify state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_domain_state")" "not-defined-expected" "reprotect standby domain state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "peer_domain_expected")" "false" "reprotect peer domain expected"

  ftctl_state_set "${vm}" "standby_verify_state=running-network-unknown"
  ftctl_failback_reprotect_after_cloud_cutback "${vm}" "selftest-idempotent"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_verify_state")" "not-defined-expected" "idempotent reprotect standby verify state"

  local out=""
  out="$(ftctl_state_print_one "${vm}" 1)"
  selftest_assert_contains "${out}" '"standby_verify_state":"not-defined-expected"' "status emits post-failback standby verify state"
  selftest_assert_not_contains "${out}" '"standby_verify_state":"running-network-unknown"' "status omits stale standby verify state"
)

selftest_write_xcolo_mtree_deferred_fixture() {
  local vm="${1-}"
  local phase="${2-}"
  local debug_dir

  debug_dir="$(ftctl_xcolo_debug_dir "${vm}")"
  mkdir -p "${debug_dir}"
  cat > "${debug_dir}/primary-info-qtree-${phase}.txt" <<'EOF'
dev: i440FX-pcihost, id ""
dev: pci-bridge, id "pci.6"
dev: virtio-scsi-pci, id "scsi0"
dev: virtio-net-pci, id "net0"
EOF
  cat > "${debug_dir}/secondary-info-qtree-${phase}.txt" <<'EOF'
dev: i440FX-pcihost, id ""
dev: pci-bridge, id "pci.6"
dev: virtio-scsi-pci, id "scsi0"
dev: virtio-net-pci, id "net0"
EOF
  cat > "${debug_dir}/primary-info-mtree-${phase}.txt" <<'EOF'
0000000000000000-00000000ffffffff (prio 0, ram): pc.ram
00000000febf0000-00000000febf0fff (prio 1, i/o): alias pci_bridge_mem @pci_bridge_pci 0000000000000000-0000000000000fff
00000000fec00000-00000000fec00fff (prio 1, i/o): alias pci_bridge_io @pci_bridge_pci 0000000000000000-0000000000000fff
00000000fed00000-00000000fed00fff (prio 1, i/o): alias pci_bridge_pref_mem @pci_bridge_pci 0000000000000000-0000000000000fff
EOF
  cat > "${debug_dir}/secondary-info-mtree-${phase}.txt" <<'EOF'
0000000000000000-00000000ffffffff (prio 0, ram): pc.ram
0000000000000000-0000000000000000 (prio 1, i/o): alias pci_bridge_mem @pci_bridge_pci 0000000000000000-0000000000000000
0000000000000000-0000000000000000 (prio 1, i/o): alias pci_bridge_io @pci_bridge_pci 0000000000000000-0000000000000000
0000000000000000-0000000000000000 (prio 1, i/o): alias pci_bridge_pref_mem @pci_bridge_pci 0000000000000000-0000000000000000
EOF
  : > "${debug_dir}/primary-info-pci-${phase}.txt"
  : > "${debug_dir}/secondary-info-pci-${phase}.txt"
}

selftest_case_xcolo_mtree_zero_alias_fails_before_migrate() (
  selftest_reset_env
  selftest_info "x-colo secondary mtree zero PCI aliases fail before migrate"

  local vm="xcolo-mtree-pre-fail"
  local phase="before_migrate"
  ftctl_state_init_vm "${vm}"
  selftest_write_xcolo_mtree_deferred_fixture "${vm}" "${phase}"

  ftctl_xcolo_analyze_runtime_topology_diff "${vm}" "${phase}" "pre_migrate"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_migrate_topology_gate_state")" \
    "failed" "pre-migrate zero PCI aliases should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_migrate_topology_gate_error")" \
    "xcolo_pre_migrate_secondary_pci_resource_unmaterialized" \
    "pre-migrate unmaterialized PCI resource error recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_migrate_mtree_secondary_zero_pci_alias_count")" \
    "3" "pre-migrate secondary zero alias count"
)

selftest_case_xcolo_mtree_zero_alias_fails_after_migrate() (
  selftest_reset_env
  selftest_info "x-colo secondary mtree zero PCI aliases fail after migrate"

  local vm="xcolo-mtree-post-fail"
  local phase="after_migrate_materialization"
  ftctl_state_init_vm "${vm}"
  selftest_write_xcolo_mtree_deferred_fixture "${vm}" "${phase}"

  ftctl_xcolo_analyze_runtime_topology_diff "${vm}" "${phase}" "post_migrate_materialization"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_topology_gate_state")" \
    "failed" "post-migrate zero PCI aliases should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_topology_gate_error")" \
    "xcolo_post_migrate_secondary_pci_resources_unmaterialized" \
    "post-migrate materialization error recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_mtree_secondary_zero_pci_alias_count")" \
    "3" "post-migrate secondary zero alias count"
)

selftest_write_xcolo_incoming_pci_fixture() {
  local vm="${1-}"
  local phase="${2-}"
  local debug_dir

  debug_dir="$(ftctl_xcolo_debug_dir "${vm}")"
  mkdir -p "${debug_dir}"
  cat > "${debug_dir}/primary-generated-pci-manifest-startup_disk_graph.json" <<'EOF'
{
  "qemu_guest_devices": [
    {"driver": "pcie-root-port", "opts": {"id": "pci.1"}},
    {"driver": "virtio-scsi-pci", "opts": {"id": "scsi0"}}
  ]
}
EOF
  cp "${debug_dir}/primary-generated-pci-manifest-startup_disk_graph.json" \
    "${debug_dir}/secondary-generated-pci-manifest-startup_disk_graph.json"
  cat > "${debug_dir}/primary-info-qtree-${phase}.txt" <<'EOF'
dev: pcie-root-port, id "pci.1"
dev: virtio-scsi-pci, id "scsi0"
EOF
  cp "${debug_dir}/primary-info-qtree-${phase}.txt" "${debug_dir}/secondary-info-qtree-${phase}.txt"
  : > "${debug_dir}/primary-info-mtree-${phase}.txt"
  : > "${debug_dir}/secondary-info-mtree-${phase}.txt"
  cat > "${debug_dir}/primary-info-pci-${phase}.txt" <<'EOF'
  Bus  0, device   0, function 0:
    Host bridge: PCI device 8086:29c0
      id ""
  Bus  0, device   2, function 0:
    PCI bridge: PCI device 1b36:000c
      secondary bus 1.
      subordinate bus 2.
      BAR0: 32 bit memory at 0x82d47000 [0x82d47fff]
      id "pci.1"
  Bus  1, device   0, function 0:
    PCI bridge: PCI device 1b36:000e
      secondary bus 2.
      subordinate bus 2.
      BAR0: 64 bit memory at 0x82c00000 [0x82c000ff]
      id "pci.6"
  Bus  0, device   9, function 0:
    SCSI controller: PCI device 1af4:1004
      BAR0: I/O at 0x6040 [0x607f]
      id "scsi0"
EOF
  cat > "${debug_dir}/secondary-info-pci-${phase}.txt" <<'EOF'
  Bus  0, device   0, function 0:
    Host bridge: PCI device 8086:29c0
      id ""
  Bus  0, device   2, function 0:
    PCI bridge: PCI device 1b36:000c
      secondary bus 0.
      subordinate bus 0.
      BAR0: 32 bit memory (not mapped)
      id "pci.1"
  Bus  0, device   2, function 1:
    PCI bridge: PCI device 1b36:000c
      secondary bus 0.
      subordinate bus 0.
      BAR0: 32 bit memory (not mapped)
      id "pci.2"
  Bus  0, device   9, function 0:
    SCSI controller: PCI device 1af4:1004
      BAR0: I/O (not mapped)
      id "scsi0"
EOF
}

selftest_case_xcolo_live_pci_incoming_fails_before_migrate() (
  selftest_reset_env
  selftest_info "x-colo incoming secondary PCI identity fails before migrate"

  local vm="xcolo-live-pci-pre-fail"
  local phase="before_migrate"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu:///system"
  selftest_write_xcolo_incoming_pci_fixture "${vm}" "${phase}"

  # shellcheck disable=SC2317
  ftctl_xcolo_capture_live_runtime_topology_one() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_qemu_proc_args_pair() {
    local out_primary="${4}" out_secondary="${5}"
    local argv=$'-device\n{"driver":"pcie-root-port","id":"pci.1","bus":"pcie.0","addr":"0x2"}\n-device\n{"driver":"virtio-scsi-pci","id":"scsi0","bus":"pcie.0","addr":"0x9"}'
    printf -v "${out_primary}" '%s' "${argv}"
    printf -v "${out_secondary}" '%s' "${argv}"
    ftctl_xcolo_write_debug_file "${vm}" "primary-live-qemu-argv-${phase}.txt" "${argv}"
    ftctl_xcolo_write_debug_file "${vm}" "secondary-live-qemu-argv-${phase}.txt" "${argv}"
    return 0
  }

  ftctl_xcolo_verify_live_runtime_topology_pair "${vm}" "${vm}-standby" "${phase}" || rc=$?
  selftest_assert_eq "${rc}" "1" "incoming PCI identity must fail before migrate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_live_runtime_topology")" \
    "failed" "pre-migrate incoming PCI identity failed"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_live_pci_identity")" \
    "failed" "pre-migrate live PCI identity failed"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pre_migrate_pci_materialization_deferred")" \
    "no" "pre-migrate materialization deferred marker disabled"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_protocol_failure_phase")" \
    "pre_migrate_materialization" "pre-migrate materialization is a failure phase"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_pre_migrate_secondary_pci_resource_unmaterialized" \
    "pre-migrate unmaterialized PCI resource error recorded"
)

selftest_case_xcolo_live_pci_incoming_fails_after_migrate() (
  selftest_reset_env
  selftest_info "x-colo incoming secondary PCI identity fails after migrate"

  local vm="xcolo-live-pci-post-fail"
  local phase="post_migrate_materialization"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu:///system"
  selftest_write_xcolo_incoming_pci_fixture "${vm}" "${phase}"

  # shellcheck disable=SC2317
  ftctl_xcolo_capture_live_runtime_topology_one() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_qemu_proc_args_pair() {
    local out_primary="${4}" out_secondary="${5}"
    local argv=$'-device\n{"driver":"pcie-root-port","id":"pci.1","bus":"pcie.0","addr":"0x2"}\n-device\n{"driver":"virtio-scsi-pci","id":"scsi0","bus":"pcie.0","addr":"0x9"}'
    printf -v "${out_primary}" '%s' "${argv}"
    printf -v "${out_secondary}" '%s' "${argv}"
    ftctl_xcolo_write_debug_file "${vm}" "primary-live-qemu-argv-${phase}.txt" "${argv}"
    ftctl_xcolo_write_debug_file "${vm}" "secondary-live-qemu-argv-${phase}.txt" "${argv}"
    return 0
  }

  ftctl_xcolo_verify_live_runtime_topology_pair "${vm}" "${vm}-standby" "${phase}" || rc=$?
  selftest_assert_eq "${rc}" "1" "incoming PCI identity must fail after migrate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_live_pci_identity_unmaterialized" \
    "post-migrate incoming PCI identity error"
)

selftest_case_xcolo_post_migrate_secondary_crash_fails_fast() (
  selftest_reset_env
  selftest_info "x-colo post-migrate secondary crash fails fast"

  local vm="xcolo-post-migrate-secondary-crash"
  local secondary_vm="${vm}-standby"
  local rc=0

  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_XCOLO_POST_MIGRATE_ROLE_TRANSITION_WAIT_SEC="5"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu:///system"

  # shellcheck disable=SC2317
  ftctl_xcolo_capture_post_migrate_transition_state() {
    local _vm="${1}" _secondary_vm="${2}" phase="${3}"
    : "${_secondary_vm}"
    ftctl_state_set "${_vm}" \
      "xcolo_post_migrate_${phase}_primary_migrate_status=colo" \
      "xcolo_post_migrate_${phase}_secondary_migrate_status=" \
      "xcolo_post_migrate_${phase}_primary_status=paused" \
      "xcolo_post_migrate_${phase}_secondary_status=" \
      "xcolo_post_migrate_${phase}_primary_colo_mode=primary" \
      "xcolo_post_migrate_${phase}_secondary_colo_mode=" \
      "xcolo_post_migrate_${phase}_invalid_message=no" \
      "xcolo_post_migrate_${phase}_chardev_contract_ready=no" \
      "xcolo_post_migrate_${phase}_chardev_contract_reason=mirror_path_secondary_red0=query_failed" \
      "xcolo_post_migrate_${phase}_chardev_contract_query_state=secondary_query_failed" \
      "xcolo_post_migrate_${phase}_chardev_contract_query_transient=yes"
  }

  # shellcheck disable=SC2317
  ftctl_xcolo_capture_post_migrate_secondary_failure_evidence() {
    local _vm="${1}" _secondary_vm="${2}" phase="${3}"
    : "${_secondary_vm}"
    ftctl_state_set "${_vm}" \
      "xcolo_post_migrate_failure_evidence_phase=${phase}" \
      "xcolo_post_migrate_failure_evidence_captured=yes"
  }

  # shellcheck disable=SC2317
  ftctl_xcolo_secondary_qemu_assert_memory_region_container_observed() {
    local _vm="${1}" _secondary_vm="${2}"
    : "${_secondary_vm}"
    ftctl_state_set "${_vm}" \
      "xcolo_secondary_qemu_assert=memory_region_add_subregion_common" \
      "xcolo_secondary_crash_detected=yes"
    return 0
  }

  ftctl_xcolo_wait_post_migrate_role_transition "${vm}" "${secondary_vm}" || rc=$?

  selftest_assert_eq "${rc}" "1" "secondary crash must fail role transition"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_attempts")" \
    "1" "secondary crash should fail fast"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_reason")" \
    "secondary_qemu_assert_memory_region_container" "secondary assertion reason recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_protocol_failure_phase")" \
    "post_migrate_secondary_crash" "post-migrate secondary crash phase recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_safe_fail_recovery_required")" \
    "yes" "primary safe-fail recovery marker recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_repeated_failure_signature")" \
    "memory_region_add_subregion_common" "repeated failure signature recorded"
)

selftest_write_xcolo_generated_manifest_xml() {
  local path="${1-}"
  local vm_name="${2-}"
  local root_port_addr="${3:-0x2}"

  cat > "${path}" <<EOF
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>${vm_name}</name>
  <uuid>11111111-2222-3333-4444-555555555555</uuid>
  <memory unit='KiB'>1048576</memory>
  <currentMemory unit='KiB'>1048576</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-rhel9.6.0'>hvm</type>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-model'/>
  <devices>
    <controller type='pci' index='0' model='pcie-root'>
      <alias name='pcie.0'/>
    </controller>
    <controller type='pci' index='1' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='1' port='0x10'/>
      <alias name='pci.1'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0'/>
    </controller>
    <interface type='bridge'>
      <mac address='52:54:00:aa:bb:cc'/>
      <model type='virtio'/>
      <alias name='net0'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
  </devices>
  <qemu:commandline>
    <qemu:arg value='-device'/>
    <qemu:arg value='pcie-root-port,id=pci.1,bus=pcie.0,addr=${root_port_addr},chassis=1,port=0x10'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='pcie-pci-bridge,id=pci.6,bus=pci.1,addr=0x0'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='virtio-net-pci,netdev=hostnet0,id=net0,bus=pci.6,addr=0x0,mac=52:54:00:aa:bb:cc'/>
  </qemu:commandline>
</domain>
EOF
}

selftest_case_xcolo_generated_pci_manifest_pair_ok() (
  selftest_reset_env
  selftest_info "x-colo generated PCI manifest accepts identical topology"

  local vm="xcolo-generated-manifest-ok"
  local primary_xml="${SELFTEST_ROOT}/primary.xml"
  local secondary_xml="${SELFTEST_ROOT}/secondary.xml"
  local rc=0

  ftctl_state_init_vm "${vm}"
  selftest_write_xcolo_generated_manifest_xml "${primary_xml}" "${vm}" "0x2"
  selftest_write_xcolo_generated_manifest_xml "${secondary_xml}" "${vm}-standby" "0x2"

  ftctl_xcolo_verify_generated_pci_manifest_pair "${vm}" "${primary_xml}" "${secondary_xml}" "selftest" || rc=$?
  selftest_assert_eq "${rc}" "0" "identical generated PCI manifest should pass"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_generated_pci_manifest")" \
    "ok" "generated PCI manifest ok state"
  selftest_assert_file_contains "$(ftctl_xcolo_debug_dir "${vm}")/primary-generated-pci-manifest-selftest.json" \
    "pcie-pci-bridge"
)

selftest_case_xcolo_generated_pci_manifest_pair_mismatch() (
  selftest_reset_env
  selftest_info "x-colo generated PCI manifest rejects topology mismatch"

  local vm="xcolo-generated-manifest-mismatch"
  local primary_xml="${SELFTEST_ROOT}/primary.xml"
  local secondary_xml="${SELFTEST_ROOT}/secondary.xml"
  local rc=0

  ftctl_state_init_vm "${vm}"
  selftest_write_xcolo_generated_manifest_xml "${primary_xml}" "${vm}" "0x2"
  selftest_write_xcolo_generated_manifest_xml "${secondary_xml}" "${vm}-standby" "0x3"

  ftctl_xcolo_verify_generated_pci_manifest_pair "${vm}" "${primary_xml}" "${secondary_xml}" "selftest" || rc=$?
  selftest_assert_eq "${rc}" "1" "mismatched generated PCI manifest should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_generated_pci_manifest_mismatch" \
    "generated PCI manifest mismatch error"
  selftest_assert_file_contains "$(ftctl_xcolo_debug_dir "${vm}")/generated-pci-manifest-diff-selftest.txt" \
    "mismatch"
)

selftest_write_xcolo_materialization_pipeline_base() {
  local vm="${1-}"
  local phase="${2-}"
  local mode="${3:-ok}"
  local debug_dir primary_xml secondary_xml

  debug_dir="$(ftctl_xcolo_debug_dir "${vm}")"
  mkdir -p "${debug_dir}"
  primary_xml="${SELFTEST_ROOT}/primary.xml"
  secondary_xml="${SELFTEST_ROOT}/secondary.xml"
  selftest_write_xcolo_generated_manifest_xml "${primary_xml}" "${vm}" "0x2"
  selftest_write_xcolo_generated_manifest_xml "${secondary_xml}" "${vm}-standby" "0x2"
  ftctl_xcolo_verify_generated_pci_manifest_pair "${vm}" "${primary_xml}" "${secondary_xml}" "startup_disk_graph"

  if [[ "${mode}" == "scsi_child" ]]; then
    DEBUG_DIR="${debug_dir}" python3 - <<'PY'
import json
import os

debug_dir = os.environ["DEBUG_DIR"]
for role in ("primary", "secondary"):
    path = os.path.join(debug_dir, f"{role}-generated-pci-manifest-startup_disk_graph.json")
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    data.setdefault("qemu_guest_devices", []).extend([
        {"driver": "virtio-scsi-pci", "opts": {"id": "scsi0", "bus": "pci.6", "addr": "0x1"}},
        {"driver": "scsi-hd", "opts": {"id": "scsi0-0-0-0", "drive": "drive-scsi0-0-0-0", "bus": "scsi0.0"}},
    ])
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, sort_keys=True, indent=2)
        handle.write("\n")
PY
  fi

  cat > "${debug_dir}/primary-live-qemu-argv-${phase}.txt" <<'EOF'
-device
pcie-root-port,id=pci.1,bus=pcie.0,addr=0x2,chassis=1,port=0x10
-device
pcie-pci-bridge,id=pci.6,bus=pci.1,addr=0x0
-device
virtio-net-pci,netdev=hostnet0,id=net0,bus=pci.6,addr=0x0,mac=52:54:00:aa:bb:cc
EOF
  if [[ "${mode}" == "argv_missing" ]]; then
    cat > "${debug_dir}/secondary-live-qemu-argv-${phase}.txt" <<'EOF'
-device
pcie-root-port,id=pci.1,bus=pcie.0,addr=0x2,chassis=1,port=0x10
-device
virtio-net-pci,netdev=hostnet0,id=net0,bus=pci.6,addr=0x0,mac=52:54:00:aa:bb:cc
EOF
  else
    cp "${debug_dir}/primary-live-qemu-argv-${phase}.txt" "${debug_dir}/secondary-live-qemu-argv-${phase}.txt"
  fi
  if [[ "${mode}" == "scsi_child" ]]; then
    cat >> "${debug_dir}/primary-live-qemu-argv-${phase}.txt" <<'EOF'
-device
virtio-scsi-pci,id=scsi0,bus=pci.6,addr=0x1
-device
scsi-hd,drive=drive-scsi0-0-0-0,id=scsi0-0-0-0,bus=scsi0.0,channel=0,scsi-id=0,lun=0
EOF
    cp "${debug_dir}/primary-live-qemu-argv-${phase}.txt" "${debug_dir}/secondary-live-qemu-argv-${phase}.txt"
  fi

  cat > "${debug_dir}/primary-info-qtree-${phase}.txt" <<'EOF'
dev: pcie-root-port, id "pci.1"
dev: pcie-pci-bridge, id "pci.6"
dev: virtio-net-pci, id "net0"
EOF
  if [[ "${mode}" == "scsi_child" ]]; then
    cat >> "${debug_dir}/primary-info-qtree-${phase}.txt" <<'EOF'
dev: virtio-scsi-pci, id "scsi0"
dev: scsi-hd, id "scsi0-0-0-0"
EOF
  fi
  cp "${debug_dir}/primary-info-qtree-${phase}.txt" "${debug_dir}/secondary-info-qtree-${phase}.txt"

  cat > "${debug_dir}/primary-info-pci-${phase}.txt" <<'EOF'
  Bus  0, device   2, function 0:
    PCI bridge: PCI device 1b36:000c
      secondary bus 1.
      subordinate bus 2.
      BAR0: 32 bit memory at 0x82d47000 [0x82d47fff]
      id "pci.1"
  Bus  1, device   0, function 0:
    PCI bridge: PCI device 1b36:000e
      secondary bus 2.
      subordinate bus 2.
      BAR0: 64 bit memory at 0x82c00000 [0x82c000ff]
      id "pci.6"
  Bus  2, device   0, function 0:
    Ethernet controller: PCI device 1af4:1000
      BAR0: I/O at 0x6040 [0x607f]
      id "net0"
EOF
  if [[ "${mode}" == "scsi_child" ]]; then
    cat >> "${debug_dir}/primary-info-pci-${phase}.txt" <<'EOF'
  Bus  2, device   1, function 0:
    SCSI storage controller: PCI device 1af4:1004
      BAR0: I/O at 0x6080 [0x60bf]
      id "scsi0"
EOF
  fi
  if [[ "${mode}" == "pci_unassigned" ]]; then
    cat > "${debug_dir}/secondary-info-pci-${phase}.txt" <<'EOF'
  Bus  0, device   2, function 0:
    PCI bridge: PCI device 1b36:000c
      secondary bus 1.
      subordinate bus 2.
      BAR0: 32 bit memory at 0x82d47000 [0x82d47fff]
      id "pci.1"
  Bus  1, device   0, function 0:
    PCI bridge: PCI device 1b36:000e
      secondary bus 0.
      subordinate bus 0.
      BAR0: 64 bit memory (not mapped)
      id "pci.6"
  Bus  2, device   0, function 0:
    Ethernet controller: PCI device 1af4:1000
      BAR0: I/O at 0x6040 [0x607f]
      id "net0"
EOF
  else
    cp "${debug_dir}/primary-info-pci-${phase}.txt" "${debug_dir}/secondary-info-pci-${phase}.txt"
  fi

  cat > "${debug_dir}/primary-info-mtree-${phase}.txt" <<'EOF'
00000000febf0000-00000000febf0fff (prio 1, i/o): alias pci_bridge_mem @pci_bridge_pci 0000000000000000-0000000000000fff
EOF
  cp "${debug_dir}/primary-info-mtree-${phase}.txt" "${debug_dir}/secondary-info-mtree-${phase}.txt"
}

selftest_case_xcolo_materialization_pipeline_reports_argv_missing() (
  selftest_reset_env
  selftest_info "x-colo materialization pipeline reports argv missing layer"

  local vm="xcolo-materialization-argv-missing"
  local phase="before_migrate"
  ftctl_state_init_vm "${vm}"
  selftest_write_xcolo_materialization_pipeline_base "${vm}" "${phase}" "argv_missing"

  ftctl_xcolo_analyze_materialization_pipeline "${vm}" "${phase}" "selftest"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_materialization_pipeline")" \
    "failed" "materialization pipeline should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_materialization_failure_layer")" \
    "argv_missing" "argv missing layer recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_materialization_first_missing_id")" \
    "pci.6" "argv missing device id"
  selftest_assert_file_contains "$(ftctl_xcolo_debug_dir "${vm}")/materialization-pipeline-diff-${phase}.txt" \
    "failure_layer=argv_missing"
)

selftest_case_xcolo_materialization_pipeline_allows_scsi_bus_child_without_pci_endpoint() (
  selftest_reset_env
  selftest_info "x-colo materialization pipeline allows SCSI disk bus child without direct PCI endpoint"

  local vm="xcolo-materialization-scsi-child"
  local phase="after_migrate_materialization"
  ftctl_state_init_vm "${vm}"
  selftest_write_xcolo_materialization_pipeline_base "${vm}" "${phase}" "scsi_child"

  ftctl_xcolo_analyze_materialization_pipeline "${vm}" "${phase}" "selftest"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_materialization_pipeline")" \
    "ok" "SCSI child materialization should not require info pci endpoint"
  selftest_assert_file_contains "$(ftctl_xcolo_debug_dir "${vm}")/materialization-pipeline-${phase}.json" \
    '"device_class": "bus_child"'
  selftest_assert_file_contains "$(ftctl_xcolo_debug_dir "${vm}")/materialization-pipeline-${phase}.json" \
    '"id": "scsi0-0-0-0"'
)

selftest_case_xcolo_materialization_pipeline_reports_pci_unassigned() (
  selftest_reset_env
  selftest_info "x-colo materialization pipeline reports PCI unassigned layer"

  local vm="xcolo-materialization-pci-unassigned"
  local phase="before_migrate"
  ftctl_state_init_vm "${vm}"
  selftest_write_xcolo_materialization_pipeline_base "${vm}" "${phase}" "pci_unassigned"

  ftctl_xcolo_analyze_materialization_pipeline "${vm}" "${phase}" "selftest"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_materialization_pipeline")" \
    "failed" "materialization pipeline should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_materialization_failure_layer")" \
    "pci_unassigned" "PCI unassigned layer recorded"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_materialization_first_missing_id")" \
    "pci.6" "PCI unassigned device id"
  selftest_assert_file_contains "$(ftctl_xcolo_debug_dir "${vm}")/materialization-pipeline-${phase}.json" \
    '"resource_unassigned": true'
)

selftest_case_xcolo_primary_restore_detects_generated_graph() (
  selftest_reset_env
  selftest_info "x-colo primary restore detects generated FT block graph"

  local vm="xcolo-primary-restore-graph"
  local graph="" rc=0

  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp() {
    local _uri="${1-}" _domain="${2-}" _payload="${3-}" out_var="${4}" rc_var="${5}"
    : "${_uri}${_domain}${_payload}"
    printf -v "${out_var}" '%s' '{"return":[{"node-name":"ftctl-colo-sda"},{"node-name":"ftctl-primary-active-sda"}]}'
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_xcolo_primary_has_generated_block_graph "${vm}" graph || rc=$?
  selftest_assert_eq "${rc}" "0" "generated FT graph should be detected"
  selftest_assert_contains "${graph}" "ftctl-colo-sda" "graph evidence contains ftctl node"
)

selftest_case_xcolo_primary_internal_retry_enabled_by_default() (
  selftest_reset_env
  selftest_info "x-colo primary create retries KRBD ENOENT internally by default"

  local vm="xcolo-primary-internal-retry"
  local tmp_dir="${SELFTEST_ROOT}/primary-internal-retry"
  local bin_dir="${tmp_dir}/bin"
  local xml="${tmp_dir}/primary.generated.xml"
  local out_file="${tmp_dir}/stdout"
  local err_file="${tmp_dir}/stderr"
  local count_file="${tmp_dir}/virsh.count"
  local rc=0
  mkdir -p "${bin_dir}"
  cat > "${xml}" <<'XML'
<domain type='kvm'>
  <name>xcolo-primary-internal-retry</name>
  <devices>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/test'/>
      <target dev='sda' bus='scsi'/>
    </disk>
  </devices>
</domain>
XML
  : > "${out_file}"
  : > "${err_file}"
  : > "${count_file}"

  cat > "${bin_dir}/virsh" <<'SH'
#!/usr/bin/env bash
count_file="${FTCTL_SELFTEST_VIRSH_COUNT_FILE}"
count="$(cat "${count_file}" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "${count}" > "${count_file}"
printf "qemu-kvm: Could not open '/dev/rbd/rbd/test': No such file or directory\n" >&2
exit 1
SH
  chmod +x "${bin_dir}/virsh"

  ftctl_state_init_vm "${vm}"
  PATH="${bin_dir}:${PATH}"
  FTCTL_SELFTEST_VIRSH_COUNT_FILE="${count_file}"
  export FTCTL_SELFTEST_VIRSH_COUNT_FILE
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_XCOLO_PRIMARY_INTERNAL_CREATE_RETRY=""

  # shellcheck disable=SC2317
  ftctl_xcolo_prepare_primary_krbd_runtime_paths_from_xml() { return 0; }

  ftctl_xcolo_run_primary_generated_create_with_retry "${vm}" "${xml}" "${out_file}" "${err_file}" "1" || rc=$?
  selftest_assert_eq "${rc}" "1" "primary create still fails when retry also fails"
  selftest_assert_eq "$(cat "${count_file}")" "2" "virsh create should retry once by default"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_create_retry")" "1" "retry state recorded"
)

selftest_case_xcolo_channel_timeout_records_failure_reason() (
  selftest_reset_env
  selftest_info "x-colo channel attach timeout records classified reason"

  local vm="xcolo-channel-timeout-reason"
  local tmp_dir="${SELFTEST_ROOT}/channel-timeout"
  local handle rc=0
  mkdir -p "${tmp_dir}"
  handle="999999|${tmp_dir}/rc|${tmp_dir}/stdout|${tmp_dir}/stderr|${tmp_dir}"
  : > "${tmp_dir}/stdout"
  : > "${tmp_dir}/stderr"

  ftctl_state_init_vm "${vm}"
  FTCTL_XCOLO_MIRROR_PORT="9003"
  FTCTL_XCOLO_COMPARE_PORT="9004"

  # shellcheck disable=SC2317
  ftctl_xcolo_channel_connect_timeout_sec() { printf '%s\n' "1"; }
  # shellcheck disable=SC2317
  ftctl_xcolo_primary_create_async_done() { return 1; }
  # shellcheck disable=SC2317
  ftctl_xcolo_local_tcp_established_port_ready() { return 1; }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_socket_snapshot() { return 0; }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_qemu_log_tails() { return 0; }
  # shellcheck disable=SC2317
  ftctl_profile_secondary_vm_name_resolved() { printf '%s\n' "${1}-standby"; }
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_primary_channel_state() {
    local target_vm="${1-}"
    ftctl_state_set "${target_vm}" \
      "xcolo_channel_mirror_established=no" \
      "xcolo_channel_compare_established=no" \
      "xcolo_channel_mirror_listen=no" \
      "xcolo_channel_compare_listen=yes"
  }
  # shellcheck disable=SC2317
  sleep() { :; }

  ftctl_xcolo_wait_primary_peer_connections "${vm}" "${handle}" || rc=$?
  selftest_assert_eq "${rc}" "1" "channel attach should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_channel_attach_failure_reason")" \
    "mirror_listener_absent" "channel timeout reason"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_channel_attach_timeout" "channel timeout keeps stable last_error"
)

selftest_case_xcolo_primary_restore_ignores_domain_missing_destroy() (
  selftest_reset_env
  selftest_info "x-colo primary restore continues when generated domain is already missing"

  local vm="xcolo-primary-restore-missing-domain"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
    shift 4
    : "${_timeout}"
    case "$*" in
      *" destroy "*)
        printf -v "${out_var}" '%s' "error: failed to get domain '${vm}'"
        printf -v "${err_var}" '%s' ""
        printf -v "${rc_var}" '%s' "1"
        ;;
      *)
        printf -v "${out_var}" '%s' ""
        printf -v "${err_var}" '%s' ""
        printf -v "${rc_var}" '%s' "0"
        ;;
    esac
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_prepare_primary_krbd_runtime_paths_from_xml() { return 0; }
  # shellcheck disable=SC2317
  ftctl_primary_activate_from_backup() { return 0; }
  # shellcheck disable=SC2317
  ftctl_xcolo_primary_has_generated_block_graph() { return 1; }
  # shellcheck disable=SC2317
  ftctl_xcolo_primary_domain_state() { printf '%s\n' "running"; }

  ftctl_xcolo_force_primary_restore_from_backup "${vm}" "xcolo_channel_attach_timeout" || rc=$?
  selftest_assert_eq "${rc}" "0" "missing generated primary should not block restore"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "cloud_runtime_restore")" \
    "primary_running" "primary restore verified"
)

selftest_case_xcolo_primary_restore_continues_when_destroy_rc_and_domain_absent() (
  selftest_reset_env
  selftest_info "x-colo primary restore checks domstate when destroy rc is nonzero"

  local vm="xcolo-primary-restore-destroy-rc-domain-absent"
  local rc=0
  local domain_state="unknown"
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
    shift 4
    : "${_timeout}"
    case "$*" in
      *" destroy "*)
        printf -v "${out_var}" '%s' ""
        printf -v "${err_var}" '%s' "unexpected destroy transport error"
        printf -v "${rc_var}" '%s' "1"
        ;;
      *)
        printf -v "${out_var}" '%s' ""
        printf -v "${err_var}" '%s' ""
        printf -v "${rc_var}" '%s' "0"
        ;;
    esac
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_primary_domain_state() { printf '%s\n' "${domain_state}"; }
  # shellcheck disable=SC2317
  ftctl_xcolo_prepare_primary_krbd_runtime_paths_from_xml() { return 0; }
  # shellcheck disable=SC2317
  ftctl_primary_activate_from_backup() { domain_state="running"; return 0; }
  # shellcheck disable=SC2317
  ftctl_xcolo_primary_has_generated_block_graph() { return 1; }
  # shellcheck disable=SC2317
  ftctl_xcolo_end_primary_krbd_shutdown_guard() { return 0; }

  ftctl_xcolo_force_primary_restore_from_backup "${vm}" "xcolo_channel_attach_timeout" || rc=$?
  selftest_assert_eq "${rc}" "0" "unknown domstate should allow restore after destroy rc"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "cloud_runtime_restore")" \
    "primary_running" "primary restore verified"
)

selftest_case_xcolo_primary_disk_args_precede_listener_chardevs() (
  selftest_reset_env
  selftest_info "x-colo primary commandline opens disk graph before listener chardevs"

  local disk_args="-device;virtio-scsi-pci,id=scsi0,bus=pci.0,addr=0x9;-blockdev;driver=host_device,node-name=ftctl-primary-parent-sda-host,filename=/dev/rbd/rbd/root;-blockdev;driver=raw,node-name=ftctl-primary-parent-sda,file=ftctl-primary-parent-sda-host"
  local net_args="-S;-chardev;socket,id=compare1,host=0.0.0.0,port=9104,server=on,wait=off;-chardev;socket,id=mirror0,host=0.0.0.0,port=9103,server=on,wait=off"
  local primary_args drive_prefix chardev_prefix

  primary_args="$(ftctl_xcolo_qemu_args_append "${disk_args}" "${net_args}")"
  drive_prefix="${primary_args%%filename=/dev/rbd/rbd/root*}"
  chardev_prefix="${primary_args%%socket,id=compare1*}"
  [[ "${#drive_prefix}" -lt "${#chardev_prefix}" ]] || \
    selftest_fail "primary disk args must precede compare1 listener chardev"
)

selftest_case_xcolo_primary_listener_rejects_partial_compare_bootstrap() (
  selftest_reset_env
  selftest_info "x-colo primary listener gate rejects compare-only bootstrap"

  local vm="xcolo-listener-pair"
  local handle rc=0
  local tmp_dir="${SELFTEST_ROOT}/listener-pair"
  mkdir -p "${tmp_dir}"
  handle="999999|${tmp_dir}/rc|${tmp_dir}/stdout|${tmp_dir}/stderr|${tmp_dir}"
  : > "${tmp_dir}/stdout"
  : > "${tmp_dir}/stderr"

  FTCTL_XCOLO_MIRROR_PORT="9003"
  FTCTL_XCOLO_COMPARE_PORT="9004"
  FTCTL_XCOLO_COMPARE_LOCAL_PORT="9001"
  FTCTL_XCOLO_COMPARE_OUT_PORT="9005"
  FTCTL_XCOLO_MIRROR_WAIT="on"
  FTCTL_XCOLO_COMPARE_WAIT="on"
  ftctl_state_init_vm "${vm}"

  ftctl_xcolo_domain_create_timeout_sec() { printf '%s\n' "1"; }
  ftctl_xcolo_primary_create_async_done() { return 1; }
  ftctl_xcolo_local_tcp_listen_port_ready() {
    [[ "${1-}" == "9004" ]]
  }
  sleep() { :; }

  ftctl_xcolo_wait_primary_generated_listeners "${vm}" "${handle}" || rc=$?
  selftest_assert_eq "${rc}" "1" "compare-only listener bootstrap must fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_listener_wait_policy")" "wait_off_qmp_gated" "listener policy"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_listener_mirror_listen")" "no" "mirror listener missing"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_listener_compare_listen")" "yes" "compare listener present"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "xcolo_primary_listener_not_open" "listener error"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "primary.create_generated.listeners"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"reason":"primary_listener_not_open"'
)

selftest_case_xcolo_primary_listener_refreshes_krbd_paths() (
  selftest_reset_env
  selftest_info "x-colo primary listener wait refreshes KRBD stable paths"

  local vm="xcolo-listener-krbd-refresh"
  local tmp_dir="${SELFTEST_ROOT}/listener-krbd-refresh"
  local xml="${tmp_dir}/primary.xml"
  local handle rc=0 refresh_log="${tmp_dir}/refresh.log"
  mkdir -p "${tmp_dir}"
  cat > "${xml}" <<'XML'
<domain type='kvm'>
  <name>xcolo-listener-krbd-refresh</name>
  <devices>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/xcolo-listener-root'/>
      <target dev='sda' bus='scsi'/>
    </disk>
  </devices>
</domain>
XML
  handle="999999|${tmp_dir}/rc|${tmp_dir}/stdout|${tmp_dir}/stderr|${tmp_dir}"
  : > "${tmp_dir}/stdout"
  : > "${tmp_dir}/stderr"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "primary_xml_generated=${xml}"
  FTCTL_XCOLO_MIRROR_PORT="9003"
  FTCTL_XCOLO_COMPARE_PORT="9004"
  FTCTL_XCOLO_MIRROR_WAIT="on"
  FTCTL_XCOLO_COMPARE_WAIT="on"

  ftctl_xcolo_domain_create_timeout_sec() { printf '%s\n' "1"; }
  ftctl_xcolo_primary_create_async_done() { return 1; }
  ftctl_xcolo_local_tcp_listen_port_ready() { [[ "${1-}" == "9003" || "${1-}" == "9004" ]]; }
  ftctl_xcolo_verify_primary_krbd_qemu_namespace() { return 0; }
  ftctl_xcolo_prepare_primary_krbd_runtime_path() {
    printf '%s|%s|%s\n' "${1-}" "${2-}" "${3-}" >> "${refresh_log}"
    return 0
  }
  sleep() { :; }

  ftctl_xcolo_wait_primary_generated_listeners "${vm}" "${handle}" || rc=$?
  selftest_assert_eq "${rc}" "0" "listener wait should pass"
  selftest_assert_file_contains "${refresh_log}" "wait_listener_remap"
  selftest_assert_file_contains "${refresh_log}" "listener_ready_remap"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_krbd_refresh_phase")" \
    "listener_ready" "listener ready refresh phase"
)

selftest_case_xcolo_primary_peer_wait_refreshes_krbd_paths() (
  selftest_reset_env
  selftest_info "x-colo primary peer wait refreshes KRBD stable paths"

  local vm="xcolo-peer-krbd-refresh"
  local tmp_dir="${SELFTEST_ROOT}/peer-krbd-refresh"
  local xml="${tmp_dir}/primary.xml"
  local handle rc=0 refresh_log="${tmp_dir}/refresh.log"
  mkdir -p "${tmp_dir}"
  cat > "${xml}" <<'XML'
<domain type='kvm'>
  <name>xcolo-peer-krbd-refresh</name>
  <devices>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/xcolo-peer-root'/>
      <target dev='sda' bus='scsi'/>
    </disk>
  </devices>
</domain>
XML
  handle="999999|${tmp_dir}/rc|${tmp_dir}/stdout|${tmp_dir}/stderr|${tmp_dir}"
  : > "${tmp_dir}/stdout"
  : > "${tmp_dir}/stderr"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "primary_xml_generated=${xml}"
  FTCTL_XCOLO_MIRROR_PORT="9003"
  FTCTL_XCOLO_COMPARE_PORT="9004"

  ftctl_xcolo_channel_connect_timeout_sec() { printf '%s\n' "1"; }
  ftctl_xcolo_primary_create_async_done() { return 1; }
  ftctl_xcolo_local_tcp_established_port_ready() { return 0; }
  ftctl_xcolo_capture_primary_channel_state() { return 0; }
  ftctl_xcolo_prepare_primary_krbd_runtime_path() {
    printf '%s|%s|%s\n' "${1-}" "${2-}" "${3-}" >> "${refresh_log}"
    return 0
  }
  sleep() { :; }

  ftctl_xcolo_wait_primary_peer_connections "${vm}" "${handle}" || rc=$?
  selftest_assert_eq "${rc}" "0" "peer wait should pass"
  selftest_assert_file_contains "${refresh_log}" "wait_peer_attach_remap"
  selftest_assert_file_contains "${refresh_log}" "peer_attached_remap"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_krbd_refresh_phase")" \
    "peer_attached" "peer attached refresh phase"
)

selftest_case_cloud_managed_rollback_cleanup_does_not_restart_secondary() (
  selftest_reset_env
  selftest_info "cloud-managed FT rollback cleanup does not recreate secondary runtime"

  local vm="xcolo-cloud-cleanup"
  local call_log="${SELFTEST_ROOT}/cloud-cleanup-calls.log"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "secondary_vm_name=${vm}-standby"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"

  ftctl_virsh() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
    shift 4
    : "${_timeout}"
    printf '%s\n' "$*" >> "${call_log}"
    case "$*" in
      *" domstate "*)
        printf -v "${out_var}" '%s' ""
        printf -v "${err_var}" '%s' "error: failed to get domain"
        printf -v "${rc_var}" '%s' "1"
        ;;
      *)
        printf -v "${out_var}" '%s' ""
        printf -v "${err_var}" '%s' ""
        printf -v "${rc_var}" '%s' "0"
        ;;
    esac
  }

  ftctl_standby_cleanup_cloud_managed_runtime "${vm}" "${vm}-standby"

  selftest_assert_file_contains "${call_log}" "destroy ${vm}-standby"
  selftest_assert_file_contains "${call_log}" "domstate ${vm}-standby"
  selftest_assert_file_not_contains "${call_log}" "create"
  selftest_assert_file_not_contains "${call_log}" "start ${vm}-standby"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "stopped" "secondary runtime marked stopped"
)

selftest_case_events_json() {
  selftest_reset_env
  selftest_info "events json output"

  cat > "${SELFTEST_ROOT}/log/events.log" <<EOF
{"ts":"2026-04-18T10:00:00+09:00","scan_id":"s1","vm":"vm-a","stage":"health","event":"reconcile.tick","result":"ok"}
{"ts":"2026-04-18T10:01:00+09:00","scan_id":"s2","vm":"vm-b","stage":"failover","event":"failover.request","result":"warn"}
{"ts":"2026-04-18T10:02:00+09:00","scan_id":"s3","vm":"vm-a","stage":"rearm","event":"rearm.defer","result":"warn","details":{"reason":"backoff"}}
EOF

  local out=""
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" events --config "${SELFTEST_CONFIG}" --vm vm-a --limit 2 --json)"
  selftest_assert_contains "${out}" '"command":"events"' "events json command"
  selftest_assert_contains "${out}" '"result":"ok"' "events json result"
  selftest_assert_contains "${out}" '"count":2' "events count"
  selftest_assert_contains "${out}" '"event":"rearm.defer"' "events latest item"
}

selftest_case_dr_runtime_profile_status_cancel() {
  selftest_reset_env
  selftest_info "FTCTL_DR runtime profile, status, and cancel path"

  local profile="${SELFTEST_ROOT}/dr-profile.json"
  local out="" status="" canceled=""
  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-step3",
  "runUuid": "run-step3",
  "direction": "KVM_TO_VMWARE",
  "activeSide": "SOURCE",
  "mapping": {
    "source": {
      "hardware": {
        "sourceVmRef": "vm-test",
        "sourceHostUuid": "host-a",
        "sourceHostName": "host-a-name",
        "instanceName": "i-2-100-VM",
        "firmware": "EFI",
        "secureBoot": true,
        "fingerprint": "sha256:test-source-hardware"
      }
    },
    "target": {
      "hardware": {
        "bootType": "UEFI",
        "bootMode": "SECURE",
        "ioPolicy": "io_uring",
        "ioThreadsEnabled": true
      }
    }
  },
  "request": {
    "mode": "planned",
    "remoteMoldSecretKey": "plain-secret"
  }
}
JSON

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-plan-apply \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step3 \
    --profile-json "${profile}" \
    --role coordinator \
    --dry-run \
    --json)"
  selftest_assert_contains "${out}" '"command":"dr-plan-apply"' "plan apply command"
  selftest_assert_contains "${out}" '"capable":true' "plan apply capable"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step3 \
    --run run-step3 \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"result":"accepted"' "sync start accepted"
  selftest_assert_contains "${out}" '"state":"SYNCING"' "sync state"
  selftest_assert_contains "${out}" '"step":"sync-start-accepted"' "sync step"
  selftest_assert_contains "${out}" '"external_job_ref":"run-step3"' "external job ref"
  selftest_assert_not_contains "${out}" "plain-secret" "sync output redacts secret"

  selftest_assert_file_contains "${SELFTEST_ROOT}/run/dr-runtime/plans/plan-step3/profile.json" '"remoteMoldSecretKey":"REDACTED"'
  selftest_assert_file_not_contains "${SELFTEST_ROOT}/run/dr-runtime/plans/plan-step3/profile.json" "plain-secret"

  status="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step3 \
    --run run-step3 \
    --events-offset 0 \
    --events-limit 20 \
    --json)"
  python3 -c 'import json,sys; value=json.load(sys.stdin); assert isinstance(value, dict)' <<< "${status}"
  selftest_assert_contains "${status}" '"command":"dr-status"' "status command"
  selftest_assert_contains "${status}" '"state":"SYNCING"' "status state"
  selftest_assert_contains "${status}" '"progress":1' "status progress"
  selftest_assert_contains "${status}" '"events_offset":' "status event offset"
  selftest_assert_contains "${status}" '"events_next_offset":' "status next event offset"
  selftest_assert_contains "${status}" '"events_truncated":' "status event truncation marker"
  selftest_assert_contains "${status}" '"source_firmware":"EFI"' "status source firmware"
  selftest_assert_contains "${status}" '"source_secure_boot":true' "status source secure boot"
  selftest_assert_contains "${status}" '"source_hardware_fingerprint_version":"2"' "status stable hardware fingerprint version"
  selftest_assert_not_contains "${status}" '"source_hardware_fingerprint":"sha256:test-source-hardware"' "status replaces legacy placement fingerprint"
  selftest_assert_contains "${status}" '"target_boot_type":"UEFI"' "status target boot type"
  selftest_assert_contains "${status}" '"target_boot_mode":"SECURE"' "status target boot mode"
  selftest_assert_contains "${status}" '"target_io_policy":"io_uring"' "status target io policy"
  selftest_assert_contains "${status}" '"target_iothreads":true' "status target iothreads"

  ftctl_log_event "dr-runtime" "dr.foreign" "ok" "" "" \
    "plan=plan-foreign run=run-foreign"
  status="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step3 \
    --run run-step3 \
    --events-offset 0 \
    --events-limit 20 \
    --json)"
  selftest_assert_not_contains "${status}" 'plan-foreign' "status excludes foreign plan events"

  # Completed-cycle metrics are Plan authority fields, while retryability is
  # scoped to the operation Run returned by this status request.
  ftctl_dr_runtime_path_set "$(ftctl_dr_runtime_status_path plan-step3)" \
    "latest_completed_incremental_verified=True" \
    "latest_completed_metrics_estimated=False"
  ftctl_dr_runtime_path_set "$(ftctl_dr_runtime_run_path plan-step3 run-step3)" \
    "retryable=True"
  status="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step3 \
    --run run-step3 \
    --events-limit 0 \
    --json)"
  python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["latest_completed_incremental_verified"] is True; assert value["latest_completed_metrics_estimated"] is False; assert value["retryable"] is True; assert value["events"] == []' <<< "${status}"

  canceled="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-cancel \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step3 \
    --run run-step3 \
    --json)"
  selftest_assert_contains "${canceled}" '"command":"dr-cancel"' "cancel command"
  selftest_assert_contains "${canceled}" '"result":"canceled"' "cancel result"
  selftest_assert_contains "${canceled}" '"accepted":true' "cancel accepted"

  status="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step3 \
    --run run-step3 \
    --json)"
  selftest_assert_contains "${status}" '"state":"CANCELED"' "status canceled"
  selftest_assert_contains "${status}" '"progress":100' "cancel progress"

  rm -f "${SELFTEST_ROOT}/run/dr-runtime/plans/plan-step3/profile.json"
  status="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step3 \
    --run run-step3 \
    --events-limit 0 \
    --json)"
  python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["profile_exists"] is False; assert value["source_firmware"] == ""; assert value["target_io_policy"] == ""' <<< "${status}"
}

selftest_case_dr_target_materialization_manifest_v2() {
  selftest_reset_env
  selftest_info "FTCTL_DR target materialization manifest v2 ownership contract"

  local plan="plan-materialization-v2" run="run-materialization-v2" retry_run="run-materialization-retry"
  local profile="${SELFTEST_ROOT}/dr-materialization-profile.json"
  local volume_map manifest digest out status rc=0
  cat > "${profile}" <<JSON
{"version":1,"engine":"FTCTL_DR","planUuid":"${plan}","direction":"VMWARE_TO_KVM","request":{"mode":"planned"}}
JSON
  bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --run "${run}" \
    --profile-json "${profile}" \
    --json >/dev/null

  volume_map='{"disks":[{"diskIndex":0,"targetVolumeId":"501","targetDiskRef":"rbd/target-volume-501"}]}'
  manifest="{\"contractVersion\":2,\"planUuid\":\"${plan}\",\"runUuid\":\"${run}\",\"replicaId\":41,\"ownershipGeneration\":2,\"targetVm\":{\"vmId\":\"301\",\"externalRef\":\"i-2-301-VM\",\"observedPowerState\":\"POWERED_OFF\"},\"targetVolumeMap\":${volume_map}}"
  digest="$(printf '%s' "${manifest}" | sha256sum | awk '{print $1}')"
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-target-materialized \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --run "${run}" \
    --target-vm-id 301 \
    --target-external-ref i-2-301-VM \
    --target-vm-name target-vm \
    --target-volume-map-json "${volume_map}" \
    --materialization-spec-json "${manifest}" \
    --materialization-spec-sha256 "${digest}" \
    --json)"
  selftest_assert_contains "${out}" '"result":"ok"' "materialization manifest accepted"
  selftest_assert_contains "${out}" '"state":"READY"' "materialization state ready"

  status="$(ftctl_dr_runtime_status_path "${plan}")"
  selftest_assert_file_contains "${status}" "materialization_contract_version=2"
  selftest_assert_file_contains "${status}" "materialization_replica_id=41"
  selftest_assert_file_contains "${status}" "materialization_ownership_generation=2"
  selftest_assert_file_contains "${status}" "materialization_spec_sha256=${digest}"
  selftest_assert_file_contains "${status}" "materialization_ownership_fingerprint_sha256="
  selftest_assert_file_contains "${status}" "materialization_observed_power_state=POWERED_OFF"

  manifest="{\"contractVersion\":2,\"planUuid\":\"${plan}\",\"runUuid\":\"${retry_run}\",\"replicaId\":41,\"ownershipGeneration\":2,\"targetVm\":{\"vmId\":\"301\",\"externalRef\":\"i-2-301-VM\",\"observedPowerState\":\"POWERED_ON\"},\"targetVolumeMap\":${volume_map}}"
  digest="$(printf '%s' "${manifest}" | sha256sum | awk '{print $1}')"
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-target-materialized \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${retry_run}" \
    --target-vm-id 301 --target-external-ref i-2-301-VM \
    --target-volume-map-json "${volume_map}" \
    --materialization-spec-json "${manifest}" \
    --materialization-spec-sha256 "${digest}" --json)"
  selftest_assert_contains "${out}" '"result":"ok"' "same ownership accepts a new run and power observation"

  manifest="{\"contractVersion\":2,\"planUuid\":\"${plan}\",\"runUuid\":\"${run}\",\"replicaId\":41,\"ownershipGeneration\":1,\"targetVm\":{\"vmId\":\"301\",\"externalRef\":\"i-2-301-VM\",\"observedPowerState\":\"POWERED_OFF\"},\"targetVolumeMap\":${volume_map}}"
  digest="$(printf '%s' "${manifest}" | sha256sum | awk '{print $1}')"
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-target-materialized \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${run}" \
    --target-vm-id 301 --target-external-ref i-2-301-VM \
    --target-volume-map-json "${volume_map}" \
    --materialization-spec-json "${manifest}" \
    --materialization-spec-sha256 "${digest}" --json 2>/dev/null)" || rc=$?
  selftest_assert_eq "${rc}" "79" "stale ownership generation exit"
  selftest_assert_contains "${out}" '"error_code":"DR_MATERIALIZATION_STALE_GENERATION"' "stale ownership generation is typed"

  rc=0
  volume_map='{"disks":[{"diskIndex":0,"targetVolumeId":"999","targetDiskRef":"rbd/foreign-volume"}]}'
  manifest="{\"contractVersion\":2,\"planUuid\":\"${plan}\",\"runUuid\":\"${run}\",\"replicaId\":41,\"ownershipGeneration\":2,\"targetVm\":{\"vmId\":\"301\",\"externalRef\":\"i-2-301-VM\",\"observedPowerState\":\"POWERED_OFF\"},\"targetVolumeMap\":${volume_map}}"
  digest="$(printf '%s' "${manifest}" | sha256sum | awk '{print $1}')"
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-target-materialized \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${run}" \
    --target-vm-id 301 --target-external-ref i-2-301-VM \
    --target-volume-map-json "${volume_map}" \
    --materialization-spec-json "${manifest}" \
    --materialization-spec-sha256 "${digest}" --json 2>/dev/null)" || rc=$?
  selftest_assert_eq "${rc}" "79" "same-generation ownership conflict exit"
  selftest_assert_contains "${out}" '"error_code":"DR_MATERIALIZATION_GENERATION_CONFLICT"' "same-generation target change is typed"
}

selftest_case_dr_runtime_control_actions() {
  selftest_reset_env
  selftest_info "FTCTL_DR runtime control actions"

  local profile="${SELFTEST_ROOT}/dr-control-profile.json"
  local out=""
  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-control",
  "direction": "KVM_TO_KVM",
  "request": {
    "mode": "planned"
  }
}

JSON

  bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-control \
    --run run-control \
    --profile-json "${profile}" \
    --json >/dev/null

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-pause \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-control \
    --run run-pause \
    --profile-json "${profile}" \
    --json)"
  selftest_assert_contains "${out}" '"state":"PAUSED"' "pause state"
  selftest_assert_contains "${out}" '"progress":100' "pause progress"

  local resume_rc=0
  set +e
  out="$(FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC=1 bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-resume \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-control \
    --run run-resume \
    --profile-json "${profile}" \
    --json 2>&1)"
  resume_rc="$?"
  set -e
  [[ "${resume_rc}" != "0" ]] || selftest_fail "resume must not report RUNNING without an owned scheduler"
  selftest_assert_contains "${out}" 'DR_SCHEDULER_NOT_RUNNING' "resume scheduler ownership failure"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-release \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-control \
    --run run-release \
    --profile-json "${profile}" \
    --force \
    --json)"
  selftest_assert_contains "${out}" '"state":"RELEASED"' "release state"
  selftest_assert_contains "${out}" '"step":"release-completed"' "release step"
  local release_tombstone="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-control/release.json"
  [[ -f "${release_tombstone}" ]] || selftest_fail "release tombstone must be persisted"
  selftest_assert_file_contains "${release_tombstone}" '"contract_version":"dr-release-tombstone-v1"'
  selftest_assert_file_contains "${release_tombstone}" '"vm_mutated":false'
  [[ ! -f "${SELFTEST_ROOT}/run/dr-runtime/plans/plan-control/profile.json" ]] \
    || selftest_fail "release must remove the active DR profile"
}

selftest_case_dr_plan_scoped_control_protocol() {
  selftest_reset_env
  selftest_info "FTCTL_DR plan-scoped control protocol and checkpoint lease"

  local plan="plan-control-v2" run="run-control-v2"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local scheduler_dir="${plan_dir}/scheduler"
  local run_path="${plan_dir}/runs/${run}.state"
  local producer_run="run-sync-authority"
  local producer_run_path="${plan_dir}/runs/${producer_run}.state"
  local status_path="${plan_dir}/status.state"
  local generation="" lease_path="" ack_pid="" capabilities="" worker_pid="" worker_start_ticks=""
  local dr_command=""

  for dr_command in dr-sync-start dr-sync-recover dr-sync-pause dr-sync-resume \
      dr-test-failover dr-failover dr-failback dr-release dr-future-operation; do
    if ftctl_command_requires_lock "${dr_command}" ""; then
      selftest_fail "DR command must not use the legacy global lock: ${dr_command}"
    fi
  done

  mkdir -p "${scheduler_dir}" "$(dirname "${run_path}")"
  cat > "${run_path}" <<EOF
plan=${plan}
run=${run}
state=SYNCING
scheduler_state=RUNNING
EOF
  cp -f "${run_path}" "${status_path}"

  bash -c 'while true; do sleep 1; done' -- --plan "${plan}" &
  worker_pid="$!"
  worker_start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${worker_pid}")"
  ftctl_state_write_kv_all "$(ftctl_dr_scheduler_active_pid_path "${plan}")" \
    "pid=${worker_pid}" \
    "start_ticks=${worker_start_ticks}" \
    "scheduler_session_uuid=${plan}" \
    "lease_epoch=1" \
    "worker_run_uuid=${producer_run}" \
    "heartbeat_at=$(ftctl_now_iso8601)"
  (
    local control_path control_generation
    control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
    while [[ ! -f "${control_path}" ]]; do sleep 1; done
    control_generation="$(ftctl_state_read_kv "${control_path}" generation)"
    ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "PAUSED" "IDLE" "${producer_run}" \
      "${plan}" "1" "${worker_pid}" "${worker_start_ticks}"
  ) &
  ack_pid="$!"
  generation="$(ftctl_dr_scheduler_request_and_wait "${plan}" pause PAUSED test-failover "${run}" true)"
  wait "${ack_pid}"
  kill "${worker_pid}" 2>/dev/null || true
  wait "${worker_pid}" 2>/dev/null || true

  selftest_assert_eq "${generation}" "1" "first control generation"
  selftest_assert_file_contains "$(ftctl_dr_scheduler_control_path "${plan}")" "version=4"
  selftest_assert_file_contains "$(ftctl_dr_scheduler_control_path "${plan}")" "generation=1"
  selftest_assert_file_contains "$(ftctl_dr_scheduler_control_ack_path "${plan}")" "state=PAUSED"
  selftest_assert_file_contains "$(ftctl_dr_scheduler_control_ack_path "${plan}")" "cycle_state=IDLE"

  bash -c 'while true; do sleep 1; done' -- --plan "${plan}" &
  worker_pid="$!"
  worker_start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${worker_pid}")"
  ftctl_state_write_kv_all "$(ftctl_dr_scheduler_active_pid_path "${plan}")" \
    "pid=${worker_pid}" \
    "start_ticks=${worker_start_ticks}" \
    "scheduler_session_uuid=${plan}" \
    "lease_epoch=2" \
    "worker_run_uuid=${producer_run}" \
    "heartbeat_at=$(ftctl_now_iso8601)"
  (
    local control_path control_generation
    control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
    while [[ "$(ftctl_state_read_kv "${control_path}" command 2>/dev/null || true)" != "stop" ]]; do
      sleep 1
    done
    control_generation="$(ftctl_state_read_kv "${control_path}" generation)"
    kill "${worker_pid}" 2>/dev/null || true
    wait "${worker_pid}" 2>/dev/null || true
    rm -f "$(ftctl_dr_scheduler_active_pid_path "${plan}")"
    ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "STOPPED" "IDLE" "${producer_run}" \
      "${plan}" "2" "${worker_pid}" "${worker_start_ticks}"
  ) &
  ack_pid="$!"
  generation="$(FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC=5 \
    ftctl_dr_scheduler_request_and_wait "${plan}" stop STOPPED failback-abort "${run}" false)"
  wait "${ack_pid}"
  selftest_assert_eq "${generation}" "2" "terminal STOPPED acknowledgement generation"
  selftest_assert_file_contains "$(ftctl_dr_scheduler_control_ack_path "${plan}")" "state=STOPPED"
  selftest_assert_file_contains "$(ftctl_dr_scheduler_control_ack_path "${plan}")" "generation=2"

  lease_path="$(ftctl_dr_scheduler_checkpoint_lease_acquire "${plan}" 7 "${run}" "ftctl:${plan}:${run}:7")"
  selftest_assert_file_contains "${lease_path}" "state=LEASED"
  selftest_assert_file_contains "${lease_path}" "checkpoint_sequence=7"
  ftctl_dr_scheduler_checkpoint_lease_release "${plan}" 7
  [[ ! -e "${lease_path}" ]] || selftest_fail "checkpoint lease should be released"

  capabilities="$(ftctl_dr_runtime_capabilities 1)"
  selftest_assert_contains "${capabilities}" '"runtime_schema_version":"20260727"' "control schema version"
  selftest_assert_contains "${capabilities}" '"cutover-manifest-v2"' "cutover manifest capability"
  selftest_assert_contains "${capabilities}" '"control-protocol-v2"' "control protocol capability"
  selftest_assert_contains "${capabilities}" '"control-protocol-v3"' "control protocol v3 capability"
  selftest_assert_contains "${capabilities}" '"control-protocol-v4"' "control protocol v4 capability"
  selftest_assert_contains "${capabilities}" '"dr-scheduler-singleton-v1"' "singleton scheduler capability"
  selftest_assert_contains "${capabilities}" '"checkpoint-lease"' "checkpoint lease capability"
  selftest_assert_contains "${capabilities}" '"file-checkpoint-invariance-v1"' "immutable file checkpoint capability"
  selftest_assert_contains "${capabilities}" \
    '"reprotect_authority_contract_versions":["2026-07-23","2026-08-26"]' \
    "reprotect authority contracts are advertised from the runtime gate"
}

selftest_case_dr_ablestack_target_prepare() {
  selftest_reset_env
  selftest_info "FTCTL_DR ABLESTACK target prepare driver"

  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/qemu-img.log"
  local profile="${SELFTEST_ROOT}/dr-ablestack-profile.json"
  local out="" manifest=""
  mkdir -p "${fakebin}" "${SELFTEST_ROOT}/src" "${SELFTEST_ROOT}/target"
  : > "${SELFTEST_ROOT}/src/root.qcow2"
  cat > "${fakebin}/qemu-img" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
if [[ "\$1" == "create" ]]; then
  args=("\$@")
  target="\${args[\${#args[@]}-2]}"
  : > "\${target}"
  exit 0
fi
if [[ "\$1" == "info" ]]; then
  printf '{"format":"qcow2","virtual-size":1048576}\n'
  exit 0
fi
if [[ "\$1" == "convert" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"

  cat > "${profile}" <<JSON
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-step4",
  "runUuid": "run-step4",
  "direction": "KVM_TO_KVM",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP"},
  "target": {
    "provider": "ABLESTACK",
    "driver": "ABLESTACK",
    "zoneId": "zone-1",
    "storageRef": "${SELFTEST_ROOT}/target",
    "serviceOfferingId": "service-offering-1",
    "networks": [{"networkId": "network-1"}]
  },
  "mapping": {
    "disks": [
      {
        "device": "vda",
        "sourcePath": "${SELFTEST_ROOT}/src/root.qcow2",
        "targetPath": "${SELFTEST_ROOT}/target/root.qcow2",
        "sourceFormat": "qcow2",
        "targetFormat": "qcow2",
        "sizeBytes": 1048576,
        "targetDiskOfferingId": "disk-offering-1"
      }
    ]
  }
}
JSON

  out="$(FTCTL_DR_SYNC_FOREGROUND=1 FTCTL_DR_SCHEDULER_DISABLE=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step4 \
    --run run-step4 \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"state":"SYNCING"' "prepare state"
  selftest_assert_contains "${out}" '"step":"ablestack-targets-prepared"' "prepare step"
  selftest_assert_contains "${out}" '"progress":5' "prepare progress"
  selftest_assert_contains "${out}" '"driver":"ABLESTACK"' "prepare driver"
  selftest_assert_contains "${out}" '"driver_state":"TARGET_PREPARED"' "prepare driver state"
  selftest_assert_file_contains "${call_log}" "create -f qcow2 ${SELFTEST_ROOT}/target/root.qcow2 1048576"
  manifest="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-step4/manifests/run-step4-manifest.json"
  selftest_assert_file_contains "${manifest}" '"phase":"target-prepared"'
  selftest_assert_file_contains "${manifest}" '"targetPath":"'"${SELFTEST_ROOT}"'/target/root.qcow2"'
  selftest_assert_file_contains "${SELFTEST_ROOT}/run/dr-runtime/plans/plan-step4/checkpoints/run-step4-checkpoint.json" '"state":"TARGET_PREPARED"'
}

selftest_case_dr_ablestack_rbd_target_prepare_preserves_empty_source_format() {
  selftest_reset_env
  selftest_info "FTCTL_DR ABLESTACK RBD target prepare preserves empty source format"

  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/rbd.log"
  local profile="${SELFTEST_ROOT}/dr-ablestack-rbd-profile.json"
  local out="" manifest=""
  mkdir -p "${fakebin}" "${SELFTEST_ROOT}/src"
  cat > "${fakebin}/rbd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
if [[ "\$1" == "info" ]]; then
  exit 2
fi
if [[ "\$1" == "create" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${fakebin}/rbd"

  cat > "${profile}" <<JSON
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-step4-rbd",
  "runUuid": "run-step4-rbd",
  "direction": "KVM_TO_KVM",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP"},
  "target": {
    "provider": "ABLESTACK",
    "driver": "ABLESTACK",
    "zoneId": "zone-1",
    "storageRef": "Primary",
    "serviceOfferingId": "service-offering-1",
    "networks": [{"networkId": "network-1"}]
  },
  "mapping": {
    "disks": [
      {
        "device": "scsi0:0",
        "sourcePath": "2000",
        "targetName": "root-rbd",
        "sourceFormat": "",
        "targetFormat": "raw",
        "sizeBytes": 1048576,
        "targetStorageType": "RBD",
        "targetStoragePath": "rbd",
        "targetStorageKrbdPath": "/dev/rbd",
        "targetDiskOfferingId": "disk-offering-1"
      }
    ]
  }
}
JSON

  out="$(FTCTL_DR_SYNC_FOREGROUND=1 FTCTL_DR_SCHEDULER_DISABLE=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step4-rbd \
    --run run-step4-rbd \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"state":"SYNCING"' "rbd prepare state"
  selftest_assert_contains "${out}" '"step":"ablestack-targets-prepared"' "rbd prepare step"
  selftest_assert_file_contains "${call_log}" "create --image-format 2 --size 1 rbd/root-rbd"
  manifest="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-step4-rbd/manifests/run-step4-rbd-manifest.json"
  selftest_assert_file_contains "${manifest}" '"targetPath":"/dev/rbd/rbd/root-rbd"'
  selftest_assert_file_contains "${manifest}" '"targetType":"rbd"'
  selftest_assert_file_contains "${manifest}" '"sourceFormat":""'
}

selftest_case_dr_ablestack_full_seed_once() {
  selftest_reset_env
  selftest_info "FTCTL_DR ABLESTACK full seed driver"

  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/qemu-img-full-seed.log"
  local profile="${SELFTEST_ROOT}/dr-ablestack-full-seed-profile.json"
  local out=""
  mkdir -p "${fakebin}" "${SELFTEST_ROOT}/src" "${SELFTEST_ROOT}/target"
  : > "${SELFTEST_ROOT}/src/root.qcow2"
  cat > "${fakebin}/qemu-img" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
if [[ "\$1" == "create" ]]; then
  args=("\$@")
  target="\${args[\${#args[@]}-2]}"
  : > "\${target}"
  exit 0
fi
if [[ "\$1" == "info" ]]; then
  printf '{"format":"qcow2","virtual-size":1048576}\n'
  exit 0
fi
if [[ "\$1" == "convert" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"

  cat > "${profile}" <<JSON
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-step4-full",
  "runUuid": "run-step4-full",
  "direction": "KVM_TO_KVM",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP"},
  "target": {
    "provider": "ABLESTACK",
    "driver": "ABLESTACK",
    "zoneId": "zone-1",
    "storageRef": "${SELFTEST_ROOT}/target",
    "serviceOfferingId": "service-offering-1",
    "networks": [{"networkId": "network-1"}]
  },
  "request": {"performFullSeed": true},
  "mapping": {
    "disks": [
      {
        "device": "vda",
        "sourcePath": "${SELFTEST_ROOT}/src/root.qcow2",
        "targetPath": "${SELFTEST_ROOT}/target/root.qcow2",
        "sourceFormat": "qcow2",
        "targetFormat": "qcow2",
        "sizeBytes": 1048576,
        "targetDiskOfferingId": "disk-offering-1"
      }
    ]
  }
}
JSON

  out="$(FTCTL_DR_SYNC_FOREGROUND=1 FTCTL_DR_SCHEDULER_DISABLE=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step4-full \
    --run run-step4-full \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=true \
    --json)"
  selftest_assert_contains "${out}" '"state":"READY"' "full seed state"
  selftest_assert_contains "${out}" '"step":"ablestack-full-seed-complete"' "full seed step"
  selftest_assert_contains "${out}" '"progress":100' "full seed progress"
  selftest_assert_contains "${out}" '"driver_state":"TARGET_READY"' "full seed driver state"
  selftest_assert_contains "${out}" '"target_ready_rpo_seconds":' "full seed rpo field"
  selftest_assert_file_contains "${call_log}" "convert --force-share -p -n -S"
  selftest_assert_file_contains "${SELFTEST_ROOT}/run/dr-runtime/plans/plan-step4-full/checkpoints/run-step4-full-checkpoint.json" '"state":"TARGET_READY"'
}

selftest_case_dr_ablestack_missing_disk_map_waits() {
  selftest_reset_env
  selftest_info "FTCTL_DR ABLESTACK missing disk map waits"

  local profile="${SELFTEST_ROOT}/dr-ablestack-missing-map-profile.json"
  local out="" rc=0
  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-step4-wait",
  "runUuid": "run-step4-wait",
  "direction": "KVM_TO_KVM",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP"},
  "target": {"provider": "ABLESTACK", "driver": "ABLESTACK"}
}
JSON

  out="$(FTCTL_DR_SYNC_FOREGROUND=1 bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-step4-wait \
    --run run-step4-wait \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)" || rc=$?
  [[ "${rc}" != "0" ]] || selftest_fail "missing disk map sync should fail"
  selftest_assert_contains "${out}" '"result":"error"' "missing map result"
  selftest_assert_contains "${out}" '"accepted":false' "missing map accepted false"
  selftest_assert_contains "${out}" '"state":"ERROR"' "missing map state"
  selftest_assert_contains "${out}" '"step":"ablestack-disk-map-pending"' "missing map step"
  selftest_assert_contains "${out}" '"driver_state":"WAITING_FOR_DISK_MAP"' "missing map driver state"
  selftest_assert_contains "${out}" '"error_code":"DR_TARGET_DISK_MAPPING_INVALID"' "missing map error code"
}

selftest_case_dr_ablestack_vmware_source_size_unresolved() {
  selftest_reset_env
  selftest_info "FTCTL_DR ABLESTACK target rejects VMware source disk with unresolved size"

  local fakebin="${SELFTEST_ROOT}/fakebin"
  local profile="${SELFTEST_ROOT}/dr-ablestack-vmware-zero-size-profile.json"
  local out="" rc=0
  mkdir -p "${fakebin}" "${SELFTEST_ROOT}/target"
  cat > "${fakebin}/qemu-img" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"
  cat > "${profile}" <<JSON
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-vmware-to-kvm-size",
  "runUuid": "run-vmware-to-kvm-size",
  "direction": "VMWARE_TO_KVM",
  "source": {"provider": "VMWARE", "driver": "VMWARE_CBT"},
  "policy": {"cbtPolicy": {"required": false}},
  "target": {
    "provider": "ABLESTACK",
    "driver": "ABLESTACK",
    "zoneId": "zone-1",
    "storageRef": "${SELFTEST_ROOT}/target",
    "serviceOfferingId": "service-offering-1",
    "networks": [{"networkId": "network-1"}]
  },
  "mapping": {
    "disks": [
      {"device": "scsi0:0", "sourcePath": "2000", "targetPath": "${SELFTEST_ROOT}/target/root.qcow2", "targetFormat": "qcow2", "sizeBytes": 0, "targetDiskOfferingId": "disk-offering-1"}
    ]
  }
}
JSON

  out="$(FTCTL_DR_SYNC_FOREGROUND=1 FTCTL_DR_VMWARE_FORCE_VDDK_READY=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-vmware-to-kvm-size \
    --run run-vmware-to-kvm-size \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)" || rc=$?
  [[ "${rc}" != "0" ]] || selftest_fail "VMware source disk with unresolved size should fail"
  selftest_assert_contains "${out}" '"result":"error"' "unresolved size result"
  selftest_assert_contains "${out}" '"state":"ERROR"' "unresolved size state"
  selftest_assert_contains "${out}" '"step":"ablestack-target-map-invalid"' "unresolved size step"
  selftest_assert_contains "${out}" '"error_code":"DR_TARGET_DISK_SIZE_UNRESOLVED"' "unresolved size error code"
  selftest_assert_contains "${out}" '"target_disk_invalid_count":1' "unresolved size invalid disk count"
}

selftest_case_dr_vmware_preflight_missing_vddk() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware preflight reports missing VDDK"

  local profile="${SELFTEST_ROOT}/dr-vmware-preflight-profile.json"
  local out=""
  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-vmware-preflight",
  "direction": "KVM_TO_VMWARE",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP"},
  "target": {"provider": "VMWARE", "driver": "VMWARE_VDDK"}
}
JSON

  out="$(FTCTL_DR_VMWARE_FORCE_MISSING_VDDK=1 bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-plan-apply \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-vmware-preflight \
    --profile-json "${profile}" \
    --role coordinator \
    --dry-run \
    --json)"
  selftest_assert_contains "${out}" '"command":"dr-plan-apply"' "vmware preflight command"
  selftest_assert_contains "${out}" '"capable":false' "vmware preflight capable false"
  selftest_assert_contains "${out}" '"error_code":"DR_VDDK_LIBDIR_UNRESOLVED"' "vmware preflight error code"
  selftest_assert_contains "${out}" '"driver":"VMWARE"' "vmware preflight details"
}

selftest_case_dr_vmware_contract_ready() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware contract-ready metadata path"

  local profile="${SELFTEST_ROOT}/dr-vmware-contract-profile.json"
  local fakebin="${SELFTEST_ROOT}/fakebin"
  local out="" manifest="" checkpoint=""
  mkdir -p "${fakebin}"
  cat > "${fakebin}/qemu-img" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"
  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-vmware-ready",
  "runUuid": "run-vmware-ready",
  "direction": "VMWARE_TO_VMWARE",
  "source": {
    "provider": "VMWARE",
    "driver": "VMWARE_CBT",
    "vmId": "vm-101",
    "vcenterRef": "vc-a"
  },
  "target": {
    "provider": "VMWARE",
    "driver": "VMWARE_VDDK",
    "vmId": "vm-201"
  },
  "policy": {
    "cbtPolicy": {
      "required": false
    }
  },
  "mapping": {
    "targetStorageRef": "ds-dr",
    "targetFolderPath": "/DR",
    "targetComputeRef": "rp-dr",
    "targetNetworkRef": "net-dr",
    "disks": [
      {
        "device": "scsi0:0",
        "sourceVmdkPath": "[prod] vm-101/root.vmdk",
        "targetVmdkPath": "[dr] vm-201/root.vmdk",
        "sizeBytes": 1048576,
        "targetDiskOfferingId": "disk-offering-1",
        "changeId": "52 00 01",
        "snapshotRef": "snap-1"
      }
    ]
  }
}
JSON

  out="$(FTCTL_DR_VMWARE_FORCE_VDDK_READY=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-plan-apply \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-vmware-ready \
    --profile-json "${profile}" \
    --role coordinator \
    --dry-run \
    --json)"
  selftest_assert_contains "${out}" '"capable":true' "vmware preflight capable true"
  selftest_assert_contains "${out}" '"disk_count":1' "vmware preflight disk count"
  selftest_assert_contains "${out}" '"vddk_ready":true' "vmware preflight vddk ready"

  out="$(FTCTL_DR_SYNC_FOREGROUND=1 FTCTL_DR_SCHEDULER_DISABLE=1 FTCTL_DR_VMWARE_FORCE_VDDK_READY=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-vmware-ready \
    --run run-vmware-ready \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"result":"accepted"' "vmware sync accepted"
  selftest_assert_contains "${out}" '"state":"SYNCING"' "vmware sync state"
  selftest_assert_contains "${out}" '"step":"vmware-driver-contract-ready"' "vmware sync step"
  selftest_assert_contains "${out}" '"driver":"VMWARE"' "vmware sync driver"
  selftest_assert_contains "${out}" '"driver_state":"VMWARE_CONTRACT_READY"' "vmware sync driver state"
  manifest="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-vmware-ready/manifests/run-vmware-ready-vmware-manifest.json"
  checkpoint="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-vmware-ready/checkpoints/run-vmware-ready-vmware-checkpoint.json"
  selftest_assert_file_contains "${manifest}" '"phase":"vmware-contract-ready"'
  selftest_assert_file_contains "${manifest}" '"datastoreRef":"ds-dr"'
  selftest_assert_file_contains "${manifest}" '"resourcePoolRef":"rp-dr"'
  selftest_assert_file_contains "${manifest}" '"networkRef":"net-dr"'
  selftest_assert_file_contains "${manifest}" '"changeId":"52 00 01"'
  selftest_assert_file_contains "${checkpoint}" '"state":"VMWARE_CONTRACT_READY"'
}

selftest_case_dr_vmware_cbt_preflight_uses_runtime_credentials_file() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware CBT preflight uses runtime credentials file"

  local profile="${SELFTEST_ROOT}/dr-vmware-cbt-runtime-credential-profile.json"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-vmware-cbt-runtime-credential"
  local credentials="${plan_dir}/credentials.json"
  local compat_root="${SELFTEST_ROOT}/compat/vsphere80"
  local govc_bin="${compat_root}/bin/govc"
  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/govc-cbt-runtime-credential.log"
  local out="" cbt_status=""

  mkdir -p "${plan_dir}" "${compat_root}/bin" "${compat_root}/vddk" "${fakebin}"
  : > "${call_log}"
  cat > "${fakebin}/qemu-img" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"
  cat > "${govc_bin}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'GOVC:%s\n' "$*" >> "${FTCTL_FAKE_GOVC_LOG}"
case "${1-}" in
  about)
    printf 'Name: VMware vCenter Server\n'
    printf 'Version: 8.0.1\n'
    exit 0
    ;;
  vm.info)
    cat <<'JSON'
{
  "VirtualMachines": [
    {
      "Config": {
        "ChangeTrackingEnabled": false,
        "Hardware": {
          "Device": [
            {
              "Key": 1000,
              "BusNumber": 0,
              "SharedBus": "noSharing",
              "DeviceInfo": {"Label": "SCSI controller 0"}
            },
            {
              "Key": 2000,
              "ControllerKey": 1000,
              "UnitNumber": 0,
              "Backing": {"FileName": "[datastore] Rocky10/Rocky10.vmdk"},
              "DeviceInfo": {"Label": "Hard disk 1"}
            }
          ]
        },
        "ExtraConfig": [
          {"Key": "ctkEnabled", "Value": "TRUE"},
          {"Key": "scsi0:0.ctkEnabled", "Value": "TRUE"}
        ]
      }
    }
  ]
}
JSON
    exit 0
    ;;
  snapshot.tree)
    printf '{"Elements":[]}\n'
    exit 0
    ;;
  vm.change)
    exit 0
    ;;
esac
exit 2
EOF
  chmod +x "${govc_bin}"

  cat > "${credentials}" <<JSON
{
  "version": 1,
  "credentials": {
    "source": {
      "endpoint": "10.10.21.10",
      "principal": "administrator@ablecloud.local",
      "auth": {"password": "secret"},
      "tlsVerify": false,
      "vddkLibdir": "${compat_root}/vddk",
      "vddkVersion": "8"
    }
  }
}
JSON
  chmod 0600 "${credentials}"

  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-vmware-cbt-runtime-credential",
  "runUuid": "run-vmware-cbt-runtime-credential",
  "direction": "VMWARE_TO_VMWARE",
  "source": {
    "provider": "VMWARE",
    "driver": "VMWARE_CBT",
    "externalRef": "vm-4486"
  },
  "target": {
    "provider": "VMWARE",
    "driver": "VMWARE_VDDK",
    "vmId": "vm-201"
  },
  "mapping": {
    "targetStorageRef": "ds-dr",
    "targetFolderPath": "/DR",
    "targetComputeRef": "rp-dr",
    "targetNetworkRef": "net-dr",
    "disks": [
      {
        "sourceDiskKey": "2000",
        "sourceVmdkPath": "[datastore] Rocky10/Rocky10.vmdk",
        "targetVmdkPath": "[dr] vm-201/root.vmdk",
        "sizeBytes": 1048576,
        "targetDiskOfferingId": "disk-offering-1",
        "changeId": "52 00 01",
        "snapshotRef": "snap-1"
      }
    ]
  }
}
JSON

  out="$(FTCTL_FAKE_GOVC_LOG="${call_log}" FTCTL_DR_SYNC_FOREGROUND=1 FTCTL_DR_SCHEDULER_DISABLE=1 FTCTL_DR_VMWARE_FORCE_VDDK_READY=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-vmware-cbt-runtime-credential \
    --run run-vmware-cbt-runtime-credential \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)"

  selftest_assert_contains "${out}" '"result":"accepted"' "vmware cbt runtime credential accepted"
  selftest_assert_contains "${out}" '"step":"vmware-driver-contract-ready"' "vmware cbt runtime credential step"
  selftest_assert_contains "${out}" '"cbt_status":' "vmware cbt status projected"
  selftest_assert_contains "${out}" '"cbtDiskId":"scsi0:0"' "vmware cbt status disk id projected"
  selftest_assert_file_contains "${call_log}" "GOVC:about"
  selftest_assert_file_contains "${call_log}" "GOVC:vm.info -json vm-4486"
  cbt_status="${plan_dir}/vmware-cbt.json"
  selftest_assert_file_contains "${cbt_status}" '"enabled":false'
  selftest_assert_file_contains "${cbt_status}" '"lifecycleState":"CONFIGURED_PENDING_ACTIVATION"'
  selftest_assert_file_contains "${cbt_status}" '"vmConfigSignal":"FALSE"'
  selftest_assert_file_contains "${cbt_status}" '"cbtDiskId":"scsi0:0"'
  selftest_assert_file_contains "${cbt_status}" '"resolution":"vm-device-graph"'
  selftest_assert_file_not_contains "${cbt_status}" "secret"
}

selftest_case_dr_vmware_cbt_activation_evidence_promotes_active() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware CBT snapshot evidence promotes ACTIVE"

  local status_path="${SELFTEST_ROOT}/vmware-cbt-status.json"
  local evidence_path="${SELFTEST_ROOT}/vmware-cbt-evidence.json"
  cat > "${status_path}" <<'JSON'
{"schemaVersion":2,"driver":"VMWARE","phase":"cbt-preflight","lifecycleState":"CONFIGURED_PENDING_ACTIVATION","enabled":false,"vmConfigSignal":"FALSE"}
JSON
  cat > "${evidence_path}" <<'JSON'
[{"diskId":"scsi0:0","changeId":"52 88 fe","querySucceeded":true}]
JSON

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  ftctl_vmware_mover_publish_cbt_active "${status_path}" "${evidence_path}" "ftctl-run-snapshot" "snapshot-101"

  selftest_assert_file_contains "${status_path}" '"lifecycleState":"ACTIVE"'
  selftest_assert_file_contains "${status_path}" '"enabled":true'
  selftest_assert_file_contains "${status_path}" '"querySucceeded":true'
  selftest_assert_file_contains "${status_path}" '"snapshotRef":"snapshot-101"'
}

selftest_case_dr_vmware_cbt_full_seed_verifies_current_change_id() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware full seed verifies current snapshot changeId"

  local fake_python="${SELFTEST_ROOT}/fake-cbt-python"
  local helper="${SELFTEST_ROOT}/fake-cbt-helper.py"
  local password_file="${SELFTEST_ROOT}/vcenter-password"
  local output_path="${SELFTEST_ROOT}/cbt-query.json"
  local call_log="${SELFTEST_ROOT}/cbt-query.args"
  cat > "${fake_python}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${FTCTL_FAKE_CBT_ARGS}"
printf '{"new_change_id":"52 current","vmdk_path":"[ds] vm/disk-000001.vmdk","areas":[],"activation_verified":true}\n'
EOF
  chmod +x "${fake_python}"
  printf '# mock helper\n' > "${helper}"
  printf 'secret' > "${password_file}"

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  FTCTL_DR_VMWARE_CBT_PYTHON="${fake_python}" \
  FTCTL_DR_VMWARE_CBT_QUERY_HELPER="${helper}" \
  FTCTL_FAKE_CBT_ARGS="${call_log}" \
    ftctl_vmware_mover_query_cbt "https://vcenter/sdk" "user" "${password_file}" false "" \
      "vm-101" "run-snapshot" "scsi0:0" "" "${output_path}" true

  selftest_assert_file_contains "${call_log}" "--verify-current"
  selftest_assert_file_contains "${output_path}" '"activation_verified":true'
}

selftest_case_dr_vmware_missing_disk_map_config_incomplete() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware missing disk map reports config incomplete"

  local fakebin="${SELFTEST_ROOT}/fakebin"
  local profile="${SELFTEST_ROOT}/dr-vmware-missing-disk-map-profile.json"
  local out="" checkpoint=""
  mkdir -p "${fakebin}"
  cat > "${fakebin}/qemu-img" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"
  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-vmware-config-incomplete",
  "runUuid": "run-vmware-config-incomplete",
  "direction": "VMWARE_TO_VMWARE",
  "source": {"provider": "VMWARE", "driver": "VMWARE_CBT", "vmId": "vm-101"},
  "target": {"provider": "VMWARE", "driver": "VMWARE_VDDK", "vmId": "vm-201"}
}
JSON

  out="$(FTCTL_DR_SYNC_FOREGROUND=1 FTCTL_DR_SCHEDULER_DISABLE=1 FTCTL_DR_VMWARE_FORCE_VDDK_READY=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-vmware-config-incomplete \
    --run run-vmware-config-incomplete \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"state":"CONFIG_INCOMPLETE"' "vmware missing disk map state"
  selftest_assert_contains "${out}" '"step":"vmware-disk-map-pending"' "vmware missing disk map step"
  selftest_assert_contains "${out}" '"driver_state":"CONFIG_INCOMPLETE"' "vmware missing disk map driver state"
  selftest_assert_contains "${out}" '"error_code":"DR_TARGET_MAPPING_INVALID"' "vmware missing disk map error code"
  checkpoint="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-vmware-config-incomplete/checkpoints/run-vmware-config-incomplete-vmware-checkpoint.json"
  selftest_assert_file_contains "${checkpoint}" '"state":"CONFIG_INCOMPLETE"'
}

selftest_case_dr_vmware_missing_vddk_blocks_sync() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware missing VDDK blocks sync start"

  local profile="${SELFTEST_ROOT}/dr-vmware-missing-vddk-profile.json"
  local fakebin="${SELFTEST_ROOT}/fakebin"
  local out="" rc=0
  mkdir -p "${fakebin}"
  cat > "${fakebin}/qemu-img" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"
  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-vmware-missing",
  "runUuid": "run-vmware-missing",
  "direction": "VMWARE_TO_VMWARE",
  "source": {"provider": "VMWARE", "driver": "VMWARE_CBT", "vmId": "vm-101"},
  "target": {"provider": "VMWARE", "driver": "VMWARE_VDDK", "vmId": "vm-201"},
  "mapping": {
    "disks": [
      {
        "device": "scsi0:0",
        "sourceVmdkPath": "[prod] vm-101/root.vmdk",
        "targetVmdkPath": "[dr] vm-201/root.vmdk",
        "sizeBytes": 1048576,
        "targetDiskOfferingId": "disk-offering-1"
      }
    ]
  }
}
JSON

  out="$(FTCTL_DR_SYNC_FOREGROUND=1 FTCTL_DR_VMWARE_FORCE_MISSING_VDDK=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-vmware-missing \
    --run run-vmware-missing \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)" || rc=$?
  [[ "${rc}" != "0" ]] || selftest_fail "vmware missing VDDK sync should fail"
  selftest_assert_contains "${out}" '"result":"error"' "vmware missing sync result"
  selftest_assert_contains "${out}" '"accepted":false' "vmware missing sync accepted false"
  selftest_assert_contains "${out}" '"state":"ERROR"' "vmware missing sync state"
  selftest_assert_contains "${out}" '"step":"vmware-capability-missing"' "vmware missing sync step"
  selftest_assert_contains "${out}" '"error_code":"DR_VDDK_LIBDIR_UNRESOLVED"' "vmware missing sync error code"
  selftest_assert_contains "${out}" '"driver_state":"MISSING_VDDK"' "vmware missing sync driver state"
}

selftest_case_dr_scheduler_ablestack_checkpoint_loop() {
  selftest_reset_env
  selftest_info "FTCTL_DR scheduler ABLESTACK checkpoint loop"

  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/qemu-img-scheduler.log"
  local profile="${SELFTEST_ROOT}/dr-scheduler-ablestack-profile.json"
  local out="" restore_points="" convert_count=""
  mkdir -p "${fakebin}" "${SELFTEST_ROOT}/src" "${SELFTEST_ROOT}/target"
  : > "${SELFTEST_ROOT}/src/root.qcow2"
  cat > "${fakebin}/qemu-img" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
if [[ "\$1" == "create" ]]; then
  args=("\$@")
  target="\${args[\${#args[@]}-2]}"
  : > "\${target}"
  exit 0
fi
if [[ "\$1" == "info" ]]; then
  printf '{"format":"qcow2","virtual-size":1048576}\n'
  exit 0
fi
if [[ "\$1" == "convert" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"
  cat > "${fakebin}/virsh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"query-named-block-nodes"* ]]; then
  printf '{"return":[{"node-name":"libvirt-2-format","drv":"qcow2","active":true,"image":{"filename":"${SELFTEST_ROOT}/src/root.qcow2","virtual-size":1048576}}]}\n'
  exit 0
fi
exit 1
EOF
  chmod +x "${fakebin}/virsh"

  cat > "${profile}" <<JSON
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-scheduler-ablestack",
  "runUuid": "run-scheduler-ablestack",
  "direction": "KVM_TO_KVM",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP", "instanceName": "i-test-scheduler-VM"},
  "target": {
    "provider": "ABLESTACK",
    "driver": "ABLESTACK",
    "zoneId": "zone-1",
    "storageRef": "${SELFTEST_ROOT}/target",
    "serviceOfferingId": "service-offering-1",
    "networks": [{"networkId": "network-1"}]
  },
  "schedule": {"intervalSeconds": 1},
  "request": {"maxCycles": 2},
  "mapping": {
    "disks": [
      {
        "device": "vda",
        "sourcePath": "${SELFTEST_ROOT}/src/root.qcow2",
        "targetPath": "${SELFTEST_ROOT}/target/root.qcow2",
        "sourceFormat": "qcow2",
        "targetFormat": "qcow2",
        "sizeBytes": 1048576,
        "targetDiskOfferingId": "disk-offering-1"
      }
    ]
  }
}
JSON

  out="$(FTCTL_DR_SYNC_FOREGROUND=1 FTCTL_DR_SCHEDULER_FOREGROUND=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-scheduler-ablestack \
    --run run-scheduler-ablestack \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"state":"READY"' "scheduler completed state"
  selftest_assert_contains "${out}" '"step":"scheduler-completed"' "scheduler completed step"
  selftest_assert_contains "${out}" '"scheduler_state":"COMPLETED"' "scheduler completed flag"
  selftest_assert_contains "${out}" '"checkpoint_sequence":2' "scheduler checkpoint sequence"
  selftest_assert_contains "${out}" '"current_checkpoint_sequence":2' "scheduler current checkpoint sequence"
  selftest_assert_contains "${out}" '"current_checkpoint_state":"COMPLETED"' "scheduler current checkpoint state"
  selftest_assert_contains "${out}" '"latest_completed_checkpoint_sequence":2' "scheduler completed checkpoint sequence"
  selftest_assert_contains "${out}" '"latest_completed_checkpoint_ref":"ftctl:plan-scheduler-ablestack:run-scheduler-ablestack:2"' "scheduler completed checkpoint ref"
  selftest_assert_contains "${out}" '"latest_completed_checkpoint_state":"READY"' "scheduler completed checkpoint state"
  selftest_assert_contains "${out}" '"latest_completed_producer_run_uuid":"run-scheduler-ablestack"' "scheduler completed producer run"
  selftest_assert_contains "${out}" '"driver_state":"CHECKPOINT_READY"' "scheduler driver state"
  restore_points="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-scheduler-ablestack/restore-points.jsonl"
  selftest_assert_eq "$(wc -l < "${restore_points}" | tr -d '[:space:]')" "2" "restore point count"
  selftest_assert_file_contains "${restore_points}" '"cycleType":"full-seed"'
  selftest_assert_file_contains "${restore_points}" '"cycleType":"incremental"'
  selftest_assert_file_contains "${restore_points}" '"checkpointRef":"ftctl:plan-scheduler-ablestack:run-scheduler-ablestack:2"'
  selftest_assert_file_contains "${restore_points}" '"producerRunUuid":"run-scheduler-ablestack"'
  convert_count="$(grep -c -- "convert --force-share -p -n -S" "${call_log}")"
  selftest_assert_eq "${convert_count}" "2" "scheduler convert count"
}

selftest_case_dr_scheduler_vmware_mock_checkpoint_loop() {
  selftest_reset_env
  selftest_info "FTCTL_DR scheduler VMware mock checkpoint loop"

  local fakebin="${SELFTEST_ROOT}/fakebin"
  local profile="${SELFTEST_ROOT}/dr-scheduler-vmware-profile.json"
  local out="" restore_points="" checkpoint=""
  mkdir -p "${fakebin}"
  cat > "${fakebin}/qemu-img" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"
  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-scheduler-vmware",
  "runUuid": "run-scheduler-vmware",
  "direction": "VMWARE_TO_VMWARE",
  "source": {"provider": "VMWARE", "driver": "VMWARE_CBT", "vmId": "vm-101", "vcenterRef": "vc-a"},
  "target": {"provider": "VMWARE", "driver": "VMWARE_VDDK", "vmId": "vm-201", "datastoreRef": "ds-dr"},
  "policy": {"cbtPolicy": {"required": false}},
  "schedule": {"intervalSeconds": 1},
  "request": {"maxCycles": 2},
  "mapping": {
    "disks": [
      {
        "device": "scsi0:0",
        "sourceVmdkPath": "[prod] vm-101/root.vmdk",
        "targetVmdkPath": "[dr] vm-201/root.vmdk",
        "sizeBytes": 1048576,
        "targetDiskOfferingId": "disk-offering-1",
        "changeId": "52 00 01",
        "snapshotRef": "snap-1",
        "baselineGeneration": 1,
        "baselineState": "LOCAL_DURABLE"
      }
    ]
  }
}
JSON

  out="$(FTCTL_DR_VMWARE_FORCE_VDDK_READY=1 FTCTL_DR_VMWARE_MOCK_CYCLE=1 FTCTL_DR_SCHEDULER_FOREGROUND=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-scheduler-vmware \
    --run run-scheduler-vmware \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"state":"READY"' "vmware scheduler completed state"
  selftest_assert_contains "${out}" '"step":"scheduler-completed"' "vmware scheduler completed step"
  selftest_assert_contains "${out}" '"driver":"VMWARE"' "vmware scheduler driver"
  selftest_assert_contains "${out}" '"checkpoint_sequence":2' "vmware scheduler checkpoint sequence"
  selftest_assert_contains "${out}" '"current_checkpoint_state":"COMPLETED"' "vmware scheduler current checkpoint state"
  selftest_assert_contains "${out}" '"latest_completed_checkpoint_sequence":2' "vmware scheduler completed checkpoint sequence"
  selftest_assert_contains "${out}" '"latest_completed_checkpoint_ref":"ftctl:plan-scheduler-vmware:run-scheduler-vmware:2"' "vmware scheduler completed checkpoint ref"
  selftest_assert_contains "${out}" '"latest_completed_producer_run_uuid":"run-scheduler-vmware"' "vmware scheduler completed producer run"
  restore_points="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-scheduler-vmware/restore-points.jsonl"
  selftest_assert_eq "$(wc -l < "${restore_points}" | tr -d '[:space:]')" "2" "vmware restore point count"
  selftest_assert_file_contains "${restore_points}" '"cycleType":"incremental"'
  selftest_assert_file_contains "${restore_points}" '"checkpointRef":"ftctl:plan-scheduler-vmware:run-scheduler-vmware:2"'
  checkpoint="${SELFTEST_ROOT}/run/dr-runtime/plans/plan-scheduler-vmware/checkpoints/run-scheduler-vmware-cycle-2-vmware-checkpoint.json"
  selftest_assert_file_contains "${checkpoint}" '"state":"TARGET_READY"'
  selftest_assert_file_contains "${SELFTEST_ROOT}/run/dr-runtime/plans/plan-scheduler-vmware/manifests/run-scheduler-vmware-cycle-2-vmware-manifest.json" '"phase":"vmware-incremental-complete"'
}

selftest_case_dr_guestprep_manifest_preserves_vmware_boot_contract() {
  selftest_reset_env
  selftest_info "FTCTL_DR guest preparation preserves VMware EFI and Secure Boot metadata"

  local session="${SELFTEST_ROOT}/dr-guestprep-session.json"
  local manifest="${SELFTEST_ROOT}/dr-guestprep-manifest.json"
  cat > "${session}" <<'JSON'
{
  "planUuid": "plan-guestprep",
  "runUuid": "run-guestprep",
  "request": {"networkMode": "ISOLATED"},
  "profile": {
    "mapping": {
      "source": {
        "hardware": {"firmware": "efi", "secureBoot": true, "cpu": 4, "memoryMb": 8192},
        "workload": {"name": "Rocky10-1", "guestFamily": "linux", "guestId": "rockylinux64Guest"}
      },
      "target": {"hardware": {"bootType": "UEFI", "bootMode": "SECURE"}, "cpuNumber": 4, "memory": 8192}
    }
  },
  "testArtifacts": {
    "path": "/var/lib/ablestack/ftctl/test/plan-guestprep",
    "records": [
      {"device": "sda", "state": "CREATED", "type": "rbd-clone", "clone": "rbd:rbd/plan-guestprep-test", "sizeBytes": 21474836480}
    ]
  }
}
JSON

  ftctl_guestprep_write_manifest "${session}" "${manifest}" "ftctl-dr-test-plan-guestprep"
  selftest_assert_eq "$(jq -r '.source.vm.firmware' "${manifest}")" "efi" "guestprep firmware"
  selftest_assert_eq "$(jq -r '.source.vm.secure_boot' "${manifest}")" "true" "guestprep secure boot"
  selftest_assert_eq "$(jq -r '.source.vm.cpu' "${manifest}")" "4" "guestprep cpu"
  selftest_assert_eq "$(jq -r '.source.vm.memory_mb' "${manifest}")" "8192" "guestprep memory"
  selftest_assert_eq "$(jq -r '.target.storage.type' "${manifest}")" "rbd" "guestprep RBD target"
  selftest_assert_eq "$(jq -r '.disks[0].transfer.target_path' "${manifest}")" "rbd:rbd/plan-guestprep-test" "guestprep target disk"
}

selftest_case_dr_cutover_manifest_v2_normalizes_runtime_disk_map() {
  selftest_reset_env
  selftest_info "FTCTL_DR real failover manifest joins VMware hardware, durable checkpoint, and RBD disk map"

  local root="${SELFTEST_ROOT}/dr-cutover-manifest-v2"
  local profile="${root}/profile.json"
  local disk_map="${root}/ablestack-disks.json"
  local checkpoint="${root}/checkpoint.json"
  local restore_points="${root}/restore-points.jsonl"
  local status="${root}/status.state"
  local manifest="${root}/cutover-manifest.json"
  local tool="${LIB_BASE}/ftctl/guestprep_manifest.py"
  mkdir -p "${root}"

  cat > "${profile}" <<'JSON'
{
  "planUuid":"plan-cutover-v2",
  "runUuid":"run-cutover-v2",
  "direction":"VMWARE_TO_KVM",
  "mapping":{
    "source":{
      "vm":{"name":"w22-01","guestId":"windows2019srvNext_64Guest"},
      "hardware":{"firmware":"efi","secureBoot":true,"cpu":4,"memoryMb":8192}
    },
    "target":{"hardware":{"bootType":"UEFI","bootMode":"SECURE","rootDiskController":"scsi"},"ioPolicy":"io_uring","ioThreads":true}
  }
}
JSON
  cat > "${disk_map}" <<'JSON'
{
  "planUuid":"plan-cutover-v2",
  "count":2,
  "disks":[
    {"sourceDiskKey":"2000","device":"sda","sizeBytes":42949672960,"targetType":"rbd","targetFormat":"raw","targetPath":"/dev/rbd/rbd/w22-01-dr-disk-0"},
    {"sourceDiskKey":"2001","device":"sdb","sizeBytes":10737418240,"targetType":"rbd","targetFormat":"raw","targetPath":"rbd:rbd/w22-01-dr-disk-1"}
  ]
}
JSON
  cat > "${checkpoint}" <<'JSON'
{"state":"TARGET_READY","commitState":"LOCAL_DURABLE","checkpointSequence":418,"sourceCheckpointAt":"2026-07-22T02:45:20Z","targetDurableAt":"2026-07-22T02:45:23Z","targetReadyRpoSeconds":3}
JSON
  cat > "${restore_points}" <<JSON
{"planUuid":"plan-cutover-v2","runUuid":"run-sync","checkpointSequence":418,"checkpoint":"${checkpoint}","state":"TARGET_READY","targetDurableAt":"2026-07-22T02:45:23Z"}
JSON
  cat > "${status}" <<EOF
plan=plan-cutover-v2
run=run-sync
state=READY
checkpoint_sequence=418
checkpoint_path=${checkpoint}
restore_points_path=${restore_points}
last_target_durable_at=2026-07-22T02:45:23Z
EOF

  python3 "${tool}" build \
    --profile "${profile}" \
    --disk-map "${disk_map}" \
    --restore-points "${restore_points}" \
    --status "${status}" \
    --plan plan-cutover-v2 \
    --run run-cutover-v2 \
    --output "${manifest}" >/dev/null
  python3 "${tool}" validate --manifest "${manifest}" >/dev/null

  selftest_assert_eq "$(jq -r '.schemaVersion' "${manifest}")" "FTCTL_GUESTPREP_MANIFEST_V2" "cutover schema"
  selftest_assert_eq "$(jq -r '.source.vm.guestFamily' "${manifest}")" "windows" "cutover guest family"
  selftest_assert_eq "$(jq -r '.source.vm.firmware' "${manifest}")" "efi" "cutover firmware"
  selftest_assert_eq "$(jq -r '.source.vm.secure_boot' "${manifest}")" "true" "cutover secure boot"
  selftest_assert_eq "$(jq -r '.checkpoint.sequence' "${manifest}")" "418" "cutover checkpoint"
  selftest_assert_eq "$(jq -r '.disks | length' "${manifest}")" "2" "cutover disk count"
  selftest_assert_eq "$(jq -r '.disks[0].transfer.target_path' "${manifest}")" "rbd:rbd/w22-01-dr-disk-0" "legacy krbd normalization"
  selftest_assert_eq "$(jq -r '.target.ioPolicy' "${manifest}")" "io_uring" "cutover io policy"

  jq '.disks[0].targetPath="w22-01-dr-disk-0"' "${disk_map}" > "${disk_map}.invalid"
  if python3 "${tool}" build \
      --profile "${profile}" \
      --disk-map "${disk_map}.invalid" \
      --restore-points "${restore_points}" \
      --status "${status}" \
      --plan plan-cutover-v2 \
      --run run-cutover-invalid \
      --output "${manifest}.invalid" >/dev/null 2>&1; then
    selftest_fail "display-only RBD locator must be rejected"
  fi
}

selftest_case_dr_runtime_test_failover_cleanup() {
  local cloud_managed="${1:-false}"
  selftest_reset_env
  selftest_info "FTCTL_DR test failover selects restore point and cleanup returns READY"

  local plan="plan-test-session"
  local profile="${SELFTEST_ROOT}/dr-test-session-profile.json"
  local artifact_spec="${SELFTEST_ROOT}/dr-test-session-artifact-spec.json"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local restore_points="${plan_dir}/restore-points.jsonl"
  local checkpoint1="${plan_dir}/checkpoints/cycle-1-checkpoint.json"
  local checkpoint2="${plan_dir}/checkpoints/cycle-2-checkpoint.json"
  local manifest1="${plan_dir}/manifests/cycle-1-manifest.json"
  local manifest2="${plan_dir}/manifests/cycle-2-manifest.json"
  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/qemu-img-test-session.log"
  local status_path="${plan_dir}/status.state"
  local session_path="" artifact_dir="" guestprep_manifest="" out="" cleanup="" ack_pid=""
  local scheduler_pid="" scheduler_start_ticks=""

  mkdir -p "${plan_dir}/checkpoints" "${plan_dir}/manifests" "${fakebin}" "${SELFTEST_ROOT}/target"
  cat > "${fakebin}/qemu-img" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
case "\${1-}" in
  info)
    printf '%s\n' '{"format":"qcow2","virtual-size":4194304}'
    ;;
  check) exit 0 ;;
  convert)
    target="\${@: -1}"
    truncate -s 4M "\${target}"
    ;;
  create)
    target="\${@: -1}"
    truncate -s 4M "\${target}"
    ;;
esac
EOF
  chmod +x "${fakebin}/qemu-img"
cat > "${fakebin}/virt-inspector" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '<operatingsystems><operatingsystem><name>linux</name><mountpoints><mountpoint dev="/dev/sda1">/</mountpoint></mountpoints></operatingsystem></operatingsystems>'
EOF
  cat > "${fakebin}/guestfish" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '/dev/sda1: /'
EOF
  cat > "${fakebin}/virt-cat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'UUID=root / ext4 defaults 0 1'
EOF
  cat > "${fakebin}/virt-ls" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'vmlinuz-test'
EOF
  chmod +x "${fakebin}/virt-inspector" "${fakebin}/guestfish" \
    "${fakebin}/virt-cat" "${fakebin}/virt-ls"
  truncate -s 4M "${SELFTEST_ROOT}/target/root.qcow2"
  cat > "${artifact_spec}" <<JSON
{"contractVersion":"3","planUuid":"${plan}","runUuid":"run-test-session","checkpointRef":"ftctl:${plan}:run-sync:2","checkpointSequence":2,"checkpointImmutableRequired":true,"disks":[{"diskIndex":0,"device":"vda","provider":"FILE","canonicalLocator":"file:${SELFTEST_ROOT}/target/root.qcow2","format":"qcow2","sizeBytes":4194304}]}
JSON
  cat > "${profile}" <<JSON
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "${plan}",
  "runUuid": "run-test-session",
  "direction": "KVM_TO_KVM",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP"},
  "target": {
    "provider": "ABLESTACK",
    "driver": "ABLESTACK",
    "zoneId": "zone-1",
    "storagePath": "${SELFTEST_ROOT}/target",
    "storageRef": "${SELFTEST_ROOT}/target",
    "serviceOfferingId": "service-offering-1",
    "networks": [{"networkId": "network-1"}]
  },
  "request": {
    "restorePointRef": "ftctl:${plan}:run-sync:2",
    "checkpointWriterState": "DRAINED",
    "checkpointImmutableRequired": true,
    "sourceSchedulerRestoreManagedByCloud": ${cloud_managed},
    "networkMode": "isolated"
  },
  "policy": {"testExecutionMode": "METADATA_ONLY"},
  "mapping": {
    "source": {
      "hardware": {"firmware": "efi", "secureBoot": false, "cpu": 2, "memoryMb": 4096},
      "workload": {"name": "rocky9-vm", "guestFamily": "linux", "guestId": "rockylinux9_64Guest"}
    },
    "disks": [
      {"device": "vda", "sourcePath": "/src/root.qcow2", "targetPath": "${SELFTEST_ROOT}/target/root.qcow2", "targetFormat": "qcow2"}
    ]
  }
}
JSON
  cat > "${checkpoint1}" <<JSON
{"state":"TARGET_READY","sourceCheckpointAt":"2026-07-01T01:00:00Z","targetDurableAt":"2026-07-01T01:00:03Z","targetReadyRpoSeconds":3}
JSON
  cat > "${checkpoint2}" <<JSON
{"state":"TARGET_READY","sourceCheckpointAt":"2026-07-01T01:05:00Z","targetDurableAt":"2026-07-01T01:05:02Z","targetReadyRpoSeconds":2}
JSON
  cat > "${manifest1}" <<JSON
{"phase":"incremental-complete","sequence":1}
JSON
  cat > "${manifest2}" <<JSON
{"phase":"incremental-complete","sequence":2}
JSON
  cat > "${restore_points}" <<JSON
{"planUuid":"${plan}","runUuid":"run-sync","checkpointSequence":1,"cycleType":"full-seed","driver":"ABLESTACK","manifest":"${manifest1}","checkpoint":"${checkpoint1}","sourceCheckpointAt":"2026-07-01T01:00:00Z","targetDurableAt":"2026-07-01T01:00:03Z","targetReadyRpoSeconds":3,"state":"TARGET_READY","recordedAt":"2026-07-01T01:00:04Z"}
{"planUuid":"${plan}","runUuid":"run-sync","checkpointSequence":2,"cycleType":"incremental","driver":"ABLESTACK","manifest":"${manifest2}","checkpoint":"${checkpoint2}","sourceCheckpointAt":"2026-07-01T01:05:00Z","targetDurableAt":"2026-07-01T01:05:02Z","targetReadyRpoSeconds":2,"state":"TARGET_READY","recordedAt":"2026-07-01T01:05:03Z"}
JSON
  cat > "${status_path}" <<EOF
plan=${plan}
run=run-sync
action=dr-sync-start
state=READY
step=scheduler-completed
progress=100
accepted=true
external_job_ref=run-sync
last_source_checkpoint_at=2026-07-01T01:05:00Z
last_target_durable_at=2026-07-01T01:05:02Z
target_ready_rpo_seconds=2
error_code=
updated_at=2026-07-01T01:05:03Z
manifest_path=${manifest2}
checkpoint_path=${checkpoint2}
checkpoint_sequence=2
restore_points_path=${restore_points}
EOF

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-test-prepare \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --run run-test-session \
    --profile-json "${profile}" \
    --artifact-spec-json "${artifact_spec}" \
    --restore-point "ftctl:${plan}:run-sync:2" \
    --json)"
  selftest_assert_contains "${out}" '"result":"accepted"' "test failover accepted"
  selftest_assert_contains "${out}" '"state":"TEST_ARTIFACTS_READY"' "test artifact prepare state"
  selftest_assert_contains "${out}" '"step":"test-artifacts-ready"' "test artifact prepare step"
  selftest_assert_contains "${out}" '"test_session_state":"READY"' "test session ready"
  selftest_assert_contains "${out}" '"test_restore_point_ref":"ftctl:plan-test-session:run-sync:2"' "test restore point ref"
  selftest_assert_contains "${out}" '"test_restore_point_sequence":2' "test restore point sequence"
  selftest_assert_contains "${out}" '"test_artifacts_state":"CREATED"' "test artifact state"
  selftest_assert_contains "${out}" '"test_artifact_count":1' "test artifact count"
  session_path="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/test-sessions/run-test-session.json"
  artifact_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/test-sessions/run-test-session-artifacts"
  local shared_artifact="${SELFTEST_ROOT}/target/ftctl-dr-test-run-test-session-vda.qcow2"
  local sealed_checkpoint="${SELFTEST_ROOT}/target/.ftctl-dr-checkpoints/${plan}/2/vda.qcow2"
  selftest_assert_file_contains "${session_path}" '"networkMode":"isolated"'
  selftest_assert_file_contains "${session_path}" '"checkpointSequence":2'
  selftest_assert_file_contains "${session_path}" '"type":"qcow2-checkpoint-overlay"'
  selftest_assert_file_contains "${session_path}" '"checkpointSealState":"SEALED"'
  selftest_assert_file_contains "${session_path}" '"checkpointIntegrityState":"PASSED"'
  selftest_assert_file_contains "${call_log}" "info --output=json ${SELFTEST_ROOT}/target/root.qcow2"
  selftest_assert_file_contains "${call_log}" "check -q ${SELFTEST_ROOT}/target/.ftctl-dr-checkpoints/${plan}/2/.vda."
  selftest_assert_file_contains "${call_log}" "compare -f qcow2 -F qcow2 ${SELFTEST_ROOT}/target/root.qcow2"
  selftest_assert_file_contains "${call_log}" "create -f qcow2 -F qcow2 -b ${sealed_checkpoint} ${shared_artifact}"
  selftest_assert_file_contains "${call_log}" "check -q ${shared_artifact}"
  selftest_assert_file_contains "${session_path}" '"ownedByFtctl":true'
  selftest_assert_file_contains "${session_path}" "\"storageRoot\":\"${SELFTEST_ROOT}/target\""
  [[ -f "${shared_artifact}" ]] || selftest_fail "independent test copy should be created in the Cloud storage root"
  [[ -f "${sealed_checkpoint}" ]] || selftest_fail "immutable per-Cycle checkpoint should be sealed"

  guestprep_manifest="${artifact_dir}/guestprep-contract.json"
  python3 "${LIB_BASE}/ftctl/guestprep_manifest.py" build-test \
    --session "${session_path}" \
    --domain "ftctl-dr-test-${plan}" \
    --output "${guestprep_manifest}"
  python3 "${LIB_BASE}/ftctl/guestprep_manifest.py" validate --manifest "${guestprep_manifest}"
  selftest_assert_eq "$(jq -r '.target.storage.type' "${guestprep_manifest}")" "file" "checkpoint overlay guestprep storage"
  selftest_assert_eq "$(jq -r '.target.format' "${guestprep_manifest}")" "qcow2" "checkpoint overlay guestprep format"
  selftest_assert_eq "$(jq -r '.disks[0].storage.locator' "${guestprep_manifest}")" "${shared_artifact}" "checkpoint overlay guestprep locator"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --json)"
  selftest_assert_contains "${out}" '"state":"TEST_ARTIFACTS_READY"' "status projects artifact-ready state"
  selftest_assert_file_contains "${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/test-sessions/active.json" '"sessionId":"plan-test-session:run-test-session"'

  bash -c 'while true; do sleep 1; done' -- --plan "${plan}" &
  scheduler_pid="$!"
  scheduler_start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${scheduler_pid}")"
  ftctl_state_write_kv_all "$(ftctl_dr_scheduler_active_pid_path "${plan}")" \
    "pid=${scheduler_pid}" \
    "start_ticks=${scheduler_start_ticks}" \
    "scheduler_session_uuid=${plan}" \
    "lease_epoch=1" \
    "worker_run_uuid=run-sync" \
    "heartbeat_at=$(ftctl_now_iso8601)"

  (
    local control_path="" generation="" command="" last_generation=""
    control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
    last_generation="$(ftctl_dr_scheduler_control_generation "${plan}")"
    while true; do
      generation="$(ftctl_state_read_kv "${control_path}" generation 2>/dev/null || true)"
      command="$(ftctl_state_read_kv "${control_path}" command 2>/dev/null || true)"
      if [[ -n "${generation}" && "${generation}" != "${last_generation}" ]]; then
        if [[ "${command}" == "pause" ]]; then
          ftctl_dr_scheduler_control_ack "${plan}" "${generation}" "PAUSED" "IDLE" "run-sync" \
            "${plan}" "1" "${scheduler_pid}" "${scheduler_start_ticks}"
        elif [[ "${command}" == "run" ]]; then
          ftctl_dr_scheduler_control_ack "${plan}" "${generation}" "RUNNING" "IDLE" "run-sync" \
            "${plan}" "1" "${scheduler_pid}" "${scheduler_start_ticks}"
          break
        fi
        last_generation="${generation}"
      fi
      sleep 0.1
    done
  ) >/dev/null 2>&1 &
  ack_pid="$!"
  printf '%s\n' "${scheduler_pid}" > "$(ftctl_dr_scheduler_pid_path "${plan}" run-test-cleanup)"

  local before_cleanup_generation
  before_cleanup_generation="$(ftctl_dr_scheduler_control_generation "${plan}")"
  cleanup="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-test-artifact-cleanup \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --run run-test-cleanup \
    --profile-json "${profile}" \
    --json)"
  if [[ "${cloud_managed}" == "true" ]]; then
    kill "${ack_pid}" 2>/dev/null || true
    wait "${ack_pid}" 2>/dev/null || true
    selftest_assert_eq "$(ftctl_dr_scheduler_control_command "${plan}")" "pause" "Cloud cleanup must leave source paused"
    selftest_assert_eq "$(ftctl_dr_scheduler_control_generation "${plan}")" "$((before_cleanup_generation + 1))" "Cloud cleanup must only request quiesce, never source RUN"
  else
    wait "${ack_pid}"
  fi
  kill "${scheduler_pid}" 2>/dev/null || true
  wait "${scheduler_pid}" 2>/dev/null || true
  selftest_assert_contains "${cleanup}" '"state":"READY"' "test cleanup state"
  selftest_assert_contains "${cleanup}" '"step":"test-cleanup-completed"' "test cleanup step"
  selftest_assert_contains "${cleanup}" '"test_session_state":"CLEANED"' "test cleanup session state"
  selftest_assert_contains "${cleanup}" '"test_artifacts_state":"CLEANED"' "test artifact cleanup state"
  [[ ! -e "${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/test-sessions/active.json" ]] || selftest_fail "active test session should be removed"
  [[ ! -d "${artifact_dir}" ]] || selftest_fail "test artifact directory should be removed"
  [[ ! -e "${shared_artifact}" ]] || selftest_fail "Cloud-visible test artifact should be removed"
}

selftest_case_dr_runtime_cloud_managed_test_cleanup() {
  selftest_case_dr_runtime_test_failover_cleanup true
}

selftest_case_dr_runtime_shared_file_artifact_cleanup() {
  selftest_reset_env
  selftest_info "FTCTL_DR cleanup removes only its owned SharedMountPoint test copy"

  local plan="plan-shared-artifact-cleanup"
  local run="run-shared-artifact-cleanup"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local session_dir="${plan_dir}/test-sessions/${run}-artifacts"
  local active_path="${plan_dir}/test-sessions/active.json"
  local session_path="${plan_dir}/test-sessions/${run}.json"
  local run_path="${plan_dir}/runs/${run}.state"
  local status_path="${plan_dir}/status.state"
  local storage_root="${SELFTEST_ROOT}/shared-pool"
  local artifact="${storage_root}/ftctl-dr-test-${run}-vda.qcow2"
  local durable="${storage_root}/durable-replica.qcow2"

  mkdir -p "${session_dir}" "${plan_dir}/runs" "${storage_root}"
  truncate -s 1M "${artifact}"
  truncate -s 1M "${durable}"
  cat > "${active_path}" <<JSON
{"sessionId":"${plan}:${run}","runUuid":"${run}","testArtifacts":{"state":"CREATED","path":"${session_dir}","count":1,"records":[{"type":"qcow2-checkpoint-overlay","state":"CREATED","path":"${artifact}","storageRoot":"${storage_root}","ownedByFtctl":true}]}}
JSON
  printf 'plan=%s\nrun=%s\n' "${plan}" "${run}" > "${run_path}"
  cp -f "${run_path}" "${status_path}"

  ftctl_dr_runtime_cleanup_test_session "${plan}" "${run}" "${run_path}" "${status_path}"

  [[ ! -e "${artifact}" ]] || selftest_fail "owned SharedMountPoint test copy should be removed"
  [[ -e "${durable}" ]] || selftest_fail "durable replica must not be removed"
  [[ ! -d "${session_dir}" ]] || selftest_fail "runtime artifact directory should be removed"
  [[ ! -e "${active_path}" ]] || selftest_fail "active test session should be removed"
  selftest_assert_file_contains "${session_path}" '"state":"CLEANED"'
  selftest_assert_file_contains "${session_path}" '"ownedByFtctl":true'
}

selftest_case_dr_scheduler_resume_recovers_missing_worker() {
  selftest_reset_env
  selftest_info "FTCTL_DR cleanup resume recovers a missing scheduler worker"

  local plan="plan-resume-recovery"
  local run="run-resume-recovery"
  local producer_run="run-sync-producer"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local run_path="${plan_dir}/runs/${run}.state"
  local producer_run_path="${plan_dir}/runs/${producer_run}.state"
  local status_path="${plan_dir}/status.state"
  local call_log="${SELFTEST_ROOT}/scheduler-resume-recovery.log"

  mkdir -p "${plan_dir}/runs"
  printf '{"planUuid":"%s","source":{"provider":"ABLESTACK"},"target":{"provider":"ABLESTACK"}}\n' "${plan}" > "${plan_dir}/profile.json"
  printf 'plan=%s\nrun=%s\n' "${plan}" "${run}" > "${run_path}"
  printf 'plan=%s\nrun=%s\n' "${plan}" "${producer_run}" > "${producer_run_path}"
  printf '{"planUuid":"%s","runUuid":"%s","checkpointSequence":4,"state":"TARGET_READY"}\n' "${plan}" "${producer_run}" > "${plan_dir}/restore-points.jsonl"
  cp -f "${run_path}" "${status_path}"

  (
    ftctl_dr_scheduler_session_uuid() {
      printf 'session-resume-recovery\n'
    }
    ftctl_dr_scheduler_control_set() {
      printf 'set:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >> "${call_log}"
      printf '7\n'
    }
    ftctl_dr_scheduler_ensure_running() {
      printf 'ensure:%s:%s:%s\n' "$1" "$2" "$3" >> "${call_log}"
      return 0
    }
    ftctl_dr_scheduler_wait_for_ack() {
      printf 'wait:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$5" "$6" >> "${call_log}"
      return 0
    }
    ftctl_dr_scheduler_update_state() {
      printf 'update:%s:%s\n' "$1" "$2" >> "${call_log}"
      return 0
    }
    ftctl_dr_scheduler_resume_after_transition "${plan}" "${run}" "test-cleanup" "${run_path}" "${status_path}"
  )

  selftest_assert_file_contains "${call_log}" "set:${plan}:run:test-cleanup:${run}"
  selftest_assert_file_contains "${call_log}" "ensure:${plan}:${producer_run}:${plan_dir}/profile.json"
  selftest_assert_file_contains "${call_log}" "wait:${plan}:7:RUNNING:${run}:session-resume-recovery"
  selftest_assert_eq "$(sed -n '1p' "${call_log}" | cut -d: -f1)" "set" "RUN generation must be durable before scheduler recovery"
  selftest_assert_eq "$(sed -n '2p' "${call_log}" | cut -d: -f1)" "ensure" "scheduler recovery follows the durable RUN generation"
  selftest_assert_eq "$(sed -n '3p' "${call_log}" | cut -d: -f1)" "wait" "resume waits for the same durable RUN generation"
}

selftest_case_dr_runtime_planned_failover_promotes_latest_checkpoint() {
  selftest_reset_env
  selftest_info "FTCTL_DR planned failover locks a final checkpoint and delegates target power-on"

  local plan="plan-failover"
  local profile="${SELFTEST_ROOT}/dr-failover-profile.json"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local restore_points="${plan_dir}/restore-points.jsonl"
  local checkpoint1="${plan_dir}/checkpoints/cycle-1-checkpoint.json"
  local checkpoint2="${plan_dir}/checkpoints/cycle-2-checkpoint.json"
  local manifest1="${plan_dir}/manifests/cycle-1-manifest.json"
  local manifest2="${plan_dir}/manifests/cycle-2-manifest.json"
  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/qemu-img-failover.log"
  local status_path="${plan_dir}/status.state"
  local out="" session_path="" active_path=""

  mkdir -p "${plan_dir}/checkpoints" "${plan_dir}/manifests" "${fakebin}" \
    "${SELFTEST_ROOT}/source" "${SELFTEST_ROOT}/target"
  : > "${SELFTEST_ROOT}/source/root.qcow2"
  cat > "${fakebin}/qemu-img" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
case "\${1:-}" in
  info)
    printf '{"format":"qcow2","virtual-size":1048576}\n'
    ;;
  create)
    target="\${@: -2:1}"
    : > "\${target}"
    ;;
  convert)
    target="\${@: -1}"
    : > "\${target}"
    ;;
esac
EOF
  chmod +x "${fakebin}/qemu-img"
  cat > "${fakebin}/virsh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"query-named-block-nodes"* ]]; then
  printf '{"return":[{"node-name":"libvirt-2-format","drv":"qcow2","active":true,"image":{"filename":"${SELFTEST_ROOT}/source/root.qcow2","virtual-size":1048576}}]}\n'
  exit 0
fi
exit 1
EOF
  chmod +x "${fakebin}/virsh"
  cat > "${profile}" <<JSON
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "${plan}",
  "runUuid": "run-failover",
  "direction": "KVM_TO_KVM",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP", "instanceName": "i-test-failover-VM"},
  "target": {
    "provider": "ABLESTACK",
    "driver": "ABLESTACK",
    "zoneId": "zone-1",
    "storageRef": "${SELFTEST_ROOT}/target",
    "serviceOfferingId": "service-offering-1",
    "networks": [{"networkId": "network-1"}]
  },
  "request": {
    "mode": "planned",
    "finalSync": true
  },
  "mapping": {
    "disks": [
      {"device": "vda", "sourcePath": "${SELFTEST_ROOT}/source/root.qcow2", "targetPath": "${SELFTEST_ROOT}/target/root.qcow2", "sourceFormat": "qcow2", "targetFormat": "qcow2", "sizeBytes": 1048576, "targetDiskOfferingId": "disk-offering-1"}
    ]
  }
}
JSON
  cat > "${checkpoint1}" <<JSON
{"state":"TARGET_READY","sourceCheckpointAt":"2026-07-01T01:00:00Z","targetDurableAt":"2026-07-01T01:00:03Z","targetReadyRpoSeconds":3}
JSON
  cat > "${checkpoint2}" <<JSON
{"state":"TARGET_READY","sourceCheckpointAt":"2026-07-01T01:05:00Z","targetDurableAt":"2026-07-01T01:05:02Z","targetReadyRpoSeconds":2}
JSON
  cat > "${manifest1}" <<JSON
{"phase":"incremental-complete","sequence":1}
JSON
  cat > "${manifest2}" <<JSON
{"phase":"incremental-complete","sequence":2}
JSON
  cat > "${restore_points}" <<JSON
{"planUuid":"${plan}","runUuid":"run-sync","checkpointSequence":1,"cycleType":"full-seed","driver":"ABLESTACK","manifest":"${manifest1}","checkpoint":"${checkpoint1}","sourceCheckpointAt":"2026-07-01T01:00:00Z","targetDurableAt":"2026-07-01T01:00:03Z","targetReadyRpoSeconds":3,"state":"TARGET_READY","recordedAt":"2026-07-01T01:00:04Z"}
{"planUuid":"${plan}","runUuid":"run-sync","checkpointSequence":2,"cycleType":"incremental","driver":"ABLESTACK","manifest":"${manifest2}","checkpoint":"${checkpoint2}","sourceCheckpointAt":"2026-07-01T01:05:00Z","targetDurableAt":"2026-07-01T01:05:02Z","targetReadyRpoSeconds":2,"state":"TARGET_READY","recordedAt":"2026-07-01T01:05:03Z"}
JSON
  cat > "${status_path}" <<EOF
plan=${plan}
run=run-sync
action=dr-sync-start
state=READY
step=scheduler-completed
progress=100
accepted=true
external_job_ref=run-sync
last_source_checkpoint_at=2026-07-01T01:05:00Z
last_target_durable_at=2026-07-01T01:05:02Z
target_ready_rpo_seconds=2
error_code=
updated_at=2026-07-01T01:05:03Z
manifest_path=${manifest2}
checkpoint_path=${checkpoint2}
checkpoint_sequence=2
restore_points_path=${restore_points}
EOF

  out="$(FTCTL_DR_FAILOVER_FOREGROUND=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-failover \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --run run-failover \
    --profile-json "${profile}" \
    --mode planned \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"result":"accepted"' "planned failover accepted"
  selftest_assert_contains "${out}" '"state":"FAILED_OVER"' "planned failover final state"
  selftest_assert_contains "${out}" '"step":"active-side-switch"' "planned failover final step"
  selftest_assert_contains "${out}" '"failover_mode":"planned"' "planned failover mode"
  selftest_assert_contains "${out}" '"failover_restore_point_ref":"ftctl:plan-failover:run-failover:3"' "planned failover restore point ref"
  selftest_assert_contains "${out}" '"failover_restore_point_sequence":3' "planned failover restore point sequence"
  selftest_assert_contains "${out}" '"active_side":"TARGET"' "planned failover active side"
  selftest_assert_contains "${out}" '"target_power_state":"POWER_ON_DELEGATED"' "planned failover target power delegated"
  selftest_assert_contains "${out}" '"target_promotion_state":"PROMOTED"' "planned failover target promoted"
  selftest_assert_contains "${out}" '"rto_actual_seconds":' "planned failover RTO field"
  selftest_assert_file_contains "${restore_points}" '"cycleType":"failover-final"'
  selftest_assert_file_contains "${call_log}" "convert --force-share -p -n -S"

  session_path="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/failovers/run-failover.json"
  active_path="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/failovers/active.json"
  selftest_assert_file_contains "${session_path}" '"state":"FAILED_OVER"'
  selftest_assert_file_contains "${session_path}" '"lifecycleOwner":"Cloud"'
  selftest_assert_file_contains "${active_path}" '"sessionId":"plan-failover:run-failover"'

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --json)"
  selftest_assert_contains "${out}" '"state":"FAILED_OVER"' "status projects failover state"
  selftest_assert_contains "${out}" '"active_side":"TARGET"' "status projects active target"
  selftest_assert_contains "${out}" '"target_power_state":"POWER_ON_DELEGATED"' "status projects delegated power state"
}

selftest_case_dr_runtime_cloud_cutover_commit_is_idempotent() {
  selftest_reset_env
  selftest_info "FTCTL_DR commits Cloud-owned target promotion with monotonic authority"

  local plan="plan-cloud-cutover" run="run-cloud-cutover"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local run_path="${plan_dir}/runs/${run}.state"
  local status_path="${plan_dir}/status.state"
  local session_path="${plan_dir}/failovers/${run}.json"
  local out="" rc=0

  mkdir -p "${plan_dir}/runs" "${plan_dir}/failovers"
  cat > "${run_path}" <<EOF
plan=${plan}
run=${run}
action=dr-failover
state=CUTOVER_READY
step=cutover-ready
progress=100
failover_session_id=${plan}:${run}
failover_restore_point_sequence=42
active_side=SOURCE
target_power_state=POWERED_OFF
target_promotion_state=CUTOVER_READY
updated_at=2026-07-22T00:00:00Z
EOF
  cp -f "${run_path}" "${status_path}"
  cat > "${session_path}" <<JSON
{"planUuid":"${plan}","runUuid":"${run}","sessionId":"${plan}:${run}","state":"CUTOVER_READY","activeSide":"SOURCE","targetPromotion":{"state":"CUTOVER_READY","powerState":"POWERED_OFF","lifecycleOwner":"Cloud"}}
JSON
  cp -f "${session_path}" "${plan_dir}/failovers/active.json"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-cutover-commit \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${run}" \
    --session-id "${plan}:${run}" --checkpoint-sequence 42 --authority-generation 7 \
    --target-power-state POWERED_ON --boot-validation-state POWER_STATE_VALIDATED --json)"
  selftest_assert_contains "${out}" '"state":"FAILED_OVER"' "Cloud cutover commit state"
  selftest_assert_contains "${out}" '"active_side":"TARGET"' "Cloud cutover commit active side"
  selftest_assert_contains "${out}" '"engine_ack_state":"ACKNOWLEDGED"' "Cloud cutover commit acknowledgement"
  selftest_assert_file_contains "${session_path}" '"cloudAuthorityGeneration":7'
  selftest_assert_file_contains "${session_path}" '"activeSide":"TARGET"'

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-cutover-commit \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${run}" \
    --session-id "${plan}:${run}" --checkpoint-sequence 42 --authority-generation 7 \
    --target-power-state POWERED_ON --boot-validation-state POWER_STATE_VALIDATED --json)"
  selftest_assert_contains "${out}" '"state":"FAILED_OVER"' "repeated Cloud cutover commit is idempotent"

  set +e
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-cutover-commit \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${run}" \
    --session-id "${plan}:${run}" --checkpoint-sequence 42 --authority-generation 6 \
    --target-power-state POWERED_ON --boot-validation-state POWER_STATE_VALIDATED --json 2>&1)"
  rc=$?
  set -e
  selftest_assert_eq "${rc}" "79" "stale Cloud authority generation must fail"
  selftest_assert_contains "${out}" 'DR_CUTOVER_GENERATION_STALE' "stale generation error code"
}

selftest_case_dr_runtime_cloud_cutover_commit_v2_is_durable() {
  selftest_reset_env
  selftest_info "FTCTL_DR validates and durably acknowledges the Cloud cutover commit envelope"

  local plan="plan-cloud-cutover-v2" run="run-cloud-cutover-v2"
  local engine_session="${plan}:${run}" cloud_session="cloud-cutover-session-v2"
  local attempt="cutover-attempt-v2" manifest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local target_vm_id="266" target_external_ref="ce028129-98a7-4dba-b05c-7c74ca5df398"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local run_path="${plan_dir}/runs/${run}.state" status_path="${plan_dir}/status.state"
  local session_path="${plan_dir}/failovers/${run}.json" journal_path="${plan_dir}/cutover-commits/${run}.commit.state"
  local envelope_sha out rc=0

  mkdir -p "${plan_dir}/runs" "${plan_dir}/failovers"
  cat > "${run_path}" <<EOF
plan=${plan}
run=${run}
action=dr-failover
state=CUTOVER_READY
step=cutover-ready
progress=100
failover_session_id=${engine_session}
failover_restore_point_sequence=43
manifest_sha256=${manifest}
target_vm_id=${target_vm_id}
target_external_ref=${target_external_ref}
source_fence_state=REQUESTED
source_power_state=UNKNOWN
active_side=SOURCE
target_power_state=POWERED_OFF
target_promotion_state=CUTOVER_READY
updated_at=2026-08-06T00:00:00Z
EOF
  cp -f "${run_path}" "${status_path}"
  cat > "${session_path}" <<JSON
{"planUuid":"${plan}","runUuid":"${run}","sessionId":"${engine_session}","state":"CUTOVER_READY","activeSide":"SOURCE"}
JSON
  cp -f "${session_path}" "${plan_dir}/failovers/active.json"

  envelope_sha="$(python3 - "${plan}" "${run}" "${engine_session}" "${cloud_session}" "${attempt}" \
      "${manifest}" "${target_vm_id}" "${target_external_ref}" <<'PY'
import hashlib
import json
import sys
plan, run, engine_session, cloud_session, attempt, manifest, target_vm_id, target_external_ref = sys.argv[1:]
payload = {
    "authorityGeneration": 43,
    "bootValidationState": "POWER_STATE_VALIDATED",
    "checkpointSequence": 43,
    "cloudCutoverSessionUuid": cloud_session,
    "commitAttemptId": attempt,
    "contractVersion": "DR_CUTOVER_COMMIT_V2",
    "engineSessionId": engine_session,
    "manifestSha256": manifest,
    "planUuid": plan,
    "runUuid": run,
    "sourceFenceState": "VERIFIED",
    "sourcePowerState": "POWERED_OFF",
    "targetExternalRef": target_external_ref,
    "targetPowerState": "POWERED_ON",
    "targetVmId": int(target_vm_id),
}
print(hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
PY
  )"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-cutover-commit \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${run}" \
    --commit-contract-version DR_CUTOVER_COMMIT_V2 \
    --engine-session-id "${engine_session}" --cloud-session-id "${cloud_session}" \
    --checkpoint-sequence 43 --manifest-sha256 "${manifest}" --authority-generation 43 \
    --commit-attempt-id "${attempt}" --commit-envelope-sha256 "${envelope_sha}" \
    --target-vm-id "${target_vm_id}" --target-external-ref "${target_external_ref}" \
    --target-power-state POWERED_ON --boot-validation-state POWER_STATE_VALIDATED \
    --source-fence-state VERIFIED --source-power-state POWERED_OFF --json)"
  selftest_assert_contains "${out}" '"state":"FAILED_OVER"' "V2 cutover commit state"
  selftest_assert_file_contains "${journal_path}" 'phase=ACKNOWLEDGED'
  selftest_assert_file_contains "${journal_path}" "commit_envelope_sha256=${envelope_sha}"
  selftest_assert_file_contains "${run_path}" 'source_fence_state=VERIFIED'
  selftest_assert_file_contains "${run_path}" 'source_power_state=POWERED_OFF'

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-cutover-commit-status \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${run}" \
    --commit-contract-version DR_CUTOVER_COMMIT_V2 --engine-session-id "${engine_session}" \
    --commit-attempt-id "${attempt}" --commit-envelope-sha256 "${envelope_sha}" --json)"
  selftest_assert_contains "${out}" '"commit_outcome":"ACKNOWLEDGED"' "V2 durable cutover ACK"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-cutover-commit \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${run}" \
    --commit-contract-version DR_CUTOVER_COMMIT_V2 \
    --engine-session-id "${engine_session}" --cloud-session-id "${cloud_session}" \
    --checkpoint-sequence 43 --manifest-sha256 "${manifest}" --authority-generation 43 \
    --commit-attempt-id "${attempt}" --commit-envelope-sha256 "${envelope_sha}" \
    --target-vm-id "${target_vm_id}" --target-external-ref "${target_external_ref}" \
    --target-power-state POWERED_ON --boot-validation-state POWER_STATE_VALIDATED \
    --source-fence-state VERIFIED --source-power-state POWERED_OFF --json)"
  selftest_assert_contains "${out}" '"state":"FAILED_OVER"' "V2 cutover replay is idempotent"

  set +e
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-cutover-commit-status \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run "${run}" \
    --commit-contract-version DR_CUTOVER_COMMIT_V2 --engine-session-id "${engine_session}" \
    --commit-attempt-id different-attempt --commit-envelope-sha256 "${envelope_sha}" --json 2>&1)"
  rc=$?
  set -e
  selftest_assert_eq "${rc}" "79" "conflicting cutover status identity must fail"
  selftest_assert_contains "${out}" 'DR_CUTOVER_COMMIT_IDENTITY_MISMATCH' "cutover status identity error"
}

selftest_case_dr_runtime_status_hydrates_complete_cycle_evidence() {
  selftest_reset_env
  selftest_info "FTCTL_DR status hydrates exact completed-cycle NBD evidence from restore points"

  local plan="plan-cycle-evidence" run="run-cycle-evidence"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local restore_points="${plan_dir}/restore-points.jsonl"
  local status_path="${plan_dir}/status.state"
  local out=""
  mkdir -p "${plan_dir}"
  cat > "${restore_points}" <<JSON
{"planUuid":"other-plan","producerRunUuid":"wrong-run","checkpointSequence":99,"cycleType":"incremental","state":"READY","cycleToken":"other-plan:99","baselineGeneration":99,"effectiveMode":"CBT_INCREMENTAL","incrementalVerified":true,"nbdTeardownState":"DRAINED"}
{"planUuid":"${plan}","producerRunUuid":"${run}","checkpointSequence":7,"checkpointRef":"ftctl:${plan}:${run}:7","cycleType":"incremental","state":"READY","sourceCheckpointAt":"2026-07-27T00:00:00Z","targetDurableAt":"2026-07-27T00:00:02Z","targetReadyRpoSeconds":2,"requestedMode":"CBT_INCREMENTAL","effectiveMode":"CBT_INCREMENTAL","incrementalVerified":true,"metricsEstimated":false,"virtualBytes":1073741824,"changedBytes":9306112,"sourceReadBytes":9306112,"targetWrittenBytes":9306112,"transferPayloadBytes":9306112,"changedExtentCount":94,"durationMs":2500,"throughputBps":3722444,"baselineGeneration":7,"cycleToken":"${plan}:7","nbdTeardownState":"DRAINED","nbdTeardownStartedAtEpochMs":1000,"nbdTeardownCompletedAtEpochMs":1100,"nbdTeardownDurationMs":100,"nbdSourceDeviceCount":1,"nbdTargetDeviceCount":1,"nbdQuarantinedDeviceCount":0,"nbdTeardownErrorCode":"","nbdTeardownErrorMessage":""}
JSON
  cat > "${status_path}" <<EOF
plan=${plan}
run=${run}
action=dr-failover
state=CUTOVER_READY
step=cutover-ready
progress=100
active_side=SOURCE
target_power_state=POWERED_OFF
restore_points_path=${restore_points}
EOF

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --json)"
  selftest_assert_contains "${out}" '"latest_completed_checkpoint_sequence":7' "exact plan checkpoint sequence"
  selftest_assert_contains "${out}" '"latest_completed_producer_run_uuid":"run-cycle-evidence"' "producer identity"
  selftest_assert_contains "${out}" '"latest_completed_cycle_token":"plan-cycle-evidence:7"' "cycle token"
  selftest_assert_contains "${out}" '"latest_completed_nbd_teardown_state":"DRAINED"' "NBD drain state"
  selftest_assert_contains "${out}" '"latest_completed_nbd_source_device_count":1' "NBD source count"
  selftest_assert_contains "${out}" '"latest_completed_nbd_quarantined_device_count":0' "NBD quarantine count"
}

selftest_case_dr_runtime_failover_abort_resumes_source_protection() (
  selftest_reset_env
  selftest_info "FTCTL_DR failover abort resumes source protection before Cloud promotion"

  local plan="plan-failover-abort" run="run-failover-abort"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local run_path="${plan_dir}/runs/${run}.state"
  local status_path="${plan_dir}/status.state"
  local session_path="${plan_dir}/failovers/${run}.json"
  local active_path="${plan_dir}/failovers/active.json"
  local out=""
  mkdir -p "${plan_dir}/runs" "${plan_dir}/failovers"
  cat > "${plan_dir}/profile.json" <<JSON
{"version":1,"engine":"FTCTL_DR","planUuid":"${plan}","direction":"VMWARE_TO_KVM"}
JSON
  cat > "${run_path}" <<EOF
plan=${plan}
run=${run}
action=dr-failover
state=CUTOVER_READY
step=cutover-ready
progress=100
failover_session_id=${plan}:${run}
failover_restore_point_sequence=7
active_side=SOURCE
target_power_state=POWERED_OFF
target_promotion_state=CUTOVER_READY
EOF
  cp -f "${run_path}" "${status_path}"
  cat > "${session_path}" <<JSON
{"version":1,"planUuid":"${plan}","runUuid":"${run}","sessionId":"${plan}:${run}","state":"CUTOVER_READY","activeSide":"SOURCE","targetPromotion":{"state":"CUTOVER_READY","powerState":"POWERED_OFF"}}
JSON
  cp -f "${session_path}" "${active_path}"
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_resume_after_transition() {
    ftctl_dr_runtime_path_set "$4" "scheduler_state=RUNNING" "scheduler_desired_state=RUNNING"
    cp -f "$4" "$5"
  }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_checkpoint_lease_release() { return 0; }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_transition_end() { return 0; }

  out="$(ftctl_dr_runtime_failover_abort "${plan}" "${run}" "${plan}:${run}" 1)"
  selftest_assert_contains "${out}" '"state":"ABORTED"' "abort terminal state"
  selftest_assert_contains "${out}" '"active_side":"SOURCE"' "source authority retained"
  selftest_assert_contains "${out}" '"scheduler_recovery_state":"RESUMED_AFTER_FAILOVER_ABORT"' "scheduler resumed"
  selftest_assert_file_contains "${status_path}" "target_power_state=POWERED_OFF"
  selftest_assert_file_contains "${session_path}" '"state":"ABORTED"'
  selftest_assert_file_contains "${session_path}" '"powerState":"POWERED_OFF"'
  [[ ! -e "${active_path}" ]] || selftest_fail "active failover session should be removed"

  out="$(ftctl_dr_runtime_failover_abort "${plan}" "${run}" "${plan}:${run}" 1)"
  selftest_assert_contains "${out}" '"state":"ABORTED"' "idempotent abort terminal state"
  [[ ! -e "${active_path}" ]] || selftest_fail "idempotent abort should keep the active pointer absent"
)

selftest_case_dr_scheduler_resume_accepts_live_worker_pending_ack() (
  selftest_reset_env
  selftest_info "FTCTL_DR resume accepts a live source worker while a cycle delays the RUN acknowledgement"

  local plan="plan-resume-pending-ack" run="run-resume-pending-ack"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local run_path="${plan_dir}/runs/${run}.state"
  local status_path="${plan_dir}/status.state"
  mkdir -p "${plan_dir}/runs"
  printf '%s\n' '{"version":1,"planUuid":"plan-resume-pending-ack"}' > "${plan_dir}/profile.json"
  printf '%s\n' "plan=${plan}" "run=${run}" > "${run_path}"
  cp -f "${run_path}" "${status_path}"

  # shellcheck disable=SC2317
  ftctl_dr_scheduler_has_live_worker() { return 0; }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_session_uuid() { printf '%s\n' "${plan}"; }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_control_set() { printf '%s\n' "12"; }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_ensure_running() { return 0; }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_wait_for_ack() { return 21; }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_control_generation() { printf '%s\n' "12"; }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_control_command() { printf '%s\n' "run"; }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_active_worker_valid() { return 0; }
  # shellcheck disable=SC2317
  ftctl_dr_scheduler_control_ack_path() { printf '%s\n' "${plan_dir}/scheduler/control.ack"; }

  ftctl_dr_scheduler_resume_after_transition \
    "${plan}" "${run}" "failover-abort" "${run_path}" "${status_path}"
  selftest_assert_file_contains "${run_path}" "control_generation=12"
  selftest_assert_file_contains "${run_path}" "control_ack_generation=0"
  selftest_assert_file_contains "${run_path}" "control_state=RUNNING_PENDING_ACK"
  selftest_assert_file_contains "${run_path}" "transition_state=COMPLETED"
)

selftest_case_dr_runtime_failback_restores_source_after_reverse_checkpoint() {
  selftest_reset_env
  selftest_info "FTCTL_DR failback waits for Cloud lifecycle commit before restoring source authority"

  local plan="plan-failback"
  local profile="${SELFTEST_ROOT}/dr-failback-profile.json"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local status_path="${plan_dir}/status.state"
  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/qemu-img-failback.log"
  local out="" session_path="" active_path="" reverse_profile="" reverse_points="" run_path="" rc=0

  mkdir -p "${plan_dir}" "${fakebin}" "${SELFTEST_ROOT}/source" "${SELFTEST_ROOT}/target"
  cat > "${fakebin}/qemu-img" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
case "\${1:-}" in
  info)
    printf '{"format":"qcow2","virtual-size":1048576}\n'
    ;;
  create)
    target="\${@: -2:1}"
    : > "\${target}"
    ;;
  convert)
    target="\${@: -1}"
    : > "\${target}"
    ;;
esac
EOF
  chmod +x "${fakebin}/qemu-img"
  : > "${SELFTEST_ROOT}/target/root.qcow2"
  cat > "${profile}" <<JSON
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "${plan}",
  "runUuid": "run-original",
  "direction": "KVM_TO_KVM",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP"},
  "target": {
    "provider": "ABLESTACK",
    "driver": "ABLESTACK",
    "zoneId": "zone-1",
    "storageRef": "${SELFTEST_ROOT}/target",
    "serviceOfferingId": "service-offering-1",
    "networks": [{"networkId": "network-1"}]
  },
  "mapping": {
    "disks": [
      {"device": "vda", "sourcePath": "${SELFTEST_ROOT}/source/root.qcow2", "targetPath": "${SELFTEST_ROOT}/target/root.qcow2", "sourceFormat": "qcow2", "targetFormat": "qcow2", "sizeBytes": 1048576, "targetDiskOfferingId": "disk-offering-1"}
    ]
  },
  "guestCompatibility": {"state": "READY"}
}
JSON
  cat > "${status_path}" <<EOF
plan=${plan}
run=run-failover
action=dr-failover
state=FAILED_OVER
step=active-side-switch
progress=100
accepted=true
active_side=TARGET
target_power_state=POWER_ON_DELEGATED
target_promotion_state=PROMOTED
checkpoint_sequence=3
latest_completed_checkpoint_sequence=3
latest_completed_checkpoint_ref=ftctl:${plan}:run-before-failback:3
latest_completed_checkpoint_state=READY
latest_completed_baseline_generation=3
last_source_checkpoint_at=2026-07-01T01:10:00Z
last_target_durable_at=2026-07-01T01:10:03Z
target_ready_rpo_seconds=3
error_code=
updated_at=2026-07-01T01:10:04Z
EOF

  out="$(FTCTL_DR_FAILBACK_FOREGROUND=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-failback \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --run run-failback \
    --profile-json "${profile}" \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"result":"accepted"' "failback accepted"
  selftest_assert_contains "${out}" '"state":"FAILBACK_DATA_READY"' "failback returns data ready"
  selftest_assert_contains "${out}" '"step":"cloud-lifecycle-pending"' "failback waits for Cloud lifecycle"
  selftest_assert_contains "${out}" '"active_side":"TARGET"' "target authority retained before Cloud commit"
  selftest_assert_contains "${out}" '"source_power_state":"POWERED_OFF"' "source remains powered off before Cloud commit"
  selftest_assert_contains "${out}" '"source_promotion_state":"STANDBY"' "source remains standby before Cloud commit"
  selftest_assert_contains "${out}" '"engine_ack_state":"PENDING"' "engine commit is pending"
  selftest_assert_contains "${out}" '"failback_restore_point_sequence":4' "failback reverse checkpoint sequence"
  selftest_assert_contains "${out}" '"reverse_direction":"ABLESTACK_TO_ABLESTACK"' "failback legacy provider direction"
  selftest_assert_contains "${out}" '"route_contract_version":2' "failback route contract version"
  selftest_assert_contains "${out}" '"replication_direction":"KVM_TO_KVM"' "failback topology direction"
  selftest_assert_contains "${out}" '"provider_pair":"ABLESTACK_TO_ABLESTACK"' "failback provider pair"
  selftest_assert_contains "${out}" '"failback_rto_actual_seconds":' "failback RTO field"

  reverse_profile="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/reverse-profiles/run-failback-failback.json"
  reverse_points="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/reverse-restore-points.jsonl"
  session_path="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/failbacks/run-failback.json"
  active_path="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/failbacks/active.json"
  selftest_assert_file_contains "${reverse_profile}" "\"sourcePath\":\"${SELFTEST_ROOT}/target/root.qcow2\""
  selftest_assert_file_contains "${reverse_profile}" "\"targetPath\":\"${SELFTEST_ROOT}/source/root.qcow2\""
  selftest_assert_file_contains "${reverse_points}" '"cycleType":"failback-final"'
  selftest_assert_file_contains "${session_path}" '"operation":"failback"'
  selftest_assert_file_contains "${active_path}" '"activeSide":"TARGET"'
  selftest_assert_file_contains "${call_log}" "convert --force-share -p -n -S"

  run_path="$(ftctl_dr_runtime_run_path "${plan}" "run-failback")"
  ftctl_dr_runtime_path_set "${run_path}" \
    "baseline_generation=4" \
    "baseline_state=LOCAL_DURABLE" \
    "tracker_state=LOCAL_DURABLE" \
    "writer_state=DURABLE" \
    "target_written=true" \
    "write_verified=true" \
    "reverse_guest_compatibility_state=READY"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --json)"
  selftest_assert_contains "${out}" '"state":"FAILBACK_DATA_READY"' "failback status data ready"
  selftest_assert_contains "${out}" '"active_side":"TARGET"' "failback status target active"
  selftest_assert_contains "${out}" '"failback_phase":"DATA_READY"' "failback status phase"
  selftest_assert_contains "${out}" '"cloud_lifecycle_state":"PENDING"' "Cloud lifecycle is pending"
  selftest_assert_contains "${out}" '"reverse_evidence_contract_version":1' "reverse evidence contract version"
  selftest_assert_contains "${out}" '"reverse_evidence_state":"COMPLETE"' "reverse evidence is complete"
  selftest_assert_contains "${out}" '"reverse_evidence_run_uuid":"run-failback"' "reverse evidence is bound to the Run"
  selftest_assert_contains "${out}" '"baseline_generation":4' "reverse baseline generation is typed"
  selftest_assert_contains "${out}" '"baseline_state":"LOCAL_DURABLE"' "reverse baseline is durable"
  selftest_assert_contains "${out}" '"tracker_state":"LOCAL_DURABLE"' "reverse tracker is durable"
  selftest_assert_contains "${out}" '"writer_state":"DURABLE"' "reverse writer is durable"
  selftest_assert_contains "${out}" '"target_written":true' "reverse target write is projected"
  selftest_assert_contains "${out}" '"write_verified":true' "reverse target write verification is projected"
  selftest_assert_contains "${out}" '"reverse_guest_compatibility_state":"READY"' "reverse guest compatibility is projected"
  selftest_assert_contains "${out}" '"reverse_evidence_missing_fields":[]' "complete evidence has no missing field"

  set +e
  local failback_contract="DR_FAILBACK_COMMIT_V1" failback_attempt="commit-attempt-1" failback_hash
  failback_hash="$(ftctl_dr_runtime_failback_commit_envelope_sha256 \
    "${failback_contract}" "${plan}" "run-failback" "${plan}:run-failback" \
    "4" "4" "4" "run-failback" "${failback_attempt}" \
    "POWERED_ON" "POWERED_ON" "POWER_STATE_VALIDATED")"
  out="$(ftctl_dr_runtime_failback_commit "${plan}" "run-failback" "${plan}:run-failback" \
    "4" "4" "POWERED_ON" "POWERED_ON" "POWER_STATE_VALIDATED" "1" "4" "5" "true" \
    "${failback_contract}" "4" "run-failback" "${failback_attempt}" "${failback_hash}" 2>&1)"
  rc=$?
  set -e
  selftest_assert_eq "${rc}" "78" "running target blocks source authority commit"
  selftest_assert_contains "${out}" "DR_FAILBACK_TARGET_STILL_RUNNING" "target power preflight error"

  python3 - "${reverse_profile}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    profile = json.load(handle)
target = profile.setdefault("target", {})
target.setdefault("hardware", {})["guestId"] = "windows2019srvNext_64Guest"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(profile, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
  set +e
  ftctl_dr_runtime_failback_requires_vcenter_guest_heartbeat "${reverse_profile}"
  rc=$?
  set -e
  selftest_assert_eq "${rc}" "1" "ABLESTACK Windows failback does not require vCenter heartbeat"

  python3 - "${reverse_profile}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    profile = json.load(handle)
profile["providerPair"] = "ABLESTACK_TO_VMWARE"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(profile, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
  failback_hash="$(ftctl_dr_runtime_failback_commit_envelope_sha256 \
    "${failback_contract}" "${plan}" "run-failback" "${plan}:run-failback" \
    "4" "4" "4" "run-failback" "${failback_attempt}" \
    "POWERED_OFF" "POWERED_ON" "POWER_STATE_VALIDATED")"
  set +e
  out="$(ftctl_dr_runtime_failback_commit "${plan}" "run-failback" "${plan}:run-failback" \
    "4" "4" "POWERED_OFF" "POWERED_ON" "POWER_STATE_VALIDATED" "1" "4" "5" "true" \
    "${failback_contract}" "4" "run-failback" "${failback_attempt}" "${failback_hash}" 2>&1)"
  rc=$?
  set -e
  selftest_assert_eq "${rc}" "78" "Windows VMware target rejects power-only failback commit"
  selftest_assert_contains "${out}" "DR_FAILBACK_WINDOWS_GUEST_HEARTBEAT_REQUIRED" \
    "Windows source requires guest heartbeat"

  failback_hash="$(ftctl_dr_runtime_failback_commit_envelope_sha256 \
    "${failback_contract}" "${plan}" "run-failback" "${plan}:run-failback" \
    "4" "4" "4" "run-failback" "${failback_attempt}" \
    "POWERED_OFF" "POWERED_ON" "GUEST_HEARTBEAT_VALIDATED")"
  out="$(
    ftctl_dr_scheduler_resume_after_transition() {
      ftctl_dr_scheduler_active_worker_valid() {
        return 0
      }
      ftctl_state_write_kv_all "$(ftctl_dr_scheduler_control_path "$1")" \
        "version=4" "generation=11" "command=run" "owner_run=$2"
      ftctl_dr_scheduler_write_heartbeat "$1" "scheduler-session-11" "11" \
        "$2" "$$" "11111"
      ftctl_dr_scheduler_control_ack "$1" "11" "RUNNING" "IDLE" "$2" \
        "scheduler-session-11" "11" "$$" "11111"
      ftctl_dr_runtime_path_set "$4" "scheduler_state=RUNNING" "control_state=RUNNING"
      return 0
    }
    ftctl_dr_runtime_failback_commit "${plan}" "run-failback" "${plan}:run-failback" \
      "4" "4" "POWERED_OFF" "POWERED_ON" "GUEST_HEARTBEAT_VALIDATED" "1" "4" "5" "true" \
      "${failback_contract}" "4" "run-failback" "${failback_attempt}" "${failback_hash}"
  )"
  selftest_assert_contains "${out}" '"state":"SYNCING"' "Cloud commit resumes protection"
  selftest_assert_contains "${out}" '"active_side":"SOURCE"' "Cloud commit restores source authority"
  selftest_assert_contains "${out}" '"engine_ack_state":"ACKNOWLEDGED"' "Cloud commit is acknowledged"
  selftest_assert_contains "${out}" '"failback_phase":"PROTECTION_RESUMING"' "protection resume phase"
  selftest_assert_file_contains "${active_path}" '"activeSide":"SOURCE"'
  selftest_assert_file_contains "${plan_dir}/failbacks/run-failback.commit.state" "phase=ACKNOWLEDGED"
  selftest_assert_file_contains "${plan_dir}/failbacks/run-failback.commit.state" "control_generation=11"
  selftest_assert_file_contains "$(ftctl_dr_scheduler_sequence_path "${plan}")" "resume_baseline_checkpoint_sequence=4"
  selftest_assert_file_contains "$(ftctl_dr_scheduler_sequence_path "${plan}")" "minimum_completed_checkpoint_sequence=5"
  selftest_assert_file_contains "$(ftctl_dr_scheduler_sequence_path "${plan}")" "immediate_cycle_pending=true"
  selftest_assert_file_contains "${status_path}" "latest_completed_checkpoint_sequence=3"
  selftest_assert_file_contains "${status_path}" "latest_completed_baseline_generation=3"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-failback-commit-status \
    --config "${SELFTEST_CONFIG}" --plan "${plan}" --run run-failback \
    --session-id "${plan}:run-failback" --commit-contract-version "${failback_contract}" \
    --commit-attempt-id "${failback_attempt}" --commit-envelope-sha256 "${failback_hash}" --json)"
  selftest_assert_contains "${out}" '"failback_commit_outcome":"ACKNOWLEDGED"' "commit status projects durable acknowledgement"

  out="$(
    ftctl_dr_scheduler_active_worker_valid() {
      return 0
    }
    ftctl_state_write_kv_all "${plan_dir}/failbacks/run-failback.commit.state" \
      "version=3" "plan=${plan}" "run=run-failback" "session_id=${plan}:run-failback" \
      "checkpoint_sequence=4" "authority_generation=4" \
      "baseline_generation=4" "evidence_run=run-failback" \
      "contract_version=${failback_contract}" "commit_attempt_id=${failback_attempt}" \
      "commit_envelope_sha256=${failback_hash}" \
      "phase=SCHEDULER_RESUMING" "outcome=UNKNOWN" \
      "control_generation=12" "control_ack_generation=11" \
      "source_power_state=POWERED_ON" "target_power_state=POWERED_OFF"
    ftctl_state_write_kv_all "$(ftctl_dr_scheduler_control_path "${plan}")" \
      "version=4" "generation=12" "command=run" "owner_run=run-failback"
    ftctl_dr_scheduler_write_heartbeat "${plan}" "scheduler-session-12" "12" \
      "run-failback" "$$" "12121"
    ftctl_dr_scheduler_control_ack "${plan}" "12" "RUNNING" "IDLE" "run-failback" \
      "scheduler-session-12" "12" "$$" "12121"
    ftctl_dr_runtime_path_set "$(ftctl_dr_runtime_run_path "${plan}" "run-failback")" \
      "engine_ack_state=UNKNOWN" "failback_commit_outcome=UNKNOWN" \
      "failback_commit_phase=SCHEDULER_RESUMING"
    ftctl_dr_runtime_failback_commit_status "${plan}" "run-failback" \
      "${plan}:run-failback" "${failback_contract}" "${failback_attempt}" "${failback_hash}" "1"
  )"
  selftest_assert_contains "${out}" '"failback_commit_outcome":"ACKNOWLEDGED"' "late ACK converges commit status"
  selftest_assert_file_contains "${plan_dir}/failbacks/run-failback.commit.state" "recovered_from_late_ack=true"
  selftest_assert_file_contains "${status_path}" "latest_completed_checkpoint_sequence=3"

  out="$(
    ftctl_dr_scheduler_request_and_wait() {
      printf '12\n'
    }
    ftctl_dr_runtime_failback_abort "${plan}" "run-failback" "${plan}:run-failback" \
      "prepare" "POWERED_OFF" "POWERED_ON" "1"
  )"
  selftest_assert_contains "${out}" '"rollback_state":"FENCED"' "rollback prepare fences the scheduler"
  selftest_assert_contains "${out}" '"failback_phase":"ROLLBACK_FENCING"' "rollback prepare phase is explicit"

  ftctl_dr_runtime_path_set "$(ftctl_dr_runtime_run_path "${plan}" "run-failback")" \
    "error_code=DR_FAILBACK_PROTECTION_RESUME_FAILED" \
    "error_message=stale protection resume failure" \
    "failed_component=ftctl"
  out="$(
    ftctl_dr_scheduler_request_and_wait() {
      printf '13\n'
    }
    ftctl_dr_runtime_failback_abort "${plan}" "run-failback" "${plan}:run-failback" \
      "commit" "POWERED_ON" "POWERED_OFF" "1"
  )"
  selftest_assert_contains "${out}" '"state":"FAILED_OVER"' "abort restores failed-over state"
  selftest_assert_contains "${out}" '"active_side":"TARGET"' "abort restores target authority"
  selftest_assert_contains "${out}" '"failback_phase":"ABORTED"' "abort phase is explicit"
  selftest_assert_contains "${out}" '"rollback_state":"COMPLETED"' "rollback commit is durable"
  selftest_assert_contains "${out}" '"failback_commit_outcome":"ROLLED_BACK"' "rollback outcome is typed"
  selftest_assert_contains "${out}" '"error_code":""' "rollback clears stale failback error"
  selftest_assert_contains "${out}" '"error_message":""' "rollback clears stale failback message"
  selftest_assert_contains "${out}" '"failed_component":""' "rollback clears stale failed component"

  out="$(
    ftctl_dr_scheduler_request_and_wait() {
      selftest_fail "completed rollback must not fence the scheduler again"
    }
    ftctl_dr_runtime_failback_abort "${plan}" "run-failback" "${plan}:run-failback" \
      "prepare" "POWERED_ON" "POWERED_OFF" "1"
  )"
  selftest_assert_contains "${out}" '"rollback_state":"COMPLETED"' "completed rollback prepare is idempotent"
  selftest_assert_file_contains "$(ftctl_dr_runtime_run_path "${plan}" "run-failback")" "failback_phase=ABORTED"

  local newer_run_path
  newer_run_path="$(ftctl_dr_runtime_run_path "${plan}" "run-newer-failback")"
  ftctl_state_write_kv_all "${newer_run_path}" \
    "action=dr-failback-start" "state=FAILBACK_DATA_READY" "worker_state=SUCCEEDED" \
    "run_uuid=run-newer-failback" "control_request_run_uuid=run-newer-failback" \
    "rollback_state=NONE" "updated_at=$(ftctl_now_iso8601)"
  ftctl_dr_runtime_atomic_copy "${newer_run_path}" "${status_path}" "0644"
  ftctl_dr_runtime_path_set "$(ftctl_dr_runtime_run_path "${plan}" "run-failback")" \
    "run_uuid=run-failback" "control_request_run_uuid=run-failback"
  ftctl_dr_runtime_publish_status "$(ftctl_dr_runtime_run_path "${plan}" "run-failback")" "${status_path}"
  selftest_assert_file_contains "${status_path}" "control_request_run_uuid=run-newer-failback"
  selftest_assert_file_not_contains "${status_path}" "control_request_run_uuid=run-failback"

  ftctl_dr_runtime_path_set "${newer_run_path}" "state=READY" "worker_state=SUCCEEDED"
  ftctl_dr_runtime_atomic_copy "${newer_run_path}" "${status_path}" "0644"
  ftctl_dr_runtime_publish_status "$(ftctl_dr_runtime_run_path "${plan}" "run-failback")" "${status_path}"
  selftest_assert_file_contains "${status_path}" "control_request_run_uuid=run-failback"
}

selftest_case_dr_scheduler_wait_is_interrupted_by_new_generation() {
  selftest_reset_env
  selftest_info "FTCTL_DR scheduler wakes from RPO wait when a newer control generation arrives"

  local plan="plan-generation-wakeup"
  local started finished elapsed
  ftctl_dr_scheduler_control_set "${plan}" "run" "owner-1" >/dev/null
  (
    sleep 1
    ftctl_state_write_kv_all "$(ftctl_dr_scheduler_control_path "${plan}")" \
      "version=4" "generation=2" "command=run" "owner_run=owner-2"
  ) &
  started="$(date +%s)"
  ftctl_dr_scheduler_sleep_or_stop "${plan}" "8" "1" || true
  finished="$(date +%s)"
  elapsed=$((finished - started))
  (( elapsed < 5 )) || selftest_fail "new control generation did not interrupt scheduler wait"
}

selftest_case_dr_runtime_reprotect_starts_reverse_protection_checkpoint() {
  selftest_reset_env
  selftest_info "FTCTL_DR reprotect starts reverse protection while target remains active"

  local plan="plan-reprotect"
  local profile="${SELFTEST_ROOT}/dr-reprotect-profile.json"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local status_path="${plan_dir}/status.state"
  local failover_dir="${plan_dir}/failovers"
  local active_profile="${plan_dir}/profile.json"
  local authority_spec="${SELFTEST_ROOT}/dr-reprotect-authority.json"
  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/qemu-img-reprotect.log"
  local out="" session_path="" active_path="" reverse_profile="" reverse_points=""

  mkdir -p "${plan_dir}" "${failover_dir}" "${fakebin}" "${SELFTEST_ROOT}/source" "${SELFTEST_ROOT}/target"
  cat > "${fakebin}/qemu-img" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
case "\${1:-}" in
  info)
    printf '{"format":"qcow2","virtual-size":1048576}\n'
    ;;
  create)
    target="\${@: -2:1}"
    : > "\${target}"
    ;;
  convert)
    target="\${@: -1}"
    : > "\${target}"
    ;;
esac
EOF
  chmod +x "${fakebin}/qemu-img"
  : > "${SELFTEST_ROOT}/target/root.qcow2"
  cat > "${profile}" <<JSON
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "${plan}",
  "runUuid": "run-original",
  "direction": "KVM_TO_KVM",
  "source": {"provider": "ABLESTACK", "driver": "KVM_QMP"},
  "target": {
    "provider": "ABLESTACK",
    "driver": "ABLESTACK",
    "zoneId": "zone-1",
    "storageRef": "${SELFTEST_ROOT}/target",
    "serviceOfferingId": "service-offering-1",
    "networks": [{"networkId": "network-1"}]
  },
  "mapping": {
    "disks": [
      {"device": "vda", "sourcePath": "${SELFTEST_ROOT}/source/root.qcow2", "targetPath": "${SELFTEST_ROOT}/target/root.qcow2", "sourceFormat": "qcow2", "targetFormat": "qcow2", "sizeBytes": 1048576, "targetDiskOfferingId": "disk-offering-1"}
    ]
  }
}
JSON
  cat > "${authority_spec}" <<JSON
{
  "contractVersion": "2026-07-23",
  "planUuid": "${plan}",
  "runUuid": "run-reprotect",
  "expectedActiveSide": "TARGET",
  "authorityGeneration": 7,
  "cutoverSessionId": "cloud-cutover-session-7",
  "checkpointSequence": 5,
  "targetVmId": 256,
  "targetExternalRef": "target-vm-uuid",
  "targetInstanceName": "i-2-256-VM",
  "targetPowerState": "POWERED_ON",
  "targetMaterialized": true,
  "targetPromotionState": "PROMOTED",
  "bootValidationState": "POWER_STATE_VALIDATED"
}
JSON
  cat > "${status_path}" <<EOF
plan=${plan}
run=run-failover
action=dr-failover
state=FAILED_OVER
step=active-side-switch
progress=100
accepted=true
active_side=TARGET
target_power_state=POWER_ON_DELEGATED
target_promotion_state=PROMOTED
checkpoint_sequence=5
last_source_checkpoint_at=2026-07-01T02:10:00Z
last_target_durable_at=2026-07-01T02:10:03Z
target_ready_rpo_seconds=3
error_code=
updated_at=2026-07-01T02:10:04Z
EOF
  cat > "${failover_dir}/active.json" <<JSON
{
  "version": 1,
  "planUuid": "${plan}",
  "runUuid": "run-failover",
  "sessionId": "${plan}:run-failover",
  "state": "FAILED_OVER",
  "activeSide": "TARGET",
  "cloudAuthorityGeneration": 7,
  "restorePoint": {"checkpointSequence": 5},
  "targetPromotion": {"state": "PROMOTED", "powerState": "POWERED_ON"}
}
JSON
  cat > "${status_path}" <<EOF
plan=${plan}
run=stale-status
action=dr-sync-start
state=READY
step=target-checkpoint-ready
progress=100
accepted=true
active_side=SOURCE
checkpoint_sequence=1
error_code=
updated_at=2026-07-01T02:11:00Z
EOF

  out="$(FTCTL_DR_REPROTECT_FOREGROUND=1 PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-reprotect \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --run run-reprotect \
    --profile-json "${profile}" \
    --authority-spec-json "${authority_spec}" \
    --wait=false \
    --json)"
  selftest_assert_contains "${out}" '"result":"accepted"' "reprotect accepted"
  for _ in $(seq 1 100); do
    out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
      --config "${SELFTEST_CONFIG}" \
      --plan "${plan}" \
      --run run-reprotect \
      --json)"
    [[ "${out}" == *'"state":"READY"'* || "${out}" == *'"state":"ERROR"'* ]] && break
    sleep 0.05
  done
  selftest_assert_contains "${out}" '"state":"READY"' "delegated reprotect ready"
  selftest_assert_contains "${out}" '"step":"reprotect-ready"' "reprotect final step"
  selftest_assert_contains "${out}" '"active_side":"TARGET"' "reprotect target active"
  selftest_assert_contains "${out}" '"reprotect_mode":"reverse"' "reprotect reverse mode"
  selftest_assert_contains "${out}" '"reprotect_restore_point_sequence":6' "reprotect reverse checkpoint sequence"
  selftest_assert_contains "${out}" '"reverse_direction":"ABLESTACK_TO_ABLESTACK"' "reprotect reverse direction"
  selftest_assert_file_contains "${plan_dir}/runs/run-reprotect.state" "authority_source=failover-session"
  selftest_assert_file_contains "${plan_dir}/runs/run-reprotect.state" "cloud_authority_generation=7"
  selftest_assert_file_contains "${plan_dir}/runs/run-reprotect.authority.json" '"targetInstanceName": "i-2-256-VM"'

  reverse_profile="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/reverse-profiles/run-reprotect-reprotect.json"
  reverse_points="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/reverse-restore-points.jsonl"
  session_path="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/reprotects/run-reprotect.json"
  active_path="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}/reprotects/active.json"
  selftest_assert_file_contains "${reverse_profile}" "\"sourcePath\":\"${SELFTEST_ROOT}/target/root.qcow2\""
  selftest_assert_file_contains "${reverse_profile}" "\"targetPath\":\"${SELFTEST_ROOT}/source/root.qcow2\""
  selftest_assert_file_contains "${reverse_points}" '"cycleType":"reprotect-seed"'
  selftest_assert_file_contains "${session_path}" '"operation":"reprotect"'
  selftest_assert_file_contains "${active_path}" '"activeSide":"TARGET"'
  selftest_assert_file_contains "${active_profile}" '"reverseOf"'
  selftest_assert_file_contains "${plan_dir}/runs/run-reprotect.state" "scheduler_desired_state=RUNNING"
  selftest_assert_file_contains "${plan_dir}/scheduler/sequence.state" "reprotect_baseline_sequence=6"
  local scheduler_owner
  scheduler_owner="$(ftctl_dr_runtime_state_get_from_path "${plan_dir}/runs/run-reprotect.state" scheduler_owner_run_uuid)"
  [[ -n "${scheduler_owner}" ]] || selftest_fail "reprotect scheduler owner was not published"
  selftest_assert_file_contains "${plan_dir}/runs/${scheduler_owner}.state" "active_side=TARGET"
  selftest_assert_file_contains "${call_log}" "convert --force-share -p -n -S"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-status \
    --config "${SELFTEST_CONFIG}" \
    --plan "${plan}" \
    --json)"
  selftest_assert_contains "${out}" '"state":"READY"' "reprotect status ready"
  selftest_assert_contains "${out}" '"active_side":"TARGET"' "reprotect status target active"
}

selftest_case_dr_vmware_missing_mover_is_rejected_before_scheduler() {
  selftest_reset_env
  selftest_info "FTCTL_DR scheduler VMware path requires a mover"

  local fakebin="${SELFTEST_ROOT}/fakebin"
  local profile="${SELFTEST_ROOT}/dr-scheduler-vmware-no-mover-profile.json"
  local out="" rc=0
  mkdir -p "${fakebin}"
  cat > "${fakebin}/qemu-img" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"
  cat > "${profile}" <<'JSON'
{
  "version": 1,
  "engine": "FTCTL_DR",
  "planUuid": "plan-scheduler-vmware-no-mover",
  "runUuid": "run-scheduler-vmware-no-mover",
  "direction": "VMWARE_TO_VMWARE",
  "source": {"provider": "VMWARE", "driver": "VMWARE_CBT", "vmId": "vm-101"},
  "target": {"provider": "VMWARE", "driver": "VMWARE_VDDK", "vmId": "vm-201"},
  "schedule": {"intervalSeconds": 0},
  "request": {"maxCycles": 1},
  "mapping": {
    "disks": [
      {
        "device": "scsi0:0",
        "sourceVmdkPath": "[prod] vm-101/root.vmdk",
        "targetVmdkPath": "[dr] vm-201/root.vmdk",
        "sizeBytes": 1048576,
        "targetDiskOfferingId": "disk-offering-1"
      }
    ]
  }
}
JSON

  out="$(FTCTL_DR_VMWARE_FORCE_VDDK_READY=1 FTCTL_DR_VMWARE_MOVER="${fakebin}/missing-mover" PATH="${fakebin}:$PATH" FTCTL_DR_SCHEDULER_FOREGROUND=1 bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-sync-start \
    --config "${SELFTEST_CONFIG}" \
    --plan plan-scheduler-vmware-no-mover \
    --run run-scheduler-vmware-no-mover \
    --profile-json "${profile}" \
    --role coordinator \
    --mode planned \
    --wait=false \
    --json)" || rc=$?
  [[ "${rc}" != "0" ]] || selftest_fail "vmware scheduler without mover should fail"
  selftest_assert_contains "${out}" '"result":"error"' "vmware no mover result"
  selftest_assert_contains "${out}" '"accepted":false' "vmware no mover accepted"
  selftest_assert_contains "${out}" '"state":"ERROR"' "vmware no mover state"
  selftest_assert_contains "${out}" '"step":"vmware-capability-missing"' "vmware no mover capability gate"
  selftest_assert_contains "${out}" '"error_code":"DR_VMWARE_MOVER_UNAVAILABLE"' "vmware no mover error code"
}

selftest_case_dr_vmware_mover_uses_raw_over_nbd_image_opts() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware mover uses raw-over-NBD image opts"

  local fakebin="${SELFTEST_ROOT}/fakebin"
  local call_log="${SELFTEST_ROOT}/vmware-mover-image-opts.log"
  local credentials="${SELFTEST_ROOT}/vmware-credentials.json"
  local disk_map="${SELFTEST_ROOT}/vmware-disks.json"
  local target_map="${SELFTEST_ROOT}/ablestack-disks.json"
  local cbt_helper="${SELFTEST_ROOT}/fake-cbt-query.py"
  local vddk_dir="${SELFTEST_ROOT}/vddk"
  mkdir -p "${fakebin}" "${vddk_dir}/lib64"
  : > "${vddk_dir}/lib64/libvixDiskLib.so"
  : > "${call_log}"

  cat > "${fakebin}/nbdkit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'NBDKIT:%s\n' "$*" >> "${FTCTL_FAKE_CALL_LOG}"
if [[ "${1-}" == "--dump-plugin" ]]; then
  printf 'name=vddk\n'
  printf 'vddk_library_version=8.0.0\n'
  exit 0
fi
socket_path=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "--unix" ]]; then
    socket_path="${2-}"
    shift 2
    continue
  fi
  shift
done
[[ -n "${socket_path}" ]] || exit 2
exec python3 - "${socket_path}" <<'PY'
import os
import socket
import sys
import time

path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
while True:
    time.sleep(1)
PY
EOF
  chmod +x "${fakebin}/nbdkit"

  cat > "${fakebin}/qemu-img" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'QEMU_IMG:%s\n' "$*" >> "${FTCTL_FAKE_CALL_LOG}"
exit 0
EOF
  chmod +x "${fakebin}/qemu-img"

  cat > "${fakebin}/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'OPENSSL:%s\n' "$*" >> "${FTCTL_FAKE_CALL_LOG}"
if [[ "${1-}" == "s_client" ]]; then
  printf '-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n'
  exit 0
fi
if [[ "${1-}" == "x509" ]]; then
  cat >/dev/null || true
  printf 'sha1 Fingerprint=AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD\n'
  exit 0
fi
exit 1
EOF
  chmod +x "${fakebin}/openssl"

  cat > "${cbt_helper}" <<'PY'
import json
print(json.dumps({
    "activation_verified": True,
    "new_change_id": "52 00 02",
    "vmdk_path": "[datastore1] Rocky10/Rocky10.vmdk",
    "areas": [{"start": 0, "length": 1048576}],
}))
PY

  cat > "${credentials}" <<JSON
{
  "credentials": {
    "source": {
      "endpoint": "10.10.21.10",
      "principal": "administrator@ablecloud.local",
      "auth": {"password": "secret"},
      "tlsVerify": false,
      "vddkLibdir": "${vddk_dir}"
    }
  }
}
JSON
  cat > "${disk_map}" <<'JSON'
{
  "sourceVmRef": "vm-101",
  "disks": [
    {
      "device": "disk0",
      "cbtDiskId": "scsi0:0",
      "sourceDiskKey": "2000",
      "sourceSnapshotName": "snapshot-test",
      "sourceVmdkPath": "[datastore1] Rocky10/Rocky10.vmdk",
      "targetFormat": "raw"
    }
  ]
}
JSON
  cat > "${target_map}" <<'JSON'
{
  "disks": [
    {
      "targetPath": "rbd:rbd/target-root",
      "targetFormat": "raw"
    }
  ]
}
JSON

  FTCTL_FAKE_CALL_LOG="${call_log}" \
  FTCTL_DR_DISK_MAP="${disk_map}" \
  FTCTL_DR_TARGET_DISK_MAP="${target_map}" \
  FTCTL_DR_CREDENTIALS_FILE="${credentials}" \
  FTCTL_DR_VMWARE_MOVER_LOG_DIR="${SELFTEST_ROOT}/run/dr-runtime/mover" \
  FTCTL_DR_VMWARE_CREATE_RUN_SNAPSHOT=0 \
  FTCTL_DR_VMWARE_CBT_PYTHON="$(command -v python3)" \
  FTCTL_DR_VMWARE_CBT_QUERY_HELPER="${cbt_helper}" \
  FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT=5 \
  PATH="${fakebin}:$PATH" \
    bash "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"

  selftest_assert_file_contains "${call_log}" "QEMU_IMG:info --force-share --image-opts driver=raw,file.driver=nbd"
  selftest_assert_file_contains "${call_log}" "QEMU_IMG:convert --force-share -p -n --image-opts -O raw driver=raw,file.driver=nbd"
  selftest_assert_file_contains "${call_log}" "thumbprint=AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD"
  selftest_assert_file_contains "${call_log}" "rbd:rbd/target-root"
  selftest_assert_file_not_contains "${call_log}" "json:{"
}

selftest_case_dr_vmware_cycle_result_contract() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware cycle result and journal contract"

  local metric_path="${SELFTEST_ROOT}/cycle-metric.json"
  local result_path="${SELFTEST_ROOT}/cycle-result.json"
  local results_path="${SELFTEST_ROOT}/cycle-results.json"
  local journal_path="${SELFTEST_ROOT}/cycle-journal.json"
  local cycle_metrics_path="${SELFTEST_ROOT}/cycle-metrics.json"
  cat > "${metric_path}" <<'JSON'
{"changedExtentCount":1,"changedBytes":4096,"sourceReadBytes":4096,"targetWrittenBytes":4096,"transferPayloadBytes":4096,"durationMs":10,"throughputBps":409600,"metricsEstimated":false}
JSON
  printf '[]\n' > "${results_path}"

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  ftctl_vmware_mover_build_disk_result 0 "root-disk" "FULL_SEED" "FULL_SEED" "" "change-1" \
    1048576 false "${metric_path}" "${result_path}"
  python3 - "${result_path}" "${results_path}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    result = json.load(handle)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump([result], handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
  FTCTL_DR_PLAN_UUID="plan-result-contract" \
  FTCTL_DR_RUN_UUID="run-result-contract" \
  FTCTL_DR_CHECKPOINT_SEQUENCE=1 \
    ftctl_vmware_mover_write_cycle_journal "${journal_path}" "DATA_COPIED" "METADATA_ONLY" "" "" "${results_path}"

  cat > "${cycle_metrics_path}" <<'JSON'
{"schemaVersion":1,"cycleToken":"plan-result-contract:1","planUuid":"plan-result-contract","runUuid":"run-result-contract","sequence":1,"requestedMode":"CBT_INCREMENTAL","effectiveMode":"NO_CHANGE","automaticReseed":false,"modeDecisionCode":"CBT_BASELINE_VALID","reseedReason":"","invalidBaselineDiskCount":0,"incrementalVerified":true,"metricsEstimated":false,"baselineGeneration":1,"cycleCommitState":"LOCAL_DURABLE","virtualBytes":1048576,"changedBytes":0,"sourceReadBytes":0,"targetWrittenBytes":0,"transferPayloadBytes":0,"changedExtentCount":0,"durationMs":5,"throughputBps":0,"disks":[{"diskIndex":0,"diskLabel":"root-disk","requestedMode":"CBT_INCREMENTAL","effectiveMode":"NO_CHANGE","previousChangeId":"change-1","newChangeId":"change-1","virtualBytes":1048576,"changedBytes":0,"sourceReadBytes":0,"targetWrittenBytes":0,"transferPayloadBytes":0,"changedExtentCount":0,"durationMs":5,"throughputBps":0,"incrementalVerified":true,"metricsEstimated":false}]}
JSON
  FTCTL_DR_PLAN_UUID="plan-result-contract" \
  FTCTL_DR_RUN_UUID="run-result-contract" \
  FTCTL_DR_CHECKPOINT_SEQUENCE=1 \
  FTCTL_DR_CYCLE_METRICS_PATH="${cycle_metrics_path}" \
    ftctl_vmware_mover_write_cycle_journal "${journal_path}" "LOCAL_DURABLE" "NONE" "" "" "${results_path}"

  python3 - "${results_path}" "${journal_path}" <<'PY' || selftest_fail "vmware cycle result or journal contract is invalid"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    results = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    journal = json.load(handle)
assert results[0]["diskLabel"] == "root-disk"
assert results[0]["newChangeId"] == "change-1"
assert results[0]["changedBytes"] == 4096
assert journal["state"] == "LOCAL_DURABLE"
assert journal["dataCopied"] is True
assert journal["metadataCommitted"] is True
assert journal["completedDiskCount"] == 1
assert journal["effectiveMode"] == "NO_CHANGE"
assert journal["baselineGeneration"] == 1
assert journal["cycleToken"] == "plan-result-contract:1"
PY
  if grep -Eq -- '--arg[[:space:]]+label|\$label([^[:alnum:]_]|$)' "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"; then
    selftest_fail "vmware mover must not use jq reserved label variable"
  fi
}

selftest_case_dr_runtime_state_snapshot_consistency() {
  selftest_reset_env
  selftest_info "FTCTL_DR status reads one immutable state generation"

  local state_path="${SELFTEST_ROOT}/snapshot-consistency.state"
  ftctl_state_write_kv_all "${state_path}" \
    "latest_completed_checkpoint_sequence=10" \
    "latest_completed_baseline_generation=10"
  ftctl_dr_runtime_state_snapshot_begin "${state_path}"
  ftctl_dr_runtime_path_set "${state_path}" \
    "latest_completed_checkpoint_sequence=11" \
    "latest_completed_baseline_generation=11"
  selftest_assert_eq "$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_checkpoint_sequence")" \
    "10" "captured checkpoint sequence"
  selftest_assert_eq "$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_baseline_generation")" \
    "10" "captured baseline generation"
  ftctl_dr_runtime_state_snapshot_end
  selftest_assert_eq "$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_checkpoint_sequence")" \
    "11" "published checkpoint sequence"
  selftest_assert_eq "$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_baseline_generation")" \
    "11" "published baseline generation"
}

selftest_case_dr_vmware_direct_target_patch_contract() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware writes extents directly to a Cloud-managed target block path"

  local source_path="${SELFTEST_ROOT}/direct-source.raw"
  local target_path="${SELFTEST_ROOT}/direct-target.raw"
  local areas_path="${SELFTEST_ROOT}/direct-areas.json"
  local metrics_path="${SELFTEST_ROOT}/direct-metrics.json"

  python3 - "${source_path}" "${target_path}" "${areas_path}" <<'PY'
import json
import sys

source_path, target_path, areas_path = sys.argv[1:4]
size = 1024 * 1024
with open(source_path, "wb") as handle:
    handle.truncate(size)
with open(target_path, "wb") as handle:
    handle.truncate(size)
with open(source_path, "r+b") as handle:
    handle.seek(4096)
    handle.write(b"ABLESTACK-DR-DIRECT-TARGET")
with open(areas_path, "w", encoding="utf-8") as handle:
    json.dump({"areas": [{"offset": 4096, "length": 4096}]}, handle)
PY

  python3 "${ROOT_DIR}/lib/ftctl/dr_extent_patch.py" \
    --source "${source_path}" \
    --target "${target_path}" \
    --areas-json "${areas_path}" \
    --expected-source-size 1048576 \
    --expected-target-size 1048576 > "${metrics_path}" ||
      selftest_fail "direct target extent patch should succeed"

  python3 - "${source_path}" "${target_path}" "${metrics_path}" <<'PY' ||
import json
import sys

source_path, target_path, metrics_path = sys.argv[1:4]
with open(source_path, "rb") as source, open(target_path, "rb") as target:
    source.seek(4096)
    target.seek(4096)
    assert target.read(4096) == source.read(4096)
with open(metrics_path, "r", encoding="utf-8") as handle:
    metrics = json.load(handle)
assert metrics["changedExtentCount"] == 1
assert metrics["sourceReadBytes"] == 4096
assert metrics["targetWrittenBytes"] == 4096
PY
    selftest_fail "direct target patch data or metrics are invalid"

  python3 - "${ROOT_DIR}/lib/ftctl/dr_extent_patch.py" <<'PY' ||
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("dr_extent_patch", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert module.parse_rbd_target("rbd:rbd/target-image") == ("rbd", "target-image")
assert module.parse_rbd_target("/dev/rbd0") is None
PY
    selftest_fail "native librbd target parsing contract is invalid"

  selftest_assert_file_contains "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh" \
    "target_direct=true"
  selftest_assert_file_contains "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh" \
    "target_direct_block=false"
  selftest_assert_file_contains "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh" \
    'target_cleanup_dev=""'
}

selftest_case_dr_vmware_nbd_readiness_barrier() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware NBD readiness barrier waits for a stable size"

  local fakebin="${SELFTEST_ROOT}/nbd-ready-bin"
  local sysfs="${SELFTEST_ROOT}/nbd-sysfs"
  local counter="${SELFTEST_ROOT}/nbd-ready-count"
  mkdir -p "${fakebin}" "${sysfs}/nbd-test"
  printf '0\n' > "${sysfs}/nbd-test/size"
  printf '0\n' > "${counter}"
  cat > "${fakebin}/blockdev" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=$(cat "${FTCTL_FAKE_NBD_COUNTER}")
count=$((count + 1))
printf '%s\n' "${count}" > "${FTCTL_FAKE_NBD_COUNTER}"
if (( count >= 2 )); then
  printf '2048\n' > "${FTCTL_DR_NBD_SYSFS_ROOT}/nbd-test/size"
  printf '1048576\n'
else
  printf '0\n'
fi
EOF
  chmod +x "${fakebin}/blockdev"

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  FTCTL_FAKE_NBD_COUNTER="${counter}" \
  FTCTL_DR_NBD_SYSFS_ROOT="${sysfs}" \
  PATH="${fakebin}:${PATH}" \
    ftctl_vmware_mover_wait_block_device_ready /dev/nbd-test 1048576 500 10 ||
      selftest_fail "NBD readiness barrier should accept the delayed stable size"
  [[ "$(cat "${counter}")" -ge 2 ]] || selftest_fail "NBD readiness barrier did not poll"

  printf '0\n' > "${sysfs}/nbd-test/size"
  cat > "${fakebin}/blockdev" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF
  chmod +x "${fakebin}/blockdev"
  if FTCTL_DR_NBD_SYSFS_ROOT="${sysfs}" PATH="${fakebin}:${PATH}" \
      ftctl_vmware_mover_wait_block_device_ready /dev/nbd-test 1048576 30 10; then
    selftest_fail "NBD readiness barrier must reject a permanent zero-size device"
  fi
}

selftest_case_dr_vmware_nbd_reserved_pool_contract() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware uses the udev-isolated reserved NBD pool"

  unset FTCTL_DR_NBD_DEVICE_START FTCTL_DR_NBD_DEVICE_END
  unset FTCTL_DR_NBD_MODULE_MAX_DEVICES FTCTL_DR_NBD_MODULE_MAX_PARTITIONS
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  selftest_assert_eq "${FTCTL_DR_NBD_DEVICE_START}" "16" "reserved NBD pool start"
  selftest_assert_eq "${FTCTL_DR_NBD_DEVICE_END}" "31" "reserved NBD pool end"
  selftest_assert_eq "${FTCTL_DR_NBD_MODULE_MAX_DEVICES}" "32" "NBD module device count"
  selftest_assert_eq "${FTCTL_DR_NBD_MODULE_MAX_PARTITIONS}" "16" "NBD partition compatibility"
  selftest_assert_file_contains "${ROOT_DIR}/etc/10-ablestack-ftctl-nbd.rules" \
    'UDEV_DISABLE_PERSISTENT_STORAGE_BLKID_FLAG'
  selftest_assert_file_contains "${ROOT_DIR}/etc/10-ablestack-ftctl-nbd.rules" \
    'KERNEL=="nbd1'
}

selftest_case_dr_vmware_nbd_deterministic_drain() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware NBD drain waits for partition and sysfs teardown"

  local fakebin="${SELFTEST_ROOT}/nbd-drain-bin"
  local sysfs="${SELFTEST_ROOT}/nbd-drain-sysfs"
  local quarantine="${SELFTEST_ROOT}/nbd-quarantine"
  local call_log="${SELFTEST_ROOT}/nbd-drain.log"
  mkdir -p "${fakebin}" "${sysfs}/nbd-test/holders" \
    "${sysfs}/nbd-testp1/holders/dm-test"
  printf '4242\n' > "${sysfs}/nbd-test/pid"
  printf '2048\n' > "${sysfs}/nbd-test/size"
  : > "${call_log}"

  cat > "${fakebin}/blockdev" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'blockdev:%s\n' "$*" >> "${FTCTL_FAKE_CALL_LOG}"
exit 0
EOF
  cat > "${fakebin}/udevadm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'udevadm:%s\n' "$*" >> "${FTCTL_FAKE_CALL_LOG}"
exit 0
EOF
  cat > "${fakebin}/partx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'partx:%s\n' "$*" >> "${FTCTL_FAKE_CALL_LOG}"
rm -rf "${FTCTL_DR_NBD_SYSFS_ROOT}/nbd-testp1"
exit 0
EOF
  cat > "${fakebin}/dmsetup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'dmsetup:%s\n' "$*" >> "${FTCTL_FAKE_CALL_LOG}"
rm -rf "${FTCTL_DR_NBD_SYSFS_ROOT}/nbd-testp1/holders/dm-test"
exit 0
EOF
  cat > "${fakebin}/qemu-nbd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'qemu-nbd:%s\n' "$*" >> "${FTCTL_FAKE_CALL_LOG}"
rm -f "${FTCTL_DR_NBD_SYSFS_ROOT}/nbd-test/pid"
printf '0\n' > "${FTCTL_DR_NBD_SYSFS_ROOT}/nbd-test/size"
exit 0
EOF
  cat > "${fakebin}/lsblk" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fakebin}/blockdev" "${fakebin}/udevadm" "${fakebin}/partx" \
    "${fakebin}/dmsetup" "${fakebin}/qemu-nbd" "${fakebin}/lsblk"

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  FTCTL_FAKE_CALL_LOG="${call_log}"
  FTCTL_DR_NBD_SYSFS_ROOT="${sysfs}"
  FTCTL_DR_NBD_QUARANTINE_ROOT="${quarantine}"
  FTCTL_DR_NBD_DRAIN_TIMEOUT_MS=500
  FTCTL_DR_NBD_DRAIN_POLL_MS=10
  FTCTL_DR_NBD_STABLE_POLLS=2
  FTCTL_DR_PLAN_UUID="plan-nbd-drain"
  PATH="${fakebin}:${PATH}"
  export FTCTL_FAKE_CALL_LOG FTCTL_DR_NBD_SYSFS_ROOT FTCTL_DR_NBD_QUARANTINE_ROOT FTCTL_DR_PLAN_UUID PATH

  ftctl_vmware_mover_nbd_drain /dev/nbd-test TARGET QEMU_NBD ||
    selftest_fail "deterministic NBD drain should succeed"
  selftest_assert_file_contains "${call_log}" "blockdev:--flushbufs /dev/nbd-test"
  selftest_assert_file_contains "${call_log}" "dmsetup:remove --retry /dev/dm-test"
  selftest_assert_file_contains "${call_log}" "partx:-d /dev/nbd-test"
  selftest_assert_file_contains "${call_log}" "qemu-nbd:--disconnect /dev/nbd-test"
  selftest_assert_eq "${FTCTL_DR_NBD_TEARDOWN_STATE}" "DRAINED" "NBD teardown state"
  [[ ! -e "${sysfs}/nbd-testp1" ]] || selftest_fail "NBD partition child should be removed"
  [[ ! -d "${quarantine}/plan-nbd-drain" ]] ||
    [[ -z "$(find "${quarantine}/plan-nbd-drain" -type f -print -quit 2>/dev/null)" ]] ||
    selftest_fail "successful NBD drain must not leave quarantine records"
}

selftest_case_dr_vmware_nbd_holder_safety_barrier() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware NBD drain preserves mounted partition holders"

  local fakebin="${SELFTEST_ROOT}/nbd-holder-bin"
  local sysfs="${SELFTEST_ROOT}/nbd-holder-sysfs"
  local quarantine="${SELFTEST_ROOT}/nbd-holder-quarantine"
  local call_log="${SELFTEST_ROOT}/nbd-holder.log"
  local rc=0
  mkdir -p "${fakebin}" "${sysfs}/nbd-test/holders" \
    "${sysfs}/nbd-testp1/holders/dm-test"
  printf '4242\n' > "${sysfs}/nbd-test/pid"
  printf '2048\n' > "${sysfs}/nbd-test/size"
  : > "${call_log}"

  for command in blockdev udevadm partx qemu-nbd; do
    cat > "${fakebin}/${command}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${fakebin}/${command}"
  done
  cat > "${fakebin}/lsblk" <<'EOF'
#!/usr/bin/env bash
printf '/mnt/guest\n'
EOF
  cat > "${fakebin}/dmsetup" <<'EOF'
#!/usr/bin/env bash
printf 'dmsetup:%s\n' "$*" >> "${FTCTL_FAKE_CALL_LOG}"
exit 0
EOF
  chmod +x "${fakebin}/lsblk" "${fakebin}/dmsetup"

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  FTCTL_FAKE_CALL_LOG="${call_log}"
  FTCTL_DR_NBD_SYSFS_ROOT="${sysfs}"
  FTCTL_DR_NBD_QUARANTINE_ROOT="${quarantine}"
  FTCTL_DR_PLAN_UUID="plan-nbd-holder"
  PATH="${fakebin}:${PATH}"
  export FTCTL_FAKE_CALL_LOG FTCTL_DR_NBD_SYSFS_ROOT FTCTL_DR_NBD_QUARANTINE_ROOT FTCTL_DR_PLAN_UUID PATH

  ftctl_vmware_mover_nbd_drain /dev/nbd-test TARGET QEMU_NBD || rc=$?
  selftest_assert_eq "${rc}" "94" "mounted NBD holder exit code"
  selftest_assert_eq "${FTCTL_DR_NBD_TEARDOWN_STATE}" "QUARANTINED" \
    "mounted NBD holder quarantine state"
  [[ ! -s "${call_log}" ]] ||
    selftest_fail "mounted NBD holder must not be removed"
}

selftest_case_dr_vmware_nbd_quarantine_on_timeout() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware quarantines NBD devices that do not drain"

  local fakebin="${SELFTEST_ROOT}/nbd-timeout-bin"
  local sysfs="${SELFTEST_ROOT}/nbd-timeout-sysfs"
  local quarantine="${SELFTEST_ROOT}/nbd-timeout-quarantine"
  local rc=0
  mkdir -p "${fakebin}" "${sysfs}/nbd-test/holders"
  printf '4242\n' > "${sysfs}/nbd-test/pid"
  printf '2048\n' > "${sysfs}/nbd-test/size"
  for command in blockdev udevadm partx qemu-nbd nbd-client; do
    cat > "${fakebin}/${command}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${fakebin}/${command}"
  done
  cat > "${fakebin}/lsblk" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fakebin}/lsblk"

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  FTCTL_DR_NBD_SYSFS_ROOT="${sysfs}"
  FTCTL_DR_NBD_QUARANTINE_ROOT="${quarantine}"
  FTCTL_DR_NBD_DRAIN_TIMEOUT_MS=30
  FTCTL_DR_NBD_DRAIN_POLL_MS=10
  FTCTL_DR_NBD_STABLE_POLLS=2
  FTCTL_DR_PLAN_UUID="plan-nbd-timeout"
  PATH="${fakebin}:${PATH}"
  export FTCTL_DR_NBD_SYSFS_ROOT FTCTL_DR_NBD_QUARANTINE_ROOT FTCTL_DR_PLAN_UUID PATH

  ftctl_vmware_mover_nbd_drain /dev/nbd-test SOURCE NBD_CLIENT || rc=$?
  selftest_assert_eq "${rc}" "92" "NBD teardown timeout exit code"
  selftest_assert_eq "${FTCTL_DR_NBD_TEARDOWN_STATE}" "QUARANTINED" "NBD quarantine state"
  selftest_assert_file_contains "${quarantine}/plan-nbd-timeout/nbd-test.json" \
    '"errorCode":"DR_NBD_TEARDOWN_TIMEOUT"'
}

selftest_case_dr_vmware_automatic_reseed_mode() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware preserves baseline rows and separates requested/effective mode"

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  local source_map="${SELFTEST_ROOT}/vmware-baseline-source.json"
  local target_map="${SELFTEST_ROOT}/vmware-baseline-target.json"
  local state_path="${SELFTEST_ROOT}/vmware-mode-decision.json"
  local rows missing committed decision rc=0
  cat > "${source_map}" <<'JSON'
{"disks":[{"sourceDiskKey":"2000","cbtDiskId":"2000","changeId":"change-42","baselineGeneration":42,"lastSyncSequence":42,"baselineState":"LOCAL_DURABLE","sizeBytes":1048576,"sourceVmdkPath":"[ds] vm/root.vmdk"}]}
JSON
  cat > "${target_map}" <<'JSON'
{"disks":[{"targetPath":"rbd/target-root","sizeBytes":1048576,"targetFormat":"raw"}]}
JSON
  rows="$(ftctl_vmware_mover_disk_plan "${source_map}" "${target_map}")"
  selftest_assert_eq "$(jq -r '.[0].baselineState' <<< "${rows}")" "LOCAL_DURABLE" "baseline state row"
  selftest_assert_eq "$(jq -r '.[0].baselineGeneration' <<< "${rows}")" "42" "baseline generation row"
  selftest_assert_eq "$(jq -r '.[0].lastSyncSequence' <<< "${rows}")" "42" "last sequence row"
  selftest_assert_contains "$(jq -r '.[0].diskIdentityHash' <<< "${rows}")" "sha256:" "disk identity row"

  missing='[{"sourceDiskKey":"2000","diskIdentityHash":"sha256:test","previousChangeId":"","baselineGeneration":0,"baselineState":""}]'
  committed='[{"sourceDiskKey":"2000","diskIdentityHash":"sha256:test","previousChangeId":"change-42","baselineGeneration":42,"baselineState":"LOCAL_DURABLE"}]'
  decision="$(ftctl_vmware_mover_resolve_cycle_mode "${missing}" CBT_INCREMENTAL)"
  selftest_assert_eq "$(jq -r '.requestedMode' <<< "${decision}")" "CBT_INCREMENTAL" "missing baseline requested mode"
  selftest_assert_eq "$(jq -r '.effectiveMode' <<< "${decision}")" "FULL_RESEED" "missing baseline effective mode"
  selftest_assert_eq "$(jq -r '.decisionCode' <<< "${decision}")" "MISSING_CHANGE_ID" "missing baseline reason"
  selftest_assert_eq "$(jq -r '.automaticReseed' <<< "${decision}")" "true" "automatic reseed flag"
  selftest_assert_eq "$(jq -r '.effectiveMode' <<< "$(ftctl_vmware_mover_resolve_cycle_mode "${committed}" CBT_INCREMENTAL)")" \
    "CBT_INCREMENTAL" "committed baseline mode"

  ftctl_vmware_mover_commit_mode_decision "${state_path}" "${decision}" FULL_RESEED
  ftctl_vmware_mover_reseed_guard "${state_path}" "${decision}" || rc=$?
  selftest_assert_eq "${rc}" "90" "repeated automatic reseed guard"
}

selftest_case_dr_vmware_forward_target_map_reuses_ablestack_locator() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware forward cycles reuse canonical ABLESTACK RBD locators"

  local profile="${SELFTEST_ROOT}/vmware-forward-target-profile.json"
  local source_map="${SELFTEST_ROOT}/vmware-forward-source.json"
  local target_map="${SELFTEST_ROOT}/vmware-forward-target.json"
  local rows target_uri rc=0
  cat > "${profile}" <<'JSON'
{
  "version":1,
  "engine":"FTCTL_DR",
  "planUuid":"plan-forward-rbd",
  "direction":"VMWARE_TO_KVM",
  "source":{"provider":"VMWARE","driver":"VMWARE_DIRECT"},
  "target":{"provider":"ABLESTACK","driver":"ABLESTACK","storagePath":"rbd","storagePoolType":"RBD"},
  "mapping":{"disks":[{
    "device":"scsi0:0",
    "sourceDiskRef":"[datastore1] w22-01/w22-01.vmdk",
    "targetName":"w22-01-dr-disk-0",
    "targetDiskRef":"w22-01-dr-disk-0",
    "targetFormat":"raw",
    "sizeBytes":2147483648,
    "targetStorageType":"RBD",
    "targetStoragePath":"rbd",
    "targetStorageKrbdPath":"/dev/rbd"
  }]}
}
JSON
  cat > "${source_map}" <<'JSON'
{"disks":[{"device":"scsi0:0","sourceDiskKey":"2000","sourceVmdkPath":"[datastore1] w22-01/w22-01.vmdk","targetDiskRef":"w22-01-dr-disk-0","sizeBytes":2147483648}]}
JSON

  ftctl_dr_ablestack_canonicalize_profile "${profile}" "${target_map}"
  selftest_assert_eq "$(jq -r '.disks[0].targetPath' "${target_map}")" \
    "/dev/rbd/rbd/w22-01-dr-disk-0" "canonical forward krbd locator"

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/dr_vmware_mover.sh"
  rows="$(ftctl_vmware_mover_disk_plan "${source_map}" "${target_map}")"
  selftest_assert_eq "$(jq -r '.[0].targetPath' <<< "${rows}")" \
    "/dev/rbd/rbd/w22-01-dr-disk-0" "mover destination-only locator"
  target_uri="$(ftctl_vmware_mover_target_uri \
    "$(jq -r '.[0].targetPath' <<< "${rows}")" \
    "$(jq -r '.[0].targetStoragePath' <<< "${rows}")" \
    "$(jq -r '.[0].targetName' <<< "${rows}")" \
    "$(jq -r '.[0].targetStorageType' <<< "${rows}")")"
  selftest_assert_eq "${target_uri}" "rbd:rbd/w22-01-dr-disk-0" "librbd mover URI"

  ftctl_vmware_mover_disk_plan "${source_map}" "${target_map}.missing" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" != "0" ]] || selftest_fail "missing forward target map must not use source targetDiskRef"
}

selftest_case_dr_scheduler_systemd_launch_contract() {
  local plan="plan-systemd-owned" run="run-systemd-owned" plan_dir profile state status launch unit rc
  local failback_run="run-failback-completed" failback_dir
  selftest_reset_env
  plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  profile="${plan_dir}/profile.json"
  state="${plan_dir}/runs/${run}.state"
  status="${plan_dir}/status.state"
  launch="${plan_dir}/scheduler/launch.state"
  mkdir -p "${plan_dir}/runs" "${plan_dir}/scheduler"
  cat > "${profile}" <<JSON
{"planUuid":"${plan}","schedulerSessionUuid":"${plan}","source":{"provider":"VMWARE"},"target":{"provider":"ABLESTACK"}}
JSON
  ftctl_state_write_kv_all "${state}" "plan=${plan}" "run=${run}" "state=READY" "control_state=RUNNING"
  cp -f "${state}" "${status}"

  unit="$(ftctl_dr_scheduler_unit_name "${plan}")"
  selftest_assert_eq "${unit}" "ablestack-vm-ftctl-dr@${plan}.service" "Plan systemd unit name"
  selftest_assert_file_contains "${ROOT_DIR}/lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service" \
    'dr-scheduler-run --plan %i --json'
  selftest_assert_file_not_contains "${ROOT_DIR}/lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service" \
    'dr-scheduler-run --plan %I --json'
  ftctl_dr_scheduler_write_launch_state "${plan}" "${run}" "${profile}" "${state}" "${status}" "SELFTEST"
  selftest_assert_file_contains "${launch}" "plan_uuid=${plan}"
  selftest_assert_file_contains "${launch}" "run_uuid=${run}"
  selftest_assert_file_contains "${launch}" "desired_state=RUNNING"
  selftest_assert_file_contains "${launch}" "active_side=SOURCE"
  selftest_assert_file_contains "${launch}" "recovery_trigger=SELFTEST"

  if ftctl_dr_scheduler_unit_name 'invalid/plan' >/dev/null 2>&1; then
    selftest_fail "invalid Plan UUID must not produce a systemd unit name"
  fi

  rc=0
  ftctl_dr_runtime_path_set "${status}" "state=FAILED_OVER" "active_side=TARGET" "control_state=RUNNING"
  ftctl_dr_scheduler_recover "${plan}" "${run}" "${profile}" "${state}" "${status}" "SELFTEST" || rc=$?
  selftest_assert_eq "${rc}" "41" "TARGET authority suppresses scheduler recovery"

  failback_dir="${plan_dir}/failbacks"
  mkdir -p "${failback_dir}" "${plan_dir}/failovers"
  cat > "${plan_dir}/failovers/active.json" <<JSON
{"state":"FAILED_OVER","activeSide":"TARGET","cloudAuthorityGeneration":7,"runUuid":"run-failover-old","completedAt":"2026-08-22T00:10:00+09:00"}
JSON
  cat > "${failback_dir}/active.json" <<JSON
{"state":"COMPLETED","activeSide":"SOURCE","engineAckState":"ACKNOWLEDGED","commitOutcome":"ACKNOWLEDGED","sourcePowerState":"POWERED_ON","targetPowerState":"POWERED_OFF","cloudAuthorityGeneration":7,"postFailbackCheckpointSequence":9,"runUuid":"${failback_run}","completedAt":"2026-08-22T00:20:00+09:00"}
JSON
  ftctl_state_write_kv_all "${failback_dir}/${failback_run}.commit.state" \
    "plan=${plan}" "run=${failback_run}" "phase=COMPLETED" "outcome=ACKNOWLEDGED" \
    "source_power_state=POWERED_ON" "target_power_state=POWERED_OFF" \
    "authority_generation=7" "checkpoint_sequence=8"
  ftctl_dr_runtime_converge_completed_failback_authority "${plan}" "${state}" "${status}"
  selftest_assert_file_contains "${status}" "state=READY"
  selftest_assert_file_contains "${status}" "active_side=SOURCE"
  selftest_assert_file_contains "${status}" "target_promotion_state=STANDBY"
  selftest_assert_file_contains "${status}" "post_failback_checkpoint_sequence=9"

  # Plan-level status reads must repair the same durable race even when the
  # scheduler recovery hook already ran before failback completion.
  ftctl_dr_runtime_path_set "${status}" \
    "state=FAILED_OVER" "active_side=TARGET" "control_state=RUNNING"
  local status_json
  ftctl_dr_nbd_capacity_json() {
    printf '{"configured":true,"ready":true,"errorCode":""}\n'
  }
  status_json="$(ftctl_dr_runtime_status "${plan}" "" "0" "20" "1")"
  unset -f ftctl_dr_nbd_capacity_json
  selftest_assert_contains "${status_json}" '"state":"READY"' \
    "plan status read repairs completed failback state"
  selftest_assert_contains "${status_json}" '"active_side":"SOURCE"' \
    "plan status read repairs completed failback authority"
  selftest_assert_file_contains "${status}" "active_side=SOURCE"

  # A newer target authority must not be rewritten by an older failback.
  cat > "${plan_dir}/failovers/active.json" <<JSON
{"state":"FAILED_OVER","activeSide":"TARGET","cloudAuthorityGeneration":8,"runUuid":"run-failover-new","completedAt":"2026-08-22T00:30:00+09:00"}
JSON
  ftctl_dr_runtime_path_set "${status}" "state=FAILED_OVER" "active_side=TARGET" "control_state=RUNNING"
  rc=0
  ftctl_dr_runtime_converge_completed_failback_authority "${plan}" "${state}" "${status}" || rc=$?
  selftest_assert_eq "${rc}" "2" "newer TARGET authority blocks failback convergence"
  selftest_assert_file_contains "${status}" "active_side=TARGET"
  ftctl_dr_nbd_capacity_json() {
    printf '{"configured":true,"ready":true,"errorCode":""}\n'
  }
  status_json="$(ftctl_dr_runtime_status "${plan}" "" "0" "20" "1")"
  unset -f ftctl_dr_nbd_capacity_json
  selftest_assert_contains "${status_json}" '"state":"FAILED_OVER"' \
    "plan status read preserves newer failover state"
  selftest_assert_contains "${status_json}" '"active_side":"TARGET"' \
    "plan status read preserves newer target authority"
  rm -f "${plan_dir}/failovers/active.json"

  rc=0
  ftctl_dr_runtime_path_set "${status}" "state=READY" "active_side=SOURCE" "control_state=PAUSED"
  ftctl_dr_scheduler_recover "${plan}" "${run}" "${profile}" "${state}" "${status}" "SELFTEST" || rc=$?
  selftest_assert_eq "${rc}" "42" "PAUSED control state suppresses scheduler recovery"
}

selftest_case_dr_vmware_canonical_profile_preserves_committed_baseline() {
  selftest_reset_env
  selftest_info "DR VMware canonical profile preserves committed CBT baseline"
  local work profile disk_map
  work="${SELFTEST_ROOT}/dr-vmware-canonical-baseline"
  profile="${work}/profile.json"
  disk_map="${work}/vmware-disks.json"
  rm -rf "${work}"
  mkdir -p "${work}"
  cat > "${profile}" <<'JSON'
{"planUuid":"plan-full-resync","source":{"provider":"VMWARE","vmId":"vm-42"},"target":{"provider":"ABLESTACK"},"mapping":{"disks":[{"sourceDiskKey":"2000","cbtDiskId":"scsi0:0","sourceVmdkPath":"[ds] vm/root.vmdk","targetDiskRef":"rbd/target-root","sizeBytes":1048576}]}}
JSON
  cat > "${disk_map}" <<'JSON'
{"disks":[{"sourceDiskKey":"2000","cbtDiskId":"scsi0:0","sourceVmdkPath":"[ds] vm/root.vmdk","targetDiskRef":"rbd/target-root","sizeBytes":1048576,"changeId":"change-42","cbtChangeId":"change-42","baselineGeneration":42,"lastSyncSequence":42,"baselineState":"LOCAL_DURABLE"}]}
JSON

  ftctl_dr_vmware_canonicalize_profile "${profile}" "${disk_map}"

  selftest_assert_eq "$(jq -r '.disks[0].changeId' "${disk_map}")" "change-42" "canonical changeId"
  selftest_assert_eq "$(jq -r '.disks[0].baselineGeneration' "${disk_map}")" "42" "canonical baseline generation"
  selftest_assert_eq "$(jq -r '.disks[0].baselineState' "${disk_map}")" "LOCAL_DURABLE" "canonical baseline state"
}

selftest_case_dr_full_resync_request_is_one_shot() {
  selftest_reset_env
  selftest_info "DR full resync request is recorded as a one-shot scheduler cycle"
  local plan="plan-full-resync-request" run="run-full-resync-request"
  local plan_dir run_path status_path sequence_path
  plan_dir="$(ftctl_dr_runtime_plan_dir "${plan}")"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  rm -rf "${plan_dir}"
  mkdir -p "$(dirname "${run_path}")"
  ftctl_state_write_kv_all "${run_path}" "plan=${plan}" "run=${run}" "state=READY"
  cp -f "${run_path}" "${status_path}"

  ftctl_dr_scheduler_request_cycle "${plan}" "${run}" "FULL_RESEED" "${run_path}" "${status_path}" "true"

  selftest_assert_eq "$(ftctl_state_read_kv "${sequence_path}" requested_cycle_mode)" "FULL_RESEED" "requested cycle mode"
  selftest_assert_eq "$(ftctl_state_read_kv "${sequence_path}" requested_cycle_owner_run)" "${run}" "requested cycle owner"
  selftest_assert_eq "$(ftctl_state_read_kv "${sequence_path}" requested_cycle_state)" "PENDING" "requested cycle state"
  selftest_assert_eq "$(ftctl_state_read_kv "${status_path}" step)" "full-resync-queued" "full resync projection step"

  ftctl_state_set_path "${status_path}" \
    "run=scheduler-owner-run" \
    "scheduler_session_uuid=scheduler-session" \
    "scheduler_lease_epoch=7" \
    "latest_completed_producer_run_uuid=${run}" \
    "latest_completed_checkpoint_sequence=42" \
    "latest_completed_requested_mode=FULL_RESEED" \
    "latest_completed_effective_mode=FULL_RESEED" \
    "latest_completed_cycle_token=${plan}:42" \
    "data_commit_state=LOCAL_DURABLE" \
    "target_durable=true" \
    "latest_completed_target_durable_at=2026-07-31T00:00:02Z"
  ftctl_dr_scheduler_project_requested_cycle_run "${plan}" "${run}" "${status_path}" \
    "READY" "full-resync-completed" "100" "" ""
  selftest_assert_eq "$(ftctl_state_read_kv "${run_path}" run)" "${run}" "completed request run identity"
  selftest_assert_eq "$(ftctl_state_read_kv "${run_path}" state)" "READY" "completed request state"
  selftest_assert_eq "$(ftctl_state_read_kv "${run_path}" latest_completed_producer_run_uuid)" "${run}" \
    "completed request producer identity"
  selftest_assert_eq "$(ftctl_state_read_kv "${run_path}" latest_completed_requested_mode)" "FULL_RESEED" \
    "completed request mode"
  selftest_assert_eq "$(ftctl_state_read_kv "${run_path}" terminal_authoritative)" "true" \
    "completed request terminal authority"
  selftest_assert_file_contains "$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" terminal)" \
    "terminal_source=ENGINE_TERMINAL"
  ftctl_dr_scheduler_control_set "${plan}" "run" "next-incremental" "scheduler-next-run" "false" >/dev/null
  selftest_assert_contains "$(ftctl_dr_runtime_status "${plan}" "${run}" 0 20 1)" \
    '"control_request_run_uuid":"run-full-resync-request"' \
    "operation request owner survives the next incremental cycle"
}

selftest_case_dr_requested_cycle_terminal_repair_matrix() {
  selftest_reset_env
  selftest_info "FTCTL_DR repairs durable one-disk, two-disk, and Windows requested cycles"
  local variant plan run run_path output terminal_path sequence_path
  for variant in linux-one-disk linux-two-disk windows-two-disk; do
    plan="plan-terminal-repair-${variant}"
    run="run-terminal-repair-${variant}"
    ftctl_dr_runtime_ensure_plan_dirs "${plan}"
    run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
    terminal_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" terminal)"
    ftctl_state_write_kv_all "${run_path}" \
      "plan=${plan}" "run=${run}" "action=dr-sync-start" \
      "state=READY" "step=full-resync-completed" "progress=100" \
      "control_request_run_uuid=${run}" "requested_cycle_owner_run=${run}" \
      "requested_cycle_state=COMPLETED" "latest_completed_checkpoint_sequence=9" \
      "latest_completed_requested_mode=FULL_RESEED" "latest_completed_effective_mode=FULL_RESEED" \
      "latest_completed_cycle_token=${plan}:9" "data_commit_state=LOCAL_DURABLE" \
      "target_durable=true" "guest_family=$([[ "${variant}" == windows-* ]] && printf WINDOWS || printf LINUX)" \
      "target_disk_count=$([[ "${variant}" == *two-disk ]] && printf 2 || printf 1)"
    if [[ "${variant}" == "linux-two-disk" ]]; then
      ftctl_dr_runtime_path_set "${run_path}" "requested_cycle_state=PENDING"
      sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
      mkdir -p "$(dirname "${sequence_path}")"
      ftctl_state_write_kv_all "${sequence_path}" \
        "requested_cycle_owner_run=${run}" \
        "requested_cycle_sequence=9" \
        "requested_cycle_state=COMPLETED"
    fi
    output="$(ftctl_dr_runtime_status "${plan}" "${run}" 0 20 1)"
    selftest_assert_file_contains "${terminal_path}" "terminal_authoritative=true"
    selftest_assert_contains "${output}" '"terminal_source":"ENGINE_TERMINAL"' "${variant} terminal source"
    selftest_assert_contains "${output}" '"terminal_authoritative":true' "${variant} terminal authority"
  done

  plan="plan-terminal-repair-mismatch"
  run="run-terminal-repair-mismatch"
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  terminal_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" terminal)"
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  mkdir -p "$(dirname "${sequence_path}")"
  ftctl_state_write_kv_all "${run_path}" \
    "plan=${plan}" "run=${run}" "state=READY" "step=full-resync-completed" "progress=100" \
    "control_request_run_uuid=${run}" "requested_cycle_state=PENDING" \
    "latest_completed_checkpoint_sequence=9" "latest_completed_effective_mode=FULL_RESEED" \
    "latest_completed_cycle_token=${plan}:9" "data_commit_state=LOCAL_DURABLE" "target_durable=true"
  ftctl_state_write_kv_all "${sequence_path}" \
    "requested_cycle_owner_run=another-run" "requested_cycle_sequence=9" "requested_cycle_state=COMPLETED"
  ftctl_dr_runtime_status "${plan}" "${run}" 0 20 1 >/dev/null
  [[ ! -f "${terminal_path}" ]] || selftest_fail "mismatched scheduler owner must not repair terminal journal"
}

selftest_case_dr_requested_cycle_terminal_barrier_retries() (
  selftest_reset_env
  selftest_info "FTCTL_DR terminal publication is a required barrier before requested Cycle completion"
  local plan="plan-terminal-barrier" run="run-terminal-barrier" status_path sequence_path attempts=0
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  mkdir -p "$(dirname "${sequence_path}")"
  ftctl_state_write_kv_all "${status_path}" \
    "plan=${plan}" "run=${run}" "state=READY" "step=full-resync-completed" "progress=100" \
    "latest_completed_checkpoint_sequence=12" "latest_completed_requested_mode=FULL_RESEED" \
    "latest_completed_effective_mode=FULL_RESEED" "latest_completed_cycle_token=${plan}:12" \
    "data_commit_state=LOCAL_DURABLE" "target_durable=true"
  cp -f "${status_path}" "$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  ftctl_state_write_kv_all "${sequence_path}" \
    "requested_cycle_owner_run=${run}" "requested_cycle_sequence=12" "requested_cycle_state=RUNNING"
  ftctl_dr_scheduler_project_requested_cycle_run() {
    attempts=$((attempts + 1))
    [[ "${attempts}" -gt 1 ]] || return 1
    ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "barrier-test" "1" \
      "SUCCEEDED" "0" "" "$(ftctl_now_iso8601)"
    ftctl_dr_runtime_path_set "$(ftctl_dr_runtime_run_path "${plan}" "${run}")" \
      "terminal_authoritative=true" "terminal_publication_pending=false"
  }
  sleep() { :; }
  ftctl_dr_scheduler_publish_requested_cycle_terminal "${plan}" "${run}" "${status_path}" "${sequence_path}" 12
  selftest_assert_eq "$(ftctl_state_read_kv "${sequence_path}" requested_cycle_state)" "COMPLETED" \
    "requested Cycle completes only after terminal publication"
  selftest_assert_eq "$(ftctl_state_read_kv "${status_path}" terminal_publication_pending)" "false" \
    "terminal publication pending flag clears"
)

selftest_case_dr_transition_preflight_is_read_only() {
  selftest_reset_env
  selftest_info "FTCTL_DR transition preflight is typed and read-only"

  local plan="plan-transition-preflight"
  local status_path before_sha after_sha out rc=0
  local missing_plan="plan-transition-preflight-missing"
  local recovery_plan="plan-transition-preflight-reprotect-recovery"
  local recovery_status recovery_active recovery_authority recovery_sha
  local stderr_path="${SELFTEST_ROOT}/transition-preflight-missing.stderr"
  if ftctl_command_requires_lock "dr-transition-preflight" ""; then
    selftest_fail "DR transition preflight must not use the legacy global lock"
  fi
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  ftctl_dr_runtime_write_state "${status_path}" "${plan}" "" "dr-status" "FAILED_OVER" "cloud-promotion-committed" "100" "" ""
  ftctl_dr_runtime_path_set "${status_path}" "active_side=TARGET" "cloud_authority_generation=7" "target_power_state=POWERED_ON" "source_fence_state=ACKNOWLEDGED" "source_power_state=POWERED_OFF"
  before_sha="$(sha256sum "${status_path}" | awk '{print $1}')"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-transition-preflight --config "${SELFTEST_CONFIG}" --plan "${plan}" --operation failback --expected-authority TARGET --authority-generation 7 --json)"
  selftest_assert_contains "${out}" '"command":"dr-transition-preflight"' "transition preflight command"
  selftest_assert_contains "${out}" '"schema_version":2' "transition preflight schema"
  selftest_assert_contains "${out}" '"contract_version":"dr-transition-preflight-v2"' "transition preflight contract"
  selftest_assert_contains "${out}" '"status_scope":"TRANSITION_PREFLIGHT"' "transition preflight scope"
  selftest_assert_contains "${out}" '"ready":true' "transition preflight ready"
  selftest_assert_contains "${out}" '"authority_generation":7' "transition preflight generation"
  after_sha="$(sha256sum "${status_path}" | awk '{print $1}')"
  selftest_assert_eq "${after_sha}" "${before_sha}" "transition preflight does not mutate status"

  ftctl_dr_runtime_path_set "${status_path}" "target_power_state=POWER_ON_DELEGATED"
  before_sha="$(sha256sum "${status_path}" | awk '{print $1}')"
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-transition-preflight --config "${SELFTEST_CONFIG}" --plan "${plan}" --operation failback --expected-authority TARGET --authority-generation 7 --json)"
  selftest_assert_contains "${out}" '"ready":true' "delegated Cloud power ownership is transition-ready"
  selftest_assert_contains "${out}" '"target_power_state":"POWER_ON_DELEGATED"' "delegated power evidence is preserved"
  after_sha="$(sha256sum "${status_path}" | awk '{print $1}')"
  selftest_assert_eq "${after_sha}" "${before_sha}" "delegated transition preflight remains read-only"

  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-transition-preflight --config "${SELFTEST_CONFIG}" --plan "${plan}" --operation reprotect --expected-authority TARGET --authority-generation 8 --json 2>/dev/null)" || rc=$?
  selftest_assert_eq "${rc}" "79" "generation mismatch exit"
  selftest_assert_contains "${out}" '"error_code":"DR_TRANSITION_PREFLIGHT_GENERATION_MISMATCH"' "generation mismatch is typed"

  ftctl_dr_runtime_ensure_plan_dirs "${recovery_plan}"
  recovery_status="$(ftctl_dr_runtime_status_path "${recovery_plan}")"
  recovery_active="$(ftctl_dr_runtime_active_reprotect_session_path "${recovery_plan}")"
  recovery_authority="$(ftctl_dr_runtime_authority_spec_path "${recovery_plan}" "prior-reprotect")"
  ftctl_dr_runtime_write_state "${recovery_status}" "${recovery_plan}" "scheduler-owner" \
    "dr-scheduler-run" "READY" "target-checkpoint-ready" "100" "scheduler-owner" ""
  ftctl_dr_runtime_path_set "${recovery_status}" \
    "active_side=TARGET" "scheduler_state=RUNNING" "scheduler_health=HEALTHY" \
    "owner_matched=true" "protection_state=READY"
  cat > "${recovery_active}" <<EOF
{"planUuid":"${recovery_plan}","runUuid":"prior-reprotect","state":"READY","activeSide":"TARGET"}
EOF
  cat > "${recovery_authority}" <<EOF
{"expectedActiveSide":"TARGET","authorityGeneration":9,"targetPowerState":"POWERED_ON","sourceFenceState":"ACKNOWLEDGED","sourcePowerState":"POWERED_OFF"}
EOF
  recovery_sha="$(sha256sum "${recovery_status}" | awk '{print $1}')"
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-transition-preflight --config "${SELFTEST_CONFIG}" --plan "${recovery_plan}" --operation reprotect --expected-authority TARGET --authority-generation 9 --json)"
  selftest_assert_contains "${out}" '"ready":true' "reprotect authority snapshot recovers omitted scheduler projection"
  selftest_assert_contains "${out}" '"authority_generation":9' "recovered authority generation is reported"
  selftest_assert_contains "${out}" '"target_power_state":"POWERED_ON"' "recovered target power is reported"
  selftest_assert_eq "$(sha256sum "${recovery_status}" | awk '{print $1}')" "${recovery_sha}" \
    "authority recovery remains read-only"

  rc=0
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" dr-transition-preflight --config "${SELFTEST_CONFIG}" --plan "${missing_plan}" --operation failback --expected-authority TARGET --authority-generation 7 --json 2>"${stderr_path}")" || rc=$?
  selftest_assert_eq "${rc}" "79" "missing state exit"
  selftest_assert_eq "$(wc -l <<< "${out}" | tr -d ' ')" "1" "missing state emits one JSON object"
  selftest_assert_eq "$(cat "${stderr_path}")" "" "missing state emits no stderr noise"
  selftest_assert_contains "${out}" '"error_code":"DR_TRANSITION_PREFLIGHT_STATE_MISSING"' "missing state is typed"
}

selftest_case_dr_kvm_vmware_reverse_route_and_baseline_contract() {
  selftest_reset_env
  selftest_info "FTCTL_DR KVM to VMware uses the reverse writer and direction-scoped baseline"

  local plan="plan-kvm-vmware-reverse"
  local profile="${SELFTEST_ROOT}/kvm-vmware-profile.json"
  local map_path="${SELFTEST_ROOT}/kvm-vmware-map.json"
  local baseline_path
  local out
  cat > "${profile}" <<JSON
{
  "planUuid":"${plan}",
  "runUuid":"run-reverse",
  "direction":"KVM_TO_VMWARE",
  "source":{"provider":"ABLESTACK","externalRef":"target-vm","instanceName":"i-2-266-VM"},
  "target":{"provider":"VMWARE","externalRef":"vm-101"},
  "mapping":{"disks":[{
    "device":"sda",
    "sourcePath":"/dev/rbd/rbd/w22-01-dr-disk-0",
    "targetVmdkPath":"[datastore] w22-01/w22-01.vmdk",
    "sizeBytes":1048576
  }]}
}
JSON
  ftctl_dr_kvm_vmware_canonicalize_profile "${profile}" "${map_path}"
  selftest_assert_file_contains "${map_path}" '"providerPair":"ABLESTACK_TO_VMWARE"'
  selftest_assert_file_contains "${map_path}" '"sourcePool":"rbd"'
  selftest_assert_file_contains "${map_path}" '"sourceImage":"w22-01-dr-disk-0"'
  selftest_assert_file_contains "${map_path}" '"targetVmRef":"vm-101"'

  baseline_path="$(ftctl_dr_kvm_vmware_baseline_path "${plan}")"
  selftest_assert_eq "$(ftctl_dr_kvm_vmware_cycle_type "${plan}" incremental)" "FULL_REVERSE_SEED" "missing reverse baseline forces seed"
  selftest_assert_eq "$(ftctl_dr_kvm_vmware_cycle_type "${plan}" failback-final)" "FULL_REVERSE_SEED" "initial failback final uses a full reverse seed"
  selftest_assert_contains "$(ftctl_dr_kvm_vmware_mode_decision "${plan}" FAILBACK_FINAL AUTO)" $'MISSING_EXPECTED\tFULL_REVERSE_SEED\tINITIAL_REVERSE_BASELINE_MISSING\ttrue' "initial failback decision is explicit"
  mkdir -p "$(dirname "${baseline_path}")"
  cat > "${baseline_path}" <<JSON
{"state":"LOCAL_DURABLE","commonBaselineVerified":true,"generation":1,"disks":[{"diskIndex":0,"snapshot":"baseline-1"}]}
JSON
  selftest_assert_eq "$(ftctl_dr_kvm_vmware_cycle_type "${plan}" incremental)" "REVERSE_INCREMENTAL" "durable reverse baseline enables incremental"
  selftest_assert_eq "$(ftctl_dr_kvm_vmware_cycle_type "${plan}" failback-final)" "REVERSE_FINAL" "durable reverse baseline enables final delta"
  selftest_assert_contains "$(ftctl_dr_kvm_vmware_mode_decision "${plan}" FAILBACK_FINAL AUTO)" $'LOCAL_DURABLE\tREVERSE_FINAL\tDURABLE_BASELINE_FINAL_DELTA\tfalse' "durable failback decision is explicit"
  out="$({
    ftctl_dr_kvm_vmware_replication_cycle() { printf 'reverse-writer:%s:%s\n' "$1" "$5"; }
    ftctl_dr_vmware_replication_cycle() { printf 'wrong-forward-reader\n'; }
    ftctl_dr_scheduler_run_cycle "${plan}" run-reverse "${profile}" 2 reverse-incremental
  })"
  selftest_assert_contains "${out}" "reverse-writer:${plan}:reverse-incremental" "provider pair routes to reverse writer"
}

selftest_case_dr_kvm_vmware_failover_seeds_reverse_baseline() (
  selftest_reset_env
  selftest_info "FTCTL_DR cutover tracking does not assert a common reverse baseline"

  local plan="plan-cutover-baseline" run="run-cutover-baseline"
  local profile="${SELFTEST_ROOT}/cutover-baseline-profile.json"
  local baseline_path="" rbd_log="${SELFTEST_ROOT}/rbd-cutover-baseline.log"
  cat > "${profile}" <<JSON
{
  "planUuid":"${plan}",
  "runUuid":"${run}",
  "direction":"VMWARE_TO_KVM",
  "source":{"provider":"VMWARE","externalRef":"vm-101"},
  "target":{"provider":"ABLESTACK","externalRef":"target-vm","instanceName":"i-2-266-VM"},
  "mapping":{"disks":[{
    "device":"sda",
    "sizeBytes":1048576,
    "sourcePath":"[datastore] w22-01/w22-01.vmdk",
    "targetPath":"rbd/rbd/w22-01-dr-disk-0",
    "source":{"vmdkPath":"[datastore] w22-01/w22-01.vmdk"},
    "target":{"storagePath":"rbd","name":"w22-01-dr-disk-0"}
  }]}
}
JSON

  rbd() {
    printf '%s\n' "$*" >> "${rbd_log}"
    if [[ "${1-} ${2-}" == "snap ls" ]]; then
      printf '[]\n'
    fi
  }

  ftctl_dr_kvm_vmware_seed_cutover_baseline "${plan}" "${run}" "${profile}" 7
  baseline_path="$(ftctl_dr_kvm_vmware_baseline_path "${plan}")"
  selftest_assert_file_contains "${baseline_path}" '"origin":"FAILOVER_CUTOVER"'
  selftest_assert_file_contains "${baseline_path}" '"createdFromCheckpoint":7'
  selftest_assert_file_contains "${baseline_path}" '"state":"LOCAL_DURABLE"'
  selftest_assert_file_contains "${baseline_path}" '"snapshot":"ftctl-dr-plan-cut-cutover-7-run-cuto-0"'
  selftest_assert_file_contains "${rbd_log}" 'snap create rbd/w22-01-dr-disk-0@ftctl-dr-plan-cut-cutover-7-run-cuto-0'
  selftest_assert_contains "$(ftctl_dr_kvm_vmware_mode_decision "${plan}" FAILBACK_FINAL AUTO)" \
    $'LOCAL_DURABLE\tFULL_REVERSE_SEED\tINITIAL_REVERSE_COMMON_BASELINE_UNVERIFIED\ttrue' \
    "target-only cutover tracker requires initial full reconciliation"
)

selftest_case_dr_failback_resume_checkpoint_publishes_terminal_state() {
  selftest_reset_env
  selftest_info "FTCTL_DR post-failback checkpoint publishes one terminal state across runtime artifacts"

  local plan="plan-failback-terminal" run="run-failback-terminal"
  local plan_dir="${SELFTEST_ROOT}/run/dr-runtime/plans/${plan}"
  local run_path="${plan_dir}/runs/${run}.state"
  local status_path="${plan_dir}/status.state"
  local sequence_path="${plan_dir}/scheduler/sequence.state"
  local commit_path="${plan_dir}/failbacks/${run}.commit.state"
  local session_path="${plan_dir}/failbacks/${run}.json"
  local active_path="${plan_dir}/failbacks/active.json"
  mkdir -p "${plan_dir}/runs" "${plan_dir}/scheduler" "${plan_dir}/failbacks"
  ftctl_state_write_kv_all "${sequence_path}" \
    "minimum_completed_checkpoint_sequence=8" \
    "immediate_cycle_pending=false" \
    "immediate_cycle_owner_run=${run}"
  ftctl_state_write_kv_all "${run_path}" \
    "plan=${plan}" "run=${run}" "state=SYNCING" "step=protection-resuming" \
    "failback_session_id=${plan}:${run}" "active_side=SOURCE" \
    "engine_ack_state=ACKNOWLEDGED" "source_power_state=POWERED_ON" \
    "target_power_state=POWERED_OFF" "baseline_generation=8" \
    "baseline_state=LOCAL_DURABLE" "tracker_state=LOCAL_DURABLE" \
    "writer_state=DURABLE" "target_written=true" "write_verified=true" \
    "reverse_guest_compatibility_state=READY"
  cp -f "${run_path}" "${status_path}"
  ftctl_state_write_kv_all "${commit_path}" "phase=ACKNOWLEDGED" "outcome=ACKNOWLEDGED"
  printf '%s\n' \
    "{\"planUuid\":\"${plan}\",\"runUuid\":\"${run}\",\"sessionId\":\"${plan}:${run}\",\"state\":\"PROTECTION_RESUMING\",\"activeSide\":\"SOURCE\",\"sourcePowerState\":\"POWERED_ON\",\"targetPowerState\":\"POWERED_OFF\"}" \
    > "${session_path}"

  ftctl_dr_runtime_complete_failback_resume_checkpoint "${plan}" 8

  selftest_assert_file_contains "${run_path}" "state=READY"
  selftest_assert_file_contains "${run_path}" "failback_phase=COMPLETED"
  selftest_assert_file_contains "${run_path}" "terminal_authoritative=true"
  selftest_assert_file_contains "${status_path}" "step=target-checkpoint-ready"
  selftest_assert_file_contains "${commit_path}" "phase=COMPLETED"
  selftest_assert_file_contains "${session_path}" '"state":"COMPLETED"'
  selftest_assert_file_contains "${active_path}" '"postFailbackCheckpointSequence":8'

  local forward_run_path="${plan_dir}/runs/run-forward.state" output
  ftctl_state_write_kv_all "${forward_run_path}" \
    "plan=${plan}" "run=run-forward" "action=dr-sync-start" \
    "state=READY" "step=target-checkpoint-ready" "progress=100" \
    "latest_completed_checkpoint_sequence=9"
  ftctl_dr_runtime_publish_status "${forward_run_path}" "${status_path}"
  selftest_assert_file_contains "${status_path}" "active_side=SOURCE"
  selftest_assert_file_contains "${status_path}" "failback_phase=COMPLETED"
  selftest_assert_file_contains "${status_path}" "engine_ack_state=ACKNOWLEDGED"
  selftest_assert_file_contains "${status_path}" "post_failback_checkpoint_sequence=8"
  selftest_assert_file_contains "${status_path}" "reverse_evidence_run_uuid=${run}"
  output="$(ftctl_dr_runtime_emit_state_json "dr-status" "ok" "${plan}" "" "${status_path}" "0")"
  selftest_assert_contains "${output}" '"post_failback_checkpoint_sequence":8' "plan authority emits post-failback sequence"
  selftest_assert_contains "${output}" '"reverse_evidence_state":"COMPLETE"' "completed failback evidence remains complete"
  selftest_assert_contains "${output}" '"reverse_evidence_run_uuid":"run-failback-terminal"' "completed failback Run owns reverse evidence"

  # Reproduce the production race: a forward cycle publishes first and the
  # failback sidecar reaches COMPLETED immediately afterward. A plan-level
  # status read must reconstruct sticky authority without another write.
  cp -f "${forward_run_path}" "${status_path}"
  selftest_assert_file_not_contains "${status_path}" "failback_phase=COMPLETED"
  output="$(ftctl_dr_runtime_status "${plan}" "" "0" "20" "1")"
  selftest_assert_contains "${output}" '"failback_phase":"COMPLETED"' "status read restores failback phase"
  selftest_assert_contains "${output}" '"post_failback_checkpoint_sequence":8' "status read restores post-failback sequence"
  selftest_assert_contains "${output}" '"reverse_evidence_state":"COMPLETE"' "read repair restores complete reverse evidence"
  selftest_assert_contains "${output}" '"reverse_evidence_run_uuid":"run-failback-terminal"' "read repair restores failback evidence owner"
  selftest_assert_contains "${output}" '"reverse_evidence_missing_fields":[]' "read repair restores all reverse evidence fields"
  selftest_assert_file_contains "${status_path}" "active_side=SOURCE"
}

selftest_case_dr_failback_commit_pending_is_not_authoritative_terminal() {
  selftest_reset_env
  selftest_info "FTCTL_DR data-worker terminal does not terminalize a pending Failback commit"

  local plan="plan-failback-commit-pending" run="run-failback-commit-pending"
  local run_path output
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  ftctl_state_write_kv_all "${run_path}" \
    "plan=${plan}" "run=${run}" "action=dr-failback-commit" \
    "state=SYNCING" "step=commit-verifying" "progress=90" \
    "failback_phase=COMMIT_VERIFYING" "cloud_lifecycle_state=COMMIT_VERIFYING" \
    "failback_commit_outcome=UNKNOWN" "engine_ack_state=UNKNOWN" \
    "error_code=DR_FAILBACK_COMMIT_ACK_PENDING" "retryable=true"
  ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "nonce-pending" "1" \
    "SUCCEEDED" "0" "" "$(ftctl_now_iso8601)"

  output="$(ftctl_dr_runtime_emit_state_json "dr-failback-commit" "unknown" "${plan}" "${run}" "${run_path}" "0")"
  selftest_assert_contains "${output}" '"terminal_authoritative":false' "pending commit is not lifecycle terminal"
  selftest_assert_contains "${output}" '"terminal_source":"DATA_TERMINAL"' "worker terminal is data scoped"
  selftest_assert_contains "${output}" '"failback_phase":"COMMIT_VERIFYING"' "pending lifecycle phase is retained"
}

selftest_case_dr_kvm_vmware_reverses_forward_profile_roles() {
  selftest_reset_env
  selftest_info "FTCTL_DR derives the KVM to VMware route from a forward VMware to KVM profile"

  local profile="${SELFTEST_ROOT}/forward-vmware-kvm-profile.json"
  local reverse_profile="${SELFTEST_ROOT}/reverse-kvm-vmware-profile.json"
  local map_path="${SELFTEST_ROOT}/forward-vmware-kvm-map.json"
  cat > "${profile}" <<'JSON'
{
  "planUuid":"plan-forward-profile",
  "direction":"VMWARE_TO_KVM",
  "source":{"provider":"VMWARE","externalRef":"vm-6429","hardware":{"guestId":"windows2022srvNext_64Guest"}},
  "target":{"provider":"ABLESTACK","externalRef":"target-vm","instanceName":"i-2-266-VM"},
  "mapping":{"disks":[{
    "sizeBytes":1048576,
    "sourcePath":"[datastore] w22-01/w22-01.vmdk",
    "targetPath":"rbd/rbd/w22-01-dr-disk-0",
    "source":{"vmdkPath":"[datastore] w22-01/w22-01.vmdk"},
    "target":{"storagePath":"rbd","name":"w22-01-dr-disk-0"}
  }]}
}
JSON

  ftctl_dr_runtime_build_reverse_profile "plan-forward-profile" "run-reverse" \
    "${profile}" "${reverse_profile}" "failback"
  selftest_assert_file_contains "${reverse_profile}" '"direction":"KVM_TO_VMWARE"'
  selftest_assert_file_contains "${reverse_profile}" '"replicationDirection":"KVM_TO_VMWARE"'
  selftest_assert_file_contains "${reverse_profile}" '"providerPair":"ABLESTACK_TO_VMWARE"'
  selftest_assert_file_contains "${reverse_profile}" '"routeContractVersion":2'
  selftest_assert_file_contains "${reverse_profile}" '"state":"ORIGINAL_VMWARE_COMPATIBILITY_PRESERVED"'
  selftest_assert_file_contains "${reverse_profile}" '"bootValidationRequired":true'

  ftctl_dr_kvm_vmware_canonicalize_profile "${reverse_profile}" "${map_path}"
  selftest_assert_file_contains "${map_path}" '"direction":"KVM_TO_VMWARE"'
  selftest_assert_file_contains "${map_path}" '"sourceDomain":"i-2-266-VM"'
  selftest_assert_file_contains "${map_path}" '"sourcePool":"rbd"'
  selftest_assert_file_contains "${map_path}" '"sourceImage":"w22-01-dr-disk-0"'
  selftest_assert_file_contains "${map_path}" 'w22-01/w22-01.vmdk'
  selftest_assert_file_contains "${map_path}" '"targetVmRef":"vm-6429"'
}

selftest_case_dr_ablestack_reverse_profile_canonicalizes_rbd_and_workers() {
  selftest_reset_env
  selftest_info "FTCTL_DR canonicalizes the reverse ABLESTACK RBD route and swaps workers"

  local profile="${SELFTEST_ROOT}/forward-ablestack-profile.json"
  local reverse_profile="${SELFTEST_ROOT}/reverse-ablestack-profile.json"
  cat > "${profile}" <<'JSON'
{
  "planUuid":"plan-rbd-reverse",
  "direction":"KVM_TO_KVM",
  "source":{"provider":"ABLESTACK","instanceName":"i-2-332-VM"},
  "target":{"provider":"ABLESTACK","instanceName":"i-2-283-VM"},
  "workers":{"source":"source-host","target":"target-host","coordinator":"target-host"},
  "mapping":{"disks":[{
    "device":"sda","sizeBytes":1048576,
    "sourcePath":"rbd:rbd/source-image",
    "targetPath":"target-image",
    "targetStoragePath":"rbd","targetStorageType":"RBD",
    "source":{"path":"rbd:rbd/source-image","storagePoolType":"RBD","storagePath":"rbd"},
    "target":{"path":"target-image","storagePoolType":"RBD","storagePath":"rbd","format":"raw"}
  }]}
}
JSON

  ftctl_dr_runtime_build_reverse_profile "plan-rbd-reverse" "run-rbd-reverse" \
    "${profile}" "${reverse_profile}" "failback"
  selftest_assert_file_contains "${reverse_profile}" '"providerPair":"ABLESTACK_TO_ABLESTACK"'
  selftest_assert_file_contains "${reverse_profile}" '"state":"NATIVE_COMPATIBILITY_PRESERVED"'
  selftest_assert_file_contains "${reverse_profile}" '"sourcePath":"rbd:rbd/target-image"'
  selftest_assert_file_contains "${reverse_profile}" '"targetPath":"rbd:rbd/source-image"'
  selftest_assert_file_contains "${reverse_profile}" '"source":"target-host"'
  selftest_assert_file_contains "${reverse_profile}" '"target":"source-host"'
}

selftest_case_dr_kvm_vmware_initial_seed_accepts_missing_baseline() {
  selftest_reset_env
  selftest_info "FTCTL_DR initial KVM to VMware seed treats a missing baseline as expected"

  local baseline="${SELFTEST_ROOT}/missing-reverse-baseline.json"
  local invalid="${SELFTEST_ROOT}/invalid-reverse-baseline.json"
  local valid="${SELFTEST_ROOT}/valid-reverse-baseline.json"
  local out="" rc=0

  out="$( (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    ftctl_kvm_vmware_load_previous_snapshot "${baseline}" 0 FULL_REVERSE_SEED
  ) )" || rc=$?
  selftest_assert_eq "${rc}" "0" "missing reverse baseline is valid for full seed"
  selftest_assert_eq "${out}" "" "full seed has no previous snapshot"

  rc=0
  (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    ftctl_kvm_vmware_load_previous_snapshot "${baseline}" 0 REVERSE_INCREMENTAL
  ) >/dev/null 2>&1 || rc=$?
  selftest_assert_eq "${rc}" "83" "incremental reverse sync requires a baseline"

  printf '%s\n' '{"schemaVersion":1,"state":"BROKEN","direction":"KVM_TO_VMWARE","disks":[]}' > "${invalid}"
  rc=0
  (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    ftctl_kvm_vmware_load_previous_snapshot "${invalid}" 0 FULL_REVERSE_SEED
  ) >/dev/null 2>&1 || rc=$?
  selftest_assert_eq "${rc}" "84" "invalid reverse baseline is rejected"

  printf '%s\n' '{"schemaVersion":1,"state":"LOCAL_DURABLE","direction":"KVM_TO_VMWARE","disks":[{"diskIndex":0,"snapshot":"baseline-1"}]}' > "${valid}"
  out="$( (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    ftctl_kvm_vmware_load_previous_snapshot "${valid}" 0 REVERSE_INCREMENTAL
  ) )"
  selftest_assert_eq "${out}" "baseline-1" "incremental reverse sync loads the durable snapshot"
}

selftest_case_dr_kvm_vmware_run_scoped_snapshot_retry() {
  selftest_reset_env
  selftest_info "FTCTL_DR reverse snapshots are run scoped and interrupted attempts are idempotent"

  local call_log="${SELFTEST_ROOT}/reverse-run-snapshot.log"
  local first second rc=0
  first="$( (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    FTCTL_DR_PLAN_UUID="plan-12345678"
    FTCTL_DR_CHECKPOINT_SEQUENCE="1859"
    FTCTL_DR_RUN_UUID="run-alpha-123456"
    ftctl_kvm_vmware_run_snapshot_name 0
  ) )"
  second="$( (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    FTCTL_DR_PLAN_UUID="plan-12345678"
    FTCTL_DR_CHECKPOINT_SEQUENCE="1859"
    FTCTL_DR_RUN_UUID="run-beta-123456"
    ftctl_kvm_vmware_run_snapshot_name 0
  ) )"
  selftest_assert_not_eq "${first}" "${second}" "different Runs do not collide at the same checkpoint"
  selftest_assert_contains "${first}" "run-alpha-12" "snapshot name contains the Run owner token"

  (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    rbd() {
      printf '%s\n' "$*" >> "${call_log}"
      return 0
    }
    ftctl_kvm_vmware_prepare_run_snapshot "rbd" "vm-disk" "baseline-snapshot" "${first}"
  )
  selftest_assert_file_contains "${call_log}" "snap info rbd/vm-disk@${first}"
  selftest_assert_file_contains "${call_log}" "snap rm rbd/vm-disk@${first}"
  selftest_assert_file_contains "${call_log}" "snap create rbd/vm-disk@${first}"

  rc=0
  (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    rbd() { return 0; }
    ftctl_kvm_vmware_prepare_run_snapshot "rbd" "vm-disk" "${first}" "${first}"
  ) >/dev/null 2>&1 || rc=$?
  selftest_assert_eq "${rc}" "87" "a durable baseline snapshot is never removed as retry residue"
}

selftest_case_dr_kvm_vmware_reverse_preflight_clears_return_trap() {
  selftest_reset_env
  selftest_info "FTCTL_DR reverse preflight clears its RETURN trap after temporary map cleanup"

  local profile="${SELFTEST_ROOT}/reverse-preflight-profile.json"
  local stderr_file="${SELFTEST_ROOT}/reverse-preflight.stderr"
  local out="" rc=0
  printf '%s\n' '{}' > "${profile}"

  out="$( (
    ftctl_dr_kvm_vmware_canonicalize_profile() {
      printf '%s\n' '{"sourceDomain":"i-2-266-VM","disks":[{"sourcePool":"rbd","sourceImage":"image","virtualBytes":1024}]}' > "${2}"
    }
    ftctl_dr_kvm_vmware_mode_decision() {
      printf 'MISSING_EXPECTED\tFULL_REVERSE_SEED\tINITIAL_REVERSE_BASELINE_MISSING\ttrue\n'
    }
    ftctl_dr_kvm_vmware_refresh_target_backings() { return 0; }
    rbd() { return 0; }
    virsh() { selftest_fail "reverse preflight must not probe source domain runtime"; }
    command() { return 0; }

    ftctl_dr_kvm_vmware_reverse_preflight plan-trap "${profile}" FAILBACK_FINAL AUTO 1
    printf 'caller-returned\n'
  ) 2>"${stderr_file}" )" || rc=$?

  selftest_assert_eq "${rc}" "0" "reverse preflight caller returns successfully under set -u"
  selftest_assert_contains "${out}" '"effective_mode":"FULL_REVERSE_SEED"' "reverse preflight emits the selected mode"
  selftest_assert_contains "${out}" '"source_domain_probe_state":"NOT_REQUIRED"' "reverse preflight ignores KVM domain runtime"
  selftest_assert_contains "${out}" '"status_evidence_contract_version":1' "reverse preflight advertises evidence contract"
  selftest_assert_contains "${out}" '"status_evidence_publication_ready":true' "reverse preflight proves evidence publication support"
  selftest_assert_contains "${out}" "caller-returned" "RETURN trap does not escape into its caller"
  selftest_assert_eq "$(cat "${stderr_file}")" "" "reverse preflight emits no cleanup error"
}

selftest_case_dr_kvm_vmware_snapshot_attach_is_read_only() {
  selftest_reset_env
  selftest_info "FTCTL_DR reverse source snapshot is attached read-only"

  local call_log="${SELFTEST_ROOT}/reverse-source-attach.log"
  (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    qemu-nbd() {
      printf '%s\n' "$*" > "${call_log}"
    }
    ftctl_kvm_vmware_attach_source_snapshot "/dev/nbd15" \
      "rbd:rbd/w22-01-dr-disk-0@snapshot-1"
  )

  selftest_assert_file_contains "${call_log}" "--read-only"
  selftest_assert_file_contains "${call_log}" "--cache=none"
  selftest_assert_file_contains "${call_log}" "--connect=/dev/nbd15"
  selftest_assert_file_contains "${call_log}" "rbd:rbd/w22-01-dr-disk-0@snapshot-1"
  selftest_assert_contains "$(ftctl_dr_runtime_capabilities 1)" \
    '"dr-reverse-rbd-snapshot-readonly-v1"' "read-only reverse capability is advertised"
  selftest_assert_contains "$(ftctl_dr_runtime_capabilities 1)" \
    '"dr-reverse-evidence-publication-v1"' "reverse evidence publication capability is advertised"
  selftest_assert_contains "$(ftctl_dr_runtime_capabilities 1)" \
    '"dr-terminal-causality-v1"' "terminal causality capability is advertised"
}

selftest_case_dr_failback_terminal_publication_grace() {
  selftest_reset_env
  selftest_info "FTCTL_DR failback waits for authoritative terminal publication"

  local state_path="${SELFTEST_ROOT}/failback-terminal-grace.state"
  local output=""
  ftctl_state_write_kv_all "${state_path}" \
    "action=dr-failback" \
    "state=RUNNING" \
    "step=reverse-transfer" \
    "progress=80" \
    "failback_phase=REVERSE_SYNCING" \
    "worker_state=RUNNING" \
    "worker_pid=999999" \
    "worker_pid_alive=true"

  output="$(FTCTL_DR_TERMINAL_PUBLICATION_GRACE_SECONDS=10 \
    ftctl_dr_runtime_emit_state_json "dr-failback" "ok" \
      "plan-terminal-grace" "run-terminal-grace" "${state_path}" "0")"
  selftest_assert_contains "${output}" '"state":"RUNNING"' "dead worker remains non-terminal during grace"
  selftest_assert_contains "${output}" '"worker_state":"TERMINAL_PENDING"' "terminal publication is explicit"
  selftest_assert_contains "${output}" '"terminal_publication_pending":true' "pending provenance is emitted"
  selftest_assert_not_contains "${output}" '"DR_FAILBACK_WORKER_EXITED"' "legacy synthetic failure is suppressed"

  ftctl_dr_runtime_path_set "${state_path}" \
    "terminal_publication_pending=true" \
    "terminal_publication_pending_since=1970-01-01T00:00:00+0000"
  output="$(FTCTL_DR_TERMINAL_PUBLICATION_GRACE_SECONDS=1 \
    ftctl_dr_runtime_emit_state_json "dr-failback" "ok" \
      "plan-terminal-grace" "run-terminal-grace" "${state_path}" "0")"
  selftest_assert_contains "${output}" '"state":"RUNNING"' "status observation never terminalizes the Run"
  selftest_assert_contains "${output}" '"worker_liveness_state":"DEAD_CONFIRMED"' "dead worker is typed for backend reconciliation"
  selftest_assert_contains "${output}" '"reconciliation_required":true' "dead worker requires reconciliation"
  selftest_assert_not_contains "${output}" '"terminal_source":"WATCHDOG_DERIVED"' "status does not synthesize terminal provenance"
}

selftest_case_dr_failback_live_worker_journal_is_read_only() (
  selftest_reset_env
  selftest_info "FTCTL_DR live Failback journal survives conflicting legacy identity and status reads"

  local plan="plan-live-worker" run="run-live-worker" run_path worker_path progress_path before after output pid ticks
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  worker_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" worker)"
  progress_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" progress)"
  sleep 30 &
  pid="$!"
  ticks="$(ftctl_dr_scheduler_process_start_ticks "${pid}")"
  ftctl_state_write_kv_all "${run_path}" \
    "action=dr-failback" "state=RUNNING" "step=failback-transfer" "progress=55" \
    "failback_phase=REVERSE_SYNCING" "worker_state=RUNNING" "checkpoint_sequence=185" \
    "worker_pid=${pid}" "worker_start_ticks=$((ticks + 1))" "worker_pid_alive=true" \
    "transfer_progress_path=${progress_path}"
  ftctl_dr_runtime_worker_journal_write "${plan}" "${run}" "nonce-live" "7" \
    "${pid}" "${ticks}" "RUNNING" "$(ftctl_now_iso8601)"
  printf '{"schemaVersion":2,"planUuid":"%s","runUuid":"%s","direction":"KVM_TO_VMWARE","cycleSequence":185,"state":"COPYING","transferPayloadBytes":1048576,"updatedAtEpochMs":%s}\n' \
    "${plan}" "${run}" "$(( $(date +%s) * 1000 ))" > "${progress_path}"
  before="$(sha256sum "${run_path}" "${worker_path}")"
  output="$(ftctl_dr_runtime_emit_state_json "dr-failback" "ok" "${plan}" "${run}" "${run_path}" "0")"
  after="$(sha256sum "${run_path}" "${worker_path}")"
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true

  selftest_assert_eq "${after}" "${before}" "status read does not mutate Run or worker journals"
  selftest_assert_contains "${output}" '"worker_identity_state":"MATCHED"' "worker-owned identity overrides conflicting legacy state"
  selftest_assert_contains "${output}" '"worker_liveness_state":"ALIVE"' "live worker remains non-terminal"
  selftest_assert_contains "${output}" '"transfer_activity_state":"COPYING"' "live transfer activity is projected"
  selftest_assert_contains "${output}" '"transfer_payload_bytes":1048576' "live payload bytes are projected"
  selftest_assert_contains "${output}" '"terminal_authoritative":false' "live transfer has no terminal"
  selftest_assert_contains "${output}" "\"transfer_run_uuid\":\"${run}\"" "progress is bound to operation"
  jq '.runUuid = "previous-run" | .state = "COMPLETE" | .percent = 100' "${progress_path}" > "${progress_path}.tmp"
  mv "${progress_path}.tmp" "${progress_path}"
  output="$(ftctl_dr_runtime_emit_state_json "dr-failback" "ok" "${plan}" "${run}" "${run_path}" "0")"
  selftest_assert_contains "${output}" '"transfer_activity_state":"UNKNOWN"' "old completed Run is not current transfer"
  selftest_assert_contains "${output}" '"transfer_payload_bytes":0' "old completed bytes are not reused"
  jq --arg run "${run}" '.runUuid = $run | .cycleSequence = 184' "${progress_path}" > "${progress_path}.tmp"
  mv "${progress_path}.tmp" "${progress_path}"
  output="$(ftctl_dr_runtime_emit_state_json "dr-failback" "ok" "${plan}" "${run}" "${run_path}" "0")"
  selftest_assert_contains "${output}" '"transfer_activity_state":"UNKNOWN"' "older checkpoint of the same Run is not current transfer"
)

selftest_case_dr_kvm_vmware_reverse_preflight_ignores_domain_runtime() {
  selftest_reset_env
  selftest_info "FTCTL_DR reverse preflight uses storage evidence without a live KVM domain"

  local profile="${SELFTEST_ROOT}/reverse-live-domain-profile.json"
  local out="" rc=0
  printf '%s\n' '{}' > "${profile}"

  out="$( (
    ftctl_dr_kvm_vmware_canonicalize_profile() {
      printf '%s\n' '{"sourceDomain":"i-2-266-VM","disks":[{"sourcePool":"rbd","sourceImage":"image","targetVmdkPath":"[ds] vm/disk.vmdk","targetVmRef":"vm-1","virtualBytes":1024}]}' > "${2}"
    }
    ftctl_dr_kvm_vmware_mode_decision() {
      printf 'MISSING_EXPECTED\tFULL_REVERSE_SEED\tINITIAL_REVERSE_BASELINE_MISSING\ttrue\n'
    }
    ftctl_dr_kvm_vmware_refresh_target_backings() { return 0; }
    virsh() { return 1; }
    rbd() { return 0; }
    command() { return 0; }
    ftctl_dr_kvm_vmware_reverse_preflight plan-domain-missing "${profile}" FAILBACK_FINAL AUTO 1
  ) 2>/dev/null)" || rc=$?
  selftest_assert_eq "${rc}" "0" "missing KVM source domain does not block storage-based reverse preflight"
  selftest_assert_contains "${out}" '"source_domain_probe_state":"NOT_REQUIRED"' "domain runtime is not a preflight prerequisite"
  selftest_assert_contains "${out}" '"source_disk_probe_state":"READY"' "RBD storage evidence remains authoritative"

  rc=0
  out="$( (
    ftctl_dr_kvm_vmware_canonicalize_profile() {
      printf '%s\n' '{"sourceDomain":"i-2-266-VM","disks":[{"sourcePool":"rbd","sourceImage":"image","targetVmdkPath":"[ds] vm/disk.vmdk","targetVmRef":"vm-1","virtualBytes":1024}]}' > "${2}"
    }
    ftctl_dr_kvm_vmware_mode_decision() {
      printf 'MISSING_EXPECTED\tFULL_REVERSE_SEED\tINITIAL_REVERSE_BASELINE_MISSING\ttrue\n'
    }
    ftctl_dr_kvm_vmware_refresh_target_backings() { return 0; }
    virsh() {
      case "${1-}" in
        dominfo) return 0 ;;
        domstate) printf 'shut off\n'; return 0 ;;
      esac
      return 1
    }
    rbd() { return 0; }
    command() { return 0; }
    ftctl_dr_kvm_vmware_reverse_preflight plan-domain-stopped "${profile}" FAILBACK_FINAL AUTO 1
  ) 2>/dev/null)" || rc=$?
  selftest_assert_eq "${rc}" "0" "stopped KVM source domain does not block storage-based reverse preflight"
  selftest_assert_contains "${out}" '"source_domain_probe_state":"NOT_REQUIRED"' "stopped domain is outside the data-path contract"
  selftest_assert_contains "${out}" '"source_disk_probe_state":"READY"' "RBD storage evidence remains authoritative"
}

selftest_case_dr_kvm_vmware_canonicalizes_cloud_rbd_volume_identity() {
  local tmp profile output credentials password_file
  tmp="$(mktemp -d)"
  profile="${tmp}/reverse-profile.json"
  output="${tmp}/disk-map.json"
  credentials="${tmp}/credentials.json"
  password_file="${tmp}/vcenter.password"
  cat > "${profile}" <<'JSON'
{"planUuid":"plan-rbd","runUuid":"run-rbd","direction":"KVM_TO_VMWARE","source":{"provider":"ABLESTACK","instanceName":"i-2-266-VM"},"target":{"provider":"VMWARE","externalRef":"vm-6429"},"mapping":{"disks":[{"sizeBytes":"107374182400","sourcePath":"w22-01-dr-disk-0","targetVmdkPath":"[datastore] w22-01/w22-01.vmdk","source":{"storagePath":"rbd","volumeUuid":"7e74a011-47dc-4de5-acd3-a7af6aeaf9f6","name":"w22-01-dr-disk-0"}}]}}
JSON
  ftctl_dr_kvm_vmware_canonicalize_profile "${profile}" "${output}"
  jq -e '.direction == "KVM_TO_VMWARE"
    and .disks[0].sourcePool == "rbd"
    and .disks[0].sourceImage == "w22-01-dr-disk-0"
    and .disks[0].sourceVolumeUuid == "7e74a011-47dc-4de5-acd3-a7af6aeaf9f6"
    and .disks[0].sourceUri == "rbd:rbd/w22-01-dr-disk-0"
    and .disks[0].targetVmRef == "vm-6429"' "${output}" >/dev/null
  cat > "${credentials}" <<'JSON'
{"credentials":{"source":{"type":"VCENTER","endpoint":"10.10.21.10","principal":"administrator@example.local","auth":{"password":"vcenter-password"}},"target":{"type":"MOLD_API","endpoint":"http://10.10.32.10:8080/client/api","auth":{"password":"wrong-password"}}}}
JSON
  (
    # shellcheck source=/dev/null
    source "${LIB_BASE}/ftctl/dr_kvm_vmware_mover.sh"
    FTCTL_DR_CREDENTIALS_FILE="${credentials}"
    ftctl_kvm_vmware_write_password_file "${password_file}"
  )
  selftest_assert_file_contains "${password_file}" 'vcenter-password'
  rm -rf "${tmp}"
}

selftest_case_dr_kvm_vmware_dispatches_shared_qcow2_reverse_baseline() {
  selftest_reset_env
  selftest_info "FTCTL_DR VMware to SharedMountPoint cutover uses a qcow2 bitmap baseline"

  local profile="${SELFTEST_ROOT}/vmware-file-profile.json"
  local output="${SELFTEST_ROOT}/vmware-file-map.json"
  local call_log="${SELFTEST_ROOT}/vmware-file-baseline.log"
  cat > "${profile}" <<'JSON'
{"planUuid":"plan-file","runUuid":"run-file","direction":"VMWARE_TO_KVM","source":{"provider":"VMWARE","externalRef":"vm-60975"},"target":{"provider":"ABLESTACK","instanceName":"i-2-234-VM","storagePath":"/mnt/glue-gfs","storagePoolType":"SharedMountPoint"},"mapping":{"disks":[{"device":"2000","sizeBytes":107374182400,"sourcePath":"[ds] vm/vm.vmdk","targetPath":"disk-uuid","source":{"path":"[ds] vm/vm.vmdk"},"target":{"path":"disk-uuid","format":"qcow2","type":"file","storagePath":"/mnt/glue-gfs","storagePoolType":"SharedMountPoint"}}]}}
JSON
  ftctl_dr_kvm_vmware_canonicalize_profile "${profile}" "${output}"
  jq -e '.sourceDomain == "i-2-234-VM"
    and .disks[0].sourceType == "file"
    and .disks[0].sourceFormat == "qcow2"
    and .disks[0].sourcePath == "/mnt/glue-gfs/disk-uuid"
    and .disks[0].targetVmdkPath == "[ds] vm/vm.vmdk"' "${output}" >/dev/null

  (
    ftctl_dr_kvm_vmware_seed_qcow2_cutover_baseline() {
      printf '%s\n' "$*" > "${call_log}"
    }
    rbd() { selftest_fail "SharedMountPoint baseline must not invoke rbd"; }
    ftctl_dr_kvm_vmware_seed_cutover_baseline \
      plan-file run-file "${profile}" 41
  )
  selftest_assert_file_contains "${call_log}" "plan-file run-file"
  selftest_assert_file_contains "${call_log}" "41"
}

selftest_case_dr_kvm_vmware_refreshes_stale_target_backing() {
  selftest_reset_env
  selftest_info "FTCTL_DR resolves the current VMware backing by stable device key before reverse writes"

  local tmp profile map_path credentials compat govc_bin rc=0
  tmp="$(mktemp -d)"
  profile="${tmp}/reverse-profile.json"
  map_path="${tmp}/disk-map.json"
  credentials="${tmp}/credentials.json"
  compat="${tmp}/compat/vsphere80"
  govc_bin="${compat}/bin/govc"
  mkdir -p "${compat}/bin" "${compat}/vddk"
  cat > "${profile}" <<'JSON'
{"direction":"VMWARE_TO_KVM","source":{"provider":"VMWARE","externalRef":"vm-5027"},"target":{"provider":"ABLESTACK","externalRef":"kvm-target-uuid"}}
JSON
  cat > "${map_path}" <<'JSON'
{"targetVmRef":"vm-5027","disks":[{"device":"2000","targetDiskKey":"2000","targetVmdkPath":"[ds] utest1/utest1-000004.vmdk","targetVmRef":"vm-5027","virtualBytes":107374182400}]}
JSON
  cat > "${credentials}" <<JSON
{"credentials":{"source":{"type":"VCENTER","endpoint":"10.10.21.10","principal":"administrator@example.local","tlsVerify":false,"vddkLibdir":"${compat}/vddk","auth":{"password":"secret"}}}}
JSON
  cat > "${govc_bin}" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"virtualMachines":[{"config":{"hardware":{"device":[{"key":2000,"capacityInBytes":107374182400,"deviceInfo":{"label":"Hard disk 1"},"backing":{"fileName":"[ds] utest1/utest1.vmdk"}}]}}}]}
JSON
SH
  chmod +x "${govc_bin}"

  ftctl_dr_kvm_vmware_refresh_target_backings "${profile}" "${map_path}" "${credentials}" || rc=$?
  selftest_assert_eq "${rc}" "0" "current VMware backing resolution succeeds"
  jq -e '.disks[0].targetVmdkPath == "[ds] utest1/utest1.vmdk"
    and .disks[0].targetBackingResolution == "vcenter-current-device-graph"' "${map_path}" >/dev/null \
    || selftest_fail "current VMware backing was not persisted"

  jq '.disks[0].targetDiskKey="2999" | .disks[0].targetVmdkPath="[ds] stale/missing.vmdk"' \
    "${map_path}" > "${map_path}.tmp" && mv -f "${map_path}.tmp" "${map_path}"
  rc=0
  ftctl_dr_kvm_vmware_refresh_target_backings "${profile}" "${map_path}" "${credentials}" >/dev/null 2>&1 || rc=$?
  selftest_assert_eq "${rc}" "90" "unresolved VMware backing blocks the reverse writer"
  rm -rf "${tmp}"
}

selftest_main() {
  selftest_run_lint
  selftest_case_cluster_cli
  selftest_case_blockcopy_and_standby
  selftest_case_libvirt_managed_peer_krbd_map
  selftest_case_standby_activate_already_exists
  selftest_case_standby_deactivate_uses_generated_domain_name
  selftest_case_backend_validation
  selftest_case_dr_remote_key_connectivity_args
  selftest_case_blockcopy_missing_job_state
  selftest_case_blockcopy_progress_status
  selftest_case_shared_xml_reuse_external
  selftest_case_blockcopy_target_empty_verify
  selftest_case_blockcopy_verify_blocks_mirroring
  selftest_case_reconcile_and_fencing
  selftest_case_failover_blocks_copying_transport
  selftest_case_xcolo_and_xml
  selftest_case_xcolo_iothread_contract_validation
  selftest_case_xcolo_block_xml_preserves_disk_targets
  selftest_case_xcolo_file_qcow2_uses_cold_conversion_detection
  selftest_case_inventory_disk_format_uses_force_share
  selftest_case_xcolo_file_qcow2_empty_format_avoids_prebuilt_fallback
  selftest_case_xcolo_prebuilt_backup_uses_secondary_vm_name
  selftest_case_xcolo_cloud_managed_rbd_metadata_inference
  selftest_case_xcolo_primary_create_maps_rbd_sources
  selftest_case_xcolo_runtime_disk_device_replace_is_forbidden
  selftest_case_xcolo_block_handshake_sets_checkpoint_before_migrate
  selftest_case_xcolo_multi_disk_handshake_exports_all_disks
  selftest_case_xcolo_staged_filter_activation_classifies_failed_step
  selftest_case_xcolo_fast_redire1_gate_allows_secondary_active
  selftest_case_xcolo_primary_filter_binding_defers_to_runtime_validation
  selftest_case_xcolo_premigrate_chardev_binding_accepts_listener_endpoints
  selftest_case_xcolo_strict_chardev_binding_rejects_closed_frontends
  selftest_case_xcolo_virtio_vnet_hdr_support
  selftest_case_xcolo_storage_mismatch_gate
  selftest_case_xcolo_storage_qcow2_to_librbd_allowed
  selftest_case_xcolo_machine_contract_gate
  selftest_case_xcolo_filter_qom_hard_gate
  selftest_case_xcolo_primary_filter_qmp_order_matches_qemu_doc
  selftest_case_xcolo_primary_netdev_vhost_guard
  selftest_case_xcolo_startup_disk_graph_uses_native_rbd_backend_by_default
  selftest_case_xcolo_startup_disk_graph_allows_explicit_krbd_backend
  selftest_case_xcolo_startup_disk_graph_allows_explicit_librbd_backend
  selftest_case_xcolo_baseline_seed_uses_primary_nbd_before_runtime_graph
  selftest_case_xcolo_libvirt_qemu_identity_avoids_local_name_collision
  selftest_case_xcolo_primary_parent_nbd_qemu_user_probe
  selftest_case_xcolo_baseline_seed_maps_cloud_managed_rbd
  selftest_case_xcolo_secondary_runtime_maps_cloud_managed_rbd
  selftest_case_xcolo_stable_rbd_contract_remaps_cloud_paths
  selftest_case_xcolo_librbd_contract_does_not_map_primary_krbd
  selftest_case_xcolo_baseline_seed_retries_ssh_transport_failure
  selftest_case_xcolo_runtime_validation_blocks_false_positive
  selftest_case_xcolo_runtime_validation_reports_primary_migrate_failure
  selftest_case_xcolo_runtime_validation_classifies_repeated_invalid_message
  selftest_case_xcolo_startup_active_failure_classifies_filter_mirror_eperm
  selftest_case_xcolo_chardev_contract_reports_closed_edges
  selftest_case_xcolo_pre_guest_gate_warns_closed_chardev_contract
  selftest_case_xcolo_runtime_validation_reports_pending_convergence
  selftest_case_xcolo_runtime_validation_times_out_stuck_convergence
  selftest_case_xcolo_runtime_validation_reports_one_sided_colo_role
  selftest_case_xcolo_runtime_validation_refines_missing_primary_colo_capability
  selftest_case_xcolo_runtime_validation_refines_primary_chardev_binding
  selftest_case_xcolo_runtime_validation_reports_compare_channel_failure
  selftest_case_xcolo_runtime_validation_accepts_reported_colo_role
  selftest_case_xcolo_runtime_validation_records_optional_qga
  selftest_case_xcolo_runtime_validation_requires_primary_qga
  selftest_case_xcolo_runtime_reconcile_marks_steady_after_guest_health_recovers
  selftest_case_xcolo_runtime_recovery_preserves_error_reason
  selftest_case_xcolo_block_handshake_failure_recovers_runtime
  selftest_case_xcolo_error_status_uses_sticky_runtime_error
  selftest_case_json_and_locking
  selftest_case_check_secondary_active_side
  selftest_case_reconcile_secondary_steady_skips_primary_disks
  selftest_case_reconcile_cloud_managed_reports_failover_candidate
  selftest_case_reconcile_defers_manual_fence_pending
  selftest_case_global_reconcile_skips_missing_profile_state
  selftest_case_unprotect_releases_blockcopy_targets
  selftest_case_unprotect_releases_remote_nbd_exports
  selftest_case_unprotect_fails_when_remote_nbd_release_fails
  selftest_case_unprotect_force_cleanup_warns_when_remote_nbd_release_fails
  selftest_case_failback_reverse_finalize
  selftest_case_failback_reverse_finalize_uses_rbd_uri_source
  selftest_case_failback_shared_reverse_finalize
  selftest_case_dr_remote_failback_maps_reverse_rbd_on_primary
  selftest_case_dr_remote_reverse_plan_stores_rbd_uri_source
  selftest_case_dr_remote_primary_nbd_prepare_maps_unmapped_rbd
  selftest_case_failback_reverse_progress_ready
  selftest_case_failback_sync_idempotent_when_reverse_ready
  selftest_case_failback_sync_recovers_failed_ready_progress
  selftest_case_reconcile_preserves_cloud_failback_failure
  selftest_case_reconcile_waits_for_cloud_failback_after_fence_clear
  selftest_case_reconcile_waits_for_cloud_dr_failback_after_fence_clear
  selftest_case_failback_reprotect_clears_standby_verify_state
  selftest_case_xcolo_mtree_zero_alias_fails_before_migrate
  selftest_case_xcolo_mtree_zero_alias_fails_after_migrate
  selftest_case_xcolo_live_pci_incoming_fails_before_migrate
  selftest_case_xcolo_live_pci_incoming_fails_after_migrate
  selftest_case_xcolo_post_migrate_secondary_crash_fails_fast
  selftest_case_xcolo_generated_pci_manifest_pair_ok
  selftest_case_xcolo_generated_pci_manifest_pair_mismatch
  selftest_case_xcolo_materialization_pipeline_reports_argv_missing
  selftest_case_xcolo_materialization_pipeline_reports_pci_unassigned
  selftest_case_xcolo_materialization_pipeline_allows_scsi_bus_child_without_pci_endpoint
  selftest_case_xcolo_primary_restore_detects_generated_graph
  selftest_case_xcolo_primary_internal_retry_enabled_by_default
  selftest_case_xcolo_channel_timeout_records_failure_reason
  selftest_case_xcolo_primary_restore_ignores_domain_missing_destroy
  selftest_case_xcolo_primary_restore_continues_when_destroy_rc_and_domain_absent
  selftest_case_xcolo_primary_disk_args_precede_listener_chardevs
  selftest_case_xcolo_primary_listener_rejects_partial_compare_bootstrap
  selftest_case_xcolo_primary_listener_refreshes_krbd_paths
  selftest_case_xcolo_primary_peer_wait_refreshes_krbd_paths
  selftest_case_cloud_managed_rollback_cleanup_does_not_restart_secondary
  selftest_case_dr_runtime_profile_status_cancel
  selftest_case_dr_target_materialization_manifest_v2
  selftest_case_dr_runtime_control_actions
  selftest_case_dr_plan_scoped_control_protocol
  selftest_case_dr_ablestack_target_prepare
  selftest_case_dr_ablestack_rbd_target_prepare_preserves_empty_source_format
  selftest_case_dr_ablestack_full_seed_once
  selftest_case_dr_ablestack_missing_disk_map_waits
  selftest_case_dr_ablestack_vmware_source_size_unresolved
  selftest_case_dr_vmware_preflight_missing_vddk
  selftest_case_dr_vmware_contract_ready
  selftest_case_dr_vmware_cbt_preflight_uses_runtime_credentials_file
  selftest_case_dr_vmware_cbt_activation_evidence_promotes_active
  selftest_case_dr_vmware_cbt_full_seed_verifies_current_change_id
  selftest_case_dr_vmware_missing_disk_map_config_incomplete
  selftest_case_dr_vmware_missing_vddk_blocks_sync
  selftest_case_dr_scheduler_ablestack_checkpoint_loop
  selftest_case_dr_scheduler_vmware_mock_checkpoint_loop
  selftest_case_dr_guestprep_manifest_preserves_vmware_boot_contract
  selftest_case_dr_cutover_manifest_v2_normalizes_runtime_disk_map
  selftest_case_dr_runtime_test_failover_cleanup
  selftest_case_dr_runtime_shared_file_artifact_cleanup
  selftest_case_dr_scheduler_resume_recovers_missing_worker
  selftest_case_dr_scheduler_systemd_launch_contract
  selftest_case_dr_vmware_canonical_profile_preserves_committed_baseline
  selftest_case_dr_full_resync_request_is_one_shot
  selftest_case_dr_requested_cycle_terminal_repair_matrix
  selftest_case_dr_requested_cycle_terminal_barrier_retries
  selftest_case_dr_runtime_planned_failover_promotes_latest_checkpoint
  selftest_case_dr_runtime_cloud_cutover_commit_is_idempotent
  selftest_case_dr_runtime_cloud_cutover_commit_v2_is_durable
  selftest_case_dr_runtime_status_hydrates_complete_cycle_evidence
  selftest_case_dr_runtime_failover_abort_resumes_source_protection
  selftest_case_dr_scheduler_resume_accepts_live_worker_pending_ack
  selftest_case_dr_runtime_failback_restores_source_after_reverse_checkpoint
  selftest_case_dr_transition_preflight_is_read_only
  selftest_case_dr_scheduler_wait_is_interrupted_by_new_generation
  selftest_case_dr_runtime_reprotect_starts_reverse_protection_checkpoint
  selftest_case_dr_vmware_missing_mover_is_rejected_before_scheduler
  selftest_case_dr_vmware_cycle_result_contract
  selftest_case_dr_runtime_state_snapshot_consistency
  selftest_case_dr_vmware_direct_target_patch_contract
  selftest_case_dr_vmware_nbd_readiness_barrier
  selftest_case_dr_vmware_nbd_reserved_pool_contract
  selftest_case_dr_vmware_nbd_deterministic_drain
  selftest_case_dr_vmware_nbd_holder_safety_barrier
  selftest_case_dr_vmware_nbd_quarantine_on_timeout
  selftest_case_dr_vmware_automatic_reseed_mode
  selftest_case_dr_vmware_forward_target_map_reuses_ablestack_locator
  selftest_case_dr_vmware_mover_uses_raw_over_nbd_image_opts
  selftest_case_dr_kvm_vmware_reverse_route_and_baseline_contract
  selftest_case_dr_kvm_vmware_failover_seeds_reverse_baseline
  selftest_case_dr_failback_resume_checkpoint_publishes_terminal_state
  selftest_case_dr_failback_commit_pending_is_not_authoritative_terminal
  selftest_case_dr_kvm_vmware_reverses_forward_profile_roles
  selftest_case_dr_ablestack_reverse_profile_canonicalizes_rbd_and_workers
  selftest_case_dr_kvm_vmware_initial_seed_accepts_missing_baseline
  selftest_case_dr_kvm_vmware_run_scoped_snapshot_retry
  selftest_case_dr_kvm_vmware_reverse_preflight_clears_return_trap
  selftest_case_dr_kvm_vmware_snapshot_attach_is_read_only
  selftest_case_dr_failback_terminal_publication_grace
  selftest_case_dr_failback_live_worker_journal_is_read_only
  selftest_case_dr_kvm_vmware_reverse_preflight_ignores_domain_runtime
  selftest_case_dr_kvm_vmware_canonicalizes_cloud_rbd_volume_identity
  selftest_case_dr_kvm_vmware_dispatches_shared_qcow2_reverse_baseline
  selftest_case_dr_kvm_vmware_refreshes_stale_target_backing
  selftest_case_events_json
  selftest_info "all checks passed"
}

if [[ -n "${FTCTL_SELFTEST_CASES:-}" ]]; then
  IFS=',' read -r -a _ftctl_selftest_cases <<< "${FTCTL_SELFTEST_CASES}"
  for _ftctl_selftest_case in "${_ftctl_selftest_cases[@]}"; do
    [[ -n "${_ftctl_selftest_case}" ]] || continue
    "${_ftctl_selftest_case}"
  done
else
  selftest_main "$@"
fi
