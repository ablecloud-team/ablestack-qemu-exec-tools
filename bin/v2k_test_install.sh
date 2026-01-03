#!/usr/bin/env bash
# ---------------------------------------------------------------------
# TODO: Copy the exact author/license header from bin/vm_exec.sh here.
#
# v2k test dependency installer + checker (Rocky/RHEL9+ focus)
#
# Usage:
#   sudo bin/v2k_test_install.sh [--offline-wheel-dir /path/to/wheels] [--skip-install]
#
# What it does:
#   - Checks required commands
#   - Installs OS packages (dnf) unless --skip-install
#   - Ensures python deps (pyvmomi) via pip (online) or wheel dir (offline)
#   - Validates nbdkit vddk plugin availability and VDDK_LIBDIR
# ---------------------------------------------------------------------
set -euo pipefail

OFFLINE_WHEEL_DIR=""
SKIP_INSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline-wheel-dir) OFFLINE_WHEEL_DIR="${2:-}"; shift 2;;
    --skip-install) SKIP_INSTALL=1; shift 1;;
    -h|--help)
      echo "Usage: sudo $0 [--offline-wheel-dir /path] [--skip-install]"
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

check_vddk() {
  : "${VDDK_LIBDIR:?Missing VDDK_LIBDIR. Example: export VDDK_LIBDIR=/opt/vmware-vix-disklib-distrib/lib64}"
  [[ -d "${VDDK_LIBDIR}" ]] || { echo "[ERR] VDDK_LIBDIR not a dir: ${VDDK_LIBDIR}" >&2; exit 2; }
  [[ -f "${VDDK_LIBDIR}/libvixDiskLib.so" || -f "${VDDK_LIBDIR}/libvixDiskLib.so.8" ]] || {
    echo "[ERR] libvixDiskLib.so not found under VDDK_LIBDIR=${VDDK_LIBDIR}" >&2
    exit 2
  }
  echo "[OK] VDDK_LIBDIR looks valid: ${VDDK_LIBDIR}"
}

check_nbdkit_vddk_plugin() {
  if ! has_cmd nbdkit; then
    echo "[ERR] nbdkit not found" >&2
    exit 2
  fi
  if nbdkit vddk --help >/dev/null 2>&1; then
    echo "[OK] nbdkit vddk plugin available"
  else
    echo "[ERR] nbdkit vddk plugin not available." >&2
    echo "      You need nbdkit built/installed with the vddk plugin enabled, and VDDK libraries present." >&2
    exit 2
  fi
}

check_govc() {
  if has_cmd govc; then
    echo "[OK] govc found: $(command -v govc)"
    return 0
  fi
  echo "[ERR] govc not found." >&2
  echo "      Install govc binary (offline: place in /usr/local/bin/govc and chmod +x)." >&2
  exit 2
}

check_core_cmds() {
  local cmds=(jq openssl qemu-img qemu-nbd nbd-client virsh udevadm python3)
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

  local id
  id="$(os_id)"
  echo "[INFO] OS ID: ${id}"

  if [[ "${SKIP_INSTALL}" -eq 0 ]]; then
    if [[ "${id}" =~ (rocky|rhel|almalinux|centos) ]]; then
      install_pkgs_dnf jq openssl qemu-img qemu-kvm libvirt-client nbd nbdkit udev python3 python3-pip
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

  check_govc
  install_pyvmomi
  check_vddk
  check_nbdkit_vddk_plugin

  echo ""
  echo "[OK] v2k test dependencies are ready."
  echo "Next:"
  echo "  - Export GOVC_* env (examples/v2k/govc.env.example)"
  echo "  - Export VDDK_LIBDIR"
  echo "  - Run docs/v2k_test_guide.md"
}

main "$@"
