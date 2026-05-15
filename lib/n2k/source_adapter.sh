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

n2k_source_http_endpoint_candidate() {
  local code="${1:-000}"
  case "${code}" in
    200|201|202|204|400|401|403|405|415|422) return 0 ;;
    *) return 1 ;;
  esac
}

n2k_source_http_endpoint_verified() {
  local code="${1:-000}"
  case "${code}" in
    200|201|202|204) return 0 ;;
    *) return 1 ;;
  esac
}

n2k_source_urlencode() {
  jq -rn --arg value "${1:-}" '$value | @uri'
}

n2k_source_probe_v4() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local response="" http_code="" api_error=""
  local revision path
  local vmm=false dataprotection=false clustermgmt=false
  local vmm_revision="" dataprotection_revision="" clustermgmt_revision=""
  local vmm_http_code="000" dataprotection_http_code="000" clustermgmt_http_code="000"

  for revision in $(n2k_nutanix_v4_candidate_revisions vmm); do
    path="$(n2k_nutanix_v4_probe_path vmm "${revision}")"
    response=""
    api_error=""
    n2k_nutanix_api_request_capture GET "${pc}" "${path}" \
      "${username}" "${password}" "${insecure}" "" response http_code api_error || true
    vmm_http_code="${http_code:-000}"
    if n2k_nutanix_http_success "${http_code}"; then
      vmm=true
      vmm_revision="${revision}"
      break
    fi
  done

  for revision in $(n2k_nutanix_v4_candidate_revisions dataprotection); do
    path="$(n2k_nutanix_v4_probe_path dataprotection "${revision}")"
    response=""
    api_error=""
    n2k_nutanix_api_request_capture GET "${pc}" "${path}" \
      "${username}" "${password}" "${insecure}" "" response http_code api_error || true
    dataprotection_http_code="${http_code:-000}"
    if n2k_nutanix_http_success "${http_code}"; then
      dataprotection=true
      dataprotection_revision="${revision}"
      break
    fi
  done

  for revision in $(n2k_nutanix_v4_candidate_revisions clustermgmt); do
    path="$(n2k_nutanix_v4_probe_path clustermgmt "${revision}")"
    response=""
    api_error=""
    n2k_nutanix_api_request_capture GET "${pc}" "${path}" \
      "${username}" "${password}" "${insecure}" "" response http_code api_error || true
    clustermgmt_http_code="${http_code:-000}"
    if n2k_nutanix_http_success "${http_code}"; then
      clustermgmt=true
      clustermgmt_revision="${revision}"
      break
    fi
  done

  jq -nc \
    --argjson vmm "${vmm}" \
    --argjson dataprotection "${dataprotection}" \
    --argjson clustermgmt "${clustermgmt}" \
    --arg vmm_revision "${vmm_revision}" \
    --arg dataprotection_revision "${dataprotection_revision}" \
    --arg clustermgmt_revision "${clustermgmt_revision}" \
    --arg vmm_http_code "${vmm_http_code}" \
    --arg dataprotection_http_code "${dataprotection_http_code}" \
    --arg clustermgmt_http_code "${clustermgmt_http_code}" \
    '{
      vmm:$vmm,
      dataprotection:$dataprotection,
      clustermgmt:$clustermgmt,
      changed_regions:$dataprotection,
      data_plane:false,
      revisions:{
        vmm:$vmm_revision,
        dataprotection:$dataprotection_revision,
        clustermgmt:$clustermgmt_revision
      },
      probe:{
        vmm:{http_code:$vmm_http_code},
        dataprotection:{http_code:$dataprotection_http_code},
        clustermgmt:{http_code:$clustermgmt_http_code}
      }
    }'
}

n2k_source_power_state_normalize() {
  local state="${1:-}"
  state="$(printf '%s' "${state}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
  state="${state##_}"
  state="${state%%_}"
  case "${state}" in
    off|poweroff|poweredoff|powered_off|koff|stopped|halted) printf 'off' ;;
    on|poweron|poweredon|powered_on|kon|running) printf 'on' ;;
    acpi_shutdown|shutting_down|stopping) printf 'stopping' ;;
    "") printf 'unknown' ;;
    *) printf '%s' "${state}" ;;
  esac
}

n2k_source_power_state_is_off() {
  [[ "$(n2k_source_power_state_normalize "${1:-}")" == "off" ]]
}

n2k_source_vm_uuid_from_inventory_raw() {
  local inventory_raw="$1"
  printf '%s' "${inventory_raw}" | jq -r '
    .metadata.uuid
    // .uuid
    // .vm_id
    // .extId
    // .ext_id
    // .vm.uuid
    // .vm.ext_id
    // .status.uuid
    // empty
  '
}

n2k_source_vm_power_state_from_inventory_raw() {
  local inventory_raw="$1"
  printf '%s' "${inventory_raw}" | jq -r '
    .power_state
    // .powerState
    // .status.resources.power_state
    // .resources.power_state
    // .status.powerState
    // .vm.power_state
    // empty
  '
}

n2k_source_vm_power_transition_for_policy() {
  local policy="$1"
  case "${policy}" in
    guest) printf 'ACPI_SHUTDOWN' ;;
    poweroff) printf 'OFF' ;;
    *)
      echo "Unsupported source VM shutdown policy: ${policy}" >&2
      return 2
      ;;
  esac
}

n2k_source_compact_json_value() {
  local value="${1:-}"
  if printf '%s' "${value}" | jq -cse 'if length == 0 then {} elif length == 1 then .[0] else . end' 2>/dev/null; then
    return 0
  fi
  printf '{}'
}

n2k_source_vm_set_power_state_v2() {
  local pc="$1" username="$2" password="$3" insecure="$4" vm_uuid="$5" transition="$6"
  local response="" http_code="" api_error="" body response_json="{}"

  [[ -n "${vm_uuid}" ]] || {
    echo "VM UUID is required for Nutanix power state transition." >&2
    return 2
  }
  [[ -n "${transition}" ]] || {
    echo "Power transition is required." >&2
    return 2
  }

  body="$(jq -nc --arg transition "${transition}" '{transition:$transition}')"
  n2k_nutanix_api_request_capture POST "${pc}" "/PrismGateway/services/rest/v2.0/vms/${vm_uuid}/set_power_state" \
    "${username}" "${password}" "${insecure}" "${body}" response http_code api_error || true
  response_json="$(n2k_source_compact_json_value "${response}")"
  if ! n2k_nutanix_http_success "${http_code}"; then
    jq -nc \
      --arg status "${http_code}" \
      --arg error "${api_error}" \
      --arg vm_uuid "${vm_uuid}" \
      --arg transition "${transition}" \
      --argjson response "${response_json}" \
      '{ok:false,status:$status,error:$error,vm_uuid:$vm_uuid,transition:$transition,response:$response}'
    return 4
  fi

  jq -nc \
    --arg status "${http_code}" \
    --arg vm_uuid "${vm_uuid}" \
    --arg transition "${transition}" \
    --argjson response "${response_json}" \
    '{ok:true,status:$status,vm_uuid:$vm_uuid,transition:$transition,response:$response}'
}

n2k_source_vm_wait_power_off() {
  local pc="$1" vm="$2" username="$3" password="$4" insecure="$5" timeout_sec="$6" poll_sec="$7"
  local start now state inventory_raw normalized

  start="$(date +%s)"
  while true; do
    inventory_raw="$(n2k_nutanix_fetch_vm_inventory "${pc}" "${vm}" "${username}" "${password}" "${insecure}")"
    state="$(n2k_source_vm_power_state_from_inventory_raw "${inventory_raw}")"
    normalized="$(n2k_source_power_state_normalize "${state}")"
    if [[ "${normalized}" == "off" ]]; then
      printf '%s' "${state:-off}"
      return 0
    fi
    now="$(date +%s)"
    if [[ $((now - start)) -ge "${timeout_sec}" ]]; then
      printf '%s' "${state:-unknown}"
      return 124
    fi
    sleep "${poll_sec}"
  done
}

n2k_source_vm_poweroff_fallback() {
  local pc="$1" vm="$2" username="$3" password="$4" insecure="$5" vm_uuid="$6" before_state="$7" reason="$8" guest_response="$9" timeout_sec="${10}" poll_sec="${11}" guest_after_state="${12:-}"
  local guest_safe poweroff_response poweroff_safe final_state set_rc wait_rc

  guest_safe="$(n2k_source_compact_json_value "${guest_response:-{\"ok\":false}}")"

  set_rc=0
  poweroff_response="$(n2k_source_vm_set_power_state_v2 "${pc}" "${username}" "${password}" "${insecure}" "${vm_uuid}" "OFF")" || set_rc=$?
  poweroff_safe="$(n2k_source_compact_json_value "${poweroff_response:-{\"ok\":false}}")"
  if [[ "${set_rc}" -ne 0 ]]; then
    jq -nc \
      --arg policy "guest" \
      --arg transition "ACPI_SHUTDOWN" \
      --arg fallback_policy "poweroff" \
      --arg fallback_transition "OFF" \
      --arg fallback_reason "${reason}" \
      --arg vm_uuid "${vm_uuid}" \
      --arg before_state "${before_state}" \
      --arg after_state "${guest_after_state:-${before_state}}" \
      --argjson guest_response "${guest_safe}" \
      --argjson poweroff_response "${poweroff_safe}" \
      '{ok:false,fallback_used:true,fallback_failed:true,policy:$policy,transition:$transition,fallback_policy:$fallback_policy,fallback_transition:$fallback_transition,fallback_reason:$fallback_reason,vm_uuid:$vm_uuid,before_state:$before_state,after_state:$after_state,response:{guest:$guest_response,poweroff:$poweroff_response}}'
    return "${set_rc}"
  fi

  wait_rc=0
  final_state="$(n2k_source_vm_wait_power_off "${pc}" "${vm}" "${username}" "${password}" "${insecure}" "${timeout_sec}" "${poll_sec}")" || wait_rc=$?
  if [[ "${wait_rc}" -ne 0 ]]; then
    jq -nc \
      --arg policy "guest" \
      --arg transition "ACPI_SHUTDOWN" \
      --arg fallback_policy "poweroff" \
      --arg fallback_transition "OFF" \
      --arg fallback_reason "${reason}" \
      --arg vm_uuid "${vm_uuid}" \
      --arg before_state "${before_state}" \
      --arg after_state "${final_state}" \
      --argjson guest_response "${guest_safe}" \
      --argjson poweroff_response "${poweroff_safe}" \
      '{ok:false,timeout:true,fallback_used:true,policy:$policy,transition:$transition,fallback_policy:$fallback_policy,fallback_transition:$fallback_transition,fallback_reason:$fallback_reason,vm_uuid:$vm_uuid,before_state:$before_state,after_state:$after_state,response:{guest:$guest_response,poweroff:$poweroff_response}}'
    return "${wait_rc}"
  fi

  jq -nc \
    --arg policy "guest" \
    --arg transition "ACPI_SHUTDOWN" \
    --arg fallback_policy "poweroff" \
    --arg fallback_transition "OFF" \
    --arg fallback_reason "${reason}" \
    --arg vm_uuid "${vm_uuid}" \
    --arg before_state "${before_state}" \
    --arg after_state "${final_state:-off}" \
    --argjson guest_response "${guest_safe}" \
    --argjson poweroff_response "${poweroff_safe}" \
    '{ok:true,fallback_used:true,policy:$policy,transition:$transition,fallback_policy:$fallback_policy,fallback_transition:$fallback_transition,fallback_reason:$fallback_reason,vm_uuid:$vm_uuid,before_state:$before_state,after_state:$after_state,response:{guest:$guest_response,poweroff:$poweroff_response}}'
}

n2k_source_vm_shutdown() {
  local pc="$1" vm="$2" username="$3" password="$4" insecure="$5" policy="$6" timeout_sec="$7" poll_sec="$8"
  local inventory_raw vm_uuid before_state before_normalized transition response_json response_safe after_state set_rc wait_rc

  [[ -n "${pc}" ]] || {
    echo "Prism endpoint is required for source VM shutdown." >&2
    return 2
  }
  [[ -n "${vm}" ]] || {
    echo "VM name or UUID is required for source VM shutdown." >&2
    return 2
  }
  [[ -n "${username}" ]] || {
    echo "Source VM shutdown requires --username or --cred-file." >&2
    return 2
  }
  [[ -n "${password}" ]] || {
    echo "Source VM shutdown requires --password or --cred-file." >&2
    return 2
  }
  [[ "${timeout_sec}" =~ ^[0-9]+$ ]] || {
    echo "Invalid shutdown timeout: ${timeout_sec}" >&2
    return 2
  }
  [[ "${poll_sec}" =~ ^[0-9]+$ && "${poll_sec}" -gt 0 ]] || {
    echo "Invalid shutdown poll interval: ${poll_sec}" >&2
    return 2
  }

  transition="$(n2k_source_vm_power_transition_for_policy "${policy}")"
  inventory_raw="$(n2k_nutanix_fetch_vm_inventory "${pc}" "${vm}" "${username}" "${password}" "${insecure}")"
  vm_uuid="$(n2k_source_vm_uuid_from_inventory_raw "${inventory_raw}")"
  before_state="$(n2k_source_vm_power_state_from_inventory_raw "${inventory_raw}")"
  before_normalized="$(n2k_source_power_state_normalize "${before_state}")"
  [[ -n "${vm_uuid}" ]] || {
    echo "Could not resolve VM UUID for source shutdown: ${vm}" >&2
    return 4
  }

  if [[ "${before_normalized}" == "off" ]]; then
    jq -nc \
      --arg policy "${policy}" \
      --arg transition "${transition}" \
      --arg vm_uuid "${vm_uuid}" \
      --arg before_state "${before_state:-off}" \
      '{ok:true,already_off:true,policy:$policy,transition:$transition,vm_uuid:$vm_uuid,before_state:$before_state,after_state:$before_state,response:{}}'
    return 0
  fi

  set_rc=0
  response_json="$(n2k_source_vm_set_power_state_v2 "${pc}" "${username}" "${password}" "${insecure}" "${vm_uuid}" "${transition}")" || set_rc=$?
  if [[ "${set_rc}" -ne 0 ]]; then
    response_safe="$(n2k_source_compact_json_value "${response_json:-{\"ok\":false}}")"
    if [[ "${policy}" == "guest" ]]; then
      n2k_source_vm_poweroff_fallback "${pc}" "${vm}" "${username}" "${password}" "${insecure}" "${vm_uuid}" "${before_state}" "guest_request_failed" "${response_safe}" "${timeout_sec}" "${poll_sec}" "${before_state}"
      return $?
    fi
    jq -nc \
      --arg policy "${policy}" \
      --arg transition "${transition}" \
      --arg vm_uuid "${vm_uuid}" \
      --arg before_state "${before_state}" \
      --argjson response "${response_safe}" \
      '{ok:false,request_failed:true,policy:$policy,transition:$transition,vm_uuid:$vm_uuid,before_state:$before_state,after_state:$before_state,response:$response}'
    return "${set_rc}"
  fi
  wait_rc=0
  after_state="$(n2k_source_vm_wait_power_off "${pc}" "${vm}" "${username}" "${password}" "${insecure}" "${timeout_sec}" "${poll_sec}")" || wait_rc=$?
  if [[ "${wait_rc}" -ne 0 ]]; then
    if [[ "${policy}" == "guest" ]]; then
      n2k_source_vm_poweroff_fallback "${pc}" "${vm}" "${username}" "${password}" "${insecure}" "${vm_uuid}" "${before_state}" "guest_timeout" "${response_json}" "${timeout_sec}" "${poll_sec}" "${after_state}"
      return $?
    fi
    jq -nc \
      --arg policy "${policy}" \
      --arg transition "${transition}" \
      --arg vm_uuid "${vm_uuid}" \
      --arg before_state "${before_state}" \
      --arg after_state "${after_state}" \
      --argjson response "${response_json}" \
      '{ok:false,timeout:true,policy:$policy,transition:$transition,vm_uuid:$vm_uuid,before_state:$before_state,after_state:$after_state,response:$response}'
    return "${wait_rc}"
  fi

  jq -nc \
    --arg policy "${policy}" \
    --arg transition "${transition}" \
    --arg vm_uuid "${vm_uuid}" \
    --arg before_state "${before_state}" \
    --arg after_state "${after_state:-off}" \
    --argjson response "${response_json}" \
    '{ok:true,already_off:false,policy:$policy,transition:$transition,vm_uuid:$vm_uuid,before_state:$before_state,after_state:$after_state,response:$response}'
}

n2k_source_probe_inventory() {
  local pc="$1" vm="$2" username="$3" password="$4" insecure="$5"
  local inventory_raw="" inventory_json=""

  if [[ -z "${vm}" ]]; then
    jq -nc '{available:false,reason:"vm name was not provided",vm:null,disks:[]}'
    return 0
  fi

  if ! inventory_raw="$(n2k_nutanix_fetch_vm_inventory "${pc}" "${vm}" "${username}" "${password}" "${insecure}" 2>/dev/null)"; then
    jq -nc --arg vm "${vm}" '{available:false,reason:"vm inventory lookup failed",vm:{name:$vm},disks:[]}'
    return 0
  fi
  if ! inventory_json="$(n2k_nutanix_inventory_from_raw "${inventory_raw}" "${vm}" 2>/dev/null)"; then
    jq -nc --arg vm "${vm}" '{available:false,reason:"vm inventory normalization failed",vm:{name:$vm},disks:[]}'
    return 0
  fi

  jq -c '{available:true,vm:.vm,disks:.disks}' <<<"${inventory_json}"
}

n2k_source_probe_legacy_changed_regions() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local response="" http_code="" api_error="" candidate=false verified=false reason response_bytes

  n2k_nutanix_api_request_capture POST "${pc}" "/api/nutanix/v3/data/changed_regions" \
    "${username}" "${password}" "${insecure}" '{}' response http_code api_error || true
  response_bytes="${#response}"

  if n2k_source_http_endpoint_candidate "${http_code}"; then
    candidate=true
  fi
  if n2k_source_http_endpoint_verified "${http_code}"; then
    verified=true
  fi

  case "${http_code}" in
    200|201|202|204)
      reason="legacy changed-region endpoint accepted the probe request"
      ;;
    400|415|422)
      reason="legacy changed-region endpoint exists but requires a valid snapshot path payload"
      ;;
    401|403)
      reason="legacy changed-region endpoint exists but authentication or authorization failed"
      ;;
    405)
      reason="legacy changed-region endpoint exists but rejected the probe method"
      ;;
    404)
      reason="legacy changed-region endpoint was not found"
      ;;
    000)
      reason="legacy changed-region endpoint probe could not connect"
      ;;
    *)
      reason="legacy changed-region endpoint probe returned HTTP ${http_code}"
      ;;
  esac

  jq -nc \
    --arg endpoint "/api/nutanix/v3/data/changed_regions" \
    --arg status "${http_code}" \
    --arg reason "${reason}" \
    --arg error "${api_error}" \
    --argjson response_bytes "${response_bytes}" \
    --argjson candidate "${candidate}" \
    --argjson verified "${verified}" \
    '{
      changed_regions:$candidate,
      candidate:$candidate,
      verified:$verified,
      endpoint:$endpoint,
      probe:{status:$status,reason:$reason,error:$error,response_bytes:$response_bytes}
    }'
}

n2k_source_probe_legacy_pd_snapshots() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local pd_response="" pd_http_code="" pd_error="" snap_response="" snap_http_code="" snap_error=""
  local pd_available=false dr_available=false pd_count=0 dr_count=0

  n2k_nutanix_api_request_capture GET "${pc}" "/PrismGateway/services/rest/v2.0/protection_domains/" \
    "${username}" "${password}" "${insecure}" "" pd_response pd_http_code pd_error || true
  if n2k_nutanix_http_success "${pd_http_code}"; then
    pd_available=true
    pd_count="$(printf '%s' "${pd_response}" | jq -r '(.metadata.total_entities // .metadata.grand_total_entities // (.entities // [] | length) // 0) | tonumber' 2>/dev/null || printf '0')"
  fi

  n2k_nutanix_api_request_capture GET "${pc}" "/PrismGateway/services/rest/v2.0/protection_domains/dr_snapshots/?full_details=true&count=20" \
    "${username}" "${password}" "${insecure}" "" snap_response snap_http_code snap_error || true
  if n2k_nutanix_http_success "${snap_http_code}"; then
    dr_available=true
    dr_count="$(printf '%s' "${snap_response}" | jq -r '(.metadata.total_entities // .metadata.grand_total_entities // (.entities // [] | length) // 0) | tonumber' 2>/dev/null || printf '0')"
  fi

  jq -nc \
    --arg pd_status "${pd_http_code}" \
    --arg dr_status "${snap_http_code}" \
    --arg pd_error "${pd_error}" \
    --arg dr_error "${snap_error}" \
    --argjson pd_available "${pd_available}" \
    --argjson dr_available "${dr_available}" \
    --argjson pd_count "${pd_count}" \
    --argjson dr_count "${dr_count}" \
    '{
      protection_domains:{
        available:$pd_available,
        count:$pd_count,
        probe:{status:$pd_status,error:$pd_error}
      },
      dr_snapshots:{
        available:$dr_available,
        count:$dr_count,
        full_details:true,
        probe:{status:$dr_status,error:$dr_error}
      }
    }'
}

n2k_source_probe_v3_vm_snapshots() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local response="" http_code="" api_error="" available=false
  local body='{"kind":"vm_snapshot","length":1}'

  n2k_nutanix_api_request_capture POST "${pc}" "/api/nutanix/v3/vm_snapshots/list" \
    "${username}" "${password}" "${insecure}" "${body}" response http_code api_error || true
  if n2k_nutanix_http_success "${http_code}"; then
    available=true
  fi

  jq -nc \
    --arg endpoint "/api/nutanix/v3/vm_snapshots" \
    --arg list_endpoint "/api/nutanix/v3/vm_snapshots/list" \
    --arg status "${http_code}" \
    --arg error "${api_error}" \
    --argjson available "${available}" \
    '{
      vm_snapshots:$available,
      available:$available,
      endpoint:$endpoint,
      list_endpoint:$list_endpoint,
      probe:{status:$status,error:$error}
    }'
}

n2k_source_legacy_create_protection_domain() {
  local pc="$1" username="$2" password="$3" insecure="$4" pd_name="$5"
  local body response="" http_code="" api_error=""

  [[ -n "${pd_name}" ]] || {
    echo "Protection Domain name is required." >&2
    return 2
  }

  body="$(jq -nc --arg pd_name "${pd_name}" '{value:$pd_name,annotations:["created-by:ablestack-n2k"]}')"
  n2k_nutanix_api_request_capture POST "${pc}" "/PrismGateway/services/rest/v2.0/protection_domains/" \
    "${username}" "${password}" "${insecure}" "${body}" response http_code api_error || true
  if ! n2k_nutanix_http_success "${http_code}"; then
    echo "Protection Domain create failed: HTTP ${http_code}${api_error:+ ${api_error}}" >&2
    return 4
  fi
  printf '%s' "${response}"
}

n2k_source_legacy_get_protection_domain() {
  local pc="$1" username="$2" password="$3" insecure="$4" pd_name="$5"
  local pd_path response="" http_code="" api_error=""

  [[ -n "${pd_name}" ]] || {
    echo "Protection Domain name is required." >&2
    return 2
  }

  pd_path="$(n2k_source_urlencode "${pd_name}")"
  n2k_nutanix_api_request_capture GET "${pc}" "/PrismGateway/services/rest/v2.0/protection_domains/${pd_path}" \
    "${username}" "${password}" "${insecure}" "" response http_code api_error || true
  if ! n2k_nutanix_http_success "${http_code}"; then
    echo "Protection Domain lookup failed: HTTP ${http_code}${api_error:+ ${api_error}}" >&2
    return 4
  fi
  printf '%s' "${response}"
}

n2k_source_legacy_protect_vm() {
  local pc="$1" username="$2" password="$3" insecure="$4" pd_name="$5" vm="$6"
  local pd_path body response="" http_code="" api_error=""

  [[ -n "${pd_name}" ]] || {
    echo "Protection Domain name is required." >&2
    return 2
  }
  [[ -n "${vm}" ]] || {
    echo "VM name is required for Protection Domain membership." >&2
    return 2
  }

  pd_path="$(n2k_source_urlencode "${pd_name}")"
  body="$(jq -nc --arg vm "${vm}" '{names:[$vm],ignore_dup_or_missing_vms:true}')"
  n2k_nutanix_api_request_capture POST "${pc}" "/PrismGateway/services/rest/v2.0/protection_domains/${pd_path}/protect_vms" \
    "${username}" "${password}" "${insecure}" "${body}" response http_code api_error || true
  if ! n2k_nutanix_http_success "${http_code}"; then
    echo "Protection Domain VM attach failed: HTTP ${http_code}${api_error:+ ${api_error}}" >&2
    return 4
  fi
  printf '%s' "${response}"
}

n2k_source_legacy_create_oob_snapshot() {
  local pc="$1" username="$2" password="$3" insecure="$4" pd_name="$5"
  local retention_seconds="${6:-3600}" app_consistent="${7:-false}"
  local pd_path start_time body response="" http_code="" api_error=""

  [[ -n "${pd_name}" ]] || {
    echo "Protection Domain name is required." >&2
    return 2
  }
  case "${app_consistent}" in
    true|false) ;;
    1) app_consistent=true ;;
    0) app_consistent=false ;;
    *) echo "Invalid app_consistent value: ${app_consistent}" >&2; return 2 ;;
  esac

  pd_path="$(n2k_source_urlencode "${pd_name}")"
  start_time="$(printf '%s000000' "$(date +%s)")"
  body="$(jq -nc \
    --argjson start_time "${start_time}" \
    --argjson retention_seconds "${retention_seconds}" \
    --argjson app_consistent "${app_consistent}" \
    '{
      app_consistent:$app_consistent,
      remote_site_names:[],
      schedule_start_time_usecs:$start_time,
      snapshot_retention_time_secs:$retention_seconds
    }')"
  n2k_nutanix_api_request_capture POST "${pc}" "/PrismGateway/services/rest/v2.0/protection_domains/${pd_path}/oob_schedules" \
    "${username}" "${password}" "${insecure}" "${body}" response http_code api_error || true
  if ! n2k_nutanix_http_success "${http_code}"; then
    echo "Protection Domain OOB snapshot request failed: HTTP ${http_code}${api_error:+ ${api_error}}" >&2
    return 4
  fi
  printf '%s' "${response}"
}

n2k_source_legacy_list_pd_snapshots() {
  local pc="$1" username="$2" password="$3" insecure="$4" pd_name="$5" count="${6:-20}"
  local pd_path response="" http_code="" api_error=""

  [[ -n "${pd_name}" ]] || {
    echo "Protection Domain name is required." >&2
    return 2
  }

  pd_path="$(n2k_source_urlencode "${pd_name}")"
  n2k_nutanix_api_request_capture GET "${pc}" "/PrismGateway/services/rest/v2.0/protection_domains/${pd_path}/dr_snapshots/?full_details=true&count=${count}" \
    "${username}" "${password}" "${insecure}" "" response http_code api_error || true
  if ! n2k_nutanix_http_success "${http_code}"; then
    echo "Protection Domain snapshot lookup failed: HTTP ${http_code}${api_error:+ ${api_error}}" >&2
    return 4
  fi
  printf '%s' "${response}"
}

n2k_source_legacy_wait_pd_snapshot_count() {
  local pc="$1" username="$2" password="$3" insecure="$4" pd_name="$5" min_count="$6" timeout_seconds="${7:-180}"
  local start now response count

  start="$(date +%s)"
  while true; do
    response="$(n2k_source_legacy_list_pd_snapshots "${pc}" "${username}" "${password}" "${insecure}" "${pd_name}" 20)"
    count="$(printf '%s' "${response}" | jq -r '(.entities // []) | length')"
    if [[ "${count}" -ge "${min_count}" ]]; then
      printf '%s' "${response}"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      echo "Timed out waiting for Protection Domain snapshots: ${pd_name}" >&2
      return 4
    fi
    sleep 5
  done
}

n2k_source_legacy_latest_pd_snapshot() {
  local snapshots_json="$1"
  printf '%s' "${snapshots_json}" | jq -c '(.entities // []) | sort_by(.snapshot_create_time_usecs // 0) | last // empty'
}

n2k_source_legacy_pd_snapshot_paths_from_json() {
  local snapshot_json="$1"

  printf '%s' "${snapshot_json}" | jq -c '
    def nonempty_string($v):
      if $v == null then empty
      else ($v | tostring | select(length > 0)) end;

    def vm_handles($vm):
      [
        nonempty_string($vm.vm_handle),
        nonempty_string($vm.vm_id),
        nonempty_string($vm.consistency_group)
      ] | unique;

    def disk_path($snapshot_id; $vm; $live_path):
      ($live_path | capture("^(?<container>/[^/]+)/(?<rel>[.]acropolis/vmdisk/(?<vdisk_uuid>[^/]+))$")?) as $m
      | select($m != null)
      | {
          vdisk_uuid: $m.vdisk_uuid,
          live_path: $live_path,
          container: $m.container,
          vm_name: ($vm.vm_name // ""),
          vm_id: ($vm.vm_id // ""),
          vm_handle: ($vm.vm_handle // null),
          consistency_group: ($vm.consistency_group // ""),
          candidate_paths: (vm_handles($vm) | map($m.container + "/.snapshot/" + ($snapshot_id | tostring) + "/" + . + "/" + $m.rel))
        };

    . as $snapshot
    | ($snapshot.snapshot_id // "") as $snapshot_id
    | [
        ($snapshot.vms // [])[]? as $vm
        | ($vm.vm_files // [])[]? as $live_path
        | disk_path($snapshot_id; $vm; $live_path)
      ] as $paths
    | {
        schema:"ablestack-n2k/legacy-pd-snapshot-paths-v1",
        source_api:"legacy",
        path_status:"candidate_unverified",
        protection_domain_name:($snapshot.protection_domain_name // ""),
        snapshot_id:$snapshot_id,
        snapshot_uuid:($snapshot.snapshot_uuid // ""),
        snapshot_create_time_usecs:($snapshot.snapshot_create_time_usecs // null),
        state:($snapshot.state // ""),
        disks:(($paths | map({(.vdisk_uuid): .}) | add) // {}),
        disk_count:($paths | length)
      }'
}

n2k_source_v3_create_vm_snapshot() {
  local pc="$1" username="$2" password="$3" insecure="$4" vm_uuid="$5" name="$6"
  local retention_seconds="${7:-3600}" snapshot_type="${8:-CRASH_CONSISTENT}"
  local expiration_time_msecs body response="" http_code="" api_error=""

  [[ -n "${vm_uuid}" ]] || {
    echo "VM UUID is required for v3 VM snapshot creation." >&2
    return 2
  }
  [[ -n "${name}" ]] || {
    echo "Snapshot name is required for v3 VM snapshot creation." >&2
    return 2
  }
  [[ "${retention_seconds}" =~ ^[0-9]+$ ]] || {
    echo "Invalid v3 VM snapshot retention seconds: ${retention_seconds}" >&2
    return 2
  }
  case "${snapshot_type}" in
    CRASH_CONSISTENT|APPLICATION_CONSISTENT) ;;
    crash|crash_consistent|crash-consistent) snapshot_type="CRASH_CONSISTENT" ;;
    app|application|application_consistent|application-consistent) snapshot_type="APPLICATION_CONSISTENT" ;;
    *) echo "Invalid v3 VM snapshot type: ${snapshot_type}" >&2; return 2 ;;
  esac

  expiration_time_msecs="$(( ($(date +%s) + retention_seconds) * 1000 ))"
  body="$(jq -nc \
    --arg name "${name}" \
    --arg vm_uuid "${vm_uuid}" \
    --arg snapshot_type "${snapshot_type}" \
    --argjson expiration_time_msecs "${expiration_time_msecs}" \
    '{
      metadata:{kind:"vm_snapshot"},
      spec:{
        name:$name,
        snapshot_type:$snapshot_type,
        expiration_time_msecs:$expiration_time_msecs,
        resources:{entity_uuid:$vm_uuid}
      }
    }')"
  n2k_nutanix_api_request_capture POST "${pc}" "/api/nutanix/v3/vm_snapshots" \
    "${username}" "${password}" "${insecure}" "${body}" response http_code api_error || true
  if ! n2k_nutanix_http_success "${http_code}"; then
    echo "v3 VM snapshot create failed: HTTP ${http_code}${api_error:+ ${api_error}}" >&2
    return 4
  fi
  printf '%s' "${response}"
}

n2k_source_v3_get_vm_snapshot() {
  local pc="$1" username="$2" password="$3" insecure="$4" snapshot_uuid="$5"
  local response="" http_code="" api_error=""

  [[ -n "${snapshot_uuid}" ]] || {
    echo "VM snapshot UUID is required." >&2
    return 2
  }
  n2k_nutanix_api_request_capture GET "${pc}" "/api/nutanix/v3/vm_snapshots/${snapshot_uuid}" \
    "${username}" "${password}" "${insecure}" "" response http_code api_error || true
  if ! n2k_nutanix_http_success "${http_code}"; then
    echo "v3 VM snapshot lookup failed: HTTP ${http_code}${api_error:+ ${api_error}}" >&2
    return 4
  fi
  printf '%s' "${response}"
}

n2k_source_v3_wait_vm_snapshot() {
  local pc="$1" username="$2" password="$3" insecure="$4" snapshot_uuid="$5" timeout_seconds="${6:-180}"
  local start now response state file_count

  start="$(date +%s)"
  while true; do
    response="$(n2k_source_v3_get_vm_snapshot "${pc}" "${username}" "${password}" "${insecure}" "${snapshot_uuid}")"
    state="$(printf '%s' "${response}" | jq -r '.status.state // ""')"
    file_count="$(printf '%s' "${response}" | jq -r '(.status.snapshot_file_list // []) | length')"
    if [[ "${state}" == "COMPLETE" && "${file_count}" -gt 0 ]]; then
      printf '%s' "${response}"
      return 0
    fi
    case "${state}" in
      ERROR|FAILED|FAILURE)
        echo "v3 VM snapshot failed: ${snapshot_uuid}" >&2
        return 4
        ;;
    esac
    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      echo "Timed out waiting for v3 VM snapshot: ${snapshot_uuid}" >&2
      return 4
    fi
    sleep 2
  done
}

n2k_source_v3_delete_vm_snapshot() {
  local pc="$1" username="$2" password="$3" insecure="$4" snapshot_uuid="$5"
  local response="" http_code="" api_error=""

  [[ -n "${snapshot_uuid}" ]] || {
    echo "VM snapshot UUID is required." >&2
    return 2
  }
  n2k_nutanix_api_request_capture DELETE "${pc}" "/api/nutanix/v3/vm_snapshots/${snapshot_uuid}" \
    "${username}" "${password}" "${insecure}" "" response http_code api_error || true
  if ! n2k_nutanix_http_success "${http_code}"; then
    echo "v3 VM snapshot delete failed: HTTP ${http_code}${api_error:+ ${api_error}}" >&2
    return 4
  fi
  printf '%s' "${response}"
}

n2k_source_v3_vm_snapshot_paths_from_json() {
  local snapshot_json="$1"

  printf '%s' "${snapshot_json}" | jq -c '
    def disk_path($file):
      ($file.file_path // "" | capture("^(?<container>/[^/]+)/(?<rel>[.]acropolis/vmdisk/(?<vdisk_uuid>[^/]+))$")?) as $m
      | select($m != null)
      | {
          vdisk_uuid:$m.vdisk_uuid,
          live_path:($file.file_path // ""),
          snapshot_file_path:($file.snapshot_file_path // ""),
          container:$m.container,
          candidate_paths:([($file.snapshot_file_path // empty)] | map(select(length > 0)))
        };

    . as $snapshot
    | [
        ($snapshot.status.snapshot_file_list // [])[]? as $file
        | disk_path($file)
      ] as $paths
    | {
        schema:"ablestack-n2k/v3-vm-snapshot-paths-v1",
        source_api:"v3",
        path_status:"api_provided",
        snapshot_uuid:($snapshot.metadata.uuid // ""),
        snapshot_name:($snapshot.status.name // $snapshot.spec.name // ""),
        snapshot_type:($snapshot.status.snapshot_type // $snapshot.spec.snapshot_type // ""),
        entity_uuid:($snapshot.status.resources.entity_uuid // $snapshot.spec.resources.entity_uuid // ""),
        state:($snapshot.status.state // ""),
        disks:(($paths | map({(.vdisk_uuid): .}) | add) // {}),
        disk_count:($paths | length)
      }'
}

n2k_source_legacy_changed_region_candidate_pairs_from_indexes() {
  local current_index_json="$1" reference_index_json="$2" max_pairs="${3:-40}"

  jq -nc \
    --argjson current "${current_index_json}" \
    --argjson reference "${reference_index_json}" \
    --argjson max_pairs "${max_pairs}" \
    '
      [
        ($current.disks // {}) | to_entries[]? as $current_disk
        | ($reference.disks[$current_disk.key] // null) as $reference_disk
        | select($reference_disk != null)
        | ($current_disk.value.candidate_paths // [])[]? as $current_path
        | ($reference_disk.candidate_paths // [])[]? as $reference_path
        | {
            vdisk_uuid:$current_disk.key,
            snapshot_file_path:$current_path,
            reference_snapshot_file_path:$reference_path
          }
      ][0:$max_pairs]'
}

n2k_source_legacy_changed_regions_try_pair() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local snapshot_file_path="$5" reference_snapshot_file_path="$6" start_offset="${7:-0}" end_offset="${8:-}"
  local endpoint="${9:-/api/nutanix/v3/data/changed_regions}"
  local body response="" http_code="" api_error="" response_json="null" verified=false

  body="$(n2k_source_legacy_changed_regions_body "${snapshot_file_path}" "${reference_snapshot_file_path}" "${start_offset}" "${end_offset}")"
  n2k_nutanix_api_request_capture POST "${pc}" "${endpoint}" \
    "${username}" "${password}" "${insecure}" "${body}" response http_code api_error || true

  if n2k_nutanix_http_success "${http_code}"; then
    verified=true
  fi
  if printf '%s' "${response}" | jq empty >/dev/null 2>&1; then
    response_json="$(printf '%s' "${response}" | jq -c .)"
  fi

  jq -nc \
    --arg endpoint "${endpoint}" \
    --arg status "${http_code}" \
    --arg error "${api_error}" \
    --arg snapshot_file_path "${snapshot_file_path}" \
    --arg reference_snapshot_file_path "${reference_snapshot_file_path}" \
    --argjson verified "${verified}" \
    --argjson response "${response_json}" \
    '{
      verified:$verified,
      endpoint:$endpoint,
      status:$status,
      error:$error,
      snapshot_file_path:$snapshot_file_path,
      reference_snapshot_file_path:$reference_snapshot_file_path,
      response:$response
    }'
}

n2k_source_legacy_collect_changed_regions_for_pair() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local disk_key="$5" snapshot_file_path="$6" reference_snapshot_file_path="${7:-}"
  local current_recovery_point_id="${8:-}" reference_recovery_point_id="${9:-}" max_pages="${10:-256}"
  local start_offset=0 page_count=0 body response="" http_code="" api_error="" response_json regions="[]"
  local file_size="null" next_offset="" region_count bytes_total

  while true; do
    body="$(n2k_source_legacy_changed_regions_body "${snapshot_file_path}" "${reference_snapshot_file_path}" "${start_offset}")"
    n2k_nutanix_api_request_capture POST "${pc}" "/api/nutanix/v3/data/changed_regions" \
      "${username}" "${password}" "${insecure}" "${body}" response http_code api_error || true

    response_json="null"
    if printf '%s' "${response}" | jq empty >/dev/null 2>&1; then
      response_json="$(printf '%s' "${response}" | jq -c .)"
    fi
    if ! n2k_nutanix_http_success "${http_code}"; then
      jq -nc \
        --arg disk_key "${disk_key}" \
        --arg status "${http_code}" \
        --arg error "${api_error}" \
        --arg snapshot_file_path "${snapshot_file_path}" \
        --arg reference_snapshot_file_path "${reference_snapshot_file_path}" \
        --argjson response "${response_json}" \
        '{
          ok:false,
          disk_key:$disk_key,
          status:$status,
          error:$error,
          snapshot_file_path:$snapshot_file_path,
          reference_snapshot_file_path:$reference_snapshot_file_path,
          response:$response
        }'
      return 0
    fi

    file_size="$(printf '%s' "${response_json}" | jq -r '.file_size // null')"
    regions="$(jq -cs '.[0] + ((.[1].region_list // .[1].regions // .[1].changed_regions // []) | map({offset:(.offset // .start // .start_offset), length:(.length // .len // .size), type:((.type // .region_type // "regular") | tostring | ascii_downcase)}))' \
      <(printf '%s\n' "${regions}") <(printf '%s\n' "${response_json}"))"
    next_offset="$(printf '%s' "${response_json}" | jq -r '.next_offset // empty')"
    page_count="$((page_count + 1))"

    [[ -n "${next_offset}" ]] || break
    [[ "${next_offset}" =~ ^[0-9]+$ ]] || break
    if [[ "${next_offset}" -le "${start_offset}" ]]; then
      break
    fi
    if [[ "${page_count}" -ge "${max_pages}" ]]; then
      jq -nc \
        --arg disk_key "${disk_key}" \
        --arg snapshot_file_path "${snapshot_file_path}" \
        --arg reference_snapshot_file_path "${reference_snapshot_file_path}" \
        --argjson page_count "${page_count}" \
        '{ok:false,disk_key:$disk_key,status:"pagination_limit",snapshot_file_path:$snapshot_file_path,reference_snapshot_file_path:$reference_snapshot_file_path,page_count:$page_count,response:null}'
      return 0
    fi
    start_offset="${next_offset}"
  done

  region_count="$(printf '%s' "${regions}" | jq -r 'length')"
  bytes_total="$(printf '%s' "${regions}" | jq -r 'map(.length) | add // 0')"
  jq -nc \
    --arg disk_key "${disk_key}" \
    --arg current_recovery_point_id "${current_recovery_point_id}" \
    --arg reference_recovery_point_id "${reference_recovery_point_id}" \
    --arg snapshot_file_path "${snapshot_file_path}" \
    --arg reference_snapshot_file_path "${reference_snapshot_file_path}" \
    --argjson file_size "${file_size}" \
    --argjson page_count "${page_count}" \
    --argjson region_count "${region_count}" \
    --argjson bytes_total "${bytes_total}" \
    --argjson regions "${regions}" \
    '{
      ok:true,
      schema:"ablestack-n2k/changed-regions-v1",
      source_api:"v3",
      disk_key:$disk_key,
      current_recovery_point_id:$current_recovery_point_id,
      base_recovery_point_id:$reference_recovery_point_id,
      reference_recovery_point_id:$reference_recovery_point_id,
      snapshot_file_path:$snapshot_file_path,
      reference_snapshot_file_path:(if $reference_snapshot_file_path == "" then null else $reference_snapshot_file_path end),
      file_size:$file_size,
      page_count:$page_count,
      region_count:$region_count,
      bytes_total:$bytes_total,
      disks:{($disk_key):$regions}
    }'
}

n2k_source_manifest_disk_id_for_snapshot_file() {
  local manifest="$1" vdisk_uuid="$2" file_size="${3:-null}" ordinal="${4:-0}"

  jq -r \
    --arg vdisk_uuid "${vdisk_uuid}" \
    --argjson file_size "${file_size}" \
    --argjson ordinal "${ordinal}" \
    '
      def disk_size($d):
        (($d.size_bytes // $d.disk_size_bytes // $d.capacity_bytes // $d.size // null) | tonumber?);
      .disks as $disks
      | (
          [$disks[]? | select(
              (.disk_id // "") == $vdisk_uuid
              or (.device_key // "") == $vdisk_uuid
              or (.nutanix.vdisk_uuid // "") == $vdisk_uuid
            ) | (.disk_id // .device_key // "")]
          | map(select(length > 0))
          | .[0]
        ) as $direct
      | if ($direct // "") != "" then $direct
        else
          ([$disks[]? | select(($file_size != null) and (disk_size(.) == $file_size)) | (.disk_id // .device_key // "")]
           | map(select(length > 0))) as $size_matches
          | if ($size_matches | length) == 1 then $size_matches[0]
            elif ($ordinal < ($disks | length)) and ($file_size != null) and (disk_size($disks[$ordinal]) == $file_size) then
              ($disks[$ordinal].disk_id // $disks[$ordinal].device_key // "")
            else
              ""
            end
        end
    ' "${manifest}"
}

n2k_source_v3_collect_changed_regions_from_indexes() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local current_index_json="$5" reference_index_json="$6" manifest="$7"
  local current_recovery_point_id="${8:-}" reference_recovery_point_id="${9:-}" max_pages="${10:-256}"
  local pairs_json pair_count idx pair vdisk_uuid snapshot_file_path reference_snapshot_file_path result
  local file_size disk_id regions regions_by_disk="{}" mappings="{}" errors="[]" skipped="[]"
  local total_regions=0 total_bytes=0 mapped_count=0

  pairs_json="$(n2k_source_legacy_changed_region_candidate_pairs_from_indexes "${current_index_json}" "${reference_index_json}" 200)"
  pair_count="$(printf '%s' "${pairs_json}" | jq -r 'length')"
  if [[ "${pair_count}" -eq 0 ]]; then
    jq -nc \
      --arg current_recovery_point_id "${current_recovery_point_id}" \
      --arg reference_recovery_point_id "${reference_recovery_point_id}" \
      '{
        schema:"ablestack-n2k/changed-regions-v1",
        source_api:"v3",
        ok:false,
        reason:"no comparable candidate paths",
        current_recovery_point_id:$current_recovery_point_id,
        base_recovery_point_id:$reference_recovery_point_id,
        reference_recovery_point_id:$reference_recovery_point_id,
        disks:{},
        disk_mappings:{},
        errors:[],
        skipped:[]
      }'
    return 0
  fi

  idx=0
  while [[ "${idx}" -lt "${pair_count}" ]]; do
    pair="$(printf '%s' "${pairs_json}" | jq -c --argjson idx "${idx}" '.[$idx]')"
    vdisk_uuid="$(printf '%s' "${pair}" | jq -r '.vdisk_uuid')"
    snapshot_file_path="$(printf '%s' "${pair}" | jq -r '.snapshot_file_path')"
    reference_snapshot_file_path="$(printf '%s' "${pair}" | jq -r '.reference_snapshot_file_path')"
    result="$(n2k_source_legacy_collect_changed_regions_for_pair \
      "${pc}" "${username}" "${password}" "${insecure}" \
      "${vdisk_uuid}" "${snapshot_file_path}" "${reference_snapshot_file_path}" \
      "${current_recovery_point_id}" "${reference_recovery_point_id}" "${max_pages}")"

    if ! printf '%s' "${result}" | jq -e '.ok == true' >/dev/null; then
      errors="$(jq -cs '.[0] + [.[1]]' <(printf '%s\n' "${errors}") <(printf '%s\n' "${result}"))"
      idx="$((idx + 1))"
      continue
    fi

    file_size="$(printf '%s' "${result}" | jq -r '.file_size // null')"
    disk_id="$(n2k_source_manifest_disk_id_for_snapshot_file "${manifest}" "${vdisk_uuid}" "${file_size}" "${idx}")"
    if [[ -z "${disk_id}" ]]; then
      skipped="$(jq -cs '.[0] + [.[1]]' \
        <(printf '%s\n' "${skipped}") \
        <(jq -nc --arg vdisk_uuid "${vdisk_uuid}" --argjson file_size "${file_size}" --arg snapshot_file_path "${snapshot_file_path}" '{vdisk_uuid:$vdisk_uuid,file_size:$file_size,snapshot_file_path:$snapshot_file_path,reason:"snapshot file was not mapped to a manifest disk"}'))"
      idx="$((idx + 1))"
      continue
    fi

    regions="$(printf '%s' "${result}" | jq -c --arg vdisk_uuid "${vdisk_uuid}" '.disks[$vdisk_uuid] // []')"
    regions_by_disk="$(jq -c --arg disk_id "${disk_id}" --argjson regions "${regions}" '. + {($disk_id):$regions}' <<<"${regions_by_disk}")"
    mappings="$(jq -c \
      --arg disk_id "${disk_id}" \
      --arg vdisk_uuid "${vdisk_uuid}" \
      --arg snapshot_file_path "${snapshot_file_path}" \
      --arg reference_snapshot_file_path "${reference_snapshot_file_path}" \
      --argjson file_size "${file_size}" \
      '. + {($disk_id):{vdisk_uuid:$vdisk_uuid,file_size:$file_size,snapshot_file_path:$snapshot_file_path,reference_snapshot_file_path:$reference_snapshot_file_path}}' \
      <<<"${mappings}")"
    total_regions="$((total_regions + $(printf '%s' "${result}" | jq -r '.region_count // 0')))"
    total_bytes="$((total_bytes + $(printf '%s' "${result}" | jq -r '.bytes_total // 0')))"
    mapped_count="$((mapped_count + 1))"
    idx="$((idx + 1))"
  done

  jq -nc \
    --arg current_recovery_point_id "${current_recovery_point_id}" \
    --arg reference_recovery_point_id "${reference_recovery_point_id}" \
    --argjson mapped_count "${mapped_count}" \
    --argjson total_regions "${total_regions}" \
    --argjson total_bytes "${total_bytes}" \
    --argjson disks "${regions_by_disk}" \
    --argjson mappings "${mappings}" \
    --argjson errors "${errors}" \
    --argjson skipped "${skipped}" \
    '{
      schema:"ablestack-n2k/changed-regions-v1",
      source_api:"v3",
      ok:(($errors | length) == 0 and $mapped_count > 0),
      current_recovery_point_id:$current_recovery_point_id,
      base_recovery_point_id:$reference_recovery_point_id,
      reference_recovery_point_id:$reference_recovery_point_id,
      disk_count:$mapped_count,
      region_count:$total_regions,
      bytes_total:$total_bytes,
      disks:$disks,
      disk_mappings:$mappings,
      errors:$errors,
      skipped:$skipped
    }'
}

n2k_source_legacy_verify_changed_region_paths() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local current_index_json="$5" reference_index_json="$6" max_pairs="${7:-40}"
  local pairs_json pair_count idx pair attempt attempts="[]" verified_attempt=""
  local snapshot_file_path reference_snapshot_file_path status

  pairs_json="$(n2k_source_legacy_changed_region_candidate_pairs_from_indexes "${current_index_json}" "${reference_index_json}" "${max_pairs}")"
  pair_count="$(printf '%s' "${pairs_json}" | jq -r 'length')"
  if [[ "${pair_count}" -eq 0 ]]; then
    jq -nc '{verified:false,reason:"no comparable candidate paths",attempt_count:0,attempts:[]}'
    return 0
  fi

  idx=0
  while [[ "${idx}" -lt "${pair_count}" ]]; do
    pair="$(printf '%s' "${pairs_json}" | jq -c --argjson idx "${idx}" '.[$idx]')"
    snapshot_file_path="$(printf '%s' "${pair}" | jq -r '.snapshot_file_path')"
    reference_snapshot_file_path="$(printf '%s' "${pair}" | jq -r '.reference_snapshot_file_path')"
    attempt="$(n2k_source_legacy_changed_regions_try_pair \
      "${pc}" "${username}" "${password}" "${insecure}" \
      "${snapshot_file_path}" "${reference_snapshot_file_path}" 0)"
    status="$(printf '%s' "${attempt}" | jq -r '.status')"
    attempts="$(jq -cs '.[0] + [.[1]] | .[0:10]' <(printf '%s\n' "${attempts}") <(printf '%s\n' "${attempt}"))"
    if n2k_nutanix_http_success "${status}"; then
      verified_attempt="${attempt}"
      break
    fi
    idx="$((idx + 1))"
  done

  if [[ -n "${verified_attempt}" ]]; then
    jq -nc \
      --argjson attempt "${verified_attempt}" \
      --argjson attempt_count "$((idx + 1))" \
      '{verified:true,reason:"changed-region path pair verified",attempt_count:$attempt_count,selected:$attempt}'
  else
    jq -nc \
      --argjson attempt_count "${pair_count}" \
      --argjson attempts "${attempts}" \
      '{
        verified:false,
        reason:"all candidate snapshot path pairs were rejected",
        attempt_count:$attempt_count,
        attempts:$attempts
      }'
  fi
}

n2k_source_legacy_changed_regions_body() {
  local snapshot_file_path="$1" reference_snapshot_file_path="${2:-}" start_offset="${3:-0}" end_offset="${4:-}"

  if [[ -n "${end_offset}" ]]; then
    jq -nc \
      --arg snapshot_file_path "${snapshot_file_path}" \
      --arg reference_snapshot_file_path "${reference_snapshot_file_path}" \
      --argjson start_offset "${start_offset}" \
      --argjson end_offset "${end_offset}" \
      '{
        snapshot_file_path:$snapshot_file_path,
        start_offset:$start_offset,
        end_offset:$end_offset
      } + (if $reference_snapshot_file_path == "" then {} else {reference_snapshot_file_path:$reference_snapshot_file_path} end)'
  else
    jq -nc \
      --arg snapshot_file_path "${snapshot_file_path}" \
      --arg reference_snapshot_file_path "${reference_snapshot_file_path}" \
      --argjson start_offset "${start_offset}" \
      '{
        snapshot_file_path:$snapshot_file_path,
        start_offset:$start_offset
      } + (if $reference_snapshot_file_path == "" then {} else {reference_snapshot_file_path:$reference_snapshot_file_path} end)'
  fi
}

n2k_source_legacy_compute_changed_regions() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local snapshot_file_path="$5" reference_snapshot_file_path="${6:-}" start_offset="${7:-0}" end_offset="${8:-}"
  local body response="" http_code="" api_error=""

  [[ -n "${snapshot_file_path}" ]] || {
    echo "snapshot_file_path is required for legacy changed regions." >&2
    return 2
  }

  body="$(n2k_source_legacy_changed_regions_body "${snapshot_file_path}" "${reference_snapshot_file_path}" "${start_offset}" "${end_offset}")"
  n2k_nutanix_api_request_capture POST "${pc}" "/api/nutanix/v3/data/changed_regions" \
    "${username}" "${password}" "${insecure}" "${body}" response http_code api_error || true

  if ! n2k_nutanix_http_success "${http_code}"; then
    echo "Legacy changed-region request failed: HTTP ${http_code}${api_error:+ ${api_error}}" >&2
    return 4
  fi

  printf '%s' "${response}"
}

n2k_source_legacy_changed_regions_to_canonical() {
  local disk_id="$1" response_json="$2" base_recovery_point_id="${3:-}" reference_recovery_point_id="${4:-}"

  printf '%s' "${response_json}" | jq -c \
    --arg disk_id "${disk_id}" \
    --arg base_recovery_point_id "${base_recovery_point_id}" \
    --arg reference_recovery_point_id "${reference_recovery_point_id}" \
    '
      def normalize_region:
        {
          offset: (.offset // .start // .start_offset),
          length: (.length // .len // .size),
          type: ((.type // .region_type // "regular") | tostring | ascii_downcase)
        };
      {
        schema:"ablestack-n2k/changed-regions-v1",
        source_api:"legacy",
        base_recovery_point_id:$base_recovery_point_id,
        reference_recovery_point_id:$reference_recovery_point_id,
        file_size:(.file_size // .fileSize // null),
        next_offset:(.next_offset // .nextOffset // null),
        disks:{
          ($disk_id): ((.region_list // .regions // .changed_regions // []) | map(normalize_region))
        }
      }
    '
}

n2k_source_probe_capabilities() {
  local pc="$1" vm="$2" username="$3" password="$4" insecure="$5" probe_legacy="$6"
  local v4_json v3_json inventory_json legacy_json pd_json

  v4_json="$(n2k_source_probe_v4 "${pc}" "${username}" "${password}" "${insecure}")"
  v3_json="$(n2k_source_probe_v3_vm_snapshots "${pc}" "${username}" "${password}" "${insecure}")"
  inventory_json="$(n2k_source_probe_inventory "${pc}" "${vm}" "${username}" "${password}" "${insecure}")"
  pd_json="$(n2k_source_probe_legacy_pd_snapshots "${pc}" "${username}" "${password}" "${insecure}")"

  if [[ "${probe_legacy}" == "true" ]]; then
    legacy_json="$(n2k_source_probe_legacy_changed_regions "${pc}" "${username}" "${password}" "${insecure}")"
  else
    legacy_json="$(jq -nc '{changed_regions:false,candidate:false,verified:false,endpoint:"",probe:{status:null,reason:"legacy probe was not requested",error:""}}')"
  fi

  legacy_json="$(jq -cs '.[0] * .[1]' <(printf '%s\n' "${legacy_json}") <(printf '%s\n' "${pd_json}"))"

  jq -nc \
    --argjson v4 "${v4_json}" \
    --argjson v3 "${v3_json}" \
    --argjson inventory "${inventory_json}" \
    --argjson legacy "${legacy_json}" \
    '{
      api:{
        v4:$v4,
        v3:$v3,
        legacy:$legacy
      },
      inventory:$inventory,
      cold_export:{available:false},
      manual_disk:{available:true}
    }'
}
