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
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source_n2k_lib() {
  local name="$1"
  local installed="${ROOT_DIR}/lib/ablestack-qemu-exec-tools/n2k/${name}"
  local source_tree="${ROOT_DIR}/lib/n2k/${name}"
  if [[ -f "${installed}" ]]; then
    export N2K_LIB_DIR="${ROOT_DIR}/lib/ablestack-qemu-exec-tools/n2k"
    # shellcheck source=/dev/null
    source "${installed}"
    return 0
  fi
  if [[ -f "${source_tree}" ]]; then
    export N2K_LIB_DIR="${ROOT_DIR}/lib/n2k"
    # shellcheck source=/dev/null
    source "${source_tree}"
    return 0
  fi
  echo "Missing n2k library: ${name}" >&2
  exit 2
}

usage() {
  cat <<'EOF'
ablestack_n2k - Nutanix AHV -> ABLESTACK(KVM) migration tool

Usage:
  ablestack_n2k [global options] <command> [command options]
  ablestack_n2k <command> --help

Global options:
  --workdir <path>        Work directory
  --run-id <id>           Run identifier
  --manifest <path>       Manifest path
  --log <path>            Events log path
  --json                  Emit machine-readable JSON output
  --dry-run               Plan without destructive actions
  --resume                Resume from an existing manifest
  --force                 Allow risky operations
  -h, --help              Show help

Commands:
  preflight               Check Nutanix/API/target host capabilities
  plan                    Build a migration plan for a VM
  run (alias: auto)       Run the migration pipeline
  init                    Initialize workdir and manifest
  snapshot                Create or select a source snapshot/recovery point
  sync                    Data sync: base|incr|final
  verify                  Verify migration state and target data
  cutover                 Final sync and target VM define/start
  cleanup                 Clean temporary migration resources
  status                  Show migration status
EOF
}

usage_preflight() {
  cat <<'EOF'
Usage:
  ablestack_n2k preflight --pc <host> [options]

Options:
  --pc <host>             Prism Central host
  --username <user>       Prism Central username
  --password <pass>       Prism Central password
  --cred-file <file>      Credential file
  --insecure <0|1>        Skip TLS verification when set to 1
  --mode <mode>           auto|v4-incremental|v3-incremental|legacy-cbt|cold-export|manual-disk
  --source-api <api>      auto|v3; v3 forces v3-incremental selection
  --force-v3              Force v3-incremental even when v4 is available
  --target-storage <type> auto|rbd|file|block
  --target-format <fmt>   qcow2|raw
  --rbd-access-mode <m>   librbd|krbd for target VM RBD access
  --target-provider <p>   libvirt|ablestack-cloud; default libvirt
  --cloud-endpoint <url>  ABLESTACK Cloud API endpoint
  --cloud-api-key <key>   ABLESTACK Cloud API key
  --cloud-secret-key <k>  ABLESTACK Cloud secret key
  --cloud-cred-file <f>   ABLESTACK Cloud credential file
  --cloud-zone-id <id>    Cloud zone ID for VM deployment
  --cloud-service-offering-id <id>
                          Cloud service offering ID
  --cloud-network-id <id> Cloud network ID; repeatable
  --cloud-network-ids <s> Comma-separated Cloud network IDs
  --cloud-storage-id <id> Cloud primary storage ID for importVolume
  --cloud-disk-offering-id <id>
                          Cloud disk offering ID for imported volumes
  --cloud-host-id <id>    Optional Cloud host ID
  --cloud-account <name>  Optional Cloud account
  --cloud-domain-id <id>  Optional Cloud domain ID
  --cloud-project-id <id> Optional Cloud project ID
  --cloud-name <name>     Optional Cloud VM host name
  --cloud-display-name <name>
                          Optional Cloud VM display name
  --capability-json <js>  Capability JSON string or file path
  --v4-vmm <0|1>          Override v4 vmm capability
  --v4-dataprotection <0|1>
                           Override v4 dataprotection capability
  --v4-data-plane <0|1>   Override verified v4 recovery-point data-plane capability
  --legacy-changed-regions <0|1>
                           Override legacy changed-region capability
  --legacy-endpoint-verified <0|1>
                           Override legacy endpoint verification
  --cold-export-available <0|1>
                           Override cold export availability
  --manual-disk-available <0|1>
                           Override manual disk availability
  --probe-legacy-cbt      Accept legacy changed-region probe request
  --allow-experimental    Allow experimental legacy paths

Notes:
  - With credentials, this command probes PC v4 capability, PE v3 fallback
    capability, target storage dependencies, and records the selected path.
  - Current runnable data path is v3 snapshot/NFS. PC v4 is used for discovery
    only until a verified v4 byte source is available.
EOF
}

usage_plan() {
  cat <<'EOF'
Usage:
  ablestack_n2k plan --vm <name|uuid> --pc <host> [options]

Options:
  --vm <name|uuid>        Source Nutanix VM
  --pc <host>             Prism Central host
  --username <user>       Prism Central username
  --password <pass>       Prism Central password
  --cred-file <file>      Credential file
  --insecure <0|1>        Skip TLS verification when set to 1
  --mode <mode>           auto|v4-incremental|v3-incremental|legacy-cbt|cold-export|manual-disk
  --source-api <api>      auto|v3; v3 forces v3-incremental selection
  --force-v3              Force v3-incremental even when v4 is available
  --target-storage <type> auto|rbd|file|block
  --target-format <fmt>   qcow2|raw
  --rbd-access-mode <m>   librbd|krbd for target VM RBD access
  --target-provider <p>   libvirt|ablestack-cloud; default libvirt
  --cloud-endpoint <url>  ABLESTACK Cloud API endpoint
  --cloud-api-key <key>   ABLESTACK Cloud API key
  --cloud-secret-key <k>  ABLESTACK Cloud secret key
  --cloud-cred-file <f>   ABLESTACK Cloud credential file
  --cloud-zone-id <id>    Cloud zone ID for VM deployment
  --cloud-service-offering-id <id>
                          Cloud service offering ID
  --cloud-network-id <id> Cloud network ID; repeatable
  --cloud-network-ids <s> Comma-separated Cloud network IDs
  --cloud-storage-id <id> Cloud primary storage ID for importVolume
  --cloud-disk-offering-id <id>
                          Cloud disk offering ID for imported volumes
  --cloud-host-id <id>    Optional Cloud host ID
  --cloud-account <name>  Optional Cloud account
  --cloud-domain-id <id>  Optional Cloud domain ID
  --cloud-project-id <id> Optional Cloud project ID
  --cloud-name <name>     Optional Cloud VM host name
  --cloud-display-name <name>
                          Optional Cloud VM display name
  --capability-json <js>  Capability JSON string or file path
  --probe-legacy-cbt      Probe legacy changed-region endpoint when credentials are provided
  --v4-vmm <0|1>          Override v4 vmm capability
  --v4-dataprotection <0|1>
                           Override v4 dataprotection capability
  --v4-data-plane <0|1>   Override verified v4 recovery-point data-plane capability
  --legacy-changed-regions <0|1>
                           Override legacy changed-region capability
  --legacy-endpoint-verified <0|1>
                           Override legacy endpoint verification
  --cold-export-available <0|1>
                           Override cold export availability
  --manual-disk-available <0|1>
                           Override manual disk availability
  --allow-experimental    Allow experimental legacy paths

Notes:
  - This command produces a VM-specific migration plan.
  - With credentials, PC v4 capability and PE v3 fallback capability are probed.
  - v4-incremental is not selected unless a v4 byte source/data-plane is verified.
EOF
}

usage_run() {
  cat <<'EOF'
Usage:
  ablestack_n2k run --vm <name|uuid> --pc <host> [options]
  ablestack_n2k auto --vm <name|uuid> --pc <host> [options]

Options:
  --vm <name|uuid>        Source Nutanix VM
  --pc <host>             Prism Central host
  --username <user>       Prism Central username
  --password <pass>       Prism Central password
  --cred-file <file>      Credential file
  --insecure <0|1>        Skip TLS verification when set to 1
  --mode <mode>           auto|v4-incremental|v3-incremental|legacy-cbt|cold-export|manual-disk
  --dst <path>            Destination root
  --target-format <fmt>   qcow2|raw
  --target-storage <type> file|block|rbd
  --target-map-json <js>  Per-disk target map
  --rbd-access-mode <m>   librbd|krbd for target VM RBD access
  --target-provider <p>   libvirt|ablestack-cloud; default libvirt
  --cloud-endpoint <url>  ABLESTACK Cloud API endpoint
  --cloud-api-key <key>   ABLESTACK Cloud API key
  --cloud-secret-key <k>  ABLESTACK Cloud secret key
  --cloud-cred-file <f>   ABLESTACK Cloud credential file
  --cloud-zone-id <id>    Cloud zone ID for VM deployment
  --cloud-service-offering-id <id>
                          Cloud service offering ID
  --cloud-network-id <id> Cloud network ID; repeatable
  --cloud-network-ids <s> Comma-separated Cloud network IDs
  --cloud-storage-id <id> Cloud primary storage ID for importVolume
  --cloud-disk-offering-id <id>
                          Cloud disk offering ID for imported volumes
  --cloud-host-id <id>    Optional Cloud host ID
  --cloud-account <name>  Optional Cloud account
  --cloud-domain-id <id>  Optional Cloud domain ID
  --cloud-project-id <id> Optional Cloud project ID
  --cloud-name <name>     Optional Cloud VM host name
  --cloud-display-name <name>
                          Optional Cloud VM display name
  --inventory-source <s>  none|fixture|api; default api
  --split <mode>          full|phase1|phase2
  --source-api <api>      v3; run data path currently uses v3 snapshot/NFS
  --force-v3              Force v3-incremental even when v4 is available
  --source-map-from-v3-nfs
                          Build source map from v3 snapshot metadata and NFS
                           (default)
  --no-source-map-from-v3-nfs
                          Reject v3 NFS source-map use
  --nfs-host <host>       Nutanix container NFS host for v3 snapshot files
  --nfs-mount-root <dir>  Local NFS mount root
  --deadline-sec <sec>    Phase2 incremental round deadline before final sync
  --max-incr-phase2 <n>   Maximum Phase2 incremental rounds
  --max-final-bytes <n>   Optional changed-byte threshold for Phase2 final gate
  --wait-seconds <N>      Source snapshot wait timeout
  --retention-seconds <N> Source snapshot retention time
  --snapshot-type <type>  CRASH_CONSISTENT|APPLICATION_CONSISTENT
  --shutdown <policy>     manual|none|guest|poweroff
  --shutdown-timeout-sec <sec>
                          Wait time for guest/poweroff shutdown completion
                          guest falls back to poweroff on failure/timeout
  --shutdown-poll-sec <sec>
                           Power-state polling interval after shutdown request
  --cutover-args <args>   Arguments forwarded to cutover, defaults to --define-only
  --network-mode <mode>   Target NIC mode: bridge|network; default bridge
  --bridge <name>         Bridge name for bridge mode; default bridge0
  --network <name>        Libvirt NAT network name for network mode; default default
  --cleanup-source-points Delete Nutanix source snapshots after successful cutover
                           (default)
  --keep-source-points    Keep Nutanix source snapshots after successful cutover
  --define-only           Generate target XML without virsh define/start
  --apply                 Run virsh define for the generated target XML
  --start                 Run virsh define and start the target VM
  --skip-plan             Skip preflight/plan recording before Phase1
  --probe-legacy-cbt      Probe legacy changed-region endpoint during plan
  --allow-experimental    Allow experimental legacy paths

Notes:
  - With global --resume, this command prints the manifest-based resume plan.
  - In auto mode, run records PC v4 capability and uses the validated PE v3
    fallback path when v4 byte-source/data-plane is unavailable.
  - Phase1 performs base sync and the first incremental sync, then exits.
  - Phase2 requires the Phase1 marker, loops incremental sync until the
    deadline gate is met, then performs final sync and cutover.
EOF
}

usage_init() {
  cat <<'EOF'
Usage:
  ablestack_n2k init --vm <name|uuid> --pc <host> --dst <path> [options]

Options:
  --vm <name|uuid>        Source Nutanix VM
  --pc <host>             Prism Central host
  --cred-file <file>      Credential file
  --username <user>       Prism Central username
  --password <pass>       Prism Central password
  --insecure <0|1>        Skip TLS verification when set to 1
  --dst <path>            Destination root
  --mode <mode>           auto|v4-incremental|v3-incremental|legacy-cbt|cold-export|manual-disk
  --force-v3              Initialize the manifest as v3-incremental
  --inventory-json <json> Normalized or raw VM inventory JSON
  --inventory-file <file> Normalized or raw VM inventory JSON file
  --inventory-source <s>  none|fixture|api
  --target-format <fmt>   qcow2|raw
  --target-storage <type> file|block|rbd
  --target-map-json <js>  Per-disk target map
  --rbd-access-mode <m>   librbd|krbd for target VM RBD access
  --target-provider <p>   libvirt|ablestack-cloud; default libvirt
  --cloud-endpoint <url>  ABLESTACK Cloud API endpoint
  --cloud-zone-id <id>    Cloud zone ID for VM deployment
  --cloud-service-offering-id <id>
                          Cloud service offering ID
  --cloud-network-id <id> Cloud network ID; repeatable
  --cloud-network-ids <s> Comma-separated Cloud network IDs
  --cloud-storage-id <id> Cloud primary storage ID for importVolume
  --cloud-disk-offering-id <id>
                          Cloud disk offering ID for imported volumes
  --cloud-host-id <id>    Optional Cloud host ID
  --cloud-account <name>  Optional Cloud account
  --cloud-domain-id <id>  Optional Cloud domain ID
  --cloud-project-id <id> Optional Cloud project ID
  --cloud-name <name>     Optional Cloud VM host name
  --cloud-display-name <name>
                          Optional Cloud VM display name

Notes:
  - This command creates the initial n2k manifest.
  - Direct API inventory lookup runs only with --inventory-source api.
  - --force-v3 stores v3-incremental as the manifest mode.
EOF
}

usage_snapshot() {
  cat <<'EOF'
Usage:
  ablestack_n2k snapshot base|incr|final [options]

Options:
  --name <name>           Snapshot or recovery point name
  --recovery-point-id <id>
                           Recovery point identifier to record
  --source-api <api>      manual|v4|v3|legacy
  --pc <host>             Prism host for API snapshot creation
  --vm <name|uuid>        Source VM for snapshot creation or legacy PD membership
  --cred-file <file>      Credential file
  --username <user>       Prism username
  --password <pass>       Prism password
  --insecure <0|1>        Skip TLS verification when set to 1
  --create-recovery-point Create a v4 Recovery Point
  --create-vm-snapshot    Create an internal v3 VM snapshot
  --snapshot-type <type>   CRASH_CONSISTENT|APPLICATION_CONSISTENT
  --pd-name <name>        Legacy Protection Domain name
  --create-pd             Create the PD when it does not exist
  --protect-vm            Add the VM to the PD before snapshot
  --create-oob-snapshot   Create a legacy PD out-of-band snapshot
  --verify-changed-regions
                           Probe legacy changed-region path pairs after snapshot
  --collect-changed-regions
                           Store changed-region metadata for this snapshot pair
  --reference-kind <kind>  Reference recovery point kind: base|incr|final
  --restore-to-temp-vm     Restore v4 Recovery Point to a temporary VM
                           Requires global --force unless --dry-run is used
  --temp-vm-name <name>    Temporary VM name for v4 restore validation
  --restore-cluster-id <id>
                           Target cluster extId for v4 restore, optional
  --restore-strict-mode <0|1>
                           Use strict mode for v4 VM restore override
  --wait-seconds <N>      Wait timeout for PD snapshot materialization
  --retention-seconds <N> Legacy PD snapshot retention time
  --app-consistent        Request app-consistent legacy snapshot

Notes:
  - Manual mode records a recovery point reference in the manifest.
  - v4 mode can create a Recovery Point and records top-level, VM, and disk
    recovery point metadata.
  - v4 restore-to-temp-vm is intended only for byte-source validation and
    records the temporary VM identity when the restore task completes.
  - v3 mode can create an internal VM snapshot and records API-provided disk snapshot paths.
  - Legacy mode can create a PD OOB snapshot and records its snapshot metadata.
  - Legacy changed-region path verification records rejected path attempts in metadata.
EOF
}

usage_sync() {
  cat <<'EOF'
Usage:
  ablestack_n2k sync base|incr|final [options]

Options:
  --jobs <N>              Parallel job count
  --chunk <bytes>         Transfer chunk size
  --coalesce-gap <bytes>  Changed-region coalesce gap
  --source-map-json <js>  Cold-export source map JSON
  --source-map-file <file>
                           Cold-export source map JSON file
  --pc <host-or-url>       Prism endpoint for Nutanix API source URIs
  --cred-file <file>       Credential file for Nutanix API source URIs
  --username <user>        Prism username for Nutanix API source URIs
  --password <pass>        Prism password for Nutanix API source URIs
  --insecure <0|1>         Allow insecure TLS for Prism API source URIs
  --source-map-from-v3-nfs
                           Build source map from v3 snapshot metadata and NFS
  --nfs-host <host>        Nutanix NFS host for v3 snapshot file paths
  --nfs-mount-root <path>  Local mount root for Nutanix NFS sources
  --changed-regions-json <js>
                           Changed-region JSON for incr/final sync
  --changed-regions-file <file>
                           Changed-region JSON file for incr/final sync
  --recovery-point-id <id>
                           Recovery point identifier for manifest recording

Notes:
  - base sync supports cold-export/manual-disk source maps.
  - incr/final sync currently supports raw file or block targets.
  - incr/final sync can reuse manifest-collected changed regions when no
    --changed-regions-* option is provided.
  - incr/final source maps may use nutanix-v3-data://<vm_uuid>/<disk_uuid>
    for experimental Prism v3 disk data reads.
  - base/incr/final source maps may use nutanix-nfs://<host>/<container>/...
    for full-offset vDisk reads through Nutanix NFS exports.
EOF
}

usage_verify() {
  cat <<'EOF'
Usage:
  ablestack_n2k verify [options]

Options:
  --mode <mode>           quick|full
  --samples <N>           Sample count for quick verification

Notes:
  - Verification support is planned after manifest and transfer layers.
EOF
}

usage_cutover() {
  cat <<'EOF'
Usage:
  ablestack_n2k cutover [options]

Options:
  --shutdown <policy>     Accepted from run; source shutdown is handled before cutover
  --define-only           Generate target XML without virsh define/start
  --apply                 Run virsh define for the generated XML
  --start                 Start target VM after definition
  --rbd-access-mode <m>   Override manifest RBD access mode: librbd|krbd
  --network-mode <mode>   Target NIC mode: bridge|network; default bridge
  --bridge <name>         Bridge name for bridge mode; default bridge0
  --network <name>        Libvirt NAT network name for network mode; default default
  --target-provider <p>   libvirt|ablestack-cloud; defaults to manifest provider
  --cloud-endpoint <url>  ABLESTACK Cloud API endpoint
  --cloud-api-key <key>   ABLESTACK Cloud API key
  --cloud-secret-key <k>  ABLESTACK Cloud secret key
  --cloud-cred-file <f>   ABLESTACK Cloud credential file
  --cloud-zone-id <id>    Cloud zone ID for VM deployment
  --cloud-service-offering-id <id>
                          Cloud service offering ID
  --cloud-network-id <id> Cloud network ID; repeatable
  --cloud-network-ids <s> Comma-separated Cloud network IDs
  --cloud-storage-id <id> Cloud primary storage ID for importVolume
  --cloud-disk-offering-id <id>
                          Cloud disk offering ID for imported volumes
  --cloud-host-id <id>    Optional Cloud host ID
  --cloud-account <name>  Optional Cloud account
  --cloud-domain-id <id>  Optional Cloud domain ID
  --cloud-project-id <id> Optional Cloud project ID
  --cloud-name <name>     Optional Cloud VM host name
  --cloud-display-name <name>
                          Optional Cloud VM display name

Notes:
  - With libvirt, without --apply this command only generates the XML artifact.
  - With ablestack-cloud, --define-only validates imported volumes are visible;
    --apply imports volumes and deploys the VM stopped; --start starts it.
EOF
}

usage_cleanup() {
  cat <<'EOF'
Usage:
  ablestack_n2k cleanup [options]

Options:
  --keep-source-points    Keep source snapshots or recovery points
  --keep-workdir          Keep local workdir
  --remove-source-points  Remove recorded source points, requires global --force
  --remove-workdir        Remove empty workdir entries, requires global --force
  --apply                 Apply the cleanup plan

Notes:
  - Without --apply, this command only prints the cleanup plan.
  - Cleanup only removes resources recorded in the manifest.
EOF
}

usage_status() {
  cat <<'EOF'
Usage:
  ablestack_n2k status [options]

Options:
  --vm <name|uuid>        Show latest run status for a VM
  --watch                 Refresh status output
  --resume-plan           Show only the next resumable step

Notes:
  - This command reads the current manifest and prints a status summary.
EOF
}

usage_command() {
  local cmd="${1:-}"
  case "${cmd}" in
    preflight) usage_preflight ;;
    plan) usage_plan ;;
    run|auto) usage_run ;;
    init) usage_init ;;
    snapshot) usage_snapshot ;;
    sync) usage_sync ;;
    verify) usage_verify ;;
    cutover) usage_cutover ;;
    cleanup) usage_cleanup ;;
    status) usage_status ;;
    *) usage ;;
  esac
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

WORKDIR=""
RUN_ID=""
MANIFEST=""
EVENTS_LOG=""
JSON_OUT=0
DRY_RUN=0
RESUME=0
FORCE=0

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --log) EVENTS_LOG="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift 1 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    --resume) RESUME=1; shift 1 ;;
    --force) FORCE=1; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      ARGS=("$@")
      break
      ;;
  esac
done

if [[ ${#ARGS[@]} -lt 1 ]]; then
  usage
  exit 2
fi

CMD="${ARGS[0]}"
shifted_args=()
if [[ ${#ARGS[@]} -gt 1 ]]; then
  shifted_args=("${ARGS[@]:1}")
fi

if [[ ${#shifted_args[@]} -gt 0 ]]; then
  case "${shifted_args[0]}" in
    -h|--help)
      usage_command "${CMD}"
      exit 0
      ;;
  esac
fi

export N2K_ROOT_DIR="${ROOT_DIR}"
export N2K_WORKDIR="${WORKDIR}"
export N2K_RUN_ID="${RUN_ID}"
export N2K_MANIFEST="${MANIFEST}"
export N2K_EVENTS_LOG="${EVENTS_LOG}"
export N2K_JSON_OUT="${JSON_OUT}"
export N2K_DRY_RUN="${DRY_RUN}"
export N2K_RESUME="${RESUME}"
export N2K_FORCE="${FORCE}"

source_n2k_lib engine.sh

n2k_call_command() {
  local fn="$1"
  if [[ ${#shifted_args[@]} -gt 0 ]]; then
    "${fn}" "${shifted_args[@]}"
  else
    "${fn}"
  fi
}

case "${CMD}" in
  preflight) n2k_call_command n2k_cmd_preflight ;;
  plan) n2k_call_command n2k_cmd_plan ;;
  run|auto) n2k_call_command n2k_cmd_run ;;
  init) n2k_call_command n2k_cmd_init ;;
  snapshot) n2k_call_command n2k_cmd_snapshot ;;
  sync) n2k_call_command n2k_cmd_sync ;;
  verify) n2k_call_command n2k_cmd_verify ;;
  cutover) n2k_call_command n2k_cmd_cutover ;;
  cleanup) n2k_call_command n2k_cmd_cleanup ;;
  status) n2k_call_command n2k_cmd_status ;;
  *)
    die "Unknown command: ${CMD}"
    ;;
esac
