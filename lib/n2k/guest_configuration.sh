#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.

n2k_guest_config_python() {
  local name
  for name in APPLIANCE NATIVE CACHE VIRTIO_ROOT UBUNTU_ASSETS ROCKY_ASSETS WINDOWS_DRIVERS; do
    local from="N2K_GUEST_CONFIG_${name}" to="V2K_GUEST_CONFIG_${name}"
    [[ -z "${!from:-}" ]] || export "$to=${!from}"
  done
 "${N2K_POLICY_PYTHON_BIN:-/usr/bin/python3}" "${N2K_MIGRATION_LIB_DIR}/$1" "${@:2}"; }
n2k_guest_config_policy() { case "$1" in preserve|off) return 0;; *) echo 'Expected --guest-config-policy preserve|off' >&2; return 44;; esac; }
n2k_guest_config_timeout_validate() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 1800 ]] || { echo 'Expected --guest-config-timeout 1..1800' >&2; return 44; }
}
n2k_guest_config_frozen_options() {
  local manifest="$1" expected=off
  n2k_cloud_handoff_started "$manifest" || return 0
  if jq -e '.target.guest_configuration_plan.version==1' "$manifest" >/dev/null; then expected=preserve; fi
  [[ -z "${N2K_GUEST_CONFIG_POLICY:-}" || "$N2K_GUEST_CONFIG_POLICY" == "$expected" ]] || { echo 'GUEST_CONFIG_FROZEN_POLICY' >&2; return 44; }
}
n2k_guest_config_credentials_fd() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 44
  IFS= read -r N2K_SOURCE_GUEST_PASSWORD <&"$1" || return 44
  export N2K_SOURCE_GUEST_PASSWORD
}
n2k_guest_config_configure() {
  local manifest="$1" default="${2:-}" policy tmp
  if n2k_cloud_handoff_started "$manifest"; then return 0; fi
  policy="${N2K_GUEST_CONFIG_POLICY:-$(jq -r '.target.guest_config_policy // empty' "$manifest")}"
  [[ -n "$policy" ]] || policy="$default"
  [[ -n "$policy" ]] || return 0
  n2k_guest_config_policy "$policy" || return $?
  n2k_guest_config_timeout_validate "${N2K_GUEST_CONFIG_TIMEOUT:-600}" || return $?
  if jq -e '.target.guest_configuration_plan.version==1' "$manifest" >/dev/null && [[ "$policy" != preserve ]]; then echo 'GUEST_CONFIG_FROZEN_POLICY' >&2; return 44; fi
  if [[ "$(jq -r '.target.provider' "$manifest")" != ablestack-cloud ]]; then
    [[ -z "${N2K_GUEST_CONFIG_POLICY:-}" || "$policy" == off ]] || { echo 'GUEST_CONFIG_TARGET_UNSUPPORTED' >&2; return 44; }
    return 0
  fi
  tmp="$(mktemp "${manifest}.guest-policy.XXXXXX")" || return $?
  jq --arg p "$policy" '.target.guest_config_policy=$p' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
  [[ "$policy" == preserve ]] || return 0
  n2k_guest_config_python guest_configuration_prepare.py preflight --manifest "$manifest" >/dev/null || return $?
}
n2k_guest_config_collect() {
  local manifest="$1" capture tmp
  [[ "$(jq -r '.target.guest_config_policy // empty' "$manifest")" == preserve ]] || return 0
  n2k_cloud_require_unmanaged_target "$manifest" || return $?
  if [[ -z "${N2K_SOURCE_GUEST_PASSWORD:-}" && -n "${N2K_SOURCE_GUEST_PASSWORD_FD:-}" ]]; then n2k_guest_config_credentials_fd "$N2K_SOURCE_GUEST_PASSWORD_FD" || return $?; fi
  if [[ -n "${N2K_GUEST_CONFIG_MAP_JSON:-}" ]]; then
    capture="$(cat -- "$N2K_GUEST_CONFIG_MAP_JSON")" || return $?
  else
    [[ -n "${N2K_SOURCE_GUEST_USER:-}" && -n "${N2K_SOURCE_GUEST_PASSWORD:-}" ]] || { echo 'SOURCE_CONFIG_REQUIRED: runtime source guest authentication or explicit state file is required' >&2; return 44; }
    capture="$("${N2K_PYTHON_BIN:-python3}" "${N2K_LIB_DIR}/nutanix_guest_configuration.py" --manifest "$manifest" --common-dir "$N2K_MIGRATION_LIB_DIR")" || return $?
  fi
  jq -e --arg vm "$(jq -r '.source.vm.uuid' "$manifest")" '.source_vm_uuid==$vm and (.capture_id|length)>0 and (.os=="linux" or .os=="windows")' <<<"$capture" >/dev/null || return 44
  printf '%s' "$capture" | n2k_guest_config_python guest_configuration.py validate-capture --manifest "$manifest" || return $?
  tmp="$(mktemp "${manifest}.guest-source.XXXXXX")" || return $?
  jq --argjson state "$capture" '.source.guest_configuration=$state' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
  # Validate OS-specific offline packages while the source is still running.
  n2k_guest_config_python guest_configuration_prepare.py preflight --manifest "$manifest" >/dev/null || return $?
  n2k_guest_config_python guest_configuration.py preview --manifest "$manifest" >&2 || return $?
}
n2k_guest_config_preflight_manifest() {
  local manifest="$1" runtime
  [[ "$(jq -r '.target.guest_config_policy // empty' "$manifest")" == preserve ]] || return 0
  runtime="$(n2k_cloud_target_resolve_runtime_json "$manifest" "${2:-}" "${3:-}" "${4:-}" "${5:-}")" || return $?
  n2k_guest_config_preflight_cloud "$manifest" "$(jq -r .endpoint <<<"$runtime")" "$(jq -r .api_key <<<"$runtime")" "$(jq -r .secret_key <<<"$runtime")"
}
n2k_guest_config_preflight_cloud() {
  local manifest="$1" endpoint="$2" key="$3" secret="$4" params response
  [[ "$(jq -r '.target.guest_config_policy // empty' "$manifest")" == preserve ]] || return 0
  params="$(jq -nc --arg storage "$(jq -r '.target.cloud.storage_id' "$manifest")" '{storageid:$storage}')"
  response="$(n2k_cloud_api_get "$endpoint" "$key" "$secret" getMigrationGuestConfigurationCapabilities "$params")" || return $?
  jq -e --arg storage "$(jq -r '.target.cloud.storage_id' "$manifest")" '.getmigrationguestconfigurationcapabilitiesresponse.migrationguestconfigurationcapability as $c | $c.contractversion==1 and $c.supported==true and $c.storageid==$storage' <<<"$response" >/dev/null || { echo 'GUEST_CONFIG_WORKER_UNSUPPORTED' >&2; return 44; }
}
n2k_guest_config_stage() {
  local manifest="$1" count idx path format size mode
  [[ "$(jq -r '.target.guest_config_policy // empty' "$manifest")" == preserve ]] || return 0
  n2k_cloud_require_unmanaged_target "$manifest" || return $?
  n2k_guest_config_python guest_configuration_prepare.py prepare --manifest "$manifest" >/dev/null || return $?
  count="$(jq -r '.disks|length' "$manifest")";format="$(jq -r '.target.format' "$manifest")";mode="$(jq -r '.target.storage.preallocation' "$manifest")"
  for ((idx=0;idx<count;idx++)); do
    path="$(jq -r --argjson i "$idx" '.disks[$i].transfer.target_path' "$manifest")";size="$(jq -r --argjson i "$idx" '.disks[$i].size_bytes' "$manifest")"
    image_preallocation_verify "$manifest" "$idx" "$path" "$format" "$size" "$mode" guest-config-preparation || return $?
  done
}
n2k_guest_config_reconcile() {
  local manifest="$1" endpoint="$2" key="$3" secret="$4" phase="$5" response params status end now timeout tmp
  if ! jq -e '.target.guest_configuration_plan.version==1' "$manifest" >/dev/null; then
    local skipped_status=LEGACY_UNVERIFIED skipped_temp
    [[ "$(jq -r '.target.guest_config_policy // empty' "$manifest")" != off ]] || skipped_status=SKIPPED
    skipped_temp="$(mktemp "${manifest}.guest-skipped.XXXXXX")" || return $?
    jq --arg status "$skipped_status" '.runtime.guest_configuration={status:$status,verified:false}' "$manifest" > "$skipped_temp" && mv -- "$skipped_temp" "$manifest"
    return 0
  fi
  n2k_guest_config_python guest_configuration.py validate --manifest "$manifest" || return $?
  if [[ "$phase" == verify ]]; then
    n2k_cloud_target_record_checkpoint "$manifest" guest-config-pending '{"complete":false,"inspection_required":true}' || return $?
    n2k_cloud_target_record_result "$manifest" '{"complete":false,"validated":false,"guest_configuration_verified":false,"status":"guest_configuration_pending","inspection_required":true}' || return $?
  fi
  params="$(jq -nc --arg id "$(jq -r '.runtime.cloud.checkpoint.vm_id' "$manifest")" --arg hash "$(jq -r '.target.guest_configuration_plan.hash' "$manifest")" --arg operation "$(jq -r '.target.guest_configuration_plan.operation_id' "$manifest")" '{id:$id,planhash:$hash,operationid:$operation}')"
  timeout="${N2K_GUEST_CONFIG_TIMEOUT:-600}";[[ "$timeout" =~ ^[0-9]+$ && "$timeout" -ge 1 && "$timeout" -le 1800 ]] || return 44
  now="$(date +%s)";end=$((now+timeout))
  while :; do
    response="$(n2k_cloud_api_get "$endpoint" "$key" "$secret" reconcileMigratedGuestConfiguration "$params")" || return $?
    jq -e --argjson want "$params" '.reconcilemigratedguestconfigurationresponse.migrationguestconfiguration as $r | $r.contractversion==1 and $r.supported==true and $r.id==$want.id and $r.planhash==$want.planhash and $r.operationid==$want.operationid' <<<"$response" >/dev/null || return 44
    status="$(jq -r '.reconcilemigratedguestconfigurationresponse.migrationguestconfiguration.status' <<<"$response")"
    tmp="$(mktemp "${manifest}.guest-evidence.XXXXXX")" || return $?
    jq --argjson evidence "$(jq -c '.reconcilemigratedguestconfigurationresponse.migrationguestconfiguration' <<<"$response")" '.runtime.guest_configuration=((.runtime.guest_configuration // {} | del(.reason))+$evidence)' "$manifest" > "$tmp" && mv -- "$tmp" "$manifest"
    if [[ "$phase" == bind ]]; then [[ "$status" == BOUND || "$status" == VERIFIED ]] && return 0; return 44; fi
    if [[ "$status" == VERIFIED ]] && jq -e '.reconcilemigratedguestconfigurationresponse.migrationguestconfiguration.verified==true' <<<"$response" >/dev/null; then
      n2k_cloud_target_record_checkpoint "$manifest" complete '{"complete":true,"inspection_required":false}' || return $?
      n2k_cloud_target_record_result "$manifest" '{"complete":true,"validated":true,"guest_configuration_verified":true,"guest_configuration_status":"VERIFIED","status":"completed","inspection_required":false}' || return $?
      return 0
    fi
    if [[ "$status" == FAILED || "$status" == DRIFT ]]; then echo "GUEST_CONFIGURATION_$status" >&2; return 78; fi
    now="$(date +%s)";[[ "$now" -lt "$end" ]] || { echo 'GUEST_CONFIG_TIMEOUT: inspect/reconcile the same operation; source writes remain sealed' >&2; return 78; }
    sleep "${N2K_GUEST_CONFIG_POLL_SECONDS:-2}"
  done
}

# Collect authentication only at execution; command previews never execute probes.
n2k_guest_config_wizard() {
  local provider="$1" manifest="$2" yes="$3" preview="$4" sealed=0 policy
  [[ "$provider" == ablestack-cloud ]] || return 0
  if [[ -f "$manifest" ]] && n2k_cloud_handoff_started "$manifest"; then sealed=1; fi
  policy="${N2K_GUEST_CONFIG_POLICY:-}"
  if [[ -z "$policy" && -f "$manifest" ]]; then policy="$(jq -r '.target.guest_config_policy // empty' "$manifest")"; fi
  if [[ -z "$policy" && ! -f "$manifest" ]]; then policy=preserve; fi
  # Old manifests keep their old semantics until explicitly requested, before seal.
  [[ -n "$policy" ]] || { echo '  Guest configuration: legacy, unverified' >&2; return 0; }
  if [[ "$yes" == 0 && "$preview" == 0 && "$sealed" == 0 && -z "${N2K_GUEST_CONFIG_POLICY:-}" ]] && n2k_interactive_has_tty; then
    policy="$(n2k_interactive_select_tsv 'guest configuration policy' $'preserve\tRestore and verify original guest configuration\noff\tSkip automatic guest restoration (unverified)' "$policy" 0 1)" || return $?
  fi
  n2k_guest_config_policy "$policy" || return $?
  export N2K_GUEST_CONFIG_POLICY="$policy"
  printf '  Guest configuration: %s (source state will be validated before shutdown)\n' "$policy" >&2
  [[ "$policy" == preserve && "$sealed" == 0 && "$preview" == 0 && -z "${N2K_GUEST_CONFIG_MAP_JSON:-}" ]] || return 0
  if [[ -z "${N2K_SOURCE_GUEST_PASSWORD:-}" && -n "${N2K_SOURCE_GUEST_PASSWORD_FD:-}" ]]; then n2k_guest_config_credentials_fd "$N2K_SOURCE_GUEST_PASSWORD_FD" || return $?; fi
  if [[ "$yes" == 0 ]] && n2k_interactive_has_tty; then
    [[ -n "${N2K_SOURCE_GUEST_HOST:-}" ]] || N2K_SOURCE_GUEST_HOST="$(n2k_interactive_prompt_text 'Source guest SSH/WinRM address' '' 1 '')"
    export N2K_SOURCE_GUEST_HOST
    [[ -n "${N2K_SOURCE_GUEST_USER:-}" ]] || N2K_SOURCE_GUEST_USER="$(n2k_interactive_prompt_text 'Source guest administrator (separate from Prism)' '' 1 '')"
    if [[ "${N2K_SOURCE_GUEST_USER,,}" != administrator && -z "${N2K_SOURCE_GUEST_HOSTKEY_SHA256:-}" ]]; then
      local fingerprint
      fingerprint="$("${N2K_PYTHON_BIN:-python3}" "$N2K_LIB_DIR/nutanix_guest_configuration.py" --host-key-host "$N2K_SOURCE_GUEST_HOST")" || return $?
      printf 'Source SSH host %s, SHA-256 key fingerprint: %s\n' "$N2K_SOURCE_GUEST_HOST" "$fingerprint" >&2
      n2k_interactive_prompt_confirm 'Trust this source SSH key after checking the fingerprint' no || return 44
      export N2K_SOURCE_GUEST_HOSTKEY_SHA256="$fingerprint"
    fi
    [[ -n "${N2K_SOURCE_GUEST_PASSWORD:-}" ]] || N2K_SOURCE_GUEST_PASSWORD="$(n2k_interactive_prompt_secret 'Source guest password (runtime only)')"
    export N2K_SOURCE_GUEST_USER N2K_SOURCE_GUEST_PASSWORD
  fi
  [[ -n "${N2K_SOURCE_GUEST_USER:-}" && -n "${N2K_SOURCE_GUEST_PASSWORD:-}" ]] || { echo 'SOURCE_CONFIG_REQUIRED: supply runtime guest credentials or --guest-config-map-json' >&2; return 44; }
}

n2k_guest_config_source_copy_frozen() {
  jq -e '.target.provider=="ablestack-cloud" and .target.guest_config_policy=="preserve" and .phases.final_sync.done==true and (.source.guest_configuration.capture_id|length)>0' "$1" >/dev/null
}

n2k_guest_config_shutdown() {
  local manifest="$1"
  [[ "$(jq -r '.target.guest_config_policy // empty' "$manifest")" == preserve && "$(jq -r '.source.guest_configuration.os // empty' "$manifest")" == windows ]] || return 0
  "${N2K_PYTHON_BIN:-python3}" "$N2K_LIB_DIR/nutanix_guest_configuration.py" --manifest "$manifest" --common-dir "$N2K_MIGRATION_LIB_DIR" --request-shutdown || return $?
}
