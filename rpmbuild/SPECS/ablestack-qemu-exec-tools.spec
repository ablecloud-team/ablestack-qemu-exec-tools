Name:           ablestack-qemu-exec-tools
Version:        1.0.0
Release:        1%{?dist}
Summary:        Tools to remotely execute commands in VMs using QEMU Guest Agent

License:        Apache License 2.0
URL:            https://github.com/ablecloud-team/ablestack-qemu-exec-tools
Source0:        %{name}-%{version}.tar.gz

%description
A collection of command-line utilities to execute processes inside Linux or Windows virtual machines using QEMU guest agent.

%prep
%setup -q

%install
mkdir -p %{buildroot}/usr/bin
install -m 755 bin/vm_exec.sh %{buildroot}/usr/bin/vm_exec.sh

%files
/usr/bin/vm_exec.sh
