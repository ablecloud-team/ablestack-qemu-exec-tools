# ablestack_v2k.spec - RPM spec for ablestack_v2k (V2K add-on)
#
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

Name:           ablestack_v2k
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ABLESTACK VMware-to-KVM migration tool (V2K add-on)

License:        Apache-2.0
URL:            https://github.com/ablecloud-team/ablestack-qemu-exec-tools
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       bash
Requires:       bash-completion
Requires:       jq
Requires:       python3
Requires:       python3-pip
Requires:       openssl
Requires:       nbd
Requires:       nbdkit
Requires:       nbdkit-vddk-plugin
Requires:       qemu-img
Requires:       libvirt-client
Requires:       tar

%description
ablestack_v2k provides ABLESTACK VMware-to-KVM (V2K) migration scripts and libraries.
The package includes the offline V2K compatibility runtime assets used by v2k:
govc, VDDK payloads, pyVmomi wheels, compatibility profile definitions, and an
optional WinPE ISO when one is staged at RPM build time.

%prep
%setup -q

%install
# NOTE:
# - lib/v2k/fleet.sh 는 기존 cp -a lib/v2k/* 에 자동 포함됩니다.
# - completions/ablestack_v2k 는 표준 bash-completion 경로에 별도 설치합니다.

# Binaries (explicit path: /usr/local/bin)
mkdir -p %{buildroot}/usr/local/bin
install -m 0755 bin/ablestack_v2k.sh %{buildroot}/usr/local/bin/ablestack_v2k
install -m 0755 bin/v2k_test_install.sh %{buildroot}/usr/local/bin/v2k_test_install.sh

# Libraries (explicit path: /usr/local/lib/ablestack-qemu-exec-tools/v2k)
mkdir -p %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/v2k
cp -a lib/v2k/* %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/v2k/ 2>/dev/null || :

# Compatibility profiles (sample/default layout)
mkdir -p %{buildroot}/usr/share/ablestack/v2k
cp -a share/ablestack/v2k/compat %{buildroot}/usr/share/ablestack/v2k/ 2>/dev/null || :

# Offline runtime asset payload used by %post and by air-gapped repair flows.
mkdir -p %{buildroot}/usr/share/ablestack/v2k/runtime-assets
if [ -d assets ]; then
  cp -a assets %{buildroot}/usr/share/ablestack/v2k/runtime-assets/
fi
mkdir -p %{buildroot}/usr/share/ablestack/v2k/runtime-assets/share/ablestack/v2k
cp -a share/ablestack/v2k/compat %{buildroot}/usr/share/ablestack/v2k/runtime-assets/share/ablestack/v2k/ 2>/dev/null || :

# Optional WinPE ISO payload. Official release builds stage exactly one
# versioned ISO plus SHA256SUMS and set with_winpe=1. The payload, authoritative
# metadata, and compatibility link are all owned by the same RPM transaction.
mkdir -p %{buildroot}/usr/share/ablestack/v2k/winpe
%if 0%{?with_winpe}
set -- winpe/*.iso
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "[ERR] with_winpe=1 requires exactly one staged WinPE ISO." >&2
  exit 1
fi
if [ ! -f winpe/SHA256SUMS ]; then
  echo "[ERR] with_winpe=1 requires winpe/SHA256SUMS." >&2
  exit 1
fi
(
  cd winpe
  sha256sum -c SHA256SUMS
)
winpe_src="$1"
winpe_name="$(basename "${winpe_src}")"
case "${winpe_name}" in
  winpe-ablestack-v2k-*-amd64.iso) ;;
  *)
    echo "[ERR] Unexpected versioned WinPE ISO filename: ${winpe_name}" >&2
    exit 1
    ;;
esac
winpe_sha="$(awk -v name="${winpe_name}" '$2 == name {print $1; exit}' winpe/SHA256SUMS)"
if ! printf '%s' "${winpe_sha}" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  echo "[ERR] SHA256SUMS does not contain ${winpe_name}." >&2
  exit 1
fi
install -m 0444 "${winpe_src}" %{buildroot}/usr/share/ablestack/v2k/winpe/
install -m 0444 winpe/SHA256SUMS %{buildroot}/usr/share/ablestack/v2k/winpe/SHA256SUMS
printf '{"schema":1,"filename":"%s","sha256":"%s","architecture":"amd64","package_version":"%s"}\n' \
  "${winpe_name}" "${winpe_sha}" "%{version}" \
  > %{buildroot}/usr/share/ablestack/v2k/winpe/current.json
chmod 0444 %{buildroot}/usr/share/ablestack/v2k/winpe/current.json
ln -s "winpe/${winpe_name}" %{buildroot}/usr/share/ablestack/v2k/winpe.iso
%endif

# Bash completion (standard location)
mkdir -p %{buildroot}%{_datadir}/bash-completion/completions
install -m 0644 completions/%{name} %{buildroot}%{_datadir}/bash-completion/completions/%{name}

%post
if [ -x /usr/local/bin/v2k_test_install.sh ] && [ -d /usr/share/ablestack/v2k/runtime-assets/assets ]; then
  /usr/local/bin/v2k_test_install.sh \
    --repo-root /usr/share/ablestack/v2k/runtime-assets \
    --compat-root /usr/share/ablestack/v2k/compat \
    --skip-install \
    --install-assets \
    --install-profile all \
    --validate-profile all
fi

%posttrans
%if 0%{?with_winpe}
winpe_root=/usr/share/ablestack/v2k/winpe
winpe_name="$(jq -r '.filename // empty' "${winpe_root}/current.json" 2>/dev/null || true)"
if [ -z "${winpe_name}" ] \
    || [ ! -f "${winpe_root}/${winpe_name}" ] \
    || [ "$(readlink -e /usr/share/ablestack/v2k/winpe.iso 2>/dev/null || true)" != "${winpe_root}/${winpe_name}" ] \
    || ! (cd "${winpe_root}" && sha256sum -c SHA256SUMS); then
  echo "[ERR] Installed WinPE ISO, metadata, checksum, and compatibility link are inconsistent." >&2
  exit 1
fi
%endif
:

%preun
if [ "$1" -eq 0 ]; then
  # Remove installer-managed compatibility runtime assets on final erase.
  rm -rf /usr/share/ablestack/v2k/compat >/dev/null 2>&1 || true
  rm -rf /usr/share/ablestack/v2k/runtime-assets >/dev/null 2>&1 || true
  rm -f /etc/profile.d/v2k-compat.sh >/dev/null 2>&1 || true

  # Remove now-empty parent directories when possible.
  rmdir /usr/share/ablestack/v2k >/dev/null 2>&1 || true
  rmdir /usr/share/ablestack >/dev/null 2>&1 || true
fi

%files



%license LICENSE
/usr/local/bin/ablestack_v2k
/usr/local/bin/v2k_test_install.sh
/usr/local/lib/ablestack-qemu-exec-tools/v2k/*
/usr/share/ablestack/v2k/compat
/usr/share/ablestack/v2k/runtime-assets
/usr/share/ablestack/v2k/winpe
%if 0%{?with_winpe}
/usr/share/ablestack/v2k/winpe.iso
%endif
%{_datadir}/bash-completion/completions/%{name}

%changelog
* Sun Jan 11 2026 ABLECLOUD <dev@ablecloud.io> %{version}-%{release}
- Initial packaging for ablestack_v2k (scripts + lib/v2k)
- Git hash: %{githash}
