#!/usr/bin/env bash
# shellcheck disable=SC2317
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/v2k-offering-cpu-speed.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/cloudstack_api.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/target_cloud.sh"

# The single-quoted pattern intentionally searches for the literal legacy code.
# shellcheck disable=SC2016
if grep -Fq 'cloud_cpu_speed="${cloud_cpu_speed:-1000}"' \
    "${ROOT_DIR}/lib/v2k/interactive.sh"; then
  echo '[ERR] V2K Wizard still injects the legacy 1000 MHz CPU-speed default' >&2
  exit 1
fi
if grep -Fq -- '--cloud-cpu-speed <MHz>                   Default: 1000' \
    "${ROOT_DIR}/bin/ablestack_v2k.sh"; then
  echo '[ERR] V2K help still advertises the removed 1000 MHz default' >&2
  exit 1
fi

config_without_speed="$(v2k_cloud_target_config_json \
  endpoint zone offering network storage '' '' '' '' '' vm vm '')"
jq -e 'has("cpu_speed") | not' <<<"${config_without_speed}" >/dev/null

manifest="${WORK_DIR}/manifest.json"
cat >"${manifest}" <<'JSON'
{
  "source":{"vm":{"cpu":2,"memory_mb":4096,"firmware":"bios"}},
  "target":{"cloud":{"cpu_speed":"1000"}},
  "disks":[{"size_bytes":21474836480,"controller":{"kind":"scsi"}}]
}
JSON

fixed_params="$(v2k_cloud_target_source_deploy_params_json \
  "${manifest}" '{"id":"offering-fixed","cpuspeed":2000}')"
jq -e '
  has("details[0].cpuSpeed") | not
' <<<"${fixed_params}" >/dev/null
jq -e '
  .["details[0].cpuNumber"] == "2"
  and .["details[0].memory"] == "4096"
  and .["details[0].rootdisksize"] == "20"
' <<<"${fixed_params}" >/dev/null

custom_params="$(v2k_cloud_target_source_deploy_params_json \
  "${manifest}" '{"id":"offering-custom","cpuspeed":null,"iscustomized":true}')"
jq -e '.["details[0].cpuSpeed"] == "1000"' <<<"${custom_params}" >/dev/null


# Both providers may pass source values only for dimensions the chosen offering
# leaves configurable. Firmware and disk settings remain available in all cases.
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/target_cloud.sh"
fixed='{"id":"offering-static","cpunumber":2,"cpuspeed":2000,"memory":4096,"iscustomized":false}'
mixed='{"id":"offering-dynamic","cpunumber":2,"cpuspeed":2000,"iscustomized":true}'
for deploy_params in v2k_cloud_target_source_deploy_params_json n2k_cloud_target_source_deploy_params_json; do
  params="$("$deploy_params" "$manifest" "$fixed")"
  jq -e '
    (has("details[0].cpuSpeed") or has("details[0].cpuNumber") or has("details[0].memory") | not)
    and ."details[0].rootdisksize" == "20" and .boottype == "BIOS"
  ' <<<"$params" >/dev/null
  params="$("$deploy_params" "$manifest" "$mixed")"
  jq -e '
    (has("details[0].cpuSpeed") or has("details[0].cpuNumber") | not) and ."details[0].memory" == "4096"
  ' <<<"$params" >/dev/null
done

manifest_without_speed="${WORK_DIR}/manifest-without-speed.json"
jq 'del(.target.cloud.cpu_speed)' "${manifest}" >"${manifest_without_speed}"
optional_params="$(v2k_cloud_target_source_deploy_params_json \
  "${manifest_without_speed}" '{}')"
jq -e 'has("details[0].cpuSpeed") | not' <<<"${optional_params}" >/dev/null

v2k_cloud_api_get() {
  printf '%s' '{"listserviceofferingsresponse":{"serviceoffering":[{"id":"selected","cpuspeed":2000},{"id":"other","cpuspeed":900}]}}'
}
offering="$(v2k_cloud_target_service_offering_json endpoint api secret selected)"
jq -e '.id == "selected" and .cpuspeed == 2000' <<<"${offering}" >/dev/null

cfg='{"zone_id":"zone","service_offering_id":"offering","network_ids":["network"],"nic_mappings":[],"name":"vm","display_name":"vm"}'
source_params='{"details[0].cpuSpeed":"1000","details[0].cpuNumber":"2"}'
call_log="${WORK_DIR}/deploy-calls.jsonl"

v2k_cloud_api_get() {
  local endpoint="$1" api_key="$2" secret_key="$3" command="$4" params="$5"
  : "${endpoint}" "${api_key}" "${secret_key}"
  [[ "${command}" == "deployVirtualMachineForVolume" ]]
  printf '%s\n' "${params}" >>"${call_log}"
  if [[ "$(wc -l <"${call_log}")" -eq 1 ]]; then
    echo 'Cloud API error: errortext=The CPU speed of this offering is not customizable. This is predefined as 2000 MHz.' >&2
    return 1
  fi
  printf '%s' '{"deployvirtualmachineforvolumeresponse":{"jobid":"deploy-job"}}'
}
v2k_cloud_wait_job() {
  printf '%s' '{"jobresult":{"virtualmachine":{"id":"vm-id"}}}'
}

deploy_result="$(v2k_cloud_target_deploy_vm_for_volume \
  endpoint api secret "${cfg}" root-volume false "${source_params}")"
jq -e '.id == "vm-id" and .job_id == "deploy-job"' <<<"${deploy_result}" >/dev/null
[[ "$(wc -l <"${call_log}")" -eq 2 ]]
sed -n '1p' "${call_log}" | jq -e '.["details[0].cpuSpeed"] == "1000"' >/dev/null
sed -n '2p' "${call_log}" | jq -e '
  (has("details[0].cpuSpeed") | not)
  and .["details[0].cpuNumber"] == "2"
' >/dev/null

: >"${call_log}"
v2k_cloud_api_get() {
  local endpoint="$1" api_key="$2" secret_key="$3" command="$4" params="$5"
  : "${endpoint}" "${api_key}" "${secret_key}"
  [[ "${command}" == "deployVirtualMachineForVolume" ]]
  printf '%s\n' "${params}" >>"${call_log}"
  echo 'Cloud API error: errortext=The selected network is unavailable.' >&2
  return 1
}

set +e
v2k_cloud_target_deploy_vm_for_volume \
  endpoint api secret "${cfg}" root-volume false "${source_params}" \
  >/dev/null 2>"${WORK_DIR}/unrelated-error.log"
unrelated_rc=$?
set -e
[[ "${unrelated_rc}" -ne 0 ]]
[[ "$(wc -l <"${call_log}")" -eq 1 ]]
grep -F 'selected network is unavailable' "${WORK_DIR}/unrelated-error.log" >/dev/null

echo '[OK] V2K Cloud service-offering CPU speed smoke passed'
