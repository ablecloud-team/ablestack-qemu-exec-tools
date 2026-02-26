Name:           ablestack_vm_hangctl
Version:        %{?version}%{!?version:0.0.0}
Release:        %{?release}%{!?release:1}
Summary:        ABLESTACK VM hang controller (scan/probe/dump/destroy + libvirtd safety)

License:        Apache-2.0
URL:            https://github.com/ablecloud-team/ablestack-qemu-exec-tools
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

BuildRequires:  systemd-rpm-macros
Requires:       bash
Requires:       coreutils
Requires:       findutils
Requires:       jq
Requires:       libvirt-client
Requires:       systemd

# systemd scriptlet ordering/requires must be in preamble (NOT in prep/install script sections)
%{?systemd_requires}

%description
ablestack_vm_hangctl provides automated handling for hung libvirt/QEMU domains:
scan/probe, evidence collection (including memory dump), destroy/kill escalation,
and libvirtd health safety logic. This RPM ships systemd oneshot+timer units
for production operation.

%prep
%setup -q

%build
:

%install
rm -rf %{buildroot}

# Fail fast if systemd macros are missing
%{!?_unitdir: %{error: systemd unitdir macro (_unitdir) is not defined. Install systemd-rpm-macros.}}

# Binaries: keep /usr/local/bin convention to match existing toolchain layout.
install -d %{buildroot}/usr/local/bin
if [ -f "bin/ablestack_vm_hangctl.sh" ]; then
  install -m 0755 "bin/ablestack_vm_hangctl.sh" %{buildroot}/usr/local/bin/ablestack_vm_hangctl
elif [ -f "ablestack_vm_hangctl.sh" ]; then
  install -m 0755 "ablestack_vm_hangctl.sh" %{buildroot}/usr/local/bin/ablestack_vm_hangctl
else
  echo "[ERR] ablestack_vm_hangctl.sh not found (expected bin/ablestack_vm_hangctl.sh or ./ablestack_vm_hangctl.sh)" >&2
  exit 2
fi

# Libraries (hangctl only)
install -d %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/hangctl
cp -a lib/hangctl/* %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/hangctl/
find %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/hangctl -type f -name "*.sh" -exec chmod 0755 {} \;

# Default config
install -d %{buildroot}/etc/ablestack
install -m 0644 etc/ablestack-vm-hangctl.conf %{buildroot}/etc/ablestack/ablestack-vm-hangctl.conf

# systemd unit files
install -d %{buildroot}%{_unitdir}
install -m 0644 lib/hangctl/systemd/ablestack-vm-hangctl.service %{buildroot}%{_unitdir}/ablestack-vm-hangctl.service
install -m 0644 lib/hangctl/systemd/ablestack-vm-hangctl.timer %{buildroot}%{_unitdir}/ablestack-vm-hangctl.timer

%post
%systemd_post ablestack-vm-hangctl.service
%systemd_post ablestack-vm-hangctl.timer
if [ $1 -eq 1 ]; then
  # fresh install only (not upgrade)
  systemctl enable --now ablestack-vm-hangctl.timer >/dev/null 2>&1 || :
fi

%preun
%systemd_preun ablestack-vm-hangctl.service
%systemd_preun ablestack-vm-hangctl.timer

%postun
%systemd_postun_with_restart ablestack-vm-hangctl.service
%systemd_postun_with_restart ablestack-vm-hangctl.timer

%files
%license LICENSE
/usr/local/bin/ablestack_vm_hangctl
/usr/local/lib/ablestack-qemu-exec-tools/hangctl/
%config(noreplace) /etc/ablestack/ablestack-vm-hangctl.conf
%{_unitdir}/ablestack-vm-hangctl.service
%{_unitdir}/ablestack-vm-hangctl.timer

%changelog
* Sat Feb 15 2026 ABLECLOUD <dev@ablecloud.io> - %{version}-%{release}
- Add systemd oneshot+timer units and RPM packaging for ablestack_vm_hangctl
