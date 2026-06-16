#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${ROOT_DIR}/lib/hangctl/state_cache.sh"
source "${ROOT_DIR}/lib/hangctl/detect.sh"

HANGCTL_STATE_DIR="$(mktemp -d)"
HANGCTL_MIGRATION_PROGRESS_CHECK_SEC=300
HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC=3600
trap 'rm -rf "${HANGCTL_STATE_DIR}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local got="${1-}"
  local want="${2-}"
  local msg="${3-}"
  [[ "${got}" == "${want}" ]] || fail "${msg}: got=${got} want=${want}"
}

assert_contains() {
  local haystack="${1-}"
  local needle="${2-}"
  local msg="${3-}"
  [[ "${haystack}" == *"${needle}"* ]] || fail "${msg}: missing ${needle} in ${haystack}"
}

migration_job() {
  local data="${1-200.000 MiB}"
  cat <<EOF
Job type:         Unbounded
Operation:        Migration Out
Data processed:   ${data}
Memory processed: ${data}
Memory remaining: 10.000 MiB
EOF
}

backup_job() {
  cat <<'EOF'
Job type:         Bounded
Operation:        Backup
Data processed:   100.000 MiB
EOF
}

unknown_progress_migration_job() {
  cat <<'EOF'
Job type:         Unbounded
Operation:        Migration Out
EOF
}

reset_vm_state() {
  local vm="${1-}"
  rm -f "$(hangctl_state__path "${vm}")" "$(hangctl_state__path "${vm}").migrate"
}

test_size_parser() {
  assert_eq "$(hangctl_parse_size_to_bytes 1.5 GiB)" "1610612736" "GiB parser"
  assert_eq "$(hangctl_parse_size_to_bytes 47.235 MiB)" "49529487" "MiB parser"
}

test_classify_domjobinfo_migration_from_operation() {
  local job_type operation is_migration is_backup
  hangctl_classify_domjobinfo "running" "$(migration_job)" job_type operation is_migration is_backup
  assert_eq "${is_migration}" "1" "operation migration classification"
  assert_eq "${is_backup}" "0" "migration must not be backup"
  assert_eq "${job_type}" "Unbounded" "job type"
  assert_eq "${operation}" "Migration Out" "operation"
}

test_classify_domjobinfo_backup() {
  local job_type operation is_migration is_backup
  hangctl_classify_domjobinfo "running" "$(backup_job)" job_type operation is_migration is_backup
  assert_eq "${is_migration}" "0" "backup must not be migration"
  assert_eq "${is_backup}" "1" "backup classification"
}

test_progress_increase_is_protected() {
  local vm="hangctl-progressing" status detail now
  reset_vm_state "${vm}"
  now="$(date +%s)"
  hangctl_state_set_migration_kv_all "${vm}" \
    "migration_metric_bytes=104857600" \
    "migration_metric_kind=data_processed" \
    "migration_last_progress_ts=$((now - 100))"
  hangctl_probe_migration_progress_evaluate "${vm}" "$(migration_job '200.000 MiB')" 4000 status detail
  assert_eq "${status}" "progressing" "progressing status"
  assert_contains "${detail}" "delta_bytes=104857600" "progressing detail"
}

test_unknown_progress_is_protected() {
  local vm="hangctl-unknown" status detail
  reset_vm_state "${vm}"
  hangctl_probe_migration_progress_evaluate "${vm}" "$(unknown_progress_migration_job)" 4000 status detail
  assert_eq "${status}" "protect_unknown_progress" "unknown progress status"
}

test_no_progress_before_progress_window_is_protected() {
  local vm="hangctl-before-progress-window" status detail now
  reset_vm_state "${vm}"
  now="$(date +%s)"
  hangctl_state_set_migration_kv_all "${vm}" \
    "migration_metric_bytes=209715200" \
    "migration_metric_kind=data_processed" \
    "migration_last_progress_ts=$((now - 250))"
  hangctl_probe_migration_progress_evaluate "${vm}" "$(migration_job '200.000 MiB')" 4000 status detail
  assert_eq "${status}" "no_progress_within_grace" "no progress before progress window"
}

test_no_progress_before_confirm_window_is_protected() {
  local vm="hangctl-before-confirm-window" status detail now
  reset_vm_state "${vm}"
  now="$(date +%s)"
  hangctl_state_set_migration_kv_all "${vm}" \
    "migration_metric_bytes=209715200" \
    "migration_metric_kind=data_processed" \
    "migration_last_progress_ts=$((now - 301))"
  hangctl_probe_migration_progress_evaluate "${vm}" "$(migration_job '200.000 MiB')" 1000 status detail
  assert_eq "${status}" "no_progress_within_grace" "no progress before confirm window"
}

test_no_progress_after_both_windows_is_zombie() {
  local vm="hangctl-zombie" status detail now
  reset_vm_state "${vm}"
  now="$(date +%s)"
  hangctl_state_set_migration_kv_all "${vm}" \
    "migration_metric_bytes=209715200" \
    "migration_metric_kind=data_processed" \
    "migration_last_progress_ts=$((now - 301))"
  hangctl_probe_migration_progress_evaluate "${vm}" "$(migration_job '200.000 MiB')" 3600 status detail
  assert_eq "${status}" "zombie_no_progress" "zombie status"
}

test_memory_remaining_change_is_progress() {
  local vm="hangctl-remaining" status detail now job
  reset_vm_state "${vm}"
  now="$(date +%s)"
  hangctl_state_set_migration_kv_all "${vm}" \
    "migration_metric_bytes=104857600" \
    "migration_metric_kind=memory_remaining" \
    "migration_last_progress_ts=$((now - 301))"
  job=$'Job type:         Unbounded\nOperation:        Migration Out\nMemory remaining: 90.000 MiB\n'
  hangctl_probe_migration_progress_evaluate "${vm}" "${job}" 4000 status detail
  assert_eq "${status}" "progressing" "memory remaining changed"
}

test_size_parser
test_classify_domjobinfo_migration_from_operation
test_classify_domjobinfo_backup
test_progress_increase_is_protected
test_unknown_progress_is_protected
test_no_progress_before_progress_window_is_protected
test_no_progress_before_confirm_window_is_protected
test_no_progress_after_both_windows_is_zombie
test_memory_remaining_change_is_progress

echo "hangctl migration protection smoke: ok"
