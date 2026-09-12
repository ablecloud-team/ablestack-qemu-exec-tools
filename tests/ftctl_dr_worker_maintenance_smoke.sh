#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
source "${ROOT}/lib/ftctl/dr_scheduler.sh"
ftctl_dr_runtime_profile_path() { echo "${TMP}/profile"; }
ftctl_dr_runtime_status_path() { echo "${TMP}/status"; }
ftctl_dr_runtime_run_path() { echo "${TMP}/run"; }
ftctl_dr_runtime_remote_source_transition() { return 1; }
ftctl_dr_scheduler_active_worker_valid() { return 1; }
ftctl_dr_scheduler_control_command() { echo "${control}"; }
ftctl_dr_runtime_state_get_from_path() {
 awk -F= -v k="$2" '$1==k {v=substr($0,index($0,"=")+1)} END {print v}' "$1"
}
ftctl_dr_runtime_path_set() { local file="$1"; shift; printf '%s\n' "$@" >> "$file"; }
ftctl_dr_scheduler_recover() { echo recovered >> "${TMP}/calls"; }
reset_case() {
 control=run
 : > "${TMP}/profile"; : > "${TMP}/run"; : > "${TMP}/calls"
 cat > "${TMP}/status" <<EOF
state=ERROR
retryable=true
error_code=DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE
active_side=SOURCE
control_state=RUNNING
scheduler_desired_state=RUNNING
transition_state=IDLE
run=run1
EOF
}
reset_case
ftctl_dr_scheduler_reconcile_plan plan1
[[ $(wc -l < "${TMP}/calls") == 1 ]]
ftctl_dr_scheduler_reconcile_plan plan1
[[ $(wc -l < "${TMP}/calls") == 1 ]] # durable backoff
printf 'local_recovery_next_retry_epoch=1\n' >> "${TMP}/status"
ftctl_dr_scheduler_reconcile_plan plan1
[[ $(wc -l < "${TMP}/calls") == 2 ]]
for override in 'control_state=PAUSED' 'active_side=TARGET' 'scheduler_desired_state=STOPPED' 'transition_state=PREPARING' 'retryable=false' 'error_code=DR_DATA_CORRUPT'; do
 reset_case
 echo "$override" >> "${TMP}/status"
 ftctl_dr_scheduler_reconcile_plan plan1
 [[ ! -s "${TMP}/calls" ]] || { echo "unexpected recovery: $override"; exit 1; }
done
reset_case; control=stop
ftctl_dr_scheduler_reconcile_plan plan1
[[ ! -s "${TMP}/calls" ]]
reset_case
printf 'error_code=DR_QCOW2_OFFLINE_SOURCE_BUSY\n' >> "${TMP}/status"
ftctl_dr_scheduler_reconcile_plan plan1
[[ $(wc -l < "${TMP}/calls") == 1 ]]
echo 'worker maintenance reconcile: PASS (retry, backoff, pause, stop, authority, transition, fatal error)'