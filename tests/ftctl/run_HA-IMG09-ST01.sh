#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/run_case.sh" "${SCRIPT_DIR}/cases/HA-IMG09-ST01.env"
