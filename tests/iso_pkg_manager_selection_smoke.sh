#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="${ROOT_DIR}/.github/workflows/build.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

extract_generated_script() {
  local target="$1"
  local output="$2"
  awk -v target="${target}" '
    index($0, "cat <<'\''EOF'\'' > " target) { capture = 1; next }
    capture && $0 == "          EOF" { exit }
    capture {
      sub(/^          /, "")
      print
    }
  ' "${WORKFLOW}" > "${output}"
}

extract_function_prefix() {
  local script="$1"
  local output="$2"
  awk '
    /^case .*DISTRO.* in/ { exit }
    { print }
  ' "${script}" > "${output}"
}

write_fake_cmd() {
  local path="$1"
  local body="$2"
  printf '#!/usr/bin/env bash\n%s\n' "${body}" > "${path}"
  chmod +x "${path}"
}

assert_selection() {
  local prefix="$1"
  local pretty_name="$2"
  local expected_manager="$3"
  local expected_query="$4"

  (
    # shellcheck disable=SC1090
    source "${prefix}" >/dev/null
    PRETTY_NAME="${pretty_name}"

    manager_cmd="$(rpm_pkg_manager_cmd)"
    query_cmd="$(rpm_query_cmd)"

    [[ "$(basename "${manager_cmd}")" == "${expected_manager}" ]] || {
      echo "expected package manager ${expected_manager}, got ${manager_cmd}" >&2
      exit 1
    }
    [[ "$(basename "${query_cmd}")" == "${expected_query}" ]] || {
      echo "expected query command ${expected_query}, got ${query_cmd}" >&2
      exit 1
    }
  )
}

mkdir -p "${TMP_DIR}/bin"
write_fake_cmd "${TMP_DIR}/bin/dnf" 'echo "dnf, yum usage is blocked" >&2; exit 64'
write_fake_cmd "${TMP_DIR}/bin/rpm" 'echo "rpm usage is blocked" >&2; exit 64'
write_fake_cmd "${TMP_DIR}/bin/aspm" 'exit 0'
write_fake_cmd "${TMP_DIR}/bin/aspkg" 'exit 0'

extract_generated_script "release/install-linux.sh" "${TMP_DIR}/install-linux.sh"
extract_generated_script "release/uninstall-linux.sh" "${TMP_DIR}/uninstall-linux.sh"
bash -n "${TMP_DIR}/install-linux.sh"
bash -n "${TMP_DIR}/uninstall-linux.sh"
extract_function_prefix "${TMP_DIR}/install-linux.sh" "${TMP_DIR}/install-prefix.sh"
extract_function_prefix "${TMP_DIR}/uninstall-linux.sh" "${TMP_DIR}/uninstall-prefix.sh"

PATH="${TMP_DIR}/bin:${PATH}"
export PATH

assert_selection "${TMP_DIR}/install-prefix.sh" "ABLESTACK Host 9" aspm aspkg
assert_selection "${TMP_DIR}/uninstall-prefix.sh" "ABLESTACK Host 9" aspm aspkg
assert_selection "${TMP_DIR}/install-prefix.sh" "Rocky Linux 9.6" dnf rpm
assert_selection "${TMP_DIR}/uninstall-prefix.sh" "Rocky Linux 9.6" dnf rpm

echo "[OK] ISO package manager selection smoke test passed"
