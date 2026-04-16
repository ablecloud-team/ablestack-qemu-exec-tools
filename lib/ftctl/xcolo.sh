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

ftctl_xcolo_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").xcolo"
}

ftctl_xcolo_state_write() {
  local vm="${1-}"
  shift
  local path tmp line
  path="$(ftctl_xcolo_state_path "${vm}")"
  tmp="$(mktemp -t ftctl.xcolo.XXXXXX)"
  for line in "$@"; do
    printf "%s\n" "${line}" >> "${tmp}"
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_xcolo_parse_tcp_endpoint() {
  local endpoint="${1-}"
  local host_var="${2}"
  local port_var="${3}"
  local rest host port
  [[ "${endpoint}" == tcp:* ]] || {
    echo "ERROR: x-colo endpoint must start with tcp:" >&2
    return 2
  }
  rest="${endpoint#tcp:}"
  host="${rest%:*}"
  port="${rest##*:}"
  [[ -n "${host}" && -n "${port}" ]] || {
    echo "ERROR: invalid x-colo endpoint: ${endpoint}" >&2
    return 2
  }
  printf -v "${host_var}" '%s' "${host}"
  printf -v "${port_var}" '%s' "${port}"
}

ftctl_xcolo_qmp() {
  local uri="${1-}"
  local vm="${2-}"
  local payload="${3-}"
  local out_var="${4}"
  local rc_var="${5}"
  local qmp_out qmp_err qmp_rc

  qmp_out=""
  qmp_err=""
  qmp_rc=0
  ftctl_cmd_run "${FTCTL_XCOLO_QMP_TIMEOUT_SEC}" qmp_out qmp_err qmp_rc -- \
    virsh -c "${uri}" qemu-monitor-command "${vm}" --pretty "${payload}" || true
  : "${qmp_err}"
  printf -v "${out_var}" '%s' "${qmp_out}"
  printf -v "${rc_var}" '%s' "${qmp_rc}"
  return 0
}

ftctl_xcolo_qmp_require_ok() {
  local uri="${1-}"
  local vm="${2-}"
  local payload="${3-}"
  local stage="${4-}"
  local event="${5-}"
  local out rc allow_already_negotiated has_error error_desc

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "${stage}" "${event}" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" "${payload}" out rc
  allow_already_negotiated="0"
  if [[ "${payload}" == '{"execute":"qmp_capabilities"}' ]]; then
    allow_already_negotiated="1"
  fi
  has_error="0"
  error_desc="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
if not raw.strip():
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    raise SystemExit(0)
if isinstance(data, dict) and "error" in data:
    err = data.get("error") or {}
    print((err.get("desc") or "").strip())
    raise SystemExit(10)
raise SystemExit(0)
PY
)" || {
    rc="$?"
    if [[ "${rc}" == "10" ]]; then
      has_error="1"
      rc=0
    fi
  }
  if [[ "${has_error}" == "1" && "${allow_already_negotiated}" == "1" ]]; then
    if [[ "${error_desc}" == *"Capabilities negotiation is already complete"* ]]; then
      has_error="0"
      error_desc=""
    fi
  fi
  if [[ "${rc}" != "0" || "${has_error}" == "1" ]]; then
    ftctl_log_event "${stage}" "${event}" "fail" "${vm}" "${rc}" "uri=${uri} desc=${error_desc:-qmp_error}"
    [[ "${rc}" == "0" ]] && rc=1
    return "${rc}"
  fi
  ftctl_log_event "${stage}" "${event}" "ok" "${vm}" "" "uri=${uri}"
}

ftctl_xcolo_collect_primary_disk_binding() {
  local vm="${1-}"
  local source_path="${2-}"
  local node_var="${3}"
  local qdev_var="${4}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-block"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    return 1
  fi

  payload="$(python3 - <<'PY' "${source_path}" "${out}"
import json, sys
source = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print("|")
    raise SystemExit(0)
for item in data.get("return", []):
    ins = item.get("inserted") or {}
    image = ins.get("image") or {}
    filename = image.get("filename", "")
    node = ins.get("node-name", "")
    qdev = item.get("qdev", "")
    if filename == source:
        print(f"{node}|{qdev}")
        break
else:
    print("|")
PY
)" || payload="|"

  printf -v "${node_var}" '%s' "${payload%%|*}"
  printf -v "${qdev_var}" '%s' "${payload##*|}"
  [[ -n "${payload%%|*}" ]]
}

ftctl_xcolo_query_running_flag() {
  local uri="${1-}"
  local vm="${2-}"
  local running_var="${3}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-status"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${running_var}" '%s' ""
    return 1
  fi
  payload="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
ret = data.get("return") if isinstance(data, dict) else {}
running = ret.get("running")
if isinstance(running, bool):
    print("true" if running else "false")
else:
    print("")
PY
)" || payload=""
  printf -v "${running_var}" '%s' "${payload}"
  [[ "${payload}" == "true" || "${payload}" == "false" ]]
}

ftctl_xcolo_query_status_name() {
  local uri="${1-}"
  local vm="${2-}"
  local status_var="${3}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-status"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${status_var}" '%s' ""
    return 1
  fi
  payload="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
ret = data.get("return") if isinstance(data, dict) else {}
print(ret.get("status", "") if isinstance(ret, dict) else "")
PY
)" || payload=""
  printf -v "${status_var}" '%s' "${payload}"
  [[ -n "${payload}" ]]
}

ftctl_xcolo_query_colo_mode() {
  local uri="${1-}"
  local vm="${2-}"
  local mode_var="${3}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-colo-status"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${mode_var}" '%s' ""
    return 1
  fi
  payload="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
ret = data.get("return") if isinstance(data, dict) else {}
print(ret.get("mode", "") if isinstance(ret, dict) else "")
PY
)" || payload=""
  printf -v "${mode_var}" '%s' "${payload}"
  [[ -n "${payload}" ]]
}

ftctl_xcolo_capture_runtime_snapshot() {
  local vm="${1-}"
  local prefix="${2-}"
  local primary_running="" secondary_running=""
  local primary_status="" secondary_status=""
  local primary_colo="" secondary_colo=""

  ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_running || true
  ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" secondary_running || true
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_status || true
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" secondary_status || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_colo || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" secondary_colo || true

  if [[ -n "${prefix}" ]]; then
    ftctl_state_set "${vm}" \
      "${prefix}_primary_running=${primary_running}" \
      "${prefix}_secondary_running=${secondary_running}" \
      "${prefix}_primary_status=${primary_status}" \
      "${prefix}_secondary_status=${secondary_status}" \
      "${prefix}_primary_colo_mode=${primary_colo}" \
      "${prefix}_secondary_colo_mode=${secondary_colo}"
  else
    ftctl_state_set "${vm}" \
      "xcolo_primary_running=${primary_running}" \
      "xcolo_secondary_running=${secondary_running}" \
      "xcolo_primary_status=${primary_status}" \
      "xcolo_secondary_status=${secondary_status}" \
      "xcolo_primary_colo_mode=${primary_colo}" \
      "xcolo_secondary_colo_mode=${secondary_colo}"
  fi
}

ftctl_xcolo_wait_pair_running() {
  local vm="${1-}"
  local timeout="${2:-30}"
  local secondary_vm="${3:-$vm}"
  local i primary_running secondary_running

  for ((i=0; i<timeout; i++)); do
    primary_running=""
    secondary_running=""
    ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_running || true
    ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_running || true
    if [[ "${primary_running}" == "true" && "${secondary_running}" == "true" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ftctl_xcolo_prebuilt_secondary_stage() {
  local vm="${1-}"
  local nbd_host="${2-}"
  local nbd_port="${3-}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "secondary.qmp_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}}' \
    "colo" "secondary.migrate_set_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"nbd-server-start\",\"arguments\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"}}}}" \
    "colo" "secondary.nbd_server_start" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"nbd-server-add\",\"arguments\":{\"device\":\"${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}\",\"writable\":true}}" \
    "colo" "secondary.nbd_server_add" || return 1
}

ftctl_xcolo_prebuilt_primary_stage() {
  local vm="${1-}"
  local nbd_host="${2-}"
  local nbd_port="${3-}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "primary.qmp_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"nbd\",\"node-name\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\",\"server\":{\"type\":\"inet\",\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"},\"export\":\"${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}\",\"detect-zeroes\":\"on\"}}" \
    "colo" "primary.blockdev_add" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"x-blockdev-change\",\"arguments\":{\"parent\":\"${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE}\",\"node\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\"}}" \
    "colo" "primary.x_blockdev_change" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}}' \
    "colo" "primary.migrate_set_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate\",\"arguments\":{\"uri\":\"${FTCTL_PROFILE_XCOLO_MIGRATE_URI}\"}}" \
    "colo" "primary.migrate" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate-set-parameters\",\"arguments\":{\"x-checkpoint-delay\":${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY}}}" \
    "colo" "primary.migrate_set_parameters" || return 1
}

ftctl_xcolo_primary_domain_state() {
  local vm="${1-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_XCOLO_QMP_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" domstate "${vm}" || true
  : "${err}"
  if [[ "${rc}" != "0" ]]; then
    printf '%s\n' "unknown"
    return 0
  fi
  printf '%s\n' "$(printf '%s' "${out}" | tr -d '\r' | xargs)"
}

ftctl_xcolo_local_record() {
  local out_var="${1}"
  local item=""
  ftctl_cluster_load || return 1
  ftctl_cluster_find_record_by_host_id "${FTCTL_LOCAL_HOST_ID}" item || return 1
  printf -v "${out_var}" '%s' "${item}"
}

ftctl_xcolo_primary_listen_host() {
  local port_hint="${1-}"
  local record="" host_id="" role="" mgmt_ip="" libvirt_uri="" blockcopy_ip="" xcolo_ctrl="" xcolo_data=""
  local peer_host="" peer_port="" out err rc
  if ftctl_xcolo_local_record record; then
    ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
    case "${port_hint}" in
      control)
        if [[ -n "${xcolo_ctrl}" ]]; then
          printf '%s\n' "${xcolo_ctrl}"
          return 0
        fi
        ;;
      data)
        if [[ -n "${xcolo_data}" ]]; then
          printf '%s\n' "${xcolo_data}"
          return 0
        fi
        ;;
    esac
    if [[ -n "${mgmt_ip}" ]]; then
      printf '%s\n' "${mgmt_ip}"
      return 0
    fi
  fi

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" peer_host peer_port || true
  if [[ -n "${peer_host}" && "${peer_host}" != "0.0.0.0" ]]; then
    out=""
    err=""
    rc=0
    ftctl_cmd_run "${FTCTL_XCOLO_QMP_TIMEOUT_SEC}" out err rc -- ip route get "${peer_host}" || true
    if [[ "${rc}" == "0" ]]; then
      peer_host="$(awk '{for (i=1;i<=NF;i++) if ($i=="src" && i+1<=NF) {print $(i+1); exit}}' <<< "${out}")"
      if [[ -n "${peer_host}" ]]; then
        printf '%s\n' "${peer_host}"
        return 0
      fi
    fi
  fi

  printf '%s\n' "0.0.0.0"
}

ftctl_xcolo_build_primary_qemu_args() {
  local proxy_host proxy_port nbd_host nbd_port
  local mirror_port compare_port compare_local_port compare_out_port

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" proxy_host proxy_port
  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  compare_local_port="${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}"
  compare_out_port="${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}"

  # Match the QEMU COLO startup procedure: mirror0 is non-blocking, compare1 blocks until connected.
  printf '%s\n' "-S;-chardev;socket,id=mirror0,host=0.0.0.0,port=${mirror_port},server=on,wait=off;-chardev;socket,id=compare1,host=0.0.0.0,port=${compare_port},server=on,wait=on;-chardev;socket,id=compare0,host=127.0.0.1,port=${compare_local_port},server=on,wait=off;-chardev;socket,id=compare0-0,host=127.0.0.1,port=${compare_local_port};-chardev;socket,id=compare_out,host=127.0.0.1,port=${compare_out_port},server=on,wait=off;-chardev;socket,id=compare_out0,host=127.0.0.1,port=${compare_out_port};-object;filter-mirror,id=m0,netdev=hostnet0,queue=tx,outdev=mirror0;-object;filter-redirector,id=redire0,netdev=hostnet0,queue=rx,indev=compare_out;-object;filter-redirector,id=redire1,netdev=hostnet0,queue=rx,outdev=compare0;-object;iothread,id=iothread1;-object;colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0,iothread=iothread1"
}

ftctl_xcolo_build_secondary_qemu_args() {
  local connect_ctrl connect_data proxy_host proxy_port nbd_host nbd_port
  local mirror_port compare_port

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" proxy_host proxy_port
  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port
  connect_ctrl="$(ftctl_xcolo_primary_listen_host control)"
  connect_data="$(ftctl_xcolo_primary_listen_host data)"
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"

  # Match the QEMU COLO startup procedure: the secondary does not use -S during startup.
  printf '%s\n' "-chardev;socket,id=red0,host=${connect_ctrl},port=${mirror_port},reconnect-ms=1000;-chardev;socket,id=red1,host=${connect_data},port=${compare_port},reconnect-ms=1000;-object;filter-redirector,id=f1,netdev=hostnet0,queue=tx,indev=red0;-object;filter-redirector,id=f2,netdev=hostnet0,queue=rx,outdev=red1;-object;filter-rewriter,id=rew0,netdev=hostnet0,queue=all;-incoming;${FTCTL_PROFILE_XCOLO_MIGRATE_URI}"
}

ftctl_xcolo_doc_alignment_summary() {
  cat <<'EOF'
COLO startup alignment checklist
1. Primary startup:
   - mirror0 server wait=off
   - compare1 server wait=on
   - compare0 / compare0-0 / compare_out / compare_out0 loopback sockets
   - filter-mirror / filter-redirector / colo-compare objects present
   - root disk on if=ide quorum node
   - startup paused with -S
2. Secondary startup:
   - red0 / red1 reconnect sockets toward primary
   - filter-redirector / filter-rewriter objects present
   - parent0 / childs0 / colo-disk0 disk graph present
   - incoming migration URI present
   - no -S on secondary startup
3. Protect QMP sequence:
   - secondary qmp_capabilities
   - secondary migrate-set-capabilities x-colo
   - secondary nbd-server-start
   - secondary nbd-server-add parent0
   - primary qmp_capabilities
   - primary blockdev-add nbd0
   - primary x-blockdev-change parent=colo-disk0 node=nbd0
   - primary migrate-set-capabilities x-colo
   - primary migrate
EOF
}

ftctl_xcolo_backup_prebuilt_pair_xml() {
  local vm="${1-}"
  local bundle_dir primary_xml standby_xml meta_file out err rc checksum persistence

  bundle_dir="$(ftctl_inventory_xml_backup_path "${vm}")"
  ftctl_ensure_dir "${bundle_dir}" "0755"
  primary_xml="${bundle_dir}/primary.xml"
  standby_xml="${bundle_dir}/standby.xml"
  meta_file="${bundle_dir}/meta"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dumpxml --security-info "${vm}" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return "${rc}"
  printf '%s\n' "${out}" > "${primary_xml}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" dumpxml --security-info "${vm}" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return "${rc}"
  printf '%s\n' "${out}" > "${standby_xml}"

  persistence="no"
  checksum=""
  if command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum "${primary_xml}" | awk '{print $1}')"
  fi
  cat > "${meta_file}" <<EOF
vm=${vm}
primary_uri=${FTCTL_PROFILE_PRIMARY_URI}
secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}
primary_xml=${primary_xml}
standby_xml=${standby_xml}
persistent=${persistence}
xml_sha256=${checksum}
EOF
  chmod 0644 "${primary_xml}" "${standby_xml}" "${meta_file}" 2>/dev/null || true
  ftctl_state_set "${vm}" \
    "xml_bundle_dir=${bundle_dir}" \
    "primary_xml_backup=${primary_xml}" \
    "standby_xml_seed=${standby_xml}" \
    "primary_persistence=${persistence}"
}

ftctl_xcolo_prepare_block_generated_xmls() {
  local vm="${1-}"
  local primary_xml_backup="${2-}"
  local standby_xml_seed="${3-}"
  local primary_source="${4-}"
  local secondary_dest="${5-}"
  local disk_format="${6-}"
  local primary_args="${7-}"
  local secondary_args="${8-}"
  local primary_generated_xml standby_generated_xml standby_vm_name

  [[ -n "${primary_xml_backup}" && -f "${primary_xml_backup}" ]] || return 1
  [[ -n "${standby_xml_seed}" && -f "${standby_xml_seed}" ]] || return 1

  primary_generated_xml="$(ftctl_primary_generated_xml_path "${vm}")"
  standby_generated_xml="$(ftctl_standby_generated_xml_path "${vm}")"
  standby_vm_name="$(ftctl_profile_secondary_vm_name_resolved "${vm}")"

  ftctl_ensure_dir "$(dirname "${primary_generated_xml}")" "0755"
  ftctl_ensure_dir "$(dirname "${standby_generated_xml}")" "0755"

  cp -f "${primary_xml_backup}" "${primary_generated_xml}"
  cp -f "${standby_xml_seed}" "${standby_generated_xml}"

  ftctl_standby__rewrite_domain_name "${standby_generated_xml}" "${standby_vm_name}"

  ftctl_xml_remove_qemu_commandline "${primary_generated_xml}" || true
  ftctl_xml_remove_qemu_commandline "${standby_generated_xml}" || true
  ftctl_xml_rewrite_first_disk_block_runtime "${primary_generated_xml}" "${primary_source}" "${disk_format}" "ro-shareable" "9" || true
  ftctl_xml_rewrite_first_disk_block_runtime "${standby_generated_xml}" "${secondary_dest}" "${disk_format}" "rw" "9" || true
  ftctl_xml_apply_qemu_commandline "${primary_generated_xml}" "${primary_args}" || true
  ftctl_xml_apply_qemu_commandline "${standby_generated_xml}" "${secondary_args}" || true
  ftctl_xml_rewrite_first_disk_block_runtime "${primary_generated_xml}" "${primary_source}" "${disk_format}" "ro-shareable" "9" || true
  ftctl_xml_rewrite_first_disk_block_runtime "${standby_generated_xml}" "${secondary_dest}" "${disk_format}" "rw" "9" || true

  ftctl_state_set "${vm}" \
    "primary_xml_generated=${primary_generated_xml}" \
    "standby_xml_generated=${standby_generated_xml}" \
    "secondary_vm_name=${standby_vm_name}"
}

ftctl_xcolo_block_runtime_dir() {
  local vm="${1-}"
  printf '%s\n' "${FTCTL_BLOCKCOPY_TARGET_BASE_DIR}/$(ftctl_state_vm_key "${vm}")/xcolo"
}

ftctl_xcolo_primary_active_overlay_path() {
  local vm="${1-}"
  printf '%s\n' "$(ftctl_xcolo_block_runtime_dir "${vm}")/primary-active.qcow2"
}

ftctl_xcolo_secondary_hidden_overlay_path() {
  local vm="${1-}"
  printf '%s\n' "$(ftctl_xcolo_block_runtime_dir "${vm}")/secondary-hidden.qcow2"
}

ftctl_xcolo_secondary_active_overlay_path() {
  local vm="${1-}"
  printf '%s\n' "$(ftctl_xcolo_block_runtime_dir "${vm}")/secondary-active.qcow2"
}

ftctl_xcolo_prepare_primary_overlay() {
  local vm="${1-}"
  local size_bytes="${2-}"
  local path current_size=""
  path="$(ftctl_xcolo_primary_active_overlay_path "${vm}")"
  ftctl_ensure_dir "$(dirname "${path}")" "0755"
  [[ -n "${size_bytes}" ]] || return 1
  if [[ -f "${path}" ]]; then
    current_size="$(ftctl_xcolo_disk_virtual_size_bytes "${path}" 2>/dev/null || true)"
  fi
  if [[ ! -f "${path}" || "${current_size}" != "${size_bytes}" ]]; then
    rm -f -- "${path}" 2>/dev/null || true
    qemu-img create -f qcow2 "${path}" "${size_bytes}" >/dev/null || return 1
  fi
  printf '%s\n' "${path}"
}

ftctl_xcolo_prepare_secondary_overlays() {
  local vm="${1-}"
  local size_bytes="${2-}"
  local host user dir hidden active remote_cmd out err rc

  ftctl_blockcopy_remote_target_host_user host user || return 1
  dir="$(ftctl_xcolo_block_runtime_dir "${vm}")"
  hidden="$(ftctl_xcolo_secondary_hidden_overlay_path "${vm}")"
  active="$(ftctl_xcolo_secondary_active_overlay_path "${vm}")"
  [[ -n "${size_bytes}" ]] || return 1
  remote_cmd="$(cat <<EOF
set -euo pipefail
mkdir -p '${dir}'
current_hidden=""
current_active=""
if [[ -f '${hidden}' ]]; then
  current_hidden="\$(qemu-img info --output=json '${hidden}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"virtual-size\",\"\"))' 2>/dev/null || true)"
fi
if [[ -f '${active}' ]]; then
  current_active="\$(qemu-img info --output=json '${active}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"virtual-size\",\"\"))' 2>/dev/null || true)"
fi
if [[ ! -f '${hidden}' || "\${current_hidden}" != '${size_bytes}' ]]; then
  rm -f -- '${hidden}' >/dev/null 2>&1 || true
  qemu-img create -f qcow2 '${hidden}' '${size_bytes}' >/dev/null
fi
if [[ ! -f '${active}' || "\${current_active}" != '${size_bytes}' ]]; then
  rm -f -- '${active}' >/dev/null 2>&1 || true
  qemu-img create -f qcow2 '${active}' '${size_bytes}' >/dev/null
fi
EOF
)"
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]] || return 1
  printf '%s|%s\n' "${hidden}" "${active}"
}

ftctl_xcolo_disk_virtual_size_bytes() {
  local path="${1-}"
  local out err rc
  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- qemu-img info --force-share --output=json "${path}" || true
  : "${err}"
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    return 1
  fi
  python3 - <<'PY' "${out}"
import json, sys
data = json.loads(sys.argv[1])
print(data.get("virtual-size", ""))
PY
}

ftctl_xcolo_remote_disk_virtual_size_bytes() {
  local host="${1-}"
  local user="${2-}"
  local path="${3-}"
  local out="" err="" rc=0 cmd=""

  cmd="$(cat <<EOF
set -euo pipefail
qemu-img info --force-share --output=json $(printf '%q' "${path}") | python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size",""))'
EOF
)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${cmd}" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return 1
  printf '%s\n' "$(printf '%s' "${out}" | tr -d '\r' | xargs)"
}

ftctl_xcolo_collect_disk_binding_on_uri() {
  local uri="${1-}"
  local vm="${2-}"
  local source_path="${3-}"
  local node_var="${4}"
  local qdev_var="${5}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-block"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    return 1
  fi

  payload="$(python3 - <<'PY' "${source_path}" "${out}"
import json, sys
source = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print("|")
    raise SystemExit(0)
for item in data.get("return", []):
    ins = item.get("inserted") or {}
    image = ins.get("image") or {}
    filename = image.get("filename", "")
    node = ins.get("node-name", "")
    qdev = item.get("qdev", "")
    if filename == source:
        print(f"{node}|{qdev}")
        break
else:
    print("|")
PY
)" || payload="|"

  printf -v "${node_var}" '%s' "${payload%%|*}"
  printf -v "${qdev_var}" '%s' "${payload##*|}"
  [[ -n "${payload%%|*}" ]]
}

ftctl_xcolo_attach_secondary_block_graph() {
  local vm="${1-}"
  local base_node="${2-}"
  local hidden="${3-}"
  local active="${4-}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"qcow2\",\"node-name\":\"ftctl-hidden\",\"file\":{\"driver\":\"file\",\"filename\":\"${hidden}\"},\"backing\":\"${base_node}\"}}" \
    "colo" "secondary.blockdev_add_hidden" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"qcow2\",\"node-name\":\"ftctl-active\",\"file\":{\"driver\":\"file\",\"filename\":\"${active}\"},\"backing\":\"ftctl-hidden\"}}" \
    "colo" "secondary.blockdev_add_active" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"replication\",\"node-name\":\"childs0\",\"mode\":\"secondary\",\"top-id\":\"colo-disk0\",\"file\":\"ftctl-active\"}}" \
    "colo" "secondary.blockdev_add_replication" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"quorum\",\"node-name\":\"colo-disk0\",\"read-pattern\":\"fifo\",\"vote-threshold\":1,\"children\":[\"childs0\"]}}" \
    "colo" "secondary.blockdev_add_quorum" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"device_add","arguments":{"driver":"scsi-hd","bus":"scsi0.0","channel":0,"scsi-id":0,"lun":0,"drive":"colo-disk0","id":"ftctl-colo-root","bootindex":1}}' \
    "colo" "secondary.device_add_colo_root" || return 1
}

ftctl_xcolo_attach_primary_block_graph() {
  local vm="${1-}"
  local base_node="${2-}"
  local active="${3-}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"qcow2\",\"node-name\":\"ftctl-primary-active\",\"file\":{\"driver\":\"file\",\"filename\":\"${active}\"},\"backing\":\"${base_node}\"}}" \
    "colo" "primary.blockdev_add_active" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"quorum\",\"node-name\":\"colo-disk0\",\"read-pattern\":\"fifo\",\"vote-threshold\":1,\"children\":[\"ftctl-primary-active\"]}}" \
    "colo" "primary.blockdev_add_quorum" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"device_add","arguments":{"driver":"scsi-hd","bus":"scsi0.0","channel":0,"scsi-id":0,"lun":0,"drive":"colo-disk0","id":"ftctl-colo-root","bootindex":1}}' \
    "colo" "primary.device_add_colo_root" || return 1
}

ftctl_xcolo_execute_handshake_with_nodes() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local export_node="${3-}"
  local nbd_host nbd_port

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "secondary.qmp_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}}' \
    "colo" "secondary.migrate_set_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    "{\"execute\":\"nbd-server-start\",\"arguments\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"}}}}" \
    "colo" "secondary.nbd_server_start" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    "{\"execute\":\"nbd-server-add\",\"arguments\":{\"device\":\"${export_node}\",\"writable\":true}}" \
    "colo" "secondary.nbd_server_add" || return 1

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "primary.qmp_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"nbd\",\"node-name\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\",\"server\":{\"type\":\"inet\",\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"},\"export\":\"${export_node}\",\"detect-zeroes\":\"on\"}}" \
    "colo" "primary.blockdev_add" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"x-blockdev-change\",\"arguments\":{\"parent\":\"colo-disk0\",\"node\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\"}}" \
    "colo" "primary.x_blockdev_change" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}}' \
    "colo" "primary.migrate_set_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate-set-parameters\",\"arguments\":{\"x-checkpoint-delay\":${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY}}}" \
    "colo" "primary.migrate_set_parameters" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate\",\"arguments\":{\"uri\":\"${FTCTL_PROFILE_XCOLO_MIGRATE_URI}\"}}" \
    "colo" "primary.migrate" || return 1
}

ftctl_xcolo_shutdown_primary_for_conversion() {
  local vm="${1-}"
  local out err rc state i action_timeout

  state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
  case "${state}" in
    shut\ off|shutoff|unknown) return 0 ;;
  esac

  action_timeout="${FTCTL_FENCING_TIMEOUT_SEC:-15}"
  if [[ -z "${action_timeout}" || ! "${action_timeout}" =~ ^[0-9]+$ || "${action_timeout}" -lt 15 ]]; then
    action_timeout=15
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${action_timeout}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" shutdown "${vm}" || true
  : "${out}${err}"
  ftctl_log_event "colo" "primary.shutdown_for_conversion" "$(ftctl_result_from_rc "${rc}")" "${vm}" "${rc}" "state=${state}"

  for ((i=0; i<30; i++)); do
    state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
    case "${state}" in
      shut\ off|shutoff|unknown) return 0 ;;
    esac
    sleep 1
  done

  out=""
  err=""
  rc=0
  ftctl_virsh "${action_timeout}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" destroy "${vm}" || true
  : "${out}${err}"
  ftctl_log_event "colo" "primary.destroy_for_conversion" "$(ftctl_result_from_rc "${rc}")" "${vm}" "${rc}" ""
  state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
  case "${state}" in
    shut\ off|shutoff|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

ftctl_xcolo_create_primary_generated() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local out err rc

  [[ -n "${generated_xml}" && -f "${generated_xml}" ]] || return 1
  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_XCOLO_QMP_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" create "${generated_xml}" || true
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    ftctl_log_event "colo" "primary.create_generated" "fail" "${vm}" "${rc}" "path=${generated_xml}"
    return "${rc}"
  fi
  ftctl_log_event "colo" "primary.create_generated" "ok" "${vm}" "" "path=${generated_xml}"
}

ftctl_xcolo_execute_block_cold_conversion() {
  local vm="${1-}"
  local primary_generated_xml standby_generated_xml primary_source secondary_dest
  local primary_overlay secondary_pair secondary_hidden secondary_active
  local primary_base_node primary_qdev secondary_base_node secondary_qdev
  local secondary_vm primary_size secondary_size host user out err rc

  primary_generated_xml="$(ftctl_state_get "${vm}" "primary_xml_generated" 2>/dev/null || true)"
  standby_generated_xml="$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)"
  primary_source="$(ftctl_state_get "${vm}" "primary_disk_source" 2>/dev/null || true)"
  secondary_dest="$(ftctl_state_get "${vm}" "secondary_block_dest" 2>/dev/null || true)"
  secondary_vm="$(ftctl_profile_secondary_vm_name_resolved "${vm}")"

  [[ -n "${primary_generated_xml}" && -n "${standby_generated_xml}" && -n "${primary_source}" && -n "${secondary_dest}" ]] || return 1

  ftctl_log_event "colo" "block_conversion.start" "ok" "${vm}" "" \
    "primary_generated=${primary_generated_xml} standby_generated=${standby_generated_xml}"

  ftctl_xcolo_shutdown_primary_for_conversion "${vm}" || {
    ftctl_log_event "colo" "block_conversion.primary_stop" "fail" "${vm}" "" \
      "reason=shutdown_failed"
    ftctl_state_set "${vm}" "last_error=xcolo_block_shutdown_failed"
    return 1
  }

  ftctl_state_set "${vm}" "conversion_stage=primary_stopped"
  ftctl_log_event "colo" "block_conversion.primary_stop" "ok" "${vm}" "" ""

  ftctl_log_event "colo" "block_conversion.secondary_create" "ok" "${vm}" "" \
    "path=${standby_generated_xml}"
  ftctl_standby_activate "${vm}" || {
    ftctl_log_event "colo" "block_conversion.secondary_create" "fail" "${vm}" "" \
      "path=${standby_generated_xml}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_secondary_create_failed"
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=secondary_created"
  ftctl_log_event "colo" "block_conversion.secondary_create" "ok" "${vm}" "" \
    "vm=${secondary_vm}"

  ftctl_log_event "colo" "block_conversion.primary_create" "ok" "${vm}" "" \
    "path=${primary_generated_xml}"
  ftctl_xcolo_create_primary_generated "${vm}" "${primary_generated_xml}" || {
    ftctl_log_event "colo" "block_conversion.primary_create" "fail" "${vm}" "" \
      "path=${primary_generated_xml}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_primary_create_failed"
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=primary_created"
  ftctl_log_event "colo" "block_conversion.primary_create" "ok" "${vm}" "" ""

  primary_size="$(ftctl_xcolo_disk_virtual_size_bytes "${primary_source}" 2>/dev/null || true)"
  secondary_size=""
  host=""
  user=""
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_target_host_user host user || true
  if [[ -n "${host}" ]]; then
    ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "qemu-img info --output=json '${secondary_dest}'" || true
    : "${err}"
    if [[ "${rc}" == "0" && -n "${out}" ]]; then
      secondary_size="$(python3 - <<'PY' "${out}"
import json, sys
data = json.loads(sys.argv[1])
print(data.get("virtual-size", ""))
PY
)" || secondary_size=""
    fi
  fi
  if [[ -n "${secondary_size}" && -n "${primary_size}" && "${secondary_size}" != "${primary_size}" ]]; then
    ftctl_log_event "colo" "block_conversion.size_validation" "fail" "${vm}" "" \
      "primary_size=${primary_size} secondary_size=${secondary_size}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_preflight_size_mismatch"
    return 1
  fi
  if [[ -z "${secondary_size}" ]]; then
    secondary_size="${primary_size}"
  fi

  primary_overlay="$(ftctl_xcolo_prepare_primary_overlay "${vm}" "${primary_size}")" || {
    ftctl_log_event "colo" "block_conversion.primary_overlay" "fail" "${vm}" "" ""
    ftctl_state_set "${vm}" "last_error=xcolo_block_primary_overlay_prepare_failed"
    return 1
  }
  secondary_pair="$(ftctl_xcolo_prepare_secondary_overlays "${vm}" "${secondary_size}")" || {
    ftctl_log_event "colo" "block_conversion.secondary_overlay" "fail" "${vm}" "" ""
    ftctl_state_set "${vm}" "last_error=xcolo_block_secondary_overlay_prepare_failed"
    return 1
  }
  secondary_hidden="${secondary_pair%%|*}"
  secondary_active="${secondary_pair##*|}"
  ftctl_log_event "colo" "block_conversion.overlay_prepare" "ok" "${vm}" "" \
    "primary_overlay=${primary_overlay} secondary_hidden=${secondary_hidden} secondary_active=${secondary_active}"

  ftctl_xcolo_collect_disk_binding_on_uri "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${primary_source}" primary_base_node primary_qdev || {
    ftctl_log_event "colo" "block_conversion.primary_binding" "fail" "${vm}" "" \
      "source=${primary_source}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_primary_binding_missing"
    return 1
  }
  ftctl_xcolo_collect_disk_binding_on_uri "${FTCTL_PROFILE_SECONDARY_URI}" "$(ftctl_profile_secondary_vm_name_resolved "${vm}")" "${secondary_dest}" secondary_base_node secondary_qdev || {
    ftctl_log_event "colo" "block_conversion.secondary_binding" "fail" "${vm}" "" \
      "source=${secondary_dest}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_secondary_binding_missing"
    return 1
  }
  ftctl_log_event "colo" "block_conversion.binding" "ok" "${vm}" "" \
    "primary_base=${primary_base_node} secondary_base=${secondary_base_node}"

  ftctl_xcolo_attach_secondary_block_graph "${secondary_vm}" "${secondary_base_node}" "${secondary_hidden}" "${secondary_active}" || {
    ftctl_log_event "colo" "block_conversion.secondary_attach" "fail" "${vm}" "" \
      "base=${secondary_base_node}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_secondary_attach_failed"
    return 1
  }
  ftctl_log_event "colo" "block_conversion.secondary_attach" "ok" "${vm}" "" \
    "base=${secondary_base_node}"
  ftctl_xcolo_attach_primary_block_graph "${vm}" "${primary_base_node}" "${primary_overlay}" || {
    ftctl_log_event "colo" "block_conversion.primary_attach" "fail" "${vm}" "" \
      "base=${primary_base_node}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_primary_attach_failed"
    return 1
  }
  ftctl_log_event "colo" "block_conversion.primary_attach" "ok" "${vm}" "" \
    "base=${primary_base_node}"

  ftctl_xcolo_execute_handshake_with_nodes "${vm}" "${secondary_vm}" "${secondary_base_node}" || {
    ftctl_log_event "colo" "block_conversion.handshake" "fail" "${vm}" "" \
      "export_node=${secondary_base_node}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_handshake_failed"
    return 1
  }
  ftctl_log_event "colo" "block_conversion.handshake" "ok" "${vm}" "" \
    "export_node=${secondary_base_node}"

  ftctl_xcolo_state_write "${vm}" \
    "mode=cold-conversion" \
    "conversion_policy=block-backed-cold-restart" \
    "conversion_required=yes" \
    "primary_disk_source=${primary_source}" \
    "secondary_block_dest=${secondary_dest}" \
    "primary_base_node=${primary_base_node}" \
    "primary_base_qdev=${primary_qdev}" \
    "secondary_base_node=${secondary_base_node}" \
    "secondary_base_qdev=${secondary_qdev}" \
    "primary_overlay=${primary_overlay}" \
    "secondary_hidden=${secondary_hidden}" \
    "secondary_active=${secondary_active}" \
    "primary_disk_node=${secondary_base_node}" \
    "parent_block_node=colo-disk0" \
    "nbd_node=${FTCTL_PROFILE_XCOLO_NBD_NODE}" \
    "proxy_endpoint=${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" \
    "nbd_endpoint=${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" \
    "migrate_uri=${FTCTL_PROFILE_XCOLO_MIGRATE_URI}"

  ftctl_state_set "${vm}" \
    "conversion_stage=handshake_complete" \
    "conversion_state=colo_running" \
    "protection_state=colo_running" \
    "transport_state=mirroring" \
    "active_side=primary" \
    "last_sync_ts=$(ftctl_now_iso8601)" \
    "last_error="
  ftctl_log_event "colo" "xcolo.block_cold_conversion.execute" "ok" "${vm}" "" \
    "primary_base=${primary_base_node} secondary_base=${secondary_base_node}"
  return 0
}

ftctl_xcolo_detect_block_backed_ft() {
  local vm="${1-}"
  local out_kind_var="${2}"
  local out_target_var="${3}"
  local out_source_var="${4}"
  local out_format_var="${5}"
  local disks=()
  local first target source format dtype

  printf -v "${out_kind_var}" '%s' "unknown"
  printf -v "${out_target_var}" '%s' ""
  printf -v "${out_source_var}" '%s' ""
  printf -v "${out_format_var}" '%s' ""

  ftctl_inventory_collect_vm_disks_detailed "${vm}" disks || return 1
  first="${disks[0]}"
  target="${first%%|*}"
  first="${first#*|}"
  source="${first%%|*}"
  first="${first#*|}"
  format="${first%%|*}"
  dtype="${first##*|}"

  printf -v "${out_target_var}" '%s' "${target}"
  printf -v "${out_source_var}" '%s' "${source}"
  printf -v "${out_format_var}" '%s' "${format}"
  printf -v "${out_kind_var}" '%s' "${dtype}"
  [[ "${dtype}" == "block" ]]
}

ftctl_xcolo_plan_protect_prebuilt() {
  local vm="${1-}"
  local nbd_host nbd_port
  local primary_xml_backup standby_xml_seed

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port
  primary_xml_backup="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  standby_xml_seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  if [[ -z "${primary_xml_backup}" || -z "${standby_xml_seed}" || ! -f "${primary_xml_backup}" || ! -f "${standby_xml_seed}" ]]; then
    ftctl_xcolo_backup_prebuilt_pair_xml "${vm}" || return 1
    primary_xml_backup="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
    standby_xml_seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  fi

  ftctl_state_set "${vm}" \
    "protection_state=colo_preparing" \
    "transport_state=planned" \
    "xcolo_protect_stage=secondary-stage" \
    "last_error="

  if ! ftctl_xcolo_validate_prebuilt_file_pair_sizes "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_preflight_size_mismatch"
    ftctl_log_event "colo" "xcolo.protect" "fail" "${vm}" "" \
      "reason=preflight_size_mismatch"
    return 1
  fi

  ftctl_xcolo_prebuilt_secondary_stage "${vm}" "${nbd_host}" "${nbd_port}" || return 1
  ftctl_xcolo_capture_runtime_snapshot "${vm}" "xcolo_after_secondary"
  ftctl_state_set "${vm}" "xcolo_protect_stage=primary-stage"
  ftctl_xcolo_prebuilt_primary_stage "${vm}" "${nbd_host}" "${nbd_port}" || return 1
  ftctl_xcolo_capture_runtime_snapshot "${vm}" "xcolo_after_primary"

  ftctl_xcolo_state_write "${vm}" \
    "proxy_endpoint=${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" \
    "nbd_endpoint=${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" \
    "migrate_uri=${FTCTL_PROFILE_XCOLO_MIGRATE_URI}" \
    "primary_disk_node=${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}" \
    "parent_block_node=${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE}" \
    "nbd_node=${FTCTL_PROFILE_XCOLO_NBD_NODE}"

  ftctl_state_set "${vm}" \
    "xcolo_protect_stage=wait-running" \
    "protection_state=colo_running" \
    "transport_state=mirroring" \
    "last_sync_ts=$(ftctl_now_iso8601)" \
    "last_error="
  ftctl_xcolo_capture_runtime_snapshot "${vm}"
  if ! ftctl_xcolo_wait_pair_running "${vm}" "20" "${vm}"; then
    ftctl_xcolo_capture_runtime_snapshot "${vm}"
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_protect_not_running"
    ftctl_log_event "colo" "xcolo.protect" "fail" "${vm}" "" \
      "reason=pair_not_running"
    return 1
  fi
  ftctl_log_event "colo" "xcolo.protect" "ok" "${vm}" "" \
    "qmp_timeout=${FTCTL_XCOLO_QMP_TIMEOUT_SEC}"
}

ftctl_xcolo_plan_protect_block_cold_conversion() {
  local vm="${1-}"
  local disk_kind primary_target primary_source primary_format current_node current_qdev
  local primary_xml_backup standby_xml_seed
  local primary_generated_xml standby_generated_xml
  local xml_bundle_dir persistence secondary_dest primary_state
  local primary_qemu_args secondary_qemu_args

  ftctl_xcolo_detect_block_backed_ft "${vm}" disk_kind primary_target primary_source primary_format || return 1
  current_node=""
  current_qdev=""
  primary_xml_backup="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  standby_xml_seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  primary_generated_xml=""
  standby_generated_xml=""
  xml_bundle_dir=""
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || true)"
  secondary_dest=""
  primary_state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
  primary_qemu_args="$(ftctl_xcolo_build_primary_qemu_args)"
  secondary_qemu_args="$(ftctl_xcolo_build_secondary_qemu_args)"

  if [[ -z "${primary_xml_backup}" || -z "${standby_xml_seed}" || ! -f "${primary_xml_backup}" || ! -f "${standby_xml_seed}" ]]; then
    ftctl_inventory_backup_domain_xml "${vm}" xml_bundle_dir primary_xml_backup standby_xml_seed persistence || {
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=planned" \
        "last_error=xcolo_block_xml_backup_failed"
      return 1
    }
    ftctl_state_set "${vm}" \
      "primary_xml_backup=${primary_xml_backup}" \
      "standby_xml_seed=${standby_xml_seed}" \
      "primary_persistence=${persistence}"
  fi

  if [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_block_explicit_disk_map_required"
    ftctl_log_event "colo" "xcolo.protect.block_cold_conversion" "fail" "${vm}" "" \
      "reason=explicit_disk_map_required target=${primary_target}"
    return 1
  fi

  secondary_dest="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_DISK_MAP}" "${primary_target}" 2>/dev/null || true)"
  if [[ -z "${secondary_dest}" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_block_secondary_dest_missing"
    ftctl_log_event "colo" "xcolo.protect.block_cold_conversion" "fail" "${vm}" "" \
      "reason=secondary_dest_missing target=${primary_target}"
    return 1
  fi

  if [[ -n "${primary_xml_backup}" && -f "${primary_xml_backup}" ]]; then
    ftctl_xcolo_prepare_block_generated_xmls "${vm}" \
      "${primary_xml_backup}" "${standby_xml_seed}" "${primary_source}" "${secondary_dest}" \
      "${primary_format}" "${primary_qemu_args}" "${secondary_qemu_args}" || {
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=planned" \
        "last_error=xcolo_block_generated_xml_prepare_failed"
      return 1
    }
    primary_generated_xml="$(ftctl_state_get "${vm}" "primary_xml_generated" 2>/dev/null || true)"
    standby_generated_xml="$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)"
  fi

  ftctl_xcolo_collect_primary_disk_binding "${vm}" "${primary_source}" current_node current_qdev || {
    ftctl_log_event "colo" "primary.block_binding" "fail" "${vm}" "" \
      "source=${primary_source}"
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_block_binding_not_found"
    return 1
  }

  ftctl_xcolo_state_write "${vm}" \
    "mode=cold-conversion" \
    "conversion_policy=block-backed-cold-restart" \
    "conversion_required=yes" \
    "primary_disk_type=${disk_kind}" \
    "primary_disk_target=${primary_target}" \
    "primary_disk_source=${primary_source}" \
    "primary_disk_format=${primary_format}" \
    "current_primary_node=${current_node}" \
    "current_primary_qdev=${current_qdev}" \
    "primary_xml_backup=${primary_xml_backup}" \
    "standby_xml_seed=${standby_xml_seed}" \
    "primary_xml_generated=${primary_generated_xml}" \
    "standby_xml_generated=${standby_generated_xml}" \
    "primary_qemu_args=${primary_qemu_args}" \
    "secondary_qemu_args=${secondary_qemu_args}" \
    "primary_runtime_disk_mode=ro-shareable" \
    "secondary_runtime_disk_mode=rw" \
    "secondary_block_dest=${secondary_dest}" \
    "proxy_endpoint=${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" \
    "nbd_endpoint=${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" \
    "migrate_uri=${FTCTL_PROFILE_XCOLO_MIGRATE_URI}" \
    "primary_disk_node=${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}" \
    "parent_block_node=${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE}" \
    "nbd_node=${FTCTL_PROFILE_XCOLO_NBD_NODE}"

  ftctl_log_event "colo" "xcolo.protect.block_cold_conversion" "warn" "${vm}" "" \
    "source=${primary_source} node=${current_node} qdev=${current_qdev} secondary_dest=${secondary_dest} policy=cold_restart stage=runtime_xml_generated"
  ftctl_state_set "${vm}" \
    "primary_disk_type=${disk_kind}" \
    "primary_disk_target=${primary_target}" \
    "primary_disk_source=${primary_source}" \
    "primary_disk_format=${primary_format}" \
    "current_primary_node=${current_node}" \
    "current_primary_qdev=${current_qdev}" \
    "secondary_block_dest=${secondary_dest}" \
    "protection_state=pairing" \
    "transport_state=planned" \
    "conversion_stage=runtime_xml_generated" \
    "conversion_state=shutdown_required" \
    "primary_domain_state=${primary_state}" \
    "last_error="

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_block_cold_conversion_handshake_not_implemented"
    return 0
  fi

  ftctl_xcolo_execute_block_cold_conversion "${vm}" || return 1
  return 0
}

ftctl_xcolo_plan_protect() {
  local vm="${1-}"
  local disk_kind primary_target primary_source primary_format

  if ftctl_xcolo_detect_block_backed_ft "${vm}" disk_kind primary_target primary_source primary_format; then
    ftctl_xcolo_plan_protect_block_cold_conversion "${vm}"
    return $?
  fi

  ftctl_xcolo_plan_protect_prebuilt "${vm}"
}

ftctl_xcolo_rearm() {
  local vm="${1-}"
  local count
  count="$(ftctl_state_increment "${vm}" "rearm_count")"
  ftctl_state_set "${vm}" \
    "protection_state=colo_rearming" \
    "transport_state=rearm_pending" \
    "last_rearm_ts=$(ftctl_now_iso8601)" \
    "last_error="

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"nbd-server-stop"}' "rearm" "secondary.nbd_server_stop" || true
  ftctl_xcolo_plan_protect "${vm}" || {
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=rearm_failed" \
      "last_error=xcolo_rearm_failed"
    return 1
  }
  ftctl_log_event "rearm" "xcolo.rearm" "ok" "${vm}" "" \
    "rearm_count=${count}"
}

ftctl_xcolo_failover() {
  local vm="${1-}"
  local secondary_vm=""

  secondary_vm="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || true)"
  [[ -n "${secondary_vm}" ]] || secondary_vm="${vm}"

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=failed_over" \
      "active_side=secondary" \
      "transport_state=colo_failover_dry_run"
    ftctl_log_event "failover" "xcolo.failover" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    '{"execute":"nbd-server-stop"}' "failover" "secondary.nbd_server_stop" || true
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    '{"execute":"x-colo-lost-heartbeat"}' "failover" "secondary.x_colo_lost_heartbeat" || return 1

  ftctl_state_set "${vm}" \
    "protection_state=failed_over" \
    "active_side=secondary" \
    "transport_state=colo_failover"
  ftctl_log_event "failover" "xcolo.failover" "ok" "${vm}" "" "active_side=secondary"
}

ftctl_xcolo_failback_policy() {
  local vm="${1-}"
  local disk_kind primary_target primary_source primary_format
  disk_kind="$(ftctl_state_get "${vm}" "primary_disk_type" 2>/dev/null || true)"
  if [[ "${disk_kind}" == "block" ]]; then
    printf '%s\n' "block-ft-cold-cutback"
    return 0
  fi
  if ftctl_xcolo_detect_block_backed_ft "${vm}" disk_kind primary_target primary_source primary_format; then
    printf '%s\n' "block-ft-cold-cutback"
  else
    printf '%s\n' "file-ft-runtime-cutback"
  fi
}

ftctl_xcolo_failback_record_state() {
  local vm="${1-}"
  local policy="${2-}"
  local stage="${3-}"
  local transport="${4-}"
  local reason="${5-}"
  local prev_transport

  prev_transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "unknown")"
  ftctl_state_set "${vm}" \
    "protection_state=failing_back" \
    "transport_state=${transport}" \
    "last_error=${reason}" \
    "xcolo_failback_policy=${policy}" \
    "xcolo_failback_stage=${stage}" \
    "xcolo_failback_prev_transport=${prev_transport}"
}

ftctl_xcolo_collect_disks_on_uri() {
  local uri="${1-}"
  local vm="${2-}"
  local out_array_name="${3}"
  local out err rc
  local -n _out_array="${out_array_name}"
  local line dtype device target source

  _out_array=()
  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" domblklist "${vm}" --details || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      Type*|----*) continue ;;
    esac
    dtype="$(awk '{print $1}' <<< "${line}")"
    device="$(awk '{print $2}' <<< "${line}")"
    target="$(awk '{print $3}' <<< "${line}")"
    source="$(awk '{print $4}' <<< "${line}")"
    [[ "${device}" == "disk" ]] || continue
    [[ -n "${target}" && -n "${source}" && "${source}" != "-" ]] || continue
    _out_array+=("${target}|${source}|${dtype}")
  done <<< "${out}"
  ((${#_out_array[@]} > 0))
}

ftctl_xcolo_collect_disks_from_xml() {
  local xml_path="${1-}"
  local out_array_name="${2}"
  local -n _out_array="${out_array_name}"

  _out_array=()
  [[ -n "${xml_path}" && -f "${xml_path}" ]] || return 1

  mapfile -t _out_array < <(python3 - <<'PY' "${xml_path}"
import sys, xml.etree.ElementTree as ET
xml_path = sys.argv[1]
root = ET.parse(xml_path).getroot()
for disk in root.findall("./devices/disk"):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    source = disk.find("source")
    if target is None or source is None:
        continue
    dev = target.get("dev", "")
    path = source.get("file") or source.get("dev") or ""
    if dev and path:
        print(f"{dev}|{path}|xml")
PY
)
  ((${#_out_array[@]} > 0))
}

ftctl_xcolo_collect_prebuilt_file_pair_paths() {
  local vm="${1-}"
  local primary_parent_var="${2}"
  local secondary_active_var="${3}"
  local primary_xml secondary_xml payload

  primary_xml="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  secondary_xml="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  [[ -n "${primary_xml}" && -f "${primary_xml}" && -n "${secondary_xml}" && -f "${secondary_xml}" ]] || return 1

  payload="$(python3 - <<'PY' "${primary_xml}" "${secondary_xml}"
import sys, xml.etree.ElementTree as ET
qns = {'qemu': 'http://libvirt.org/schemas/domain/qemu/1.0'}
primary_xml, secondary_xml = sys.argv[1], sys.argv[2]

def collect(xml_path):
    root = ET.parse(xml_path).getroot()
    vals = []
    for node in root.findall('.//qemu:arg', qns):
        v = node.get('value', '')
        if v:
            vals.append(v)
    return vals

primary_args = collect(primary_xml)
secondary_args = collect(secondary_xml)
primary_parent = ''
secondary_active = ''
for v in primary_args:
    if 'id=parent0' in v and 'file.filename=' in v:
        part = v.split('file.filename=', 1)[1]
        primary_parent = part.split(',', 1)[0]
        break
    if 'id=colo-disk0' in v and 'children.0.file.filename=' in v:
        part = v.split('children.0.file.filename=', 1)[1]
        primary_parent = part.split(',', 1)[0]
        break
for v in secondary_args:
    if 'file.file.filename=' in v:
        part = v.split('file.file.filename=', 1)[1]
        secondary_active = part.split(',', 1)[0]
        break
print(primary_parent + '|' + secondary_active)
PY
)" || payload="|"

  printf -v "${primary_parent_var}" '%s' "${payload%%|*}"
  printf -v "${secondary_active_var}" '%s' "${payload##*|}"
  [[ -n "${payload%%|*}" && -n "${payload##*|}" ]]
}

ftctl_xcolo_collect_prebuilt_file_pair_detail() {
  local vm="${1-}"
  local primary_parent_var="${2}"
  local secondary_parent_var="${3}"
  local secondary_hidden_var="${4}"
  local secondary_active_var="${5}"
  local primary_xml secondary_xml payload

  primary_xml="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  secondary_xml="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  [[ -n "${primary_xml}" && -f "${primary_xml}" && -n "${secondary_xml}" && -f "${secondary_xml}" ]] || return 1

  payload="$(python3 - <<'PY' "${primary_xml}" "${secondary_xml}"
import sys, xml.etree.ElementTree as ET
qns = {'qemu': 'http://libvirt.org/schemas/domain/qemu/1.0'}
primary_xml, secondary_xml = sys.argv[1], sys.argv[2]

def collect(xml_path):
    root = ET.parse(xml_path).getroot()
    vals = []
    for node in root.findall('.//qemu:arg', qns):
        v = node.get('value', '')
        if v:
            vals.append(v)
    return vals

primary_args = collect(primary_xml)
secondary_args = collect(secondary_xml)
primary_parent = ''
secondary_parent = ''
secondary_hidden = ''
secondary_active = ''

for v in primary_args:
    if 'id=parent0' in v and 'file.filename=' in v:
        part = v.split('file.filename=', 1)[1]
        primary_parent = part.split(',', 1)[0]
        break
    if 'id=colo-disk0' in v and 'children.0.file.filename=' in v:
        part = v.split('children.0.file.filename=', 1)[1]
        primary_parent = part.split(',', 1)[0]
        break

for v in secondary_args:
    if 'id=parent0' in v and 'file.filename=' in v:
        part = v.split('file.filename=', 1)[1]
        secondary_parent = part.split(',', 1)[0]
    if 'file.file.filename=' in v:
        part = v.split('file.file.filename=', 1)[1]
        secondary_active = part.split(',', 1)[0]
    if 'file.backing.file.filename=' in v:
        part = v.split('file.backing.file.filename=', 1)[1]
        secondary_hidden = part.split(',', 1)[0]

print("|".join([primary_parent, secondary_parent, secondary_hidden, secondary_active]))
PY
)" || payload="|||"

  printf -v "${primary_parent_var}" '%s' "${payload%%|*}"
  payload="${payload#*|}"
  printf -v "${secondary_parent_var}" '%s' "${payload%%|*}"
  payload="${payload#*|}"
  printf -v "${secondary_hidden_var}" '%s' "${payload%%|*}"
  printf -v "${secondary_active_var}" '%s' "${payload##*|}"
  [[ -n "${!primary_parent_var}" && -n "${!secondary_parent_var}" && -n "${!secondary_hidden_var}" && -n "${!secondary_active_var}" ]]
}

ftctl_xcolo_validate_prebuilt_file_pair_sizes() {
  local vm="${1-}"
  local primary_parent="" secondary_parent="" secondary_hidden="" secondary_active=""
  local primary_size="" secondary_parent_size="" secondary_hidden_size="" secondary_active_size=""
  local secondary_host="" secondary_user=""

  ftctl_xcolo_collect_prebuilt_file_pair_detail "${vm}" primary_parent secondary_parent secondary_hidden secondary_active || return 1
  ftctl_blockcopy_remote_target_host_user secondary_host secondary_user || return 1

  primary_size="$(ftctl_xcolo_disk_virtual_size_bytes "${primary_parent}" 2>/dev/null || true)"
  secondary_parent_size="$(ftctl_xcolo_remote_disk_virtual_size_bytes "${secondary_host}" "${secondary_user}" "${secondary_parent}" 2>/dev/null || true)"
  secondary_hidden_size="$(ftctl_xcolo_remote_disk_virtual_size_bytes "${secondary_host}" "${secondary_user}" "${secondary_hidden}" 2>/dev/null || true)"
  secondary_active_size="$(ftctl_xcolo_remote_disk_virtual_size_bytes "${secondary_host}" "${secondary_user}" "${secondary_active}" 2>/dev/null || true)"

  ftctl_state_set "${vm}" \
    "xcolo_primary_source_path=${primary_parent}" \
    "xcolo_secondary_parent_path=${secondary_parent}" \
    "xcolo_secondary_hidden_path=${secondary_hidden}" \
    "xcolo_secondary_active_path=${secondary_active}" \
    "xcolo_primary_source_size=${primary_size}" \
    "xcolo_secondary_parent_size=${secondary_parent_size}" \
    "xcolo_secondary_hidden_size=${secondary_hidden_size}" \
    "xcolo_secondary_active_size=${secondary_active_size}"

  [[ -n "${primary_size}" && -n "${secondary_parent_size}" && -n "${secondary_hidden_size}" && -n "${secondary_active_size}" ]] || return 1
  [[ "${primary_size}" == "${secondary_parent_size}" ]] || return 1
  [[ "${primary_size}" == "${secondary_hidden_size}" ]] || return 1
  [[ "${primary_size}" == "${secondary_active_size}" ]]
}

ftctl_xcolo_remote_copy_file_to_primary() {
  local vm="${1-}"
  local target="${2-}"
  local secondary_source="${3-}"
  local primary_dest="${4-}"
  local format="${5-}"
  local host="" user="" primary_host="" primary_user="" out="" err="" rc=0
  local tmp_dest="" remote_cmd=""

  [[ -n "${secondary_source}" && -n "${primary_dest}" ]] || return 1
  ftctl_blockcopy_remote_target_host_user host user || return 1
  if ! ftctl_blockcopy_primary_target_host_user primary_host primary_user 2>/dev/null || [[ -z "${primary_host}" ]]; then
    primary_host="$(ftctl_xcolo_primary_listen_host control 2>/dev/null || true)"
    primary_user="${FTCTL_PROFILE_FENCING_SSH_USER:-root}"
  fi
  [[ -n "${primary_host}" ]] || return 1
  tmp_dest="${primary_dest}.ftfb.tmp"

  remote_cmd="$(cat <<EOF
set -euo pipefail
src=$(printf '%q' "${secondary_source}")
dst=$(printf '%q' "${primary_dest}")
tmp_dst=$(printf '%q' "${tmp_dest}")
primary_host=$(printf '%q' "${primary_host}")
primary_user=$(printf '%q' "${primary_user}")
stage=\$(mktemp /tmp/${vm}-${target}-ftfb.XXXXXX.${format})
cleanup() {
  rm -f "\${stage}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
qemu-img convert --force-share -p -f $(printf '%q' "${format}") -O $(printf '%q' "${format}") "\${src}" "\${stage}"
scp -o BatchMode=yes -o StrictHostKeyChecking=no "\${stage}" "\${primary_user}@\${primary_host}:\${tmp_dst}"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "\${primary_user}@\${primary_host}" "mv -f \${tmp_dst} \${dst}"
EOF
)"
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]]
}

ftctl_xcolo_file_failback_sync_disks() {
  local vm="${1-}"
  local primary_source secondary_active format

  ftctl_xcolo_collect_prebuilt_file_pair_paths "${vm}" primary_source secondary_active || return 1
  format=""
  ftctl_inventory_detect_disk_format "${primary_source}" format
  ftctl_xcolo_remote_copy_file_to_primary "${vm}" "vda" "${secondary_active}" "${primary_source}" "${format:-qcow2}" || return 1
}

ftctl_xcolo_copy_block_active_back_to_primary() {
  local vm="${1-}"
  local secondary_active="${2-}"
  local primary_dest="${3-}"
  local secondary_host="" secondary_user=""
  local remote_stage="" local_stage="" remote_cmd="" out="" err="" rc=0

  [[ -n "${secondary_active}" && -n "${primary_dest}" ]] || return 1
  ftctl_blockcopy_remote_target_host_user secondary_host secondary_user || return 1

  remote_stage="/tmp/${vm}-block-failback.qcow2"
  local_stage="/tmp/${vm}-block-failback.qcow2"

  remote_cmd="$(cat <<EOF
set -euo pipefail
rm -f $(printf '%q' "${remote_stage}")
qemu-img convert -p -f qcow2 -O qcow2 $(printf '%q' "${secondary_active}") $(printf '%q' "${remote_stage}")
EOF
)"
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${secondary_host}" "${secondary_user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]] || return 1

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- \
    scp -o BatchMode=yes -o StrictHostKeyChecking=no "${secondary_user}@${secondary_host}:${remote_stage}" "${local_stage}" || true
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    ftctl_blockcopy_remote_exec "${secondary_host}" "${secondary_user}" out err rc "rm -f $(printf '%q' "${remote_stage}")" || true
    return 1
  fi

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- \
    qemu-img convert -p -f qcow2 -O qcow2 "${local_stage}" "${primary_dest}" || true
  : "${out}${err}"

  rm -f -- "${local_stage}" >/dev/null 2>&1 || true
  ftctl_blockcopy_remote_exec "${secondary_host}" "${secondary_user}" out err rc "rm -f $(printf '%q' "${remote_stage}")" || true

  [[ "${rc}" == "0" ]]
}

ftctl_xcolo_activate_secondary_seed_same_name() {
  local vm="${1-}"
  local seed content_b64 host="" user="" remote_cmd out="" err="" rc=0

  seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  [[ -n "${seed}" && -f "${seed}" ]] || return 1
  ftctl_blockcopy_remote_target_host_user host user || return 1
  content_b64="$(base64 -w0 "${seed}")"
  remote_cmd="$(cat <<EOF
set -euo pipefail
xml_path="/tmp/${vm}-ft-failback.xml"
printf '%s' '${content_b64}' | base64 -d > "\${xml_path}"
virsh destroy ${vm@Q} >/dev/null 2>&1 || true
virsh undefine ${vm@Q} >/dev/null 2>&1 || true
virsh create "\${xml_path}"
EOF
)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]]
}

ftctl_xcolo_failback_file() {
  local vm="${1-}"
  local primary_generated out err rc

  primary_generated="$(ftctl_primary_generated_xml_path "${vm}")"

  ftctl_standby_materialize_primary_xml "${vm}" || {
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "materialize-primary-failed" \
      "ft_reverse_syncing" \
      "xcolo_file_failback_primary_xml_failed"
    return 1
  }

  ftctl_xcolo_failback_record_state "${vm}" \
    "file-ft-runtime-cutback" \
    "reverse-sync-copy" \
    "ft_reverse_syncing" \
    ""

  if ! ftctl_xcolo_file_failback_sync_disks "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "reverse-sync-copy-failed" \
      "ft_reverse_syncing" \
      "xcolo_file_failback_copy_failed"
    return 1
  fi

  ftctl_xcolo_failback_record_state "${vm}" \
    "file-ft-runtime-cutback" \
    "cutback-switching" \
    "ft_cutback_switching" \
    ""

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"nbd-server-stop"}' "failback" "secondary.nbd_server_stop" || true

  if ! ftctl_xcolo_activate_secondary_seed_same_name "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "secondary-activate-failed" \
      "ft_cutback_switching" \
      "xcolo_file_failback_secondary_activate_failed"
    return 1
  fi

  if ! ftctl_activate_domain_from_xml "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${primary_generated}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "primary-activate-failed" \
      "ft_cutback_switching" \
      "xcolo_file_failback_primary_activate_failed"
    return 1
  fi

  if ! ftctl_xcolo_plan_protect_prebuilt "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "reprotect-failed" \
      "ft_cutback_switching" \
      "xcolo_file_failback_reprotect_failed"
    return 1
  fi

  if ! ftctl_xcolo_wait_pair_running "${vm}" "20" "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "reprotect-not-running" \
      "ft_cutback_switching" \
      "xcolo_file_failback_reprotect_not_running"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "active_side=primary" \
    "protection_state=colo_running" \
    "transport_state=mirroring" \
    "last_error="
  ftctl_log_event "failback" "xcolo.failback.file" "ok" "${vm}" "" \
    "reason=cutback_complete"
  return 0
}

ftctl_xcolo_failback_block() {
  local vm="${1-}"
  local primary_source="" secondary_active=""

  primary_source="$(ftctl_state_get "${vm}" "primary_disk_source" 2>/dev/null || true)"
  secondary_active="$(ftctl_xcolo_secondary_active_overlay_path "${vm}")"
  [[ -n "${primary_source}" && -n "${secondary_active}" ]] || {
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "missing-paths" \
      "ft_reverse_syncing" \
      "xcolo_block_failback_missing_paths"
    return 1
  }

  ftctl_xcolo_failback_record_state "${vm}" \
    "block-ft-cold-cutback" \
    "secondary-stop" \
    "ft_reverse_syncing" \
    ""
  if ! ftctl_standby_deactivate "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "secondary-stop-failed" \
      "ft_reverse_syncing" \
      "xcolo_block_failback_secondary_stop_failed"
    return 1
  fi

  ftctl_xcolo_failback_record_state "${vm}" \
    "block-ft-cold-cutback" \
    "reverse-sync-copy" \
    "ft_reverse_syncing" \
    ""
  if ! ftctl_xcolo_copy_block_active_back_to_primary "${vm}" "${secondary_active}" "${primary_source}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "reverse-sync-copy-failed" \
      "ft_reverse_syncing" \
      "xcolo_block_failback_copy_failed"
    return 1
  fi

  ftctl_xcolo_failback_record_state "${vm}" \
    "block-ft-cold-cutback" \
    "primary-activate" \
    "ft_cutback_switching" \
    ""
  if ! ftctl_primary_activate_from_backup "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "primary-activate-failed" \
      "ft_cutback_switching" \
      "xcolo_block_failback_primary_activate_failed"
    return 1
  fi

  ftctl_xcolo_failback_record_state "${vm}" \
    "block-ft-cold-cutback" \
    "reprotect" \
    "ft_cutback_switching" \
    ""
  if ! ftctl_xcolo_plan_protect_block_cold_conversion "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "reprotect-failed" \
      "ft_cutback_switching" \
      "xcolo_block_failback_reprotect_failed"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "active_side=primary" \
    "protection_state=colo_running" \
    "transport_state=mirroring" \
    "last_error="
  ftctl_log_event "failback" "xcolo.failback.block" "ok" "${vm}" "" \
    "reason=cold_cutback_complete"
  return 0
}

ftctl_xcolo_failback() {
  local vm="${1-}"
  local policy transport

  policy="$(ftctl_xcolo_failback_policy "${vm}")"
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "unknown")"

  if ! ftctl_verify_xcolo_failback_ready "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=xcolo_failback_precheck_failed"
    return 1
  fi

  case "${policy}" in
    file-ft-runtime-cutback)
      ftctl_log_event "failback" "xcolo.failback" "warn" "${vm}" "" \
        "policy=${policy} transport=${transport} dispatch=file"
      ftctl_xcolo_failback_file "${vm}"
      ;;
    block-ft-cold-cutback)
      ftctl_log_event "failback" "xcolo.failback" "warn" "${vm}" "" \
        "policy=${policy} transport=${transport} dispatch=block"
      ftctl_xcolo_failback_block "${vm}"
      ;;
    *)
      ftctl_xcolo_failback_record_state "${vm}" \
        "${policy}" \
        "invalid-policy" \
        "ft_reverse_syncing" \
        "xcolo_failback_unknown_policy"
      ftctl_log_event "failback" "xcolo.failback" "fail" "${vm}" "" \
        "policy=${policy} transport=${transport} reason=unknown_policy"
      return 1
      ;;
  esac
}
