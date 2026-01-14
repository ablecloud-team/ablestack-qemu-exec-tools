#!/usr/bin/env bash
# ---------------------------------------------------------------------
# TODO: Copy the exact author/license header from bin/vm_exec.sh here.
#
# v2k test dependency installer + checker (Rocky/RHEL9+ focus)
#
# Enhancements (assets support):
#   - Installs "non-RPM" assets from repo ./assets
#       * assets/govc_Linux_x86_64.tar.gz
#       * assets/VMware-vix-disklib-*.tar.gz
#   - Installs govc to /usr/local/bin
#   - Installs VMware VDDK to /opt/vmware-vix-disklib-distrib (symlink)
#   - Writes default env to /etc/profile.d/v2k-vddk.sh (optional)
#
# Usage:
#   sudo bin/v2k_test_install.sh [--offline-wheel-dir /path/to/wheels] [--skip-install] [--install-assets] [--no-profiled]
# ---------------------------------------------------------------------
set -euo pipefail

OFFLINE_WHEEL_DIR=""
SKIP_INSTALL=0
INSTALL_ASSETS=0
WRITE_PROFILED=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline-wheel-dir) OFFLINE_WHEEL_DIR="${2:-}"; shift 2;;
    --skip-install) SKIP_INSTALL=1; shift 1;;
    --install-assets) INSTALL_ASSETS=1; shift 1;;
    --no-profiled) WRITE_PROFILED=0; shift 1;;
    -h|--help)
      echo "Usage: sudo $0 [--offline-wheel-dir /path] [--skip-install] [--install-assets] [--no-profiled]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
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

has_cmd() { command -v "$1" >/dev/null 2>&1; }

repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "${here}/.." && pwd)
}

os_id() {
  if [[ -r /etc/os-release ]]; then
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

python_has_module() {
  local mod="$1"
  python3 -c "import ${mod}" >/dev/null 2>&1
}

ensure_pip() {
  if ! has_cmd pip3; then
    echo "[INFO] Installing python3-pip"
    dnf -y install python3-pip
  fi
}

install_pyvmomi() {
  if python_has_module "pyVmomi"; then
    echo "[OK] pyvmomi already installed"
    return 0
  fi

  ensure_pip
  if [[ -n "${OFFLINE_WHEEL_DIR}" ]]; then
    [[ -d "${OFFLINE_WHEEL_DIR}" ]] || { echo "[ERR] wheel dir not found: ${OFFLINE_WHEEL_DIR}" >&2; exit 2; }
    echo "[INFO] Installing pyvmomi from offline wheels: ${OFFLINE_WHEEL_DIR}"
    python3 -m pip install --no-index --find-links "${OFFLINE_WHEEL_DIR}" pyvmomi
  else
    echo "[INFO] Installing pyvmomi from PyPI (requires internet)"
    python3 -m pip install pyvmomi
  fi

  python_has_module "pyVmomi" || { echo "[ERR] pyvmomi install failed" >&2; exit 1; }
  echo "[OK] pyvmomi installed"
}

install_govc_from_assets() {
  local root="$1"
  local tgz="${root}/assets/govc_Linux_x86_64.tar.gz"
  if [[ ! -f "${tgz}" ]]; then
    echo "[WARN] govc asset not found: ${tgz}"
    return 1
  fi

  echo "[INFO] Installing govc from asset: ${tgz}"
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "${tgz}" -C "${tmp}"

  local bin=""
  if [[ -f "${tmp}/govc" ]]; then
    bin="${tmp}/govc"
  else
    bin="$(find "${tmp}" -maxdepth 3 -type f -name govc | head -n1 || true)"
  fi

  if [[ -z "${bin}" || ! -f "${bin}" ]]; then
    echo "[ERR] govc binary not found inside ${tgz}" >&2
    rm -rf "${tmp}"
    return 2
  fi

  install -m 0755 "${bin}" /usr/local/bin/govc
  rm -rf "${tmp}"
  echo "[OK] govc installed to /usr/local/bin/govc"
  return 0
}

install_vddk_from_assets() {
  local root="$1"
  local tgz
  tgz="$(ls -1 "${root}"/assets/VMware-vix-disklib-*.tar.gz 2>/dev/null | sort | tail -n1 || true)"
  if [[ -z "${tgz}" ]]; then
    echo "[WARN] VDDK asset not found: ${root}/assets/VMware-vix-disklib-*.tar.gz"
    return 1
  fi

  echo "[INFO] Installing VMware VDDK from asset: ${tgz}"
  mkdir -p /opt
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "${tgz}" -C "${tmp}"

  local distrib=""
  distrib="$(find "${tmp}" -maxdepth 2 -type d \( -iname 'vmware-vix-disklib-distrib' -o -iname 'VMware-vix-disklib-distrib' \) | head -n1 || true)"
  if [[ -z "${distrib}" ]]; then
    distrib="$(find "${tmp}" -maxdepth 2 -type d -iname '*disklib*distrib*' | head -n1 || true)"
  fi
  if [[ -z "${distrib}" || ! -d "${distrib}" ]]; then
    echo "[ERR] Could not locate VDDK distrib directory in ${tgz}" >&2
    rm -rf "${tmp}"
    return 2
  fi

  local base_name
  base_name="$(basename "${tgz}" .tar.gz)"
  base_name="${base_name// /_}"
  local dest_versioned="/opt/${base_name}"

  rm -rf "${dest_versioned}" >/dev/null 2>&1 || true
  cp -a "${distrib}" "${dest_versioned}"

  ln -sfn "${dest_versioned}" /opt/vmware-vix-disklib-distrib

  rm -rf "${tmp}"

  echo "[OK] VDDK installed to ${dest_versioned} (symlink: /opt/vmware-vix-disklib-distrib)"
  return 0
}

write_profiled_env() {
  local vddk_libdir="/opt/vmware-vix-disklib-distrib"
  local f="/etc/profile.d/v2k-vddk.sh"
  cat > "${f}" <<EOF
# Generated by v2k_test_install.sh
export VDDK_LIBDIR="${vddk_libdir}"
EOF
  chmod 0644 "${f}"
  source "${f}"
  echo "[OK] Wrote VDDK_LIBDIR default to ${f}"
}

check_vddk() {
  : "${VDDK_LIBDIR:?Missing VDDK_LIBDIR. Example: export VDDK_LIBDIR=/opt/vmware-vix-disklib-distrib/lib64}"
  [[ -d "${VDDK_LIBDIR}" ]] || { echo "[ERR] VDDK_LIBDIR not a dir: ${VDDK_LIBDIR}" >&2; exit 2; }
  if [[ ! -f "${VDDK_LIBDIR}/lib64/libvixDiskLib.so" && ! -f "${VDDK_LIBDIR}/lib64/libvixDiskLib.so."* ]]; then
    echo "[ERR] libvixDiskLib.so not found under VDDK_LIBDIR=${VDDK_LIBDIR}" >&2
    echo "      Provide VDDK tarball in ./assets and re-run with --install-assets, or set VDDK_LIBDIR correctly." >&2
    exit 2
  fi
  echo "[OK] VDDK_LIBDIR looks valid: ${VDDK_LIBDIR}"
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

check_govc() {
  if has_cmd govc; then
    echo "[OK] govc found: $(command -v govc)"
    return 0
  fi
  echo "[ERR] govc not found." >&2
  echo "      Provide ./assets/govc_Linux_x86_64.tar.gz and re-run with --install-assets." >&2
  exit 2
}

check_core_cmds() {
  local cmds=(jq openssl qemu-img qemu-nbd nbd-client virsh udevadm python3 tar)
  local missing=0
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

main() {
  require_root

  local root id
  root="$(repo_root)"
  id="$(os_id)"
  echo "[INFO] Repo root: ${root}"
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

  if [[ "${INSTALL_ASSETS}" -eq 1 ]]; then
    install_govc_from_assets "${root}" || true
    install_vddk_from_assets "${root}" || true
    if [[ "${WRITE_PROFILED}" -eq 1 ]]; then
      write_profiled_env
    fi
  fi

  if [[ -z "${VDDK_LIBDIR:-}" && -f /etc/profile.d/v2k-vddk.sh ]]; then
    # shellcheck source=/etc/profile.d/v2k-vddk.sh
    source /etc/profile.d/v2k-vddk.sh || true
  fi

  check_govc
  install_pyvmomi
  check_vddk
  check_nbdkit_vddk_plugin

  echo ""
  echo "[OK] v2k test dependencies are ready."
  echo "Hints:"
  echo "  - Place assets under ./assets and run: sudo bin/v2k_test_install.sh --install-assets"
  echo "  - Default VDDK_LIBDIR (if installed): /opt/vmware-vix-disklib-distrib"
}

main "$@"
