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

# ===== [ê³µí†µ] ë¡œì???ê°ì? ë°?ë©”ì‹œì§€ ì¶œë ¥ ?¨ìˆ˜ =====
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
    # OS ê°ì?
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_id="${ID,,}"
    else
        msg "[ERROR] /etc/os-release ?Œì¼???†ì–´ OS ê°ì????¤íŒ¨?ˆìŠµ?ˆë‹¤." \
            "[ERROR] /etc/os-release not found! Failed to detect OS." >&2
        return 1
    fi

    case "$os_id" in
        rocky|rhel|centos|almalinux)
            msg "[INFO] cloud-init??yum?¼ë¡œ ?¤ì¹˜?©ë‹ˆ??" "[INFO] Installing cloud-init with yum."
            sudo yum install -y cloud-init
            ;;
        ubuntu|debian)
            msg "[INFO] cloud-init??aptë¡??¤ì¹˜?©ë‹ˆ??" "[INFO] Installing cloud-init with apt."
            sudo apt-get update
            sudo apt-get install -y cloud-init
            ;;
        *)
            msg "[ERROR] ì§€?í•˜ì§€ ?ŠëŠ” OS: $os_id" "[ERROR] Unsupported OS: $os_id" >&2
            return 1
            ;;
    esac
}

set_metadata_provider_configdrive_cloudstack() {
    # cloud-init config ?„ì¹˜
    CFG_DIR="/etc/cloud"
    MAIN_CFG="$CFG_DIR/cloud.cfg"
    CFGD_DIR="$CFG_DIR/cloud.cfg.d"
    CUSTOM_CFG="$CFGD_DIR/99_ablestack_datasource.cfg"
    DSIDENTIFY_CFG="$CFG_DIR/ds-identify.cfg"

    # cloud.cfg.dê°€ ?†ìœ¼ë©??ì„±
    sudo mkdir -p "$CFGD_DIR"

    # ê¸°ì¡´ datasource_list ?? œ(ì¶©ëŒ ë°©ì?)
    sudo sed -i '/^datasource_list:/d' "$MAIN_CFG" 2>/dev/null

    # 99_ablestack_datasource.cfg??datasource_list ?‘ì„± (ìµœìš°???ìš©)
    sudo tee "$CUSTOM_CFG" >/dev/null <<EOF
datasource_list: [ ConfigDrive, CloudStack, None ]
datasource:
  CloudStack:
    max_wait: 30
    timeout: 10
  ConfigDrive: {}
  None: {}
EOF

    # cloud-init ì´ˆê¸°??    sudo cloud-init clean --logs

    # ds-identify.cfg??policy: enabled ê¸°ë¡ (ê¸°ì¡´ ?´ìš© ?œê±° ???ˆë¡œ ?‘ì„±)
    echo "policy: enabled" | sudo tee "$DSIDENTIFY_CFG" >/dev/null

    msg "[INFO] metadata providerë¥?ConfigDrive, CloudStack, None ì§€???„ë£Œ" "[INFO] Metadata provider specified as ConfigDrive, CloudStack, None"
}

patch_cloud_cfg_users_root() {
    CFG="/etc/cloud/cloud.cfg"
    sudo cp -a "$CFG" "$CFG.ablestack.bak"

    # ?œìŠ¤??ID ì¶”ì¶œ
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
        # system_info ë¸”ë¡ ?œì‘ ê°ì?
        if [[ "$line" =~ ^system_info: ]]; then
            in_sysinfo=1
            sysinfo_done=1
            echo "$line" >> "$TMP"
            # ?¤ìŒ ì¤„ì— ?í•˜???´ìš©??ì§ì ‘ ì¶”ê?
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
            # system_info ?„ë˜ ê¸°ì¡´ ?´ìš©?€ ëª¨ë‘ ?¤í‚µ
            continue
        fi
        # system_info ë¸”ë¡ ?´ë???ê±´ë„ˆ?€
        if [[ $in_sysinfo -eq 1 ]]; then
            # ?¤ìŒ ?ìœ„ ?¹ì…˜(ë¹„ì¸?´íŠ¸ ì¤? ?? #, users:, cloud_init_modules:)?ì„œ ?ëƒ„
            if [[ "$line" =~ ^[^[:space:]] ]]; then
                in_sysinfo=0
                echo "$line" >> "$TMP"
            fi
            continue
        fi
        # ?˜ë¨¸ì§€ ì¤„ì? ê·¸ë?ë¡?ë³µì‚¬
        echo "$line" >> "$TMP"
    done < "$CFG"

    # ë§Œì•½ system_infoê°€ ?„ì˜ˆ ?†ì—ˆ?¤ë©´, ë§ˆì?ë§‰ì— ì¶”ê?
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

    msg "[INFO] system_info ë¸”ë¡(distro, default_user)ë§??¨ì¹˜ ?„ë£Œ, users??ê·¸ë?ë¡?? ì?" \
        "[INFO] Only patched system_info block (distro, default_user); users left as-is"

    # 2. disable_root: ê°’ì„ falseë¡?êµì²´ (ì¡´ì¬??ì¹˜í™˜, ?†ìœ¼ë©?ë£¨íŠ¸ ?ˆë²¨ ë§ˆì?ë§‰ì— ì¶”ê?)
    if grep -q '^disable_root:' "$CFG"; then
        sudo sed -i 's/^disable_root:.*$/disable_root: false/' "$CFG"
    else
        # ë§?ë§ˆì?ë§?users: ?¤ê? ?„ë‹ˆ?? ?Œì¼ ë§ˆì?ë§‰ì— ì¶”ê?
        echo "disable_root: false" | sudo tee -a "$CFG" >/dev/null
    fi

    # 3. ssh_pwauth: ê°’ì„ trueë¡?êµì²´ (ì¡´ì¬??ì¹˜í™˜, ?†ìœ¼ë©?ë£¨íŠ¸ ?ˆë²¨ ë§ˆì?ë§‰ì— ì¶”ê?)
    if grep -q '^ssh_pwauth:' "$CFG"; then
        sudo sed -i 's/^ssh_pwauth:.*$/ssh_pwauth: true/' "$CFG"
    else
        echo "ssh_pwauth: true" | sudo tee -a "$CFG" >/dev/null
    fi

    msg "[INFO] users, disable_root, ssh_pwauth ??ª©??root/false/trueë¡??¨ì¹˜ ?„ë£Œ" \
        "[INFO] users, disable_root, ssh_pwauth have been patched to root/false/true"
}

patch_cloud_init_and_config_modules_frequency_partial() {
    CFG="/etc/cloud/cloud.cfg"
    sudo cp -a "$CFG" "$CFG.ablestack.bak.freq"

    # ê°?ë¸”ë¡ë³??¨ì¹˜ ?€??ì§€??    modules_to_always_init=(set_hostname set_passwords ssh)
    modules_to_always_config=(runcmd)

    TMP="$(mktemp)"
    in_block=0
    block_type=""

    while IFS= read -r line; do
        # ë¸”ë¡ ?œì‘ ê°ì?
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

        # ë¸”ë¡ ?´ë?
        if [[ $in_block -eq 1 ]]; then
            # ë¸”ë¡ ì¢…ë£Œ ê°ì?(ìµœìƒ????
            if [[ "$line" =~ ^[^[:space:]] && ! "$line" =~ ^- ]]; then
                in_block=0
                block_type=""
                echo "$line" >> "$TMP"
                continue
            fi

            # - ëª¨ë“ˆëª???ª©ë§??¨ì¹˜
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

        # ë¸”ë¡ ?¸ì—??ê·¸ë?ë¡?        echo "$line" >> "$TMP"
    done < "$CFG"

    sudo mv "$TMP" "$CFG"

    msg "[INFO] ì§€?•ëœ ëª¨ë“ˆë§?alwaysë¡??¨ì¹˜ ?„ë£Œ (cloud_init_modules, cloud_config_modules)" \
        "[INFO] Only the specified modules set to always (cloud_init_modules, cloud_config_modules)."
}

setup_cloud_init_clean_on_shutdown() {
    # ?¤ì œ ?™ì‘?€ "shutdown" ???„ë‹ˆ??"ë¶€???„ë£Œ ??clean at boot)" ë¡?ë³€ê²?    # ??ê¸°ì¡´ ?´ë¦„?€ ? ì??˜ì?ë§? ?™ì‘?€ ?€??2ë²?ë°©ì‹?¼ë¡œ êµ¬í˜„

    local HELPER="/usr/local/libexec/ablestack-qemu-exec-tools/cloud_init_clean_at_boot.sh"
    local UNIT_PATH="/etc/systemd/system/ablestack-cloud-init-clean-at-boot.service"

    # ?¬í¼ ?¤í¬ë¦½íŠ¸ ?„ì¹˜ ?ì„±
    sudo mkdir -p "$(dirname "$HELPER")"

    # 1) ë¶€?????¤í–‰???¬í¼ ?¤í¬ë¦½íŠ¸ ?‘ì„±
    sudo tee "$HELPER" >/dev/null <<'EOS'
#!/bin/bash
# cloud_init_clean_at_boot.sh
# 1) /var/log/cloud-init*.log ë¥?/var/log/cloud-init/ ?„ë˜ timestamp ë°±ì—…
# 2) cloud-init clean --logs ?¤í–‰

set -euo pipefail

SRC_DIR="/var/log"
DST_DIR="/var/log/cloud-init"

mkdir -p "$DST_DIR"

ts="$(date +%Y%m%d%H%M%S)"

backup_one() {
    local src="$1"
    local base dst
    base="$(basename "$src")"

    if [ -f "$src" ]; then
        dst="${DST_DIR}/${base}.${ts}"
        # ?¼ë????Œìœ ê¶?? ì? ?œë„, ?¤íŒ¨?˜ë©´ ?¼ë°˜ cp
        if ! cp -p "$src" "$dst" 2>/dev/null; then
            cp "$src" "$dst"
        fi
    fi
}

# 1) ë¡œê·¸ ë°±ì—…
backup_one "${SRC_DIR}/cloud-init.log"
backup_one "${SRC_DIR}/cloud-init-output.log"

# 2) cloud-init clean --logs ?¤í–‰ (?¤íŒ¨?´ë„ ë¶€?…ì? ê³„ì†?˜ì–´???˜ë?ë¡?ë¬´ì‹œ)
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init clean --logs || true
fi

exit 0
EOS

    sudo chmod +x "$HELPER"

    # 2) ë¶€???„ë£Œ ?œì (multi-user.target)?ì„œ ??ë²??¤í–‰?˜ëŠ” ?œë¹„??? ë‹› ?‘ì„±
    sudo tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=ABLESTACK: Backup and clean cloud-init logs at boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$HELPER

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable ablestack-cloud-init-clean-at-boot.service

    msg "[INFO] ?œìŠ¤??ë¶€???„ë£Œ ??cloud-init ë¡œê·¸ ë°±ì—… ë°?clean???ë™?¼ë¡œ ?¤í–‰?˜ë„ë¡??¤ì •?ˆìŠµ?ˆë‹¤." \
        "[INFO] Configured a systemd service to backup and clean cloud-init logs at boot."
}

print_final_message() {
    # ?„ì¬ OS ë¡œì???ê°ì?
    locale="$(locale 2>/dev/null | grep LANG= | cut -d= -f2 | cut -d. -f1)"
    case "$locale" in 
        ko_KR|ko|ko_KR_*) # ?œêµ­??ë¡œì??¼ì¼ ??            echo "---------------------------------------------"
            echo "[INFO] ëª¨ë“  cloud-init ?ë™???¤ì •???„ë£Œ?˜ì—ˆ?µë‹ˆ??"
            echo "[INFO] ?´ì œ ?„ë˜ ?œì„œë¡?VM??ë§ˆë¬´ë¦¬í•˜?¸ìš”:"
            echo
            echo "  1. ê°€?ë¨¸? ì„ ?§ë‹¤??shutdown) ?˜ì‹­?œì˜¤."
            echo "  2. ì¢…ë£Œ??VM???œí”Œë¦¿ìœ¼ë¡??±ë¡ ?ëŠ” ?´ë?ì§€ë¡?ë³€?˜í•˜??‹œ??"
            echo
            echo "???œí”Œë¦??´ë?ì§€?ì„œ ? ê·œ VM??ë§Œë“¤ë©? cloud-init??ë¶€?…ë§ˆ??ìµœì‹  ë©”í??°ì´?°ë? ?ë™ ?ìš©?©ë‹ˆ??"
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