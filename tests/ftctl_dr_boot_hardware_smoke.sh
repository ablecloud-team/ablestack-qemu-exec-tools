#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/ftctl/dr_runtime.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cat > "${TMP}/profile.json" <<'JSON'
{"mapping":{"source":{"hardware":{"firmware":"UEFI","secureBoot":false,"cpuCount":4,"vmDetails":{"UEFI":"LEGACY","iothreads":"false","io.policy":"native","memory":"8192","tpmversion":"NONE"}}}}}
JSON
result="$(ftctl_dr_runtime_boot_hardware "${TMP}/profile.json")"
jq -e '.firmware == "UEFI" and .vmDetails.UEFI == "LEGACY" and .vmDetails.tpmversion == "NONE" and (.vmDetails | has("iothreads") | not) and (has("cpuCount") | not)' <<<"${result}" >/dev/null
[[ "$(ftctl_dr_runtime_boot_hardware "${TMP}/missing")" == '{}' ]]
echo 'DR boot profile evidence smoke: PASS'
