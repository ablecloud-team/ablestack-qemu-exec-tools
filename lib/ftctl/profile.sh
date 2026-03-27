#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

FTCTL_PROFILE_NAME=""
FTCTL_PROFILE_MODE=""
FTCTL_PROFILE_PRIMARY_URI=""
FTCTL_PROFILE_SECONDARY_URI=""
FTCTL_PROFILE_DISK_MAP=""
FTCTL_PROFILE_NETWORK_MAP=""
FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC=""
FTCTL_PROFILE_AUTO_REARM=""
FTCTL_PROFILE_FENCING_POLICY=""
FTCTL_PROFILE_RECOVERY_PRIORITY=""
FTCTL_PROFILE_QGA_POLICY=""
FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT=""
FTCTL_PROFILE_XCOLO_NBD_ENDPOINT=""

ftctl_profile_reset() {
  FTCTL_PROFILE_NAME="default"
  FTCTL_PROFILE_MODE=""
  FTCTL_PROFILE_PRIMARY_URI="${FTCTL_DEFAULT_PRIMARY_URI}"
  FTCTL_PROFILE_SECONDARY_URI="${FTCTL_DEFAULT_PEER_URI}"
  FTCTL_PROFILE_DISK_MAP="auto"
  FTCTL_PROFILE_NETWORK_MAP="inherit"
  FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="${FTCTL_TRANSIENT_NET_GRACE_SEC}"
  FTCTL_PROFILE_AUTO_REARM="1"
  FTCTL_PROFILE_FENCING_POLICY="manual-block"
  FTCTL_PROFILE_RECOVERY_PRIORITY="100"
  FTCTL_PROFILE_QGA_POLICY="optional"
  FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT=""
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT=""
}

ftctl_profile_load_vm() {
  local vm="${1-}"
  local path
  ftctl_profile_reset
  path="${FTCTL_PROFILE_DIR}/${vm}.conf"
  if [[ -f "${path}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${path}"
    set +a
    FTCTL_PROFILE_NAME="${FTCTL_PROFILE_NAME:-default}"
    FTCTL_PROFILE_PRIMARY_URI="${FTCTL_PROFILE_PRIMARY_URI:-${FTCTL_DEFAULT_PRIMARY_URI}}"
    FTCTL_PROFILE_SECONDARY_URI="${FTCTL_PROFILE_SECONDARY_URI:-${FTCTL_DEFAULT_PEER_URI}}"
    FTCTL_PROFILE_DISK_MAP="${FTCTL_PROFILE_DISK_MAP:-auto}"
    FTCTL_PROFILE_NETWORK_MAP="${FTCTL_PROFILE_NETWORK_MAP:-inherit}"
    FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="${FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC:-${FTCTL_TRANSIENT_NET_GRACE_SEC}}"
    FTCTL_PROFILE_AUTO_REARM="${FTCTL_PROFILE_AUTO_REARM:-1}"
    FTCTL_PROFILE_FENCING_POLICY="${FTCTL_PROFILE_FENCING_POLICY:-manual-block}"
    FTCTL_PROFILE_RECOVERY_PRIORITY="${FTCTL_PROFILE_RECOVERY_PRIORITY:-100}"
    FTCTL_PROFILE_QGA_POLICY="${FTCTL_PROFILE_QGA_POLICY:-optional}"
    FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT="${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT:-}"
    FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT:-}"
  fi
}

ftctl_profile_apply_cli() {
  local vm="${1-}"
  local mode="${2-}"
  local peer="${3-}"
  local profile="${4-}"
  [[ -n "${profile}" ]] && FTCTL_PROFILE_NAME="${profile}"
  [[ -n "${mode}" ]] && FTCTL_PROFILE_MODE="${mode}"
  [[ -n "${peer}" ]] && FTCTL_PROFILE_SECONDARY_URI="${peer}"
  [[ -n "${FTCTL_PROFILE_MODE}" ]] || FTCTL_PROFILE_MODE="ha"
  case "${FTCTL_PROFILE_MODE}" in
    ha|dr|ft) ;;
    *)
      echo "ERROR: invalid mode: ${FTCTL_PROFILE_MODE}" >&2
      return 2
      ;;
  esac
  ftctl_log_event "profile" "profile.load" "ok" "${vm}" "" \
    "mode=${FTCTL_PROFILE_MODE} profile=${FTCTL_PROFILE_NAME} peer=${FTCTL_PROFILE_SECONDARY_URI}"
}

ftctl_profile__is_uint() {
  local value="${1-}"
  [[ "${value}" =~ ^[0-9]+$ ]]
}

ftctl_profile__validate_bool() {
  local name="${1-}"
  local value="${2-}"
  case "${value}" in
    0|1) return 0 ;;
    *)
      echo "ERROR: ${name} must be 0 or 1: ${value}" >&2
      return 2
      ;;
  esac
}

ftctl_profile__validate_choice() {
  local name="${1-}"
  local value="${2-}"
  shift 2
  local allowed
  for allowed in "$@"; do
    [[ "${value}" == "${allowed}" ]] && return 0
  done
  echo "ERROR: ${name} has invalid value: ${value}" >&2
  return 2
}

ftctl_profile__validate_nonempty() {
  local name="${1-}"
  local value="${2-}"
  [[ -n "${value}" ]] && return 0
  echo "ERROR: ${name} is required" >&2
  return 2
}

ftctl_profile__validate_disk_map() {
  local value="${1-}"
  local re='^[^=;]+=[^=;]+(;[^=;]+=[^=;]+)*$'
  [[ -n "${value}" ]] || {
    echo "ERROR: FTCTL_PROFILE_DISK_MAP is required" >&2
    return 2
  }
  if [[ "${value}" == "auto" ]]; then
    return 0
  fi
  [[ "${value}" =~ ${re} ]] && return 0
  echo "ERROR: FTCTL_PROFILE_DISK_MAP must be 'auto' or target=path[;target=path...]" >&2
  return 2
}

ftctl_profile__validate_network_map() {
  local value="${1-}"
  local re='^[^=;]+=[^=;]+(;[^=;]+=[^=;]+)*$'
  [[ -n "${value}" ]] || {
    echo "ERROR: FTCTL_PROFILE_NETWORK_MAP is required" >&2
    return 2
  }
  if [[ "${value}" == "inherit" ]]; then
    return 0
  fi
  [[ "${value}" =~ ${re} ]] && return 0
  echo "ERROR: FTCTL_PROFILE_NETWORK_MAP must be 'inherit' or guestnet=hostnet[;guestnet=hostnet...]" >&2
  return 2
}

ftctl_profile_validate() {
  local vm="${1-}"

  ftctl_profile__validate_choice "FTCTL_PROFILE_MODE" "${FTCTL_PROFILE_MODE}" ha dr ft || return 2
  ftctl_profile__validate_nonempty "FTCTL_PROFILE_PRIMARY_URI" "${FTCTL_PROFILE_PRIMARY_URI}" || return 2
  ftctl_profile__validate_nonempty "FTCTL_PROFILE_SECONDARY_URI" "${FTCTL_PROFILE_SECONDARY_URI}" || return 2
  ftctl_profile__validate_disk_map "${FTCTL_PROFILE_DISK_MAP}" || return 2
  ftctl_profile__validate_network_map "${FTCTL_PROFILE_NETWORK_MAP}" || return 2
  ftctl_profile__validate_choice "FTCTL_PROFILE_FENCING_POLICY" "${FTCTL_PROFILE_FENCING_POLICY}" \
    manual-block ssh peer-virsh-destroy ipmi redfish || return 2
  ftctl_profile__validate_choice "FTCTL_PROFILE_QGA_POLICY" "${FTCTL_PROFILE_QGA_POLICY}" \
    optional required off || return 2
  ftctl_profile__validate_bool "FTCTL_PROFILE_AUTO_REARM" "${FTCTL_PROFILE_AUTO_REARM}" || return 2

  ftctl_profile__is_uint "${FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC}" || {
    echo "ERROR: FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC must be an unsigned integer" >&2
    return 2
  }
  ftctl_profile__is_uint "${FTCTL_PROFILE_RECOVERY_PRIORITY}" || {
    echo "ERROR: FTCTL_PROFILE_RECOVERY_PRIORITY must be an unsigned integer" >&2
    return 2
  }

  case "${FTCTL_PROFILE_MODE}" in
    ha|dr)
      if [[ -n "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" || -n "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" ]]; then
        echo "ERROR: FTCTL_PROFILE_XCOLO_* fields are only valid for ft mode" >&2
        return 2
      fi
      ;;
    ft)
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT" "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_XCOLO_NBD_ENDPOINT" "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" || return 2
      ;;
  esac

  ftctl_log_event "profile" "profile.validate" "ok" "${vm}" "" \
    "mode=${FTCTL_PROFILE_MODE} fencing=${FTCTL_PROFILE_FENCING_POLICY} qga=${FTCTL_PROFILE_QGA_POLICY} auto_rearm=${FTCTL_PROFILE_AUTO_REARM}"
}

ftctl_profile_lookup_map_value() {
  local map_value="${1-}"
  local key="${2-}"
  local entry lhs rhs
  [[ -n "${map_value}" && -n "${key}" ]] || return 1
  for entry in ${map_value//;/ }; do
    lhs="${entry%%=*}"
    rhs="${entry#*=}"
    if [[ "${lhs}" == "${key}" && "${rhs}" != "${lhs}" ]]; then
      printf '%s\n' "${rhs}"
      return 0
    fi
  done
  return 1
}
