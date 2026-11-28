#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# shellcheck source=/dev/null

v2k_controller_python() {
  # Policy uses only the host standard library, never the profile's VMware SDK.
  local interpreter="${V2K_POLICY_PYTHON_BIN:-/usr/bin/python3}"
  [[ -x "$interpreter" ]] || interpreter="$(command -v python3)"
  "$interpreter" "$(dirname "${BASH_SOURCE[0]}")/controller_policy.py" "$@"
}
v2k_controller_policy_enum() {
  case "${1:-}" in auto|sata|virtio-scsi|preserve) return 0;; *) echo 'Expected --target-disk-controller auto|sata|virtio-scsi|preserve' >&2; return 44;; esac
}
v2k_controller_inventory() { v2k_controller_python inventory --root "${2:-}" <<<"$1"; }
v2k_controller_prepare() {
  local manifest="$1" policy="${2:-auto}" tmp
  v2k_controller_policy_enum "$policy" || return $?
  tmp="$(mktemp "${manifest}.controller.XXXXXX")" || return $?
  if ! v2k_controller_python prepare --manifest "$manifest" --policy "$policy" > "$tmp"; then rm -f -- "$tmp"; return 44; fi
  mv -- "$tmp" "$manifest"
}
v2k_controller_validate() { v2k_controller_python validate --manifest "$1"; }
v2k_controller_cloud_preflight() {
  local manifest="$1" endpoint="$2" key="$3" secret="$4" params response
  jq -e '.target.disk_controller_plan.version == 1' "$manifest" >/dev/null || return 0
  v2k_controller_validate "$manifest" || return $?
  params="$(jq -nc --argjson c "$(jq -c '.target.cloud' "$manifest")" --argjson p "$(jq -c '.target.disk_controller_plan' "$manifest")" \
    '{storageid:$c.storage_id,machine:$p.machine,firmware:$p.firmware} + (if (($c.host_id // "") | length)>0 then {hostid:$c.host_id} else {} end)')"
  response="$(v2k_cloud_api_get "$endpoint" "$key" "$secret" getMigrationDiskControllerCapabilities "$params")" || return $?
  jq -e --arg storage "$(jq -r '.target.cloud.storage_id' "$manifest")" --argjson p "$(jq -c '.target.disk_controller_plan' "$manifest")" '
    .getmigrationdiskcontrollercapabilitiesresponse.migrationdiskcontrollercapability as $c
    | $c.contractversion == 1 and $c.supported == true and $c.storageid == $storage and $c.machine == $p.machine and $c.firmware == $p.firmware
      and all($p.disks[]; .target.bus as $bus | ($c.buses | index($bus)) != null)
  ' <<<"$response" >/dev/null || { echo 'DISK_CONTROLLER_UNSUPPORTED: no qualified live target worker' >&2; return 44; }
}
v2k_controller_cloud_verify() {
  local manifest="$1" endpoint="$2" key="$3" secret="$4" phase="$5" vm response tmp
  jq -e '.target.disk_controller_plan.version == 1' "$manifest" >/dev/null || return 0
  v2k_controller_validate "$manifest" || return $?
  vm="$(jq -r '.runtime.cloud.checkpoint.vm_id // empty' "$manifest")"
  [[ -n "$vm" ]] || return 44
  response="$(v2k_cloud_api_get "$endpoint" "$key" "$secret" verifyMigratedVirtualMachine \
    "$(jq -nc --arg id "$vm" --arg hash "$(jq -r '.target.disk_controller_plan.hash' "$manifest")" --arg plan "$(jq -c '.target.disk_controller_plan' "$manifest")" '{id:$id,planhash:$hash,controllerplan:$plan}')")" || return $?
  jq -e --arg id "$vm" --arg hash "$(jq -r '.target.disk_controller_plan.hash' "$manifest")" --arg phase "$phase" '
    .verifymigratedvirtualmachineresponse.migrationdiskcontroller as $c
    | $c.id == $id and $c.contractversion == 1 and $c.planhash == $hash and $c.verified == true
      and (if $phase == "running" then $c.scope == "running-xml" else $c.scope == "pre-first-start" or $c.scope == "running-xml" end)
  ' <<<"$response" >/dev/null || { echo 'DISK_CONTROLLER_MISMATCH: final migration controller contract unverified' >&2; return 44; }
  if [[ "$phase" == running ]] && jq -e 'any(.disks[]; .transfer.rbd_image != null)' "$manifest" >/dev/null; then
    jq -e --argjson disks "$(jq -c '.disks' "$manifest")" '
      .verifymigratedvirtualmachineresponse.migrationdiskcontroller.observation.disks as $observed
      | ($observed|length)==($disks|length) and all(range(0;$disks|length); . as $i
          | $observed[$i].rbd_access_mode=="krbd" and $observed[$i].image_id==$disks[$i].transfer.rbd_image.image_id)
    ' <<<"$response" >/dev/null || { echo 'DISK_CONTROLLER_KRBD_IMAGE_IDENTITY_MISMATCH' >&2; return 44; }
  fi
  tmp="$(mktemp "${manifest}.controller.XXXXXX")" || return $?
  jq --argjson proof "$(jq -c '.verifymigratedvirtualmachineresponse.migrationdiskcontroller' <<<"$response")" \
    '.runtime.cloud.controller_verification = $proof' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
}

v2k_controller_check_target() {
  local manifest="$1" runtime
  [[ "$(jq -r '.target.provider' "$manifest")" == ablestack-cloud ]] || return 0
  jq -e '.target.disk_controller_plan.version == 1' "$manifest" >/dev/null || return 0
  [[ "${V2K_DRY_RUN:-0}" != 1 ]] || return 0
  runtime="$(v2k_cloud_target_resolve_runtime_json "$manifest" "${2:-}" "${3:-}" "${4:-}" "${5:-}")" || return $?
  v2k_controller_cloud_preflight "$manifest" "$(jq -r .endpoint <<<"$runtime")" "$(jq -r .api_key <<<"$runtime")" "$(jq -r .secret_key <<<"$runtime")"
}
v2k_controller_resume_check() {
  local manifest="$1" policy root
  jq -e '.target.disk_controller_plan.version == 1' "$manifest" >/dev/null || return 0
  v2k_controller_validate "$manifest" || return $?
  policy="$(jq -r '.target.disk_controller_plan.policy' "$manifest")"
  root="$(jq -r '.disks[0].disk_id' "$manifest")"
  [[ -z "${V2K_TARGET_DISK_CONTROLLER:-}" || "$V2K_TARGET_DISK_CONTROLLER" == "$policy" ]] || { echo 'DISK_CONTROLLER_POLICY: requested policy differs from frozen checkpoint' >&2; return 44; }
  [[ -z "${V2K_ROOT_DISK_ID:-}" || "$V2K_ROOT_DISK_ID" == "$root" || "$V2K_ROOT_DISK_ID" == "$(jq -r '.disks[0].device_key' "$manifest")" ]] || { echo 'DISK_CONTROLLER_POLICY: root disk identity is frozen' >&2; return 44; }
}
