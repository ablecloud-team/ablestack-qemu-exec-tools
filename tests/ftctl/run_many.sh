#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOMATION_ENV="${AUTOMATION_ENV:-${SCRIPT_DIR}/automation.env}"

if [[ ! -f "${AUTOMATION_ENV}" ]]; then
  echo "[FTCTL-TEST][FAIL] automation env not found: ${AUTOMATION_ENV}" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "${AUTOMATION_ENV}"
set +a

for test_id in ${AUTOMATION_TARGET_IDS//,/ }; do
  echo ""
  echo "============================================================"
  echo "RUNNING ${test_id}"
  echo "============================================================"
  "${SCRIPT_DIR}/run_case.sh" "${SCRIPT_DIR}/cases/${test_id}.env"
done
