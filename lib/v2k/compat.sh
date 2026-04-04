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

set -euo pipefail

v2k_compat_repo_root() {
  local script_root fallback
  script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if command -v git >/dev/null 2>&1; then
    if git -C "${script_root}" rev-parse --show-toplevel >/dev/null 2>&1; then
      git -C "${script_root}" rev-parse --show-toplevel
      return 0
    fi
  fi

  fallback="$(cd "${script_root}/../.." && pwd)"
  printf '%s' "${fallback}"
}

v2k_compat_repo_sample_root() {
  printf '%s/share/ablestack/v2k/compat' "$(v2k_compat_repo_root)"
}

v2k_compat_schema_id() {
  printf '%s' "ablestack-v2k/compat-profile-v1"
}

v2k_compat_root_has_profiles() {
  local root="${1:-}"
  [[ -n "${root}" && -d "${root}" ]] || return 1

  local dir
  for dir in "${root}"/*; do
    [[ -d "${dir}" && -f "${dir}/profile.json" ]] || continue
    return 0
  done
  return 1
}

v2k_compat_default_root() {
  local installed_root="/usr/share/ablestack/v2k/compat"
  local repo_root
  repo_root="$(v2k_compat_repo_sample_root)"

  if v2k_compat_root_has_profiles "${installed_root}"; then
    printf '%s' "${installed_root}"
    return 0
  fi
  if v2k_compat_root_has_profiles "${repo_root}"; then
    printf '%s' "${repo_root}"
    return 0
  fi

  printf '%s' "${installed_root}"
}

v2k_compat_root() {
  if [[ -z "${V2K_COMPAT_ROOT:-}" ]]; then
    V2K_COMPAT_ROOT="$(v2k_compat_default_root)"
    export V2K_COMPAT_ROOT
  fi
  printf '%s' "${V2K_COMPAT_ROOT}"
}

v2k_compat_requested_profile() {
  if [[ -n "${V2K_COMPAT_PROFILE:-}" ]]; then
    printf '%s' "${V2K_COMPAT_PROFILE}"
  else
    printf '%s' "auto"
  fi
}

v2k_compat_selected_profile() {
  printf '%s' "${V2K_COMPAT_SELECTED_PROFILE:-}"
}

v2k_compat_profile_dir() {
  local profile="${1:-}"
  [[ -n "${profile}" ]] || return 1
  printf '%s/%s' "$(v2k_compat_root)" "${profile}"
}

v2k_compat_profile_json() {
  local profile="${1:-}"
  [[ -n "${profile}" ]] || return 1
  printf '%s/profile.json' "$(v2k_compat_profile_dir "${profile}")"
}

v2k_compat_profile_exists() {
  local profile="${1:-}"
  [[ -n "${profile}" ]] || return 1
  [[ -f "$(v2k_compat_profile_json "${profile}")" ]]
}

v2k_compat_profile_is_valid() {
  local profile="${1:-}"
  local profile_json schema_id
  profile_json="$(v2k_compat_profile_json "${profile}")" || return 1
  [[ -f "${profile_json}" ]] || return 1
  schema_id="$(v2k_compat_schema_id)"

  PROFILE_JSON="${profile_json}" PROFILE_ID="${profile}" PROFILE_SCHEMA_ID="${schema_id}" v2k_python - <<'PY'
import json
import os
import sys

path = os.environ["PROFILE_JSON"]
profile_id = os.environ["PROFILE_ID"]
schema_id = os.environ["PROFILE_SCHEMA_ID"]

try:
    with open(path, "r", encoding="utf-8") as f:
        obj = json.load(f)
except Exception:
    sys.exit(1)

if obj.get("schema") != schema_id:
    sys.exit(1)
if str(obj.get("id") or "") != profile_id:
    sys.exit(1)
if not str(obj.get("label") or "").strip():
    sys.exit(1)
if not isinstance(obj.get("supported_vcenter"), dict):
    sys.exit(1)
if not isinstance(obj.get("toolchain"), dict):
    sys.exit(1)

sys.exit(0)
PY
}

v2k_compat_profile_tool_path() {
  local profile="${1:-}" field="${2:-}" default_rel="${3:-}"
  local profile_json
  profile_json="$(v2k_compat_profile_json "${profile}")" || return 1
  [[ -f "${profile_json}" ]] || return 1

  local rel
  rel="$(PROFILE_JSON="${profile_json}" PROFILE_FIELD="${field}" PROFILE_DEFAULT_REL="${default_rel}" v2k_python - <<'PY'
import json
import os
import sys

path = os.environ["PROFILE_JSON"]
field = os.environ["PROFILE_FIELD"]
default_rel = os.environ["PROFILE_DEFAULT_REL"]

try:
    with open(path, "r", encoding="utf-8") as f:
        obj = json.load(f)
except Exception:
    sys.exit(1)

toolchain = obj.get("toolchain") or {}
value = toolchain.get(field) or default_rel
if not value:
    sys.exit(1)
print(value)
PY
  )" || true
  [[ -n "${rel}" && "${rel}" != "null" ]] || return 1

  printf '%s/%s' "$(v2k_compat_profile_dir "${profile}")" "${rel}"
}

v2k_compat_list_profiles() {
  local root
  root="$(v2k_compat_root)"
  [[ -d "${root}" ]] || return 0

  local dir
  for dir in "${root}"/*; do
    [[ -d "${dir}" && -f "${dir}/profile.json" ]] || continue
    local profile
    profile="$(basename "${dir}")"
    v2k_compat_profile_is_valid "${profile}" || continue
    basename "${dir}"
  done
}

v2k_compat_version_prefix() {
  local version="${1:-}"
  [[ -n "${version}" ]] || return 1

  if [[ "${version}" =~ ^([0-9]+)\.([0-9]+) ]]; then
    printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

v2k_compat_version_key() {
  local version="${1:-}"
  local prefix major minor
  prefix="$(v2k_compat_version_prefix "${version}")" || return 1
  major="${prefix%%.*}"
  minor="${prefix##*.}"
  printf '%03d%03d' "${major}" "${minor}"
}

v2k_compat_profile_supports_version() {
  local profile="${1:-}" version="${2:-}"
  local profile_json version_prefix version_key
  profile_json="$(v2k_compat_profile_json "${profile}")" || return 1
  [[ -f "${profile_json}" ]] || return 1
  version_prefix="$(v2k_compat_version_prefix "${version}")" || return 1
  version_key="$(v2k_compat_version_key "${version}")" || return 1

  PROFILE_JSON="${profile_json}" VERSION_PREFIX="${version_prefix}" VERSION_KEY="${version_key}" v2k_python - <<'PY'
import json
import os
import sys

path = os.environ["PROFILE_JSON"]
version_prefix = os.environ["VERSION_PREFIX"]
version_key = int(os.environ["VERSION_KEY"])

def version_to_key(raw: str):
    if not raw:
        return None
    parts = raw.split(".")
    if len(parts) < 2:
        return None
    try:
        major = int(parts[0])
        minor = int(parts[1])
    except ValueError:
        return None
    return int(f"{major:03d}{minor:03d}")

with open(path, "r", encoding="utf-8") as f:
    obj = json.load(f)

supported = obj.get("supported_vcenter") or {}
versions = supported.get("versions") or []
for item in versions:
    item = str(item)
    if version_prefix == item or version_prefix.startswith(item + "."):
        sys.exit(0)

min_key = version_to_key(str(supported.get("min") or ""))
max_key = version_to_key(str(supported.get("max") or ""))

if min_key is not None and version_key < min_key:
    sys.exit(1)
if max_key is not None and version_key > max_key:
    sys.exit(1)
if min_key is not None or max_key is not None:
    sys.exit(0)

sys.exit(1)
PY
}

v2k_compat_select_profile_for_version() {
  local version="${1:-}"
  [[ -n "${version}" ]] || return 1

  local profile
  while IFS= read -r profile; do
    [[ -n "${profile}" ]] || continue
    if v2k_compat_profile_supports_version "${profile}" "${version}"; then
      printf '%s' "${profile}"
      return 0
    fi
  done < <(v2k_compat_list_profiles | sort)

  return 1
}

v2k_compat_path_prepend() {
  local path="${1:-}"
  [[ -n "${path}" && -d "${path}" ]] || return 0

  case ":${PATH}:" in
    *":${path}:"*) ;;
    *)
      PATH="${path}${PATH:+:${PATH}}"
      export PATH
      ;;
  esac
}

v2k_compat_export_tool_paths() {
  local profile="${1:-}"
  [[ -n "${profile}" ]] || return 1

  local govc_bin python_bin vddk_dir
  govc_bin="$(v2k_compat_profile_tool_path "${profile}" "govc" "bin/govc" 2>/dev/null || true)"
  python_bin="$(v2k_compat_profile_tool_path "${profile}" "python" "venv/bin/python3" 2>/dev/null || true)"
  vddk_dir="$(v2k_compat_profile_tool_path "${profile}" "vddk_libdir" "vddk" 2>/dev/null || true)"

  if [[ -n "${govc_bin}" && -x "${govc_bin}" ]]; then
    export V2K_GOVC_BIN="${govc_bin}"
  fi
  if [[ -n "${python_bin}" && -x "${python_bin}" ]]; then
    export V2K_PYTHON_BIN="${python_bin}"
  fi
  if [[ -n "${vddk_dir}" && -d "${vddk_dir}" ]]; then
    export VDDK_LIBDIR="${vddk_dir}"
  fi

  if [[ -n "${python_bin}" ]]; then
    v2k_compat_path_prepend "$(dirname "${python_bin}")"
  fi
  if [[ -n "${govc_bin}" ]]; then
    v2k_compat_path_prepend "$(dirname "${govc_bin}")"
  fi
}

v2k_compat_activate_profile() {
  local profile="${1:-}"
  [[ -n "${profile}" ]] || return 1
  [[ "${profile}" != "auto" ]] || return 0

  local profile_dir
  profile_dir="$(v2k_compat_profile_dir "${profile}")"
  [[ -f "${profile_dir}/profile.json" ]] || {
    echo "Compatibility profile not found: ${profile}" >&2
    return 1
  }
  v2k_compat_profile_is_valid "${profile}" || {
    echo "Compatibility profile is invalid: ${profile}" >&2
    return 1
  }

  export V2K_COMPAT_SELECTED_PROFILE="${profile}"
  export V2K_COMPAT_PROFILE_DIR="${profile_dir}"
  v2k_compat_export_tool_paths "${profile}"
}

v2k_compat_load_from_manifest() {
  local manifest="${1:-}"
  [[ -n "${manifest}" && -f "${manifest}" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local compat_json
  compat_json="$(jq -c '.source.compat // empty' "${manifest}" 2>/dev/null || true)"
  [[ -n "${compat_json}" ]] || return 1

  local requested selected detected root govc_bin python_bin vddk_libdir
  requested="$(printf '%s' "${compat_json}" | jq -r '.requested_profile // empty' 2>/dev/null || true)"
  selected="$(printf '%s' "${compat_json}" | jq -r '.selected_profile // empty' 2>/dev/null || true)"
  detected="$(printf '%s' "${compat_json}" | jq -r '.detected_vcenter_version // empty' 2>/dev/null || true)"
  root="$(printf '%s' "${compat_json}" | jq -r '.compat_root // empty' 2>/dev/null || true)"
  govc_bin="$(printf '%s' "${compat_json}" | jq -r '.tools.govc_bin // empty' 2>/dev/null || true)"
  python_bin="$(printf '%s' "${compat_json}" | jq -r '.tools.python_bin // empty' 2>/dev/null || true)"
  vddk_libdir="$(printf '%s' "${compat_json}" | jq -r '.tools.vddk_libdir // empty' 2>/dev/null || true)"

  [[ -n "${requested}" ]] && export V2K_COMPAT_PROFILE="${requested}"
  [[ -n "${selected}" ]] && export V2K_COMPAT_SELECTED_PROFILE="${selected}"
  [[ -n "${detected}" ]] && export V2K_COMPAT_DETECTED_VCENTER_VERSION="${detected}"
  [[ -n "${root}" ]] && export V2K_COMPAT_ROOT="${root}"
  [[ -n "${govc_bin}" ]] && export V2K_GOVC_BIN="${govc_bin}"
  [[ -n "${python_bin}" ]] && export V2K_PYTHON_BIN="${python_bin}"
  [[ -n "${vddk_libdir}" ]] && export VDDK_LIBDIR="${vddk_libdir}"

  if [[ -n "${govc_bin}" ]]; then
    v2k_compat_path_prepend "$(dirname "${govc_bin}")"
  fi
  if [[ -n "${python_bin}" ]]; then
    v2k_compat_path_prepend "$(dirname "${python_bin}")"
  fi

  if [[ -n "${selected}" && -z "${V2K_COMPAT_PROFILE_DIR:-}" ]]; then
    export V2K_COMPAT_PROFILE_DIR="$(v2k_compat_profile_dir "${selected}")"
  fi
}

v2k_compat_load_from_workdir() {
  local workdir="${1:-}"
  [[ -n "${workdir}" && -d "${workdir}" ]] || return 1
  local env_file="${workdir}/compat.env"
  [[ -f "${env_file}" ]] || return 1

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a

  if [[ -n "${V2K_GOVC_BIN:-}" ]]; then
    v2k_compat_path_prepend "$(dirname "${V2K_GOVC_BIN}")"
  fi
  if [[ -n "${V2K_PYTHON_BIN:-}" ]]; then
    v2k_compat_path_prepend "$(dirname "${V2K_PYTHON_BIN}")"
  fi
}

v2k_compat_write_env() {
  local workdir="${1:-}"
  [[ -n "${workdir}" && -d "${workdir}" ]] || return 1

  local env_file="${workdir}/compat.env"
  cat > "${env_file}" <<EOF
V2K_COMPAT_ROOT=${V2K_COMPAT_ROOT:-}
V2K_COMPAT_PROFILE=${V2K_COMPAT_PROFILE:-auto}
V2K_COMPAT_SELECTED_PROFILE=${V2K_COMPAT_SELECTED_PROFILE:-}
V2K_COMPAT_DETECTED_VCENTER_VERSION=${V2K_COMPAT_DETECTED_VCENTER_VERSION:-}
V2K_COMPAT_PROFILE_DIR=${V2K_COMPAT_PROFILE_DIR:-}
V2K_GOVC_BIN=${V2K_GOVC_BIN:-}
V2K_PYTHON_BIN=${V2K_PYTHON_BIN:-}
VDDK_LIBDIR=${VDDK_LIBDIR:-}
EOF
  chmod 600 "${env_file}" 2>/dev/null || true
}

v2k_compat_extract_version_from_about_json() {
  local about_json="${1:-}"
  [[ -n "${about_json}" ]] || return 1

  local version
  version="$(printf '%s' "${about_json}" | jq -r '
    .About.Version
    // .about.version
    // .version
    // empty
  ' 2>/dev/null || true)"
  [[ -n "${version}" ]] || return 1
  printf '%s' "${version}"
}

v2k_compat_bootstrap_env() {
  local manifest="${1:-}"
  local workdir="${2:-}"
  local requested

  v2k_compat_root >/dev/null
  requested="$(v2k_compat_requested_profile)"
  export V2K_COMPAT_PROFILE="${requested}"

  if [[ -n "${manifest}" ]]; then
    v2k_compat_load_from_manifest "${manifest}" || true
  fi
  if [[ -n "${workdir}" ]]; then
    v2k_compat_load_from_workdir "${workdir}" || true
  fi

  if [[ -n "${V2K_COMPAT_SELECTED_PROFILE:-}" ]]; then
    v2k_compat_activate_profile "${V2K_COMPAT_SELECTED_PROFILE}"
    return 0
  fi

  if [[ "${requested}" != "auto" ]]; then
    v2k_compat_activate_profile "${requested}"
  fi
}

v2k_compat_detect_vcenter_version() {
  if [[ -n "${V2K_COMPAT_DETECTED_VCENTER_VERSION:-}" ]]; then
    printf '%s' "${V2K_COMPAT_DETECTED_VCENTER_VERSION}"
    return 0
  fi

  command -v jq >/dev/null 2>&1 || return 1

  local about_json version
  about_json="$(v2k_govc about -json 2>/dev/null || true)"
  [[ -n "${about_json}" ]] || return 1

  version="$(v2k_compat_extract_version_from_about_json "${about_json}" 2>/dev/null || true)"
  [[ -n "${version}" ]] || return 1

  export V2K_COMPAT_DETECTED_VCENTER_VERSION="${version}"
  printf '%s' "${version}"
}

v2k_compat_probe_vcenter_version_from_profile() {
  local profile="${1:-}"
  [[ -n "${profile}" ]] || return 1

  local govc_bin about_json version
  govc_bin="$(v2k_compat_profile_tool_path "${profile}" "govc" "bin/govc" 2>/dev/null || true)"
  [[ -n "${govc_bin}" && -x "${govc_bin}" ]] || return 1

  about_json="$("${govc_bin}" about -json 2>/dev/null || true)"
  [[ -n "${about_json}" ]] || return 1

  version="$(v2k_compat_extract_version_from_about_json "${about_json}" 2>/dev/null || true)"
  [[ -n "${version}" ]] || return 1
  printf '%s' "${version}"
}

v2k_compat_validate_requested_profile() {
  local requested="${1:-}"
  [[ -n "${requested}" ]] || return 1
  [[ "${requested}" == "auto" ]] && return 0
  v2k_compat_profile_exists "${requested}"
}

v2k_compat_guard_manifest_profile() {
  local manifest="${1:-}" requested="${2:-auto}"
  [[ -n "${manifest}" && -f "${manifest}" ]] || return 0

  local selected
  selected="$(v2k_manifest_get_compat_selected_profile "${manifest}" 2>/dev/null || true)"
  [[ -n "${selected}" ]] || return 0

  if [[ "${requested}" != "auto" && "${requested}" != "${selected}" ]]; then
    echo "Compatibility profile mismatch: requested=${requested}, existing=${selected}" >&2
    return 1
  fi
  return 0
}

v2k_compat_resolve_profile() {
  local requested="${1:-auto}"
  local workdir="${2:-}"
  local manifest="${3:-}"
  local fail_on_missing="${4:-0}"

  [[ -n "${requested}" ]] || requested="auto"
  export V2K_COMPAT_PROFILE="${requested}"

  if [[ -n "${manifest}" ]]; then
    v2k_compat_guard_manifest_profile "${manifest}" "${requested}" || return 1
  fi

  if [[ -n "${V2K_COMPAT_SELECTED_PROFILE:-}" ]]; then
    v2k_compat_activate_profile "${V2K_COMPAT_SELECTED_PROFILE}" || return 1
    [[ -n "${workdir}" ]] && v2k_compat_write_env "${workdir}" || true
    return 0
  fi

  if [[ "${requested}" != "auto" ]]; then
    v2k_compat_activate_profile "${requested}" || return 1
    [[ -n "${workdir}" ]] && v2k_compat_write_env "${workdir}" || true
    return 0
  fi

  local detected selected available_count
  detected="$(v2k_compat_detect_vcenter_version 2>/dev/null || true)"
  if [[ -z "${detected}" ]]; then
    local probe_profile
    while IFS= read -r probe_profile; do
      [[ -n "${probe_profile}" ]] || continue
      detected="$(v2k_compat_probe_vcenter_version_from_profile "${probe_profile}" 2>/dev/null || true)"
      [[ -n "${detected}" ]] && break
    done < <(v2k_compat_list_profiles | sort)
  fi
  [[ -n "${detected}" ]] && export V2K_COMPAT_DETECTED_VCENTER_VERSION="${detected}"

  selected=""
  if [[ -n "${detected}" ]]; then
    selected="$(v2k_compat_select_profile_for_version "${detected}" 2>/dev/null || true)"
  fi

  if [[ -n "${selected}" ]]; then
    v2k_compat_activate_profile "${selected}" || return 1
    [[ -n "${workdir}" ]] && v2k_compat_write_env "${workdir}" || true
    return 0
  fi

  available_count="$(v2k_compat_list_profiles | wc -l | tr -d '[:space:]')"
  if [[ "${fail_on_missing}" == "1" && "${available_count}" != "0" ]]; then
    echo "No compatible profile found for detected vCenter version: ${detected:-unknown}" >&2
    return 1
  fi

  [[ -n "${workdir}" ]] && v2k_compat_write_env "${workdir}" || true
  return 0
}

v2k_require_compat_profile() {
  local requested
  requested="$(v2k_compat_requested_profile)"

  if [[ "${requested}" != "auto" && -z "${V2K_COMPAT_SELECTED_PROFILE:-}" ]]; then
    echo "Compatibility profile requested but not activated: ${requested}" >&2
    return 1
  fi
}

v2k_has_govc_bin() {
  local bin="${V2K_GOVC_BIN:-}"
  if [[ -z "${bin}" ]]; then
    bin="$(command -v govc 2>/dev/null || true)"
  fi
  [[ -n "${bin}" && -x "${bin}" ]]
}

v2k_has_python_bin() {
  local bin="${V2K_PYTHON_BIN:-}"
  if [[ -z "${bin}" ]]; then
    bin="$(command -v python3 2>/dev/null || true)"
  fi
  [[ -n "${bin}" && -x "${bin}" ]]
}

v2k_govc() {
  local bin="${V2K_GOVC_BIN:-}"
  if [[ -z "${bin}" ]]; then
    bin="$(command -v govc 2>/dev/null || true)"
  fi
  [[ -n "${bin}" ]] || {
    echo "govc not found in compatibility profile or PATH" >&2
    return 127
  }
  "${bin}" "$@"
}

v2k_python() {
  local bin="${V2K_PYTHON_BIN:-}"
  if [[ -z "${bin}" ]]; then
    bin="$(command -v python3 2>/dev/null || true)"
  fi
  [[ -n "${bin}" ]] || {
    echo "python3 not found in compatibility profile or PATH" >&2
    return 127
  }
  "${bin}" "$@"
}
