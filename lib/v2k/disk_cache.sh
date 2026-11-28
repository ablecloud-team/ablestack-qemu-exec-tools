#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# Shared policy, kept byte-identical in both packages.
migration_disk_cache_handed_off() {
  [[ -f "$1" ]] || return 1
  local rc=0
  jq -e '((.runtime.cloud.checkpoint.root_volume_id // "")|length)>0 or ((.runtime.cloud.checkpoint.vm_id // "")|length)>0 or ((.runtime.cloud.checkpoint.data_volumes // {})|length)>0 or any(.disks[]?; ((.transfer.cloud_allocation.request_id // "")|length)>0)' "$1" >/dev/null || rc=$?
  [[ "$rc" != 1 ]]
}
migration_disk_cache_enum() {
  case "$1" in none|writeback) return 0;; *) echo 'Expected --target-disk-cache none|writeback' >&2; return 44;; esac
}
migration_disk_cache_resolve() {
  local tool="$1" manifest="${2:-}" new="${3:-0}" var stored="" requested="" sealed=0 provider=libvirt
  var="${tool^^}_TARGET_DISK_CACHE";requested="${!var:-}"
  if [[ -n "$manifest" && -f "$manifest" ]]; then
    provider="$(jq -r '.target.provider // "libvirt"' "$manifest")" || return 44
    stored="$(jq -r '.target.storage.cache_mode // .target.cloud.resolved_disk_offering.cache_mode // empty' "$manifest")" || return 44
    if migration_disk_cache_handed_off "$manifest"; then sealed=1; fi
    if [[ -z "$stored" && "$new" != 1 ]]; then
      if [[ "$provider" == ablestack-cloud ]]; then stored=writeback; else stored=none; fi
    fi
  fi
  [[ -z "$requested" ]] || migration_disk_cache_enum "$requested" || return $?
  [[ -z "$stored" ]] || migration_disk_cache_enum "$stored" || return $?
  if [[ "$sealed" == 1 && -n "$requested" && "$requested" != "$stored" ]]; then
    echo 'TARGET_CACHE_POLICY_FROZEN: resume the original cache policy after handoff' >&2; return 44
  fi
  MIGRATION_DISK_CACHE_MODE="${requested:-${stored:-none}}"
  MIGRATION_DISK_CACHE_SOURCE=default
  if [[ -n "$requested" ]]; then MIGRATION_DISK_CACHE_SOURCE=cli
  elif [[ -n "$stored" ]]; then MIGRATION_DISK_CACHE_SOURCE=manifest; fi
}
migration_disk_cache_value() {
  migration_disk_cache_resolve "$@" || return $?
  printf '%s' "$MIGRATION_DISK_CACHE_MODE"
}
migration_disk_cache_configure() {
  local tool="$1" manifest="$2" new="${3:-0}" tmp
  migration_disk_cache_resolve "$tool" "$manifest" "$new" || return $?
  migration_disk_cache_handed_off "$manifest" && return 0
  tmp="$(mktemp "${manifest}.cache-policy.XXXXXX")" || return $?
  jq --arg mode "$MIGRATION_DISK_CACHE_MODE" --arg source "$MIGRATION_DISK_CACHE_SOURCE" \
    '.target.storage.cache_mode=$mode | .target.storage.cache_source=$source' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
}
migration_disk_cache_wizard() {
  local tool="$1" manifest="$2" yes="$3" preview="$4" mode var default_index=1
  mode="$(migration_disk_cache_value "$tool" "$manifest")" || return $?
  var="${tool^^}_TARGET_DISK_CACHE"
  if [[ -z "${!var:-}" && "$yes" == 0 && "$preview" == 0 ]] && ! migration_disk_cache_handed_off "$manifest" && "${tool}_interactive_has_tty"; then
    [[ "$mode" != writeback ]] || default_index=2
    mode="$("${tool}_interactive_select_tsv" 'target disk cache' $'none\tNo host page cache (default)\nwriteback\tWriteback host page cache' '' 0 "$default_index")" || return $?
  fi
  migration_disk_cache_enum "$mode" || return $?
  printf -v "$var" '%s' "$mode";export "${var?}"
  # Validate a frozen manifest without changing it.
  migration_disk_cache_resolve "$tool" "$manifest" || return $?
  printf '  Target disk cache: %s\n' "$mode" >&2
}
migration_disk_cache_verify_cloud() {
  local tool="$1" manifest="$2" endpoint="$3" key="$4" secret="$5" expected vm count idx id response volume records='[]' tmp
  expected="$(migration_disk_cache_value "$tool" "$manifest")" || return $?
  vm="$(jq -r '.runtime.cloud.checkpoint.vm_id // empty' "$manifest")";count="$(jq -r '.disks|length' "$manifest")"
  [[ -n "$vm" ]] || return 44
  for ((idx=0;idx<count;idx++)); do
    id="$(jq -r --arg i "$idx" 'if $i=="0" then .runtime.cloud.checkpoint.root_volume_id // empty else .runtime.cloud.checkpoint.data_volumes[$i].id // empty end' "$manifest")"
    [[ -n "$id" ]] || return 44
    response="$("${tool}_cloud_api_get" "$endpoint" "$key" "$secret" listVolumes "$(jq -nc --arg id "$id" '{id:$id,listall:true}')")" || return $?
    volume="$(jq -c '(.listvolumesresponse.volume // [])[0] // {}' <<<"$response")" || return $?
    jq -e --arg id "$id" --arg vm "$vm" --arg cache "$expected" --argjson idx "$idx" \
      '.id==$id and .virtualmachineid==$vm and .state=="Ready" and (.deviceid|tonumber)==$idx and ((.cachemode // "")|ascii_downcase)==$cache' <<<"$volume" >/dev/null || { echo "TARGET_CACHE_POLICY_MISMATCH: volume $id expected $expected" >&2; return 78; }
    records="$(jq -nc --argjson a "$records" --arg id "$id" --arg cache "$expected" '$a+[{volume_id:$id,cache_mode:$cache,verified:true}]')"
  done
  tmp="$(mktemp "${manifest}.cache-evidence.XXXXXX")" || return $?
  jq --arg cache "$expected" --argjson records "$records" '.runtime.cloud.cache={requested:$cache,verified:true,volumes:$records}' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
}
