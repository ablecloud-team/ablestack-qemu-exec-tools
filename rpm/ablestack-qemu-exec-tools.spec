# ablestack-qemu-exec-tools.spec - RPM spec for ablestack-qemu-exec-tools
#
# Copyright 2025 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0
# See: http://www.apache.org/licenses/LICENSE-2.0

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

mkdir -p %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools
cp -a lib/* %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/

mkdir -p %{buildroot}/usr/share/doc/%{name}
cp -a docs/* %{buildroot}/usr/share/doc/%{name}/
cp -a examples/* %{buildroot}/usr/share/doc/%{name}/

%files
%license LICENSE
%doc README.md
%doc /usr/share/doc/%{name}
%{_bindir}/vm_exec
/usr/local/lib/ablestack-qemu-exec-tools/*

%changelog
* Tue Jul 09 2025 Ablecloud Team <dev@ablecloud.io> - 0.1-1
- Initial packaging of vm_exec tool and library
