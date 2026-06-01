#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/n2k_cloud_target_runtime_smoke"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: $1" >&2
    exit 2
  }
}

cleanup() {
  rm -rf "${WORK_DIR}"
}

require_cmd jq
trap cleanup EXIT
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/cloudstack_api.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/target_cloud.sh"

manifest="${WORK_DIR}/manifest.json"
cat > "${manifest}" <<'JSON'
{
  "source": {
    "vm": {
      "cpu": 2,
      "memory_mb": 4096,
      "firmware": "bios",
      "nics": [
        {"mac": "52:54:00:12:34:56"}
      ]
    }
  },
  "target": {
    "cloud": {
      "cpu_speed": "1000"
    }
  },
  "disks": [
    {
      "disk_id": "disk0",
      "size_bytes": 32212254720,
      "controller": {"type": "scsi"}
    },
    {
      "disk_id": "disk1",
      "capacity_bytes": 10737418240,
      "controller": {"type": "scsi"}
    }
  ]
}
JSON

params="$(n2k_cloud_target_source_deploy_params_json "${manifest}")"
jq -e '
  .["details[0].cpuNumber"] == "2"
  and .["details[0].cpuSpeed"] == "1000"
  and .["details[0].io.policy"] == "io_uring"
  and .["details[0].iothreads"] == "true"
  and .["details[0].memory"] == "4096"
  and .["details[0].rootdisksize"] == "30"
  and .["details[0].rootDiskController"] == "scsi"
  and .["details[0].dataDiskController"] == "scsi"
  and .macaddress == "52:54:00:12:34:56"
' <<<"${params}" >/dev/null || {
  echo "[ERR] n2k Cloud deploy params did not include expected rootdisksize/details" >&2
  printf '%s\n' "${params}" >&2
  exit 1
}

manifest_ceil="${WORK_DIR}/manifest-ceil.json"
jq '.disks[0].size_bytes = 32212254721' "${manifest}" > "${manifest_ceil}"
params_ceil="$(n2k_cloud_target_source_deploy_params_json "${manifest_ceil}")"
jq -e '.["details[0].rootdisksize"] == "31"' <<<"${params_ceil}" >/dev/null || {
  echo "[ERR] n2k Cloud deploy rootdisksize was not rounded up to GiB" >&2
  printf '%s\n' "${params_ceil}" >&2
  exit 1
}

manifest_capacity="${WORK_DIR}/manifest-capacity.json"
jq 'del(.disks[0].size_bytes) | .disks[0].capacity_bytes = 21474836480' "${manifest}" > "${manifest_capacity}"
params_capacity="$(n2k_cloud_target_source_deploy_params_json "${manifest_capacity}")"
jq -e '.["details[0].rootdisksize"] == "20"' <<<"${params_capacity}" >/dev/null || {
  echo "[ERR] n2k Cloud deploy rootdisksize did not fall back to capacity_bytes" >&2
  printf '%s\n' "${params_capacity}" >&2
  exit 1
}

[[ "$(n2k_cloud_api_method deployVirtualMachineForVolume 100)" == "POST" ]] || {
  echo "[ERR] deployVirtualMachineForVolume should prefer POST" >&2
  exit 1
}
N2K_CLOUD_POST_THRESHOLD=10
[[ "$(n2k_cloud_api_method listApis 100)" == "POST" ]] || {
  echo "[ERR] long Cloud API queries should use POST in auto mode" >&2
  exit 1
}
unset N2K_CLOUD_POST_THRESHOLD

query="$(n2k_cloud_params_query "$(jq -nc '{"details[0].rootdisksize":"30"}')")"
[[ "${query}" == "details[0].rootdisksize=30" ]] || {
  echo "[ERR] Cloud API parameter keys should remain literal while values are encoded" >&2
  printf '%s\n' "${query}" >&2
  exit 1
}

body_file="${WORK_DIR}/body.json"
header_file="${WORK_DIR}/headers.txt"
cat > "${body_file}" <<'JSON'
{"deployvirtualmachineforvolumeresponse":{"uuidList":[],"errorcode":431,"cserrorcode":4350,"errortext":"This disk offering requires a custom size specified"}}
JSON
cat > "${header_file}" <<'EOF'
HTTP/1.1 431 Request Header Fields Too Large
Content-Type: application/json;charset=utf-8
X-Description: This disk offering requires a custom size specified
EOF
summary="$(n2k_cloud_response_error_summary "${body_file}" "${header_file}")"
[[ "${summary}" == *"errorcode=431"* && "${summary}" == *"cserrorcode=4350"* && "${summary}" == *"errortext=This disk offering requires a custom size specified"* ]] || {
  echo "[ERR] n2k Cloud API error summary did not preserve 431 details" >&2
  printf '%s\n' "${summary}" >&2
  exit 1
}

echo "[OK] n2k Cloud target rootdisksize and API method/error helpers passed"
