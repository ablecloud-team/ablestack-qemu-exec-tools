#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
v2k_load_vddk_cred_from_manifest() {
  local manifest="$1"
  local cred
  cred="$(jq -r '.source.vddk.cred_file // empty' "${manifest}" 2>/dev/null || true)"
  if [[ -n "${cred}" && -f "${cred}" ]]; then
    # shellcheck disable=SC1090
    source "${cred}"
  fi
  export VDDK_USER="${VDDK_USER:-${GOVC_USERNAME:-}}" VDDK_PASSWORD="${VDDK_PASSWORD:-${GOVC_PASSWORD:-}}"
  [[ -n "${VDDK_USER}" && -n "${VDDK_PASSWORD}" ]] || { echo 'VDDK runtime credentials are required' >&2; return 32; }
}
