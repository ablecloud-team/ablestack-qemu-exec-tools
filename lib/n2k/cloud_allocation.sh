#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# Standalone per-tool bundle; keep both copies identical (checked by tests).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/preallocation.sh"

migration_cloud_allocation_error() { printf 'Cloud allocation: %s\n' "$*" >&2; return 2; }

# Resolver API consumed by the Cloud transport and wizard.
# shellcheck disable=SC2034
migration_cloud_allocation_intent() {
  local manifest="$1"
  CLOUD_ALLOCATION_ACTIVE=0 CLOUD_ALLOCATION_MODE='' CLOUD_ALLOCATION_FORMAT='' CLOUD_ALLOCATION_COPY=false
  [[ -n "$manifest" && -f "$manifest" ]] || return 0
  if ! jq -e '.target.provider == "ablestack-cloud" and .target.storage.type == "file"
      and (.target.storage | has("preallocation")) and .target.storage.preallocation != null
      and (.target.storage.preallocation_source // "") != "legacy"' "$manifest" >/dev/null; then return 0; fi
  image_preallocation_from_manifest "$manifest" || return $?
  CLOUD_ALLOCATION_ACTIVE=1 CLOUD_ALLOCATION_MODE="$IMAGE_PREALLOCATION_MODE"
  CLOUD_ALLOCATION_FORMAT="$(jq -r '.target.format' "$manifest")"
  CLOUD_ALLOCATION_COPY="$(jq -r '.target.cloud.allocation_allow_copy // false' "$manifest")"
}

migration_cloud_allocation_allow_copy() {
  local manifest="$1" allow="$2" tmp
  [[ "$allow" == 1 ]] || return 0
  tmp="$(mktemp "${manifest}.cloud-allocation.XXXXXX")" || return $?
  jq '.target.cloud.allocation_allow_copy = true' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
}

migration_cloud_allocation_copy_choice() {
  local tool="$1" provider="$2" storage="$3" mode="$4" manifest="$5" allow="$6" yes="$7" print_only="$8"
  CLOUD_ALLOCATION_COPY_CHOICE="$allow"
  if [[ -f "$manifest" ]] && jq -e '.target.cloud.allocation_allow_copy == true' "$manifest" >/dev/null; then CLOUD_ALLOCATION_COPY_CHOICE=1; fi
  [[ "$provider" == ablestack-cloud && "$storage" == file && ( "$mode" == metadata || "$mode" == full ) ]] || return 0
  [[ "$CLOUD_ALLOCATION_COPY_CHOICE" != 1 ]] || return 0
  if [[ "$yes" == 0 && "$print_only" == 0 ]] && "${tool}_interactive_has_tty" &&
      "${tool}_interactive_prompt_confirm" 'Allow a verified offline Mold allocation copy (extra space and I/O; source is preserved)' no; then
    CLOUD_ALLOCATION_COPY_CHOICE=1; return 0
  fi
  migration_cloud_allocation_error 'metadata/full Mold import requires explicit --cloud-allocation-copy; choose off/falloc to use qualified adoption'
}

migration_cloud_allocation_preflight() {
  local tool="$1" manifest="$2" endpoint="$3" key="$4" secret="$5" cfg="$6" params response capability tmp
  migration_cloud_allocation_intent "$manifest" || return $?
  [[ "$CLOUD_ALLOCATION_ACTIVE" == 1 ]] || return 0
  if [[ ( "$CLOUD_ALLOCATION_MODE" == metadata || "$CLOUD_ALLOCATION_MODE" == full ) && "$CLOUD_ALLOCATION_COPY" != true ]]; then
    migration_cloud_allocation_error 'metadata/full requires --cloud-allocation-copy before migration'; return 2
  fi
  params="$(jq -nc --argjson cfg "$cfg" --arg policy "$CLOUD_ALLOCATION_MODE" --arg format "$CLOUD_ALLOCATION_FORMAT" '
    {storageid:$cfg.storage_id,allocationpolicy:$policy,allocationformat:$format,operation:"import"}
    + (if (($cfg.host_id // "") | length) > 0 then {hostid:$cfg.host_id} else {} end)')"
  response="$("${tool}_cloud_api_get" "$endpoint" "$key" "$secret" getVolumeAllocationCapabilities "$params")" || {
    migration_cloud_allocation_error 'ALLOCATION_IMPORT_UNSUPPORTED: Mold/Agent capability could not be verified'; return 2;
  }
  capability="$(jq -c '.getvolumeallocationcapabilitiesresponse.volumeallocationcapability // {}' <<< "$response")" || return $?
  if ! jq -e --arg policy "$CLOUD_ALLOCATION_MODE" --arg format "$CLOUD_ALLOCATION_FORMAT" --argjson cfg "$cfg" '
      .supported == true and .contractversion == 1 and .backend == "GFS2" and .operation == "import"
      and .storageid == $cfg.storage_id and .allocationformat == $format
      and .agentpolicies[$policy] == (if $policy == "off" or $policy == "falloc" then "import-adopt-" + $policy else "import-copy-qemu-preallocation-" + $policy end)' <<< "$capability" >/dev/null; then
    printf '%s\n' "$capability" >&2
    migration_cloud_allocation_error 'ALLOCATION_IMPORT_UNSUPPORTED: no qualified end-to-end import contract'; return 2
  fi
  tmp="$(mktemp "${manifest}.cloud-allocation.XXXXXX")" || return $?
  # A worker UUID is a probe observation, never a placement or future authority binding.
  jq --argjson capability "$capability" '.target.cloud.allocation_capability = $capability' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
}

migration_cloud_allocation_offering_params() {
  local manifest="$1" params="$2"
  migration_cloud_allocation_intent "$manifest" || return $?
  if [[ "$CLOUD_ALLOCATION_ACTIVE" != 1 ]]; then printf '%s' "$params"; return; fi
  jq -c --arg policy "$CLOUD_ALLOCATION_MODE" --arg format "$CLOUD_ALLOCATION_FORMAT" \
    'del(.provisioningtype) + {allocationpolicy:$policy,allocationformat:$format}' <<< "$params"
}

migration_cloud_allocation_validate_offering() {
  local tool="$1" manifest="$2" endpoint="$3" key="$4" secret="$5" offering_id="$6" storage_type="$7" response offering
  migration_cloud_allocation_intent "$manifest" || return $?
  [[ "$CLOUD_ALLOCATION_ACTIVE" == 1 ]] || return 0
  response="$("${tool}_cloud_api_get" "$endpoint" "$key" "$secret" listDiskOfferings "$(jq -nc --arg id "$offering_id" '{id:$id,listall:true}')")" || return $?
  offering="$(jq -c '(.listdiskofferingsresponse.diskoffering // [])[0] // {}' <<< "$response")" || return $?
  if ! jq -e --arg id "$offering_id" --arg policy "$CLOUD_ALLOCATION_MODE" --arg format "$CLOUD_ALLOCATION_FORMAT" --arg st "$storage_type" '
      .id == $id and .allocation.requestedpolicy == $policy and .allocation.requestedformat == $format
      and (.allocation.contractversion | tostring) == "1" and .allocation.policyorigin == "explicit"
      and ((.storagetype // "") | ascii_downcase) == $st and ((.cachemode // "") | ascii_downcase) == "writeback"
      and ((.state // "Active") | ascii_downcase) == "active" and (.iscustomized // .customized // false) == true
      and ((.tags // "") | tostring | length) == 0' <<< "$offering" >/dev/null; then
    migration_cloud_allocation_error "ALLOCATION_POLICY_MISMATCH: disk offering $offering_id does not preserve requested policy/format/storage/writeback"; return 2
  fi
}

migration_cloud_allocation_import_params() {
  local manifest="$1" idx="$2" params="$3" existing request_id tmp
  migration_cloud_allocation_intent "$manifest" || return $?
  if [[ "$CLOUD_ALLOCATION_ACTIVE" != 1 ]]; then printf '%s' "$params"; return; fi
  existing="$(jq -c --argjson idx "$idx" '.disks[$idx].transfer.cloud_allocation // {}' "$manifest")"
  request_id="$(jq -r '.request_id // empty' <<< "$existing")"
  if [[ -n "$request_id" ]]; then
    if ! jq -e --arg policy "$CLOUD_ALLOCATION_MODE" --arg format "$CLOUD_ALLOCATION_FORMAT" \
        '.policy == $policy and .format == $format and (.request_id | test("^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$"))' <<< "$existing" >/dev/null; then
      migration_cloud_allocation_error 'ALLOCATION_POLICY_MISMATCH: import checkpoint intent changed'; return 2
    fi
  else
    request_id="$(cat /proc/sys/kernel/random/uuid)"
    tmp="$(mktemp "${manifest}.cloud-allocation.XXXXXX")" || return $?
    jq --argjson idx "$idx" --arg id "$request_id" --arg policy "$CLOUD_ALLOCATION_MODE" --arg format "$CLOUD_ALLOCATION_FORMAT" \
      '.disks[$idx].transfer.cloud_allocation = {request_id:$id,policy:$policy,format:$format,verified:false}' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
  fi
  jq -c --arg id "$request_id" --arg policy "$CLOUD_ALLOCATION_MODE" --arg format "$CLOUD_ALLOCATION_FORMAT" --argjson copy "$CLOUD_ALLOCATION_COPY" \
    '. + {allocationpolicy:$policy,allocationformat:$format,allocationcontractversion:1,allocationrequestid:$id,allocationallowcopy:$copy}' <<< "$params"
}

migration_cloud_allocation_verify_final() {
  local tool="$1" manifest="$2" endpoint="$3" key="$4" secret="$5" count idx id request response volume vm records='[]' tmp
  migration_cloud_allocation_intent "$manifest" || return $?
  [[ "$CLOUD_ALLOCATION_ACTIVE" == 1 ]] || return 0
  vm="$(jq -r '.runtime.cloud.checkpoint.vm_id // empty' "$manifest")"
  [[ -n "$vm" ]] || { migration_cloud_allocation_error 'ALLOCATION_EVIDENCE_REQUIRED: deployed VM identity missing'; return 2; }
  count="$(jq -r '.disks | length' "$manifest")"
  for ((idx=0;idx<count;idx++)); do
    request="$(jq -r --argjson idx "$idx" '.disks[$idx].transfer.cloud_allocation.request_id // empty' "$manifest")"
    id="$(jq -r --arg idx "$idx" 'if $idx == "0" then .runtime.cloud.checkpoint.root_volume_id // empty else .runtime.cloud.checkpoint.data_volumes[$idx].id // empty end' "$manifest")"
    [[ -n "$request" && "$request" == "$id" ]] || { migration_cloud_allocation_error 'ALLOCATION_EVIDENCE_REQUIRED: final volume does not match stable import identity'; return 2; }
    response="$("${tool}_cloud_api_get" "$endpoint" "$key" "$secret" verifyImportedVolumeAllocation \
      "$(jq -nc --arg id "$id" --arg policy "$CLOUD_ALLOCATION_MODE" --arg format "$CLOUD_ALLOCATION_FORMAT" --arg request "$request" \
        '{id:$id,allocationpolicy:$policy,allocationformat:$format,allocationrequestid:$request}')")" || return $?
    volume="$(jq -c '.verifyimportedvolumeallocationresponse.volume // .verifyimportedvolumeallocationresponse // {}' <<< "$response")" || return $?
    if ! jq -e --arg id "$id" --arg policy "$CLOUD_ALLOCATION_MODE" --arg format "$CLOUD_ALLOCATION_FORMAT" --arg vm "$vm" --argjson idx "$idx" --arg storage "$(jq -r '.target.cloud.storage_id' "$manifest")" --argjson copy "$CLOUD_ALLOCATION_COPY" '
        .id == $id and .state == "Ready" and (.path | length) > 0 and .storageid == $storage
        and .virtualmachineid == $vm and (.deviceid | tonumber) == $idx
        and .type == (if $idx == 0 then "ROOT" else "DATADISK" end)
        and .allocation.importpool == $storage and .allocation.importpath == .path
        and ((.cachemode // "") | ascii_downcase) == "writeback"
        and (.allocation.contractversion | tostring) == "1" and .allocation.policyorigin == "explicit"
        and .allocation.requestedpolicy == $policy and .allocation.requestedformat == $format and .allocation.actualformat == $format
        and .allocation.fixedpolicy == $policy and .allocation.effectivepolicy == $policy and .allocation.evidence == "verified"
        and .allocation.appliedbackend == "GFS2" and .allocation.importrequestid == $id
        and (.allocation.importidentity | test("^[a-f0-9]{64}$")) and (.allocation.importverifiedat | length) > 0
        and ((.allocation.importstrategy == "adopt" and .allocation.appliedoperation == "import" and
             .allocation.appliedmethod == ("import-adopt-" + $policy) and .allocation.evidencescope == "import-time")
          or ($copy == true and .allocation.importstrategy == "copy" and .allocation.appliedoperation == "copy" and
              .allocation.appliedmethod == ("qemu-preallocation-" + $policy) and .allocation.evidencescope == "creation-or-copy-time"))
        and (if $policy == "falloc" or $policy == "full" then (.allocation.observedallocatedbytes | tonumber) >= .size else true end)' <<< "$volume" >/dev/null; then
      printf '%s\n' "$volume" >&2
      migration_cloud_allocation_error "ALLOCATION_POLICY_MISMATCH: final volume $id is not verified"; return 2
    fi
    records="$(jq -nc --argjson records "$records" --argjson volume "$volume" --argjson idx "$idx" \
      '$records + [{index:$idx,volume_id:$volume.id,path:$volume.path,allocation:$volume.allocation,verified:true,scope:(if ($volume.allocation.importstartedat // "") != "" then "historical-first-start" else "pre-first-start" end)}]')"
  done
  tmp="$(mktemp "${manifest}.cloud-allocation.XXXXXX")" || return $?
  jq --argjson records "$records" '
    .runtime.cloud.allocation = {strict:true,verified:true,disks:$records,scope:(if any($records[]; .scope == "historical-first-start") then "historical-first-start" else "pre-first-start" end)}
    | reduce $records[] as $record (. ; .disks[$record.index].transfer.cloud_allocation += $record)
    | .runtime.cloud.checkpoint.allocation_verified = true' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
}

migration_cloud_allocation_check_manifest() {
  local tool="$1" manifest="$2" endpoint="${3:-}" key="${4:-}" secret="${5:-}" cred="${6:-}" runtime cfg offering pool
  migration_cloud_allocation_intent "$manifest" || return $?
  [[ "$CLOUD_ALLOCATION_ACTIVE" == 1 ]] || return 0
  if [[ "$tool" == v2k && "${V2K_DRY_RUN:-0}" == 1 || "$tool" == n2k && "${N2K_DRY_RUN:-0}" == 1 ]]; then return 0; fi
  runtime="$("${tool}_cloud_target_resolve_runtime_json" "$manifest" "$endpoint" "$key" "$secret" "$cred")" || return $?
  cfg="$("${tool}_cloud_target_required_config_json" "$manifest")" || return $?
  endpoint="$(jq -r '.endpoint' <<< "$runtime")"; key="$(jq -r '.api_key' <<< "$runtime")"; secret="$(jq -r '.secret_key' <<< "$runtime")"
  migration_cloud_allocation_preflight "$tool" "$manifest" "$endpoint" "$key" "$secret" "$cfg" || return $?
  offering="$(jq -r '.disk_offering_id // empty' <<< "$cfg")"
  if [[ -n "$offering" ]]; then
    pool="$("${tool}_cloud_target_storage_pool_json" "$endpoint" "$key" "$secret" "$(jq -r '.storage_id' <<< "$cfg")")" || return $?
    migration_cloud_allocation_validate_offering "$tool" "$manifest" "$endpoint" "$key" "$secret" "$offering" \
      "$("${tool}_cloud_target_disk_offering_storage_type_from_pool" "$pool")" || return $?
  fi
}
