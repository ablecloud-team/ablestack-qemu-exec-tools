#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.

n2k_cloud_handoff_started() {
  [[ -f "$1" ]] || return 1
  local status=0
  jq -e '
    ((.runtime.cloud.checkpoint.root_volume_id // "") | tostring | length) > 0
    or ((.runtime.cloud.checkpoint.root_import_job_id // "") | tostring | length) > 0
    or ((.runtime.cloud.checkpoint.deploy_job_id // "") | tostring | length) > 0
    or ((.runtime.cloud.checkpoint.vm_id // "") | tostring | length) > 0
    or ((.runtime.cloud.checkpoint.data_volumes // {}) | length) > 0
    or any(.disks[]?; ((.transfer.cloud_allocation.request_id // "") | tostring | length) > 0)
  ' "$1" >/dev/null || status=$?
  # An unreadable or malformed manifest must never reopen the byte plane.
  [[ "$status" != 1 ]]
}

n2k_cloud_require_unmanaged_target() {
  if n2k_cloud_handoff_started "$1"; then
    echo 'CLOUD_TARGET_SEALED: resume Mold deployment; source sync and offline preparation cannot write handed-off images' >&2
    return 44
  fi
}
