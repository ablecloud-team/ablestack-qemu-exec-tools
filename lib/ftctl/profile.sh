#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

FTCTL_PROFILE_NAME=""
FTCTL_PROFILE_MODE=""
FTCTL_PROFILE_PRIMARY_URI=""
FTCTL_PROFILE_SECONDARY_URI=""
FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC=""
FTCTL_PROFILE_AUTO_REARM=""
FTCTL_PROFILE_FENCING_POLICY=""

ftctl_profile_reset() {
  FTCTL_PROFILE_NAME="default"
  FTCTL_PROFILE_MODE=""
  FTCTL_PROFILE_PRIMARY_URI="${FTCTL_DEFAULT_PRIMARY_URI}"
  FTCTL_PROFILE_SECONDARY_URI="${FTCTL_DEFAULT_PEER_URI}"
  FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="${FTCTL_TRANSIENT_NET_GRACE_SEC}"
  FTCTL_PROFILE_AUTO_REARM="1"
  FTCTL_PROFILE_FENCING_POLICY="manual-block"
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
    FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="${FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC:-${FTCTL_TRANSIENT_NET_GRACE_SEC}}"
    FTCTL_PROFILE_AUTO_REARM="${FTCTL_PROFILE_AUTO_REARM:-1}"
    FTCTL_PROFILE_FENCING_POLICY="${FTCTL_PROFILE_FENCING_POLICY:-manual-block}"
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
