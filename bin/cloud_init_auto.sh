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

LIBDIR="/usr/libexec/ablestack-qemu-exec-tools"
source "$LIBDIR/cloud_init_common.sh"

msg "[INFO] cloud-init 설치 확인 중..." "[INFO] Checking cloud-init installation..."
if check_cloud_init_installed; then
    msg "[INFO] cloud-init이 이미 설치되어 있습니다." "[INFO] cloud-init is already installed."
else
    msg "[INFO] cloud-init이 설치되어 있지 않아 설치를 진행합니다." \
        "[INFO] cloud-init is not installed, so installation will proceed."
    install_cloud_init || { msg "[ERROR] cloud-init 설치 실패!" "[ERROR] cloud-init installation failed!"; exit 1; }
fi

msg "[INFO] metadata provider를 ConfigDrive로 지정합니다..." \
    "[INFO] Specify metadata provider as ConfigDrive..."
set_metadata_provider_configdrive_cloudstack

msg "[INFO] cloud.cfg에서 users 항목을 root로 설정합니다..." \
    "[INFO] Set users entry to root in cloud.cfg..."
patch_cloud_cfg_users_root

msg "[INFO] set_hostname, set_passwords, ssh, runcmd 항목만 매 부팅(always) 실행으로 패치합니다..." \
    "[INFO] Patch only set_hostname, set_passwords, ssh, runcmd items to always run on every boot..."
patch_cloud_init_and_config_modules_frequency_partial

msg "[INFO] cloud-init 초기화 설정을 가상머신 셧다운 시에 재설정(clean) 하도록 서비스를 등록합니다." \
    "[INFO] Register a service to reset (clean) cloud-init initialization settings when the virtual machine is shut down."
setup_cloud_init_clean_on_shutdown

print_final_message
exit 0