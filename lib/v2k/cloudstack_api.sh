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

v2k_cloud_load_cred_file() {
  local file="$1"
  [[ -f "${file}" ]] || {
    echo "Cloud credential file not found: ${file}" >&2
    return 2
  }
  set -a
  # shellcheck source=/dev/null
  source "${file}"
  set +a
}

v2k_cloud_normalize_endpoint() {
  local endpoint="$1"
  [[ -n "${endpoint}" ]] || {
    echo "Cloud API endpoint is required." >&2
    return 2
  }
  printf '%s' "${endpoint%/}"
}

v2k_cloud_resolve_api_key() {
  local explicit="${1:-}"
  printf '%s' "${explicit:-${V2K_CLOUD_API_KEY:-${ABLESTACK_CLOUD_API_KEY:-${CLOUDSTACK_API_KEY:-}}}}"
}

v2k_cloud_resolve_secret_key() {
  local explicit="${1:-}"
  printf '%s' "${explicit:-${V2K_CLOUD_SECRET_KEY:-${ABLESTACK_CLOUD_SECRET_KEY:-${CLOUDSTACK_SECRET_KEY:-}}}}"
}

v2k_cloud_require_credentials() {
  local endpoint="$1" api_key="$2" secret_key="$3"
  [[ -n "${endpoint}" ]] || {
    echo "Cloud API endpoint is required." >&2
    return 2
  }
  [[ -n "${api_key}" ]] || {
    echo "Cloud API key is required." >&2
    return 2
  }
  [[ -n "${secret_key}" ]] || {
    echo "Cloud secret key is required." >&2
    return 2
  }
}

v2k_cloud_urlencode() {
  local value="${1:-}"
  jq -rn --arg v "${value}" '$v | @uri'
}

v2k_cloud_params_query() {
  local params_json="$1"
  printf '%s' "${params_json}" | jq -r '
    to_entries
    | sort_by(.key)
    | map(.key + "=" + ((.value | tostring) | @uri))
    | join("&")
  '
}

v2k_cloud_unsigned_request() {
  local params_json="$1"
  v2k_cloud_params_query "${params_json}" | tr '[:upper:]' '[:lower:]'
}

v2k_cloud_signature() {
  local unsigned="$1" secret_key="$2"
  printf '%s' "${unsigned}" \
    | openssl dgst -sha256 -hmac "${secret_key}" -binary \
    | base64 \
    | tr -d '\n'
}

v2k_cloud_signed_query() {
  local params_json="$1" secret_key="$2"
  local query unsigned signature signature_enc
  query="$(v2k_cloud_params_query "${params_json}")"
  unsigned="$(v2k_cloud_unsigned_request "${params_json}")"
  signature="$(v2k_cloud_signature "${unsigned}" "${secret_key}")"
  signature_enc="$(v2k_cloud_urlencode "${signature}")"
  printf '%s&signature=%s' "${query}" "${signature_enc}"
}

v2k_cloud_api_prefers_post() {
  local command="$1"
  case "${command}" in
    createDiskOffering|importVolume|deployVirtualMachineForVolume|updateVolume|attachVolume|startVirtualMachine)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

v2k_cloud_api_method() {
  local command="$1" query_len="$2"
  local requested threshold
  requested="$(printf '%s' "${V2K_CLOUD_API_METHOD:-auto}" | tr '[:lower:]' '[:upper:]')"
  threshold="${V2K_CLOUD_POST_THRESHOLD:-1800}"
  [[ "${threshold}" =~ ^[0-9]+$ ]] || threshold=1800

  case "${requested}" in
    GET|POST)
      printf '%s' "${requested}"
      return 0
      ;;
  esac

  if v2k_cloud_api_prefers_post "${command}" || (( query_len >= threshold )); then
    printf '%s' "POST"
  else
    printf '%s' "GET"
  fi
}

v2k_cloud_command_params_json() {
  local command="$1" api_key="$2" params_json="${3:-}"
  [[ -n "${params_json}" ]] || params_json="{}"
  printf '%s' "${params_json}" | jq -c \
    --arg command "${command}" \
    --arg api_key "${api_key}" \
    '. + {command:$command, apiKey:$api_key, response:"json"}'
}

v2k_cloud_response_error_summary() {
  local body_file="$1" header_file="$2"
  local json_summary="" header_desc=""

  if [[ -s "${body_file}" ]]; then
    json_summary="$(jq -r '
      to_entries[0].value as $v
      | [
          (if ($v.errorcode // null) != null then "errorcode=" + ($v.errorcode | tostring) else empty end),
          (if ($v.cserrorcode // null) != null then "cserrorcode=" + ($v.cserrorcode | tostring) else empty end),
          (if (($v.errortext // "") | tostring | length) > 0 then "errortext=" + ($v.errortext | tostring) else empty end)
        ]
      | join(" ")
    ' "${body_file}" 2>/dev/null || true)"
  fi

  if [[ -s "${header_file}" ]]; then
    header_desc="$(awk -F': *' 'tolower($1) == "x-description" {print substr($0, index($0, $2))}' "${header_file}" | tail -n 1 | tr -d '\r' || true)"
  fi

  if [[ -n "${json_summary}" && -n "${header_desc}" && "${json_summary}" != *"${header_desc}"* ]]; then
    printf '%s x-description=%s' "${json_summary}" "${header_desc}"
  elif [[ -n "${json_summary}" ]]; then
    printf '%s' "${json_summary}"
  elif [[ -n "${header_desc}" ]]; then
    printf 'x-description=%s' "${header_desc}"
  elif [[ -s "${body_file}" ]]; then
    head -c 512 "${body_file}" | tr '\n' ' '
  fi
}

v2k_cloud_api_report_failure() {
  local command="$1" method="$2" query_len="$3" http_status="$4" body_file="$5" header_file="$6" curl_err_file="$7"
  local summary curl_err

  echo "Cloud API request failed: command=${command} method=${method} http_status=${http_status:-000} query_length=${query_len}" >&2
  summary="$(v2k_cloud_response_error_summary "${body_file}" "${header_file}")"
  if [[ -n "${summary}" ]]; then
    echo "Cloud API error: ${summary}" >&2
  fi
  if [[ -s "${curl_err_file}" ]]; then
    curl_err="$(tr '\n' ' ' <"${curl_err_file}")"
    [[ -n "${curl_err}" ]] && echo "Cloud API curl error: ${curl_err}" >&2
  fi
}

v2k_cloud_api_get() {
  local endpoint="$1" api_key="$2" secret_key="$3" command="$4" params_json="${5:-}"
  local connect_timeout max_time body_params query url method query_len
  local body_file header_file curl_err_file http_status curl_rc
  [[ -n "${params_json}" ]] || params_json="{}"
  endpoint="$(v2k_cloud_normalize_endpoint "${endpoint}")"
  v2k_cloud_require_credentials "${endpoint}" "${api_key}" "${secret_key}"
  connect_timeout="${V2K_CLOUD_CONNECT_TIMEOUT:-10}"
  max_time="${V2K_CLOUD_MAX_TIME:-120}"

  body_params="$(v2k_cloud_command_params_json "${command}" "${api_key}" "${params_json}")"
  query="$(v2k_cloud_signed_query "${body_params}" "${secret_key}")"
  query_len="${#query}"
  method="$(v2k_cloud_api_method "${command}" "${query_len}")"
  url="${endpoint}?${query}"

  body_file="$(mktemp "${TMPDIR:-/tmp}/v2k-cloud-body.XXXXXX")"
  header_file="$(mktemp "${TMPDIR:-/tmp}/v2k-cloud-headers.XXXXXX")"
  curl_err_file="$(mktemp "${TMPDIR:-/tmp}/v2k-cloud-curl.XXXXXX")"

  if [[ "${method}" == "POST" ]]; then
    http_status="$(curl --globoff --silent --show-error \
      --request POST \
      --header "Content-Type: application/x-www-form-urlencoded" \
      --data-binary "${query}" \
      --connect-timeout "${connect_timeout}" \
      --max-time "${max_time}" \
      --dump-header "${header_file}" \
      --output "${body_file}" \
      --write-out "%{http_code}" \
      "${endpoint}" 2>"${curl_err_file}")"
    curl_rc=$?
    if (( curl_rc != 0 )) || ! [[ "${http_status}" =~ ^[0-9]{3}$ ]] || (( http_status >= 400 )); then
      v2k_cloud_api_report_failure "${command}" "POST" "${query_len}" "${http_status}" "${body_file}" "${header_file}" "${curl_err_file}"
      rm -f "${body_file}" "${header_file}" "${curl_err_file}"
      return 1
    fi
  else
    http_status="$(curl --globoff --silent --show-error \
      --connect-timeout "${connect_timeout}" \
      --max-time "${max_time}" \
      --dump-header "${header_file}" \
      --output "${body_file}" \
      --write-out "%{http_code}" \
      "${url}" 2>"${curl_err_file}")"
    curl_rc=$?
    if (( curl_rc != 0 )) || ! [[ "${http_status}" =~ ^[0-9]{3}$ ]] || (( http_status >= 400 )); then
      v2k_cloud_api_report_failure "${command}" "GET" "${query_len}" "${http_status}" "${body_file}" "${header_file}" "${curl_err_file}"
      rm -f "${body_file}" "${header_file}" "${curl_err_file}"
      return 1
    fi
  fi
  cat "${body_file}"
  rm -f "${body_file}" "${header_file}" "${curl_err_file}"
}

v2k_cloud_response_body() {
  jq -c 'to_entries[0].value'
}

v2k_cloud_response_job_id() {
  jq -r 'to_entries[0].value.jobid // empty'
}

v2k_cloud_wait_job() {
  local endpoint="$1" api_key="$2" secret_key="$3" job_id="$4"
  local timeout_sec="${5:-${V2K_CLOUD_JOB_TIMEOUT_SEC:-600}}"
  local poll_sec="${6:-${V2K_CLOUD_JOB_POLL_SEC:-3}}"
  local start now response body status error_text

  [[ -n "${job_id}" ]] || {
    echo "Cloud async job id is required." >&2
    return 2
  }
  [[ "${timeout_sec}" =~ ^[0-9]+$ ]] || timeout_sec=600
  [[ "${poll_sec}" =~ ^[0-9]+$ && "${poll_sec}" -gt 0 ]] || poll_sec=3

  start="$(date +%s)"
  while true; do
    response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "queryAsyncJobResult" \
      "$(jq -nc --arg jobid "${job_id}" '{jobid:$jobid}')")"
    body="$(printf '%s' "${response}" | v2k_cloud_response_body)"
    status="$(printf '%s' "${body}" | jq -r '.jobstatus // 0')"
    case "${status}" in
      1)
        printf '%s' "${body}"
        return 0
        ;;
      2)
        error_text="$(printf '%s' "${body}" | jq -r '.jobresult.errortext // .jobresult.errorcode // "cloud job failed"')"
        echo "Cloud async job failed (${job_id}): ${error_text}" >&2
        printf '%s' "${body}" >&2
        return 1
        ;;
    esac

    now="$(date +%s)"
    if (( now - start >= timeout_sec )); then
      echo "Timed out waiting for Cloud async job: ${job_id}" >&2
      return 1
    fi
    sleep "${poll_sec}"
  done
}

v2k_cloud_api_exists() {
  local endpoint="$1" api_key="$2" secret_key="$3" api_name="$4"
  local response
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listApis")"
  printf '%s' "${response}" | jq -e --arg api_name "${api_name}" '
    (.listapisresponse.api // [])
    | map(.name)
    | index($api_name) != null
  ' >/dev/null
}

v2k_cloud_json_array_from_csv() {
  local csv="${1:-}"
  if [[ -z "${csv}" ]]; then
    jq -nc '[]'
    return 0
  fi
  jq -nc --arg csv "${csv}" '
    $csv
    | split(",")
    | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
    | map(select(length > 0))
  '
}
