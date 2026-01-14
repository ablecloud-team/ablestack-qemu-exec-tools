#!/usr/bin/env bash
# ---------------------------------------------------------------------
# TODO: Copy the exact author/license header from bin/vm_exec.sh here.
# ---------------------------------------------------------------------
set -euo pipefail

# ---------------------------
# NBD allocator utilities (productized)
# - robust lock (atomic mkdir)
# - in-use detection via /sys/block/nbdX/pid
# - disconnect waits until kernel releases nbd
# ---------------------------

v2k_nbd_sys_pid() {
  local dev="$1" base pidf
  base="$(basename "${dev}")"
  pidf="/sys/block/${base}/pid"
  if [[ -r "${pidf}" ]]; then
    cat "${pidf}" 2>/dev/null || true
  else
    echo ""
  fi
}

v2k_nbd_is_in_use() {
  local dev="$1" pid
  pid="$(v2k_nbd_sys_pid "${dev}")"
  # kernel exports "0" or empty when free
  if [[ -n "${pid}" && "${pid}" != "0" ]]; then
    return 0
  fi
  # fallback (older stacks / transient): nbd-client query
  if command -v nbd-client >/dev/null 2>&1; then
    if nbd-client -c "${dev}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

v2k_nbd_lock_try() {
  # atomic lockdir per device. stores pid for stale cleanup.
  local lock_dir="$1" dev="$2" base lock
  base="$(basename "${dev}")"
  lock="${lock_dir}/${base}.lock.d"

  if mkdir "${lock}" >/dev/null 2>&1; then
    echo "$$" > "${lock}/pid" 2>/dev/null || true
    date +%s > "${lock}/ts" 2>/dev/null || true
    return 0
  fi

  # stale lock handling: if owner pid is gone AND device is free -> remove lock and retry once
  local owner
  owner="$(cat "${lock}/pid" 2>/dev/null || true)"
  if [[ -n "${owner}" ]] && ! kill -0 "${owner}" >/dev/null 2>&1; then
    if ! v2k_nbd_is_in_use "${dev}"; then
      rm -rf "${lock}" >/dev/null 2>&1 || true
      if mkdir "${lock}" >/dev/null 2>&1; then
        echo "$$" > "${lock}/pid" 2>/dev/null || true
        date +%s > "${lock}/ts" 2>/dev/null || true
        return 0
      fi
    fi
  fi
  return 1
}

v2k_nbd_lock_release() {
  local lock_dir="$1" dev="$2" base lock
  base="$(basename "${dev}")"
  lock="${lock_dir}/${base}.lock.d"
  rm -rf "${lock}" >/dev/null 2>&1 || true
}

# Find a free /dev/nbdX and lock it.
v2k_nbd_alloc() {
  local lock_dir="${V2K_WORKDIR:-/tmp}/nbd-lock"
  mkdir -p "${lock_dir}"
  modprobe nbd max_part=16 >/dev/null 2>&1 || true

  local x dev lock
  for x in $(seq 0 63); do
    dev="/dev/nbd${x}"
    [[ -b "${dev}" ]] || continue

    # Try to acquire per-dev lock
    if v2k_nbd_lock_try "${lock_dir}" "${dev}"; then
      # Check if in use (kernel pid is authoritative)
      if v2k_nbd_is_in_use "${dev}"; then
        v2k_nbd_lock_release "${lock_dir}" "${dev}"
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
  v2k_nbd_lock_release "${lock_dir}" "${dev}"
}

v2k_nbd_disconnect() {
  local dev="$1"
  # best-effort detach (nbd-client, then qemu-nbd) + wait for kernel release
  command -v nbd-client >/dev/null 2>&1 && nbd-client -d "${dev}" >/dev/null 2>&1 || true
  command -v qemu-nbd   >/dev/null 2>&1 && qemu-nbd -d "${dev}"   >/dev/null 2>&1 || true

  # Wait until /sys/block/nbdX/pid becomes 0 (avoid reattach races)
  local i pid
  for i in $(seq 1 50); do
    pid="$(v2k_nbd_sys_pid "${dev}")"
    if [[ -z "${pid}" || "${pid}" == "0" ]]; then
      return 0
    fi
    sleep 0.1
  done
  # last resort: still return success (caller trap will prevent leak chaining)
  return 0
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

v2k_kill_pidfile_safe() {
  local pidfile="$1"
  local match="${2:-}"   # optional token (e.g. unix socket path) to ensure we only kill our own process

  [[ -f "${pidfile}" ]] || return 0
  local pid
  pid="$(cat "${pidfile}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] || { rm -f "${pidfile}" || true; return 0; }
  [[ "${pid}" =~ ^[0-9]+$ ]] || { rm -f "${pidfile}" || true; return 0; }
  [[ -d "/proc/${pid}" ]] || { rm -f "${pidfile}" || true; return 0; }

  # Safety: ensure the pid is an nbdkit process, and (if match provided) it contains the token
  local cmdline
  cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  if [[ -z "${cmdline}" ]]; then
    rm -f "${pidfile}" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ "${cmdline}" != *"nbdkit"* ]]; then
    rm -f "${pidfile}" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ -n "${match}" && "${cmdline}" != *"${match}"* ]]; then
    rm -f "${pidfile}" >/dev/null 2>&1 || true
    return 0
  fi

  kill "${pid}" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 50); do
    kill -0 "${pid}" >/dev/null 2>&1 || break
    sleep 0.1
  done
  kill -9 "${pid}" >/dev/null 2>&1 || true
  rm -f "${pidfile}" >/dev/null 2>&1 || true
}

v2k_nbdkit_kill_by_token() {
  # Kill ONLY our nbdkit process(es) identified by unix socket token.
  # Why: nbdkit may reexec and PID in pidfile can be stale.
  #
  # Args:
  #   $1: pidfile (optional)
  #   $2: sock token (required for safe kill)
  local pidfile="${1:-}"
  local sock="${2:-}"

  [[ -n "${sock}" ]] || return 0

  # 1) Try pidfile first (fast path)
  if [[ -n "${pidfile}" && -f "${pidfile}" ]]; then
    v2k_kill_pidfile_safe "${pidfile}" "${sock}" >/dev/null 2>&1 || true
  fi

  # 2) Fallback: find by cmdline token (ONLY our socket path)
  # NOTE: do not kill if sock is empty -> avoid collateral.
  local pids=""
  if command -v pgrep >/dev/null 2>&1; then
    # match both "nbdkit" and "-U <sock>"
    pids="$(pgrep -f "nbdkit .* -U ${sock}" 2>/dev/null || true)"
  else
    # fallback without pgrep: scan /proc
    local pid cmdline
    for pid in /proc/[0-9]*; do
      pid="${pid##*/}"
      cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
      [[ -n "${cmdline}" ]] || continue
      [[ "${cmdline}" == *"nbdkit"* && "${cmdline}" == *" -U ${sock}"* ]] || continue
      pids+="${pid}"$'\n'
    done
  fi

  local p
  for p in ${pids}; do
    [[ "${p}" =~ ^[0-9]+$ ]] || continue
    kill "${p}" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 50); do
      kill -0 "${p}" >/dev/null 2>&1 || break
      sleep 0.1
    done
    kill -9 "${p}" >/dev/null 2>&1 || true
  done
}

v2k_force_cleanup_run() {
  # Force cleanup ONLY resources belonging to current run-id namespace.
  # It does NOT touch other runs because it only matches /tmp paths with this run-id.
  local run_id="${1:-${V2K_RUN_ID:-}}"
  [[ -n "${run_id}" ]] || return 0

  local pidfile sock
  # pidfile naming in transfer_*: /tmp/v2k_nbdkit_${V2K_RUN_ID}_${idx}.pid
  for pidfile in "/tmp/v2k_nbdkit_${run_id}_"*.pid; do
    [[ -e "${pidfile}" ]] || continue
    # derive sock path: /tmp/v2k_src_${run_id}_${idx}.sock
    sock="${pidfile/v2k_nbdkit_/v2k_src_}"
    sock="${sock%.pid}.sock"
    v2k_nbdkit_kill_by_token "${pidfile}" "${sock}" >/dev/null 2>&1 || true
    rm -f "${pidfile}" >/dev/null 2>&1 || true
    rm -f "${sock}" >/dev/null 2>&1 || true
  done
}

v2k_kill_pidfile() {
  local pidfile="$1"
  v2k_kill_pidfile_safe "${pidfile}" ""
}

# ---- nbdkit safe stop (PID ONLY; never kill process group) ----
v2k_is_pid_alive() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 1
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  [[ -d "/proc/${pid}" ]]
}

v2k_is_nbdkit_pid_for_sock() {
  local pid="$1" sock="$2"
  v2k_is_pid_alive "${pid}" || return 1
  [[ -n "${sock}" ]] || return 1
  local cmd
  cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  # Must be nbdkit and must reference the socket path we generated for this run.
  [[ "${cmd}" == *"nbdkit"* ]] || return 1
  [[ "${cmd}" == *"${sock}"* ]] || return 1
  return 0
}

# Stop nbdkit safely using pidfile + (optional) socket token verification.
v2k_nbdkit_stop() {
  local pidfile="$1" sock="${2:-}"
  [[ -f "${pidfile}" ]] || return 0
  local pid
  pid="$(cat "${pidfile}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] || { rm -f "${pidfile}" || true; return 0; }

  # If sock is given, verify pid belongs to our nbdkit instance.
  if [[ -n "${sock}" ]]; then
    v2k_is_nbdkit_pid_for_sock "${pid}" "${sock}" || {
      # Do not kill unknown PID (prevents killing unrelated processes)
      return 0
    }
  fi

  # PID-only termination (NO negative pid, NO pkill -f)
  kill -TERM "${pid}" >/dev/null 2>&1 || true
  # Wait briefly
  local i
  for i in $(seq 1 20); do
    v2k_is_pid_alive "${pid}" || break
    sleep 0.2
  done
  v2k_is_pid_alive "${pid}" && kill -KILL "${pid}" >/dev/null 2>&1 || true
  rm -f "${pidfile}" >/dev/null 2>&1 || true
}

# Force cleanup ONLY for this run_id: kill nbdkit instances whose pidfile matches the run pattern
# AND whose cmdline references the run socket token.
v2k_force_cleanup_run() {
  local run_id="$1"
  [[ -n "${run_id}" ]] || return 0
  local pidfile pid sock idx
  for pidfile in /tmp/v2k_nbdkit_"${run_id}"_*.pid; do
    [[ -f "${pidfile}" ]] || continue
    idx="$(basename "${pidfile}" | sed -E "s/^v2k_nbdkit_${run_id}_([0-9]+)\\.pid$/\\1/")"
    [[ "${idx}" =~ ^[0-9]+$ ]] || continue
    sock="/tmp/v2k_src_${run_id}_${idx}.sock"
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    [[ -n "${pid}" ]] || { rm -f "${pidfile}" || true; continue; }
    v2k_nbdkit_stop "${pidfile}" "${sock}" || true
    rm -f "${sock}" >/dev/null 2>&1 || true
  done
}