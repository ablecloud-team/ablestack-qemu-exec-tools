#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
source "${ROOT_DIR}/lib/hangctl/config.sh"
source "${ROOT_DIR}/lib/hangctl/state_cache.sh"
source "${ROOT_DIR}/lib/hangctl/detect.sh"
source "${ROOT_DIR}/lib/hangctl/actions.sh"
source "${ROOT_DIR}/lib/hangctl/libvirt_wrap.sh"
# Load the real detector without executing the CLI or loading host libraries.
source <(sed -n '/^hangctl_detect_probe_maybe_act_one_vm() {/,/^cmd_scan() {/p' "${ROOT_DIR}/bin/ablestack_vm_hangctl.sh" | sed '$d')
hangctl_config_init_defaults
HANGCTL_OPERATION_ROOT="${TMP_DIR}/operations"
HANGCTL_STATE_DIR="${TMP_DIR}/state"
mkdir -p "${HANGCTL_STATE_DIR}"
HANGCTL_KILL_GRACE_SEC=0
LOG="${TMP_DIR}/log"
CALLS="${TMP_DIR}/calls"
hangctl_log_event() { printf '%s %s %s %s\n' "$2" "$3" "$4" "${7-}" >> "${LOG}"; }
hangctl_new_incident_id() { echo test-incident; }
hangctl_ftctl_guard_should_skip_action() { [[ "${FTCTL}" == 1 ]]; }
hangctl_qemu_identity() { [[ "${IDENTITY_FAIL}" == 0 ]] || return 1; echo "${IDENTITY}"; }
hangctl_storage_guard_vm_volumes() { echo storage >> "${CALLS}"; }
hangctl_collect_evidence_pre_action() {
  echo evidence >> "${CALLS}"
  [[ "${RACE}" != before_dump ]] || DOM='paused (saving)'
}
hangctl_collect_dump_pre_action() {
  echo dump >> "${CALLS}"
  [[ "${RACE}" != before_destroy ]] || DOM='paused (snapshot)'
}
hangctl_probe_qmp_query_status() { printf -v "$2" '%s' "${QMP}"; printf -v "$3" '%s' "${QMP_RC}"; }
hangctl_virsh() {
  local -n mock_out="$2" mock_err="$3" mock_rc="$4"
  mock_out=''; mock_err=''; mock_rc=0
  case "$*" in
    *domuuid*) mock_out="11111111-1111-1111-1111-111111111111" ;;
    *domjobinfo*) mock_out="${JOB}"; mock_rc="${JOB_RC}" ;;
    *domstate*) mock_out="${DOM}"; mock_rc="${DOM_RC}" ;;
    *destroy*)
      echo destroy >> "${CALLS}"; mock_rc="${DESTROY_RC}"
      case "${RACE}" in
        before_term) DOM='paused (saving)' ;;
        pid_changed) IDENTITY='uuid:9999:2' ;;
        recovered) DOM='running (booted)'; QMP=running; QMP_RC=0 ;;
      esac ;;
    *) echo "unexpected virsh: $*" >&2; exit 1 ;;
  esac
  return "${mock_rc}"
}
kill() {
  case "$1" in
    -0) return 0 ;;
    -TERM)
      echo TERM >> "${CALLS}"
      [[ "${RACE}" != before_kill ]] || DOM='paused (saving)'
      [[ "${RACE}" != pid_after_term ]] || IDENTITY='uuid:1234:2'
      [[ "${RACE}" != ftctl_after_term ]] || FTCTL=1 ;;
    -KILL) echo KILL >> "${CALLS}" ;;
    *) exit 1 ;;
  esac
}
# libvirt writes PID files without a newline on the deployed hosts.
printf 1234 > "${TMP_DIR}/pid"
[[ "$(hangctl_read_pidfile "${TMP_DIR}/pid")" == 1234 ]]
printf '1234\n' > "${TMP_DIR}/pid"
[[ "$(hangctl_read_pidfile "${TMP_DIR}/pid")" == 1234 ]]
printf '1234\n9999' > "${TMP_DIR}/pid"
if hangctl_read_pidfile "${TMP_DIR}/pid"; then exit 1; fi
printf 0 > "${TMP_DIR}/pid"
if hangctl_read_pidfile "${TMP_DIR}/pid"; then exit 1; fi

reset_case() {
  DOM='paused (user)'; DOM_RC=0; JOB='Job type: None'; JOB_RC=0
  QMP=''; QMP_RC=143; FTCTL=0; IDENTITY='uuid:1234:1'; IDENTITY_FAIL=0
  DESTROY_RC=143; RACE=''; HANGCTL_DRY_RUN=0
  : > "${LOG}"; : > "${CALLS}"
  hangctl_state_reset_vm test-vm
}
fail() { echo "FAIL: $*" >&2; cat "${LOG}" "${CALLS}" >&2; exit 1; }
assert_absent() { ! grep -Eq "$1" "${CALLS}" || fail "unexpected $1"; }
assert_present() { grep -Eq "$1" "${CALLS}" || fail "missing $1"; }
seed_suspect() {
  hangctl_state__write_kv_all "$(hangctl_state__path test-vm)" operation_state=NONE "first_suspect_ts=$(($(date +%s)-4000))"
}
run_detector() { hangctl_detect_probe_maybe_act_one_vm test-vm 1; }
run_action() { hangctl_action_handle_confirmed_vm test-vm stuck_in_paused_state paused 4000 ''; }

for reason in saving snapshot restoring dump migration in-migration post-copy 'post-copy failed'; do
  for rc in 0 1 124 137 143; do
    reset_case; seed_suspect; DOM="paused (${reason})"; JOB_RC="${rc}"
    [[ "${rc}" == 0 ]] || JOB=''
    run_detector; assert_absent 'storage|evidence|dump|destroy|TERM|KILL'
    grep -q 'vm.operation_guard.*defer_ACTIVE' "${LOG}" || fail "unprotected ${reason}/${rc}"
    run_action; assert_absent 'storage|evidence|dump|destroy|TERM|KILL'
  done
done
for rc in 0 1 124 137 143; do
  reset_case; seed_suspect; JOB=''; JOB_RC="${rc}"
  run_detector; assert_absent 'dump|destroy|TERM|KILL'
  grep -q 'defer_UNKNOWN' "${LOG}" || fail "unknown job ${rc}"
done
for job in 'Job type: nonsense' 'Job type: Completed' $'Job type: Bounded\nOperation: Backup' $'Job type: Unbounded\nOperation: Migration Out' $'Job type: None\nOperation: Snapshot'; do
  reset_case; seed_suspect; JOB="${job}"
  run_detector; assert_absent 'dump|destroy|TERM|KILL'
done
reset_case; seed_suspect; DOM_RC=143; run_detector; assert_absent 'dump|destroy|TERM|KILL'
reset_case; seed_suspect; DOM='running (from snapshot)'; QMP=running; QMP_RC=0
run_detector; assert_absent 'dump|destroy|TERM|KILL'
grep -q 'vm.heartbeat' "${LOG}" || fail 'historical snapshot treated as active'

# No pre-operation age (including old on-disk cache) is inherited after protection.
reset_case; seed_suspect; DOM='paused (saving)'; run_detector
DOM='paused (user)'; run_detector; assert_absent 'dump|destroy|TERM|KILL'
[[ "$(hangctl_state_suspect_duration test-vm)" -lt 5 ]] || fail 'timer not reset'
reset_case
hangctl_state__write_kv_all "$(hangctl_state__path test-vm)" last_change_ts=1
run_detector; assert_absent 'dump|destroy|TERM|KILL'
reset_case; seed_suspect; QMP=running; QMP_RC=0; DOM='running (booted)'
run_detector; DOM='paused (user)'; run_detector; assert_absent 'dump|destroy|TERM|KILL'

# Persistent unknown status escalates a warning, never an action.
reset_case; JOB=''; run_detector
hangctl_state__write_kv_all "$(hangctl_state__path test-vm)" "operation_started_ts=$(($(date +%s)-4000))"
run_detector; assert_absent 'dump|destroy|TERM|KILL'
grep -q 'vm.operation_guard warn.*attention_required=1' "${LOG}" || fail 'missing unknown warning'

# Dry run cannot collect a potentially destructive crash-mode dump.
reset_case; HANGCTL_DRY_RUN=1; run_action; assert_absent 'storage|dump|destroy|TERM|KILL'
reset_case; FTCTL=1; run_action; assert_absent 'storage|dump|destroy|TERM|KILL'
reset_case; IDENTITY_FAIL=1; run_action; assert_absent 'storage|dump|destroy|TERM|KILL'

for race in before_dump before_destroy before_term pid_changed recovered before_kill pid_after_term ftctl_after_term; do
  reset_case; RACE="${race}"; DESTROY_RC=1
  run_action
  case "${race}" in
    before_dump) assert_absent 'dump|destroy|TERM|KILL' ;;
    before_destroy) assert_present '^dump$'; assert_absent 'destroy|TERM|KILL' ;;
    before_term|pid_changed|recovered) assert_present '^destroy$'; assert_absent 'TERM|KILL' ;;
    *) assert_present '^TERM$'; assert_absent KILL ;;
  esac
done
for rc in 124 137 143; do
  reset_case; seed_suspect; DESTROY_RC="${rc}"; run_detector
  assert_present '^destroy$'; assert_absent 'TERM|KILL'
  grep -q 'reason=destroy_timeout' "${LOG}" || fail 'destroy timeout not deferred'
done
# A positively observed ordinary paused hang can still reach an action.
reset_case; seed_suspect; DESTROY_RC=1
run_detector; assert_present '^dump$'; assert_present '^destroy$'; assert_present '^TERM$'; assert_present '^KILL$'
# Failed observation cannot be reported as successfully stopped.
reset_case; DOM_RC=143
if hangctl_verify_vm_stopped test-vm test-incident; then fail 'unknown reported stopped'; fi
printf 'hangctl snapshot protection and action gate smoke: ok\n'
