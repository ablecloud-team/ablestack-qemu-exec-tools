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

    # cloud.cfg.d가 없으면 생성
    sudo mkdir -p "$CFGD_DIR"

    # 기존 datasource_list 삭제(충돌 방지)
    sudo sed -i '/^datasource_list:/d' "$MAIN_CFG" 2>/dev/null

    # 99_ablestack_datasource.cfg에 datasource_list 작성 (최우선 적용)
    echo "datasource_list: [ ConfigDrive, CloudStack ]" | sudo tee "$CUSTOM_CFG" >/dev/null

    msg "[INFO] metadata provider를 ConfigDrive, CloudStack으로 지정 완료" "[INFO] Metadata provider specified as ConfigDrive, CloudStack"
}

patch_cloud_cfg_users_root() {
    CFG="/etc/cloud/cloud.cfg"

    if [ ! -f "$CFG" ]; then
        msg "[ERROR] $CFG 파일이 존재하지 않습니다." "[ERROR] $CFG file does not exist."
        return 1
    fi

    # 백업
    sudo cp -a "$CFG" "$CFG.ablestack.bak"

    # users: ~ 섹션을 모두 주석처리 또는 삭제 후 users: - root 추가
    # 기존 users: ... - default  등 패턴을 치환
    if grep -q "^users:" "$CFG"; then
        # users:부터 다음 상위 키 또는 파일 끝까지 삭제 후 users: - root로 대체
        sudo awk '
            BEGIN {inusers=0}
            /^users:/ {print "users:"; print "  - root"; inusers=1; next}
            /^[^[:space:]]/ {inusers=0}
            !inusers
        ' "$CFG" > "$CFG.tmp" && sudo mv "$CFG.tmp" "$CFG"
    else
        echo -e "\nusers:\n  - root" | sudo tee -a "$CFG" >/dev/null
    fi

    msg "[INFO] cloud.cfg의 users 항목을 root로 변경 완료" "[INFO] Completed changing users entry in cloud.cfg to root"
}

set_cloud_cfg_everyboot() {
    CFGD="/etc/cloud/cloud.cfg.d"
    CFG="$CFGD/99_ablestack_everyboot.cfg"
    sudo mkdir -p "$CFGD"

    # always_run_init_modules로 cloud_init_modules 매 부팅마다 실행
    cat <<EOF | sudo tee "$CFG" >/dev/null
# ablestack: cloud-init every boot 적용
always_run_init_modules: true
EOF

    msg "[INFO] cloud-init의 cloud_init_modules (ssh-key, password, runcmd, hostname 등) 매 부팅마다 실행 설정 완료" \
        "[INFO] Setting up cloud-init's cloud_init_modules (ssh-key, password, runcmd, hostname, etc.) to run on every boot completed"
}

patch_cloud_init_modules_frequency_partial() {
    CFG="/etc/cloud/cloud.cfg"
    sudo cp -a "$CFG" "$CFG.ablestack.bak"

    # 패치 대상 모듈
    modules_to_always=(set_hostname set_passwords ssh runcmd)

    # awk로 cloud_init_modules 블록만 수정
    sudo awk -v mods="$(IFS=,; echo "${modules_to_always[*]}")" '
    BEGIN {
        split(mods, always_mods, ",");
        for (i in always_mods) always_map[always_mods[i]] = 1;
    }
    /^cloud_init_modules:/ {inblock=1}
    inblock && /^[^[:space:]]/ {inblock=0}
    {
        if (!inblock) print $0;
        else if ($1 ~ /^-/) {
            # 모듈명 추출
            gsub("^- *", "", $1);
            gsub(",", "", $1);
            mod=$1;
            if (mod in always_map) {
                print "  - [" mod ", always]";
            } else {
                print "  - " mod;
            }
        }
    }
    ' "$CFG" > "$CFG.tmp" && sudo mv "$CFG.tmp" "$CFG"

    msg "[INFO] cloud_init_modules: set_hostname, set_passwords, ssh, runcmd 만 always로 지정 완료" \
        "[INFO] cloud_init_modules: set_hostname, set_passwords, ssh, runcmd only specified as always"
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