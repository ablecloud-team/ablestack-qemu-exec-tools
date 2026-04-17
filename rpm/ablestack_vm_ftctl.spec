Name:           ablestack_vm_ftctl
Version:        %{?version}%{!?version:0.0.0}
Release:        %{?release}%{!?release:1}
Summary:        ABLESTACK VM HA/DR/FT controller (ftctl add-on)

License:        Apache-2.0
URL:            https://github.com/ablecloud-team/ablestack-qemu-exec-tools
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

BuildRequires:  systemd-rpm-macros
Requires:       bash
Requires:       bash-completion
Requires:       coreutils
Requires:       findutils
Requires:       iputils
Requires:       jq
Requires:       libvirt-client
Requires:       openssh-clients
Requires:       python3
Requires:       qemu-img
Requires:       firewalld
Requires:       nmap-ncat
Requires:       socat
Requires:       systemd
Requires:       util-linux

%{?systemd_requires}

%description
ablestack_vm_ftctl provides an ABLESTACK host-side controller for VM protection
workflows including HA/DR blockcopy orchestration, standby domain preparation,
cluster inventory management, fencing abstraction, and FT/x-colo orchestration.

%prep
%setup -q

%build
:

%install
rm -rf %{buildroot}

%{!?_unitdir: %{error: systemd unitdir macro (_unitdir) is not defined. Install systemd-rpm-macros.}}

install -d %{buildroot}/usr/local/bin
install -m 0755 bin/ablestack_vm_ftctl.sh %{buildroot}/usr/local/bin/ablestack_vm_ftctl
install -m 0755 bin/ablestack_vm_ftctl_selftest.sh %{buildroot}/usr/local/bin/ablestack_vm_ftctl_selftest
install -m 0755 bin/ablestack_vm_ftctl_firewalld.sh %{buildroot}/usr/local/bin/ablestack_vm_ftctl_firewalld

install -d %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/ftctl
cp -a lib/ftctl/* %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/ftctl/
find %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/ftctl -type f -name "*.sh" -exec chmod 0755 {} \;

install -d %{buildroot}/etc/ablestack
install -m 0644 etc/ablestack-vm-ftctl.conf %{buildroot}/etc/ablestack/ablestack-vm-ftctl.conf
install -m 0644 etc/ablestack-vm-ftctl-cluster.conf %{buildroot}/etc/ablestack/ablestack-vm-ftctl-cluster.conf
install -d %{buildroot}/etc/ablestack/ftctl-cluster.d/hosts

install -d %{buildroot}%{_unitdir}
install -m 0644 lib/ftctl/systemd/ablestack-vm-ftctl.service %{buildroot}%{_unitdir}/ablestack-vm-ftctl.service
install -m 0644 lib/ftctl/systemd/ablestack-vm-ftctl.timer %{buildroot}%{_unitdir}/ablestack-vm-ftctl.timer

install -d %{buildroot}%{_datadir}/bash-completion/completions
install -m 0644 completions/%{name} %{buildroot}%{_datadir}/bash-completion/completions/%{name}

%post
%systemd_post ablestack-vm-ftctl.service
%systemd_post ablestack-vm-ftctl.timer
if [ -x /usr/local/bin/ablestack_vm_ftctl_firewalld ]; then
  /usr/local/bin/ablestack_vm_ftctl_firewalld apply >/dev/null 2>&1 || true
fi

%preun
%systemd_preun ablestack-vm-ftctl.service
%systemd_preun ablestack-vm-ftctl.timer

%postun
%systemd_postun_with_restart ablestack-vm-ftctl.service
%systemd_postun_with_restart ablestack-vm-ftctl.timer
if [ "$1" -eq 0 ] && [ -x /usr/local/bin/ablestack_vm_ftctl_firewalld ]; then
  /usr/local/bin/ablestack_vm_ftctl_firewalld remove >/dev/null 2>&1 || true
fi

%files
%license LICENSE
/usr/local/bin/ablestack_vm_ftctl
/usr/local/bin/ablestack_vm_ftctl_selftest
/usr/local/bin/ablestack_vm_ftctl_firewalld
/usr/local/lib/ablestack-qemu-exec-tools/ftctl/
%config(noreplace) /etc/ablestack/ablestack-vm-ftctl.conf
%config(noreplace) /etc/ablestack/ablestack-vm-ftctl-cluster.conf
%dir /etc/ablestack/ftctl-cluster.d
%dir /etc/ablestack/ftctl-cluster.d/hosts
%{_unitdir}/ablestack-vm-ftctl.service
%{_unitdir}/ablestack-vm-ftctl.timer
%{_datadir}/bash-completion/completions/%{name}

%changelog
* Sat Mar 28 2026 ABLECLOUD <dev@ablecloud.io> - %{version}-%{release}
- Add RPM packaging for ablestack_vm_ftctl (controller, configs, units, completion, selftest)
