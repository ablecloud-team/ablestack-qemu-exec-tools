#!/usr/bin/env bash
# ---------------------------------------------------------------------
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
# ---------------------------------------------------------------------

# KVM/RBD -> VMware/VDDK reverse replication.  The RBD snapshot named in the
# baseline is the durable tracker.  It is advanced only after the VDDK writer
# reports that every selected extent was flushed to the target VMDK.

ftctl_dr_kvm_vmware_root() {
  printf '%s/kvm-vmware\n' "$(ftctl_dr_runtime_plan_dir "$1")"
}

ftctl_dr_kvm_vmware_disk_map_path() {
  printf '%s/disk-map.json\n' "$(ftctl_dr_kvm_vmware_root "$1")"
}

ftctl_dr_kvm_vmware_baseline_path() {
  printf '%s/baseline.json\n' "$(ftctl_dr_kvm_vmware_root "$1")"
}

ftctl_dr_kvm_vmware_cycle_dir() {
  printf '%s/cycles/%s\n' "$(ftctl_dr_kvm_vmware_root "$1")" "$2"
}

ftctl_dr_kvm_vmware_effective_mover() {
  local candidate="${FTCTL_DR_KVM_VMWARE_MOVER:-}"
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  candidate="${FTCTL_LIB_BASE:-/usr/local/lib/ablestack-qemu-exec-tools}/ftctl/dr_kvm_vmware_mover.sh"
  [[ -x "${candidate}" ]] || return 1
  printf '%s\n' "${candidate}"
}

ftctl_dr_kvm_vmware_canonicalize_profile() {
  local profile_file="${1-}" output_path="${2-}"
  python3 - "${profile_file}" "${output_path}" <<'PY'
import hashlib
import json
import os
import re
import sys

profile_path, output_path = sys.argv[1:3]
with open(profile_path, "r", encoding="utf-8") as handle:
    profile = json.load(handle)

def obj(value):
    return value if isinstance(value, dict) else {}

def items(value):
    return value if isinstance(value, list) else []

def first(*values):
    for value in values:
        if value is None or isinstance(value, (dict, list)):
            continue
        value = str(value).strip()
        if value:
            return value
    return ""

forward_source = obj(profile.get("source"))
forward_target = obj(profile.get("target"))
mapping = obj(profile.get("mapping"))
direction = first(profile.get("direction")).upper()
reverse_from_target = direction == "VMWARE_TO_KVM"
source = forward_target if reverse_from_target else forward_source
target = forward_source if reverse_from_target else forward_target
disks = items(mapping.get("disks") or mapping.get("diskMappings") or profile.get("disks"))
rows = []
for index, disk in enumerate(disks):
    disk = obj(disk)
    forward_disk_source = obj(disk.get("source"))
    forward_disk_target = obj(disk.get("target"))
    source_obj = forward_disk_target if reverse_from_target else forward_disk_source
    target_obj = forward_disk_source if reverse_from_target else forward_disk_target
    source_path = first(
        source_obj.get("path"), source_obj.get("diskRef"),
        disk.get("targetPath") if reverse_from_target else disk.get("sourcePath"),
        disk.get("targetDiskRef") if reverse_from_target else disk.get("sourceDiskRef"),
    )
    source_type = first(
        disk.get("sourceType"), source_obj.get("type"), source_obj.get("targetType"),
    ).lower()
    source_format = first(
        disk.get("sourceFormat"), source_obj.get("format"),
    ).lower()
    if not source_type:
        source_storage_type = first(
            source_obj.get("storagePoolType"), source_obj.get("poolType"),
            source.get("storagePoolType"), source.get("poolType"),
        ).upper()
        source_storage_path = first(source_obj.get("storagePath"), source.get("storagePath"))
        if (source_path.startswith(("rbd:", "rbd/", "/dev/rbd/"))
                or "RBD" in source_storage_type
                or source_storage_path.startswith(("rbd:", "rbd/", "/dev/rbd/"))
                or source_storage_path == "rbd"):
            source_type = "rbd"
        elif source_path.startswith("/dev/"):
            source_type = "block"
        elif source_path:
            source_type = "file"
    if not source_format:
        source_format = "qcow2" if source_type == "file" and source_path.endswith(".qcow2") else "raw"
    if source_type == "file":
        storage_root = first(source_obj.get("storagePath"), source.get("storagePath"))
        if not os.path.isabs(source_path) and storage_root:
            source_path = os.path.normpath(os.path.join(storage_root, source_path))
        if not os.path.isabs(source_path) or not os.path.isabs(storage_root):
            raise SystemExit("KVM_TO_VMWARE file source locator is incomplete")
        if os.path.commonpath((os.path.normpath(storage_root), source_path)) != os.path.normpath(storage_root):
            raise SystemExit("KVM_TO_VMWARE file source escapes the storage root")
    pool = first(
        disk.get("sourcePool"), source_obj.get("pool"), source_obj.get("storagePath"),
        source_obj.get("storagePool"), source.get("storagePool"),
    )
    image = first(
        disk.get("sourceImage"), source_obj.get("image"), source_obj.get("rbdImage"),
        source_obj.get("name"), source_obj.get("volumeUuid"), source_obj.get("uuid"),
    )
    match = re.match(r"^(?:rbd:|/dev/rbd/|rbd/)?([^/]+)/(.+)$", source_path)
    if match:
        pool = pool or match.group(1)
        image = image or match.group(2)
    image = image.split("@", 1)[0]
    target_vmdk = first(
        target_obj.get("vmdkPath"), target_obj.get("path"), target_obj.get("diskRef"),
        disk.get("sourcePath") if reverse_from_target else disk.get("targetVmdkPath"),
        disk.get("sourceDiskRef") if reverse_from_target else disk.get("targetPath"),
    )
    target_disk_key = first(
        target_obj.get("sourceDiskKey"), target_obj.get("deviceKey"),
        disk.get("sourceDiskKey"),
        disk.get("device") if str(disk.get("device") or "").isdigit() else "",
    )
    size = disk.get("sizeBytes") or source_obj.get("sizeBytes") or target_obj.get("sizeBytes") or 0
    identity = "|".join((pool, image, target_vmdk, str(size)))
    rows.append({
        "diskIndex": index,
        "device": first(disk.get("device"), source_obj.get("device"), target_obj.get("device"), f"disk{index}"),
        "sourcePool": pool,
        "sourceImage": image,
        "sourcePath": source_path,
        "sourceType": source_type,
        "sourceFormat": source_format,
        "sourceVolumeUuid": first(source_obj.get("volumeUuid"), source_obj.get("uuid")),
        "sourceUri": source_path if source_type == "file" else (f"rbd:{pool}/{image}" if pool and image else source_path),
        "targetVmdkPath": target_vmdk,
        "targetDiskKey": target_disk_key,
        "targetDiskLabel": first(target_obj.get("label"), disk.get("label")),
        "targetVmRef": first(target.get("externalRef"), target.get("vmId"), target.get("id"), disk.get("targetVmRef")),
        "virtualBytes": int(size or 0),
        "diskIdentityHash": "sha256:" + hashlib.sha256(identity.encode("utf-8")).hexdigest(),
    })

payload = {
    "schemaVersion": 1,
    "direction": "KVM_TO_VMWARE",
    "providerPair": "ABLESTACK_TO_VMWARE",
    "planUuid": profile.get("planUuid", ""),
    "runUuid": profile.get("runUuid", ""),
    "source": source,
    "target": target,
    "sourceDomain": first(source.get("instanceName"), source.get("domainName"), source.get("vmName")),
    "disks": rows,
}
def valid_source(row):
    if row["sourceType"] == "file" and row["sourceFormat"] == "qcow2":
        return bool(row["sourcePath"])
    return bool(row["sourcePool"] and row["sourceImage"])

if not payload["sourceDomain"] or not rows or any(not valid_source(row) or not row["targetVmdkPath"] or not row["targetVmRef"] for row in rows):
    raise SystemExit("KVM_TO_VMWARE disk map is incomplete")
os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
tmp = output_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, output_path)
PY
}

ftctl_dr_kvm_vmware_refresh_target_backings() {
  local profile_file="${1-}" map_path="${2-}" credentials_file="${3-}" rc=0
  [[ -f "${profile_file}" && -f "${map_path}" && -f "${credentials_file}" ]] || return 90
  python3 - "${profile_file}" "${map_path}" "${credentials_file}" <<'PY' || rc=$?
import json
import os
import shutil
import subprocess
import sys
import time
from urllib.parse import urlparse, urlunparse

profile_path, map_path, credentials_path = sys.argv[1:4]

def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)

def obj(value):
    return value if isinstance(value, dict) else {}

def first(*values):
    for value in values:
        if value is None or isinstance(value, (dict, list)):
            continue
        text = str(value).strip()
        if text:
            return text
    return ""

def boolish(value):
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")

def normalize_url(value):
    text = first(value)
    if "://" not in text:
        text = "https://" + text
    parsed = urlparse(text)
    path = parsed.path or "/sdk"
    if path.rstrip("/") in ("", "/rest", "/ui"):
        path = "/sdk"
    return urlunparse((parsed.scheme, parsed.netloc, path, "", "", ""))

def find_vcenter_credential(payload):
    credentials = obj(payload.get("credentials"))
    candidates = [credentials.get("source"), credentials.get("target"), payload.get("source"), payload.get("target")]
    for candidate in candidates:
        candidate = obj(candidate)
        kind = first(candidate.get("type"), candidate.get("provider")).upper()
        if "VCENTER" in kind or "VMWARE" in kind:
            return candidate
    return {}

def resolve_govc(credential):
    candidates = [os.environ.get("FTCTL_DR_VMWARE_GOVC_BIN"), credential.get("govcPath"), credential.get("govcBin")]
    libdir = first(credential.get("vddkLibdir"), credential.get("libdir"))
    if libdir:
        compat_root = os.path.dirname(os.path.abspath(libdir))
        candidates.extend((os.path.join(compat_root, "bin", "govc"), os.path.join(os.path.dirname(compat_root), "bin", "govc")))
    version = first(credential.get("vddkVersion"), credential.get("version")).replace(".", "")
    if version:
        candidates.append(f"/usr/share/ablestack/v2k/compat/vsphere{'80' if version == '8' else version}/bin/govc")
    candidates.extend((shutil.which("govc"), "/usr/local/bin/govc", "/usr/bin/govc"))
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return ""

def collect_devices(vm_info):
    machines = vm_info.get("virtualMachines") or vm_info.get("VirtualMachines") or []
    vm = machines[0] if isinstance(machines, list) and machines else vm_info
    return obj(obj(obj(vm).get("config")).get("hardware")).get("device") or []

profile = load(profile_path)
disk_map = load(map_path)
runtime_credentials = load(credentials_path)
credential = find_vcenter_credential(runtime_credentials)
auth = obj(credential.get("auth"))
target = obj(profile.get("target"))
endpoint = normalize_url(first(credential.get("endpoint"), target.get("endpoint")))
username = first(credential.get("principal"), credential.get("username"), auth.get("username"), auth.get("user"))
password = first(auth.get("password"), credential.get("password"))
govc = resolve_govc(credential)
map_disks = disk_map.get("disks") or []
map_vm_ref = first(obj(map_disks[0]).get("targetVmRef")) if map_disks else ""
vm_ref = first(map_vm_ref, disk_map.get("targetVmRef"), target.get("externalRef"))
if not endpoint or not username or not password or not govc or not vm_ref:
    raise SystemExit("DR_REVERSE_TARGET_BACKING_UNRESOLVED: vCenter lookup contract is incomplete")

env = os.environ.copy()
env.update({
    "GOVC_URL": endpoint,
    "GOVC_USERNAME": username,
    "GOVC_PASSWORD": password,
    "GOVC_INSECURE": "false" if boolish(credential.get("tlsVerify")) else "true",
})
proc = subprocess.run([govc, "vm.info", "-json", vm_ref], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
if proc.returncode != 0:
    raise SystemExit("DR_REVERSE_TARGET_BACKING_UNRESOLVED: " + (proc.stderr.strip() or "govc vm.info failed"))
try:
    vm_info = json.loads(proc.stdout or "{}")
except json.JSONDecodeError as exc:
    raise SystemExit(f"DR_REVERSE_TARGET_BACKING_UNRESOLVED: invalid govc JSON: {exc}")

devices = []
for device in collect_devices(vm_info):
    if not isinstance(device, dict):
        continue
    backing = obj(device.get("backing") or device.get("Backing"))
    path = first(backing.get("fileName"), backing.get("FileName"))
    if not path:
        continue
    info = obj(device.get("deviceInfo") or device.get("DeviceInfo"))
    devices.append({
        "key": first(device.get("key"), device.get("Key")),
        "label": first(info.get("label"), info.get("Label")),
        "path": path,
        "capacity": int(device.get("capacityInBytes") or device.get("CapacityInBytes") or 0),
    })

resolved = []
used_keys = set()
for index, row in enumerate(disk_map.get("disks") or []):
    key = first(row.get("targetDiskKey"), row.get("device") if str(row.get("device") or "").isdigit() else "")
    label = first(row.get("targetDiskLabel"))
    old_path = first(row.get("targetVmdkPath"))
    matches = [item for item in devices if item["key"] == key] if key else []
    if not key and not matches and old_path:
        matches = [item for item in devices if item["path"] == old_path]
    if not key and not matches and label:
        matches = [item for item in devices if item["label"] == label]
    if len(matches) != 1 or matches[0]["key"] in used_keys:
        raise SystemExit(f"DR_REVERSE_TARGET_BACKING_UNRESOLVED: disk {index} key={key or '-'} path={old_path or '-'}")
    match = matches[0]
    expected_size = int(row.get("virtualBytes") or 0)
    if expected_size and match["capacity"] and expected_size != match["capacity"]:
        raise SystemExit(f"DR_REVERSE_TARGET_BACKING_UNRESOLVED: disk {index} capacity mismatch")
    used_keys.add(match["key"])
    updated = dict(row)
    updated["targetDiskKey"] = match["key"]
    updated["targetDiskLabel"] = match["label"]
    updated["targetVmdkPath"] = match["path"]
    updated["targetBackingResolution"] = "vcenter-current-device-graph"
    resolved.append(updated)

if not resolved or len(resolved) != len(disk_map.get("disks") or []):
    raise SystemExit("DR_REVERSE_TARGET_BACKING_UNRESOLVED: disk count mismatch")
disk_map["disks"] = resolved
disk_map["targetBackingResolvedAtEpochMs"] = int(time.time() * 1000)
tmp = map_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(disk_map, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, map_path)
PY
  [[ "${rc}" == "0" ]] || return 90
}

ftctl_dr_kvm_vmware_baseline_state() {
  local plan="${1-}" baseline
  baseline="$(ftctl_dr_kvm_vmware_baseline_path "${plan}")"
  if [[ ! -e "${baseline}" ]]; then
    printf 'MISSING_EXPECTED\n'
  elif [[ -s "${baseline}" ]] && jq -e '.state == "LOCAL_DURABLE" and ((.disks | type) == "array") and ((.disks | length) > 0)
      and ((.trackerType // "RBD_SNAPSHOT") == "RBD_SNAPSHOT" or (.trackerType // "") == "QCOW2_BITMAP")' \
      "${baseline}" >/dev/null 2>&1; then
    printf 'LOCAL_DURABLE\n'
  else
    printf 'INVALID\n'
  fi
}

ftctl_dr_kvm_vmware_qcow2_source_provider() {
  local map_path="${1-}"
  [[ -s "${map_path}" ]] || return 1
  jq -e '.disks | length > 0 and all(.[]; .sourceType == "file" and .sourceFormat == "qcow2" and (.sourcePath | type == "string") and (.sourcePath | length > 0))' \
    "${map_path}" >/dev/null 2>&1
}

ftctl_dr_kvm_vmware_seed_qcow2_cutover_baseline() {
  local plan="${1-}" run="${2-}" map_path="${3-}" baseline_path="${4-}" checkpoint_sequence="${5-}"
  local current_run current_sequence root now
  current_run="$(jq -r '.runUuid // ""' "${baseline_path}" 2>/dev/null || true)"
  current_sequence="$(jq -r '.createdFromCheckpoint // 0' "${baseline_path}" 2>/dev/null || true)"
  if [[ "${current_run}" == "${run}" && "${current_sequence}" == "${checkpoint_sequence}" ]] \
      && ftctl_dr_ablestack_qcow2_source_baselines_ready "${plan}" "${map_path}"; then
    return 0
  fi
  ftctl_dr_ablestack_initialize_qcow2_source_baselines \
    "${plan}" "cutover-${checkpoint_sequence}" "${map_path}" 1 || return $?
  ftctl_dr_ablestack_qcow2_source_root "${map_path}" root || return 113
  now="$(ftctl_now_iso8601)"
  python3 - "${map_path}" "${baseline_path}" "${plan}" "${run}" "${checkpoint_sequence}" "${root}" "${now}" <<'PY'
import json
import os
import subprocess
import sys

map_path, output_path, plan, run, sequence, root, now = sys.argv[1:8]
with open(map_path, encoding="utf-8") as handle:
    disk_map = json.load(handle)
rows = []
for disk in disk_map.get("disks") or []:
    device = str(disk.get("device") or f"disk{len(rows)}")
    checksum = subprocess.check_output(
        ["cksum"], input=(plan + ":" + device).encode("utf-8")
    ).decode("utf-8").split()[0]
    rows.append({
        "diskIndex": int(disk.get("diskIndex") or len(rows)),
        "diskIdentityHash": disk.get("diskIdentityHash", ""),
        "sourcePath": disk.get("sourcePath", ""),
        "sourceType": "file",
        "sourceFormat": "qcow2",
        "storageRoot": root,
        "bitmap": f"ftctl-dr-{checksum}-{''.join(c if c.isalnum() or c in '._-' else '_' for c in device)}",
        "generation": int(sequence),
        "state": "LOCAL_DURABLE",
    })
payload = {
    "schemaVersion": 1, "planUuid": plan, "runUuid": run,
    "direction": "KVM_TO_VMWARE", "providerPair": "ABLESTACK_TO_VMWARE",
    "origin": "FAILOVER_CUTOVER", "commonBaselineVerified": False, "trackerType": "QCOW2_BITMAP",
    "generation": int(sequence), "createdFromCheckpoint": int(sequence),
    "state": "LOCAL_DURABLE", "committedAt": now,
    "virtualBytes": sum(int(d.get("virtualBytes") or 0) for d in disk_map.get("disks") or []),
    "disks": rows,
}
tmp = output_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, output_path)
PY
}

ftctl_dr_kvm_vmware_snapshot_exists() {
  local pool="${1-}" image="${2-}" snapshot="${3-}"
  [[ -n "${pool}" && -n "${image}" && -n "${snapshot}" ]] || return 1
  rbd snap ls --format json "${pool}/${image}" 2>/dev/null \
    | jq -e --arg snapshot "${snapshot}" \
        'any(.[]; (.name // .snapshot // "") == $snapshot)' >/dev/null 2>&1
}

ftctl_dr_kvm_vmware_seed_cutover_baseline() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" checkpoint_sequence="${4-}"
  local root map_path baseline_path work_dir rows_path created_path old_path
  local row index pool image snapshot old_snapshot rc=0
  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" \
        && "${checkpoint_sequence}" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$(jq -r '.direction // ""' "${profile_file}" 2>/dev/null || true)" == "VMWARE_TO_KVM" ]] || return 0

  root="$(ftctl_dr_kvm_vmware_root "${plan}")"
  map_path="$(ftctl_dr_kvm_vmware_disk_map_path "${plan}")"
  baseline_path="$(ftctl_dr_kvm_vmware_baseline_path "${plan}")"
  ftctl_ensure_dir "${root}" "0755"
  ftctl_dr_kvm_vmware_canonicalize_profile "${profile_file}" "${map_path}" || return 67

  if ftctl_dr_kvm_vmware_qcow2_source_provider "${map_path}"; then
    ftctl_dr_kvm_vmware_seed_qcow2_cutover_baseline \
      "${plan}" "${run}" "${map_path}" "${baseline_path}" "${checkpoint_sequence}" || return $?
    ftctl_log_event "dr-runtime" "dr.reverse.baseline.seed" "ok" "" "" \
      "plan=${plan} run=${run} checkpoint=${checkpoint_sequence} origin=FAILOVER_CUTOVER tracker=QCOW2_BITMAP"
    return 0
  fi

  if [[ -s "${baseline_path}" ]]; then
    jq -e '.schemaVersion == 1 and .state == "LOCAL_DURABLE"
      and .direction == "KVM_TO_VMWARE" and (.disks | type == "array")' \
      "${baseline_path}" >/dev/null 2>&1 || return 84
    if jq -e --arg run "${run}" --argjson sequence "${checkpoint_sequence}" \
        '.origin == "FAILOVER_CUTOVER" and .runUuid == $run
         and .createdFromCheckpoint == $sequence' "${baseline_path}" >/dev/null 2>&1; then
      while IFS=$'\t' read -r pool image snapshot; do
        ftctl_dr_kvm_vmware_snapshot_exists "${pool}" "${image}" "${snapshot}" || return 85
      done < <(jq -r '.disks[] | [.pool,.image,.snapshot] | @tsv' "${baseline_path}")
      return 0
    fi
  fi

  work_dir="$(mktemp -d -t ftctl.dr.cutover.baseline.XXXXXX)" || return 2
  rows_path="${work_dir}/rows.json"
  created_path="${work_dir}/created.tsv"
  old_path="${work_dir}/old.tsv"
  printf '[]\n' > "${rows_path}"
  : > "${created_path}"
  : > "${old_path}"
  if [[ -s "${baseline_path}" ]]; then
    jq -r '.disks[] | [.pool,.image,.snapshot] | @tsv' "${baseline_path}" > "${old_path}"
  fi

  while IFS= read -r row; do
    index="$(jq -r '.diskIndex' <<< "${row}")"
    pool="$(jq -r '.sourcePool' <<< "${row}")"
    image="$(jq -r '.sourceImage' <<< "${row}")"
    old_snapshot="$(jq -r --argjson index "${index}" \
      '[.disks[]? | select(.diskIndex == $index) | .snapshot][0] // ""' \
      "${baseline_path}" 2>/dev/null || true)"
    snapshot="ftctl-dr-${plan:0:8}-cutover-${checkpoint_sequence}-${run:0:8}-${index}"
    if ftctl_dr_kvm_vmware_snapshot_exists "${pool}" "${image}" "${snapshot}"; then
      rbd snap rm "${pool}/${image}@${snapshot}" >/dev/null 2>&1 || { rc=86; break; }
    fi
    rbd snap create "${pool}/${image}@${snapshot}" || { rc=86; break; }
    printf '%s\t%s\t%s\n' "${pool}" "${image}" "${snapshot}" >> "${created_path}"
    row="$(jq -c --arg snapshot "${snapshot}" --arg old "${old_snapshot}" \
      '. + {snapshot:$snapshot,previousSnapshot:$old}' <<< "${row}")"
    if ! jq --argjson row "${row}" '. + [$row]' "${rows_path}" > "${rows_path}.tmp" \
        || ! mv -f "${rows_path}.tmp" "${rows_path}"; then
      rc=2
      break
    fi
  done < <(jq -c '.disks[]' "${map_path}")

  if [[ "${rc}" == "0" ]]; then
    python3 - "${map_path}" "${rows_path}" "${baseline_path}" "${plan}" "${run}" "${checkpoint_sequence}" <<'PY' || rc=$?
import datetime
import json
import os
import sys

map_path, rows_path, output_path, plan, run, sequence = sys.argv[1:7]
with open(map_path, "r", encoding="utf-8") as handle:
    disk_map = json.load(handle)
with open(rows_path, "r", encoding="utf-8") as handle:
    rows = json.load(handle)
generation = int(sequence)
disks = []
for row in rows:
    disks.append({
        "diskIndex": int(row["diskIndex"]),
        "diskIdentityHash": row["diskIdentityHash"],
        "pool": row["sourcePool"],
        "image": row["sourceImage"],
        "snapshot": row["snapshot"],
        "previousSnapshot": row.get("previousSnapshot", ""),
        "generation": generation,
        "state": "LOCAL_DURABLE",
    })
payload = {
    "schemaVersion": 1,
    "planUuid": plan,
    "runUuid": run,
    "direction": "KVM_TO_VMWARE",
    "providerPair": "ABLESTACK_TO_VMWARE",
    "origin": "FAILOVER_CUTOVER",
    "commonBaselineVerified": False,
    "generation": generation,
    "createdFromCheckpoint": generation,
    "state": "LOCAL_DURABLE",
    "committedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "virtualBytes": sum(int(row.get("virtualBytes") or 0) for row in disk_map.get("disks", [])),
    "disks": disks,
}
tmp = output_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, output_path)
PY
  fi

  if [[ "${rc}" != "0" ]]; then
    while IFS=$'\t' read -r pool image snapshot; do
      if [[ -n "${snapshot}" ]]; then
        rbd snap rm "${pool}/${image}@${snapshot}" >/dev/null 2>&1 || true
      fi
    done < "${created_path}"
    rm -rf "${work_dir}"
    return "${rc}"
  fi

  while IFS=$'\t' read -r pool image snapshot; do
    [[ -n "${snapshot}" ]] || continue
    if ! grep -Fqx "${pool}"$'\t'"${image}"$'\t'"${snapshot}" "${created_path}"; then
      rbd snap rm "${pool}/${image}@${snapshot}" >/dev/null 2>&1 || true
    fi
  done < "${old_path}"
  rm -rf "${work_dir}"
  ftctl_log_event "dr-runtime" "dr.reverse.baseline.seed" "ok" "" "" \
    "plan=${plan} run=${run} checkpoint=${checkpoint_sequence} origin=FAILOVER_CUTOVER"
}

ftctl_dr_kvm_vmware_mode_decision() {
  local plan="${1-}" operation_intent="${2-}" requested_mode="${3-AUTO}" baseline_state effective_mode decision_code initial_seed=false
  operation_intent="${operation_intent^^}"
  operation_intent="${operation_intent//-/_}"
  requested_mode="${requested_mode^^}"
  requested_mode="${requested_mode//-/_}"
  baseline_state="$(ftctl_dr_kvm_vmware_baseline_state "${plan}")"

  [[ -n "${operation_intent}" ]] || operation_intent="FAILBACK_FINAL"
  [[ -n "${requested_mode}" ]] || requested_mode="AUTO"
  if [[ "${baseline_state}" == "INVALID" ]]; then
    printf '%s\t%s\t%s\t%s\n' "${baseline_state}" "" "DR_REVERSE_BASELINE_INVALID" "false"
    return 84
  fi

  case "${requested_mode}" in
    AUTO)
      if [[ "${baseline_state}" == "MISSING_EXPECTED" ]]; then
        effective_mode="FULL_REVERSE_SEED"
        decision_code="INITIAL_REVERSE_BASELINE_MISSING"
        initial_seed=true
      elif ! jq -e '.commonBaselineVerified == true' "$(ftctl_dr_kvm_vmware_baseline_path "${plan}")" >/dev/null 2>&1; then
        effective_mode="FULL_REVERSE_SEED"
        decision_code="INITIAL_REVERSE_COMMON_BASELINE_UNVERIFIED"
        initial_seed=true
      elif [[ "${operation_intent}" == "FAILBACK_FINAL" ]]; then
        effective_mode="REVERSE_FINAL"
        decision_code="DURABLE_BASELINE_FINAL_DELTA"
      else
        effective_mode="REVERSE_INCREMENTAL"
        decision_code="DURABLE_BASELINE_INCREMENTAL"
      fi
      ;;
    FULL_REVERSE_SEED)
      effective_mode="FULL_REVERSE_SEED"
      decision_code="EXPLICIT_FULL_REVERSE_SEED"
      initial_seed=true
      ;;
    REVERSE_FINAL|REVERSE_INCREMENTAL)
      if [[ "${baseline_state}" != "LOCAL_DURABLE" ]]; then
        printf '%s\t%s\t%s\t%s\n' "${baseline_state}" "" "DR_REVERSE_BASELINE_REQUIRED" "false"
        return 83
      fi
      if ! jq -e '.commonBaselineVerified == true' "$(ftctl_dr_kvm_vmware_baseline_path "${plan}")" >/dev/null 2>&1; then
        printf '%s\t%s\t%s\t%s\n' "${baseline_state}" "" "DR_REVERSE_COMMON_BASELINE_UNVERIFIED" "true"
        return 83
      fi
      effective_mode="${requested_mode}"
      decision_code="EXPLICIT_${requested_mode}"
      ;;
    *)
      printf '%s\t%s\t%s\t%s\n' "${baseline_state}" "" "DR_REVERSE_MODE_INVALID" "false"
      return 2
      ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "${baseline_state}" "${effective_mode}" "${decision_code}" "${initial_seed}"
}

ftctl_dr_kvm_vmware_cycle_type() {
  local plan="${1-}" legacy_requested="${2-}" operation_intent requested_mode decision rc=0
  case "${legacy_requested}" in
    failback-final) operation_intent="FAILBACK_FINAL"; requested_mode="AUTO" ;;
    reprotect-seed) operation_intent="REPROTECT"; requested_mode="AUTO" ;;
    full-reverse-seed|FULL_REVERSE_SEED) operation_intent="REPROTECT"; requested_mode="FULL_REVERSE_SEED" ;;
    reverse-final|REVERSE_FINAL) operation_intent="FAILBACK_FINAL"; requested_mode="REVERSE_FINAL" ;;
    reverse-incremental|REVERSE_INCREMENTAL) operation_intent="REPROTECT"; requested_mode="REVERSE_INCREMENTAL" ;;
    *) operation_intent="REPROTECT"; requested_mode="AUTO" ;;
  esac
  decision="$(ftctl_dr_kvm_vmware_mode_decision "${plan}" "${operation_intent}" "${requested_mode}")" || rc=$?
  [[ "${rc}" == "0" ]] || return "${rc}"
  awk -F '\t' '{print $2}' <<< "${decision}"
}

ftctl_dr_kvm_vmware_reverse_preflight() {
  local plan="${1-}" profile_file="${2-}" operation_intent="${3-FAILBACK_FINAL}" requested_mode="${4-AUTO}" json="${5-0}"
  local map_path="" decision="" rc=0 baseline_state="" effective_mode="" decision_code="" initial_seed=false
  local credential_override="${6-}"
  local source_disk_count=0 estimated_virtual_bytes=0
  local source_domain_probe_state="NOT_REQUIRED" source_disk_probe_state="READY" target_writer_probe_state="READY" target_backing_probe_state="NOT_CHECKED" error_code="" ready=true credentials_file
  [[ -n "${plan}" && -f "${profile_file}" ]] || return 2
  map_path="$(mktemp "${TMPDIR:-/tmp}/ftctl-reverse-map.XXXXXX.json")"
  # RETURN traps survive into the caller unless they clear themselves.
  trap 'rm -f -- "${map_path:-}"; trap - RETURN' RETURN
  ftctl_dr_kvm_vmware_canonicalize_profile "${profile_file}" "${map_path}" || {
    rc=67; error_code="DR_REVERSE_DISK_MAP_INVALID"; ready=false
  }
  credentials_file="${credential_override}"
  if [[ -z "${credentials_file}" ]]; then
    credentials_file="$(ftctl_dr_runtime_credential_path "${plan}" 2>/dev/null || true)"
    # Request profiles carry authoritative credentials, even when empty/invalid.
    # The internal worker passes its owner-only credential file explicitly because
    # its persisted reverse profile has credentials redacted for safe storage.
    if jq -e 'has("credentials")' "${profile_file}" >/dev/null 2>&1; then
      credentials_file="${profile_file}"
    fi
  fi
  if [[ "${rc}" == "0" ]]; then
    if ftctl_dr_kvm_vmware_refresh_target_backings "${profile_file}" "${map_path}" "${credentials_file}"; then
      target_backing_probe_state="READY"
    else
      rc=90; error_code="DR_REVERSE_TARGET_BACKING_UNRESOLVED"; ready=false
      target_writer_probe_state="NOT_READY"
      target_backing_probe_state="NOT_READY"
    fi
  fi
  if [[ "${rc}" == "0" ]]; then
    decision="$(ftctl_dr_kvm_vmware_mode_decision "${plan}" "${operation_intent}" "${requested_mode}")" || rc=$?
    IFS=$'\t' read -r baseline_state effective_mode decision_code initial_seed <<< "${decision}"
    [[ "${rc}" == "0" ]] || { ready=false; error_code="${decision_code}"; }
  else
    baseline_state="$(ftctl_dr_kvm_vmware_baseline_state "${plan}")"
  fi
  source_disk_count="$(jq -r '.disks | length' "${map_path}" 2>/dev/null || printf 0)"
  estimated_virtual_bytes="$(jq -r '[.disks[].virtualBytes // 0] | add // 0' "${map_path}" 2>/dev/null || printf 0)"
  if [[ "${rc}" == "0" ]]; then
    if ftctl_dr_kvm_vmware_qcow2_source_provider "${map_path}"; then
      if ! ftctl_dr_ablestack_qcow2_source_baselines_ready_for_runtime "${plan}" "${map_path}"; then
        source_disk_probe_state="NOT_READY"
        ready=false
        rc=83
        error_code="DR_REVERSE_BASELINE_REQUIRED"
      fi
    else
      while IFS=$'\t' read -r pool image; do
        if [[ -z "${pool}" || -z "${image}" ]] || ! rbd info "${pool}/${image}" >/dev/null 2>&1; then
          source_disk_probe_state="NOT_READY"
          ready=false
          rc=82
          error_code="DR_REVERSE_SOURCE_STORAGE_MISSING"
          break
        fi
      done < <(jq -r '.disks[] | [.sourcePool,.sourceImage] | @tsv' "${map_path}")
    fi
  else
    source_disk_probe_state="NOT_CHECKED"
  fi
  local required_commands=(jq nbdkit blockdev flock python3)
  if ftctl_dr_kvm_vmware_qcow2_source_provider "${map_path}"; then
    required_commands+=(qemu-storage-daemon virsh)
  else
    required_commands+=(rbd qemu-nbd nbd-client)
  fi
  for cmd in "${required_commands[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      target_writer_probe_state="NOT_READY"
      ready=false
      [[ "${rc}" != "0" ]] || rc=65
      [[ -n "${error_code}" ]] || error_code="DR_VMWARE_MOVER_UNAVAILABLE"
    fi
  done
  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-reverse-preflight","schema_version":2,"contract_version":"dr-reverse-preflight-v2","result":"%s","ready":%s,"status_evidence_contract_version":1,"status_evidence_publication_ready":true,"status_evidence_error_code":"","plan_uuid":"%s","operation_intent":"%s","requested_mode":"%s","effective_mode":"%s","mode_decision_code":"%s","initial_seed_required":%s,"baseline_file_state":"%s","source_domain_probe_state":"%s","source_disk_probe_state":"%s","source_disk_count":%s,"target_writer_probe_state":"%s","target_backing_probe_state":"%s","estimated_virtual_bytes":%s,"error_code":"%s","exit_code":%s}\n' \
      "$( [[ "${ready}" == "true" ]] && printf ok || printf error )" "${ready}" "$(ftctl__json_escape "${plan}")" \
      "$(ftctl__json_escape "${operation_intent}")" "$(ftctl__json_escape "${requested_mode}")" "$(ftctl__json_escape "${effective_mode}")" \
      "$(ftctl__json_escape "${decision_code}")" "${initial_seed:-false}" "$(ftctl__json_escape "${baseline_state}")" \
      "$(ftctl__json_escape "${source_domain_probe_state}")" "$(ftctl__json_escape "${source_disk_probe_state}")" "${source_disk_count:-0}" "$(ftctl__json_escape "${target_writer_probe_state}")" "$(ftctl__json_escape "${target_backing_probe_state}")" \
      "${estimated_virtual_bytes:-0}" "$(ftctl__json_escape "${error_code}")" "${rc}"
  else
    printf 'ready=%s baseline=%s requested=%s effective=%s decision=%s source_disks=%s writer=%s\n' \
      "${ready}" "${baseline_state}" "${requested_mode}" "${effective_mode}" "${decision_code}" "${source_disk_count}" "${target_writer_probe_state}"
  fi
  return "${rc}"
}

ftctl_dr_kvm_vmware_write_checkpoint() {
  local map_path="${1-}" baseline_path="${2-}" metrics_path="${3-}" manifest_path="${4-}" checkpoint_path="${5-}" cycle_type="${6-}"
  python3 - "${map_path}" "${baseline_path}" "${metrics_path}" "${manifest_path}" "${checkpoint_path}" "${cycle_type}" <<'PY'
import datetime
import json
import os
import sys

map_path, baseline_path, metrics_path, manifest_path, checkpoint_path, cycle_type = sys.argv[1:7]
def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)
disk_map, baseline, metrics = load(map_path), load(baseline_path), load(metrics_path)
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
common = {
    "schemaVersion": 1,
    "planUuid": metrics.get("planUuid", disk_map.get("planUuid", "")),
    "runUuid": metrics.get("runUuid", ""),
    "direction": "KVM_TO_VMWARE",
    "providerPair": "ABLESTACK_TO_VMWARE",
    "cycleType": cycle_type,
    "cycleMetrics": metrics,
    "baselineGeneration": baseline.get("generation", 0),
    "baselineState": baseline.get("state", ""),
    "trackerState": metrics.get("trackerState", ""),
    "writerState": metrics.get("writerState", ""),
    "targetWritten": bool(metrics.get("targetWritten")),
    "writeVerified": bool(metrics.get("writeVerified")),
    "transferCompletionVerified": metrics.get("transferCompletionVerified"),
    "verificationMethod": metrics.get("verificationMethod"),
    "readbackVerified": metrics.get("readbackVerified"),
    "readbackVerifiedBytes": metrics.get("readbackVerifiedBytes"),
}
manifest = dict(common, state="reverse-data-durable", disks=disk_map.get("disks", []), completedAt=now)
checkpoint = dict(common, state="TARGET_READY", sourceCheckpointAt=now, targetDurableAt=now,
                  targetReadyRpoSeconds=0, completedAt=now)
for path, payload in ((manifest_path, manifest), (checkpoint_path, checkpoint)):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
PY
}

ftctl_dr_kvm_vmware_replication_cycle() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" sequence="${4-0}" requested="${5-}"
  local root map_path baseline_path cycle_dir metrics_path manifest_path checkpoint_path mover credentials_file effective rc=0
  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" ]] || return 2
  root="$(ftctl_dr_kvm_vmware_root "${plan}")"
  map_path="$(ftctl_dr_kvm_vmware_disk_map_path "${plan}")"
  baseline_path="$(ftctl_dr_kvm_vmware_baseline_path "${plan}")"
  cycle_dir="$(ftctl_dr_kvm_vmware_cycle_dir "${plan}" "${run}-cycle-${sequence}")"
  metrics_path="${cycle_dir}/metrics.json"
  manifest_path="${cycle_dir}/manifest.json"
  checkpoint_path="${cycle_dir}/checkpoint.json"
  ftctl_ensure_dir "${root}" "0755"
  ftctl_ensure_dir "${cycle_dir}" "0755"
  ftctl_dr_kvm_vmware_canonicalize_profile "${profile_file}" "${map_path}" || return 67
  credentials_file="$(ftctl_dr_runtime_credential_path "${plan}" 2>/dev/null || true)"
  ftctl_dr_kvm_vmware_refresh_target_backings "${profile_file}" "${map_path}" "${credentials_file}" || return 90
  effective="$(ftctl_dr_kvm_vmware_cycle_type "${plan}" "${requested}")" || return $?
  mover="$(ftctl_dr_kvm_vmware_effective_mover 2>/dev/null || true)"
  [[ -n "${mover}" ]] || return 65
  FTCTL_DR_PLAN_UUID="${plan}" \
  FTCTL_DR_RUN_UUID="${run}" \
  FTCTL_DR_CHECKPOINT_SEQUENCE="${sequence}" \
  FTCTL_DR_CYCLE_TYPE="${effective}" \
  FTCTL_DR_KVM_VMWARE_DISK_MAP="${map_path}" \
  FTCTL_DR_KVM_VMWARE_BASELINE="${baseline_path}" \
  FTCTL_DR_CYCLE_METRICS_PATH="${metrics_path}" \
  FTCTL_DR_CREDENTIALS_FILE="$([[ -f "${credentials_file}" ]] && printf '%s' "${credentials_file}")" \
    "${mover}" || rc=$?
  [[ "${rc}" == "0" ]] || return "${rc}"
  jq -e '.targetWritten == true and .writeVerified == true and .writerState == "DURABLE" and .trackerState == "LOCAL_DURABLE"' \
    "${metrics_path}" >/dev/null || return 88
  ftctl_dr_kvm_vmware_write_checkpoint "${map_path}" "${baseline_path}" "${metrics_path}" "${manifest_path}" "${checkpoint_path}" "${effective}" || return $?
  ftctl_log_event "dr-runtime" "dr.kvm-vmware.cycle" "ok" "" "" \
    "plan=${plan} run=${run} sequence=${sequence} type=${effective} checkpoint=${checkpoint_path}"
  printf '%s\t%s\n' "${manifest_path}" "${checkpoint_path}"
}
