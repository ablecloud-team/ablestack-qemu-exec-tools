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

OFFLINE_WHEEL_DIR=""
SKIP_INSTALL=0
INSTALL_ASSETS=0
INSTALL_SAMPLE_PROFILES=0
WRITE_PROFILED=1
COMPAT_ROOT="/usr/share/ablestack/v2k/compat"
REPO_ROOT_OVERRIDE=""
INSTALL_PROFILE=""
LIST_PROFILES=0
VALIDATE_PROFILE=""

usage() {
  cat <<'EOF'
Usage:
  sudo bin/v2k_test_install.sh [options]

Options:
  --offline-wheel-dir <path>   Install pyVmomi from the given wheel directory
  --compat-root <path>         Compatibility profile installation root
  --repo-root <path>           Override repo/assets root (useful for ISO-mounted installs)
  --install-profile <id|all>   Install assets into one profile or all sample profiles
  --install-sample-profiles    Install sample profile templates without real SDK assets
  --validate-profile <id|all>  Validate one installed profile or all installed profiles
  --list-profiles              Show sample profile definitions and install status
  --skip-install               Skip OS package install and only validate
  --install-assets             Install compat profile assets from repo ./assets
  --no-profiled               Do not write /etc/profile.d/v2k-compat.sh
  -h, --help                   Show help

Asset resolution order for each profile:
  1. ./assets/compat/<profile>/govc_Linux_x86_64.tar.gz
  2. ./assets/govc_Linux_x86_64.tar.gz

  1. ./assets/compat/<profile>/VMware-vix-disklib-*.tar.gz
  2. ./assets/VMware-vix-disklib-*.tar.gz

  1. --offline-wheel-dir
  2. ./assets/compat/<profile>/wheels
  3. ./assets/v2k/wheels
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline-wheel-dir) OFFLINE_WHEEL_DIR="${2:-}"; shift 2;;
    --compat-root) COMPAT_ROOT="${2:-}"; shift 2;;
    --repo-root) REPO_ROOT_OVERRIDE="${2:-}"; shift 2;;
    --install-profile) INSTALL_PROFILE="${2:-}"; shift 2;;
    --install-sample-profiles) INSTALL_SAMPLE_PROFILES=1; shift 1;;
    --validate-profile) VALIDATE_PROFILE="${2:-}"; shift 2;;
    --list-profiles) LIST_PROFILES=1; shift 1;;
    --skip-install) SKIP_INSTALL=1; shift 1;;
    --install-assets) INSTALL_ASSETS=1; shift 1;;
    --no-profiled) WRITE_PROFILED=0; shift 1;;
    -h|--help) usage; exit 0;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 2
  fi
}

can_run_unprivileged() {
  [[ "${SKIP_INSTALL}" -eq 1 ]] || return 1
  [[ "${WRITE_PROFILED}" -eq 0 ]] || return 1
  [[ "${INSTALL_ASSETS}" -eq 1 || "${INSTALL_SAMPLE_PROFILES}" -eq 1 || -n "${VALIDATE_PROFILE}" ]] || return 1

  local parent
  parent="$(dirname "${COMPAT_ROOT}")"
  if [[ -d "${COMPAT_ROOT}" ]]; then
    [[ -w "${COMPAT_ROOT}" ]] && return 0
  fi
  if [[ -d "${parent}" && -w "${parent}" ]]; then
    return 0
  fi
  return 1
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "${here}/.." && pwd)
}

repo_compat_root() {
  local root="$1"
  printf '%s/share/ablestack/v2k/compat' "${root}"
}

asset_repo_root() {
  if [[ -n "${REPO_ROOT_OVERRIDE}" ]]; then
    printf '%s' "${REPO_ROOT_OVERRIDE}"
    return 0
  fi
  repo_root
}

profile_def_root() {
  local repo_root_path="$1"
  local installed_root="${COMPAT_ROOT}"
  local source_root
  source_root="$(repo_compat_root "${repo_root_path}")"

  if [[ -d "${source_root}" ]] && find "${source_root}" -mindepth 2 -maxdepth 2 -name profile.json | grep -q .; then
    printf '%s' "${source_root}"
    return 0
  fi

  if [[ -d "${installed_root}" ]] && find "${installed_root}" -mindepth 2 -maxdepth 2 -name profile.json | grep -q .; then
    printf '%s' "${installed_root}"
    return 0
  fi

  printf '%s' "${source_root}"
}

os_id() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

install_pkgs_dnf() {
  local pkgs=("$@")
  echo "[INFO] Installing packages via dnf: ${pkgs[*]}"
  dnf -y install "${pkgs[@]}"
}

ensure_epel() {
  if rpm -q epel-release >/dev/null 2>&1; then
    echo "[OK] epel-release already installed"
    return 0
  fi
  echo "[INFO] Installing epel-release (required for nbd/nbdkit on many systems)"
  dnf -y install epel-release || {
    echo "[ERR] Failed to install epel-release." >&2
    echo "      If you are in an air-gapped environment, provide epel-release RPM in a local repo and retry." >&2
    exit 2
  }
}

check_core_cmds() {
  local cmds=()
  if [[ "${INSTALL_SAMPLE_PROFILES}" -eq 1 && "${INSTALL_ASSETS}" -eq 0 ]]; then
    cmds=(jq python3 tar)
  else
    cmds=(jq openssl qemu-img qemu-nbd nbd-client virsh udevadm python3 tar)
  fi
  local missing=0
  local c
  for c in "${cmds[@]}"; do
    if has_cmd "${c}"; then
      echo "[OK] ${c}"
    else
      echo "[MISS] ${c}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || return 1
}

compat_profile_ids() {
  local compat_repo_root="$1"
  [[ -d "${compat_repo_root}" ]] || return 0

  local dir
  for dir in "${compat_repo_root}"/*; do
    [[ -d "${dir}" && -f "${dir}/profile.json" ]] || continue
    basename "${dir}"
  done | sort
}

resolve_profiles() {
  local compat_repo_root="$1"
  local selector="${2:-}"
  if [[ -z "${selector}" || "${selector}" == "all" ]]; then
    compat_profile_ids "${compat_repo_root}"
    return 0
  fi

  local item
  IFS=',' read -r -a items <<<"${selector}"
  for item in "${items[@]}"; do
    item="${item## }"
    item="${item%% }"
    [[ -n "${item}" ]] || continue
    [[ -f "${compat_repo_root}/${item}/profile.json" ]] || {
      echo "[ERR] Unknown compat profile: ${item}" >&2
      exit 2
    }
    echo "${item}"
  done
}

profile_label() {
  local profile_json="$1"
  if has_cmd jq; then
    jq -r '.label // ""' "${profile_json}" 2>/dev/null
    return 0
  fi
  python3 - <<PY
import json
with open(${profile_json@Q}, "r", encoding="utf-8") as f:
    print((json.load(f).get("label") or ""))
PY
}

profile_supported_range() {
  local profile_json="$1"
  if has_cmd jq; then
    jq -r '
      .supported_vcenter as $s
      | if ($s.versions // [] | length) > 0 then
          ($s.versions | join(","))
        else
          (($s.min // "?") + ".." + ($s.max // "?"))
        end
    ' "${profile_json}" 2>/dev/null
    return 0
  fi
  python3 - <<PY
import json
with open(${profile_json@Q}, "r", encoding="utf-8") as f:
    data = json.load(f)
supported = data.get("supported_vcenter") or {}
versions = supported.get("versions") or []
if versions:
    print(",".join(str(v) for v in versions))
else:
    print(f"{supported.get('min', '?')}..{supported.get('max', '?')}")
PY
}

asset_status() {
  local value="${1:-}"
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "missing"
  fi
}

list_profiles() {
  local root="$1" compat_repo_root="$2" compat_install_root="$3"
  echo "[INFO] Repo root: ${root}"
  echo "[INFO] Sample compat root: ${compat_repo_root}"
  echo "[INFO] Install compat root: ${compat_install_root}"

  local profile profile_json installed govc_asset vddk_asset wheel_dir
  while IFS= read -r profile; do
    [[ -n "${profile}" ]] || continue
    profile_json="${compat_repo_root}/${profile}/profile.json"
    installed="no"
    [[ -f "${compat_install_root}/${profile}/profile.json" ]] && installed="yes"
    govc_asset="$(resolve_profile_govc_asset "${root}" "${profile}" || true)"
    vddk_asset="$(resolve_profile_vddk_asset "${root}" "${profile}" || true)"
    wheel_dir="$(resolve_profile_wheel_dir "${root}" "${profile}" || true)"
    printf '%s\tinstalled=%s\tsupported=%s\tlabel=%s\n' \
      "${profile}" \
      "${installed}" \
      "$(profile_supported_range "${profile_json}")" \
      "$(profile_label "${profile_json}")"
    printf '  govc_asset=%s\n' "$(asset_status "${govc_asset}")"
    printf '  vddk_asset=%s\n' "$(asset_status "${vddk_asset}")"
    printf '  wheel_dir=%s\n' "$(asset_status "${wheel_dir}")"
  done < <(compat_profile_ids "${compat_repo_root}")
}

profile_asset_root() {
  local root="$1" profile="$2"
  printf '%s/assets/compat/%s' "${root}" "${profile}"
}

resolve_profile_govc_asset() {
  local root="$1" profile="$2"
  local profile_root tgz
  profile_root="$(profile_asset_root "${root}" "${profile}")"
  tgz="${profile_root}/govc_Linux_x86_64.tar.gz"
  if [[ -f "${tgz}" ]]; then
    printf '%s' "${tgz}"
    return 0
  fi
  tgz="${root}/assets/govc_Linux_x86_64.tar.gz"
  [[ -f "${tgz}" ]] && printf '%s' "${tgz}"
}

resolve_profile_vddk_asset() {
  local root="$1" profile="$2"
  local profile_root tgz
  profile_root="$(profile_asset_root "${root}" "${profile}")"
  tgz="$(ls -1 "${profile_root}"/VMware-vix-disklib-*.tar.gz 2>/dev/null | sort | tail -n1 || true)"
  if [[ -n "${tgz}" ]]; then
    printf '%s' "${tgz}"
    return 0
  fi
  tgz="$(ls -1 "${root}"/assets/VMware-vix-disklib-*.tar.gz 2>/dev/null | sort | tail -n1 || true)"
  [[ -n "${tgz}" ]] && printf '%s' "${tgz}"
}

resolve_profile_wheel_dir() {
  local root="$1" profile="$2"
  if [[ -n "${OFFLINE_WHEEL_DIR}" ]]; then
    printf '%s' "${OFFLINE_WHEEL_DIR}"
    return 0
  fi

  local profile_root wheel_dir
  profile_root="$(profile_asset_root "${root}" "${profile}")"
  wheel_dir="${profile_root}/wheels"
  if [[ -d "${wheel_dir}" ]]; then
    printf '%s' "${wheel_dir}"
    return 0
  fi

  wheel_dir="${root}/assets/v2k/wheels"
  [[ -d "${wheel_dir}" ]] && printf '%s' "${wheel_dir}"
}

install_profile_template() {
  local compat_repo_root="$1" compat_install_root="$2" profile="$3"
  local src="${compat_repo_root}/${profile}"
  local dst="${compat_install_root}/${profile}"
  local src_real="" dst_real=""

  [[ -f "${src}/profile.json" ]] || {
    echo "[ERR] Sample profile definition missing: ${src}/profile.json" >&2
    exit 2
  }

  src_real="$(readlink -f "${src}" 2>/dev/null || printf '%s' "${src}")"
  dst_real="$(readlink -f "${dst}" 2>/dev/null || printf '%s' "${dst}")"
  if [[ "${src_real}" == "${dst_real}" ]]; then
    mkdir -p "${dst}"
    [[ -f "${dst}/bin/govc" ]] && chmod 0755 "${dst}/bin/govc" 2>/dev/null || true
    [[ -f "${dst}/venv/bin/python3" ]] && chmod 0755 "${dst}/venv/bin/python3" 2>/dev/null || true
    return 0
  fi

  rm -rf "${dst}"
  mkdir -p "${compat_install_root}"
  cp -a "${src}" "${dst}"
  [[ -f "${dst}/bin/govc" ]] && chmod 0755 "${dst}/bin/govc" 2>/dev/null || true
  [[ -f "${dst}/venv/bin/python3" ]] && chmod 0755 "${dst}/venv/bin/python3" 2>/dev/null || true
}

mark_sample_profile_install() {
  local compat_install_root="$1" profile="$2"
  : > "${compat_install_root}/${profile}/.sample-runtime"
}

install_govc_into_profile() {
  local root="$1" compat_install_root="$2" profile="$3"
  local tgz dst tmp bin
  tgz="$(resolve_profile_govc_asset "${root}" "${profile}")"
  if [[ -z "${tgz}" ]]; then
    echo "[WARN] govc asset not found for profile=${profile}" >&2
    return 1
  fi

  echo "[INFO] Installing govc for profile=${profile} from ${tgz}"
  tmp="$(mktemp -d)"
  tar -xzf "${tgz}" -C "${tmp}"

  bin=""
  if [[ -f "${tmp}/govc" ]]; then
    bin="${tmp}/govc"
  else
    bin="$(find "${tmp}" -maxdepth 3 -type f -name govc | head -n1 || true)"
  fi
  [[ -n "${bin}" && -f "${bin}" ]] || {
    echo "[ERR] govc binary not found inside ${tgz}" >&2
    rm -rf "${tmp}"
    return 2
  }

  dst="${compat_install_root}/${profile}/bin/govc"
  mkdir -p "$(dirname "${dst}")"
  install -m 0755 "${bin}" "${dst}"
  rm -rf "${tmp}"
  echo "[OK] govc installed: ${dst}"
}

install_vddk_into_profile() {
  local root="$1" compat_install_root="$2" profile="$3"
  local tgz tmp distrib dst
  tgz="$(resolve_profile_vddk_asset "${root}" "${profile}")"
  if [[ -z "${tgz}" ]]; then
    echo "[WARN] VDDK asset not found for profile=${profile}" >&2
    return 1
  fi

  echo "[INFO] Installing VDDK for profile=${profile} from ${tgz}"
  tmp="$(mktemp -d)"
  tar -xzf "${tgz}" -C "${tmp}"

  distrib="$(find "${tmp}" -maxdepth 2 -type d \( -iname 'vmware-vix-disklib-distrib' -o -iname 'VMware-vix-disklib-distrib' \) | head -n1 || true)"
  if [[ -z "${distrib}" ]]; then
    distrib="$(find "${tmp}" -maxdepth 2 -type d -iname '*disklib*distrib*' | head -n1 || true)"
  fi
  [[ -n "${distrib}" && -d "${distrib}" ]] || {
    echo "[ERR] Could not locate VDDK distrib directory in ${tgz}" >&2
    rm -rf "${tmp}"
    return 2
  }

  dst="${compat_install_root}/${profile}/vddk"
  rm -rf "${dst}"
  mkdir -p "$(dirname "${dst}")"
  cp -a "${distrib}" "${dst}"
  rm -rf "${tmp}"
  echo "[OK] VDDK installed: ${dst}"
}

install_pyvmomi_into_profile() {
  local root="$1" compat_install_root="$2" profile="$3"
  local wheel_dir profile_root python_bin pip_bin
  profile_root="${compat_install_root}/${profile}"
  wheel_dir="$(resolve_profile_wheel_dir "${root}" "${profile}")"

  rm -rf "${profile_root}/venv"
  python3 -m venv "${profile_root}/venv"
  python_bin="${profile_root}/venv/bin/python3"
  pip_bin="${profile_root}/venv/bin/pip"

  if [[ -n "${wheel_dir}" ]]; then
    [[ -d "${wheel_dir}" ]] || {
      echo "[ERR] wheel dir not found: ${wheel_dir}" >&2
      return 2
    }
    echo "[INFO] Installing pyVmomi for profile=${profile} from wheels: ${wheel_dir}"
    "${pip_bin}" install --no-index --find-links "${wheel_dir}" pyvmomi
  else
    echo "[INFO] Installing pyVmomi for profile=${profile} from PyPI"
    "${pip_bin}" install pyvmomi
  fi

  "${python_bin}" -c "import pyVmomi" >/dev/null 2>&1 || {
    echo "[ERR] pyVmomi install failed for profile=${profile}" >&2
    return 2
  }
  echo "[OK] pyVmomi installed: ${profile_root}/venv"
}

write_profiled_env() {
  local compat_root="$1"
  local f="/etc/profile.d/v2k-compat.sh"
  cat > "${f}" <<EOF
# Generated by v2k_test_install.sh
export V2K_COMPAT_ROOT="${compat_root}"
EOF
  chmod 0644 "${f}"
  # shellcheck disable=SC1091
  source "${f}" || true
  echo "[OK] Wrote V2K_COMPAT_ROOT default to ${f}"
}

check_nbdkit_vddk_plugin() {
  if ! has_cmd nbdkit; then
    echo "[ERR] nbdkit not found" >&2
    exit 2
  fi

  if nbdkit vddk --help >/dev/null 2>&1; then
    echo "[OK] nbdkit vddk plugin available"
    return 0
  fi

  local candidates=(nbdkit-plugin-vddk nbdkit-vddk-plugin)
  echo "[WARN] nbdkit vddk plugin not detected. Trying to install plugin package if available..."
  local pkg
  for pkg in "${candidates[@]}"; do
    if dnf -y install "${pkg}" >/dev/null 2>&1; then
      echo "[OK] Installed plugin package: ${pkg}"
      break
    fi
  done

  if nbdkit vddk --help >/dev/null 2>&1; then
    echo "[OK] nbdkit vddk plugin available (after install attempt)"
    return 0
  fi

  echo "[ERR] nbdkit vddk plugin still not available." >&2
  echo "      On Rocky/RHEL, vddk plugin may not be available as RPM." >&2
  echo "      You may need to build nbdkit from source with VDDK installed." >&2
  exit 2
}

check_profile_govc() {
  local compat_install_root="$1" profile="$2"
  local bin="${compat_install_root}/${profile}/bin/govc"
  [[ -x "${bin}" ]] || {
    echo "[ERR] govc not found for profile=${profile}: ${bin}" >&2
    return 1
  }
  echo "[OK] profile=${profile} govc=${bin}"
}

check_profile_python() {
  local compat_install_root="$1" profile="$2"
  local py="${compat_install_root}/${profile}/venv/bin/python3"
  [[ -x "${py}" ]] || {
    echo "[ERR] python3 not found for profile=${profile}: ${py}" >&2
    return 1
  }
  "${py}" -c "import pyVmomi" >/dev/null 2>&1 || {
    echo "[ERR] pyVmomi import failed for profile=${profile}" >&2
    return 1
  }
  echo "[OK] profile=${profile} python=${py} pyVmomi=ok"
}

check_profile_vddk() {
  local compat_install_root="$1" profile="$2"
  local vddk="${compat_install_root}/${profile}/vddk"
  [[ -d "${vddk}" ]] || {
    echo "[ERR] VDDK dir not found for profile=${profile}: ${vddk}" >&2
    return 1
  }
  if [[ ! -f "${vddk}/lib64/libvixDiskLib.so" && ! -f "${vddk}/lib64/libvixDiskLib.so."* ]]; then
    echo "[ERR] libvixDiskLib.so not found for profile=${profile}: ${vddk}" >&2
    return 1
  fi
  echo "[OK] profile=${profile} vddk=${vddk}"
}

check_profile_json() {
  local compat_install_root="$1" profile="$2"
  local profile_json="${compat_install_root}/${profile}/profile.json"
  [[ -f "${profile_json}" ]] || {
    echo "[ERR] profile.json not found for profile=${profile}: ${profile_json}" >&2
    return 1
  }
  jq -e . "${profile_json}" >/dev/null 2>&1 || {
    echo "[ERR] Invalid profile.json for profile=${profile}: ${profile_json}" >&2
    return 1
  }
  echo "[OK] profile=${profile} profile.json=${profile_json}"
}

validate_installed_profile() {
  local compat_install_root="$1" profile="$2"
  local sample_marker="${compat_install_root}/${profile}/.sample-runtime"
  check_profile_json "${compat_install_root}" "${profile}"
  check_profile_govc "${compat_install_root}" "${profile}"
  if [[ -f "${sample_marker}" ]]; then
    local py="${compat_install_root}/${profile}/venv/bin/python3"
    local vddk="${compat_install_root}/${profile}/vddk"
    [[ -x "${py}" ]] || {
      echo "[ERR] sample python wrapper not found for profile=${profile}: ${py}" >&2
      return 1
    }
    [[ -d "${vddk}" ]] || {
      echo "[ERR] sample VDDK dir not found for profile=${profile}: ${vddk}" >&2
      return 1
    }
    echo "[OK] profile=${profile} sample-runtime markers look valid"
  else
    check_profile_python "${compat_install_root}" "${profile}"
    check_profile_vddk "${compat_install_root}" "${profile}"
  fi
}

install_profile_assets() {
  local root="$1" compat_repo_root="$2" compat_install_root="$3" profile="$4"
  install_profile_template "${compat_repo_root}" "${compat_install_root}" "${profile}"
  install_govc_into_profile "${root}" "${compat_install_root}" "${profile}" || true
  install_vddk_into_profile "${root}" "${compat_install_root}" "${profile}" || true
  install_pyvmomi_into_profile "${root}" "${compat_install_root}" "${profile}"
}

main() {
  local root asset_root compat_repo_root id
  root="$(repo_root)"
  asset_root="$(asset_repo_root)"
  compat_repo_root="$(profile_def_root "${root}")"
  id="$(os_id)"

  if [[ "${LIST_PROFILES}" -eq 1 ]]; then
    list_profiles "${asset_root}" "${compat_repo_root}" "${COMPAT_ROOT}"
    exit 0
  fi

  if ! can_run_unprivileged; then
    require_root
  fi

  echo "[INFO] Source repo root: ${root}"
  echo "[INFO] Asset repo root: ${asset_root}"
  echo "[INFO] Profile definition root: ${compat_repo_root}"
  echo "[INFO] Install compat root: ${COMPAT_ROOT}"
  echo "[INFO] OS ID: ${id}"

  if [[ "${SKIP_INSTALL}" -eq 0 ]]; then
    if [[ "${id}" =~ (rocky|rhel|almalinux|centos) ]]; then
      ensure_epel
      install_pkgs_dnf jq openssl tar qemu-img qemu-kvm libvirt-client nbd nbdkit udev python3 python3-pip
    else
      echo "[WARN] Unknown OS. Skipping package install. Install deps manually or re-run with --skip-install." >&2
    fi
  else
    echo "[INFO] --skip-install set. Only running checks."
  fi

  if ! check_core_cmds; then
    echo "[ERR] Missing core dependencies. Install them and re-run." >&2
    exit 2
  fi

  if [[ "${INSTALL_SAMPLE_PROFILES}" -eq 0 || "${INSTALL_ASSETS}" -eq 1 ]]; then
    check_nbdkit_vddk_plugin
  fi

  local profiles_to_process=()
  while IFS= read -r profile; do
    [[ -n "${profile}" ]] || continue
    profiles_to_process+=("${profile}")
  done < <(resolve_profiles "${compat_repo_root}" "${INSTALL_PROFILE:-${VALIDATE_PROFILE:-all}}")

  if [[ "${INSTALL_SAMPLE_PROFILES}" -eq 1 ]]; then
    local profile
    for profile in "${profiles_to_process[@]}"; do
      install_profile_template "${compat_repo_root}" "${COMPAT_ROOT}" "${profile}"
      mark_sample_profile_install "${COMPAT_ROOT}" "${profile}"
    done
    if [[ "${WRITE_PROFILED}" -eq 1 ]]; then
      write_profiled_env "${COMPAT_ROOT}"
    fi
  fi

  if [[ "${INSTALL_ASSETS}" -eq 1 ]]; then
    local profile
    for profile in "${profiles_to_process[@]}"; do
      install_profile_assets "${asset_root}" "${compat_repo_root}" "${COMPAT_ROOT}" "${profile}"
    done
    if [[ "${WRITE_PROFILED}" -eq 1 ]]; then
      write_profiled_env "${COMPAT_ROOT}"
    fi
  fi

  if [[ -n "${VALIDATE_PROFILE}" || "${INSTALL_ASSETS}" -eq 1 || "${INSTALL_SAMPLE_PROFILES}" -eq 1 ]]; then
    local profile
    for profile in "${profiles_to_process[@]}"; do
      validate_installed_profile "${COMPAT_ROOT}" "${profile}"
    done
  fi

  echo ""
  echo "[OK] v2k compatibility profiles are ready."
  echo "Hints:"
  echo "  - List sample profiles: sudo bin/v2k_test_install.sh --list-profiles"
  echo "  - Install sample profiles only: sudo bin/v2k_test_install.sh --skip-install --install-sample-profiles --install-profile all --compat-root <path> --no-profiled"
  echo "  - Install all sample profiles: sudo bin/v2k_test_install.sh --install-assets --install-profile all"
  echo "  - Install one profile: sudo bin/v2k_test_install.sh --install-assets --install-profile vsphere60"
  echo "  - Validate installed profiles: sudo bin/v2k_test_install.sh --skip-install --validate-profile all"
  echo "  - Default compat root (if profiled): ${COMPAT_ROOT}"
}

main "$@"
