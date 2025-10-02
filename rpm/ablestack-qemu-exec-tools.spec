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

# agent_policy_fix / cloud_init_auto 실행
if [ -x /usr/bin/agent_policy_fix ]; then
    /usr/bin/agent_policy_fix || echo "[WARN] agent_policy_fix failed"
fi
if [ -x /usr/bin/cloud_init_auto ]; then
    /usr/bin/cloud_init_auto || echo "[WARN] cloud_init_auto failed"
fi

# ----- Rocky/RHEL 10 전용 dhcpcd + dhcp.py 패치 -----
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" =~ (rocky|rhel) && "$VERSION_ID" =~ ^10 ]]; then
        echo "[INFO] Detected $ID $VERSION_ID, enabling dhcpcd and patching cloud-init dhcp.py..."

        # 1. dhcpcd 서비스 활성화
        systemctl enable dhcpcd.service >/dev/null 2>&1 || true

        # 2. dhcp.py 패치
        PATCH_FILE="/usr/lib/python3.12/site-packages/cloudinit/net/dhcp.py"
        if [ -f "$PATCH_FILE" ]; then
            cp -n "$PATCH_FILE" "${PATCH_FILE}.bak"

            patch -N "$PATCH_FILE" >/dev/null 2>&1 <<'EOF'
*** dhcp.py.orig   2025-10-01 00:00:00.000000000 +0000
--- dhcp.py        2025-10-02 00:00:00.000000000 +0000
@@ class Dhcpcd(DHCPClient):
-    def get_newest_lease(self, interface: str) -> Dict[str, Any]:
-        """Return a dict of dhcp options.
-        ...
-        return self.parse_dhcpcd_lease(lease_dump, interface)
+    def get_newest_lease(self, interface: str) -> Dict[str, Any]:
+        """Return a dict of dhcp options with fallback for Rocky/RHEL 10."""
+        try:
+            lease_dump = subp.subp(
+                [self.client_name, "--dumplease", "--ipv4only", interface],
+            ).stdout
+
+            if not lease_dump.strip():
+                LOG.warning("Empty lease dump for %s, fallback to lease file", interface)
+                lease_file = f"/var/lib/dhcpcd/{interface}.lease"
+                try:
+                    dhcp_message = util.load_binary_file(lease_file)
+                    lease = {"interface": interface, "lease-file": lease_file}
+                    try:
+                        opt_50 = Dhcpcd.parse_unknown_options_from_packet(dhcp_message, 50)
+                        if opt_50:
+                            lease["ip-address"] = socket.inet_ntoa(opt_50)
+                        opt_3 = Dhcpcd.parse_unknown_options_from_packet(dhcp_message, 3)
+                        if opt_3:
+                            lease["routers"] = socket.inet_ntoa(opt_3)
+                        opt_12 = Dhcpcd.parse_unknown_options_from_packet(dhcp_message, 12)
+                        if opt_12:
+                            lease["host-name"] = opt_12.decode(errors="ignore")
+                    except Exception as e:
+                        LOG.warning("Partial DHCP parse error from %s: %s", lease_file, e)
+                    return lease
+                except Exception as e:
+                    LOG.error("Fallback lease file unusable: %s", e)
+                    raise InvalidDHCPLeaseFileError("Empty lease dump and fallback failed")
+
+            return self.parse_dhcpcd_lease(lease_dump, interface)
+
+        except subp.ProcessExecutionError as error:
+            LOG.debug(
+                "dhcpcd exited with code: %s stderr: %r stdout: %r",
+                error.exit_code, error.stderr, error.stdout,
+            )
+            raise NoDHCPLeaseError from error
EOF
            echo "[INFO] cloud-init dhcp.py patch applied successfully"
        else
            echo "[WARN] cloud-init dhcp.py not found, patch skipped"
        fi
    fi
fi
