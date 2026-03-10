#!/usr/bin/env bash
#
# Filename : libvirt_helpers.sh
# Purpose : Common libvirt helper functions(cdrom attach/detach, os type detection, qga check, etc.)
# Author  : Donghyuk Park (ablecloud.io)
#v
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

# require bash when sourced
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[ERR] libvirt_helpers.sh requires bash (arrays, mapfile used)." 1>&2
  # sourcedë©?return, ì§ì ‘?¤í–‰?´ë©´ exit
  return 1 2>/dev/null || exit 1
fi

set -euo pipefail

ISO_PATH_DEFAULT="/usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso"

# Return list of "<dev> <source-or-EMPTY>" for all cdrom devices (via domblklist)
# usage: _list_cdrom_targets <domain>
_list_cdrom_targets() {
  local dom="$1"
  # --details ì¶œë ¥ ?•ì‹: "Type  Device  Target  Source"
  # ?¤ë”/êµ¬ë¶„???œì™¸?˜ê³  cdrom ?‰ë§Œ ì¶”ì¶œ
  virsh domblklist "$dom" --details 2>/dev/null \
  | awk 'BEGIN{IGNORECASE=1}
         NR<3 {next}                             # ?¤ë”/êµ¬ë¶„???¤í‚µ
         $2 ~ /^cdrom$/ {
           dev=$3; src=$4;
           if (src=="-" || src=="") src="EMPTY";
           print dev " " src
         }'
}

# Pick best cdrom target for insert: prefer EMPTY, else first one
# prints the chosen <dev> to stdout; returns 0 if found, 1 otherwise
_pick_cdrom_target_for_insert() {
  local dom="$1"
  local best="" line dev src
  while read -r line; do
    dev="${line%% *}"
    src="${line#* }"
    [[ -z "$best" ]] && best="$dev"
    if [[ "$src" == "EMPTY" ]]; then
      echo "$dev"; return 0
    fi
  done < <(_list_cdrom_targets "$dom")

  [[ -n "$best" ]] && { echo "$best"; return 0; }
  return 1
}

# Return first cdrom target dev that currently has given ISO path, else empty
_find_cdrom_target_by_iso() {
  local dom="$1" iso="$2"
  virsh domblklist "$dom" --details 2>/dev/null \
  | awk -v ISO="$iso" 'BEGIN{IGNORECASE=1}
       NR<3 {next}
       $2=="cdrom" && $4==ISO {print $3; exit}
     '
}

require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { echo "[ERR] '$c' not installed"; exit 1; }; done
}

# Check if the given domain exists
check_domain_exists() {
  local dom="$1"
  virsh dominfo "$dom" >/dev/null 2>&1 || { echo "[ERR] Domain '$dom' no exists"; exit 1; }
}

# Attach ISO file to the given domain's CD-ROM drive
attach_cdrom_iso() {
  local dom="$1" iso="${2:-$ISO_PATH_DEFAULT}"
  [[ -f "$iso" ]] || { echo "[ERR] ISO file not found: $iso"; exit 1; }

  # ?„ë©”???íƒœ ?•ì¸
  local state
  state="$(virsh domstate "$dom" 2>/dev/null | tr 'A-Z' 'a-z' | awk '{print $1}')"

  # 1) ?¤í–‰ ì¤‘ì´ë©? ê¸°ì¡´ CD-ROM target(dev) ì°¾ì•„ change-media --insert
  if [[ "$state" == "running" || "$state" == "paused" ]]; then
    local target
    if ! target="$(_pick_cdrom_target_for_insert "$dom")"; then
      echo "[ERR] No CD-ROM device found in domain XML"; exit 1
    fi

    echo "[INFO] change-media: domain=$dom target=$target iso=$iso"
    # ë¨¼ì? cdrom ë¹„ìš°ê¸??ˆìœ¼ë©?
    virsh change-media "$dom" "$target" --eject --live   >/dev/null 2>&1 || true
    # live ë°˜ì˜
    virsh change-media "$dom" "$target" --insert "$iso" --live   >/dev/null 2>&1 || true
    # persistent XML ë°˜ì˜
    virsh change-media "$dom" "$target" --insert "$iso" --config >/dev/null 2>&1 || true

    echo "[OK] ISO inserted via change-media (target=${target})"
    return 0
  fi

  # 2) êº¼ì ¸ ?ˆìœ¼ë©? XML??ì£¼ì…(ê¸°ì¡´ ë¡œì§ ?¬ì‚¬??
  #    - ê¸°ì¡´??ê°™ì? ISOê°€ ë¬¼ë ¤ ?ˆìœ¼ë©?skip
  #    - ë¹„ì–´?ˆëŠ” CD-ROM ?ˆìœ¼ë©?ê·?ë¸”ë¡??source ì¶”ê?
  #    - ?†ìœ¼ë©???CD-ROM ì¶”ê?
  local tmp_xml
  tmp_xml="$(mktemp)"
  virsh dumpxml --security-info "$dom" > "$tmp_xml"
  inject_cdrom_into_xml "$tmp_xml" "$iso"
  # persistent ?•ì˜ ê°±ì‹ 
  virsh define "$tmp_xml" >/dev/null
  rm -f "$tmp_xml"
  echo "[OK] ISO attached by XML update (offline)"
}

# Check qemu-guest-agent availability AND whether guest-exec is permitted
# return: "yes" if guest-ping works AND guest-exec can spawn a process, else "no"
has_qga() {
  local dom="$1"
  local timeout="${2:-3}"   # sec, optional

  # 0) ping: ì±„ë„ ?°ê²° ?•ì¸
  if ! virsh qemu-agent-command "$dom" '{"execute":"guest-ping"}' --timeout "$timeout" >/dev/null 2>&1; then
    echo "no"; return 0
  fi

  # helper: run guest-exec json and extract pid (non-empty => success)
  _qga_try_exec() {
    local dom="$1" json="$2" pid
    local resp
    resp="$(virsh qemu-agent-command "$dom" "$json" --timeout "$timeout" 2>/dev/null || true)"
    pid="$(printf '%s' "$resp" | jq -r '.return.pid // empty' 2>/dev/null || true)"
    [[ -n "$pid" ]]
  }

  # 1) Linux fast path: /bin/true
  if _qga_try_exec "$dom" '{"execute":"guest-exec","arguments":{"path":"/bin/true","arg":[],"capture-output":true}}'; then
    echo "yes"; return 0
  fi

  # 2) Linux fallback: /bin/sh -c true (sh ê²½ë¡œê°€ ?¤ë¥¸ ë°°í¬ ?€??
  if _qga_try_exec "$dom" '{"execute":"guest-exec","arguments":{"path":"/bin/sh","arg":["-c","true"],"capture-output":true}}'; then
    echo "yes"; return 0
  fi

  # 3) Windows: cmd.exe /c exit 0
  if _qga_try_exec "$dom" '{"execute":"guest-exec","arguments":{"path":"C:\\\\Windows\\\\System32\\\\cmd.exe","arg":["/c","exit","0"],"capture-output":true}}'; then
    echo "yes"; return 0
  fi

  # ?„ë? ?¤íŒ¨ ??guest-exec ê¸ˆì?/ë¯¸ë™?‘ìœ¼ë¡??ë‹¨
  echo "no"
}


# Detect OS family (windows/linux) using QGA guest-info
detect_os_family_qga() {
  local dom="$1"
  local out
  out=$(virsh qemu-agent-command "$dom" '{"execute":"guest-get-osinfo"}' 2>/dev/null || true)
  if echo "$out" | grep -qi windows; then echo "windows"; fi
  if echo "$out" | grep -qiE 'rocky|rhel|centos|almalinux|fedora|ubuntu|debian|opensuse|sles'; then echo "linux"; fi
}

# Gracefully shutdown the given domain and wait until it's powered off
graceful_shutdown_and_wait() {
  local dom="$1" timeout="${2:-120}"
  virsh shutdown "$dom" || true
  local t=0
  while virsh domstate "$dom" | grep -qi running; do
    sleep 2; t=$((t+2))
    [[ $t -ge $timeout ]] && { echo "[WARN] Try destroy domain"; virsh destroy "$dom"; break; }
  done
  echo "[OK] Successful domain shutdown : $dom"
}

# Start the given domain
start_domain() {
  local dom="$1"
  virsh start "$dom"
  echo "[OK] Domain started : $dom"
}

# Wait until QGA is up in the given domain, with a timeout
wait_for_qga_up() {
  local dom="$1" timeout="${2:-180}" t=0
  while [[ "$(has_qga "$dom")" != "yes" ]]; do
    sleep 3; t=$((t+3))
    [[ $t -ge $timeout ]] && return 1
  done
  return 0
}

# Check if the given domain is persistent
is_persistent() {
  local dom="$1"
  virsh dominfo "$dom" | awk -F: '/Persistent/{gsub(/^[ \t]+/, "", $2); print tolower($2)}'
}

# Get the UUID of the given domain
get_dom_uuid() {
  local dom="$1"
  virsh domuuid "$dom"
}

# Dump the transient XML of the given domain to the specified output file
dump_transient_xml() {
  local dom="$1" out="$2"
  virsh dumpxml --security-info "$dom" > "$out"
  echo "[OK] dumpxml -> $out"
}

# Get disk image paths of the given domain (excluding cdrom/readonly)
get_disk_paths() {
  # ?¬ìš©ë²? get_disk_paths <dom>
  # ì¶œë ¥: ??ì¤„ì— ?˜ë‚˜???”ìŠ¤???´ë?ì§€ ê²½ë¡œ(?œë””ë¡?readonly ?œì™¸)
  local dom="$1"
  virsh domblklist "$dom" --details 2>/dev/null \
    | awk 'BEGIN{IGNORECASE=1}
           NR<3 {next}                       # ?¤ë”/êµ¬ë¶„???¤í‚µ
           $2=="disk" && $4!="" && $4!="-"{  # Device=disk ?´ê³  Source ? íš¨
             print $4                        # Source ì»¬ëŸ¼
           }'
}

# Create a transient domain from the given XML file
create_from_xml() {
  local xml="$1"
  [[ -f "$xml" ]] || { echo "[ERR] XML not found: $xml"; return 1; }
  virsh create "$xml" >/dev/null
  echo "[OK] Domain created from XML: $xml"
}

# Inject or update a CD-ROM device with the specified ISO in the domain XML
# - ê¸°ì¡´ CD-ROM???ˆìœ¼ë©?ì²?ë²ˆì§¸ CD-ROM ë¸”ë¡?ë§Œ <source file=...> êµì²´/?½ì…
# - ?„í? ?†ìœ¼ë©?IDE ë²„ìŠ¤ë¡?1ê°?ì¶”ê?(ê°€???¸í™˜???’ìŒ)
inject_cdrom_into_xml() {
  local xml="$1" iso="$2"
  [[ -f "$xml" ]] || { echo "[ERR] xml not found: $xml"; exit 1; }
  [[ -f "$iso" ]] || { echo "[ERR] iso not found: $iso"; exit 1; }

  if grep -q "<disk[^>]*device=['\"]cdrom['\"]" "$xml"; then
    # ì²?ë²ˆì§¸ cdrom ë¸”ë¡ë§??ˆì „?˜ê²Œ ?˜ì • (êµ¬ì¡° ë³´ì¡´)
    ISO="$iso" perl -0777 -i -pe "$(cat <<'PERL'
my $iso  = $ENV{ISO};
my $done = 0;

# <disk ... device='cdrom'>...</disk> ë¸”ë¡????ë²ˆë§Œ ?˜ì •
s{
  ( <disk [^>]* device=(["']) cdrom \2 [^>]* > )   # $1: head
  ( .*? )                                          # $2: mid (lazy)
  ( </disk> )                                      # $3: tail
}{
  my ($head,$mid,$tail)=($1,$2,$3);
  if ($done) { $head.$mid.$tail }
  else {
    if ($mid =~ m/<source\s/i) {
      # 1) sourceê°€ ?´ë? ?ˆìœ¼ë©?file ê°’ë§Œ ISOë¡?êµì²´
      $mid =~ s{(<source\s+[^>]*file=)(["\']).*?\2}{$1.$2.$iso.$2}is;
    } else {
      # 2) sourceê°€ ?†ìœ¼ë©??½ì… ?°ì„ ?œìœ„:
      #    a) <driver ...> ë°”ë¡œ ??      #    b) <target ...> ë°”ë¡œ ??      #    c) </disk> ì§ì „
      my $ins = "      <source file='$iso'/>\n";
      if ($mid =~ s{(<driver\b[^>]*>\s*)}{$1.$ins}i) {
        # OK: driver ?¤ì— ?½ì…
      } elsif ($mid =~ s{(\s*)(<target\b)}{$ins.$2}i) {
        # OK: target ?ì— ?½ì…
      } else {
        $mid = $mid.$ins;  # fallback: </disk> ì§ì „
      }
    }
    $done=1;
    $head.$mid.$tail
  }
}egsx;
PERL
)" "$xml" > "$tmp" && mv "$tmp" "$xml"
    echo "[OK] Updated existing CD-ROM source to ISO in XML"
    return 0
  fi

  # CD-ROM ?¥ì¹˜ê°€ ?˜ë‚˜???†ìœ¼ë©? IDEë¡?1ê°?ì¶”ê?
  awk -v ISO="$iso" '
    BEGIN{added=0}
    /<\/devices>/ && !added{
      print "    <disk type='\''file'\'' device='\''cdrom'\''>";
      print "      <driver name='\''qemu'\''/>";
      print "      <source file='\''" ISO "'\''/>";
      print "      <target bus='\''ide'\''/>";   # dev ?ëµ: libvirtê°€ ë°°ì •
      print "      <readonly/>";
      print "    </disk>";
      added=1
    }
    {print}
  ' "$xml" > "${xml}.tmp" && mv "${xml}.tmp" "$xml"
  echo "[OK] Added a new IDE CD-ROM with ISO to XML"
}

# Safely eject ISO using change-media (live + config); no failure if not found
detach_iso_safely() {
  local dom="$1" iso="$2"
  local tgt
  tgt="$(_find_cdrom_target_by_iso "$dom" "$iso")"
  if [[ -z "$tgt" ]]; then
    echo "[WARN] target devë¥?ì°¾ì? ëª»í•¨. cdrom ?„ì²´ ?¤ìº” ?œë„"
    # target??ëª?ì°¾ìœ¼ë©??´ì¨Œ??ì²?ë²ˆì§¸ cdrom ?˜ë‚˜?¼ë„ eject ?œë„
    tgt="$(virsh domblklist "$dom" --details 2>/dev/null | awk 'NR>=3 && $2=="cdrom"{print $3; exit}')"
    [[ -z "$tgt" ]] && return 1
  fi

  virsh change-media "$dom" "$tgt" --eject --live   >/dev/null 2>&1 || true
  virsh change-media "$dom" "$tgt" --eject --config >/dev/null 2>&1 || true
  echo "[OK] Ejected ISO via change-media (target=$tgt)"
}

# Return "yes" if XML already has a cdrom with the given ISO source, else "no"
xml_has_cdrom_iso() {
  local xml="$1" iso="$2"
  [[ -f "$xml" && -f "$iso" ]] || { echo "no"; return 0; }
  awk -v ISO="$iso" '
    BEGIN{in_cd=0; found=0}
    /<disk[^>]*device='\''cdrom'\''/ {in_cd=1}
    in_cd && /<source / {
      if (match($0,/file='\''([^'\'']+)'\''/,m) && m[1]==ISO) {found=1}
    }
    /<\/disk>/ {in_cd=0}
    END{ print(found?"yes":"no") }
  ' "$xml"
}

# Wait until the guest-created sentinel exists (requires guest-exec)
# usage: wait_install_done_via_qga <dom> <os:linux|windows> [timeout_sec]
wait_install_done_via_qga() {
  local dom="$1" os="$2" timeout="${3:-600}"  # default 10min
  local start=$(date +%s) now resp pid

  # small helper to run guest-exec and check exit code
  _qga_exec_json() {
    local json="$1"
    virsh qemu-agent-command "$dom" "$json" --timeout 5 2>/dev/null
  }
  _qga_exec_and_wait_ok() {
    local json="$1" id rc
    resp="$(_qga_exec_json "$json")" || return 1
    id="$(echo "$resp" | jq -r '.return.pid // empty')" || return 1
    [[ -z "$id" ]] && return 1
    # poll status until exited
    while :; do
      resp="$(virsh qemu-agent-command "$dom" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$id}}" --timeout 5 2>/dev/null)" || return 1
      rc="$(echo "$resp" | jq -r '.return.exitcode // empty')" || true
      [[ -n "$rc" ]] && { [[ "$rc" == "0" ]]; return 0; }
      sleep 1
      now=$(date +%s); (( now-start > timeout )) && return 1
    done
  }

  local probe_json
  if [[ "$os" == "linux" ]]; then
    probe_json='{"execute":"guest-exec","arguments":{"path":"/bin/sh","arg":["-lc","test -f /var/lib/ablestack/autoinstall.done"],"capture-output":false}}'
  else
    probe_json='{"execute":"guest-exec","arguments":{"path":"C:\\\\Windows\\\\System32\\\\cmd.exe","arg":["/c","if exist C:\\\\ProgramData\\\\AbleStack\\\\autoinstall.done exit 0 else exit 1"],"capture-output":false}}'
  fi

  while :; do
    if _qga_exec_and_wait_ok "$probe_json"; then
      echo "[OK] Guest reported install completion sentinel."; return 0
    fi
    now=$(date +%s); (( now-start > timeout )) && { echo "[WARN] Timeout waiting for install completion"; return 1; }
    sleep 3
  done
}