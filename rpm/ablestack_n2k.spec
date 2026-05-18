# ablestack_n2k.spec - RPM spec for ablestack_n2k
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

Name:           ablestack_n2k
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        ABLESTACK Nutanix AHV-to-KVM migration tool

License:        Apache-2.0
URL:            https://github.com/ablecloud-team/ablestack-qemu-exec-tools
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       bash
Requires:       bash-completion
Requires:       jq
Requires:       curl
Requires:       openssl
Requires:       qemu-img
Requires:       libvirt-client

%description
ablestack_n2k provides ABLESTACK Nutanix AHV-to-KVM migration scripts and libraries.
It supports manifest-based state tracking, preflight planning, cold-export flows,
and early changed-region patch synchronization workflows.

%prep
%setup -q

%install
mkdir -p %{buildroot}/usr/local/bin
install -m 0755 bin/ablestack_n2k.sh %{buildroot}/usr/local/bin/ablestack_n2k

mkdir -p %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/n2k
cp -a lib/n2k/* %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/n2k/ 2>/dev/null || :

mkdir -p %{buildroot}%{_datadir}/bash-completion/completions
install -m 0644 completions/%{name} %{buildroot}%{_datadir}/bash-completion/completions/%{name}

mkdir -p %{buildroot}%{_docdir}/%{name}
cp -a docs/n2k/* %{buildroot}%{_docdir}/%{name}/ 2>/dev/null || :

%files
%license LICENSE
/usr/local/bin/ablestack_n2k
/usr/local/lib/ablestack-qemu-exec-tools/n2k/*
%{_datadir}/bash-completion/completions/%{name}
%{_docdir}/%{name}/*

%changelog
* Thu Apr 30 2026 ABLECLOUD <dev@ablecloud.io> %{version}-%{release}
- Initial packaging for ablestack_n2k
- Git hash: %{githash}
