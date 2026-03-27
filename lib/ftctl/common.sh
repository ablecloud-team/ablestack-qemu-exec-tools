#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_die() {
  echo "ERROR: $*" >&2
  return 10
}

ftctl_warn() {
  echo "WARN: $*" >&2
}

ftctl_info() {
  echo "INFO: $*"
}

ftctl_now_iso8601() {
  date +"%Y-%m-%dT%H:%M:%S%z" | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'
}

ftctl_rand_id() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    head -c 8 /proc/sys/kernel/random/uuid
    return 0
  fi
  printf "%08x" "$((( $(date +%s) ^ $$ ) & 0xffffffff ))"
}

ftctl_ensure_dir() {
  local d="${1-}"
  local mode="${2-0755}"
  [[ -n "${d}" ]] || return 10
  [[ -d "${d}" ]] || mkdir -p "${d}"
  chmod "${mode}" "${d}" 2>/dev/null || true
}
