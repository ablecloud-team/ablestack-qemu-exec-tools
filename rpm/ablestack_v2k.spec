# ablestack-v2k.spec - RPM spec for ablestack-v2k (V2K add-on)
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

Name:           ablestack-v2k
Version:        %{version}
Release:        %{release}
Summary:        ABLESTACK VMware-to-KVM migration tool (V2K add-on)

License:        Apache-2.0
URL:            https://github.com/ablecloud-team/ablestack-qemu-exec-tools
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       bash
Requires:       jq
Requires:       python3
Requires:       openssl
Requires:       nbd
Requires:       nbdkit
Requires:       nbdkit-vddk-plugin
Requires:       qemu-img
Requires:       libvirt-client

%description
ablestack-v2k provides ABLESTACK VMware-to-KVM (V2K) migration scripts and libraries.
Assets such as VDDK and govc are handled by the offline ISO installer.

%prep
%setup -q

%install
# Binaries (explicit path: /usr/local/bin)
mkdir -p %{buildroot}/usr/local/bin
install -m 0755 bin/ablestack_v2k.sh %{buildroot}/usr/local/bin/ablestack_v2k

# Libraries (explicit path: /usr/local/lib/ablestack-qemu-exec-tools/v2k)
mkdir -p %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/v2k
cp -a lib/v2k/* %{buildroot}/usr/local/lib/ablestack-qemu-exec-tools/v2k/ 2>/dev/null || :

%files



%license LICENSE
/usr/local/bin/ablestack_v2k
/usr/local/lib/ablestack-qemu-exec-tools/v2k/*

%changelog
* Sun Jan 11 2026 ABLECLOUD <dev@ablecloud.io> %{version}-%{release}
- Initial packaging for ablestack-v2k (scripts + lib/v2k)
- Git hash: %{githash}
