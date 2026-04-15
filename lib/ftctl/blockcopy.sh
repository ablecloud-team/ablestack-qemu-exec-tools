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

ftctl_blockcopy_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").blockcopy"
}

ftctl_blockcopy_reverse_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").blockcopy.reverse"
}

ftctl_blockcopy_state_write() {
  local vm="${1-}"
  shift
  local path tmp line
  path="$(ftctl_blockcopy_state_path "${vm}")"
  tmp="$(mktemp -t ftctl.blockcopy.XXXXXX)"
  for line in "$@"; do
    printf "%s\n" "${line}" >> "${tmp}"
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_blockcopy_state_record_for_target() {
  local vm="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local path line

  path="$(ftctl_blockcopy_state_path "${vm}")"
  [[ -f "${path}" ]] || return 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if [[ "${line%%|*}" == "${target}" ]]; then
      printf -v "${out_var}" '%s' "${line}"
      return 0
    fi
  done < "${path}"
  return 1
}

ftctl_blockcopy_debug_dir() {
  local vm="${1-}"
  local target="${2-}"
  printf '%s\n' "${FTCTL_RUN_DIR}/debug/blockcopy/$(ftctl_state_vm_key "${vm}")/${target}"
}

ftctl_blockcopy_write_debug_file() {
  local vm="${1-}"
  local target="${2-}"
  local name="${3-}"
  local content="${4-}"
  local dir path

  dir="$(ftctl_blockcopy_debug_dir "${vm}" "${target}")"
  ftctl_ensure_dir "${dir}" "0755"
  path="${dir}/${name}"
  printf '%s\n' "${content}" > "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_blockcopy_resolve_dest() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local format="${4-}"
  local explicit dest source_base

  explicit="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_DISK_MAP}" "${target}" 2>/dev/null || true)"
  if [[ -n "${explicit}" ]]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  if [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
    source_base="$(basename "${source}")"
    dest="${FTCTL_BLOCKCOPY_TARGET_BASE_DIR}/${vm}/${target}-${source_base}"
    if [[ -n "${format}" ]]; then
      case "${dest}" in
        *.qcow2|*.raw) ;;
        *)
          dest="${dest}.${format}"
          ;;
      esac
    fi
    printf '%s\n' "${dest}"
    return 0
  fi

  echo "ERROR: no destination mapping for disk target ${target}" >&2
  return 2
}

ftctl_blockcopy_remote_nbd_uri() {
  local host="${1-}"
  local port="${2-}"
  local export_name="${3-}"
  printf 'nbd://%s:%s/%s\n' "${host}" "${port}" "${export_name}"
}

ftctl_blockcopy_is_krbd_path() {
  local path="${1-}"
  [[ "${path}" == /dev/rbd/* ]]
}

ftctl_blockcopy_krbd_spec_from_path() {
  local path="${1-}"
  local out_var="${2}"
  [[ "${path}" == /dev/rbd/* ]] || return 1
  printf -v "${out_var}" '%s' "${path#/dev/rbd/}"
}

ftctl_blockcopy_krbd_map_local() {
  local path="${1-}"
  local spec mapped

  ftctl_blockcopy_is_krbd_path "${path}" || return 1
  command -v rbd >/dev/null 2>&1 || {
    echo "ERROR: rbd CLI not found for krbd path ${path}" >&2
    return 2
  }
  if [[ -b "${path}" ]]; then
    return 0
  fi

  ftctl_blockcopy_krbd_spec_from_path "${path}" spec || return 1
  mapped="$(rbd map "${spec}" 2>&1)" || {
    echo "ERROR: rbd map failed for ${spec}: ${mapped}" >&2
    return 2
  }
  udevadm settle >/dev/null 2>&1 || true
  [[ -b "${path}" ]] || {
    echo "ERROR: krbd stable path missing after map: ${path}" >&2
    return 2
  }
}

ftctl_blockcopy_remote_nbd_port_extract_from_uri() {
  local uri="${1-}"
  local out_var="${2}"
  local tail port
  tail="${uri#nbd://}"
  tail="${tail#*/}"
  port="${uri#nbd://}"
  port="${port#*:}"
  port="${port%%/*}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  printf -v "${out_var}" '%s' "${port}"
}

ftctl_blockcopy_remote_nbd_host_extract_from_uri() {
  local uri="${1-}"
  local out_var="${2}"
  local rest host
  rest="${uri#nbd://}"
  host="${rest%%:*}"
  [[ -n "${host}" ]] || return 1
  printf -v "${out_var}" '%s' "${host}"
}

ftctl_blockcopy_remote_nbd_candidate_port() {
  local vm="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local seed offset
  seed="$(printf '%s:%s' "${vm}" "${target}" | cksum | awk '{print $1}')"
  offset=$((seed % FTCTL_REMOTE_NBD_PORT_COUNT))
  printf -v "${out_var}" '%s' "$((FTCTL_REMOTE_NBD_PORT_BASE + offset))"
}

ftctl_blockcopy_remote_nbd_secondary_path() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local format="${4-}"
  local source_base path explicit

  explicit="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_DISK_MAP}" "${target}" 2>/dev/null || true)"
  if [[ -n "${explicit}" && "${FTCTL_PROFILE_DISK_MAP}" != "auto" ]]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  source_base="$(basename "${source}")"
  path="${FTCTL_PROFILE_SECONDARY_TARGET_DIR}/${vm}/${target}-${source_base}"
  if [[ -n "${format}" ]]; then
    case "${path}" in
      *.qcow2|*.raw) ;;
      *) path="${path}.${format}" ;;
    esac
  fi
  printf '%s\n' "${path}"
}

ftctl_blockcopy_parse_ssh_target_from_uri() {
  local uri="${1-}"
  local host_var="${2}"
  local user_var="${3}"
  local rest parsed_host parsed_user

  [[ "${uri}" == qemu+ssh://* ]] || {
    echo "ERROR: remote-nbd requires qemu+ssh secondary URI" >&2
    return 2
  }
  rest="${uri#qemu+ssh://}"
  rest="${rest%%/*}"
  if [[ "${rest}" == *"@"* ]]; then
    parsed_user="${rest%@*}"
    parsed_host="${rest#*@}"
  else
    parsed_user="${FTCTL_PROFILE_FENCING_SSH_USER}"
    parsed_host="${rest}"
  fi
  [[ -n "${parsed_host}" ]] || {
    echo "ERROR: could not parse remote host from URI: ${uri}" >&2
    return 2
  }
  [[ -n "${parsed_user}" ]] || parsed_user="root"
  printf -v "${host_var}" '%s' "${parsed_host}"
  printf -v "${user_var}" '%s' "${parsed_user}"
}

ftctl_blockcopy_remote_target_host_user() {
  local host_var="${1}"
  local user_var="${2}"
  local record="" host_id="" role="" mgmt_ip="" libvirt_uri="" blockcopy_ip="" xcolo_ctrl="" xcolo_data=""
  local resolved_host="" resolved_user=""

  resolved_user="${FTCTL_PROFILE_FENCING_SSH_USER:-root}"
  if ftctl_cluster_find_peer_record_for_vm record 2>/dev/null; then
    ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
    : "${host_id}${role}${libvirt_uri}${blockcopy_ip}${xcolo_ctrl}${xcolo_data}"
    resolved_host="${mgmt_ip}"
  fi
  if [[ -z "${resolved_host}" ]]; then
    ftctl_blockcopy_parse_ssh_target_from_uri "${FTCTL_PROFILE_SECONDARY_URI}" resolved_host resolved_user || return 2
  fi
  printf -v "${host_var}" '%s' "${resolved_host}"
  printf -v "${user_var}" '%s' "${resolved_user}"
}

ftctl_blockcopy_remote_nbd_port_in_use() {
  local host="${1-}"
  local user="${2-}"
  local port="${3-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "ss -lntp | grep -q ':${port}[[:space:]]'" || true
  [[ "${rc}" == "0" ]]
}

ftctl_blockcopy_remote_path_exists() {
  local host="${1-}"
  local user="${2-}"
  local path="${3-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "test -e $(printf '%q' "${path}")" || true
  [[ "${rc}" == "0" ]]
}

ftctl_blockcopy_remote_nbd_process_exists() {
  local host="${1-}"
  local user="${2-}"
  local needle="${3-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "ps -ef | grep qemu-nbd | grep -F -- $(printf '%q' "${needle}") | grep -v grep >/dev/null" || true
  [[ "${rc}" == "0" ]]
}

ftctl_blockcopy_remote_nbd_progress_looks_alive() {
  local dest_uri="${1-}"
  local secondary_path="${2-}"
  local host="" user="" port="" export_name=""

  ftctl_blockcopy_remote_target_host_user host user || return 1
  export_name="${dest_uri##*/}"
  [[ -n "${export_name}" ]] || return 1
  ftctl_blockcopy_remote_nbd_process_exists "${host}" "${user}" "${export_name}" || return 1
  ftctl_blockcopy_remote_nbd_port_extract_from_uri "${dest_uri}" port || return 1
  ftctl_blockcopy_remote_nbd_port_in_use "${host}" "${user}" "${port}" || return 1
  [[ -n "${secondary_path}" ]] || return 0
  ftctl_blockcopy_remote_path_exists "${host}" "${user}" "${secondary_path}"
}

ftctl_blockcopy_remote_nbd_active_count() {
  local host="${1-}"
  local user="${2-}"
  local out_var="${3}"
  local out err rc count remote_cmd

  out=""
  err=""
  rc=0
  remote_cmd=$(cat <<EOF
ss -lntp | python3 -c 'import sys,re; base=${FTCTL_REMOTE_NBD_PORT_BASE}; end=${FTCTL_REMOTE_NBD_PORT_BASE}+${FTCTL_REMOTE_NBD_PORT_COUNT}-1; n=0
for line in sys.stdin:
    if "qemu-nbd" not in line:
        continue
    m = re.search(r":([0-9]+)\\s", line)
    if not m:
        continue
    p = int(m.group(1))
    if base <= p <= end:
        n += 1
print(n)'
EOF
)
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi
  count="$(tr -dc '0-9' <<< "${out}")"
  [[ "${count}" =~ ^[0-9]+$ ]] || count="0"
  printf -v "${out_var}" '%s' "${count}"
}

ftctl_blockcopy_remote_nbd_pick_port() {
  local vm="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local record="" host="" user="" active_count=0 preferred=0 candidate=0 i=0 existing_uri="" existing_port=""

  if [[ "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT}" != "auto" ]]; then
    printf -v "${out_var}" '%s' "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT}"
    return 0
  fi

  if ftctl_blockcopy_state_record_for_target "${vm}" "${target}" record; then
    existing_uri="$(cut -d'|' -f3 <<< "${record}")"
    if ftctl_blockcopy_remote_nbd_port_extract_from_uri "${existing_uri}" existing_port; then
      printf -v "${out_var}" '%s' "${existing_port}"
      return 0
    fi
  fi

  ftctl_blockcopy_remote_target_host_user host user || return 2
  ftctl_blockcopy_remote_nbd_active_count "${host}" "${user}" active_count || true
  if (( active_count >= FTCTL_REMOTE_NBD_MAX_CONCURRENT )); then
    echo "ERROR: remote-nbd active count ${active_count} reached FTCTL_REMOTE_NBD_MAX_CONCURRENT=${FTCTL_REMOTE_NBD_MAX_CONCURRENT}" >&2
    return 3
  fi

  ftctl_blockcopy_remote_nbd_candidate_port "${vm}" "${target}" preferred
  for ((i=0; i<FTCTL_REMOTE_NBD_PORT_COUNT; i++)); do
    candidate=$((FTCTL_REMOTE_NBD_PORT_BASE + ((preferred - FTCTL_REMOTE_NBD_PORT_BASE + i) % FTCTL_REMOTE_NBD_PORT_COUNT)))
    if ! ftctl_blockcopy_remote_nbd_port_in_use "${host}" "${user}" "${candidate}"; then
      printf -v "${out_var}" '%s' "${candidate}"
      return 0
    fi
  done

  echo "ERROR: no free remote-nbd port available in range ${FTCTL_REMOTE_NBD_PORT_BASE}..$((FTCTL_REMOTE_NBD_PORT_BASE + FTCTL_REMOTE_NBD_PORT_COUNT - 1))" >&2
  return 4
}

ftctl_blockcopy_source_virtual_size_bytes() {
  local vm="${1-}"
  local target="${2-}"
  local source_path="${3-}"
  local out_var="${4}"
  local out err rc size_value

  out=""
  err=""
  rc=0
  if [[ -n "${vm}" && -n "${target}" ]]; then
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" domblkinfo "${vm}" "${target}" || true
    if [[ "${rc}" == "0" ]]; then
      size_value="$(awk -F: 'tolower($1) ~ /capacity/ { line=$0; gsub(/[^0-9]/, "", line); print line; exit }' <<< "${out}")"
      if [[ "${size_value}" =~ ^[0-9]+$ ]]; then
        printf -v "${out_var}" '%s' "${size_value}"
        return 0
      fi
    fi
  fi

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- qemu-img info --force-share --output=json "${source_path}" || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi
  size_value="$(python3 -c 'import json, sys; obj=json.loads(sys.argv[1]); print(obj.get("virtual-size", ""))' "${out}")" || return 1
  [[ "${size_value}" =~ ^[0-9]+$ ]] || return 1
  printf -v "${out_var}" '%s' "${size_value}"
}

ftctl_blockcopy_source_allocated_size_bytes() {
  local source_path="${1-}"
  local out_var="${2}"
  local out err rc size_value

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- qemu-img info --force-share --output=json "${source_path}" || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi
  size_value="$(python3 -c 'import json, sys; obj=json.loads(sys.argv[1]); print(obj.get("actual-size", obj.get("virtual-size", "")))' "${out}")" || return 1
  [[ "${size_value}" =~ ^[0-9]+$ ]] || return 1
  printf -v "${out_var}" '%s' "${size_value}"
}

ftctl_blockcopy_disk_bus_from_xml() {
  local xml_path="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local bus_value

  bus_value="$(python3 -c 'import sys, xml.etree.ElementTree as ET; xml_path, target = sys.argv[1], sys.argv[2]; tree = ET.parse(xml_path); root = tree.getroot();
for disk in root.findall("./devices/disk"):
    t = disk.find("target")
    if t is not None and t.get("dev") == target:
        print(t.get("bus", "virtio"))
        break
else:
    print("virtio")' "${xml_path}" "${target}")" || return 1
  printf -v "${out_var}" '%s' "${bus_value}"
}

ftctl_blockcopy_rbd_parse_spec() {
  local spec="${1-}"
  local pool_var="${2}"
  local image_var="${3}"
  local -n _pool_ref="${pool_var}"
  local -n _image_ref="${image_var}"
  local body="" parsed_pool="" parsed_image=""

  [[ "${spec}" == rbd:* ]] || return 1
  body="${spec#rbd:}"
  parsed_pool="${body%%/*}"
  parsed_image="${body#*/}"
  [[ -n "${parsed_pool}" && -n "${parsed_image}" && "${parsed_image}" != "${parsed_pool}" ]] || return 1
  _pool_ref="${parsed_pool}"
  _image_ref="${parsed_image}"
}

ftctl_blockcopy_rbd_connection_from_xml() {
  local xml_path="${1-}"
  local target="${2-}"
  local host_var="${3}"
  local port_var="${4}"
  local user_var="${5}"
  local secret_var="${6}"
  local values

  values="$(python3 -c 'import sys, xml.etree.ElementTree as ET
xml_path, target = sys.argv[1], sys.argv[2]
tree = ET.parse(xml_path)
root = tree.getroot()
for disk in root.findall("./devices/disk"):
    t = disk.find("target")
    if t is None or t.get("dev") != target:
        continue
    source = disk.find("source")
    auth = disk.find("auth")
    host = ""
    port = ""
    user = ""
    secret = ""
    if source is not None:
        h = source.find("host")
        if h is not None:
            host = h.get("name", "")
            port = h.get("port", "")
    if auth is not None:
        user = auth.get("username", "")
        s = auth.find("secret")
        if s is not None:
            secret = s.get("uuid", "")
    print(host)
    print(port)
    print(user)
    print(secret)
    raise SystemExit(0)
raise SystemExit(1)' "${xml_path}" "${target}")" || return 1
  printf -v "${host_var}" '%s' "$(sed -n '1p' <<< "${values}")"
  printf -v "${port_var}" '%s' "$(sed -n '2p' <<< "${values}")"
  printf -v "${user_var}" '%s' "$(sed -n '3p' <<< "${values}")"
  printf -v "${secret_var}" '%s' "$(sed -n '4p' <<< "${values}")"
}

ftctl_blockcopy_remote_nbd_dest_xml_path() {
  local vm="${1-}"
  local target="${2-}"
  printf '%s\n' "${FTCTL_RUN_DIR}/xml/$(ftctl_state_vm_key "${vm}")-${target}-remote-nbd.xml"
}

ftctl_blockcopy_shared_dest_xml_path() {
  local vm="${1-}"
  local target="${2-}"
  printf '%s\n' "${FTCTL_RUN_DIR}/xml/$(ftctl_state_vm_key "${vm}")-${target}-shared-blockcopy.xml"
}

ftctl_blockcopy_build_remote_nbd_dest_xml() {
  local vm="${1-}"
  local target="${2-}"
  local format="${3-}"
  local export_addr="${4-}"
  local export_port="${5-}"
  local export_name="${6-}"
  local source_xml="${7-}"
  local out_path_var="${8}"
  local out_path bus

  out_path="$(ftctl_blockcopy_remote_nbd_dest_xml_path "${vm}" "${target}")"
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"
  bus="virtio"
  if [[ -n "${source_xml}" && -f "${source_xml}" ]]; then
    ftctl_blockcopy_disk_bus_from_xml "${source_xml}" "${target}" bus || true
  fi
  cat > "${out_path}" <<EOF
<disk type='network' device='disk'>
  <driver name='qemu' type='${format}'/>
  <source protocol='nbd' name='${export_name}'>
    <host name='${export_addr}' port='${export_port}' transport='tcp'/>
  </source>
  <target dev='${target}' bus='${bus}'/>
</disk>
EOF
  printf -v "${out_path_var}" '%s' "${out_path}"
}

ftctl_blockcopy_build_shared_dest_xml() {
  local vm="${1-}"
  local target="${2-}"
  local format="${3-}"
  local dest="${4-}"
  local source_xml="${5-}"
  local out_path_var="${6}"
  local out_path bus disk_type source_attr_name
  local rbd_pool="" rbd_image="" rbd_host="" rbd_port="" rbd_user="" rbd_secret=""

  out_path="$(ftctl_blockcopy_shared_dest_xml_path "${vm}" "${target}")"
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"
  bus="virtio"
  if [[ -n "${source_xml}" && -f "${source_xml}" ]]; then
    ftctl_blockcopy_disk_bus_from_xml "${source_xml}" "${target}" bus || true
  fi

  if [[ "${dest}" == rbd:* ]]; then
    disk_type="network"
    source_attr_name=""
    ftctl_blockcopy_rbd_parse_spec "${dest}" rbd_pool rbd_image || return 1
    if [[ -n "${source_xml}" && -f "${source_xml}" ]]; then
      ftctl_blockcopy_rbd_connection_from_xml "${source_xml}" "${target}" rbd_host rbd_port rbd_user rbd_secret || true
    fi
    [[ -n "${rbd_host}" ]] || rbd_host="scvm"
    [[ -n "${rbd_port}" ]] || rbd_port="6789"
    [[ -n "${rbd_user}" ]] || rbd_user="admin"
    [[ -n "${rbd_secret}" ]] || rbd_secret="11111111-1111-1111-1111-111111111111"
  elif [[ "${dest}" == /dev/* ]]; then
    disk_type="block"
    source_attr_name="dev"
  else
    disk_type="file"
    source_attr_name="file"
  fi

  if [[ "${disk_type}" == "network" ]]; then
    cat > "${out_path}" <<EOF
<disk type='network' device='disk'>
  <driver name='qemu' type='${format}'/>
  <auth username='${rbd_user}'>
    <secret type='ceph' uuid='${rbd_secret}'/>
  </auth>
  <source protocol='rbd' name='${rbd_pool}/${rbd_image}'>
    <host name='${rbd_host}' port='${rbd_port}'/>
  </source>
  <target dev='${target}' bus='${bus}'/>
</disk>
EOF
  else
    cat > "${out_path}" <<EOF
<disk type='${disk_type}' device='disk'>
  <driver name='qemu' type='${format}'/>
  <source ${source_attr_name}='${dest}'/>
  <target dev='${target}' bus='${bus}'/>
</disk>
EOF
  fi
  printf -v "${out_path_var}" '%s' "${out_path}"
}

ftctl_blockcopy_remote_exec() {
  local host="${1-}"
  local user="${2-}"
  local out_var="${3}"
  local err_var="${4}"
  local rc_var="${5}"
  local remote_cmd="${6-}"
  local tmp_cmd=""
  local local_wrapper=""
  [[ -n "${host}" ]] || {
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' "missing_remote_host"
    printf -v "${rc_var}" '%s' "2"
    return 2
  }
  [[ -n "${user}" ]] || user="root"
  [[ -n "${remote_cmd}" ]] || {
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' "missing_remote_command"
    printf -v "${rc_var}" '%s' "2"
    return 2
  }
  tmp_cmd="$(mktemp -t ftctl.remote.XXXXXX)"
  printf '%s\n' "${remote_cmd}" > "${tmp_cmd}"
  chmod 0600 "${tmp_cmd}" 2>/dev/null || true
  printf -v local_wrapper 'ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=%q %q %q < %q' \
    "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" \
    "${user}@${host}" \
    "bash -s" \
    "${tmp_cmd}"
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" "${out_var}" "${err_var}" "${rc_var}" -- \
    bash -lc "${local_wrapper}"
  rm -f -- "${tmp_cmd}" 2>/dev/null || true
}

ftctl_blockcopy_secondary_uri_is_local_system() {
  [[ "${FTCTL_PROFILE_SECONDARY_URI}" == "qemu:///system" ]]
}

ftctl_blockcopy_remote_nbd_prepare_target() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local format="${4-}"
  local secondary_path="${5-}"
  local export_name="${6-}"
  local export_port="${7-}"
  local host="" user="" size="" alloc_size="" out="" err="" rc=0 pid_file="" remote_cmd="" debug_cmd=""

  ftctl_blockcopy_remote_target_host_user host user || return 2
  ftctl_blockcopy_source_virtual_size_bytes "${vm}" "${target}" "${source}" size || {
    echo "ERROR: could not determine source virtual size for ${source}" >&2
    return 2
  }
  ftctl_blockcopy_source_allocated_size_bytes "${source}" alloc_size || alloc_size="${size}"

  pid_file="/run/ablestack-vm-ftctl/nbd-${vm}-${target}.pid"
  if [[ -b "${secondary_path}" ]]; then
    lvchange -an "${secondary_path}" >/dev/null 2>&1 || true
  fi
remote_cmd=$(cat <<EOF
set -euo pipefail
mkdir -p /run/ablestack-vm-ftctl
if [[ "${secondary_path}" == /dev/rbd/* ]]; then
  krbd_spec="${secondary_path#/dev/rbd/}"
  if [[ -b "${secondary_path}" ]]; then
    krbd_real="\$(readlink -f "${secondary_path}" 2>/dev/null || true)"
    krbd_open="0"
    if [[ -n "\${krbd_real}" ]]; then
      krbd_open="\$(dmsetup info -C --noheadings -o open "\${krbd_real}" 2>/dev/null | awk 'NR==1{print \$1}' || true)"
    fi
    if [[ "\${krbd_open}" == "0" ]]; then
      rbd unmap "${secondary_path}" >/dev/null 2>&1 || true
      udevadm settle >/dev/null 2>&1 || true
    fi
  fi
  if [[ ! -b "${secondary_path}" ]]; then
    rbd map "\${krbd_spec}" >/dev/null
    udevadm settle >/dev/null 2>&1 || true
  fi
fi
if [[ -b "${secondary_path}" && "${secondary_path}" != /dev/rbd/* ]]; then
  secondary_real="\$(readlink -f "${secondary_path}" 2>/dev/null || true)"
  stale_map=""
  if [[ -n "\${secondary_real}" ]]; then
    stale_map="\$(dmsetup info -C --noheadings -o name "\${secondary_real}" 2>/dev/null | awk 'NR==1{print \$1}' || true)"
  fi
  vg_name="\$(lvs --noheadings -o vg_name "${secondary_path}" 2>/dev/null | awk 'NR==1{gsub(/^[ \t]+|[ \t]+$/, \"\", \$0); print \$0}' || true)"
  echo "=== PRE-LVCHANGE ==="
  lvs -a -o lv_name,lv_attr,lv_active "${secondary_path}" 2>/dev/null || true
  if [[ -n "\${secondary_real}" ]]; then
    dmsetup info -c "\${secondary_real}" 2>/dev/null || true
  fi
  if [[ -b "${source}" ]]; then
    lvchange -an "${source}" >/dev/null 2>&1 || true
  fi
  lvchange -an "${secondary_path}" >/dev/null 2>&1 || true
  if [[ -n "\${stale_map}" && -n "\${secondary_real}" ]]; then
    stale_open="\$(dmsetup info -C --noheadings -o open "\${secondary_real}" 2>/dev/null | awk 'NR==1{print \$1}' || true)"
    if [[ "\${stale_open}" == "0" ]]; then
      dmsetup remove "\${stale_map}" >/dev/null 2>&1 || true
      udevadm settle >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "\${vg_name}" ]]; then
    vgchange --refresh "\${vg_name}" >/dev/null 2>&1 || true
  fi
  vgscan --mknodes >/dev/null 2>&1 || true
  lvchange -ay "${secondary_path}"
  udevadm settle >/dev/null 2>&1 || true
  echo "=== POST-LVCHANGE ==="
  lvs -a -o lv_name,lv_attr,lv_active "${secondary_path}" 2>/dev/null || true
  if [[ -n "\${secondary_real}" ]]; then
    dmsetup info -c "\${secondary_real}" 2>/dev/null || true
  fi
  if [[ "${format}" != "raw" ]]; then
    current_format="\$(qemu-img info --force-share --output=json "${secondary_path}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"format\",\"\"))' 2>/dev/null || true)"
    if [[ "\${current_format}" != "${format}" ]]; then
      qemu-img create -f "${format}" "${secondary_path}" "${size}"
    fi
  fi
elif [[ -b "${secondary_path}" && "${secondary_path}" == /dev/rbd/* ]]; then
  if [[ "${format}" != "raw" ]]; then
    current_format="\$(qemu-img info --force-share --output=json "${secondary_path}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"format\",\"\"))' 2>/dev/null || true)"
    if [[ "\${current_format}" != "${format}" ]]; then
      qemu-img create -f "${format}" "${secondary_path}" "${size}"
    fi
  fi
else
  mkdir -p "$(dirname "${secondary_path}")"
  avail_bytes="\$(df -B1 --output=avail "$(dirname "${secondary_path}")" | tail -n 1 | tr -dc '0-9' || true)"
  if [[ -n "\${avail_bytes}" && "\${avail_bytes}" =~ ^[0-9]+$ ]] && (( avail_bytes < ${alloc_size} )); then
    echo "insufficient_space:${secondary_path}:\${avail_bytes}:${alloc_size}" >&2
    exit 97
  fi
  if [[ ! -f "${secondary_path}" ]]; then
    qemu-img create -f "${format}" "${secondary_path}" "${size}"
  fi
fi
if [[ -f "${pid_file}" ]]; then
  oldpid="\$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ -n "\${oldpid}" ]] && kill -0 "\${oldpid}" >/dev/null 2>&1; then
    kill "\${oldpid}" >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -f "${pid_file}"
fi
listener_pids="\$(ss -lntp | awk '/:${export_port}[[:space:]]/ { while (match(\$0, /pid=[0-9]+/)) { print substr(\$0, RSTART+4, RLENGTH-4); \$0=substr(\$0, RSTART+RLENGTH) } }' | sort -u)"
for listener_pid in \${listener_pids}; do
  [[ -n "\${listener_pid}" ]] || continue
  cmdline="\$(tr '\0' ' ' < /proc/\${listener_pid}/cmdline 2>/dev/null || true)"
  if [[ "\${cmdline}" == *qemu-nbd* ]]; then
    kill "\${listener_pid}" >/dev/null 2>&1 || true
    sleep 1
  fi
done
if ss -lntp | grep -q ":${export_port}[[:space:]]"; then
  echo "port_in_use:${export_port}" >&2
  exit 98
fi
qemu-nbd --fork --persistent --shared=8 \
  --bind "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" \
  --port "${export_port}" \
  --export-name "${export_name}" \
  --format "${format}" \
  --pid-file "${pid_file}" \
  "${secondary_path}"
EOF
)
  debug_cmd="$(tr '\n' ' ' <<< "${remote_cmd}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-stdout.txt" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-rc.txt" "${rc}"
  : "${out}${err}"
  [[ "${rc}" == "0" ]] || {
    echo "ERROR: remote-nbd prepare context: host=${host} user=${user} size=${size} format=${format} secondary_path=${secondary_path} export=${export_name}" >&2
    echo "ERROR: remote-nbd prepare command: ${debug_cmd}" >&2
    [[ -n "${err}" ]] && echo "ERROR: remote-nbd prepare failed: ${err}" >&2
    return "${rc}"
  }
}

ftctl_blockcopy_start_remote_nbd_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local format="${4-}"
  local persistence="${5-unknown}"
  local xml_path="${6-}"
  local out_var="${7-}"
  local err_var="${8-}"
  local rc_var="${9-}"
  local out err rc
  local args=()

  args=(-c "${uri}" blockcopy "${vm}" "${target}" --xml "${xml_path}")
  if [[ "${persistence}" == "yes" ]]; then
    args+=(--transient-job)
  fi
  if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
    args+=(--synchronous-writes)
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- "${args[@]}" || true
  : "${out}${err}"
  if [[ -n "${out_var}" ]]; then
    printf -v "${out_var}" '%s' "${out}"
  fi
  if [[ -n "${err_var}" ]]; then
    printf -v "${err_var}" '%s' "${err}"
  fi
  if [[ -n "${rc_var}" ]]; then
    printf -v "${rc_var}" '%s' "${rc}"
  fi
  return "${rc}"
}

ftctl_blockcopy_start_shared_xml_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local persistence="${4-unknown}"
  local xml_path="${5-}"
  local out_var="${6-}"
  local err_var="${7-}"
  local rc_var="${8-}"
  local out err rc
  local args=()

  args=(-c "${uri}" blockcopy "${vm}" "${target}" --xml "${xml_path}")
  if [[ "${persistence}" == "yes" ]]; then
    args+=(--transient-job)
  fi
  if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
    args+=(--synchronous-writes)
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- "${args[@]}" || true
  : "${out}${err}"
  if [[ -n "${out_var}" ]]; then
    printf -v "${out_var}" '%s' "${out}"
  fi
  if [[ -n "${err_var}" ]]; then
    printf -v "${err_var}" '%s' "${err}"
  fi
  if [[ -n "${rc_var}" ]]; then
    printf -v "${rc_var}" '%s' "${rc}"
  fi
  return "${rc}"
}

ftctl_blockcopy_write_remote_nbd_repro() {
  local vm="${1-}"
  local target="${2-}"
  local xml_path="${3-}"
  local remote_host="${4-}"
  local remote_user="${5-}"
  local remote_cmd="${6-}"
  local persistence="${7-}"
  local cmd script

  cmd="env LC_ALL=C LANG=C virsh -c ${FTCTL_PROFILE_PRIMARY_URI@Q} blockcopy ${vm@Q} ${target@Q} --xml ${xml_path@Q}"
  if [[ "${persistence}" == "yes" ]]; then
    cmd+=" --transient-job"
  fi
  if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
    cmd+=" --synchronous-writes"
  fi

  script=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "[REPRO] remote prepare on secondary host"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${remote_user}@${remote_host}" bash -lc $(printf '%q' "${remote_cmd}")

echo "[REPRO] blockcopy command on primary host"
${cmd}
EOF
)
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "remote-nbd-repro.sh" "${script}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-command.txt" "${cmd}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-command.txt" "${remote_cmd}"
  if [[ -f "${xml_path}" ]]; then
    ftctl_blockcopy_write_debug_file "${vm}" "${target}" "remote-nbd-dest.xml" "$(cat "${xml_path}")"
  fi
}

ftctl_blockcopy_capture_primary_debug() {
  local vm="${1-}"
  local target="${2-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dumpxml "${vm}" || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-dumpxml.stdout.xml" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-dumpxml.stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-dumpxml.rc.txt" "${rc}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" blockjob "${vm}" "${target}" --info || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockjob.stdout.txt" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockjob.stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockjob.rc.txt" "${rc}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" qemu-monitor-command "${vm}" --pretty '{"execute":"query-block-jobs"}' || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-block-jobs.stdout.json" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-block-jobs.stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-block-jobs.rc.txt" "${rc}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" qemu-monitor-command "${vm}" --pretty '{"execute":"query-named-block-nodes"}' || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-named-block-nodes.stdout.json" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-named-block-nodes.stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-named-block-nodes.rc.txt" "${rc}"
}

ftctl_blockcopy_resolve_reverse_dest() {
  local target="${1-}"
  local source="${2-}"
  local explicit

  if [[ "${FTCTL_PROFILE_FAILBACK_DISK_MAP}" == "source" ]]; then
    printf '%s\n' "${source}"
    return 0
  fi

  explicit="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_FAILBACK_DISK_MAP}" "${target}" 2>/dev/null || true)"
  if [[ -n "${explicit}" ]]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  echo "ERROR: no reverse destination mapping for disk target ${target}" >&2
  return 2
}

ftctl_blockcopy_validate_backend_mode() {
  local vm="${1-}"
  local disks=()
  local line target source format dest secondary_target

  case "${FTCTL_PROFILE_BACKEND_MODE}" in
    shared-blockcopy)
      if [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
        echo "ERROR: shared-blockcopy requires an explicit FTCTL_PROFILE_DISK_MAP with shared-visible target paths" >&2
        return 2
      fi
      ftctl_inventory_collect_vm_disks "${vm}" disks || return $?
      for line in "${disks[@]}"; do
        target="${line%%|*}"
        source="${line#*|}"
        source="${source%%|*}"
        format="${line##*|}"
        dest="$(ftctl_blockcopy_resolve_dest "${vm}" "${target}" "${source}" "${format}")" || return $?
        if [[ "${dest}" == "${FTCTL_BLOCKCOPY_TARGET_BASE_DIR}/"* ]]; then
          echo "ERROR: shared-blockcopy destination must not use the default local blockcopy target base dir: ${dest}" >&2
          return 2
        fi
      done
      ;;
    remote-nbd)
      ftctl_inventory_collect_vm_disks "${vm}" disks || return $?
      for line in "${disks[@]}"; do
        target="${line%%|*}"
        source="${line#*|}"
        source="${source%%|*}"
        format="${line##*|}"
        secondary_target="$(ftctl_blockcopy_remote_nbd_secondary_path "${vm}" "${target}" "${source}" "${format}")"
        [[ -n "${secondary_target}" ]] || {
          echo "ERROR: remote-nbd requires a resolvable secondary target path" >&2
          return 2
        }
      done
      ;;
    *)
      echo "ERROR: unsupported backend mode: ${FTCTL_PROFILE_BACKEND_MODE}" >&2
      return 2
      ;;
  esac
}

ftctl_blockcopy_start_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local dest="${4-}"
  local format="${5-}"
  local force_reuse="${6-0}"
  local persistence="${7-unknown}"
  local out_var="${8-}"
  local err_var="${9-}"
  local rc_var="${10-}"
  local out err rc
  local args=()

  args=(-c "${uri}" blockcopy "${vm}" "${target}" "${dest}")
  if [[ -n "${format}" ]]; then
    args+=(--format "${format}")
  fi
  if [[ "${persistence}" == "yes" ]]; then
    args+=(--transient-job)
  fi
  if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
    args+=(--synchronous-writes)
  fi
  if [[ "${force_reuse}" == "1" ]]; then
    args+=(--reuse-external)
  fi
  if [[ "${FTCTL_BLOCKCOPY_BANDWIDTH_MIB}" =~ ^[1-9][0-9]*$ ]]; then
    args+=("${FTCTL_BLOCKCOPY_BANDWIDTH_MIB}")
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- "${args[@]}" || true
  : "${out}${err}"
  if [[ -n "${out_var}" ]]; then
    printf -v "${out_var}" '%s' "${out}"
  fi
  if [[ -n "${err_var}" ]]; then
    printf -v "${err_var}" '%s' "${err}"
  fi
  if [[ -n "${rc_var}" ]]; then
    printf -v "${rc_var}" '%s' "${rc}"
  fi
  return "${rc}"
}

ftctl_blockcopy_abort_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" blockjob "${vm}" "${target}" --abort || true
  : "${out}${err}"
  return 0
}

ftctl_blockcopy_state_write_reverse() {
  local vm="${1-}"
  shift
  local path tmp line
  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  tmp="$(mktemp -t ftctl.blockcopy.reverse.XXXXXX)"
  for line in "$@"; do
    printf "%s\n" "${line}" >> "${tmp}"
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_blockcopy_job_query() {
  local vm="${1-}"
  local target="${2-}"
  local state_var="${3}"
  local ready_var="${4}"
  local out err rc state ready

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" blockjob "${vm}" "${target}" --info || true
  if [[ "${rc}" != "0" ]] || grep -qi "no current block job" <<< "${out}${err}"; then
    printf -v "${state_var}" '%s' "unknown"
    printf -v "${ready_var}" '%s' "unknown"
    [[ "${rc}" == "0" ]] && rc=4
    return "${rc}"
  fi

  state="$(awk -F: 'tolower($1) ~ /state/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<< "${out}")"
  ready="$(awk -F: 'tolower($1) ~ /ready/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<< "${out}")"
  if [[ -z "${state}" && "${out}" =~ Block[[:space:]]+Copy:[[:space:]]+\[([0-9.]+)[[:space:]]*%\] ]]; then
    state="copy"
    ready="no"
    if [[ "${BASH_REMATCH[1]}" == "100.00" || "${BASH_REMATCH[1]}" == "100" ]]; then
      ready="yes"
    fi
  fi
  if [[ -z "${state}" && -z "${ready}" ]]; then
    printf -v "${state_var}" '%s' "unknown"
    printf -v "${ready_var}" '%s' "unknown"
    return 5
  fi
  [[ -n "${state}" ]] || state="unknown"
  [[ -n "${ready}" ]] || ready="unknown"
  printf -v "${state_var}" '%s' "${state}"
  printf -v "${ready_var}" '%s' "${ready}"
}

ftctl_blockcopy_runtime_mirror_query() {
  local vm="${1-}"
  local target="${2-}"
  local type_var="${3}"
  local ready_var="${4}"
  local out err rc payload

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dumpxml "${vm}" || true
  if [[ "${rc}" != "0" ]]; then
    printf -v "${type_var}" '%s' "unknown"
    printf -v "${ready_var}" '%s' "unknown"
    return "${rc}"
  fi

  payload="$(python3 -c 'import sys, xml.etree.ElementTree as ET; target=sys.argv[1]; xml_text=sys.argv[2]; root=ET.fromstring(xml_text);
for disk in root.findall("./devices/disk"):
    tgt = disk.find("target")
    if tgt is None or tgt.get("dev") != target:
        continue
    mirror = disk.find("mirror")
    if mirror is None:
        print("none|unknown")
        break
    print(mirror.get("type", "unknown") + "|" + mirror.get("ready", "no"))
    break
else:
    print("none|unknown")' "${target}" "${out}")" || payload="none|unknown"

  printf -v "${type_var}" '%s' "${payload%%|*}"
  printf -v "${ready_var}" '%s' "${payload##*|}"
  [[ "${payload%%|*}" != "none" ]]
}

ftctl_blockcopy_wait_for_job_visibility() {
  local vm="${1-}"
  local target="${2-}"
  local state_var="${3}"
  local ready_var="${4}"
  local tries="${5-5}"
  local state ready rc=0

  state="unknown"
  ready="unknown"
  while ((tries > 0)); do
    if ftctl_blockcopy_job_query "${vm}" "${target}" state ready; then
      printf -v "${state_var}" '%s' "${state}"
      printf -v "${ready_var}" '%s' "${ready}"
      return 0
    fi
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
      if ftctl_blockcopy_runtime_mirror_query "${vm}" "${target}" state ready; then
        if [[ "${state}" == "network" ]]; then
          state="copy"
        fi
        printf -v "${state_var}" '%s' "${state}"
        printf -v "${ready_var}" '%s' "${ready}"
        return 0
      fi
    fi
    rc=$?
    sleep 1
    tries=$((tries - 1))
  done

  printf -v "${state_var}" '%s' "${state}"
  printf -v "${ready_var}" '%s' "${ready}"
  return "${rc}"
}

ftctl_blockcopy_refresh_vm_jobs() {
  local vm="${1-}"
  local disks=()
  local line target source format dest job_state ready secondary_dest runtime_mirror_type existing_record existing_dest
  local records=()
  local all_ready="1"
  local rc_any=0

  ftctl_inventory_collect_vm_disks "${vm}" disks || return $?

  for line in "${disks[@]}"; do
    target="${line%%|*}"
    source="${line#*|}"
    source="${source%%|*}"
    format="${line##*|}"
    secondary_dest=""
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
      existing_record=""
      existing_dest=""
      if ftctl_blockcopy_state_record_for_target "${vm}" "${target}" existing_record; then
        existing_dest="$(cut -d'|' -f3 <<< "${existing_record}")"
        secondary_dest="$(cut -d'|' -f7 <<< "${existing_record}")"
      fi
      if [[ -n "${existing_dest}" && "${existing_dest}" == nbd://* ]]; then
        dest="${existing_dest}"
      else
        dest="$(ftctl_blockcopy_remote_nbd_uri "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT}" "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}")"
      fi
      if [[ -z "${secondary_dest}" ]]; then
        secondary_dest="$(ftctl_blockcopy_remote_nbd_secondary_path "${vm}" "${target}" "${source}" "${format}")"
      fi
    else
      dest="$(ftctl_blockcopy_resolve_dest "${vm}" "${target}" "${source}" "${format}")"
    fi
    job_state="unknown"
    ready="unknown"
    if ! ftctl_blockcopy_job_query "${vm}" "${target}" job_state ready; then
      if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" || "${FTCTL_PROFILE_BACKEND_MODE}" == "shared-blockcopy" ]]; then
        runtime_mirror_type="unknown"
        if ftctl_blockcopy_runtime_mirror_query "${vm}" "${target}" runtime_mirror_type ready; then
          if [[ "${runtime_mirror_type}" == "network" || "${runtime_mirror_type}" == "file" ]]; then
            job_state="copy"
          else
            job_state="${runtime_mirror_type}"
          fi
        elif [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" && -n "${dest}" && "${dest}" == nbd://* ]]; then
          if ftctl_blockcopy_remote_nbd_progress_looks_alive "${dest}" "${secondary_dest}"; then
            job_state="copy"
            ready="no"
          else
            rc_any=1
          fi
        else
          rc_any=1
        fi
      else
        rc_any=1
      fi
    fi
    [[ "${ready}" == "yes" ]] || all_ready="0"
    records+=("${target}|${source}|${dest}|${format}|${job_state}|${ready}|${secondary_dest}")
  done

  ftctl_blockcopy_state_write "${vm}" "${records[@]}"

  if [[ "${all_ready}" == "1" && "${rc_any}" == "0" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=protected" \
      "transport_state=mirroring" \
      "last_sync_ts=$(ftctl_now_iso8601)" \
      "last_error="
  else
    ftctl_state_set "${vm}" \
      "protection_state=syncing" \
      "transport_state=copying" \
      "last_sync_ts=$(ftctl_now_iso8601)"
  fi

  return "${rc_any}"
}

ftctl_blockcopy_plan_protect() {
  local vm="${1-}"
  local disks=()
  local line target source format dest secondary_dest remote_xml shared_xml export_name export_port
  local xml_bundle_dir primary_xml_backup standby_xml_seed persistence
  local out err rc job_state ready
  local records=()
  local sync_flag="0"

  xml_bundle_dir=""
  primary_xml_backup=""
  standby_xml_seed=""
  persistence="unknown"
  if ! ftctl_blockcopy_validate_backend_mode "${vm}"; then
    rc=$?
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=failed" \
      "last_error=backend_mode_validation_failed"
    return "${rc}"
  fi
  ftctl_inventory_backup_domain_xml "${vm}" xml_bundle_dir primary_xml_backup standby_xml_seed persistence
  if [[ "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "yes" || "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "no" ]]; then
    persistence="${FTCTL_PROFILE_DOMAIN_PERSISTENCE}"
  fi
  ftctl_state_set "${vm}" \
    "xml_bundle_dir=${xml_bundle_dir}" \
    "primary_xml_backup=${primary_xml_backup}" \
    "standby_xml_seed=${standby_xml_seed}" \
    "primary_persistence=${persistence}" \
    "secondary_vm_name=$(ftctl_profile_secondary_vm_name_resolved "${vm}")" \
    "backend_mode=${FTCTL_PROFILE_BACKEND_MODE}" \
    "target_storage_scope=${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}"

  ftctl_inventory_collect_vm_disks "${vm}" disks

  for line in "${disks[@]}"; do
    target="${line%%|*}"
    source="${line#*|}"
    source="${source%%|*}"
    format="${line##*|}"
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
      secondary_dest="$(ftctl_blockcopy_remote_nbd_secondary_path "${vm}" "${target}" "${source}" "${format}")"
      export_port=""
      ftctl_blockcopy_remote_nbd_pick_port "${vm}" "${target}" export_port || return $?
      export_name="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}"
      dest="$(ftctl_blockcopy_remote_nbd_uri "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" "${export_port}" "${export_name}")"
    else
      secondary_dest=""
      export_port=""
      export_name=""
      dest="$(ftctl_blockcopy_resolve_dest "${vm}" "${target}" "${source}" "${format}")"
    fi
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" != "remote-nbd" ]]; then
      ftctl_ensure_dir "$(dirname "${dest}")" "0755"
    fi
    if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
      sync_flag="1"
    fi

    out=""
    err=""
    rc=0
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
      ftctl_blockcopy_remote_nbd_prepare_target "${vm}" "${target}" "${source}" "${format}" "${secondary_dest}" "${export_name}" "${export_port}" || return $?
      remote_xml=""
      ftctl_blockcopy_build_remote_nbd_dest_xml \
        "${vm}" "${target}" "${format}" \
        "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" "${export_port}" "${export_name}" \
        "${primary_xml_backup}" remote_xml
      {
        local remote_host="" remote_user="" debug_remote_cmd="" debug_size=""
        ftctl_blockcopy_remote_target_host_user remote_host remote_user || true
        ftctl_blockcopy_source_virtual_size_bytes "${vm}" "${target}" "${source}" debug_size || true
        debug_remote_cmd="$(cat <<EOF
set -euo pipefail
mkdir -p "$(dirname "${secondary_dest}")" /run/ablestack-vm-ftctl
if [[ ! -f "${secondary_dest}" ]]; then
  qemu-img create -f "${format}" "${secondary_dest}" "${debug_size}"
fi
qemu-nbd --fork --persistent --shared=8 --bind "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" --port "${export_port}" --export-name "${export_name}" --format "${format}" --pid-file "/run/ablestack-vm-ftctl/nbd-${vm}-${target}.pid" "${secondary_dest}"
EOF
)"
        ftctl_blockcopy_write_remote_nbd_repro "${vm}" "${target}" "${remote_xml}" "${remote_host}" "${remote_user}" "${debug_remote_cmd}" "${persistence}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-context.txt" \
          "host=${remote_host}
user=${remote_user}
size=${debug_size}
format=${format}
secondary_path=${secondary_dest}
export_name=${export_name}
xml_port=${export_port}
xml=${remote_xml}"
      }
      ftctl_blockcopy_start_remote_nbd_job \
        "${FTCTL_PROFILE_PRIMARY_URI}" \
        "${vm}" \
        "${target}" \
        "${format}" \
        "${persistence}" \
        "${remote_xml}" \
        out \
        err \
        rc || true
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stdout.txt" "${out}"
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stderr.txt" "${err}"
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-rc.txt" "${rc}"
      ftctl_blockcopy_capture_primary_debug "${vm}" "${target}"
    else
      if ftctl_blockcopy_is_krbd_path "${dest}"; then
        ftctl_blockcopy_krbd_map_local "${dest}" || return $?
      fi
      shared_xml=""
      ftctl_blockcopy_build_shared_dest_xml \
        "${vm}" "${target}" "${format}" "${dest}" "${primary_xml_backup}" shared_xml
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "shared-blockcopy-dest.xml" "$(cat "${shared_xml}")"
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-command.txt" \
        "env LC_ALL=C LANG=C virsh -c ${FTCTL_PROFILE_PRIMARY_URI@Q} blockcopy ${vm@Q} ${target@Q} --xml ${shared_xml@Q}$( [[ \"${persistence}\" == \"yes\" ]] && printf ' --transient-job' || true )$( [[ \"${FTCTL_BLOCKCOPY_SYNC_WRITES}\" == \"1\" ]] && printf ' --synchronous-writes' || true )"
      ftctl_blockcopy_start_shared_xml_job \
        "${FTCTL_PROFILE_PRIMARY_URI}" \
        "${vm}" \
        "${target}" \
        "${persistence}" \
        "${shared_xml}" \
        out \
        err \
        rc || true
    fi
    if [[ "${rc}" != "0" ]]; then
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=blockcopy_start_failed_${target}"
      ftctl_log_event "mirror" "blockcopy.protect" "fail" "${vm}" "${rc}" \
        "target=${target} dest=${dest}"
      if [[ -n "${err}" ]]; then
        echo "ERROR: blockcopy start failed for ${vm}:${target}: ${err}" >&2
      else
        echo "ERROR: blockcopy start failed for ${vm}:${target} rc=${rc}" >&2
      fi
      if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stdout.txt" "${out}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stderr.txt" "${err}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-rc.txt" "${rc}"
      fi
      return "${rc}"
    fi

    job_state="unknown"
    ready="unknown"
    if ! ftctl_blockcopy_wait_for_job_visibility "${vm}" "${target}" job_state ready 5; then
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=blockcopy_job_query_failed"
      ftctl_log_event "mirror" "blockcopy.query" "fail" "${vm}" "" \
        "target=${target} dest=${dest}"
      if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stdout.txt" "${out}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stderr.txt" "${err}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-rc.txt" "${rc}"
      fi
      return 1
    fi

    records+=("${target}|${source}|${dest}|${format}|${job_state}|${ready}|${secondary_dest}")
    ftctl_log_event "mirror" "blockcopy.start" "ok" "${vm}" "" \
      "target=${target} dest=${dest} format=${format} sync_writes=${sync_flag}"
  done

  ftctl_blockcopy_state_write "${vm}" "${records[@]}"
  ftctl_blockcopy_refresh_vm_jobs "${vm}" || true
  if [[ "${FTCTL_PROFILE_MODE}" == "dr" && "${FTCTL_EXPERIMENT_DR_DEFER_STANDBY_PREPARE:-0}" == "1" ]]; then
    ftctl_log_event "standby" "standby.prepare" "skip" "${vm}" "" "reason=dr_experiment_defer"
  else
    ftctl_standby_prepare "${vm}"
  fi
}

ftctl_blockcopy_rearm() {
  local vm="${1-}"
  local count
  local records=()
  local record target source dest format rc_any=0
  local persistence out err rc
  count="$(ftctl_state_increment "${vm}" "rearm_count")"
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"
  ftctl_state_set "${vm}" \
    "protection_state=rearming" \
    "transport_state=rearm_pending" \
    "last_rearm_ts=$(ftctl_now_iso8601)" \
    "last_error="

  ftctl_standby_blockcopy_records "${vm}" records || {
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=rearm_failed" \
      "last_error=blockcopy_rearm_missing_state"
    return 1
  }

  for record in "${records[@]}"; do
    target="${record%%|*}"
    record="${record#*|}"
    source="${record%%|*}"
    record="${record#*|}"
    dest="${record%%|*}"
    record="${record#*|}"
    format="${record%%|*}"
    : "${source}"
    ftctl_blockcopy_abort_job "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${target}"
    out=""
    err=""
    rc=0
    ftctl_blockcopy_start_job \
      "${FTCTL_PROFILE_PRIMARY_URI}" \
      "${vm}" \
      "${target}" \
      "${dest}" \
      "${format}" \
      "1" \
      "${persistence}" \
      out \
      err \
      rc || true
    if [[ "${rc}" != "0" ]]; then
      rc_any=1
      ftctl_log_event "rearm" "blockcopy.rearm.start" "fail" "${vm}" "" \
        "target=${target} dest=${dest}"
      [[ -n "${err}" ]] && echo "ERROR: blockcopy rearm failed for ${vm}:${target}: ${err}" >&2
    else
      ftctl_log_event "rearm" "blockcopy.rearm.start" "ok" "${vm}" "" \
        "target=${target} dest=${dest} rearm_count=${count}"
    fi
  done

  if [[ "${rc_any}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=rearm_failed" \
      "last_error=blockcopy_rearm_start_failed"
    return 1
  fi

  ftctl_blockcopy_refresh_vm_jobs "${vm}"
  if [[ "${FTCTL_PROFILE_MODE}" == "dr" && "${FTCTL_EXPERIMENT_DR_DEFER_STANDBY_PREPARE:-0}" == "1" ]]; then
    ftctl_log_event "standby" "standby.prepare" "skip" "${vm}" "" "reason=dr_experiment_defer"
  else
    ftctl_standby_prepare "${vm}"
  fi
}

ftctl_blockcopy_prepare_reverse_sync_plan() {
  local vm="${1-}"
  local records=()
  local reverse_records=()
  local record target source dest format reverse_dest

  ftctl_standby_blockcopy_records "${vm}" records || return 1

  for record in "${records[@]}"; do
    target="${record%%|*}"
    record="${record#*|}"
    source="${record%%|*}"
    record="${record#*|}"
    dest="${record%%|*}"
    record="${record#*|}"
    format="${record%%|*}"

    reverse_dest="$(ftctl_blockcopy_resolve_reverse_dest "${target}" "${source}")"
    reverse_records+=("${target}|${dest}|${reverse_dest}|${format}")
  done

  ftctl_blockcopy_state_write_reverse "${vm}" "${reverse_records[@]}"
}

ftctl_blockcopy_start_reverse_sync() {
  local vm="${1-}"
  local path line target source dest format rc_any=0
  local persistence out err rc

  ftctl_blockcopy_prepare_reverse_sync_plan "${vm}" || {
    ftctl_state_set "${vm}" "last_error=reverse_sync_plan_failed"
    return 1
  }

  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  [[ -f "${path}" ]] || return 1
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    target="${line%%|*}"
    line="${line#*|}"
    source="${line%%|*}"
    line="${line#*|}"
    dest="${line%%|*}"
    format="${line##*|}"
    : "${source}"
    out=""
    err=""
    rc=0
    ftctl_blockcopy_start_job \
      "${FTCTL_PROFILE_SECONDARY_URI}" \
      "${vm}" \
      "${target}" \
      "${dest}" \
      "${format}" \
      "1" \
      "${persistence}" \
      out \
      err \
      rc || true
    if [[ "${rc}" != "0" ]]; then
      rc_any=1
      ftctl_log_event "failback" "reverse_sync.start" "fail" "${vm}" "" \
        "target=${target} dest=${dest}"
      [[ -n "${err}" ]] && echo "ERROR: reverse sync start failed for ${vm}:${target}: ${err}" >&2
    else
      ftctl_log_event "failback" "reverse_sync.start" "ok" "${vm}" "" \
        "target=${target} dest=${dest}"
    fi
  done < "${path}"

  if [[ "${rc_any}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=reverse_sync_failed" \
      "last_error=reverse_sync_start_failed"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "transport_state=reverse_syncing" \
    "last_sync_ts=$(ftctl_now_iso8601)"
}

ftctl_blockcopy_stop_remote_nbd_exports() {
  local vm="${1-}"
  local records=()
  local record target source dest format job_state ready secondary_dest
  local host user out err rc pid_file export_name export_port

  ftctl_standby_blockcopy_records "${vm}" records || return 0
  if ! ftctl_blockcopy_secondary_uri_is_local_system; then
    ftctl_blockcopy_remote_target_host_user host user || return 0
  fi

  for record in "${records[@]}"; do
    target=""; source=""; dest=""; format=""; job_state=""; ready=""; secondary_dest=""
    IFS='|' read -r target source dest format job_state ready secondary_dest <<< "${record}"
    pid_file="/run/ablestack-vm-ftctl/nbd-${vm}-${target}.pid"
    export_name="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}"
    export_port=""
    if [[ "${dest}" == nbd://* ]]; then
      ftctl_blockcopy_remote_nbd_port_extract_from_uri "${dest}" export_port || true
    fi

    out="" err="" rc=0
    local stop_cmd
    stop_cmd="$(cat <<EOF
set -euo pipefail
if [[ -f "${pid_file}" ]]; then
  oldpid="\$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ -n "\${oldpid}" ]] && kill -0 "\${oldpid}" >/dev/null 2>&1; then
    kill "\${oldpid}" >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -f "${pid_file}"
fi
if [[ -n "${export_port}" ]]; then
  listener_pids="\$(ss -lntp | awk '/:${export_port}[[:space:]]/ { while (match(\$0, /pid=[0-9]+/)) { print substr(\$0, RSTART+4, RLENGTH-4); \$0=substr(\$0, RSTART+RLENGTH) } }' | sort -u)"
  for listener_pid in \${listener_pids}; do
    [[ -n "\${listener_pid}" ]] || continue
    kill "\${listener_pid}" >/dev/null 2>&1 || true
    sleep 1
  done
fi
if [[ -n "${secondary_dest}" && -e "${secondary_dest}" ]]; then
  for lock_pid in \$(fuser "${secondary_dest}" 2>/dev/null || true); do
    [[ -n "\${lock_pid}" ]] || continue
    comm="\$(ps -p "\${lock_pid}" -o comm= 2>/dev/null || true)"
    if [[ "\${comm}" == qemu-nbd* ]]; then
      kill "\${lock_pid}" >/dev/null 2>&1 || true
      sleep 1
    fi
  done
fi
pkill -f "qemu-nbd.*${vm}.*${target}" >/dev/null 2>&1 || true
EOF
)"
    if ftctl_blockcopy_secondary_uri_is_local_system; then
      ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- bash -lc "${stop_cmd}" || true
    else
      ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${stop_cmd}" || true
    fi
    : "${out}${err}"
    [[ "${rc}" == "0" ]] || {
      [[ -n "${err}" ]] && echo "ERROR: remote-nbd export stop failed: ${err}" >&2
      return "${rc}"
    }
  done
}

ftctl_blockcopy_wait_remote_nbd_release() {
  local vm="${1-}"
  local records=()
  local record target source dest format job_state ready secondary_dest
  local host user out err rc pid_file export_name export_uri export_port

  ftctl_standby_blockcopy_records "${vm}" records || return 0
  if ! ftctl_blockcopy_secondary_uri_is_local_system; then
    ftctl_blockcopy_remote_target_host_user host user || return 0
  fi

  for record in "${records[@]}"; do
    target=""; source=""; dest=""; format=""; job_state=""; ready=""; secondary_dest=""
    IFS='|' read -r target source dest format job_state ready secondary_dest <<< "${record}"
    pid_file="/run/ablestack-vm-ftctl/nbd-${vm}-${target}.pid"
    export_name="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}"
    export_port=""
    if [[ "${dest}" == nbd://* ]]; then
      export_uri="${dest}"
      ftctl_blockcopy_remote_nbd_port_extract_from_uri "${export_uri}" export_port || true
    fi

    out="" err="" rc=0
    local wait_cmd
    wait_cmd="$(cat <<EOF
set -euo pipefail
for _i in \$(seq 1 20); do
  busy=0
  if [[ -f "${pid_file}" ]]; then
    busy=1
  fi
  if [[ -n "${export_port}" ]] && ss -lntp | grep -q ":${export_port}[[:space:]]"; then
    busy=1
  fi
  if [[ -n "${secondary_dest}" && -e "${secondary_dest}" ]]; then
    for lock_pid in \$(fuser "${secondary_dest}" 2>/dev/null || true); do
      [[ -n "\${lock_pid}" ]] || continue
      comm="\$(ps -p "\${lock_pid}" -o comm= 2>/dev/null || true)"
      if [[ "\${comm}" == qemu-nbd* ]]; then
        busy=1
      fi
    done
  fi
  if [[ "\${busy}" == "0" ]]; then
    exit 0
  fi
  sleep 1
done
echo "remote_nbd_release_timeout:${secondary_dest}:${export_port}" >&2
exit 99
EOF
)"
    if ftctl_blockcopy_secondary_uri_is_local_system; then
      ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- bash -lc "${wait_cmd}" || true
    else
      ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${wait_cmd}" || true
    fi
    : "${out}${err}"
    [[ "${rc}" == "0" ]] || {
      [[ -n "${err}" ]] && echo "ERROR: remote-nbd release wait failed: ${err}" >&2
      return "${rc}"
    }
  done
}

ftctl_blockcopy_refresh_and_classify() {
  local vm="${1-}"
  local rc=0
  ftctl_blockcopy_refresh_vm_jobs "${vm}" || rc=$?
  case "${rc}" in
    0)
      if [[ "$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)" == "mirroring" ]]; then
        return 0
      fi
      return 11
      ;;
    *)
      ftctl_state_set "${vm}" \
        "protection_state=degraded" \
        "transport_state=lost" \
        "last_error=blockcopy_refresh_failed"
      return 12
      ;;
  esac
}
