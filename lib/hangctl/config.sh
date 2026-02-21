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

# Commit 02 scope:
# - Define defaults
# - Load /etc/ablestack/ablestack-vm-hangctl.conf (or --config)
# - Ensure runtime dirs

HANGCTL_DEFAULT_CONFIG="/etc/ablestack/ablestack-vm-hangctl.conf"

HANGCTL_POLICY_DEFAULT="default"
HANGCTL_DRY_RUN_DEFAULT="0"

HANGCTL_VIRSH_TIMEOUT_SEC_DEFAULT="3"
HANGCTL_QMP_TIMEOUT_SEC_DEFAULT="5"
HANGCTL_QGA_TIMEOUT_SEC_DEFAULT="5"
HANGCTL_CONFIRM_WINDOW_SEC_DEFAULT="120"
HANGCTL_PAUSED_CONFIRM_WINDOW_SEC_DEFAULT="300"
HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC_DEFAULT="1800"
HANGCTL_MIGRATION_PROGRESS_CHECK_SEC_DEFAULT="300"
HANGCTL_VERIFY_TIMEOUT_SEC_DEFAULT="3"
HANGCTL_KILL_GRACE_SEC_DEFAULT="2"

HANGCTL_LOG_MAX_SIZE_MB_DEFAULT="100"
HANGCTL_LOG_ROTATE_COUNT_DEFAULT="5"

HANGCTL_RUN_DIR_DEFAULT="/run/ablestack-vm-hangctl"
HANGCTL_LOG_DIR_DEFAULT="/var/log/ablestack-vm-hangctl"
HANGCTL_EVENTS_LOG_DEFAULT="/var/log/ablestack-vm-hangctl/events.log"
HANGCTL_LOCK_FILE_DEFAULT="/run/ablestack-vm-hangctl/lock"
HANGCTL_STATE_DIR_DEFAULT="/run/ablestack-vm-hangctl/state"

# Commit 09: evidence (pre-action snapshot)
HANGCTL_EVIDENCE_DIR_DEFAULT="/var/log/ablestack-vm-hangctl/evidence"
HANGCTL_EVIDENCE_ENABLE_DEFAULT="1"
HANGCTL_EVIDENCE_DUMPXML_DEFAULT="1"
HANGCTL_EVIDENCE_JOURNAL_SEC_DEFAULT="180"
HANGCTL_EVIDENCE_TIMEOUT_SEC_DEFAULT="3"

# Commit 09: memory dump
HANGCTL_DUMP_ENABLE_DEFAULT="1"
HANGCTL_DUMP_DIR_DEFAULT="/var/lib/libvirt/dump"
HANGCTL_DUMP_TIMEOUT_SEC_DEFAULT="60"
HANGCTL_DUMP_MIN_FREE_GB_DEFAULT="10"
HANGCTL_DUMP_MAX_PER_SCAN_DEFAULT="1"
HANGCTL_DUMP_SHA256_DEFAULT="1"

# Commit 08.1: optional target filters
HANGCTL_TARGET_VM_DEFAULT=""
HANGCTL_INCLUDE_REGEX_DEFAULT=""

# Commit 10: libvirtd recovery (circuit breaker)
# trigger: consecutive failures (default: 2)
HANGCTL_LIBVIRTD_SERVICE="libvirtd.service"
HANGCTL_LIBVIRTD_FAIL_THRESHOLD="2"
HANGCTL_LIBVIRTD_RESTART_ENABLED="1"
HANGCTL_LIBVIRTD_RESTART_COOLDOWN_SEC="180"
HANGCTL_LIBVIRTD_RESTART_TIMEOUT_SEC="60"
HANGCTL_LIBVIRTD_POST_RESTART_WAIT_SEC="15"
HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC="3"

hangctl_config_init_defaults() {
  # Effective config variables
  HANGCTL_CONFIG_PATH="${HANGCTL_DEFAULT_CONFIG}"

  HANGCTL_POLICY="${HANGCTL_POLICY_DEFAULT}"
  HANGCTL_DRY_RUN="${HANGCTL_DRY_RUN_DEFAULT}"

  HANGCTL_VIRSH_TIMEOUT_SEC="${HANGCTL_VIRSH_TIMEOUT_SEC_DEFAULT}"
  HANGCTL_QMP_TIMEOUT_SEC="${HANGCTL_QMP_TIMEOUT_SEC_DEFAULT}"
  HANGCTL_QGA_TIMEOUT_SEC="${HANGCTL_QGA_TIMEOUT_SEC_DEFAULT}"
  HANGCTL_CONFIRM_WINDOW_SEC="${HANGCTL_CONFIRM_WINDOW_SEC_DEFAULT}"
  HANGCTL_PAUSED_CONFIRM_WINDOW_SEC="${HANGCTL_PAUSED_CONFIRM_WINDOW_SEC_DEFAULT}"
  HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC="${HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC_DEFAULT}"
  HANGCTL_MIGRATION_PROGRESS_CHECK_SEC="${HANGCTL_MIGRATION_PROGRESS_CHECK_SEC_DEFAULT}"
  HANGCTL_VERIFY_TIMEOUT_SEC="${HANGCTL_VERIFY_TIMEOUT_SEC_DEFAULT}"
  HANGCTL_KILL_GRACE_SEC="${HANGCTL_KILL_GRACE_SEC_DEFAULT}"

  HANGCTL_LOG_MAX_SIZE_MB="${HANGCTL_LOG_MAX_SIZE_MB_DEFAULT}"
  HANGCTL_LOG_ROTATE_COUNT="${HANGCTL_LOG_ROTATE_COUNT_DEFAULT}"  

  HANGCTL_RUN_DIR="${HANGCTL_RUN_DIR_DEFAULT}"
  HANGCTL_LOG_DIR="${HANGCTL_LOG_DIR_DEFAULT}"
  HANGCTL_EVENTS_LOG="${HANGCTL_EVENTS_LOG_DEFAULT}"
  HANGCTL_LOCK_FILE="${HANGCTL_LOCK_FILE_DEFAULT}"
  HANGCTL_STATE_DIR="${HANGCTL_STATE_DIR_DEFAULT}"

  HANGCTL_TARGET_VM="${HANGCTL_TARGET_VM_DEFAULT}"
  HANGCTL_INCLUDE_REGEX="${HANGCTL_INCLUDE_REGEX_DEFAULT}"
  HANGCTL_EXCLUDE_REGEX=""

  # evidence
  HANGCTL_EVIDENCE_DIR="${HANGCTL_EVIDENCE_DIR_DEFAULT}"
  HANGCTL_EVIDENCE_ENABLE="${HANGCTL_EVIDENCE_ENABLE_DEFAULT}"
  HANGCTL_EVIDENCE_DUMPXML="${HANGCTL_EVIDENCE_DUMPXML_DEFAULT}"
  HANGCTL_EVIDENCE_JOURNAL_SEC="${HANGCTL_EVIDENCE_JOURNAL_SEC_DEFAULT}"
  HANGCTL_EVIDENCE_TIMEOUT_SEC="${HANGCTL_EVIDENCE_TIMEOUT_SEC_DEFAULT}"

  # dump
  HANGCTL_DUMP_ENABLE="${HANGCTL_DUMP_ENABLE_DEFAULT}"
  HANGCTL_DUMP_DIR="${HANGCTL_DUMP_DIR_DEFAULT}"
  HANGCTL_DUMP_TIMEOUT_SEC="${HANGCTL_DUMP_TIMEOUT_SEC_DEFAULT}"
  HANGCTL_DUMP_MIN_FREE_GB="${HANGCTL_DUMP_MIN_FREE_GB_DEFAULT}"
  HANGCTL_DUMP_MAX_PER_SCAN="${HANGCTL_DUMP_MAX_PER_SCAN_DEFAULT}"
  HANGCTL_DUMP_SHA256="${HANGCTL_DUMP_SHA256_DEFAULT}"
}

hangctl_config_apply_cli() {
  # usage: hangctl_config_apply_cli <config_path> <policy> <dry_run>
  local cfg="${1-}"
  local pol="${2-}"
  local dry="${3-}"

  if [[ -n "${cfg}" ]]; then
    HANGCTL_CONFIG_PATH="${cfg}"
  fi
  if [[ -n "${pol}" ]]; then
    HANGCTL_POLICY="${pol}"
  fi
  if [[ -n "${dry}" ]]; then
    HANGCTL_DRY_RUN="${dry}"
  fi
}

hangctl_config_load_file() {
  # usage: hangctl_config_load_file <path>
  local path="${1-}"
  if [[ -z "${path}" ]]; then
    return 0
  fi
  if [[ ! -f "${path}" ]]; then
    # config is optional in early stage; later commits may enforce existence
    return 0
  fi

 # shellcheck disable=SC1090
  set -a
  source "${path}"
  set +a
}

hangctl_ensure_runtime_dirs() {
  # Ensure runtime/log directories exist
  hangctl_ensure_dir "${HANGCTL_RUN_DIR}" "0755"
  hangctl_ensure_dir "${HANGCTL_LOG_DIR}" "0755"
  hangctl_ensure_dir "${HANGCTL_STATE_DIR}" "0755"

  # Ensure log file parent directory exists
  local log_parent
  log_parent="$(dirname "${HANGCTL_EVENTS_LOG}")"
  hangctl_ensure_dir "${log_parent}" "0755"

  # Commit 09: evidence dir
  hangctl_ensure_dir "${HANGCTL_EVIDENCE_DIR}" "0755"

  # Commit 09: dump dir (base only; per-incident subdir created later)
  hangctl_ensure_dir "${HANGCTL_DUMP_DIR}" "0755"
}
