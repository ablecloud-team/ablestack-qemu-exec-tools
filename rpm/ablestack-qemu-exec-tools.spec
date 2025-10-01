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
Version:        %{version}
Release:        %{release}%{?dist}
Summary:        QEMU guest-agent based VM command execution and parsing utilities

License:        Apache-2.0
URL:            https://github.com/ablecloud-team/ablestack-qemu-exec-tools
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       bash
Requires:       jq
Requires:       libvirt-client
Requires:       cloud-init
#Requires:       qemu-guest-agent   # 필요시 추가

%description
ablestack-qemu-exec-tools is a Bash-based tool that enables remote execution 
of commands inside virtual machines via qemu-guest-agent, with JSON parsing support.

%prep
%setup -q

%install
# Binaries
mkdir -p %{buildroot}/usr/bin
install -m 0755 bin/vm_exec.sh %{buildroot}/usr/bin/vm_exec
install -m 0755 bin/agent_policy_fix.sh %{buildroot}/usr/bin/agent_policy_fix
install -m 0755 bin/cloud_init_auto.sh %{buildroot}/usr/bin/cloud_init_auto
install -m 0755 install.sh %{buildroot}/usr/bin/install_ablestack_qemu_exec_tools

# Libraries
mkdir -p %{buildroot}/usr/libexec/%{name}
cp -a lib/* %{buildroot}/usr/libexec/%{name}/ 2>/dev/null || :

# Docs
mkdir -p %{buildroot}/usr/share/doc/%{name}
cp -a README.md %{buildroot}/usr/share/doc/%{name}/
cp -a docs/* %{buildroot}/usr/share/doc/%{name}/ 2>/dev/null || :
cp -a examples/* %{buildroot}/usr/share/doc/%{name}/ 2>/dev/null || :
cp -a usage_agent_policy_fix.md %{buildroot}/usr/share/doc/%{name}/ 2>/dev/null || :

%files
%license LICENSE
%doc README.md docs/* examples/* usage_agent_policy_fix.md
/usr/bin/vm_exec
/usr/bin/agent_policy_fix
/usr/bin/cloud_init_auto
/usr/bin/install_ablestack_qemu_exec_tools
/usr/libexec/%{name}/*

%changelog
* Wed Jul 10 2025 ABLECLOUD <dev@ablecloud.io> %{version}-%{release}
- Initial packaging with vm_exec.sh, agent_policy_fix.sh, cloud_init_auto.sh
- Git hash: %{githash}

%post
echo "[INFO] Running post-install tasks for %{name}..."
if [ -x /usr/bin/agent_policy_fix ]; then
    /usr/bin/agent_policy_fix || echo "[WARN] agent_policy_fix failed"
fi
if [ -x /usr/bin/cloud_init_auto ]; then
    /usr/bin/cloud_init_auto || echo "[WARN] cloud_init_auto failed"
fi