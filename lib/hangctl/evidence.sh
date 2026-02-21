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

# Commit 09:
# - Evidence collection (text + journal) BEFORE any action
# - Memory dump generation (virsh dump --memory-only) with disk/rate checks
# - Write pointer files under evidence dir; keep dump files under HANGCTL_DUMP_DIR

# Dump watch tuning (Commit 09.0.1 hotfix)
# If dump file size is stable for N consecutive checks, treat as "completed".
HANGCTL__DUMP_STABLE_COUNT_DEFAULT=3
HANGCTL__DUMP_STABLE_INTERVAL_SEC_DEFAULT=1

HANGCTL__DUMP_COUNT_THIS_SCAN=0

hangctl__sanitize_name() {
  local s="${1-}"
  s="${s//\//_}"
  s="${s// /_}"
  s="${s//:/_}"
  echo "${s}"
}

hangctl_evidence_dir() {
  # usage: hangctl_evidence_dir <vm> <incident_id>
  local vm="${1-}"
  local incident_id="${2-}"
  local scan_id
  scan_id="$(hangctl_get_scan_id)"
  [[ -z "${scan_id}" ]] && scan_id="$(hangctl_new_scan_id)"
  local base="${HANGCTL_EVIDENCE_DIR-}"
  [[ -z "${base}" ]] && base="/var/log/ablestack-vm-hangctl/evidence"
  local vmsafe
  vmsafe="$(hangctl__sanitize_name "${vm}")"
  echo "${base}/${scan_id}/${incident_id}/${vmsafe}"
}

hangctl_dump_dir_for_incident() {
  # usage: hangctl_dump_dir_for_incident <vm> <incident_id>
  local vm="${1-}"
  local incident_id="${2-}"
  local scan_id
  scan_id="$(hangctl_get_scan_id)"
  [[ -z "${scan_id}" ]] && scan_id="$(hangctl_new_scan_id)"
  local base="${HANGCTL_DUMP_DIR-}"
  [[ -z "${base}" ]] && base="/var/lib/libvirt/dump"
  local vmsafe
  vmsafe="$(hangctl__sanitize_name "${vm}")"
  echo "${base}/${vmsafe}/${scan_id}/${incident_id}"
}

hangctl__write_file() {
  local path="${1-}"
  local content="${2-}"
  local dir
  dir="$(dirname "${path}")"
  mkdir -p "${dir}" 2>/dev/null || true
  printf "%s\n" "${content}" > "${path}"
}

hangctl__save_cmd_output() {
  # usage:
  #   hangctl__save_cmd_output <vm> <incident_id> <kind> <timeout_sec> <outfile> -- <cmd...>
  local vm="${1-}"
  local incident_id="${2-}"
  local kind="${3-}"
  local timeout_sec="${4-}"
  local outfile="${5-}"
  shift 5
  if [[ "${1-}" != "--" ]]; then
    hangctl_log_event "evidence" "evidence.item" "fail" "${vm}" "${incident_id}" "2" "kind=${kind} reason=invalid_args"
    return 2
  fi
  shift

  local out err rc
  out=""; err=""; rc=0
  hangctl_cmd_run "${timeout_sec}" out err rc -- "$@" || true

  # journalctl sometimes returns rc=1 when no entries are available; treat as warn/ok (not a hard fail)
  if [[ "${kind}" == journal.* && "${rc}" == "1" ]]; then
    # keep files for evidence, but mark as warn so pipeline is not interrupted
    rc=0
  fi

  hangctl__write_file "${outfile}" "${out}"
  if [[ -n "${err}" ]]; then
    hangctl__write_file "${outfile}.err" "${err}"
  fi

  local result
  result="$(hangctl__result_from_rc "${rc}")"
  local sz
  sz="$(wc -c < "${outfile}" 2>/dev/null | xargs || echo 0)"
  local path_url
  path_url="${outfile// /%20}"
  hangctl_log_event "evidence" "evidence.item" "${result}" "${vm}" "${incident_id}" "${rc}" \
    "kind=${kind} bytes=${sz} path_url=${path_url}"
  return 0
}

hangctl_fs_free_gb() {
  # usage: hangctl_fs_free_gb <path>
  local p="${1-}"
  [[ -z "${p}" ]] && p="/"
  if ! command -v df >/dev/null 2>&1; then
    echo "0"
    return 0
  fi
  # df -BG: Avail column as e.g. "123G"
  df -BG "${p}" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}' | head -n 1
}

hangctl__kill_best_effort() {
  local pid="${1-}"
  [[ -z "${pid}" ]] && return 0
  if kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    sleep 2
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null || true
    sleep 1
  fi
  return 0
}

hangctl__run_dump_with_watch() {
  # Run virsh dump in background and watch dump file growth.
  # Success conditions:
  #   - virsh exits with rc=0
  #   - OR dump file becomes stable (size unchanged for stable_count checks) before timeout
  #
  # usage:
  #   hangctl__run_dump_with_watch <timeout_sec> <stable_count> <stable_interval_sec> \
  #     <out_var> <err_var> <rc_var> -- <cmd...> <dump_path>
  local timeout_sec="${1-}"
  local stable_count_need="${2-}"
  local stable_interval="${3-}"
  local -n _out="${4}"
  local -n _err="${5}"
  local -n _rc="${6}"
  shift 6
  if [[ "${1-}" != "--" ]]; then
    _out=""; _err="invalid_args"; _rc=2
    return 2
  fi
  shift

  _out=""; _err=""; _rc=0
  [[ -z "${timeout_sec}" ]] && timeout_sec="60"
  [[ -z "${stable_count_need}" ]] && stable_count_need="${HANGCTL__DUMP_STABLE_COUNT_DEFAULT}"
  [[ -z "${stable_interval}" ]] && stable_interval="${HANGCTL__DUMP_STABLE_INTERVAL_SEC_DEFAULT}"

  # last arg is dump_path
  local dump_path="${@: -1}"

  local tmp_out tmp_err
  tmp_out="$(mktemp -t hangctl.dump.out.XXXXXX)"
  tmp_err="$(mktemp -t hangctl.dump.err.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_out}' '${tmp_err}' 2>/dev/null || true" RETURN

  # Start in background (inherit stdin; capture stdout/stderr)
  "$@" >"${tmp_out}" 2>"${tmp_err}" &
  local pid=$!

  local start_ts now_ts elapsed
  start_ts="$(date +%s)"

  local last_size="-1"
  local stable_count="0"
  local assumed_complete="0"

  while true; do
    now_ts="$(date +%s)"
    elapsed="$((now_ts - start_ts))"

    # process finished?
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" 2>/dev/null
      _rc=$?
      break
    fi

    # watch dump file growth
    if [[ -f "${dump_path}" ]]; then
      local sz
      sz="$(wc -c < "${dump_path}" 2>/dev/null | xargs || echo 0)"
      if [[ "${sz}" -gt 0 && "${sz}" == "${last_size}" ]]; then
        stable_count="$((stable_count + 1))"
      else
        stable_count="0"
        last_size="${sz}"
      fi
      if [[ "${stable_count}" -ge "${stable_count_need}" ]]; then
        assumed_complete="1"
        break
      fi
    fi

    # timeout?
    if [[ "${elapsed}" -ge "${timeout_sec}" ]]; then
      _rc=124
      break
    fi
    sleep "${stable_interval}"
  done

  # If file seems complete but virsh still running, kill it and treat as success.
  if [[ "${assumed_complete}" == "1" ]]; then
    hangctl__kill_best_effort "${pid}"
    _rc=0
  elif [[ "${_rc}" == "124" ]]; then
    hangctl__kill_best_effort "${pid}"
  fi

  _out="$(cat "${tmp_out}" 2>/dev/null || true)"
  _err="$(cat "${tmp_err}" 2>/dev/null || true)"

  # Export extra markers via stderr prefix for caller if needed (kept simple: caller checks rc + file size)
  return "${_rc}"
}

hangctl_collect_evidence_pre_action() {
  # usage:
  #   hangctl_collect_evidence_pre_action <vm> <incident_id> <reason> <domstate> <stuck_sec> <qmp_status>
  local vm="${1-}"
  local incident_id="${2-}"
  local reason="${3-}"
  local domstate="${4-}"
  local stuck_sec="${5-}"
  local qmp_status="${6-}"

  if [[ "${HANGCTL_EVIDENCE_ENABLE-1}" != "1" ]]; then
    hangctl_log_event "evidence" "evidence.start" "skip" "${vm}" "${incident_id}" "" "reason=disabled"
    return 0
  fi

  local edir
  edir="$(hangctl_evidence_dir "${vm}" "${incident_id}")"
  mkdir -p "${edir}" 2>/dev/null || true

  local t
  t="${HANGCTL_EVIDENCE_TIMEOUT_SEC-3}"
  local jsec
  jsec="${HANGCTL_EVIDENCE_JOURNAL_SEC-180}"
  local edir_url
  edir_url="${edir// /%20}"

  hangctl_log_event "evidence" "evidence.start" "ok" "${vm}" "${incident_id}" "" \
    "evidence_dir_url=${edir_url} timeout_sec=${t} journal_sec=${jsec}"

  hangctl__write_file "${edir}/meta.txt" \
    "vm=${vm}
incident_id=${incident_id}
reason=${reason}
domstate=${domstate}
stuck_sec=${stuck_sec}
qmp_status=${qmp_status}
policy=${HANGCTL_POLICY}
dry_run=${HANGCTL_DRY_RUN}
ts=$(date -Is)
scan_id=$(hangctl_get_scan_id)"
  hangctl_log_event "evidence" "evidence.item" "ok" "${vm}" "${incident_id}" "" \
    "kind=meta path_url=${edir_url}/meta.txt"

  hangctl__save_cmd_output "${vm}" "${incident_id}" "virsh.dominfo" "${t}" "${edir}/virsh.dominfo.txt" -- \
    virsh -c qemu:///system dominfo "${vm}"
  hangctl__save_cmd_output "${vm}" "${incident_id}" "virsh.domuuid" "${t}" "${edir}/virsh.domuuid.txt" -- \
    virsh -c qemu:///system domuuid "${vm}"
  hangctl__save_cmd_output "${vm}" "${incident_id}" "virsh.domstate" "${t}" "${edir}/virsh.domstate.txt" -- \
    virsh -c qemu:///system domstate "${vm}"

  if [[ "${HANGCTL_EVIDENCE_DUMPXML-1}" == "1" ]]; then
    hangctl__save_cmd_output "${vm}" "${incident_id}" "virsh.dumpxml" "${t}" "${edir}/virsh.dumpxml.xml" -- \
      virsh -c qemu:///system dumpxml "${vm}"
  else
    hangctl_log_event "evidence" "evidence.item" "skip" "${vm}" "${incident_id}" "" "kind=virsh.dumpxml reason=disabled"
  fi

  local since="now-${jsec} seconds"
  hangctl__save_cmd_output "${vm}" "${incident_id}" "journal.libvirtd" "${t}" "${edir}/journal.libvirtd.txt" -- \
    journalctl -u libvirtd --since "${since}" --no-pager

  hangctl_log_event "evidence" "evidence.end" "ok" "${vm}" "${incident_id}" "" \
    "evidence_dir_url=${edir_url}"
  return 0
}

hangctl_collect_dump_pre_action() {
  # usage:
  #   hangctl_collect_dump_pre_action <vm> <incident_id> <out_dump_path> <out_sha256> <out_bytes>
  local vm="${1-}"
  local incident_id="${2-}"
  local -n _out_dump_path="${3}"
  local -n _out_sha256="${4}"
  local -n _out_bytes="${5}"

  _out_dump_path=""
  _out_sha256=""
  _out_bytes="0"

  if [[ "${HANGCTL_DUMP_ENABLE-1}" != "1" ]]; then
    hangctl_log_event "evidence" "dump.start" "skip" "${vm}" "${incident_id}" "" "reason=disabled"
    return 0
  fi

  local max_per
  max_per="${HANGCTL_DUMP_MAX_PER_SCAN-1}"
  if [[ "${HANGCTL__DUMP_COUNT_THIS_SCAN}" -ge "${max_per}" ]]; then
    hangctl_log_event "evidence" "dump.start" "skip" "${vm}" "${incident_id}" "" "reason=rate_limited max_per_scan=${max_per}"
    return 0
  fi

  local dump_base
  dump_base="${HANGCTL_DUMP_DIR-}"
  [[ -z "${dump_base}" ]] && dump_base="/var/lib/libvirt/dump"

  local free_gb need_gb
  free_gb="$(hangctl_fs_free_gb "${dump_base}")"
  need_gb="${HANGCTL_DUMP_MIN_FREE_GB-10}"
  if [[ -n "${free_gb}" && -n "${need_gb}" ]]; then
    if [[ "${free_gb}" -lt "${need_gb}" ]]; then
      hangctl_log_event "evidence" "dump.start" "skip" "${vm}" "${incident_id}" "" \
        "reason=disk_low free_gb=${free_gb} min_free_gb=${need_gb} dump_dir=${dump_base}"
      return 0
    fi
  fi

  local ddir
  ddir="$(hangctl_dump_dir_for_incident "${vm}" "${incident_id}")"
  mkdir -p "${ddir}" 2>/dev/null || true

  local dump_path
  dump_path="${ddir}/memdump.bin"

  # Set output dump path early (helps upper layer even if dump runner behaves unexpectedly)
  _out_dump_path="${dump_path}"

  local ddir_url
  ddir_url="${ddir// /%20}"
  local tout
  tout="${HANGCTL_DUMP_TIMEOUT_SEC-60}"
  hangctl_log_event "evidence" "dump.start" "ok" "${vm}" "${incident_id}" "" \
    "dump_dir_url=${ddir_url} timeout_sec=${tout} min_free_gb=${need_gb} free_gb=${free_gb}"

  local out err rc
  out=""; err=""; rc=0
  # Commit 09.0.1:
  # virsh dump may create the file but keep running (rare). Watch the dump file and accept "stable" completion.
  local stable_need stable_interval
  stable_need="${HANGCTL_DUMP_STABLE_COUNT-${HANGCTL__DUMP_STABLE_COUNT_DEFAULT}}"
  stable_interval="${HANGCTL_DUMP_STABLE_INTERVAL_SEC-${HANGCTL__DUMP_STABLE_INTERVAL_SEC_DEFAULT}}"
  hangctl__run_dump_with_watch "${tout}" "${stable_need}" "${stable_interval}" out err rc -- \
    virsh -c qemu:///system dump --memory-only --crash "${vm}" "${dump_path}" || true 

  local result
  if [[ "${rc}" == "124" || "${rc}" == "143" ]]; then
    result="timeout"
  else
    result="$(hangctl__result_from_rc "${rc}")"
  fi

  if [[ "${result}" != "ok" ]]; then
    local err_short="${err:0:200}"
    local err_url="${err_short// /%20}"
    hangctl_log_event "evidence" "dump.end" "${result}" "${vm}" "${incident_id}" "${rc}" \
      "dump_path_url=${dump_path// /%20} err_url=${err_url} timeout_sec=${tout} stable_need=${stable_need} stable_interval_sec=${stable_interval}"
    return 0
  fi

  local bytes
  bytes="$(wc -c < "${dump_path}" 2>/dev/null | xargs || echo 0)"
  local sha=""
  if [[ "${HANGCTL_DUMP_SHA256-1}" == "1" ]] && command -v sha256sum >/dev/null 2>&1; then
    sha="$(sha256sum "${dump_path}" 2>/dev/null | awk '{print $1}' | head -n 1)"
  fi

  _out_dump_path="${dump_path}"
  _out_sha256="${sha}"
  _out_bytes="${bytes}"

  HANGCTL__DUMP_COUNT_THIS_SCAN="$((HANGCTL__DUMP_COUNT_THIS_SCAN + 1))"

  hangctl_log_event "evidence" "dump.file" "ok" "${vm}" "${incident_id}" "" \
    "dump_path_url=${dump_path// /%20} bytes=${bytes} sha256=${sha}"

  # write pointer under evidence dir
  local edir
  edir="$(hangctl_evidence_dir "${vm}" "${incident_id}")"
  mkdir -p "${edir}" 2>/dev/null || true
  hangctl__write_file "${edir}/dump.pointer" \
    "dump_path=${dump_path}
bytes=${bytes}
sha256=${sha}
ts=$(date -Is)
scan_id=$(hangctl_get_scan_id)
incident_id=${incident_id}
vm=${vm}"
  local pointer_path pointer_url
  pointer_path="${edir}/dump.pointer"
  pointer_url="${pointer_path// /%20}"
  hangctl_log_event "evidence" "evidence.item" "ok" "${vm}" "${incident_id}" "" \
    "kind=dump.pointer path_url=${pointer_url}"

  hangctl_log_event "evidence" "dump.end" "ok" "${vm}" "${incident_id}" "" \
    "dump_path_url=${dump_path// /%20} bytes=${bytes}"
  return 0
}
