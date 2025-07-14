# ablestack-qemu-exec-tools.spec - RPM spec for ablestack-qemu-exec-tools
#
# Copyright 2025 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# You may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

Name:           ablestack-qemu-exec-tools
Version:        0.1
Release:        1%{?dist}
Summary:        QEMU guest-agent 기반 VM 명령 실행 및 파싱 유틸리티

License:        Apache-2.0
URL:            https://github.com/ablecloud-team/ablestack-qemu-exec-tools
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       bash
Requires:       jq
Requires:       libvirt-client

%description
ablestack-qemu-exec-tools는 QEMU / libvirt 환경에서 qemu-guest-agent를 이용하여
가상머신 내부 명령을 원격으로 실행하고, 그 결과를 JSON 등으로 파싱하는 Bash 기반 도구입니다.

%prep
%setup -q

%install
mkdir -p %{buildroot}/usr/local/bin
install -m 0755 bin/vm_exec.sh %{buildroot}/usr/local/bin/vm_exec
install -m 0755 bin/agent_policy_fix.sh %{buildroot}/usr/local/bin/agent_policy_fix
install -m 0755 install.sh %{buildroot}/usr/local/bin/install_ablestack_qemu_exec_tools

mkdir -p %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools
cp -a lib/* %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/ 2>/dev/null || :

mkdir -p %{buildroot}/usr/share/doc/%{name}
cp -a docs/* %{buildroot}/usr/share/doc/%{name}/ 2>/dev/null || :
cp -a examples/* %{buildroot}/usr/share/doc/%{name}/ 2>/dev/null || :
cp -a README.md %{buildroot}/usr/share/doc/%{name}/
cp -a docs/usage_vm_exec.md %{buildroot}/usr/share/doc/%{name}/
cp -a usage_agent_policy_fix.md %{buildroot}/usr/share/doc/%{name}/ 2>/dev/null || :

%files
%license LICENSE
/usr/local/bin/vm_exec
/usr/local/bin/agent_policy_fix
/usr/local/bin/install_ablestack_qemu_exec_tools
/usr/local/lib/ablestack-qemu-exec-tools/*
/usr/share/doc/%{name}/*

%changelog
* Wed Jul 10 2025 ABLECLOUD <dev@ablecloud.io> 0.1-1
- 최초 패키지화 및 agent_policy_fix.sh, 사용설명서, install.sh 추가

