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
Requires:       openssl
Requires:       nbd
Requires:       nbdkit
Requires:       nbdkit-vddk-plugin
Requires:       qemu-img
Requires:       libvirt-client

%description
ablestack_v2k provides ABLESTACK VMware-to-KVM (V2K) migration scripts and libraries.
Assets such as VDDK and govc are handled by the offline ISO installer.

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

# Bash completion (standard location)
mkdir -p %{buildroot}%{_datadir}/bash-completion/completions
install -m 0644 completions/%{name} %{buildroot}%{_datadir}/bash-completion/completions/%{name}

%preun
if [ "$1" -eq 0 ]; then
  # Remove installer-managed compatibility runtime assets on final erase.
  rm -rf /usr/share/ablestack/v2k/compat >/dev/null 2>&1 || true
  rm -f /etc/profile.d/v2k-compat.sh >/dev/null 2>&1 || true

  # Remove installer-managed WinPE staging when the V2K add-on is erased.
  rm -f /usr/share/ablestack/v2k/winpe.iso >/dev/null 2>&1 || true
  rm -rf /usr/share/ablestack/v2k/winpe >/dev/null 2>&1 || true

  # Remove now-empty parent directories when possible.
  rmdir /usr/share/ablestack/v2k >/dev/null 2>&1 || true
  rmdir /usr/share/ablestack >/dev/null 2>&1 || true
fi

%files



%license LICENSE
/usr/local/bin/ablestack_v2k
/usr/local/bin/v2k_test_install.sh
/usr/local/lib/ablestack-qemu-exec-tools/v2k/*
/usr/share/ablestack/v2k/compat/*
%{_datadir}/bash-completion/completions/%{name}

%changelog
* Sun Jan 11 2026 ABLECLOUD <dev@ablecloud.io> %{version}-%{release}
- Initial packaging for ablestack_v2k (scripts + lib/v2k)
- Git hash: %{githash}
