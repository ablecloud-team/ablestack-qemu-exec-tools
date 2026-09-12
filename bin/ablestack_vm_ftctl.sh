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

PROG="ablestack_vm_ftctl"
PROG_VERSION="0.1.0"

EXIT_OK=0
EXIT_USAGE=2
EXIT_RUNTIME=10
# Used by sourced library functions during command dispatch.
# shellcheck disable=SC2034
EXIT_LOCKED=20

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Used by sourced orchestrator code when protect-start detaches a worker.
# shellcheck disable=SC2034
FTCTL_SELF_BIN="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s\n' "${BASH_SOURCE[0]}")"

CLI_COMMAND=""
CLI_ACTION=""
CLI_VM=""
CLI_MODE=""
CLI_PEER=""
CLI_PROFILE=""
CLI_CONFIG_PATH=""
CLI_POLICY=""
CLI_DRY_RUN=""
CLI_JSON="0"
CLI_FORCE="0"
CLI_FORCE_CLEANUP="0"
CLI_CLUSTER_NAME=""
CLI_LOCAL_HOST_ID=""
CLI_HOST_ID=""
CLI_ROLE=""
CLI_MANAGEMENT_IP=""
CLI_LIBVIRT_URI=""
CLI_BLOCKCOPY_IP=""
CLI_XCOLO_CONTROL_IP=""
CLI_XCOLO_DATA_IP=""
CLI_DISK_MAP=""
CLI_BACKEND_MODE=""
CLI_PROVISIONING_BACKEND=""
CLI_PROVISIONING_STATE=""
CLI_TARGET_STORAGE_SCOPE=""
CLI_SECONDARY_VM_NAME=""
CLI_ACTIVE_SIDE=""
CLI_FENCING_POLICY=""
CLI_FENCING_IPMI_PRIMARY_HOST=""
CLI_FENCING_IPMI_PRIMARY_PORT=""
CLI_FENCING_IPMI_PRIMARY_USER=""
CLI_FENCING_IPMI_PRIMARY_PASSWORD=""
CLI_FENCING_IPMI_PRIMARY_INTERFACE=""
CLI_FENCING_IPMI_SECONDARY_HOST=""
CLI_FENCING_IPMI_SECONDARY_PORT=""
CLI_FENCING_IPMI_SECONDARY_USER=""
CLI_FENCING_IPMI_SECONDARY_PASSWORD=""
CLI_FENCING_IPMI_SECONDARY_INTERFACE=""
CLI_SECONDARY_TARGET_DIR=""
CLI_SECONDARY_SSH_KEY_FILE=""
CLI_REMOTE_NBD_EXPORT_ADDR=""
CLI_XCOLO_PROXY_ENDPOINT=""
CLI_XCOLO_NBD_ENDPOINT=""
CLI_XCOLO_MIGRATE_URI=""
CLI_XCOLO_MIRROR_PORT=""
CLI_XCOLO_COMPARE_PORT=""
CLI_XCOLO_COMPARE_LOCAL_PORT=""
CLI_XCOLO_COMPARE_OUT_PORT=""
CLI_XCOLO_CONTROL_PORT=""
CLI_LIMIT=""
CLI_PUBLIC_KEY=""
CLI_KEY_COMMENT=""
CLI_SSH_USER=""
CLI_PLAN=""
CLI_RUN=""
CLI_PROFILE_JSON=""
CLI_ARTIFACT_SPEC_JSON=""
CLI_AUTHORITY_SPEC_JSON=""
CLI_AUTHORITY_SEQUENCE_FLOOR=""
CLI_RESTORE_POINT=""
CLI_EVENTS_OFFSET=""
CLI_EVENTS_LIMIT="20"
CLI_WAIT_VALUE=""
CLI_TARGET_VM_ID=""
CLI_TARGET_EXTERNAL_REF=""
CLI_TARGET_VM_NAME=""
CLI_TARGET_NETWORK_ID=""
CLI_TARGET_VOLUME_MAP_JSON=""
CLI_TARGET_READY_RPO_SECONDS=""
CLI_MATERIALIZATION_SPEC_JSON=""
CLI_MATERIALIZATION_SPEC_SHA256=""
CLI_CUTOVER_SESSION_ID=""
CLI_ENGINE_SESSION_ID=""
CLI_CLOUD_SESSION_ID=""
CLI_CHECKPOINT_SEQUENCE=""
CLI_AUTHORITY_GENERATION=""
CLI_MANIFEST_SHA256=""
CLI_SOURCE_FENCE_STATE=""
CLI_OPERATION=""
CLI_EXPECTED_AUTHORITY=""
CLI_OPERATION_INTENT=""
CLI_REQUESTED_MODE="AUTO"
CLI_RESUME_BASELINE_CHECKPOINT_SEQUENCE=""
CLI_MINIMUM_COMPLETED_CHECKPOINT_SEQUENCE=""
CLI_FORCE_IMMEDIATE_CYCLE="false"
CLI_TARGET_POWER_STATE=""
CLI_SOURCE_POWER_STATE=""
CLI_BOOT_VALIDATION_STATE=""
CLI_PHASE=""
CLI_COMMIT_CONTRACT_VERSION=""
CLI_BASELINE_GENERATION=""
CLI_EVIDENCE_RUN=""
CLI_COMMIT_ATTEMPT_ID=""
CLI_COMMIT_ENVELOPE_SHA256=""

FTCTL_LIB_BASE=""

ftctl_die_load() {
  echo "ERROR: $*" >&2
  exit "${EXIT_RUNTIME}"
}

ftctl_resolve_lib_base() {
  local candidates=(
    "${ROOT_DIR}/lib"
    "${ROOT_DIR}/lib/ablestack-qemu-exec-tools"
    "/usr/local/lib/ablestack-qemu-exec-tools"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "${c}/ftctl" ]]; then
      FTCTL_LIB_BASE="${c}"
      return 0
    fi
  done
  ftctl_die_load "ftctl library directory not found"
}

ftctl_load_libs() {
  ftctl_resolve_lib_base

  local req=(
    common.sh
    config.sh
    logging.sh
    libvirt_wrap.sh
    state.sh
    profile.sh
    inventory.sh
    cluster.sh
    blockcopy.sh
    dr_key.sh
    standby.sh
    xcolo.sh
    fencing.sh
    failover.sh
    events.sh
    dr_ablestack.sh
    dr_vmware.sh
    dr_kvm_vmware.sh
    dr_scheduler.sh
    dr_nbd.sh
    guestprep.sh
    dr_runtime.sh
    dr_checkpoint.sh
    dr_checkpoint.py
    verify.sh
    orchestrator.sh
  )
  local f
  for f in "${req[@]}"; do
    [[ -f "${FTCTL_LIB_BASE}/ftctl/${f}" ]] || ftctl_die_load "missing: ${FTCTL_LIB_BASE}/ftctl/${f}"
  done

  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/common.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/config.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/logging.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/libvirt_wrap.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/state.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/profile.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/inventory.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/cluster.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/blockcopy.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/dr_key.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/standby.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/xcolo.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/fencing.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/failover.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/events.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/dr_ablestack.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/dr_vmware.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/dr_kvm_vmware.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/dr_scheduler.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/dr_nbd.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/guestprep.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/dr_runtime.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/verify.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/orchestrator.sh"
}

usage() {
  cat <<'EOF'
Usage:
  ablestack_vm_ftctl <command> [options]

Commands:
  protect            Register protection intent for a VM
  protect-start      Start protection asynchronously and return a job id
  status             Show current protection status
  reconcile          Keep or re-arm replication state
  failover           Start failover workflow
  failover-prepare   Release replication handles before cloud-managed standby start
  failback           Start failback workflow
  failback-sync      Prepare reverse sync for cloud-managed failback
  failback-finalize  Finalize reverse sync after cloud-managed standby stop
  failback-reprotect Re-arm protection after cloud-managed failback cutback
  unprotect          Stop protection and remove host-side FTCTL runtime state
  fence-confirm      Mark manual fencing as completed
  fence-clear        Clear fencing state
  pause-protection   Pause reconciliation for a VM
  resume-protection  Resume reconciliation for a VM
  preflight-remote   Validate remote DR qemu+ssh execution path
  dr-key-ensure      Create or return the local DR SSH public key
  dr-key-install     Install a DR SSH public key on this host
  dr-key-remove      Remove an installed DR SSH public key from this host
  check              Probe VM/profile/peer reachability
  health             Check local libvirt health only
  events             Show recent FTCTL events
  snapshot           Show recorded FTCTL state/check/health/events only
  dr-plan-apply      Validate/apply a Cloud-provided FTCTL_DR profile
  dr-sync-start      Accept a DR sync session
  dr-sync-recover    Recover a stopped DR scheduler without discarding its baseline
  dr-sync-pause      Pause a DR sync session
  dr-sync-resume     Resume a DR sync session
  dr-scheduler-run   Run the Plan scheduler as a systemd-owned foreground process
  dr-reconcile       Recover eligible local DR schedulers from Cloud-fenced profiles
  dr-test-failover   Accept a DR test failover session
  dr-test-cleanup    Complete DR test cleanup state
  dr-test-prepare    Prepare writable test artifacts for Cloud-managed Test Failover
  dr-test-artifact-cleanup
                     Remove FTCTL test artifacts after Cloud resource cleanup
  dr-failover        Accept a DR failover session
  dr-failback        Accept a DR failback session
  dr-reprotect       Accept a DR reprotect session
  dr-target-materialized
                     Mark Cloud target VM/volume materialization complete
  dr-target-export-start
                     Start Plan Owner controlled target RBD NBD exports
  dr-target-export-stop
                     Stop Plan Owner controlled target RBD NBD exports
  dr-cutover-commit  Commit Cloud-owned target promotion to FTCTL authority state
  dr-cutover-commit-status
                     Read the durable Cloud-owned cutover commit outcome
  dr-failover-abort  Abort failover preparation before target promotion
  dr-failback-commit Commit Cloud-owned source restoration to FTCTL authority state
  dr-failback-commit-status
                       Read the durable Cloud-owned failback commit outcome
  dr-failback-abort  Abort Cloud-owned failback lifecycle and retain target authority
  dr-release         Release DR runtime state
  dr-status          Show DR runtime status for a plan/run
  dr-transition-preflight
                      Validate failback/reprotect authority without changing runtime state
  dr-reverse-preflight
                      Resolve reverse seed mode and validate source disks without changing runtime state
  dr-capabilities    Show FTCTL_DR runtime command capabilities
  dr-cancel          Cancel a DR runtime run
  config             Manage cluster/host inventory

Global options:
  -h, --help         Show help
  -V, --version      Show version
      --vm NAME      VM name
      --mode MODE    Protection mode: ha|dr|ft
      --peer URI     Peer libvirt URI
      --profile ID   Profile name
      --config PATH  Config file path
      --policy NAME  Policy name
      --dry-run      Do not perform actions
      --json         JSON output where supported
      --force        Acknowledge risky transition commands
      --force-cleanup
                     Best-effort unprotect cleanup; continue after release errors
      --cluster-name NAME
      --local-host-id ID
      --host-id ID
      --role ROLE
      --management-ip ADDR
      --libvirt-uri URI
      --blockcopy-ip ADDR
      --xcolo-control-ip ADDR
      --xcolo-data-ip ADDR
      --public-key KEY
      --key-comment COMMENT
      --ssh-user USER
      --limit N       Limit items for commands that support it
      --plan UUID     FTCTL_DR plan UUID
      --run UUID      FTCTL_DR run UUID
      --profile-json PATH
                     Cloud-provided FTCTL_DR profile JSON
      --artifact-spec-json PATH
                     Cloud-provided FTCTL_DR test artifact locator contract
      --authority-spec-json PATH
                     Cloud-provided FTCTL_DR committed authority contract
      --authority-sequence-floor N
                     Monotonic Cloud authority sequence lower bound
      --restore-point ID
      --events-offset N
      --events-limit N
      --wait VALUE    DR command wait policy; --wait=false returns after accept
      --secondary-vm-name NAME
      --active-side SIDE
      --session-id ID  Cloud cutover session identifier
      --engine-session-id ID
                     FTCTL failover engine session identifier
      --cloud-session-id ID
                     Cloud cutover session UUID
      --checkpoint-sequence N
                     Durable checkpoint used for target promotion
      --authority-generation N
                      Monotonic Cloud promotion generation
      --manifest-sha256 SHA256
                     Durable cutover manifest SHA-256
      --source-fence-state STATE
                     Source isolation state observed by Cloud
      --operation-intent INTENT
                      Reverse operation intent such as FAILBACK_FINAL or REPROTECT
      --requested-mode MODE
                      Reverse transfer mode; AUTO is the default
      --resume-baseline-checkpoint-sequence N
                     Last durable sequence before source protection resumes
      --minimum-completed-checkpoint-sequence N
                     First sequence that must complete after failback
      --force-immediate-cycle
                     Start the required post-failback replication cycle immediately
      --target-power-state STATE
      --source-power-state STATE
      --boot-validation-state STATE
      --phase PHASE     Failback rollback phase: prepare or commit
      --commit-contract-version VERSION
      --baseline-generation N
      --evidence-run UUID
      --commit-attempt-id UUID
      --commit-envelope-sha256 SHA256
      --provisioning-backend BACKEND

Config actions:
  ablestack_vm_ftctl config init-cluster --cluster-name <name> --local-host-id <id>
  ablestack_vm_ftctl config set-local-host --local-host-id <id>
  ablestack_vm_ftctl config show [--json]
  ablestack_vm_ftctl config host-upsert --host-id <id> --role <role> \
    --management-ip <addr> --libvirt-uri <uri> --blockcopy-ip <addr> \
    --xcolo-control-ip <addr> --xcolo-data-ip <addr>
  ablestack_vm_ftctl config host-remove --host-id <id>
  ablestack_vm_ftctl config host-list [--json]
  ablestack_vm_ftctl config profile-upsert --vm <name> --mode <ha|dr|ft> --peer <uri> \
    [--profile <name>] [--disk-map <map>] [--backend-mode <mode>] [--target-storage-scope <scope>] \
    [--secondary-vm-name <name>] [--fencing-policy <policy>] \
    [--fencing-ipmi-primary-host <addr>] [--fencing-ipmi-primary-port <port>] \
    [--fencing-ipmi-primary-user <user>] [--fencing-ipmi-primary-password <password>] \
    [--fencing-ipmi-primary-interface <interface>] \
    [--fencing-ipmi-secondary-host <addr>] [--fencing-ipmi-secondary-port <port>] \
    [--fencing-ipmi-secondary-user <user>] [--fencing-ipmi-secondary-password <password>] \
    [--fencing-ipmi-secondary-interface <interface>] \
    [--secondary-target-dir <dir>] [--remote-nbd-export-addr <addr>] \
    [--xcolo-proxy-endpoint <endpoint>] [--xcolo-nbd-endpoint <endpoint>] \
    [--xcolo-migrate-uri <uri>] [--xcolo-mirror-port <port>] \
    [--xcolo-compare-port <port>] [--xcolo-compare-local-port <port>] \
    [--xcolo-compare-out-port <port>] [--xcolo-control-port <port>]
  ablestack_vm_ftctl config profile-remove --vm <name>
  ablestack_vm_ftctl config profile-show --vm <name> [--json]
EOF
}

print_version() {
  echo "${PROG} ${PROG_VERSION}"
}

parse_args() {
  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit "${EXIT_OK}"
        ;;
      -V|--version)
        print_version
        exit "${EXIT_OK}"
        ;;
      protect|protect-start|status|reconcile|failover|failover-prepare|failback|failback-sync|failback-finalize|failback-reprotect|unprotect|fence-confirm|fence-clear|pause-protection|resume-protection|preflight-remote|dr-key-ensure|dr-key-install|dr-key-remove|check|health|events|snapshot|dr-plan-apply|dr-sync-start|dr-sync-recover|dr-sync-pause|dr-sync-resume|dr-scheduler-run|dr-reconcile|dr-test-failover|dr-test-cleanup|dr-test-prepare|dr-test-artifact-cleanup|dr-failover|dr-failover-abort|dr-failback|dr-reprotect|dr-target-materialized|dr-checkpoint-restore|dr-checkpoint-publish-worker|dr-checkpoint-manage|dr-checkpoint-publish|dr-checkpoint-ack|dr-target-export-start|dr-target-export-stop|dr-cutover-commit|dr-cutover-commit-status|dr-failback-commit|dr-failback-commit-status|dr-failback-abort|dr-release|dr-status|dr-transition-preflight|dr-reverse-preflight|dr-capabilities|dr-cancel|config)
        [[ -z "${CLI_COMMAND}" ]] || {
          echo "ERROR: multiple commands specified" >&2
          exit "${EXIT_USAGE}"
        }
        CLI_COMMAND="$1"
        shift
        ;;
      init-cluster|set-local-host|show|host-upsert|host-remove|host-list|profile-upsert|profile-remove|profile-show)
        if [[ "${CLI_COMMAND}" == "config" && -z "${CLI_ACTION}" ]]; then
          CLI_ACTION="$1"
          shift
        else
          echo "ERROR: unexpected token: $1" >&2
          exit "${EXIT_USAGE}"
        fi
        ;;
      --vm)
        CLI_VM="${2-}"
        shift 2
        ;;
      --mode)
        CLI_MODE="${2-}"
        shift 2
        ;;
      --peer)
        CLI_PEER="${2-}"
        shift 2
        ;;
      --profile)
        CLI_PROFILE="${2-}"
        shift 2
        ;;
      --config)
        CLI_CONFIG_PATH="${2-}"
        shift 2
        ;;
      --policy)
        CLI_POLICY="${2-}"
        shift 2
        ;;
      --dry-run)
        CLI_DRY_RUN="1"
        shift
        ;;
      --json)
        CLI_JSON="1"
        shift
        ;;
      --force)
        CLI_FORCE="1"
        shift
        ;;
      --force-cleanup)
        CLI_FORCE_CLEANUP="1"
        shift
        ;;
      --cluster-name)
        CLI_CLUSTER_NAME="${2-}"
        shift 2
        ;;
      --local-host-id)
        CLI_LOCAL_HOST_ID="${2-}"
        shift 2
        ;;
      --host-id)
        CLI_HOST_ID="${2-}"
        shift 2
        ;;
      --role)
        CLI_ROLE="${2-}"
        shift 2
        ;;
      --management-ip)
        CLI_MANAGEMENT_IP="${2-}"
        shift 2
        ;;
      --libvirt-uri)
        CLI_LIBVIRT_URI="${2-}"
        shift 2
        ;;
      --blockcopy-ip)
        CLI_BLOCKCOPY_IP="${2-}"
        shift 2
        ;;
      --xcolo-control-ip)
        CLI_XCOLO_CONTROL_IP="${2-}"
        shift 2
        ;;
      --xcolo-data-ip)
        CLI_XCOLO_DATA_IP="${2-}"
        shift 2
        ;;
      --backend-mode)
        CLI_BACKEND_MODE="${2-}"
        shift 2
        ;;
      --provisioning-backend)
        CLI_PROVISIONING_BACKEND="${2-}"
        shift 2
        ;;
      --provisioning-state)
        CLI_PROVISIONING_STATE="${2-}"
        shift 2
        ;;
      --disk-map)
        CLI_DISK_MAP="${2-}"
        shift 2
        ;;
      --target-storage-scope)
        CLI_TARGET_STORAGE_SCOPE="${2-}"
        shift 2
        ;;
      --secondary-vm-name)
        CLI_SECONDARY_VM_NAME="${2-}"
        shift 2
        ;;
      --active-side)
        CLI_ACTIVE_SIDE="${2-}"
        shift 2
        ;;
      --fencing-policy)
        CLI_FENCING_POLICY="${2-}"
        shift 2
        ;;
      --fencing-ipmi-primary-host)
        CLI_FENCING_IPMI_PRIMARY_HOST="${2-}"
        shift 2
        ;;
      --fencing-ipmi-primary-port)
        CLI_FENCING_IPMI_PRIMARY_PORT="${2-}"
        shift 2
        ;;
      --fencing-ipmi-primary-user)
        CLI_FENCING_IPMI_PRIMARY_USER="${2-}"
        shift 2
        ;;
      --fencing-ipmi-primary-password)
        CLI_FENCING_IPMI_PRIMARY_PASSWORD="${2-}"
        shift 2
        ;;
      --fencing-ipmi-primary-interface)
        CLI_FENCING_IPMI_PRIMARY_INTERFACE="${2-}"
        shift 2
        ;;
      --fencing-ipmi-secondary-host)
        CLI_FENCING_IPMI_SECONDARY_HOST="${2-}"
        shift 2
        ;;
      --fencing-ipmi-secondary-port)
        CLI_FENCING_IPMI_SECONDARY_PORT="${2-}"
        shift 2
        ;;
      --fencing-ipmi-secondary-user)
        CLI_FENCING_IPMI_SECONDARY_USER="${2-}"
        shift 2
        ;;
      --fencing-ipmi-secondary-password)
        CLI_FENCING_IPMI_SECONDARY_PASSWORD="${2-}"
        shift 2
        ;;
      --fencing-ipmi-secondary-interface)
        CLI_FENCING_IPMI_SECONDARY_INTERFACE="${2-}"
        shift 2
        ;;
      --secondary-target-dir)
        CLI_SECONDARY_TARGET_DIR="${2-}"
        shift 2
        ;;
      --secondary-ssh-key-file)
        CLI_SECONDARY_SSH_KEY_FILE="${2-}"
        shift 2
        ;;
      --remote-nbd-export-addr)
        CLI_REMOTE_NBD_EXPORT_ADDR="${2-}"
        shift 2
        ;;
      --xcolo-proxy-endpoint)
        CLI_XCOLO_PROXY_ENDPOINT="${2-}"
        shift 2
        ;;
      --xcolo-nbd-endpoint)
        CLI_XCOLO_NBD_ENDPOINT="${2-}"
        shift 2
        ;;
      --xcolo-migrate-uri)
        CLI_XCOLO_MIGRATE_URI="${2-}"
        shift 2
        ;;
      --xcolo-mirror-port)
        CLI_XCOLO_MIRROR_PORT="${2-}"
        shift 2
        ;;
      --xcolo-compare-port)
        CLI_XCOLO_COMPARE_PORT="${2-}"
        shift 2
        ;;
      --xcolo-compare-local-port)
        CLI_XCOLO_COMPARE_LOCAL_PORT="${2-}"
        shift 2
        ;;
      --xcolo-compare-out-port)
        CLI_XCOLO_COMPARE_OUT_PORT="${2-}"
        shift 2
        ;;
      --xcolo-control-port)
        CLI_XCOLO_CONTROL_PORT="${2-}"
        shift 2
        ;;
      --public-key)
        CLI_PUBLIC_KEY="${2-}"
        shift 2
        ;;
      --key-comment)
        CLI_KEY_COMMENT="${2-}"
        shift 2
        ;;
      --ssh-user)
        CLI_SSH_USER="${2-}"
        shift 2
        ;;
      --limit)
        CLI_LIMIT="${2-}"
        shift 2
        ;;
      --plan)
        CLI_PLAN="${2-}"
        shift 2
        ;;
      --run)
        CLI_RUN="${2-}"
        shift 2
        ;;
      --target-vm-id)
        CLI_TARGET_VM_ID="${2-}"
        shift 2
        ;;
      --target-external-ref)
        CLI_TARGET_EXTERNAL_REF="${2-}"
        shift 2
        ;;
      --target-vm-name)
        CLI_TARGET_VM_NAME="${2-}"
        shift 2
        ;;
      --target-network-id)
        CLI_TARGET_NETWORK_ID="${2-}"
        shift 2
        ;;
      --target-volume-map-json)
        CLI_TARGET_VOLUME_MAP_JSON="${2-}"
        shift 2
        ;;
      --target-ready-rpo-seconds)
        CLI_TARGET_READY_RPO_SECONDS="${2-}"
        shift 2
        ;;
      --materialization-spec-json)
        CLI_MATERIALIZATION_SPEC_JSON="${2-}"
        shift 2
        ;;
      --materialization-spec-sha256)
        CLI_MATERIALIZATION_SPEC_SHA256="${2-}"
        shift 2
        ;;
      --session-id)
        CLI_CUTOVER_SESSION_ID="${2-}"
        shift 2
        ;;
      --engine-session-id)
        CLI_ENGINE_SESSION_ID="${2-}"
        shift 2
        ;;
      --cloud-session-id)
        CLI_CLOUD_SESSION_ID="${2-}"
        shift 2
        ;;
      --checkpoint-sequence)
        CLI_CHECKPOINT_SEQUENCE="${2-}"
        shift 2
        ;;
      --authority-generation)
        CLI_AUTHORITY_GENERATION="${2-}"
        shift 2
        ;;
      --manifest-sha256)
        CLI_MANIFEST_SHA256="${2-}"
        shift 2
        ;;
      --source-fence-state)
        CLI_SOURCE_FENCE_STATE="${2-}"
        shift 2
        ;;
      --operation)
        CLI_OPERATION="${2-}"
        shift 2
        ;;
      --operation-intent)
        CLI_OPERATION_INTENT="${2-}"
        shift 2
        ;;
      --requested-mode)
        CLI_REQUESTED_MODE="${2-}"
        shift 2
        ;;
      --expected-authority)
        CLI_EXPECTED_AUTHORITY="${2-}"
        shift 2
        ;;
      --resume-baseline-checkpoint-sequence)
        CLI_RESUME_BASELINE_CHECKPOINT_SEQUENCE="${2-}"
        shift 2
        ;;
      --minimum-completed-checkpoint-sequence)
        CLI_MINIMUM_COMPLETED_CHECKPOINT_SEQUENCE="${2-}"
        shift 2
        ;;
      --authority-sequence-floor)
        CLI_AUTHORITY_SEQUENCE_FLOOR="${2-}"
        shift 2
        ;;
      --force-immediate-cycle)
        CLI_FORCE_IMMEDIATE_CYCLE="true"
        shift
        ;;
      --target-power-state)
        CLI_TARGET_POWER_STATE="${2-}"
        shift 2
        ;;
      --source-power-state)
        CLI_SOURCE_POWER_STATE="${2-}"
        shift 2
        ;;
      --boot-validation-state)
        CLI_BOOT_VALIDATION_STATE="${2-}"
        shift 2
        ;;
      --phase)
        CLI_PHASE="${2-}"
        shift 2
        ;;
      --commit-contract-version)
        CLI_COMMIT_CONTRACT_VERSION="${2-}"
        shift 2
        ;;
      --baseline-generation)
        CLI_BASELINE_GENERATION="${2-}"
        shift 2
        ;;
      --evidence-run)
        CLI_EVIDENCE_RUN="${2-}"
        shift 2
        ;;
      --commit-attempt-id)
        CLI_COMMIT_ATTEMPT_ID="${2-}"
        shift 2
        ;;
      --commit-envelope-sha256)
        CLI_COMMIT_ENVELOPE_SHA256="${2-}"
        shift 2
        ;;
      --profile-json)
        CLI_PROFILE_JSON="${2-}"
        shift 2
        ;;
      --artifact-spec-json)
        CLI_ARTIFACT_SPEC_JSON="${2-}"
        shift 2
        ;;
      --authority-spec-json)
        CLI_AUTHORITY_SPEC_JSON="${2-}"
        shift 2
        ;;
      --restore-point)
        CLI_RESTORE_POINT="${2-}"
        shift 2
        ;;
      --events-offset)
        CLI_EVENTS_OFFSET="${2-}"
        shift 2
        ;;
      --events-limit)
        CLI_EVENTS_LIMIT="${2-}"
        shift 2
        ;;
      --wait)
        CLI_WAIT_VALUE="${2-}"
        shift 2
        ;;
      --wait=*)
        CLI_WAIT_VALUE="${1#--wait=}"
        shift
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        exit "${EXIT_USAGE}"
        ;;
    esac
  done
}

apply_common_config() {
  ftctl_config_init_defaults
  ftctl_config_load_file "${FTCTL_CONFIG_PATH}"
  ftctl_config_apply_cli "${CLI_CONFIG_PATH}" "${CLI_POLICY}" "${CLI_DRY_RUN}"
  ftctl_config_load_file "${FTCTL_CONFIG_PATH}"
  ftctl_config_finalize_paths
  if [[ "${CLI_COMMAND}" != "dr-capabilities" ]]; then
    ftctl_ensure_runtime_dirs
  fi
  if ftctl_command_requires_lock "${CLI_COMMAND}" "${CLI_ACTION}"; then
    ftctl_lock_acquire || exit $?
  fi
}

require_vm() {
  [[ -n "${CLI_VM}" ]] || {
    echo "ERROR: --vm is required" >&2
    exit "${EXIT_USAGE}"
  }
}

require_mode() {
  [[ -n "${CLI_MODE}" ]] || {
    echo "ERROR: --mode is required" >&2
    exit "${EXIT_USAGE}"
  }
}

emit_action_result_json() {
  local command="${1-}"
  local vm="${2-}"
  local rc="${3-0}"
  local result protection transport active_side last_error

  [[ "${CLI_JSON}" == "1" ]] || return 0
  result="$(ftctl_result_from_rc "${rc}")"
  protection="$(ftctl_state_get "${vm}" "protection_state" 2>/dev/null || true)"
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
  active_side="$(ftctl_state_get "${vm}" "active_side" 2>/dev/null || true)"
  last_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
  printf '{"command":"%s","result":"%s","vm":"%s","exit_code":%s,"protection_state":"%s","transport_state":"%s","active_side":"%s","last_error":"%s"}\n' \
    "$(ftctl__json_escape "${command}")" \
    "$(ftctl__json_escape "${result}")" \
    "$(ftctl__json_escape "${vm}")" \
    "${rc}" \
    "$(ftctl__json_escape "${protection}")" \
    "$(ftctl__json_escape "${transport}")" \
    "$(ftctl__json_escape "${active_side}")" \
    "$(ftctl__json_escape "${last_error}")"
}

dispatch() {
  case "${CLI_COMMAND}" in
    dr-plan-apply)
      ftctl_dr_runtime_plan_apply "${CLI_PLAN}" "${CLI_PROFILE_JSON}" "${CLI_ROLE}" "${CLI_DRY_RUN}" "${CLI_JSON}"
      ;;
    dr-sync-start|dr-sync-recover|dr-sync-pause|dr-sync-resume|dr-test-failover|dr-test-cleanup|dr-test-prepare|dr-test-artifact-cleanup|dr-failover|dr-failback|dr-reprotect|dr-release)
      ftctl_dr_runtime_action "${CLI_COMMAND}" "${CLI_PLAN}" "${CLI_RUN}" "${CLI_PROFILE_JSON}" "${CLI_ROLE}" \
        "${CLI_MODE}" "${CLI_RESTORE_POINT}" "${CLI_FORCE}" "${CLI_DRY_RUN}" "${CLI_WAIT_VALUE}" "${CLI_JSON}" \
        "${CLI_ARTIFACT_SPEC_JSON}" "${CLI_AUTHORITY_SPEC_JSON}" "${CLI_FORCE_IMMEDIATE_CYCLE}" \
        "${CLI_AUTHORITY_SEQUENCE_FLOOR}" "${CLI_RESUME_BASELINE_CHECKPOINT_SEQUENCE}" \
        "${CLI_MINIMUM_COMPLETED_CHECKPOINT_SEQUENCE}"
      ;;
    dr-scheduler-run)
      ftctl_dr_scheduler_run_from_launch "${CLI_PLAN}" "${CLI_JSON}"
      ;;
    dr-reconcile)
      ftctl_dr_scheduler_reconcile_all "${CLI_JSON}"
      ;;
    dr-target-materialized)
      ftctl_dr_runtime_target_materialized "${CLI_PLAN}" "${CLI_RUN}" "${CLI_TARGET_VM_ID}" "${CLI_TARGET_EXTERNAL_REF}" \
        "${CLI_TARGET_VM_NAME}" "${CLI_TARGET_NETWORK_ID}" "${CLI_TARGET_VOLUME_MAP_JSON}" "${CLI_TARGET_READY_RPO_SECONDS}" \
        "${CLI_MATERIALIZATION_SPEC_JSON}" "${CLI_MATERIALIZATION_SPEC_SHA256}" "${CLI_JSON}"
      ;;
    dr-checkpoint-restore)
      ftctl_dr_checkpoint_restore "${CLI_PLAN}" "${CLI_ARTIFACT_SPEC_JSON}"
      ;;
    dr-checkpoint-publish-worker)
      ftctl_dr_checkpoint_publish_worker_result "${CLI_PLAN}" "${CLI_ARTIFACT_SPEC_JSON}"
      ;;
    dr-checkpoint-manage)
      ftctl_dr_checkpoint_manage "${CLI_PLAN}" "${CLI_ARTIFACT_SPEC_JSON}"
      ;;
    dr-checkpoint-publish)
      ftctl_dr_checkpoint_publish "${CLI_PLAN}" "${CLI_ARTIFACT_SPEC_JSON}"
      ;;
    dr-checkpoint-ack)
      ftctl_dr_checkpoint_ack "${CLI_PLAN}" "${CLI_ARTIFACT_SPEC_JSON}"
      ;;
    dr-target-export-start)
      ftctl_dr_runtime_record_export_worker_role "${CLI_PLAN}" "${CLI_ROLE:-target}"
      ftctl_dr_ablestack_target_export_start "${CLI_PLAN}" "${CLI_RUN}" "${CLI_PROFILE_JSON}" "${CLI_JSON}"
      ;;
    dr-target-export-stop)
      ftctl_dr_runtime_record_export_worker_role "${CLI_PLAN}" "${CLI_ROLE:-target}"
      ftctl_dr_ablestack_target_export_stop "${CLI_PLAN}" "${CLI_JSON}" "${CLI_RUN}" "${CLI_CHECKPOINT_SEQUENCE}" \
        "${CLI_PROFILE_JSON}"
      ;;
    dr-cutover-commit)
      ftctl_dr_runtime_record_worker_role "${CLI_PLAN}" "${CLI_ROLE}"
      ftctl_dr_runtime_cutover_commit "${CLI_PLAN}" "${CLI_RUN}" "${CLI_ENGINE_SESSION_ID:-${CLI_CUTOVER_SESSION_ID}}" \
        "${CLI_CHECKPOINT_SEQUENCE}" "${CLI_AUTHORITY_GENERATION}" "${CLI_TARGET_POWER_STATE}" \
        "${CLI_BOOT_VALIDATION_STATE}" "${CLI_JSON}" "${CLI_COMMIT_CONTRACT_VERSION}" \
        "${CLI_CLOUD_SESSION_ID}" "${CLI_MANIFEST_SHA256}" "${CLI_COMMIT_ATTEMPT_ID}" \
        "${CLI_COMMIT_ENVELOPE_SHA256}" "${CLI_TARGET_VM_ID}" "${CLI_TARGET_EXTERNAL_REF}" \
        "${CLI_SOURCE_FENCE_STATE}" "${CLI_SOURCE_POWER_STATE}" "${CLI_ROLE}"
      ;;
    dr-cutover-commit-status)
      ftctl_dr_runtime_cutover_commit_status "${CLI_PLAN}" "${CLI_RUN}" \
        "${CLI_ENGINE_SESSION_ID:-${CLI_CUTOVER_SESSION_ID}}" "${CLI_COMMIT_CONTRACT_VERSION}" \
        "${CLI_COMMIT_ATTEMPT_ID}" "${CLI_COMMIT_ENVELOPE_SHA256}" "${CLI_JSON}"
      ;;
    dr-failover-abort)
      ftctl_dr_runtime_failover_abort "${CLI_PLAN}" "${CLI_RUN}" "${CLI_CUTOVER_SESSION_ID}" "${CLI_JSON}"
      ;;
    dr-failback-commit)
      ftctl_dr_runtime_failback_commit "${CLI_PLAN}" "${CLI_RUN}" "${CLI_CUTOVER_SESSION_ID}" \
        "${CLI_CHECKPOINT_SEQUENCE}" "${CLI_AUTHORITY_GENERATION}" "${CLI_TARGET_POWER_STATE}" \
        "${CLI_SOURCE_POWER_STATE}" "${CLI_BOOT_VALIDATION_STATE}" "${CLI_JSON}" \
        "${CLI_RESUME_BASELINE_CHECKPOINT_SEQUENCE}" "${CLI_MINIMUM_COMPLETED_CHECKPOINT_SEQUENCE}" \
        "${CLI_FORCE_IMMEDIATE_CYCLE}" "${CLI_COMMIT_CONTRACT_VERSION}" \
        "${CLI_BASELINE_GENERATION}" "${CLI_EVIDENCE_RUN}" "${CLI_COMMIT_ATTEMPT_ID}" \
        "${CLI_COMMIT_ENVELOPE_SHA256}"
      ;;
    dr-failback-commit-status)
      ftctl_dr_runtime_failback_commit_status "${CLI_PLAN}" "${CLI_RUN}" "${CLI_CUTOVER_SESSION_ID}" \
        "${CLI_COMMIT_CONTRACT_VERSION}" "${CLI_COMMIT_ATTEMPT_ID}" "${CLI_COMMIT_ENVELOPE_SHA256}" "${CLI_JSON}"
      ;;
    dr-failback-abort)
      ftctl_dr_runtime_failback_abort "${CLI_PLAN}" "${CLI_RUN}" "${CLI_CUTOVER_SESSION_ID}" \
        "${CLI_PHASE:-commit}" "${CLI_TARGET_POWER_STATE:-POWERED_ON}" \
        "${CLI_SOURCE_POWER_STATE:-POWERED_OFF}" "${CLI_JSON}"
      ;;
    dr-status)
      ftctl_dr_runtime_status "${CLI_PLAN}" "${CLI_RUN}" "${CLI_EVENTS_OFFSET}" "${CLI_EVENTS_LIMIT}" "${CLI_JSON}"
      ;;
    dr-transition-preflight)
      ftctl_dr_runtime_transition_preflight "${CLI_PLAN}" "${CLI_OPERATION}" "${CLI_EXPECTED_AUTHORITY}" \
        "${CLI_AUTHORITY_GENERATION}" "${CLI_JSON}"
      ;;
    dr-reverse-preflight)
      reverse_source_provider="$(ftctl_dr_ablestack_profile_provider "${CLI_PROFILE_JSON}" source)"
      reverse_target_provider="$(ftctl_dr_ablestack_profile_provider "${CLI_PROFILE_JSON}" target)"
      if [[ "${reverse_source_provider}" == "ABLESTACK" && "${reverse_target_provider}" == "ABLESTACK" ]]; then
        ftctl_dr_ablestack_reverse_preflight "${CLI_PLAN}" "${CLI_PROFILE_JSON}" \
          "${CLI_OPERATION_INTENT:-FAILBACK_FINAL}" "${CLI_REQUESTED_MODE:-AUTO}" "${CLI_JSON}"
      else
        ftctl_dr_kvm_vmware_reverse_preflight "${CLI_PLAN}" "${CLI_PROFILE_JSON}" \
          "${CLI_OPERATION_INTENT:-FAILBACK_FINAL}" "${CLI_REQUESTED_MODE:-AUTO}" "${CLI_JSON}"
      fi
      ;;
    dr-capabilities)
      ftctl_dr_runtime_capabilities "${CLI_JSON}"
      ;;
    dr-cancel)
      ftctl_dr_runtime_cancel "${CLI_PLAN}" "${CLI_RUN}" "${CLI_FORCE}" "${CLI_JSON}"
      ;;
    config)
      case "${CLI_ACTION}" in
        init-cluster)
          [[ -n "${CLI_CLUSTER_NAME}" && -n "${CLI_LOCAL_HOST_ID}" ]] || {
            echo "ERROR: config init-cluster requires --cluster-name and --local-host-id" >&2
            exit "${EXIT_USAGE}"
          }
          ftctl_cluster_write_global "${CLI_CLUSTER_NAME}" "${CLI_LOCAL_HOST_ID}"
          ftctl_cluster_show "${CLI_JSON}"
          ;;
        set-local-host)
          ftctl_cluster_load
          [[ -n "${FTCTL_CLUSTER_NAME}" ]] || {
            echo "ERROR: cluster is not initialized. Run: ablestack_vm_ftctl config init-cluster ..." >&2
            exit "${EXIT_RUNTIME}"
          }
          [[ -n "${CLI_LOCAL_HOST_ID}" ]] || {
            echo "ERROR: config set-local-host requires --local-host-id" >&2
            exit "${EXIT_USAGE}"
          }
          ftctl_cluster_write_global "${FTCTL_CLUSTER_NAME}" "${CLI_LOCAL_HOST_ID}"
          ftctl_cluster_show "${CLI_JSON}"
          ;;
        show)
          ftctl_cluster_show "${CLI_JSON}"
          ;;
        host-upsert)
          [[ -n "${CLI_HOST_ID}" ]] || {
            echo "ERROR: config host-upsert requires --host-id" >&2
            exit "${EXIT_USAGE}"
          }
          [[ -n "${CLI_ROLE}" ]] || CLI_ROLE="generic"
          [[ -n "${CLI_MANAGEMENT_IP}" ]] || {
            echo "ERROR: config host-upsert requires --management-ip" >&2
            exit "${EXIT_USAGE}"
          }
          [[ -n "${CLI_LIBVIRT_URI}" ]] || {
            echo "ERROR: config host-upsert requires --libvirt-uri" >&2
            exit "${EXIT_USAGE}"
          }
          [[ -n "${CLI_BLOCKCOPY_IP}" ]] || {
            echo "ERROR: config host-upsert requires --blockcopy-ip" >&2
            exit "${EXIT_USAGE}"
          }
          [[ -n "${CLI_XCOLO_CONTROL_IP}" ]] || {
            echo "ERROR: config host-upsert requires --xcolo-control-ip" >&2
            exit "${EXIT_USAGE}"
          }
          [[ -n "${CLI_XCOLO_DATA_IP}" ]] || {
            echo "ERROR: config host-upsert requires --xcolo-data-ip" >&2
            exit "${EXIT_USAGE}"
          }
          ftctl_cluster_upsert_host "${CLI_HOST_ID}" "${CLI_ROLE}" "${CLI_MANAGEMENT_IP}" \
            "${CLI_LIBVIRT_URI}" "${CLI_BLOCKCOPY_IP}" "${CLI_XCOLO_CONTROL_IP}" "${CLI_XCOLO_DATA_IP}"
          ftctl_cluster_show "${CLI_JSON}"
          ;;
        host-remove)
          [[ -n "${CLI_HOST_ID}" ]] || {
            echo "ERROR: config host-remove requires --host-id" >&2
            exit "${EXIT_USAGE}"
          }
          ftctl_cluster_remove_host "${CLI_HOST_ID}"
          ftctl_cluster_show "${CLI_JSON}"
          ;;
        host-list)
          if [[ "${CLI_JSON}" == "1" ]]; then
            ftctl_cluster_host_list_json
          else
            ftctl_cluster_host_list_text
          fi
          ;;
        profile-upsert)
          require_vm
          require_mode
          [[ -n "${CLI_PEER}" ]] || {
            echo "ERROR: config profile-upsert requires --peer" >&2
            exit "${EXIT_USAGE}"
          }
          ftctl_profile_write_vm "${CLI_VM}" "${CLI_MODE}" "${CLI_PEER}" "${CLI_PROFILE}" \
            "${CLI_DISK_MAP}" "${CLI_BACKEND_MODE}" "${CLI_PROVISIONING_BACKEND}" "${CLI_PROVISIONING_STATE}" \
            "${CLI_TARGET_STORAGE_SCOPE}" "${CLI_SECONDARY_VM_NAME}" "${CLI_FENCING_POLICY}" \
            "${CLI_SECONDARY_TARGET_DIR}" "${CLI_REMOTE_NBD_EXPORT_ADDR}" \
            "${CLI_XCOLO_PROXY_ENDPOINT}" "${CLI_XCOLO_NBD_ENDPOINT}" "${CLI_XCOLO_MIGRATE_URI}" \
            "${CLI_XCOLO_MIRROR_PORT}" "${CLI_XCOLO_COMPARE_PORT}" "${CLI_XCOLO_COMPARE_LOCAL_PORT}" \
            "${CLI_XCOLO_COMPARE_OUT_PORT}" "${CLI_XCOLO_CONTROL_PORT}" \
            "${CLI_FENCING_IPMI_PRIMARY_HOST}" "${CLI_FENCING_IPMI_PRIMARY_PORT}" \
            "${CLI_FENCING_IPMI_PRIMARY_USER}" "${CLI_FENCING_IPMI_PRIMARY_PASSWORD}" "${CLI_FENCING_IPMI_PRIMARY_INTERFACE}" \
            "${CLI_FENCING_IPMI_SECONDARY_HOST}" "${CLI_FENCING_IPMI_SECONDARY_PORT}" \
            "${CLI_FENCING_IPMI_SECONDARY_USER}" "${CLI_FENCING_IPMI_SECONDARY_PASSWORD}" "${CLI_FENCING_IPMI_SECONDARY_INTERFACE}" \
            "${CLI_SECONDARY_SSH_KEY_FILE}"
          ftctl_profile_show_vm "${CLI_VM}" "${CLI_JSON}"
          ;;
        profile-remove)
          require_vm
          ftctl_profile_remove_vm "${CLI_VM}"
          if [[ "${CLI_JSON}" == "1" ]]; then
            printf '{"command":"config.profile-remove","result":"ok","vm":"%s"}\n' "${CLI_VM}"
          else
            printf '%s: profile removed\n' "${CLI_VM}"
          fi
          ;;
        profile-show)
          require_vm
          ftctl_profile_show_vm "${CLI_VM}" "${CLI_JSON}"
          ;;
        *)
          echo "ERROR: config requires one of: init-cluster, set-local-host, show, host-upsert, host-remove, host-list, profile-upsert, profile-remove, profile-show" >&2
          exit "${EXIT_USAGE}"
          ;;
      esac
      ;;
    protect)
      require_vm
      require_mode
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_apply_cli "${CLI_VM}" "${CLI_MODE}" "${CLI_PEER}" "${CLI_PROFILE}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_orchestrator_protect "${CLI_VM}"
      ;;
    protect-start)
      require_vm
      require_mode
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_apply_cli "${CLI_VM}" "${CLI_MODE}" "${CLI_PEER}" "${CLI_PROFILE}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_orchestrator_protect_start "${CLI_VM}"
      ;;
    status)
      if [[ -n "${CLI_VM}" ]]; then
        if [[ ! -f "$(ftctl_profile_path "${CLI_VM}")" ]]; then
          if [[ "${CLI_JSON}" == "1" ]]; then
            printf '{"command":"status","result":"not_found","vm":"%s"}\n' "$(ftctl__json_escape "${CLI_VM}")"
            exit "${EXIT_USAGE}"
          fi
          echo "ERROR: FTCTL profile not found for VM ${CLI_VM}" >&2
          exit "${EXIT_USAGE}"
        fi
        ftctl_profile_load_vm "${CLI_VM}"
        ftctl_profile_validate "${CLI_VM}"
      fi
      ftctl_state_print_status "${CLI_VM}" "${CLI_JSON}"
      ;;
    reconcile)
      ftctl_dr_ablestack_target_export_reconcile_all "0" || true
      ftctl_dr_scheduler_reconcile_all "0" || true
      ftctl_orchestrator_reconcile "${CLI_VM}" "${CLI_JSON}"
      ;;
    failover)
      require_vm
      [[ "${CLI_FORCE}" == "1" ]] || {
        echo "ERROR: failover requires --force in skeleton mode" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_failover_request "${CLI_VM}" "manual"
      ;;
    failover-prepare)
      require_vm
      [[ "${CLI_FORCE}" == "1" ]] || {
        echo "ERROR: failover-prepare requires --force" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_failover_prepare_cloud_managed "${CLI_VM}" "manual"
      ;;
    failback)
      require_vm
      [[ "${CLI_FORCE}" == "1" ]] || {
        echo "ERROR: failback requires --force in skeleton mode" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_failback_request "${CLI_VM}" "manual"
      ;;
    failback-sync)
      require_vm
      [[ "${CLI_FORCE}" == "1" ]] || {
        echo "ERROR: failback-sync requires --force in skeleton mode" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      rc=0
      ftctl_failback_sync_for_cloud_cutback "${CLI_VM}" "manual" || rc=$?
      emit_action_result_json "failback-sync" "${CLI_VM}" "${rc}"
      exit "${rc}"
      ;;
    failback-finalize)
      require_vm
      [[ "${CLI_FORCE}" == "1" ]] || {
        echo "ERROR: failback-finalize requires --force" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      rc=0
      ftctl_failback_finalize_after_cloud_secondary_stop "${CLI_VM}" "manual" || rc=$?
      emit_action_result_json "failback-finalize" "${CLI_VM}" "${rc}"
      exit "${rc}"
      ;;
    failback-reprotect)
      require_vm
      [[ "${CLI_FORCE}" == "1" ]] || {
        echo "ERROR: failback-reprotect requires --force in skeleton mode" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      rc=0
      ftctl_failback_reprotect_after_cloud_cutback "${CLI_VM}" "manual" || rc=$?
      emit_action_result_json "failback-reprotect" "${CLI_VM}" "${rc}"
      exit "${rc}"
      ;;
    unprotect)
      require_vm
      [[ "${CLI_FORCE}" == "1" ]] || {
        echo "ERROR: unprotect requires --force" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_profile_load_vm "${CLI_VM}" 2>/dev/null || true
      ftctl_state_unprotect_vm "${CLI_VM}" "${CLI_JSON}" "${CLI_FORCE_CLEANUP}"
      ;;
    fence-confirm)
      require_vm
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_fencing_manual_confirm "${CLI_VM}"
      ;;
    fence-clear)
      require_vm
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_fencing_clear "${CLI_VM}"
      ;;
    pause-protection)
      require_vm
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_state_pause_vm "${CLI_VM}"
      ;;
    resume-protection)
      require_vm
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_state_resume_vm "${CLI_VM}"
      ;;
    preflight-remote)
      require_vm
      require_mode
      [[ -n "${CLI_PEER}" ]] || {
        echo "ERROR: preflight-remote requires --peer" >&2
        exit "${EXIT_USAGE}"
      }
      # shellcheck disable=SC2034
      FTCTL_PROFILE_MODE="${CLI_MODE}"
      # shellcheck disable=SC2034
      FTCTL_PROFILE_SECONDARY_URI="${CLI_PEER}"
      # shellcheck disable=SC2034
      FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
      # shellcheck disable=SC2034
      FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
      # shellcheck disable=SC2034
      FTCTL_PROFILE_SECONDARY_TARGET_DIR="${CLI_SECONDARY_TARGET_DIR}"
      # shellcheck disable=SC2034
      FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE="${CLI_SECONDARY_SSH_KEY_FILE}"
      # shellcheck disable=SC2034
      FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="${CLI_REMOTE_NBD_EXPORT_ADDR}"
      # shellcheck disable=SC2034
      FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${CLI_VM}"
      ftctl_profile_materialize_dr_ssh_keyfile "${CLI_VM}"
      ftctl_blockcopy_remote_preflight "${CLI_VM}" "${CLI_JSON}"
      ;;
    dr-key-ensure)
      ftctl_dr_key_ensure "${CLI_PROFILE:-${CLI_VM:-}}"
      ;;
    dr-key-install)
      [[ -n "${CLI_PUBLIC_KEY}" ]] || {
        echo "ERROR: dr-key-install requires --public-key" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_dr_key_install "${CLI_PROFILE:-${CLI_VM:-}}" "${CLI_PUBLIC_KEY}" "${CLI_KEY_COMMENT}" "${CLI_SSH_USER:-root}"
      ;;
    dr-key-remove)
      ftctl_dr_key_remove "${CLI_PROFILE:-${CLI_VM:-}}" "${CLI_KEY_COMMENT}" "${CLI_SSH_USER:-root}"
      ;;
    check)
      require_vm
      if [[ ! -f "$(ftctl_profile_path "${CLI_VM}")" ]]; then
        if [[ "${CLI_JSON}" == "1" ]]; then
          printf '{"command":"check","vm":"%s","result":"not_found","inventory_result":"not_found","primary_rc":1,"peer_rc":1,"peer_domain_expected":false,"standby_domain_state":"profile-not-found","provisioning_backend":""}\n' "$(ftctl__json_escape "${CLI_VM}")"
          exit "${EXIT_USAGE}"
        fi
        echo "ERROR: FTCTL profile not found for VM ${CLI_VM}" >&2
        exit "${EXIT_USAGE}"
      fi
      ftctl_profile_load_vm "${CLI_VM}"
      # shellcheck disable=SC2034
      [[ -n "${CLI_SECONDARY_VM_NAME}" ]] && FTCTL_PROFILE_SECONDARY_VM_NAME="${CLI_SECONDARY_VM_NAME}"
      # shellcheck disable=SC2034
      [[ -n "${CLI_PROVISIONING_BACKEND}" ]] && FTCTL_PROFILE_PROVISIONING_BACKEND="${CLI_PROVISIONING_BACKEND}"
      [[ -n "${CLI_ACTIVE_SIDE}" ]] && export FTCTL_CHECK_ACTIVE_SIDE="${CLI_ACTIVE_SIDE}"
      ftctl_profile_validate "${CLI_VM}"
      ftctl_orchestrator_check_vm "${CLI_VM}" "${CLI_JSON}"
      ;;
    health)
      ftctl_local_health "${CLI_JSON}"
      ;;
    events)
      ftctl_events_print "${CLI_VM}" "${CLI_LIMIT}" "${CLI_JSON}"
      ;;
    snapshot)
      ftctl_state_print_snapshot "${CLI_VM}" "${CLI_JSON}" "${CLI_LIMIT}"
      ;;
    "")
      usage
      exit "${EXIT_USAGE}"
      ;;
    *)
      echo "ERROR: unsupported command: ${CLI_COMMAND}" >&2
      exit "${EXIT_USAGE}"
      ;;
  esac
}

main() {
  parse_args "$@"
  ftctl_load_libs
  apply_common_config
  dispatch
}

main "$@"
