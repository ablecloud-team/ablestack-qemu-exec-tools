#!/bin/bash
#
# ablestack-qemu-exec-tools cloud_init_auto.sh
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

LIB_DIR="$(dirname "$0")/../lib"
. "$LIB_DIR/cloud_init_common.sh"

echo "[INFO] cloud-init 설치 확인 중..."
if check_cloud_init_installed; then
    echo "[INFO] cloud-init이 이미 설치되어 있습니다."
else
    echo "[INFO] cloud-init이 설치되어 있지 않아 설치를 진행합니다."
    install_cloud_init || { echo "[ERROR] cloud-init 설치 실패!"; exit 1; }
fi

echo "[INFO] metadata provider를 ConfigDrive, CloudStack으로 지정합니다..."
set_metadata_provider_configdrive_cloudstack

echo "[INFO] cloud.cfg에서 users 항목을 root로 설정합니다..."
patch_cloud_cfg_users_root

echo "[INFO] cloud-init의 cloud_init_modules를 매 부팅마다 실행하도록 설정합니다..."
set_cloud_cfg_everyboot

echo "[INFO] set_hostname, set_passwords, ssh, runcmd 항목만 매 부팅(always) 실행으로 패치합니다..."
patch_cloud_init_modules_frequency_partial

print_final_message
exit 0