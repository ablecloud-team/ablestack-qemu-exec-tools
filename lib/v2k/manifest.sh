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
# Requires: jq
# ---------------------------------------------------------------------

set -euo pipefail

v2k_manifest_init() {
  local manifest="$1" run_id="$2" workdir="$3" vm="$4" vcenter="$5" mode="$6" dst="$7" inv_json="$8"

  local created_at
  created_at="$(date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/')"

  # Optional env overrides
  # - V2K_TARGET_FORMAT: qcow2|raw
  # - V2K_TARGET_STORAGE_TYPE: file|block
  # - V2K_TARGET_STORAGE_MAP_JSON: {"scsi0:0":"/dev/sdb","scsi0:1":"/dev/sdc"} or file override path
  local target_format storage_type storage_map_json
  target_format="${V2K_TARGET_FORMAT:-qcow2}"
  storage_type="${V2K_TARGET_STORAGE_TYPE:-file}"
  storage_map_json="${V2K_TARGET_STORAGE_MAP_JSON-}"
  if [[ -z "${storage_map_json}" ]]; then
    storage_map_json="{}"
  fi


  case "${target_format}" in
    qcow2|raw) ;;
    *) echo "Unsupported target format: ${target_format}" >&2; return 2;;
  esac

  case "${storage_type}" in
    file|block) ;;
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

  # ✅ 원본 방식: inv_json을 stdin으로 jq에 전달 (이 방식은 "disks 생성 자체는 됨"이 이미 검증됨)
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
    --argjson storage_map "${map_compact}" \
    '
    . as $inv

    # inventory 검증
    | if ($inv.disks|type) != "array" then error("inventory_json .disks is not array") else . end
    | if ($inv.disks|length) == 0 then error("inventory_json .disks is empty") else . end

    # 확장자(파일 타입에서만 사용)
    | ($fmt) as $ext

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
                        ($dst + "/disk" + $idx + "." + $ext)
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

    # block 타입이면 map이 필수
    | if $st=="block" then
        if ([ $disks[] | select(.transfer.target_path=="" or .transfer.target_path=="null") ] | length) > 0 then
          error("target.storage.type=block requires target.storage.map for all disks (disk_id -> /dev/...)")
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
        source: { type:"vmware", mode:$mode, vcenter:$vcenter, vm:$inv.vm },
        target: {
          type:"kvm",
          format:$fmt,
          dst_root:$dst,
          storage:{ type:$st, map:$storage_map },
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
  tmp="$(mktemp)"
  jq --arg key "${key}" --arg ts "${ts}" \
    '.phases[$key].done=true | .phases[$key].ts=$ts' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_snapshot_set() {
  local manifest="$1" which="$2" name="$3"
  tmp="$(mktemp)"
  jq --arg which "${which}" --arg name "${name}" \
    '.disks |= map(.snapshots[$which].name=$name)' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_get_vm_name() { jq -r '.source.vm.name' "$1"; }
v2k_manifest_get_vcenter() { jq -r '.source.vcenter' "$1"; }

v2k_manifest_get_disk_count() { jq -r '.disks|length' "$1"; }

v2k_manifest_get_disk_field() {
  local manifest="$1" idx="$2" jq_expr="$3"
  jq -r ".disks[${idx}]${jq_expr}" "${manifest}"
}

v2k_manifest_set_disk_cbt() {
  local manifest="$1" idx="$2" enabled="$3" base_change_id="$4" last_change_id="$5"
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" --argjson enabled "${enabled}" --arg base "${base_change_id}" --arg last "${last_change_id}" \
    '.disks[$idx].cbt.enabled=$enabled
     | .disks[$idx].cbt.base_change_id=$base
     | .disks[$idx].cbt.last_change_id=$last' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_inc_incr_seq() {
  local manifest="$1" idx="$2"
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" \
    '.disks[$idx].transfer.incr_seq += 1' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_set_disk_metric_incr() {
  local manifest="$1" idx="$2" bytes="$3" areas="$4"
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
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" --arg ts "${ts}" \
    '.disks[$idx].transfer.base_done=true | .disks[$idx].transfer.last_synced_at=$ts' "${manifest}" > "${tmp}"
  mv "${tmp}" "${manifest}"
}

v2k_manifest_status_summary() {
  local manifest="$1" events="${2:-}"
  local msum
  msum="$(jq -c '{run:.run, vm:.source.vm, phases:.phases, disks:(.disks|map({disk_id:.disk_id,target:.transfer.target_path,base_done:.transfer.base_done,incr_seq:.transfer.incr_seq,cbt:.cbt.enabled}))}' "${manifest}")"
  if [[ -n "${events}" && -f "${events}" ]]; then
    local tail
    tail="$(tail -n 20 "${events}" | jq -s '.' 2>/dev/null || echo '[]')"
    printf '{"manifest":%s,"events_tail":%s}\n' "${msum}" "${tail}"
  else
    printf '{"manifest":%s,"events_tail":[]}\n' "${msum}"
  fi
}
