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

# cloud-init dhcp.py fix
mkdir -p %{buildroot}/usr/share/ablestack-qemu-exec-tools
cp -a rpm/dhcp.py.fixed %{buildroot}/usr/share/ablestack-qemu-exec-tools/ 2>/dev/null || :

%files
%license LICENSE
%doc README.md docs/* examples/* usage_agent_policy_fix.md
/usr/bin/vm_exec
/usr/bin/agent_policy_fix
/usr/bin/cloud_init_auto
/usr/bin/install_ablestack_qemu_exec_tools
/usr/libexec/%{name}/*
/usr/share/ablestack-qemu-exec-tools/dhcp.py.fixed

%changelog
* Wed Jul 10 2025 ABLECLOUD <dev@ablecloud.io> %{version}-%{release}
- Initial packaging with vm_exec.sh, agent_policy_fix.sh, cloud_init_auto.sh
- Git hash: %{githash}

%post
echo "[INFO] Running post-install tasks for %{name}..."

_is_ablestack_host() {
    if [ -f /etc/os-release ]; then
        if grep -q '^PRETTY_NAME="ABLESTACK' /etc/os-release 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

if _is_ablestack_host; then
    echo "[INFO] ABLESTACK Host detected - skip guest cloud-init customization (agent_policy_fix, cloud_init_auto, dhcpcd, dhcp.py patch)."
    # 여기서 바로 종료 → 아래 기존 guest용 작업은 실행 안 함
    exit 0
fi

echo "[INFO] ablestack-qemu-exec-tools post install start (guest VM)"

# agent_policy_fix / cloud_init_auto 실행
if [ -x /usr/bin/agent_policy_fix ]; then
    /usr/bin/agent_policy_fix || echo "[WARN] agent_policy_fix failed"
fi
if [ -x /usr/bin/cloud_init_auto ]; then
    /usr/bin/cloud_init_auto || echo "[WARN] cloud_init_auto failed"
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" =~ (rocky|rhel) && "$VERSION_ID" =~ ^10 ]]; then
        echo "[INFO] Detected $ID $VERSION_ID, enabling dhcpcd and replacing cloud-init dhcp.py..."

        # dhcpcd enable (not start)
        systemctl enable dhcpcd.service >/dev/null 2>&1 || true

        # cloud-init dhcp.py 위치 찾기
        PATCH_FILE=$(python3 -c "import cloudinit.net.dhcp as d; print(d.__file__)" 2>/dev/null || true)
        if [ -z "$PATCH_FILE" ] || [ ! -f "$PATCH_FILE" ]; then
            PATCH_FILE=$(find /usr/lib /usr/lib64 -path "*/site-packages/cloudinit/net/dhcp.py" 2>/dev/null | head -n1)
        fi

        FIXED_FILE="/usr/share/ablestack-qemu-exec-tools/dhcp.py.fixed"

        if [ -n "$PATCH_FILE" ] && [ -f "$PATCH_FILE" ] && [ -f "$FIXED_FILE" ]; then
            cp -n "$PATCH_FILE" "${PATCH_FILE}.bak"
            cp -f "$FIXED_FILE" "$PATCH_FILE"
            echo "[INFO] cloud-init dhcp.py replaced successfully: $PATCH_FILE"

            # --- 추가: 교체된 dhcp.py 관련 파이썬 캐시 삭제 ---
            PY_DIR="$(dirname "$PATCH_FILE")"
            PY_BASE="$(basename "$PATCH_FILE" .py)"

            # __pycache__ 아래 해당 모듈 캐시 제거
            if [ -d "${PY_DIR}/__pycache__" ]; then
                rm -f "${PY_DIR}/__pycache__/${PY_BASE}."* 2>/dev/null || true
            fi
            # 같은 디렉터리에 직접 생성된 *.pyc 가 있다면 제거
            rm -f "${PY_DIR}/${PY_BASE}.pyc" 2>/dev/null || true
            # ------------------------------------------------
        else
            echo "[WARN] dhcp.py replacement skipped (file not found)"
        fi

        systemctl daemon-reexec
        systemctl daemon-reload
    fi
fi

#        # cloud-init service override
#        mkdir -p /etc/systemd/system/cloud-init.service.d
#        cat > /etc/systemd/system/cloud-init.service.d/override.conf <<'EOF'
#[Unit]
## Re-declare Before= but without network-online.target
#Wants=cloud-init-local.service sshd-keygen.service sshd.service network-online.target
#After=cloud-init-local.service systemd-networkd-wait-online.service network-online.target
#Before=sshd-keygen.service sshd.service systemd-user-session.service
#EOF