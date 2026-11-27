#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# Recording retention never calls Mold or changes a VM/volume's power/lifecycle state.
migration_cloud_retention_record() {
  local tool="$1" manifest="$2" rc="$3" tmp
  migration_disk_cache_handed_off "$manifest" || return 0
  tmp="$(mktemp "${manifest}.retention.XXXXXX")" || return $?
  jq --arg tool "$tool" --argjson rc "$rc" --arg now "$(date -u +%FT%TZ)" '
    (.runtime.cloud.checkpoint // {}) as $cp |
    {status:"RETAINED_UNVERIFIED",retained:true,exit_code:$rc,recorded_at:$now,
     phase:($cp.stage // "handoff"),
     reason:(if $rc==0 then "VERIFICATION_DEFERRED" else (if (.runtime.guest_configuration.status=="FAILED" or .runtime.guest_configuration.status=="DRIFT" or .runtime.guest_configuration.status=="TIMED_OUT") then (.runtime.guest_configuration.reason // .runtime.guest_configuration.status) else "CUTOVER_OR_VERIFICATION_FAILED" end) end),
     vm_id:($cp.vm_id // null),root_volume_id:($cp.root_volume_id // null),
     data_volumes:($cp.data_volumes // {}),
     pending_jobs:{root_import_job_id:$cp.root_import_job_id,deploy_job_id:$cp.deploy_job_id},
     resume:{tool:$tool,manifest:input_filename,action:"resume the same workdir and original policy; do not initialize a new job"}} as $event |
    .runtime.cloud.retention = ((.runtime.cloud.retention // {}) + $event) |
    .runtime.cloud.retention.events = ((.runtime.cloud.retention.events // []) + [$event]) |
    .runtime.cloud.checkpoint += {complete:false,inspection_required:true} |
    .runtime.cloud += {complete:false,validated:false,inspection_required:true,status:"retained_unverified"}
  ' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest" || return $?
  jq -c '.runtime.cloud.retention | {status,exit_code,phase,reason,vm_id,root_volume_id,data_volumes,resume}' "$manifest" >&2
}
migration_cloud_retention_resolve() {
  local manifest="$1" tmp
  jq -e '.runtime.cloud.retention.retained == true' "$manifest" >/dev/null || return 0
  tmp="$(mktemp "${manifest}.retention-resolved.XXXXXX")" || return $?
  jq --arg now "$(date -u +%FT%TZ)" '.runtime.cloud.retention += {status:"RESOLVED",retained:false,resolved_at:$now}' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
}
migration_cloud_retention_cutover() {
  local tool="$1" manifest="$2" rc=0 output
  shift 2
  # Validate frozen options before any remote mutation. Old sealed manifests remain unchanged.
  migration_disk_cache_configure "$tool" "$manifest" || return $?
  output="$(mktemp "${manifest}.cutover-output.XXXXXX")" || return $?
  if "${tool}_cloud_target_cutover_impl" "$manifest" "$@" > "$output"; then
    if migration_disk_cache_handed_off "$manifest"; then
      if jq -e '.runtime.cloud.checkpoint.complete==true and .runtime.cloud.checkpoint.started==true and .runtime.cloud.validated==true and .runtime.cloud.inspection_required!=true' "$manifest" >/dev/null; then
        migration_cloud_retention_resolve "$manifest" || rc=$?
      else
        migration_cloud_retention_record "$tool" "$manifest" 0 || rc=$?
        # A deliberate define-only/off run is successful, but never verified.
        jq -c '.runtime.cloud' "$manifest" > "$output" || rc=$?
      fi
    fi
  else
    rc=$?
    migration_cloud_retention_record "$tool" "$manifest" "$rc" || echo 'MOLD_RETENTION_RECORD_FAILED: inspect the unchanged Mold resources' >&2
  fi
  cat -- "$output"
  rm -f -- "$output"
  return "$rc"
}
