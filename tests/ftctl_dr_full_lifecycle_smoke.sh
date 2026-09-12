#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFTEST="${ROOT_DIR}/bin/ablestack_vm_ftctl_selftest.sh"

mapfile -t lifecycle_cases < <(
  sed -n 's/^\(selftest_case_dr_[A-Za-z0-9_]*\)().*/\1/p' "${SELFTEST}"
)

required_cases=(
  selftest_case_dr_runtime_profile_status_cancel
  selftest_case_dr_runtime_control_actions
  selftest_case_dr_plan_scoped_control_protocol
  selftest_case_dr_ablestack_full_seed_once
  selftest_case_dr_scheduler_ablestack_checkpoint_loop
  selftest_case_dr_scheduler_vmware_mock_checkpoint_loop
  selftest_case_dr_runtime_test_failover_cleanup
  selftest_case_dr_runtime_cloud_managed_test_cleanup
  selftest_case_dr_runtime_planned_failover_promotes_latest_checkpoint
  selftest_case_dr_runtime_failback_restores_source_after_reverse_checkpoint
  selftest_case_dr_runtime_reprotect_starts_reverse_protection_checkpoint
  selftest_case_dr_kvm_vmware_reverse_preflight_ignores_domain_runtime
)

for required in "${required_cases[@]}"; do
  if ! printf '%s\n' "${lifecycle_cases[@]}" | grep -Fxq "${required}"; then
    printf 'ERROR: required DR lifecycle case is missing: %s\n' "${required}" >&2
    exit 1
  fi
done

if (( ${#lifecycle_cases[@]} < ${#required_cases[@]} )); then
  printf 'ERROR: no complete DR lifecycle self-test set was discovered\n' >&2
  exit 1
fi

cases_csv="$(IFS=,; printf '%s' "${lifecycle_cases[*]}")"
FTCTL_SELFTEST_CASES="${cases_csv}" bash "${SELFTEST}"
printf 'ftctl DR full lifecycle smoke: PASS (%s cases)\n' "${#lifecycle_cases[@]}"
