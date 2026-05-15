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

n2k_bool_arg() {
  case "${1:-}" in
    1|true|yes|on|available|supported|ok) printf 'true' ;;
    0|false|no|off|unavailable|unsupported|missing|"") printf 'false' ;;
    *) return 1 ;;
  esac
}

n2k_load_json_arg() {
  local value="${1:-}"
  if [[ -z "${value}" ]]; then
    printf '{}'
    return 0
  fi
  if [[ -f "${value}" ]]; then
    jq -c . "${value}"
    return 0
  fi
  printf '%s' "${value}" | jq -c .
}

n2k_detect_host_dependencies() {
  local deps="{}"
  local name path available
  for name in jq curl qemu-img qemu-nbd virsh rbd rbd-nbd lvs lvcreate modprobe; do
    path="$(command -v "${name}" 2>/dev/null || true)"
    if [[ -n "${path}" ]]; then
      available=true
    else
      available=false
    fi
    deps="$(jq -c \
      --arg name "${name}" \
      --arg path "${path}" \
      --argjson available "${available}" \
      '. + {($name): {available: $available, path: $path}}' \
      <<<"${deps}")"
  done
  printf '%s' "${deps}"
}

n2k_preflight_result_json() {
  local pc="$1" vm="$2" requested_mode="$3" allow_experimental="$4"
  local capability_json="$5" deps_json="$6"
  local v4_vmm_override="$7" v4_dp_override="$8" v4_data_plane_override="$9"
  local legacy_override="${10}" legacy_verified_override="${11}" cold_override="${12}" manual_override="${13}"
  local requested_storage="${14:-auto}" requested_format="${15:-qcow2}"

  jq -nc \
    --arg pc "${pc}" \
    --arg vm "${vm}" \
    --arg requested_mode "${requested_mode}" \
    --argjson allow_experimental "${allow_experimental}" \
    --argjson cap "${capability_json}" \
    --argjson deps "${deps_json}" \
    --arg v4_vmm_override "${v4_vmm_override}" \
    --arg v4_dp_override "${v4_dp_override}" \
    --arg v4_data_plane_override "${v4_data_plane_override}" \
    --arg legacy_override "${legacy_override}" \
    --arg legacy_verified_override "${legacy_verified_override}" \
    --arg cold_override "${cold_override}" \
    --arg manual_override "${manual_override}" \
    --arg requested_storage "${requested_storage}" \
    --arg requested_format "${requested_format}" \
    '
    def truthy:
      if type == "boolean" then .
      elif type == "number" then . != 0
      elif type == "string" then
        (ascii_downcase) as $s
        | (["available","true","yes","1","supported","ok"] | index($s)) != null
      else false end;

    def override_bool($raw; $fallback):
      if $raw == "auto" then $fallback
      elif $raw == "true" then true
      elif $raw == "false" then false
      else $fallback end;

    def http_success($raw):
      try (($raw | tonumber) >= 200 and ($raw | tonumber) <= 299) catch false;

    def cap_v4_vmm:
      ($cap.api.v4.vmm // $cap.v4.vmm // $cap.namespaces.vmm // false) | truthy;
    def cap_v4_dp:
      ($cap.api.v4.dataprotection // $cap.v4.dataprotection // $cap.namespaces.dataprotection // false) | truthy;
    def cap_v4_clustermgmt:
      ($cap.api.v4.clustermgmt // $cap.v4.clustermgmt // $cap.namespaces.clustermgmt // false) | truthy;
    def cap_v4_changed_regions:
      ($cap.api.v4.changed_regions // $cap.v4.changed_regions // $cap.changed_regions.v4 // cap_v4_dp) | truthy;
    def cap_v4_data_plane:
      ($cap.api.v4.data_plane // $cap.v4.data_plane // false) | truthy;
    def cap_v3_vm_snapshots:
      ($cap.api.v3.vm_snapshots // $cap.v3.vm_snapshots // $cap.api.v3.available // $cap.v3.available // false) | truthy;
    def cap_legacy_changed_regions:
      ($cap.api.legacy.changed_regions // $cap.legacy.changed_regions // $cap.changed_regions.legacy // false) | truthy;
    def cap_legacy_endpoint:
      ($cap.api.legacy.endpoint // $cap.legacy.endpoint // $cap.api.legacy.changed_regions_endpoint // $cap.legacy.changed_regions_endpoint // "");
    def cap_legacy_probe_status:
      ($cap.api.legacy.probe.status // $cap.legacy.probe.status // $cap.api.legacy.probe_status // $cap.legacy.probe_status // null);
    def cap_legacy_verified:
      (($cap.api.legacy.verified // $cap.legacy.verified // $cap.api.legacy.endpoint_verified // $cap.legacy.endpoint_verified // false) | truthy)
      or http_success(cap_legacy_probe_status)
      or (cap_legacy_changed_regions and cap_v3_vm_snapshots);
    def cap_cold_export:
      ($cap.cold_export.available // $cap.api.cold_export.available // false) | truthy;
    def cap_manual_disk:
      ($cap.manual_disk.available // true) | truthy;
    def cap_storage_rbd:
      (($cap.target.storage.rbd.available // $cap.storage.rbd.available // false) | truthy)
      or ($deps.rbd.available // false)
      or ($deps["rbd-nbd"].available // false);
    def cap_storage_file:
      (($cap.target.storage.file.available // $cap.storage.file.available // true) | truthy);
    def cap_storage_block:
      (($cap.target.storage.block.available // $cap.storage.block.available // false) | truthy)
      or ($deps.lvs.available // false)
      or ($deps.lvcreate.available // false);
    def storage_reason($name; $available):
      if $available then $name + " target storage is available or can be tested"
      else $name + " target storage is not confirmed" end;

    (override_bool($v4_vmm_override; cap_v4_vmm)) as $v4_vmm
    | (override_bool($v4_dp_override; cap_v4_dp)) as $v4_dp
    | (cap_v4_changed_regions or $v4_dp) as $v4_changed_regions
    | (override_bool($v4_data_plane_override; cap_v4_data_plane)) as $v4_data_plane
    | (cap_v3_vm_snapshots) as $v3_vm_snapshots
    | (override_bool($legacy_override; cap_legacy_changed_regions)) as $legacy_candidate
    | (override_bool($legacy_verified_override; cap_legacy_verified)) as $legacy_verified
    | (cap_legacy_endpoint) as $legacy_endpoint
    | (cap_legacy_probe_status) as $legacy_probe_status
    | (override_bool($cold_override; cap_cold_export)) as $cold_available
    | (override_bool($manual_override; cap_manual_disk)) as $manual_available
    | (cap_storage_rbd) as $rbd_available
    | (cap_storage_file) as $file_available
    | (cap_storage_block) as $block_available
    | (if $requested_storage == "auto" then
         if $rbd_available then "rbd"
         elif $file_available then "file"
         elif $block_available then "block"
         else "unavailable" end
       else $requested_storage end) as $selected_storage
    | (if $selected_storage == "rbd" then $rbd_available
       elif $selected_storage == "file" then $file_available
       elif $selected_storage == "block" then $block_available
       else false end) as $storage_available
    | ($v4_vmm and $v4_dp and $v4_changed_regions and $v4_data_plane) as $v4_incremental_available
    | ($legacy_candidate and $legacy_verified and $allow_experimental) as $legacy_available
    | (if $cold_available then "cold-export"
       elif $manual_available then "manual-disk"
       else "unavailable" end) as $fallback_mode
    | (if $v4_incremental_available then "v4-incremental"
       elif $legacy_available then "legacy-cbt"
       elif $cold_available then "cold-export"
       elif $manual_available then "manual-disk"
       else "unavailable" end) as $auto_mode
    | (if $requested_mode == "auto" then $auto_mode else $requested_mode end) as $selected_mode
    | (if $selected_mode == "v4-incremental" then $v4_incremental_available
       elif $selected_mode == "legacy-cbt" then $legacy_available
       elif $selected_mode == "cold-export" then $cold_available
       elif $selected_mode == "manual-disk" then $manual_available
       else false end) as $can_run
    | ($can_run and $storage_available) as $can_run_with_storage
    | {
        pc: $pc,
        vm: (if $vm == "" then null else $vm end),
        requested_mode: $requested_mode,
        allow_experimental: $allow_experimental,
        recommended_mode: $auto_mode,
        selected_mode: $selected_mode,
        can_run: $can_run_with_storage,
        mode_can_run: $can_run,
        fallback_mode: $fallback_mode,
        modes: {
          "v4-incremental": {
            available: $v4_incremental_available,
            reason: (if $v4_incremental_available then "v4 vmm and dataprotection changed regions are available" else "v4 vmm or dataprotection changed regions are unavailable" end)
          },
          "legacy-cbt": {
            candidate: $legacy_candidate,
            verified: $legacy_verified,
            available: $legacy_available,
            experimental: true,
            allow_experimental: $allow_experimental,
            endpoint: $legacy_endpoint,
            probe_status: $legacy_probe_status,
            path_source: (if $v3_vm_snapshots then "v3-vm-snapshot" else "legacy-pd-snapshot" end),
            reason: (if $legacy_available then "legacy changed-region path is enabled by explicit experimental opt-in"
                     elif ($legacy_candidate and $v3_vm_snapshots) then "legacy changed-region endpoint and v3 VM snapshot path source are available, but --allow-experimental is required"
                     elif ($legacy_candidate and ($legacy_verified | not)) then "legacy changed-region path is only a candidate and requires endpoint verification"
                     elif ($legacy_candidate and $legacy_verified) then "legacy changed-region path requires --allow-experimental"
                     else "legacy changed-region path is unavailable" end)
          },
          "cold-export": {
            available: $cold_available,
            reason: (if $cold_available then "full disk export or copy path is available" else "full disk export or copy path is not confirmed" end)
          },
          "manual-disk": {
            available: $manual_available,
            reason: (if $manual_available then "manual disk input can be used as a rescue path" else "manual disk input is disabled" end)
          }
        },
        api: {
          v4: {
            vmm: $v4_vmm,
            dataprotection: $v4_dp,
            clustermgmt: cap_v4_clustermgmt,
            changed_regions: $v4_changed_regions,
            data_plane: $v4_data_plane,
            revisions: ($cap.api.v4.revisions // $cap.v4.revisions // {}),
            probe: ($cap.api.v4.probe // $cap.v4.probe // {})
          },
          v3: {
            vm_snapshots: $v3_vm_snapshots
          },
          legacy: {
            changed_regions: $legacy_candidate,
            verified: $legacy_verified,
            endpoint: $legacy_endpoint,
            probe_status: $legacy_probe_status
          }
        },
        target: {
          requested_storage: $requested_storage,
          requested_format: $requested_format,
          selected_storage: $selected_storage,
          storage_available: $storage_available,
          storage_priority: ["rbd", "file", "block"],
          storage: {
            rbd: {available: $rbd_available, priority: 1, reason: storage_reason("rbd"; $rbd_available)},
            file: {available: $file_available, priority: 2, format: $requested_format, reason: storage_reason("file"; $file_available)},
            block: {available: $block_available, priority: 3, reason: storage_reason("block"; $block_available)}
          },
          dependencies: $deps
        },
        warnings: (
          []
          + (if $v4_vmm and $v4_dp and $v4_changed_regions and ($v4_data_plane | not) then ["v4 control-plane APIs are available, but v4 recovery-point data plane is not verified; use the validated v3 source path for E2E until data-plane support is completed"] else [] end)
          + (if $legacy_candidate and ($legacy_verified | not) then ["legacy-cbt is only a candidate because endpoint verification is missing"] else [] end)
          + (if $legacy_candidate and $legacy_verified and ($allow_experimental | not) then ["legacy-cbt is blocked because experimental mode is not enabled"] else [] end)
          + (if $selected_mode == "legacy-cbt" and ($can_run | not) and $fallback_mode != "unavailable" then ["fallback mode is " + $fallback_mode] else [] end)
          + (if ($deps["jq"].available // false | not) then ["jq is required for n2k runtime"] else [] end)
          + (if ($deps["qemu-img"].available // false | not) then ["qemu-img is required for disk conversion or image creation"] else [] end)
          + (if ($deps["virsh"].available // false | not) then ["virsh is required for target VM definition"] else [] end)
          + (if ($storage_available | not) then ["selected target storage is not available: " + $selected_storage] else [] end)
          + (if $selected_storage == "qcow2" then ["target storage value should be file with --target-format qcow2"] else [] end)
        )
      }'
}

n2k_preflight_text_summary() {
  jq -r '
    "Prism Central: " + (.pc // "") + "\n" +
    "Requested mode: " + (.requested_mode // "") + "\n" +
    "Recommended mode: " + (.recommended_mode // "") + "\n" +
    "Selected mode: " + (.selected_mode // "") + "\n" +
    "Can run selected mode: " + ((.can_run // false) | tostring) + "\n" +
    "v4 vmm: " + ((.api.v4.vmm // false) | tostring) + "\n" +
    "v4 dataprotection: " + ((.api.v4.dataprotection // false) | tostring) + "\n" +
    "v4 clustermgmt: " + ((.api.v4.clustermgmt // false) | tostring) + "\n" +
    "v4 revisions: vmm=" + (.api.v4.revisions.vmm // "") + ", dataprotection=" + (.api.v4.revisions.dataprotection // "") + ", clustermgmt=" + (.api.v4.revisions.clustermgmt // "") + "\n" +
    "v4 changed regions: " + ((.api.v4.changed_regions // false) | tostring) + "\n" +
    "v4 data plane: " + ((.api.v4.data_plane // false) | tostring) + "\n" +
    "v3 vm snapshots: " + ((.api.v3.vm_snapshots // false) | tostring) + "\n" +
    "legacy changed regions: " + ((.api.legacy.changed_regions // false) | tostring) + "\n" +
    "legacy verified: " + ((.api.legacy.verified // false) | tostring) + "\n" +
    "fallback mode: " + (.fallback_mode // "") + "\n" +
    "target storage: " + (.target.selected_storage // "") + "\n" +
    "target storage available: " + ((.target.storage_available // false) | tostring) + "\n" +
    "cold-export: " + ((.modes["cold-export"].available // false) | tostring) + "\n" +
    "manual-disk: " + ((.modes["manual-disk"].available // false) | tostring) +
    (if ((.warnings // []) | length) > 0 then
      "\nWarnings:\n" + ((.warnings // []) | map("- " + .) | join("\n"))
    else "" end)
  '
}

n2k_plan_result_json() {
  local preflight_json="$1"
  jq -c '
    . as $pf
    | {
        vm: $pf.vm,
        pc: $pf.pc,
        requested_mode: $pf.requested_mode,
        recommended_mode: $pf.recommended_mode,
        selected_mode: $pf.selected_mode,
        can_run: $pf.can_run,
        fallback_mode: ($pf.fallback_mode // "unavailable"),
        target: ($pf.target // {}),
        steps: (
          if ($pf.selected_mode == "v4-incremental" and $pf.can_run) then
            ["init","preflight","inventory","prepare-target-storage","recovery-point-base","sync-base","recovery-point-incr","sync-incr","shutdown-source","recovery-point-final","sync-final","define-target","cleanup"]
          elif ($pf.selected_mode == "legacy-cbt" and $pf.can_run) then
            ["init","preflight","inventory","prepare-target-storage","legacy-base","legacy-incr","shutdown-source","legacy-final","define-target","cleanup"]
          elif ($pf.selected_mode == "cold-export" and $pf.can_run) then
            ["init","preflight","inventory","prepare-target-storage","shutdown-or-snapshot-source","sync-full-disk","define-target","cleanup"]
          elif ($pf.selected_mode == "manual-disk" and $pf.can_run) then
            ["init","prepare-manual-disk","define-target","verify"]
          else
            []
          end
        ),
        blockers: (
          if $pf.can_run then []
          elif $pf.selected_mode == "legacy-cbt" and (($pf.modes["legacy-cbt"].candidate // false) | not) then ["legacy changed-region path is not available"]
          elif $pf.selected_mode == "legacy-cbt" and (($pf.modes["legacy-cbt"].verified // false) | not) then ["legacy changed-region endpoint is not verified"]
          elif $pf.selected_mode == "legacy-cbt" and (($pf.allow_experimental // false) | not) then ["legacy-cbt requires --allow-experimental"]
          elif ($pf.target.storage_available == false) then ["selected target storage is not available"]
          else ["selected migration mode is not available in the current capability set"] end
        ),
        warnings: ($pf.warnings // []),
        capabilities: $pf
      }' <<<"${preflight_json}"
}

n2k_plan_text_summary() {
  jq -r '
    "VM: " + (.vm // "") + "\n" +
    "Prism Central: " + (.pc // "") + "\n" +
    "Selected mode: " + (.selected_mode // "") + "\n" +
    "Can run: " + ((.can_run // false) | tostring) + "\n" +
    "Fallback mode: " + (.fallback_mode // "") + "\n" +
    "Target storage: " + (.target.selected_storage // "") + "\n" +
    "Steps:\n" +
    (if ((.steps // []) | length) > 0 then ((.steps // []) | map("- " + .) | join("\n")) else "- none" end) +
    (if ((.blockers // []) | length) > 0 then "\nBlockers:\n" + ((.blockers // []) | map("- " + .) | join("\n")) else "" end) +
    (if ((.warnings // []) | length) > 0 then "\nWarnings:\n" + ((.warnings // []) | map("- " + .) | join("\n")) else "" end)
  '
}
