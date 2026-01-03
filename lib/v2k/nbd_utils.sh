#!/usr/bin/env bash
# ---------------------------------------------------------------------
# TODO: Copy the exact author/license header from bin/vm_exec.sh here.
# ---------------------------------------------------------------------
set -euo pipefail

# Find a free /dev/nbdX and lock it (best-effort).
v2k_nbd_alloc() {
  local lock_dir="${V2K_WORKDIR:-/tmp}/nbd-lock"
  mkdir -p "${lock_dir}"
  modprobe nbd max_part=16 >/dev/null 2>&1 || true

  local x dev lock
  for x in $(seq 0 63); do
    dev="/dev/nbd${x}"
    lock="${lock_dir}/nbd${x}.lock"
    [[ -b "${dev}" ]] || continue

    # Try to acquire lock atomically
    if ( set -o noclobber; echo "$$" > "${lock}" ) 2>/dev/null; then
      # Check if in use (nbd-client -c prints something if connected)
      if nbd-client -c "${dev}" >/dev/null 2>&1; then
        # busy
        rm -f "${lock}" || true
        continue
      fi
      echo "${dev}"
      return 0
    fi
  done

  echo "No free /dev/nbdX found" >&2
  return 1
}

v2k_nbd_free() {
  local dev="$1"
  local lock_dir="${V2K_WORKDIR:-/tmp}/nbd-lock"
  local base
  base="$(basename "${dev}")"
  rm -f "${lock_dir}/${base}.lock" >/dev/null 2>&1 || true
}

v2k_nbd_disconnect() {
  local dev="$1"
  # nbd-client -d is safest; qemu-nbd -d for qemu-nbd attach.
  nbd-client -d "${dev}" >/dev/null 2>&1 || true
  qemu-nbd -d "${dev}" >/dev/null 2>&1 || true
}

v2k_wait_unix_socket() {
  local sock="$1" tries="${2:-20}" delay="${3:-1}"
  local i
  for i in $(seq 1 "${tries}"); do
    [[ -S "${sock}" ]] && return 0
    sleep "${delay}"
  done
  return 1
}

v2k_kill_pidfile() {
  local pidfile="$1"
  [[ -f "${pidfile}" ]] || return 0
  local pid
  pid="$(cat "${pidfile}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] || { rm -f "${pidfile}" || true; return 0; }

  kill "${pid}" >/dev/null 2>&1 || true
  sleep 1
  kill -9 "${pid}" >/dev/null 2>&1 || true
  rm -f "${pidfile}" >/dev/null 2>&1 || true
}
