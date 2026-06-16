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

# Commit 06 scope:
# - Track per-VM domstate and last change timestamp in /run cache
# - Calculate stuck_sec = now - last_change_ts

# Commit 08 scope:
# - Track migration progress by recording cumulative bytes in a separate file, and calculating incremental progress for
hangctl_state__vm_key() {
  # Safe key for filename
  local vm="${1-}"
  vm="${vm//\//_}"
  vm="${vm// /_}"
  echo -n "${vm}"
}

# Generate path for VM-specific state file in the runtime directory, e.g., /run/ablestack-vm-hangctl/state/<vm>.state
hangctl_state__path() {
  local vm="${1-}"
  local key
  key="$(hangctl_state__vm_key "${vm}")"
  local dir="${HANGCTL_STATE_DIR-}"
  if [[ -z "${dir}" ]]; then
    dir="/run/ablestack-vm-hangctl/state"
  fi
  echo -n "${dir}/${key}.state"
}

# Simple key=value ?Œì¼?ì„œ ?¹ì • ?¤ì˜ ê°’ì„ ?½ëŠ” ? í‹¸ë¦¬í‹° ?¨ìˆ˜
hangctl_state__read_kv() {
  # usage: hangctl_state__read_kv <path> <key>
  local path="${1-}"
  local key="${2-}"
  [[ -f "${path}" ]] || return 1
  grep -E "^${key}=" "${path}" 2>/dev/null | head -n 1 | cut -d= -f2-
}

# VMë³??íƒœ ê¸°ë¡ ?Œì¼??domstate?€ ë§ˆì?ë§?ë³€ê²??œì (timestamp)??ê¸°ë¡?˜ì—¬, hang ?íƒœ ì§€???œê°„??ê³„ì‚°?˜ëŠ” ???œìš©
hangctl_state__write_file() {
  # usage: hangctl_state__write_file <path> <domstate> <last_change_ts>
  local path="${1-}"
  local domstate="${2-}"
  local last_change_ts="${3-}"

  local dir
  dir="$(dirname "${path}")"
  [[ -d "${dir}" ]] || mkdir -p "${dir}" 2>/dev/null || true

  cat > "${path}.tmp" <<EOF
domstate=${domstate}
last_change_ts=${last_change_ts}
EOF
  mv -f "${path}.tmp" "${path}" 2>/dev/null || {
    # best effort
    rm -f "${path}.tmp" 2>/dev/null || true
    return 1
  }
  return 0
}

# VM???„ì¬ domstateë¥?ê¸°ë¡?˜ê³ , ?íƒœ ë³€ê²??œì ???…ë°?´íŠ¸?˜ì—¬ stuck_sec ê³„ì‚°???œìš©
hangctl_state_update_domstate() {
  # usage: hangctl_state_update_domstate <vm> <domstate>
  local vm="${1-}"
  local domstate="${2-}"
  local path
  path="$(hangctl_state__path "${vm}")"

  local now
  now="$(date +%s)"

  local prev_state prev_change
  prev_state="$(hangctl_state__read_kv "${path}" "domstate" || true)"
  prev_change="$(hangctl_state__read_kv "${path}" "last_change_ts" || true)"

  local change_ts="${prev_change}"
  if [[ -z "${prev_state}" ]]; then
    # ì²˜ìŒ ë°œê²¬??VM?€ ?„ì¬ ?íƒœë¥?ê¸°ì??¼ë¡œ ê¸°ë¡???œì‘?˜ì—¬ stuck_sec??0?¼ë¡œ ? ì?
    prev_state="${domstate}"
    change_ts="${now}"
  elif [[ "${prev_state}" != "${domstate}" ]]; then
    change_ts="${now}"
  elif [[ -z "${change_ts}" ]]; then
    change_ts="${now}"
  fi

  hangctl_state__write_file "${path}" "${domstate}" "${change_ts}" || true
}

# VM??hang ?íƒœ?ì„œ ë²—ì–´???„ì—???¼ì • ?œê°„ ?™ì•ˆ ê¸°ë¡??? ì??˜ì—¬, ?¤ìº” ê°„ê²©??ê¸¸ì–´??stuck_sec ê³„ì‚°??ê³„ì† ? íš¨?˜ë„ë¡???
hangctl_state_get_duration_sec() {
  # usage: hangctl_state_get_duration_sec <vm>
  local vm="${1-}"
  local path
  path="$(hangctl_state__path "${vm}")"
  local now
  now="$(date +%s)"
  local change_ts
  change_ts="$(hangctl_state__read_kv "${path}" "last_change_ts" || true)"
  if [[ -z "${change_ts}" ]]; then
    echo -n "0"
    return 0
  fi
  local duration=$(( now - change_ts ))
  if [[ "${duration}" -lt 0 ]]; then
    duration=0
  fi
  echo -n "${duration}"
}


hangctl_state__migration_path() {
  local vm="${1-}"
  echo -n "$(hangctl_state__path "${vm}").migrate"
}

hangctl_state_get_migration_kv() {
  # usage: hangctl_state_get_migration_kv <vm> <key>
  local vm="${1-}"
  local key="${2-}"
  local path
  path="$(hangctl_state__migration_path "${vm}")"

  [[ -f "${path}" ]] || return 1

  # Backward compatibility for the old one-number cache file.
  if [[ "${key}" == "migration_metric_bytes" ]] && grep -Eq '^[0-9]+$' "${path}" 2>/dev/null; then
    head -n 1 "${path}"
    return 0
  fi

  hangctl_state__read_kv "${path}" "${key}"
}

hangctl_state_set_migration_kv_all() {
  # usage: hangctl_state_set_migration_kv_all <vm> <key=value>...
  local vm="${1-}"
  shift || true
  local path
  path="$(hangctl_state__migration_path "${vm}")"

  hangctl_state__write_kv_all "${path}" "$@" || true
}

hangctl_state_reset_migration() {
  local vm="${1-}"
  rm -f "$(hangctl_state__migration_path "${vm}")" 2>/dev/null || true
}

# Migration ì§„í–‰ ?í™© ì¶”ì ???„í•´ ë³„ë„ ?Œì¼???„ì ??ë°”ì´????ê¸°ë¡
hangctl_state_get_migration_progress() {
  # usage: hangctl_state_get_migration_progress <vm> <current_bytes>
  # Compatibility wrapper for older callers. New code should use the
  # migration key-value helpers above.
  local vm="${1-}"
  local current="${2-0}"

  local prev
  prev="$(hangctl_state_get_migration_kv "${vm}" "migration_metric_bytes" 2>/dev/null || echo "0")"
  [[ "${prev}" =~ ^[0-9]+$ ]] || prev=0
  [[ "${current}" =~ ^[0-9]+$ ]] || current=0

  hangctl_state_set_migration_kv_all "${vm}" "migration_metric_bytes=${current}" || true
  echo $(( current - prev ))
}

# VM??ì¢…ë£Œ?˜ì–´ ?íƒœ ì´ˆê¸°?”ê? ?„ìš”??ê²½ìš°, ìºì‹œ ?Œì¼???? œ?˜ì—¬ ?¤ìŒ ?¤ìº”?ì„œ ?ˆë¡­ê²?ê¸°ë¡ ?œì‘
hangctl_state_reset_vm() {
  local vm="${1-}"
  local path
  path="$(hangctl_state__path "${vm}")"
  rm -f "${path}" 2>/dev/null || true
  hangctl_state_reset_migration "${vm}"
  hangctl_log_event "state" "state.reset" "ok" "${vm}" "" "" "reason=vm_not_running"
}

# QMP ?‘ë‹µ???±ê³µ?˜ë©´ ???¨ìˆ˜ë¥??¸ì¶œ?˜ì—¬ ë§ˆì?ë§??±ê³µ ?œì ???„ì¬ë¡?ê°±ì‹ 
hangctl_state_touch_heartbeat() {
  local vm="${1-}"
  local path
  path="$(hangctl_state__path "${vm}")"
  local now
  now="$(date +%s)"
  
  # ?íƒœ?€ ê´€ê³„ì—†??ë§ˆì?ë§??‘ë‹µ ?œì ???„ì¬ë¡??…ë°?´íŠ¸ (?œê°„ ì´ˆê¸°???¨ê³¼)
  hangctl_state__write_file "${path}" "alive" "${now}" || true
}

# state_cache.sh (?…ë°?´íŠ¸ ë°?ì¶”ê?)

# ê¸°ì¡´ write_file???•ì¥?˜ì—¬ ?¬ëŸ¬ ?¤ê°’??? ì—°?˜ê²Œ ?€?¥í•˜?„ë¡ ê°œì„ 
hangctl_state__write_kv_all() {
  # usage: hangctl_state__write_kv_all <path> <key1=val1> <key2=val2> ...
  local path="${1-}"
  shift
  local dir
  dir="$(dirname "${path}")"
  [[ -d "${dir}" ]] || mkdir -p "${dir}" 2>/dev/null || true

  local tmp="${path}.tmp"
  # ê¸°ì¡´ ?Œì¼???ˆìœ¼ë©??½ì–´??? ì??˜ê³ , ?ˆë¡œ??ê°’ë“¤ë¡???–´?€
  if [[ -f "${path}" ]]; then
    cat "${path}" > "${tmp}"
  else
    touch "${tmp}"
  fi

  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    # ê¸°ì¡´ ?¤ê? ?ˆìœ¼ë©??? œ ??ì¶”ê?
    sed -i "/^${k}=/d" "${tmp}"
    echo "${k}=${v}" >> "${tmp}"
  done

  mv -f "${tmp}" "${path}" 2>/dev/null || return 1
}

# QMP ?‘ë‹µ ?±ê³µ ???¸ì¶œ (ê¸°ì¡´ ?¨ìˆ˜ ? ì??˜ë˜ ?•ì¥??write_kv_all ?¬ìš©)
hangctl_state_touch_heartbeat() {
  local vm="${1-}"
  local path
  path="$(hangctl_state__path "${vm}")"
  local now
  now="$(date +%s)"
  
  # heartbeat ?œì ??blockstats??? ì??˜ê³  alive ?íƒœ?€ tsë§?ê°±ì‹ 
  hangctl_state__write_kv_all "${path}" "domstate=alive" "last_change_ts=${now}" || true
}

# ? ê·œ: ë¸”ë¡ ?µê³„(Read/Write Ops) ?€??
hangctl_state_update_blockstats() {
  # usage: hangctl_state_update_blockstats <vm> <rd_ops> <wr_ops>
  local vm="${1-}"
  local rd_ops="${2-0}"
  local wr_ops="${3-0}"
  local path
  path="$(hangctl_state__path "${vm}")"

  hangctl_state__write_kv_all "${path}" "prev_rd_ops=${rd_ops}" "prev_wr_ops=${wr_ops}" || true
}

# ? ê·œ: ?´ì „ ë¸”ë¡ ?µê³„ ê°€?¸ì˜¤ê¸?
hangctl_state_get_prev_blockstats() {
  # usage: hangctl_state_get_prev_blockstats <vm> <out_rd_var> <out_wr_var>
  local vm="${1-}"
  local -n _rd="${2}"
  local -n _wr="${3}"
  local path
  path="$(hangctl_state__path "${vm}")"

  _rd="$(hangctl_state__read_kv "${path}" "prev_rd_ops" || echo "0")"
  _wr="$(hangctl_state__read_kv "${path}" "prev_wr_ops" || echo "0")"
}
