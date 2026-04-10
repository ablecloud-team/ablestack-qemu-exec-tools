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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

CASE_ENV="${1-}"
AUTOMATION_ENV="${AUTOMATION_ENV:-${SCRIPT_DIR}/automation.env}"

[[ -n "${CASE_ENV}" ]] || ftctl_test_die "usage: $0 <case-env>"

ftctl_test_load_envs "${AUTOMATION_ENV}" "${CASE_ENV}"
ftctl_test_require_cmds virsh qemu-img python3 ssh jq
ftctl_test_prepare_log_dir

PROFILE_PATH_REAL="${FTCTL_PROFILE_DIR:-/etc/ablestack/ftctl.d}/${VM_NAME}.conf"
VM_XML_PATH="${VM_XML_RUNTIME_DIR}/${VM_NAME}.xml"

main() {
  ftctl_test_info "TEST_ID=${TEST_ID}"
  ftctl_test_info "VM_NAME=${VM_NAME}"
  ftctl_test_info "CASE_ENV=${CASE_ENV}"

  ftctl_test_run_and_log "${TEST_ID}.cluster.json" bash -lc '
    ablestack_vm_ftctl config init-cluster --cluster-name "'"${PRIMARY_HOST}"'-cluster" --local-host-id host-01 >/dev/null
    ablestack_vm_ftctl config host-upsert --host-id host-01 --role primary --management-ip "'"${PRIMARY_MGMT_IP}"'" --libvirt-uri "'"${PRIMARY_LIBVIRT_URI}"'" --blockcopy-ip "'"${PRIMARY_BLOCKCOPY_IP}"'" --xcolo-control-ip "'"${PRIMARY_BLOCKCOPY_IP}"'" --xcolo-data-ip "'"${PRIMARY_BLOCKCOPY_IP}"'" >/dev/null
    ablestack_vm_ftctl config host-upsert --host-id host-02 --role secondary --management-ip "'"${SECONDARY_MGMT_IP}"'" --libvirt-uri "'"${SECONDARY_LIBVIRT_URI}"'" --blockcopy-ip "'"${SECONDARY_BLOCKCOPY_IP}"'" --xcolo-control-ip "'"${SECONDARY_BLOCKCOPY_IP}"'" --xcolo-data-ip "'"${SECONDARY_BLOCKCOPY_IP}"'" >/dev/null
    ablestack_vm_ftctl config show --json
  '

  ftctl_test_build_profile \
    "${PROFILE_PATH_REAL}" \
    "${FTCTL_PROFILE_DOMAIN_PERSISTENCE}" \
    "${FTCTL_PROFILE_BACKEND_MODE}" \
    "${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}" \
    "${FTCTL_PROFILE_SECONDARY_VM_NAME}" \
    "${FTCTL_PROFILE_DISK_MAP}" \
    "${FTCTL_PROFILE_SECONDARY_TARGET_DIR}" \
    "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" \
    "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT}" \
    "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}"

  tee "$(ftctl_test_log_path "${TEST_ID}.profile.conf")" < "${PROFILE_PATH_REAL}" >/dev/null

  if [[ "${RECREATE_VM:-1}" == "1" ]]; then
    ftctl_test_cleanup_remote_nbd "${VM_NAME}" "${FTCTL_PROFILE_SECONDARY_VM_NAME}"
    ftctl_test_create_vm "${VM_NAME}" "${VM_XML_PATH}"
  fi

  ftctl_test_run_and_log "${TEST_ID}.check.txt" ablestack_vm_ftctl check --vm "${VM_NAME}"
  ftctl_test_run_and_log "${TEST_ID}.status.before.json" ablestack_vm_ftctl status --vm "${VM_NAME}" --json
  ftctl_test_run_and_log "${TEST_ID}.protect.txt" ablestack_vm_ftctl protect --vm "${VM_NAME}" --mode ha --peer "${SECONDARY_LIBVIRT_URI}"
  ftctl_test_run_and_log "${TEST_ID}.status.t0.json" ablestack_vm_ftctl status --vm "${VM_NAME}" --json
  ftctl_test_run_and_log "${TEST_ID}.dumpxml.t0.xml" env LC_ALL=C LANG=C virsh -c "${PRIMARY_LIBVIRT_URI}" dumpxml "${VM_NAME}"
  ftctl_test_run_and_log "${TEST_ID}.runtime-state.t0.txt" bash -lc 'find /run/ablestack-vm-ftctl -maxdepth 4 -type f -print -exec cat {} \; 2>/dev/null'

  sleep "${OBSERVE_DELAY_SEC:-10}"

  ftctl_test_run_and_log "${TEST_ID}.status.t10.json" ablestack_vm_ftctl status --vm "${VM_NAME}" --json
  ftctl_test_run_and_log "${TEST_ID}.dumpxml.t10.xml" env LC_ALL=C LANG=C virsh -c "${PRIMARY_LIBVIRT_URI}" dumpxml "${VM_NAME}"
  ftctl_test_run_and_log "${TEST_ID}.secondary-target.t10.txt" ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SECONDARY_SSH_USER}@${SECONDARY_MGMT_IP}" "ls -lh ${FTCTL_PROFILE_SECONDARY_TARGET_DIR}/${VM_NAME}/ ; ps -ef | grep qemu-nbd | grep ${VM_NAME} || true ; ss -lntp | grep ${FTCTL_REMOTE_NBD_PORT_BASE} || true"

  ftctl_test_run_and_log "${TEST_ID}.reconcile.txt" ablestack_vm_ftctl reconcile --vm "${VM_NAME}"
  ftctl_test_run_and_log "${TEST_ID}.status.final.json" ablestack_vm_ftctl status --vm "${VM_NAME}" --json
  ftctl_test_run_and_log "${TEST_ID}.dumpxml.final.xml" env LC_ALL=C LANG=C virsh -c "${PRIMARY_LIBVIRT_URI}" dumpxml "${VM_NAME}"
  ftctl_test_run_and_log "${TEST_ID}.runtime-state.final.txt" bash -lc 'find /run/ablestack-vm-ftctl -maxdepth 4 -type f -print -exec cat {} \; 2>/dev/null'

  if (( PROTECTED_DISK_COUNT >= 1 )); then
    local idx target
    for idx in $(ftctl_test_protected_disk_indices); do
      target="$(ftctl_test_disk_get "${idx}" TARGET)"
      [[ -n "${target}" ]] || continue
      ftctl_test_run_and_log "${TEST_ID}.blockjob.${target}.final.txt" env LC_ALL=C LANG=C virsh -c "${PRIMARY_LIBVIRT_URI}" blockjob --domain "${VM_NAME}" --path "${target}" --info
    done
  fi

  if [[ "${DOMAIN_MODE}" == "persistent" ]]; then
    ftctl_test_run_and_log "${TEST_ID}.peer.list.final.txt" virsh -c "${SECONDARY_LIBVIRT_URI}" list --all
    ftctl_test_run_and_log "${TEST_ID}.peer.dominfo.final.txt" env LC_ALL=C LANG=C virsh -c "${SECONDARY_LIBVIRT_URI}" dominfo "${FTCTL_PROFILE_SECONDARY_VM_NAME}"
  fi

  ftctl_test_collect_bundle "${VM_NAME}"
  ftctl_test_mark_summary "${VM_NAME}" "$(ftctl_test_log_path "${TEST_ID}.status.final.json")"
  ftctl_test_info "Completed ${TEST_ID}"
  cat "$(ftctl_test_log_path "${TEST_ID}.summary.txt")"
}

main "$@"
