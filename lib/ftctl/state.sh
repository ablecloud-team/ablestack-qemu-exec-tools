#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_state_vm_key() {
  local vm="${1-}"
  echo "${vm//[^a-zA-Z0-9_.-]/_}"
}

ftctl_state_path() {
  local vm="${1-}"
  echo "${FTCTL_STATE_DIR}/$(ftctl_state_vm_key "${vm}").state"
}

ftctl_state_read_kv() {
  local path="${1-}"
  local key="${2-}"
  [[ -f "${path}" ]] || return 1
  awk -F= -v k="${key}" '$1==k {sub(/^[^=]+=/,""); print; found=1; exit} END{if (!found) exit 1}' "${path}"
}

ftctl_state_write_kv_all() {
  local path="${1-}"
  shift
  local tmp
  tmp="$(mktemp -t ftctl.state.XXXXXX)"
  while (($#)); do
    printf "%s\n" "$1" >> "${tmp}"
    shift
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_state_exists() {
  local vm="${1-}"
  [[ -f "$(ftctl_state_path "${vm}")" ]]
}

ftctl_state_init_vm() {
  local vm="${1-}"
  local path
  path="$(ftctl_state_path "${vm}")"
  ftctl_state_write_kv_all "${path}" \
    "vm=${vm}" \
    "mode=${FTCTL_PROFILE_MODE}" \
    "profile=${FTCTL_PROFILE_NAME}" \
    "primary_uri=${FTCTL_PROFILE_PRIMARY_URI}" \
    "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}" \
    "active_side=primary" \
    "protection_state=pairing" \
    "transport_state=initializing" \
    "fencing_state=clear" \
    "admin_state=active" \
    "rearm_count=0" \
    "failover_count=0" \
    "last_healthy_ts=$(ftctl_now_iso8601)" \
    "last_sync_ts=" \
    "last_rearm_ts=" \
    "transport_loss_since=" \
    "last_reconcile_ts=" \
    "last_error="
}

ftctl_state_set() {
  local vm="${1-}"
  local path tmp key value
  shift
  path="$(ftctl_state_path "${vm}")"
  [[ -f "${path}" ]] || ftctl_state_init_vm "${vm}"
  tmp="$(mktemp -t ftctl.state.set.XXXXXX)"
  cp -f "${path}" "${tmp}"
  while (($#)); do
    key="${1%%=*}"
    value="${1#*=}"
    if grep -q "^${key}=" "${tmp}"; then
      sed -i "s#^${key}=.*#${key}=${value}#" "${tmp}"
    else
      printf "%s=%s\n" "${key}" "${value}" >> "${tmp}"
    fi
    shift
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_state_get() {
  local vm="${1-}"
  local key="${2-}"
  ftctl_state_read_kv "$(ftctl_state_path "${vm}")" "${key}"
}

ftctl_state_increment() {
  local vm="${1-}"
  local key="${2-}"
  local cur
  cur="$(ftctl_state_get "${vm}" "${key}" 2>/dev/null || echo "0")"
  [[ "${cur}" =~ ^[0-9]+$ ]] || cur="0"
  cur=$((cur + 1))
  ftctl_state_set "${vm}" "${key}=${cur}"
  echo "${cur}"
}

ftctl_state_pause_vm() {
  local vm="${1-}"
  ftctl_state_set "${vm}" "admin_state=paused"
  ftctl_log_event "state" "protection.pause" "ok" "${vm}" "" "admin_state=paused"
}

ftctl_state_resume_vm() {
  local vm="${1-}"
  ftctl_state_set "${vm}" "admin_state=active"
  ftctl_log_event "state" "protection.resume" "ok" "${vm}" "" "admin_state=active"
}

ftctl_state_get_elapsed_key_sec() {
  local vm="${1-}"
  local key="${2-}"
  local value
  value="$(ftctl_state_get "${vm}" "${key}" 2>/dev/null || true)"
  [[ -n "${value}" ]] || return 1
  ftctl_elapsed_since_iso "${value}"
}

ftctl_state_emit_json() {
  local vm="${1-}"
  local path line first="1"
  path="$(ftctl_state_path "${vm}")"
  printf "{"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if [[ "${first}" == "1" ]]; then
      first="0"
    else
      printf ","
    fi
    printf '"%s":"%s"' "${line%%=*}" "${line#*=}"
  done < "${path}"
  printf "}\n"
}

ftctl_state_print_one() {
  local vm="${1-}"
  local json="${2-0}"
  local path
  path="$(ftctl_state_path "${vm}")"
  [[ -f "${path}" ]] || {
    if [[ "${json}" == "1" ]]; then
      printf '{"vm":"%s","result":"not_found"}\n' "${vm}"
    else
      printf '%s: state not found\n' "${vm}"
    fi
    return 1
  }
  if [[ "${json}" == "1" ]]; then
    ftctl_state_emit_json "${vm}"
  else
    printf '%s mode=%s state=%s transport=%s active=%s admin=%s rearm_count=%s failover_count=%s\n' \
      "${vm}" \
      "$(ftctl_state_get "${vm}" "mode" || true)" \
      "$(ftctl_state_get "${vm}" "protection_state" || true)" \
      "$(ftctl_state_get "${vm}" "transport_state" || true)" \
      "$(ftctl_state_get "${vm}" "active_side" || true)" \
      "$(ftctl_state_get "${vm}" "admin_state" || true)" \
      "$(ftctl_state_get "${vm}" "rearm_count" || true)" \
      "$(ftctl_state_get "${vm}" "failover_count" || true)"
  fi
}

ftctl_state_print_status() {
  local vm="${1-}"
  local json="${2-0}"
  local f name
  if [[ -n "${vm}" ]]; then
    ftctl_state_print_one "${vm}" "${json}"
    return $?
  fi
  shopt -s nullglob
  for f in "${FTCTL_STATE_DIR}"/*.state; do
    name="$(basename "${f}" .state)"
    if [[ "${json}" == "1" ]]; then
      ftctl_state_emit_json "${name}"
    else
      ftctl_state_print_one "${name}" "0"
    fi
  done
  shopt -u nullglob
}
