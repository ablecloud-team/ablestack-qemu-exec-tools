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
#
# Requires: jq
# ---------------------------------------------------------------------

set -euo pipefail

# Manifest helpers
# - manifest.json is the source of truth for pipeline steps
# - Use jq to mutate (atomic write)

v2k_manifest_path() {
  echo "${V2K_MANIFEST:?Manifest path not set}"
}

v2k_manifest_init() {
  local manifest="$1" run_id="$2" workdir="$3" vm="$4" vcenter="$5" mode="$6" dst="$7" inv_json="$8"

  local created_at
  created_at="$(date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/')"

  # VDDK(vCenter 중심) 메타데이터/오버라이드
  # - V2K_VDDK_SERVER: vCenter host/ip (권장)
  # - V2K_VDDK_THUMBPRINT: vCenter SSL SHA1 thumbprint (권장)
  # - V2K_VDDK_USER: 선택(cred_file 내부의 VDDK_USER/VDDK_PASSWORD가 실사용)
  # - V2K_VDDK_CRED_FILE: workdir 하위에 복사된 vddk.cred 경로
  local vcenter_host vddk_server vddk_thumbprint vddk_user vddk_cred_file
  vcenter_host="$(printf '%s' "${vcenter}" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#^.*@##; s#:[0-9]+$##')"
  vddk_server="${V2K_VDDK_SERVER-}"
  vddk_thumbprint="${V2K_VDDK_THUMBPRINT-}"
  vddk_user="${V2K_VDDK_USER-}"
  vddk_cred_file="${V2K_VDDK_CRED_FILE-}"

  # Optional env overrides (set by engine.sh from CLI options)
  # - V2K_TARGET_FORMAT: qcow2|raw
  # - V2K_TARGET_STORAGE_TYPE: file|block|rbd
  # - V2K_TARGET_STORAGE_MAP_JSON: {"scsi0:0":"/dev/sdb","scsi0:1":"/dev/sdc"} or file override path
  local target_format storage_type storage_map_json
  target_format="${V2K_TARGET_FORMAT:-qcow2}"
  storage_type="${V2K_TARGET_STORAGE_TYPE:-file}"
  storage_map_json="${V2K_TARGET_STORAGE_MAP_JSON-}"
  if [[ -z "${storage_map_json}" ]]; then
    storage_map_json="{}"
  fi

  # Optional env override (set by engine.sh init option --force-block-device)
  local force_block_device
  force_block_device="${V2K_FORCE_BLOCK_DEVICE:-0}"

  # NOTE: vddk_* locals are already declared above. (remove duplicate locals)

  case "${target_format}" in
    qcow2|raw) ;;
    *) echo "Unsupported target format: ${target_format}" >&2; return 2;;
  esac

  case "${storage_type}" in
    file|block|rbd) ;;
    *) echo "Unsupported storage type: ${storage_type}" >&2; return 2;;
  esac

  # inventory JSON이 단일 JSON 객체인지 정규화 (여기서 깨지면 즉시 실패)
  local inv_compact
  if ! inv_compact="$(printf '%s' "${inv_json}" | jq -c '.' 2>/dev/null)"; then
    echo "[ERR] inv_json is not a single valid JSON object." >&2
    echo "------ inv_json raw (first 400 chars) ------" >&2
    printf '%s' "${inv_json}" | head -c 400 >&2
    echo >&2
    return 2
  fi

  # storage_map JSON도 정규화
  local map_compact
  if ! map_compact="$(printf '%s' "${storage_map_json}" | jq -c '.' 2>/dev/null)"; then
    echo "[ERR] V2K_TARGET_STORAGE_MAP_JSON is not valid JSON: ${storage_map_json}" >&2
    return 2
  fi

  local vmhash
  vmhash="$(jq -r '.vm.name // ""' <<<"${inv_compact}" | sha256sum | awk '{print substr($1,1,8)}')"
  [[ -n "${vmhash}" ]] || vmhash="00000000"

  # ✅ inv_json을 stdin으로 jq에 전달 (검증된 패턴)
  printf '%s' "${inv_compact}" | jq -c \
    --arg schema "ablestack-v2k/manifest-v1" \
    --arg run_id "${run_id}" \
    --arg created_at "${created_at}" \
    --arg workdir "${workdir}" \
    --arg vcenter "${vcenter}" \
    --arg mode "${mode}" \
    --arg dst "${dst}" \
    --arg fmt "${target_format}" \
    --arg st "${storage_type}" \
    --arg force_block_device "${force_block_device}" \
    --arg vcenter_host "${vcenter_host}" \
    --arg vddk_server "${vddk_server}" \
    --arg vddk_thumbprint "${vddk_thumbprint}" \
    --arg vddk_user "${vddk_user}" \
    --arg vddk_cred_file "${vddk_cred_file}" \
    --arg vmhash "${vmhash}" \
    --argjson storage_map "${map_compact}" \
    '
    def strip_vim_url($u):
      ($u|tostring)
      | sub("^https?://";"")
      | sub("/sdk$";"")
      | sub("/$";"");

    . as $inv

    # inventory 검증
    | if ($inv.disks|type) != "array" then error("inventory_json .disks is not array") else . end
    | if ($inv.disks|length) == 0 then error("inventory_json .disks is empty") else . end

    # 확장자(파일 타입에서만 사용)
    | ($fmt) as $ext

    # VM 이름 정규화 + 해시
    | ($inv.vm.name|tostring) as $vmname_raw
    | ($vmname_raw
        | gsub("[/\\\\]"; "_")
        | gsub("[[:cntrl:]]"; "_")
        | gsub("[[:space:]]+"; "_")
        | gsub("^[.]+$"; "_")
        | gsub("^[.]"; "_")
        | gsub("_+"; "_")
      ) as $vmname_norm
    | (if ($vmname_norm|length) > 0 then $vmname_norm else "vm" end) as $vmname
    | ($vmname + "-" + $vmhash) as $vmname_file

    # 디스크 변환: to_entries는 {key,value} 이므로 key를 인덱스로 사용
    | ($inv.disks
        | to_entries
        | map(
            . as $e
            | ($e.key|tostring) as $idx
            | ($e.value.disk_id) as $disk_id
            | ($storage_map[$disk_id] // "") as $override
            | ($override|tostring) as $ov

            | ($e.value + {
                cbt:{ enabled:false, base_change_id:"", last_change_id:"" },
                snapshots:{ base:{name:"",ref:""}, incr:{name:"",ref:""}, final:{name:"",ref:""}, use_current_for_final:false },
                transfer:{
                  target_path: (
                    if ($ov|length) > 0 then
                      $ov
                    else
                      if $st=="file" then
                        ($dst + "/" + $vmname_file + "-disk" + $idx + "." + $ext)
                      else
                        ""
                      end
                    end
                  ),
                  base_done:false, incr_seq:0, last_synced_at:""
                },
                metrics:{ base_bytes_written:0, incr_bytes_written:0, incr_areas:0 }
              })
          )
      ) as $disks

    # block/rbd 타입이면 map이 필수
    | if ($st=="block" or $st=="rbd") then
        if ([ $disks[] | select(.transfer.target_path=="" or .transfer.target_path=="null") ] | length) > 0 then
          error("target.storage.type=" + $st + " requires target.storage.map for all disks")
        else . end
      else . end

    # rbd 타입이면 각 target_path가 rbd: 로 시작해야 함
    | if $st=="rbd" then
        if ([ $disks[] | select((.transfer.target_path|tostring|startswith("rbd:"))|not) ] | length) > 0 then
          error("target.storage.type=rbd requires transfer.target_path to start with rbd:")
        else . end
      else . end

    # target_path 중복 방지
    | ( [ $disks[] | .transfer.target_path ] as $paths
        | if (($paths|length) != (($paths|sort|unique)|length)) then
            error("Duplicate transfer.target_path detected")
          else . end
      )

    | {
        schema: $schema,
        run: { run_id: $run_id, created_at: $created_at, workdir: $workdir },
        source: {
          type:"vmware",
          mode:$mode,
          vcenter:$vcenter,
          vm:$inv.vm,

          # ESXi host where the VM is currently running (kept for future use)
          esxi_host: ($inv.esxi_host // ""),
          esxi_name: ($inv.esxi_name // ""),
          esxi_thumbprint: ($inv.esxi_thumbprint // ""),

          # VDDK access (vCenter 중심)
          # - server: 기본 vCenter host (override 가능)
          # - thumbprint: vCenter SSL SHA1 thumbprint (override 가능)
          # - cred_file: VDDK_USER/VDDK_PASSWORD[/VDDK_SERVER/VDDK_THUMBPRINT] 포함
          vddk: {
            server: (if ($vddk_server|length) > 0 then $vddk_server else $vcenter_host end),
            thumbprint: (if ($vddk_thumbprint|length) > 0 then $vddk_thumbprint else "" end),
            user: (if ($vddk_user|length) > 0 then $vddk_user else "" end),
            cred_file: (if ($vddk_cred_file|length) > 0 then $vddk_cred_file else "" end)
          }
        },
        target: {
          type:"kvm",
          format:$fmt,
          dst_root:$dst,
          storage:{
            type:$st,
            map:$storage_map,
            force_block_device: ($force_block_device == "1")
          },
          libvirt:{ name:$inv.vm.name, uefi:true, tpm:false }
        },
        disks: $disks,
        phases:{
          init:{done:true, ts:$created_at},
          cbt_enable:{done:false, ts:""},
          base_sync:{done:false, ts:""},
          incr_sync:{done:false, ts:""},
          final_sync:{done:false, ts:""},
          cutover:{done:false, ts:""}
        }
      }
    ' > "${manifest}"
}

v2k_manifest_phase_done() {
  local manifest="$1" key="$2"
  local ts
  ts="$(date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/')"
  local tmp
  tmp="$(mktemp)"
  jq --arg key "${key}" --arg ts "${ts}" \
    '.phases[$key].done=true | .phases[$key].ts=$ts' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_snapshot_set() {
  local manifest="$1" which="$2" name="$3"
  local tmp
  tmp="$(mktemp)"
  jq --arg which "${which}" --arg name "${name}" \
    '.disks |= map(.snapshots[$which].name=$name)' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_get_vm_name() { jq -r '.source.vm.name' "$1"; }
v2k_manifest_get_vcenter() { jq -r '.source.vcenter' "$1"; }


# Return 0 if the manifest indicates a Windows guest, else 1.
#
# We intentionally keep this heuristic broad because inventory fields can vary by govc/vCenter versions.
# Typical signals include guestId/guest_id containing "windows" or guest family/name containing "Windows".
v2k_manifest_is_windows() {
  local manifest="$1"
  [[ -f "${manifest}" ]] || return 1
  jq -re '
    def s($v): ($v // "") | tostring | ascii_downcase;
    (
      [
        s(.source.vm.guestId),
        s(.source.vm.guest_id),
        s(.source.vm.config.guestId),
        s(.source.vm.config.guest_id),
        s(.source.vm.guest.guestId),
        s(.source.vm.guest.guest_id),
        s(.source.vm.guest.guestFamily),
        s(.source.vm.guest.guest_full_name),
        s(.source.vm.guest.guestFullName),
        s(.source.vm.guest.fullName),
        s(.source.vm.guest.osFullName)
      ]
      | map(select(length>0))
      | join(" ")
    ) as $h
    | ($h | contains("windows") or test("(^|[^a-z])win"))
  ' "${manifest}" >/dev/null 2>&1
}

v2k_manifest_get_disk_count() { jq -r '.disks|length' "$1"; }

v2k_manifest_get_disk_field() {
  local manifest="$1" idx="$2" jq_expr="$3"
  jq -r ".disks[${idx}]${jq_expr}" "${manifest}"
}

v2k_manifest_set_disk_cbt() {
  local manifest="$1" idx="$2" enabled="$3" base_change_id="$4" last_change_id="$5"
  local tmp
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" --argjson enabled "${enabled}" --arg base "${base_change_id}" --arg last "${last_change_id}" \
    '.disks[$idx].cbt.enabled=$enabled
     | .disks[$idx].cbt.base_change_id=$base
     | .disks[$idx].cbt.last_change_id=$last' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_get_disk_base_change_id() {
  local manifest="$1" idx="$2"
  jq -r ".disks[${idx}].cbt.base_change_id // empty" "${manifest}"
}

v2k_manifest_get_disk_last_change_id() {
  local manifest="$1" idx="$2"
  jq -r ".disks[${idx}].cbt.last_change_id // empty" "${manifest}"
}

v2k_manifest_set_disk_base_change_id() {
  local manifest="$1" idx="$2" base_change_id="$3"
  local tmp
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" --arg base "${base_change_id}" \
    '.disks[$idx].cbt.base_change_id=$base' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_set_disk_last_change_id() {
  local manifest="$1" idx="$2" last_change_id="$3"
  local tmp
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" --arg last "${last_change_id}" \
    '.disks[$idx].cbt.last_change_id=$last' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

# After a successful incremental/final patch, advance CBT changeIds.
# - If base_change_id is empty or "*", set it to prev_last_change_id (the baseline for deltas).
# - Always set last_change_id to new_last_change_id.
v2k_manifest_advance_cbt_change_ids() {
  local manifest="$1" idx="$2" prev_last_change_id="$3" new_last_change_id="$4"
  local base
  base="$(v2k_manifest_get_disk_base_change_id "${manifest}" "${idx}")"

  if [[ -z "${new_last_change_id}" || "${new_last_change_id}" == "null" ]]; then
    return 0
  fi

  if [[ -z "${base}" || "${base}" == "null" || "${base}" == "*" ]]; then
    if [[ -n "${prev_last_change_id}" && "${prev_last_change_id}" != "null" && "${prev_last_change_id}" != "*" ]]; then
      v2k_manifest_set_disk_base_change_id "${manifest}" "${idx}" "${prev_last_change_id}"
    fi
  fi
  v2k_manifest_set_disk_last_change_id "${manifest}" "${idx}" "${new_last_change_id}"
}

# Ensure CBT changeId fields are normalized for all CBT-enabled disks.
# IMPORTANT:
# - Never auto-initialize changeId to "*".
# - If one side exists, mirror it.
# - If both are empty, keep them empty (baseline not established yet).
v2k_manifest_ensure_cbt_change_ids() {
  local manifest="$1"
  local count i enabled base last
  count="$(jq -r '.disks|length' "${manifest}")"
  for ((i=0;i<count;i++)); do
    enabled="$(jq -r ".disks[$i].cbt.enabled // false" "${manifest}")"
    [[ "${enabled}" == "true" ]] || continue

    base="$(v2k_manifest_get_disk_base_change_id "${manifest}" "${i}")"
    last="$(v2k_manifest_get_disk_last_change_id "${manifest}" "${i}")"

    # If base is empty but last exists, mirror last -> base
    if [[ -z "${base}" || "${base}" == "null" ]]; then
      if [[ -n "${last}" && "${last}" != "null" ]]; then
        v2k_manifest_set_disk_base_change_id "${manifest}" "${i}" "${last}"
        base="${last}"
      fi
    fi

    # If last is empty but base exists, mirror base -> last
    if [[ -z "${last}" || "${last}" == "null" ]]; then
      if [[ -n "${base}" && "${base}" != "null" ]]; then
        v2k_manifest_set_disk_last_change_id "${manifest}" "${i}" "${base}"
      fi
    fi
  done
}

v2k_manifest_inc_incr_seq() {
  local manifest="$1" idx="$2"
  local tmp
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" \
    '.disks[$idx].transfer.incr_seq += 1' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_set_disk_metric_incr() {
  local manifest="$1" idx="$2" bytes="$3" areas="$4"
  local tmp
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" --argjson bytes "${bytes}" --argjson areas "${areas}" \
    '.disks[$idx].metrics.incr_bytes_written += $bytes
     | .disks[$idx].metrics.incr_areas += $areas' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_mark_base_done() {
  local manifest="$1" idx="$2"
  local ts
  ts="$(date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/')"
  local tmp
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" --arg ts "${ts}" \
    '.disks[$idx].transfer.base_done=true | .disks[$idx].transfer.last_synced_at=$ts' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_status_summary() {
  local manifest="$1" events="${2:-}"
  local msum
  msum="$(jq -c '
    # runtime.sync_issues는 engine.sh가 incr/final guard에서 기록(제품화 관측용)
    (.runtime // {}) as $rt
    | ($rt.sync_issues // []) as $issues
    | {
        run:.run,
        vm:.source.vm,
        phases:.phases,
        disks:(.disks|map({
          disk_id:.disk_id,
          target:.transfer.target_path,
          base_done:.transfer.base_done,
          incr_seq:.transfer.incr_seq,
          cbt_enabled:.cbt.enabled,
          base_change_id:(.cbt.base_change_id // ""),
          last_change_id:(.cbt.last_change_id // "")
        })),

        # ---- Status observability additions ----
        runtime:{
          sync_issues:$issues,
          last_sync_issue:(if ($issues|length) > 0 then $issues[-1] else null end)
        },

        # 사람이 보기 쉬운 "상태 요약 힌트" (UI/CLI 공통 활용)
        hints:{
          has_sync_issues:(($issues|length) > 0),
          last_issue_code:(if ($issues|length) > 0 then ($issues[-1].code // null) else null end),
          last_issue_reason:(if ($issues|length) > 0 then ($issues[-1].reason // "") else "" end)
        }
      }
  ' "${manifest}")"
  if [[ -n "${events}" && -f "${events}" ]]; then
    local tail
    tail="$(tail -n 20 "${events}" | jq -s '.' 2>/dev/null || echo '[]')"
    printf '{"manifest":%s,"events_tail":%s}\n' "${msum}" "${tail}"
  else
    printf '{"manifest":%s,"events_tail":[]}\n' "${msum}"
  fi
}
