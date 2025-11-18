#!/bin/bash
#
# ablestack-qemu-exec-tools cloud_init_common.sh
#
# Copyright 2025 ABLECLOUD
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

# ===== [공통] 로케일 감지 및 메시지 출력 함수 =====
_detect_locale() {
    _LOCALE="$(locale 2>/dev/null | grep LANG= | cut -d= -f2 | cut -d. -f1)"
    case "$_LOCALE" in
        ko_KR|ko|ko_KR_*) _IS_KO=1 ;;
        *) _IS_KO=0 ;;
    esac
}
_detect_locale

msg() {
    local ko="$1"
    local en="$2"
    if [ "$_IS_KO" = "1" ]; then
        echo "$ko"
    else
        echo "$en"
    fi
}

check_cloud_init_installed() {
    if command -v cloud-init >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

install_cloud_init() {
    # OS 감지
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_id="${ID,,}"
    else
        msg "[ERROR] /etc/os-release 파일이 없어 OS 감지에 실패했습니다." \
            "[ERROR] /etc/os-release not found! Failed to detect OS." >&2
        return 1
    fi

    case "$os_id" in
        rocky|rhel|centos|almalinux)
            msg "[INFO] cloud-init을 yum으로 설치합니다." "[INFO] Installing cloud-init with yum."
            sudo yum install -y cloud-init
            ;;
        ubuntu|debian)
            msg "[INFO] cloud-init을 apt로 설치합니다." "[INFO] Installing cloud-init with apt."
            sudo apt-get update
            sudo apt-get install -y cloud-init
            ;;
        *)
            msg "[ERROR] 지원하지 않는 OS: $os_id" "[ERROR] Unsupported OS: $os_id" >&2
            return 1
            ;;
    esac
}

set_metadata_provider_configdrive_cloudstack() {
    # cloud-init config 위치
    CFG_DIR="/etc/cloud"
    MAIN_CFG="$CFG_DIR/cloud.cfg"
    CFGD_DIR="$CFG_DIR/cloud.cfg.d"
    CUSTOM_CFG="$CFGD_DIR/99_ablestack_datasource.cfg"
    DSIDENTIFY_CFG="$CFG_DIR/ds-identify.cfg"

    # cloud.cfg.d가 없으면 생성
    sudo mkdir -p "$CFGD_DIR"

    # 기존 datasource_list 삭제(충돌 방지)
    sudo sed -i '/^datasource_list:/d' "$MAIN_CFG" 2>/dev/null

    # 99_ablestack_datasource.cfg에 datasource_list 작성 (최우선 적용)
    sudo tee "$CUSTOM_CFG" >/dev/null <<EOF
datasource_list: [ CloudStack, ConfigDrive, None ]
datasource:
  CloudStack:
    max_wait: 10
    timeout: 5
  ConfigDrive: {}
  None: {}
EOF

    # cloud-init 초기화
    sudo cloud-init clean --logs

    # ds-identify.cfg에 policy: enabled 기록 (기존 내용 제거 후 새로 작성)
    echo "policy: enabled" | sudo tee "$DSIDENTIFY_CFG" >/dev/null

    msg "[INFO] metadata provider를 ConfigDrive, CloudStack, None 지정 완료" "[INFO] Metadata provider specified as ConfigDrive, CloudStack, None"
}

patch_cloud_cfg_users_root() {
    CFG="/etc/cloud/cloud.cfg"
    sudo cp -a "$CFG" "$CFG.ablestack.bak"

    # 시스템 ID 추출
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_id="${ID,,}"
    else
        os_id="unknown"
    fi

    TMP="$(mktemp)"
    in_sysinfo=0
    sysinfo_done=0
    while IFS= read -r line; do
        # system_info 블록 시작 감지
        if [[ "$line" =~ ^system_info: ]]; then
            in_sysinfo=1
            sysinfo_done=1
            echo "$line" >> "$TMP"
            # 다음 줄에 원하는 내용을 직접 추가
            echo "  # This will affect which distro class gets used" >> "$TMP"
            echo "  distro: $os_id" >> "$TMP"
            echo "  # Default user name + that default users groups (if added/used)" >> "$TMP"
            echo "  default_user:" >> "$TMP"
            echo "    name: root" >> "$TMP"
            echo "    lock_passwd: false" >> "$TMP"
            echo "    gecos: root" >> "$TMP"
            echo "    groups: [root, adm, systemd-journal]" >> "$TMP"
            echo "    sudo: [\"ALL=(ALL) NOPASSWD:ALL\"]" >> "$TMP"
            echo "    shell: /bin/bash" >> "$TMP"
            echo "  network:" >> "$TMP"
            echo "    renderers: ['eni', 'netplan', 'network-manager', 'sysconfig', 'networkd']" >> "$TMP"
            echo "  # Other config here will be given to the distro class and/or path classes" >> "$TMP"
            echo "  paths:" >> "$TMP"
            echo "    cloud_dir: /var/lib/cloud/" >> "$TMP"
            echo "    templates_dir: /etc/cloud/templates/" >> "$TMP"
            echo "  ssh_svcname: sshd" >> "$TMP"
            # system_info 아래 기존 내용은 모두 스킵
            continue
        fi
        # system_info 블록 내부는 건너뜀
        if [[ $in_sysinfo -eq 1 ]]; then
            # 다음 상위 섹션(비인덴트 줄, 예: #, users:, cloud_init_modules:)에서 끝냄
            if [[ "$line" =~ ^[^[:space:]] ]]; then
                in_sysinfo=0
                echo "$line" >> "$TMP"
            fi
            continue
        fi
        # 나머지 줄은 그대로 복사
        echo "$line" >> "$TMP"
    done < "$CFG"

    # 만약 system_info가 아예 없었다면, 마지막에 추가
    if [[ $sysinfo_done -eq 0 ]]; then
        echo "" >> "$TMP"
        echo "system_info:" >> "$TMP"
        echo "  # This will affect which distro class gets used" >> "$TMP"
        echo "  distro: $os_id" >> "$TMP"
        echo "  # Default user name + that default users groups (if added/used)" >> "$TMP"
        echo "  default_user:" >> "$TMP"
        echo "    name: root" >> "$TMP"
        echo "    lock_passwd: false" >> "$TMP"
        echo "    gecos: root" >> "$TMP"
        echo "    groups: [root, adm, systemd-journal]" >> "$TMP"
        echo "    sudo: [\"ALL=(ALL) NOPASSWD:ALL\"]" >> "$TMP"
        echo "    shell: /bin/bash" >> "$TMP"
        echo "  network:" >> "$TMP"
        echo "    renderers: ['eni', 'netplan', 'network-manager', 'sysconfig', 'networkd']" >> "$TMP"
        echo "  # Other config here will be given to the distro class and/or path classes" >> "$TMP"
        echo "  paths:" >> "$TMP"
        echo "    cloud_dir: /var/lib/cloud/" >> "$TMP"
        echo "    templates_dir: /etc/cloud/templates/" >> "$TMP"
        echo "  ssh_svcname: sshd" >> "$TMP"

    fi

    sudo mv "$TMP" "$CFG"

    msg "[INFO] system_info 블록(distro, default_user)만 패치 완료, users는 그대로 유지" \
        "[INFO] Only patched system_info block (distro, default_user); users left as-is"

    # 2. disable_root: 값을 false로 교체 (존재시 치환, 없으면 루트 레벨 마지막에 추가)
    if grep -q '^disable_root:' "$CFG"; then
        sudo sed -i 's/^disable_root:.*$/disable_root: false/' "$CFG"
    else
        # 맨 마지막 users: 뒤가 아니라, 파일 마지막에 추가
        echo "disable_root: false" | sudo tee -a "$CFG" >/dev/null
    fi

    # 3. ssh_pwauth: 값을 true로 교체 (존재시 치환, 없으면 루트 레벨 마지막에 추가)
    if grep -q '^ssh_pwauth:' "$CFG"; then
        sudo sed -i 's/^ssh_pwauth:.*$/ssh_pwauth: true/' "$CFG"
    else
        echo "ssh_pwauth: true" | sudo tee -a "$CFG" >/dev/null
    fi

    msg "[INFO] users, disable_root, ssh_pwauth 항목이 root/false/true로 패치 완료" \
        "[INFO] users, disable_root, ssh_pwauth have been patched to root/false/true"
}

patch_cloud_init_and_config_modules_frequency_partial() {
    CFG="/etc/cloud/cloud.cfg"
    sudo cp -a "$CFG" "$CFG.ablestack.bak.freq"

    # 각 블록별 패치 대상 지정
    modules_to_always_init=(set_hostname set_passwords ssh)
    modules_to_always_config=(runcmd)

    TMP="$(mktemp)"
    in_block=0
    block_type=""

    while IFS= read -r line; do
        # 블록 시작 감지
        if [[ "$line" =~ ^cloud_init_modules: ]]; then
            in_block=1
            block_type="init"
            echo "$line" >> "$TMP"
            continue
        fi
        if [[ "$line" =~ ^cloud_config_modules: ]]; then
            in_block=1
            block_type="config"
            echo "$line" >> "$TMP"
            continue
        fi

        # 블록 내부
        if [[ $in_block -eq 1 ]]; then
            # 블록 종료 감지(최상위 키)
            if [[ "$line" =~ ^[^[:space:]] && ! "$line" =~ ^- ]]; then
                in_block=0
                block_type=""
                echo "$line" >> "$TMP"
                continue
            fi

            # - 모듈명 항목만 패치
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*([a-zA-Z0-9_]+) ]]; then
                mod="${BASH_REMATCH[1]}"
                patch=0
                if [[ "$block_type" == "init" ]]; then
                    for tmod in "${modules_to_always_init[@]}"; do
                        if [[ "$mod" == "$tmod" ]]; then patch=1; fi
                    done
                elif [[ "$block_type" == "config" ]]; then
                    for tmod in "${modules_to_always_config[@]}"; do
                        if [[ "$mod" == "$tmod" ]]; then patch=1; fi
                    done
                fi
                if [[ $patch -eq 1 ]]; then
                    indent=$(echo "$line" | grep -o '^[[:space:]]*')
                    echo "${indent}- [ $mod, always ]" >> "$TMP"
                else
                    echo "$line" >> "$TMP"
                fi
            else
                echo "$line" >> "$TMP"
            fi
            continue
        fi

        # 블록 외에는 그대로
        echo "$line" >> "$TMP"
    done < "$CFG"

    sudo mv "$TMP" "$CFG"

    msg "[INFO] 지정된 모듈만 always로 패치 완료 (cloud_init_modules, cloud_config_modules)" \
        "[INFO] Only the specified modules set to always (cloud_init_modules, cloud_config_modules)."
}

setup_cloud_init_clean_on_shutdown() {
    UNIT_PATH="/etc/systemd/system/cloud-init-clean-shutdown.service"
    sudo tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=Cloud-init clean at shutdown
DefaultDependencies=no
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cloud-init clean --logs
ExecStart=/usr/bin/cloud-init init --local

[Install]
WantedBy=shutdown.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable cloud-init-clean-shutdown.service

    msg "[INFO] cloud-init clean이 가상머신 종료 시점에 자동으로 실행되도록 systemd 서비스가 설정되었습니다." \
        "[INFO] cloud-init clean will now run automatically at VM shutdown (systemd service configured)."
}


print_final_message() {
    # 현재 OS 로케일 감지
    locale="$(locale 2>/dev/null | grep LANG= | cut -d= -f2 | cut -d. -f1)"
    case "$locale" in 
        ko_KR|ko|ko_KR_*) # 한국어 로케일일 때
            echo "---------------------------------------------"
            echo "[INFO] 모든 cloud-init 자동화 설정이 완료되었습니다."
            echo "[INFO] 이제 아래 순서로 VM을 마무리하세요:"
            echo
            echo "  1. 가상머신을 셧다운(shutdown) 하십시오."
            echo "  2. 종료된 VM을 템플릿으로 등록 또는 이미지로 변환하십시오."
            echo
            echo "※ 템플릿/이미지에서 신규 VM을 만들면, cloud-init이 부팅마다 최신 메타데이터를 자동 적용합니다."
            echo "---------------------------------------------"
            ;;
        *)
            echo "---------------------------------------------"
            echo "[INFO] All cloud-init automation settings are complete."
            echo "[INFO] Please finish preparing the VM as follows:"
            echo
            echo "  1. Shutdown the virtual machine."
            echo "  2. Register the shut-down VM as a template or convert it to an image."
            echo
            echo "* When you deploy new VMs from this template/image, cloud-init will apply the latest metadata at each boot."
            echo "---------------------------------------------"
            ;;
    esac
}