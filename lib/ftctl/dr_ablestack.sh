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

FTCTL_DR_ABLESTACK_FULL_SEED_ON_START="${FTCTL_DR_ABLESTACK_FULL_SEED_ON_START:-0}"

ftctl_dr_ablestack_disk_map_path() {
  local plan="${1-}"
  printf '%s/ablestack-disks.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_ablestack_manifest_dir() {
  local plan="${1-}"
  printf '%s/manifests\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_ablestack_checkpoint_dir() {
  local plan="${1-}"
  printf '%s/checkpoints\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_ablestack_manifest_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-manifest.json\n' \
    "$(ftctl_dr_ablestack_manifest_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_ablestack_checkpoint_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-checkpoint.json\n' \
    "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_ablestack_cutover_source_map_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-cutover-source-map.json\n' \
    "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_ablestack_cutover_quiesce_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-cutover-quiesce.state\n' \
    "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_ablestack_profile_provider() {
  local profile_file="${1-}" endpoint="${2-}"
  ftctl_dr_runtime_profile_value "${profile_file}" "${endpoint}.provider" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true
}

ftctl_dr_ablestack_profile_involves_ablestack() {
  local profile_file="${1-}"
  local source_provider target_provider
  source_provider="$(ftctl_dr_ablestack_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_ablestack_profile_provider "${profile_file}" target)"
  [[ "${source_provider}" == "ABLESTACK" || "${target_provider}" == "ABLESTACK" ]]
}

ftctl_dr_ablestack_canonicalize_profile() {
  local profile_file="${1-}" out_path="${2-}"
  [[ -n "${profile_file}" && -f "${profile_file}" && -n "${out_path}" ]] || return 2
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"
  python3 - "${profile_file}" "${out_path}" <<'PY'
import json
import os
import sys

profile_path, out_path = sys.argv[1], sys.argv[2]
with open(profile_path, "r", encoding="utf-8") as fh:
    profile = json.load(fh)

def obj(value):
    return value if isinstance(value, dict) else {}

def arr(value):
    return value if isinstance(value, list) else []

def first_str(*values):
    for value in values:
        if value is None:
            continue
        if isinstance(value, (dict, list)):
            continue
        text = str(value).strip()
        if text:
            return text
    return ""

def first_int(*values):
    for value in values:
        if value is None or value == "":
            continue
        try:
            number = int(value)
            if number > 0:
                return number
        except (TypeError, ValueError):
            continue
    return 0

def value_at(data, *keys):
    if not isinstance(data, dict):
        return None
    for key in keys:
        if key in data:
            return data.get(key)
    return None

def infer_disk_type(path):
    text = str(path or "")
    if text.startswith("rbd:") or text.startswith("/dev/rbd/") or text.startswith("rbd/"):
        return "rbd"
    if text.startswith("/dev/"):
        return "block"
    if text:
        return "file"
    return ""

def infer_format(path, disk_type):
    text = str(path or "")
    if disk_type in ("rbd", "block"):
        return "raw"
    if text.endswith(".qcow2") or ".qcow2" in text:
        return "qcow2"
    if text.endswith(".raw"):
        return "raw"
    return ""

def join_path(base, name, suffix=""):
    base = str(base or "").rstrip("/")
    name = str(name or "").strip().lstrip("/")
    if not base or not name:
        return ""
    return f"{base}/{name}{suffix}"

def rbd_pool_from_ref(value):
    text = str(value or "").strip()
    if not text:
        return ""
    if text.startswith("rbd:"):
        text = text[4:]
    elif text.startswith("rbd/"):
        text = text[4:]
    elif text.startswith("/dev/rbd/"):
        text = text[len("/dev/rbd/"):]
    text = text.strip("/")
    if not text or text.startswith("/"):
        return ""
    return text.split("/", 1)[0]

def derive_target_path(target_name, storage_ref, storage_path, krbd_path, pool_type):
    name = str(target_name or "").strip()
    if not name:
        return ""
    pool_text = str(pool_type or "").upper()
    krbd_text = str(krbd_path or "").strip()
    path_text = str(storage_path or "").strip()
    storage_text = str(storage_ref or "").strip()
    if "RBD" in pool_text and krbd_text:
        pool_name = rbd_pool_from_ref(path_text) or rbd_pool_from_ref(storage_text)
        if krbd_text.rstrip("/") == "/dev/rbd" and pool_name:
            return join_path("/dev/rbd/" + pool_name, name)
        return join_path(krbd_text, name)
    if "RBD" in pool_text and (path_text.startswith("rbd:") or path_text.startswith("rbd/")):
        return join_path(path_text, name)
    if "RBD" in pool_text and path_text and not path_text.startswith("/"):
        return join_path("rbd/" + path_text.strip("/"), name)
    if "RBD" in pool_text and (storage_text.startswith("rbd:") or storage_text.startswith("rbd/")):
        return join_path(storage_text, name)
    if path_text.startswith("/"):
        suffix = "" if name.endswith((".qcow2", ".raw")) else ".qcow2"
        return join_path(path_text, name, suffix)
    if path_text.startswith("rbd:") or path_text.startswith("rbd/"):
        return join_path(path_text, name)
    if storage_text.startswith("/") or storage_text.startswith("rbd:") or storage_text.startswith("rbd/"):
        suffix = "" if storage_text.startswith(("rbd:", "rbd/")) or name.endswith((".qcow2", ".raw")) else ".qcow2"
        return join_path(storage_text, name, suffix)
    return ""

def resolve_shared_mount_target_path(target_path, storage_path, pool_type):
    target_text = str(target_path or "").strip()
    if str(pool_type or "").strip().upper() != "SHAREDMOUNTPOINT" or not target_text:
        return target_text
    root = os.path.normpath(str(storage_path or "").strip())
    if not os.path.isabs(root):
        raise ValueError("SharedMountPoint target storage path must be absolute")
    candidate = os.path.normpath(target_text) if os.path.isabs(target_text) else os.path.normpath(os.path.join(root, target_text))
    try:
        inside_root = os.path.commonpath((root, candidate)) == root
    except ValueError:
        inside_root = False
    if not os.path.isabs(candidate) or not inside_root or candidate == root:
        raise ValueError("SharedMountPoint target path escapes the configured storage root")
    return candidate

def first_networks(*values):
    out = []
    for value in values:
        for item in arr(value):
            item = obj(item)
            network_ref = first_str(value_at(item, "networkId", "networkRef", "id", "uuid", "value", "ref"))
            if network_ref:
                out.append({
                    "networkId": network_ref,
                    "role": first_str(value_at(item, "role"), "default"),
                })
    return out

def normalize_disk(item, index):
    item = obj(item)
    source = obj(item.get("source"))
    target = obj(item.get("target"))
    source_path = first_str(
        value_at(item, "sourcePath", "sourceDiskRef", "sourceDisk", "source", "sourceRef"),
        value_at(source, "path", "diskRef", "disk", "sourcePath", "ref"),
    )
    target_path = first_str(
        value_at(item, "targetPath", "targetDiskRef", "targetDisk", "destination", "dest", "target"),
        value_at(target, "path", "diskRef", "disk", "targetPath", "ref"),
    )
    target_name = first_str(
        value_at(item, "targetName", "targetDiskName", "targetRef"),
        value_at(target, "name", "targetName", "ref"),
    )
    if not target_name and target_path:
        target_name = os.path.basename(target_path.rstrip("/"))
    target_storage_ref = first_str(
        value_at(item, "targetStorageRef", "targetStorage", "targetDatastoreRef"),
        value_at(target, "storageRef", "storagePoolId", "datastoreRef", "targetStorageRef"),
    )
    target_storage_path = first_str(
        value_at(item, "targetStoragePath", "storagePath"),
        value_at(target, "storagePath", "pathPrefix"),
    )
    target_storage_krbd_path = first_str(
        value_at(item, "targetStorageKrbdPath", "krbdPath"),
        value_at(target, "krbdPath"),
    )
    target_storage_type = first_str(
        value_at(item, "targetStorageType", "storagePoolType"),
        value_at(target, "storagePoolType", "poolType"),
    )
    if not target_path:
        target_path = derive_target_path(target_name, target_storage_ref, target_storage_path, target_storage_krbd_path, target_storage_type)
    elif "RBD" in str(target_storage_type or "").upper() and target_path.startswith("/dev/rbd/"):
        rbd_suffix = target_path[len("/dev/rbd/"):].strip("/")
        if rbd_suffix and "/" not in rbd_suffix:
            derived_target_path = derive_target_path(target_name or rbd_suffix, target_storage_ref, target_storage_path, target_storage_krbd_path, target_storage_type)
            if derived_target_path:
                target_path = derived_target_path
    elif "RBD" in str(target_storage_type or "").upper() and not (
        target_path.startswith("rbd:") or target_path.startswith("rbd/") or target_path.startswith("/dev/rbd/")
    ):
        derived_target_path = derive_target_path(target_name, target_storage_ref, target_storage_path, target_storage_krbd_path, target_storage_type)
        if derived_target_path:
            target_path = derived_target_path
    target_path = resolve_shared_mount_target_path(target_path, target_storage_path, target_storage_type)
    device = first_str(
        value_at(item, "device", "targetDevice", "diskTarget", "sourceDevice"),
        value_at(source, "device", "targetDevice"),
        value_at(target, "device", "targetDevice"),
        f"disk{index}",
    )
    source_type = infer_disk_type(source_path)
    target_type = first_str(
        value_at(item, "targetType", "type"),
        value_at(target, "targetType", "type"),
        infer_disk_type(target_path),
    ).lower()
    if "RBD" in str(target_storage_type or "").upper() and target_path:
        target_type = "rbd"
    source_format = first_str(
        value_at(item, "sourceFormat", "format"),
        value_at(source, "format", "sourceFormat"),
        infer_format(source_path, source_type),
    )
    target_format = first_str(
        value_at(item, "targetFormat"),
        value_at(target, "format", "targetFormat"),
        "raw" if target_type == "rbd" else "",
        infer_format(target_path, target_type),
        source_format if target_type == "file" else "",
    )
    target_disk_offering_id = first_str(
        value_at(item, "targetDiskOfferingId", "diskOfferingId"),
        value_at(target, "diskOfferingId", "diskOfferingRef", "offeringId"),
    )
    size_bytes = first_int(
        value_at(item, "sizeBytes", "virtualSize", "bytesTotal", "capacityBytes"),
        value_at(source, "sizeBytes", "virtualSize", "bytesTotal", "capacityBytes"),
        value_at(target, "sizeBytes", "virtualSize", "bytesTotal", "capacityBytes"),
    )
    return {
        "device": device,
        "sourcePath": source_path,
        "targetPath": target_path,
        "sourceFormat": source_format,
        "targetFormat": target_format,
        "sizeBytes": size_bytes,
        "sourceType": source_type,
        "targetType": target_type,
        "targetName": target_name,
        "targetStorageRef": target_storage_ref,
        "targetStoragePath": target_storage_path,
        "targetStorageKrbdPath": target_storage_krbd_path,
        "targetStorageType": target_storage_type,
        "targetDiskOfferingId": target_disk_offering_id,
    }

def normalize_pair(source_item, target_item, index):
    source_item = obj(source_item)
    target_item = obj(target_item)
    merged = {
        "device": first_str(value_at(source_item, "device", "targetDevice"), value_at(target_item, "device", "targetDevice"), f"disk{index}"),
        "source": source_item,
        "target": target_item,
        "sourcePath": first_str(value_at(source_item, "path", "diskRef", "sourcePath", "sourceDiskRef", "ref")),
        "targetPath": first_str(value_at(target_item, "path", "diskRef", "targetPath", "targetDiskRef", "ref")),
        "sourceFormat": first_str(value_at(source_item, "format", "sourceFormat")),
        "targetFormat": first_str(value_at(target_item, "format", "targetFormat")),
        "sizeBytes": first_int(value_at(source_item, "sizeBytes", "virtualSize"), value_at(target_item, "sizeBytes", "virtualSize")),
    }
    return normalize_disk(merged, index)

source = obj(profile.get("source"))
target = obj(profile.get("target"))
mapping = obj(profile.get("mapping"))
mapping_source = obj(mapping.get("source"))
mapping_target = obj(mapping.get("target"))
transport = obj(profile.get("transport"))
transport_exports = []
for export in arr(transport.get("exports")):
    export = obj(export)
    device = first_str(export.get("device"))
    host = first_str(export.get("host"), transport.get("targetHostAddress"))
    port = first_int(export.get("port"))
    name = first_str(export.get("name"))
    uri = first_str(export.get("uri"))
    target_path = first_str(export.get("targetPath"), export.get("targetLocator"))
    if device and host and port and name:
        if not uri:
            uri = f"nbd://{host}:{port}/{name}"
        transport_exports.append({
            "device": device,
            "host": host,
            "port": port,
            "name": name,
            "uri": uri,
            "targetPath": target_path,
            "exportGeneration": first_int(export.get("exportGeneration")),
        })

disk_items = []
for key in ("disks", "diskMappings", "volumes", "volumeMappings"):
    disk_items = arr(mapping.get(key))
    if disk_items:
        break
if not disk_items:
    for key in ("disks", "diskMappings", "volumes"):
        disk_items = arr(profile.get(key))
        if disk_items:
            break

disks = []
if disk_items:
    disks = [normalize_disk(item, idx) for idx, item in enumerate(disk_items)]
else:
    source_disks = arr(source.get("disks"))
    target_disks = arr(target.get("disks"))
    if source_disks or target_disks:
        for idx in range(max(len(source_disks), len(target_disks))):
            disks.append(normalize_pair(
                source_disks[idx] if idx < len(source_disks) else {},
                target_disks[idx] if idx < len(target_disks) else {},
                idx,
            ))

source_storage_path = first_str(
    source.get("storagePath"), mapping_source.get("storagePath"),
    mapping_source.get("sourceStoragePath"),
)
source_storage_type = first_str(
    source.get("storagePoolType"), mapping_source.get("storagePoolType"),
    mapping_source.get("sourceStorageType"),
)
if source_storage_type.upper() == "SHAREDMOUNTPOINT":
    for disk in disks:
        if disk.get("sourceType") == "file" and disk.get("sourcePath"):
            disk["sourcePath"] = resolve_shared_mount_target_path(
                disk["sourcePath"], source_storage_path, source_storage_type)
            if not disk.get("sourceFormat"):
                disk["sourceFormat"] = infer_format(disk["sourcePath"], "file")

out = {
    "planUuid": profile.get("planUuid", ""),
    "runUuid": profile.get("runUuid", ""),
    "direction": profile.get("direction", ""),
    "sourceProvider": str(source.get("provider", "")).upper(),
    "targetProvider": str(target.get("provider", "")).upper(),
    "sourceDriver": source.get("driver", ""),
    "targetDriver": target.get("driver", ""),
    "source": {
        "externalRef": first_str(source.get("externalRef"), source.get("vmUuid"), source.get("vmId")),
        "instanceName": first_str(source.get("instanceName"), obj(source.get("hardware")).get("instanceName")),
        "hostUuid": first_str(source.get("hostUuid"), obj(source.get("hardware")).get("sourceHostUuid")),
        "storagePath": source_storage_path,
        "storagePoolType": source_storage_type,
    },
    "target": {
        "siteId": first_str(target.get("siteId"), mapping_target.get("siteId")),
        "siteUuid": first_str(target.get("siteUuid"), mapping_target.get("siteUuid")),
        "zoneId": first_str(target.get("zoneId"), mapping_target.get("zoneId"), mapping.get("targetZoneId")),
        "workerHostId": first_str(target.get("workerHostId"), mapping_target.get("workerHostId"), mapping.get("targetWorkerHostId")),
        "vmName": first_str(target.get("vmName"), mapping_target.get("vmName"), mapping.get("targetVmName")),
        "storageRef": first_str(target.get("storageRef"), target.get("storagePoolId"), mapping_target.get("storageRef"), mapping_target.get("storagePoolId"), mapping.get("targetStorageRef"), mapping.get("targetDatastoreRef")),
        "serviceOfferingId": first_str(target.get("serviceOfferingId"), mapping_target.get("serviceOfferingId"), mapping.get("targetComputeRef")),
        "networks": first_networks(target.get("networks"), mapping_target.get("networks")),
    },
    "transport": {
        "mode": first_str(transport.get("mode"), "local"),
        "targetHostUuid": first_str(transport.get("targetHostUuid")),
        "targetHostAddress": first_str(transport.get("targetHostAddress")),
        "secondaryUri": first_str(transport.get("secondaryUri")),
        "sshUser": first_str(transport.get("sshUser"), "root"),
        "sshPort": first_str(transport.get("sshPort"), "22"),
        "sshKeyFile": first_str(transport.get("sshKeyFile")),
        "remoteNbdExportAddress": first_str(transport.get("remoteNbdExportAddress"), transport.get("targetHostAddress")),
        "targetStorageScope": first_str(transport.get("targetStorageScope"), "secondary-local"),
        "exports": transport_exports,
    },
    "requiresDiskMap": len(disks) == 0,
    "count": len(disks),
    "disks": disks,
}

tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(out, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, out_path)
PY
  ftctl_dr_ablestack_normalize_local_source_formats "${out_path}" || return $?
}

ftctl_dr_ablestack_normalize_local_source_formats() {
  local disk_map="${1-}" source_provider direction transport_mode index source_path source_type source_format detected_format="" tmp=""
  [[ -s "${disk_map}" ]] || return 2
  source_provider="$(jq -r '.sourceProvider // ""' "${disk_map}" 2>/dev/null || true)"
  direction="$(jq -r '.direction // ""' "${disk_map}" 2>/dev/null || true)"
  transport_mode="$(jq -r '.transport.mode // ""' "${disk_map}" 2>/dev/null || true)"
  [[ "${source_provider}" == "ABLESTACK" ]] || return 0
  case "${direction}" in
    KVM_TO_KVM|ABLESTACK_TO_ABLESTACK|"") ;;
    *) return 0 ;;
  esac
  [[ "${transport_mode}" == "site-agent-nbd" || "${transport_mode}" == "remote-nbd" || "${transport_mode}" == "local" ]] || return 0

  while IFS=$'\t' read -r index source_path source_type source_format; do
    [[ "${index}" =~ ^[0-9]+$ && "${source_type}" == "file" && -z "${source_format}" && -n "${source_path}" ]] || continue
    [[ -e "${source_path}" ]] || continue
    detected_format=""
    ftctl_dr_ablestack_qemu_info_value "${source_path}" "format" detected_format || return $?
    case "${detected_format}" in
      qcow2|raw) ;;
      *) return 32 ;;
    esac
    tmp="${disk_map}.format.$$"
    jq --argjson index "${index}" --arg format "${detected_format}" \
      '.disks[$index].sourceFormat = $format' "${disk_map}" > "${tmp}" || {
        rm -f "${tmp}"
        return 1
      }
    mv -f "${tmp}" "${disk_map}"
  done < <(jq -r '.disks | to_entries[] | [.key, (.value.sourcePath // ""), (.value.sourceType // ""), (.value.sourceFormat // "")] | @tsv' "${disk_map}")
}

ftctl_dr_ablestack_disk_count() {
  local disk_map="${1-}"
  [[ -n "${disk_map}" && -f "${disk_map}" ]] || return 1
  python3 - "${disk_map}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(int(data.get("count") or 0))
PY
}

ftctl_dr_ablestack_disk_total_size_bytes() {
  local disk_map="${1-}"
  [[ -n "${disk_map}" && -f "${disk_map}" ]] || return 1
  python3 - "${disk_map}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    disks = json.load(fh).get("disks") or []
print(sum(max(0, int(disk.get("sizeBytes") or 0)) for disk in disks if isinstance(disk, dict)))
PY
}

ftctl_dr_ablestack_missing_config() {
  local disk_map="${1-}"
  [[ -n "${disk_map}" && -f "${disk_map}" ]] || return 1
  python3 - "${disk_map}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

def text(value):
    return str(value or "").strip()

missing = []
target_provider = text(data.get("targetProvider")).upper()
target = data.get("target") if isinstance(data.get("target"), dict) else {}
disks = data.get("disks") if isinstance(data.get("disks"), list) else []

if target_provider == "ABLESTACK":
    if not text(target.get("zoneId")):
        missing.append("TARGET_SITE_ZONE_REQUIRED")
    if not text(target.get("storageRef")):
        missing.append("TARGET_STORAGE_REQUIRED")
    if not text(target.get("serviceOfferingId")):
        missing.append("TARGET_SERVICE_OFFERING_REQUIRED")
    if not target.get("networks"):
        missing.append("TARGET_NETWORK_REQUIRED")
    if not disks:
        missing.append("DISK_MAPPING_REQUIRED")
    for index, disk in enumerate(disks):
        if not isinstance(disk, dict):
            missing.append(f"DISK_MAPPING_REQUIRED:{index}")
            continue
        if not text(disk.get("sourcePath")):
            missing.append(f"DISK_SOURCE_REQUIRED:{index}")
        if not text(disk.get("targetName")) and not text(disk.get("targetPath")):
            missing.append(f"DISK_TARGET_REQUIRED:{index}")
        if not text(disk.get("targetPath")):
            missing.append(f"DISK_TARGET_PATH_REQUIRED:{index}")
        if not text(disk.get("targetStorageRef")) and not text(target.get("storageRef")):
            missing.append(f"TARGET_STORAGE_REQUIRED:{index}")
        if not text(disk.get("targetDiskOfferingId")):
            missing.append(f"TARGET_DISK_OFFERING_REQUIRED:{index}")

print(",".join(missing))
PY
}

ftctl_dr_ablestack_disk_preflight_error() {
  local disk_map="${1-}"
  [[ -n "${disk_map}" && -f "${disk_map}" ]] || {
    printf 'DR_TARGET_DISK_MAPPING_INVALID:disk_map_missing\n'
    return 0
  }
  python3 - "${disk_map}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

def text(value):
    return str(value or "").strip()

source_provider = text(data.get("sourceProvider")).upper()
target_provider = text(data.get("targetProvider")).upper()
disks = data.get("disks") if isinstance(data.get("disks"), list) else []
errors = []
if target_provider == "ABLESTACK":
    if not disks:
        errors.append("DR_TARGET_DISK_MAPPING_INVALID:disks")
    for index, disk in enumerate(disks):
        if not isinstance(disk, dict):
            errors.append(f"DR_TARGET_DISK_MAPPING_INVALID:{index}")
            continue
        target_type = text(disk.get("targetType")).lower()
        target_storage_type = text(disk.get("targetStorageType")).upper()
        target_path = text(disk.get("targetPath"))
        target_name = text(disk.get("targetName"))
        source_path = text(disk.get("sourcePath"))
        try:
            size = int(disk.get("sizeBytes") or 0)
        except (TypeError, ValueError):
            size = 0
        if not source_path or (not target_path and not target_name):
            errors.append(f"DR_TARGET_DISK_MAPPING_INVALID:{index}")
        if target_storage_type == "RBD" and target_type != "rbd":
            errors.append(f"DR_TARGET_DISK_TYPE_INVALID:{index}")
        if not target_type:
            errors.append(f"DR_TARGET_DISK_TYPE_INVALID:{index}")
        if source_provider == "VMWARE" and size <= 0:
            errors.append(f"DR_TARGET_DISK_SIZE_UNRESOLVED:{index}")

print(",".join(errors))
PY
}

ftctl_dr_ablestack_disk_preflight_rc() {
  local error_text="${1-}"
  case "${error_text}" in
    *DR_TARGET_DISK_SIZE_UNRESOLVED*) printf '33\n' ;;
    *DR_TARGET_DISK_TYPE_INVALID*) printf '32\n' ;;
    *DR_TARGET_STORAGE_UNRESOLVED*) printf '35\n' ;;
    *DR_TARGET_DISK_MAPPING_INVALID*) printf '31\n' ;;
    *) printf '31\n' ;;
  esac
}

ftctl_dr_ablestack_disk_rows() {
  local disk_map="${1-}"
  [[ -n "${disk_map}" && -f "${disk_map}" ]] || return 1
  python3 - "${disk_map}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for disk in data.get("disks") or []:
    print(json.dumps({
        key: str(disk.get(key, "") or "") for key in (
            "device", "sourcePath", "targetPath", "sourceFormat", "targetFormat",
            "sizeBytes", "sourceType", "targetType"
        )
    }, sort_keys=True, separators=(",", ":")))
PY
}

ftctl_dr_ablestack_disk_json_field() {
  local disk_json="${1-}" field="${2-}"
  python3 - "${disk_json}" "${field}" <<'PY'
import json
import sys

try:
    disk = json.loads(sys.argv[1])
except Exception:
    disk = {}
value = disk.get(sys.argv[2], "")
print("" if value is None else str(value))
PY
}

ftctl_dr_ablestack_json_field() {
  local json_path="${1-}" field_path="${2-}"
  [[ -f "${json_path}" && -n "${field_path}" ]] || return 1
  python3 - "${json_path}" "${field_path}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    value = json.load(fh)
for key in sys.argv[2].split("."):
    value = value.get(key) if isinstance(value, dict) else None
    if value is None:
        break
print("" if value is None else str(value))
PY
}

ftctl_dr_ablestack_remote_transport_load() {
  local disk_map="${1-}" mode host port
  mode="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.mode 2>/dev/null || true)"
  [[ "${mode}" == "remote-nbd" ]] || return 1
  host="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.targetHostAddress 2>/dev/null || true)"
  port="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.sshPort 2>/dev/null || true)"
  [[ -n "${host}" ]] || return 2
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
  FTCTL_PROFILE_SECONDARY_URI="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.secondaryUri)"
  FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.sshKeyFile)"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.remoteNbdExportAddress)"
  FTCTL_PROFILE_FENCING_SSH_USER="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.sshUser)"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT="auto"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="dr-rbd"
  FTCTL_PROFILE_SECONDARY_TARGET_DIR="/dev/rbd"
  [[ "${port}" == "22" || -z "${port}" ]] || FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://${FTCTL_PROFILE_FENCING_SSH_USER}@${host}:${port}/system"
  return 0
}

ftctl_dr_ablestack_site_agent_transport_load() {
  local disk_map="${1-}" mode
  mode="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.mode 2>/dev/null || true)"
  [[ "${mode}" == "site-agent-nbd" ]] || return 1
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
  return 0
}

ftctl_dr_ablestack_export_manifest_path() {
  local plan="${1-}"
  printf '%s/target-exports.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_ablestack_export_persist_root() {
  printf '%s\n' "${FTCTL_DR_TARGET_EXPORT_PERSIST_ROOT:-/var/lib/ablestack-vm-ftctl/dr-target-exports}"
}

ftctl_dr_ablestack_export_persist_dir() {
  local plan="${1-}"
  printf '%s/%s\n' "$(ftctl_dr_ablestack_export_persist_root)" "$(ftctl_dr_runtime_key "${plan}")"
}

ftctl_dr_ablestack_export_persist_profile_path() {
  printf '%s/profile.json\n' "$(ftctl_dr_ablestack_export_persist_dir "${1-}")"
}

ftctl_dr_ablestack_export_persist_manifest_path() {
  printf '%s/exports.json\n' "$(ftctl_dr_ablestack_export_persist_dir "${1-}")"
}

ftctl_dr_ablestack_export_persist_intent_path() {
  printf '%s/intent.json\n' "$(ftctl_dr_ablestack_export_persist_dir "${1-}")"
}

ftctl_dr_ablestack_export_persist_intent() {
  local plan="${1-}" run="${2-}" desired="${3-RUNNING}" profile_file="${4-}" manifest="${5-}"
  local actual="${6-${desired}}"
  local persist_dir persist_profile persist_manifest intent tmp redacted
  persist_dir="$(ftctl_dr_ablestack_export_persist_dir "${plan}")"
  persist_profile="$(ftctl_dr_ablestack_export_persist_profile_path "${plan}")"
  persist_manifest="$(ftctl_dr_ablestack_export_persist_manifest_path "${plan}")"
  intent="$(ftctl_dr_ablestack_export_persist_intent_path "${plan}")"
  ftctl_ensure_dir "${persist_dir}" "0750"
  if [[ -n "${profile_file}" && -f "${profile_file}" ]]; then
    if command -v ftctl_dr_runtime_redacted_profile_json >/dev/null 2>&1; then
      redacted="$(ftctl_dr_runtime_redacted_profile_json "${profile_file}")" || return $?
      ftctl_state_write_json_file "${persist_profile}" "${redacted}"
    else
      if [[ ! "${profile_file}" -ef "${persist_profile}" ]]; then cp -f "${profile_file}" "${persist_profile}" || return $?; fi
    fi
    chmod 0600 "${persist_profile}" 2>/dev/null || true
  fi
  if [[ -n "${manifest}" && -f "${manifest}" ]]; then
    if [[ ! "${manifest}" -ef "${persist_manifest}" ]]; then cp -f "${manifest}" "${persist_manifest}" || return $?; fi
    chmod 0600 "${persist_manifest}" 2>/dev/null || true
  fi
  tmp="${intent}.tmp.$$"
  python3 - "${tmp}" "${plan}" "${run}" "${desired}" "${actual}" <<'PY'
import json, os, sys, time
path, plan, run, desired, actual = sys.argv[1:6]
payload = {
    "schemaVersion": 1,
    "planUuid": plan,
    "runUuid": run,
    "desiredState": desired,
    "actualState": actual,
    "updatedAtEpochMs": int(time.time() * 1000),
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.chmod(path, 0o600)
PY
  mv -f "${tmp}" "${intent}"
}

ftctl_dr_ablestack_export_persisted_port() {
  local plan="${1-}" device="${2-}" manifest
  manifest="$(ftctl_dr_ablestack_export_persist_manifest_path "${plan}")"
  [[ -f "${manifest}" ]] || return 1
  python3 - "${manifest}" "${device}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
for item in data.get("exports") or []:
    if str(item.get("device") or "") == sys.argv[2]:
        value = item.get("port")
        if isinstance(value, int) and value > 0:
            print(value)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

ftctl_dr_ablestack_export_value() {
  local disk_map="${1-}" device="${2-}" field="${3-}"
  python3 - "${disk_map}" "${device}" "${field}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for item in (data.get("transport") or {}).get("exports") or []:
    if str(item.get("device") or "") == sys.argv[2]:
        value = item.get(sys.argv[3], "")
        print("" if value is None else value)
        break
PY
}

ftctl_dr_ablestack_target_export_reachable() {
  local host="${1-}" port="${2-}" timeout_sec="${3-2}"
  [[ -n "${host}" && "${port}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${timeout_sec}" =~ ^[1-9][0-9]*$ ]] || timeout_sec=2
  python3 - "${host}" "${port}" "${timeout_sec}" <<'PY'
import socket
import sys

host, port, timeout = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    with socket.create_connection((host, port), timeout=timeout):
        pass
except OSError:
    raise SystemExit(1)
PY
}

ftctl_dr_ablestack_local_port_in_use() {
  local port="${1-}"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

ftctl_dr_ablestack_target_export_pick_port() {
  local plan="${1-}" device="${2-}" out_var="${3-}" preferred candidate offset persisted
  persisted="$(ftctl_dr_ablestack_export_persisted_port "${plan}" "${device}" 2>/dev/null || true)"
  if [[ "${persisted}" =~ ^[0-9]+$ ]]; then
    if ! ftctl_dr_ablestack_local_port_in_use "${persisted}"; then
      printf -v "${out_var}" '%s' "${persisted}"
      return 0
    fi
    return 93
  fi
  ftctl_blockcopy_remote_nbd_candidate_port "${plan}" "${device}" preferred
  for ((offset=0; offset<FTCTL_REMOTE_NBD_PORT_COUNT; offset++)); do
    candidate=$((FTCTL_REMOTE_NBD_PORT_BASE + ((preferred - FTCTL_REMOTE_NBD_PORT_BASE + offset) % FTCTL_REMOTE_NBD_PORT_COUNT)))
    if ! ftctl_dr_ablestack_local_port_in_use "${candidate}"; then
      printf -v "${out_var}" '%s' "${candidate}"
      return 0
    fi
  done
  return 93
}

ftctl_dr_ablestack_target_export_unit_name() {
  local plan="${1-}" device="${2-}" digest
  digest="$(printf '%s' "${plan}:${device}" | sha256sum | awk '{print substr($1,1,20)}')"
  printf 'ablestack-vm-ftctl-dr-export-%s.service\n' "${digest}"
}

ftctl_dr_ablestack_target_export_systemd_available() {
  [[ -d /run/systemd/system ]] && command -v systemd-run >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1
}

ftctl_dr_ablestack_target_export_stop_item() {
  local item="${1-}" pid_file pid unit_name attempt
  pid_file="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("pidFile", ""))' "${item}")"
  unit_name="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("unitName", ""))' "${item}")"
  [[ -z "${unit_name}" || "${unit_name}" =~ ^ablestack-vm-ftctl-dr-export-[a-f0-9]{20}\.service$ ]] || return 93
  pid="$(cat "${pid_file}" 2>/dev/null || true)"
  # A stale pid file must never authorize signalling an unrelated/reused PID.
  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    python3 - "${pid}" "${pid_file}" <<'PY'
import os,sys
try:
    args=open('/proc/'+sys.argv[1]+'/cmdline','rb').read().split(b'\0')
    args=[x.decode() for x in args if x]
    ok=os.path.basename(args[0])=='qemu-nbd' and '--pid-file' in args and args[args.index('--pid-file')+1]==sys.argv[2]
except (OSError,IndexError,ValueError):
    ok=False
raise SystemExit(0 if ok else 93)
PY
    [[ "$?" == "0" ]] || return 93
  fi
  if [[ -n "${unit_name}" ]] && ftctl_dr_ablestack_target_export_systemd_available; then
    systemctl stop "${unit_name}" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "${unit_name}"; then return 93; fi
    systemctl reset-failed "${unit_name}" >/dev/null 2>&1 || true
  elif [[ "${pid}" =~ ^[0-9]+$ ]]; then
    kill "${pid}" >/dev/null 2>&1 || true
  fi
  for attempt in $(seq 1 30); do
    if [[ ! "${pid}" =~ ^[0-9]+$ ]] || ! kill -0 "${pid}" 2>/dev/null; then
      [[ -z "${pid_file}" ]] || rm -f "${pid_file}"
      return 0
    fi
    sleep 0.1
  done
  return 93
}

ftctl_dr_ablestack_target_export_stop_records() {
  local records="${1-}" item
  [[ -s "${records}" ]] || return 0
  while IFS= read -r item; do
    ftctl_dr_ablestack_target_export_stop_item "${item}" || return $?
  done < "${records}"
}

ftctl_dr_ablestack_target_export_abort() {
  local records="${1-}" manifest="${2-}"
  ftctl_dr_ablestack_target_export_stop_records "${records}" || return $?
  rm -f "${records}" "${manifest}" "${manifest}.tmp"
}

ftctl_dr_ablestack_target_export_resolve_profile() {
  local plan="${1-}" requested="${2-}" out_var="${3-}" candidate
  candidate="${requested}"
  if [[ -z "${candidate}" || ! -f "${candidate}" ]]; then
    candidate="$(ftctl_dr_ablestack_export_persist_profile_path "${plan}")"
  fi
  [[ -n "${out_var}" && -f "${candidate}" ]] || return 2
  printf -v "${out_var}" '%s' "${candidate}"
}

ftctl_dr_ablestack_target_export_lock_path() {
  local plan="${1-}"
  printf '%s/.transition.lock\n' "$(ftctl_dr_ablestack_export_persist_dir "${plan}")"
}

ftctl_dr_ablestack_target_export_start() (
  local plan="${1-}" lock_path
  lock_path="$(ftctl_dr_ablestack_target_export_lock_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${lock_path}")" "0750"
  exec 203>"${lock_path}"
  flock -w "${FTCTL_DR_TARGET_EXPORT_LOCK_TIMEOUT_SEC:-30}" 203 || return 93
  ftctl_dr_ablestack_target_export_start_unlocked "$@"
)

ftctl_dr_ablestack_target_export_start_unlocked() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" json="${4-0}"
  local disk_map manifest host count disk_json device target_path target_type size_bytes target_format spec uri target_backend
  local port name pid_file current_pid unit_name out="" err="" rc=0 records ready reverse_requested reverse_profile
  [[ -n "${plan}" && -n "${run}" ]] || return 2
  ftctl_dr_ablestack_target_export_resolve_profile "${plan}" "${profile_file}" profile_file || return $?
  if ! jq -e '.mapping.disks | length > 0' "${profile_file}" >/dev/null 2>&1; then
    local base_profile merged_profile
    base_profile="$(ftctl_dr_ablestack_export_persist_profile_path "${plan}")"
    merged_profile="$(ftctl_dr_ablestack_export_persist_dir "${plan}")/request-profile.json"
    if [[ "${profile_file}" != "${base_profile}" && -f "${base_profile}" ]]; then
      jq -s '.[0] * .[1]' "${base_profile}" "${profile_file}" > "${merged_profile}" || return 93
      profile_file="${merged_profile}"
    fi
  fi
  local export_generation ownership_profile_file="${profile_file}"
  export_generation="$(python3 "${BASH_SOURCE[0]%/*}/dr_export_ownership.py" \
    "$(ftctl_dr_ablestack_export_persist_dir "${plan}")" START "${profile_file}")" || return $?
  ftctl_dr_ablestack_export_persist_intent "${plan}" "${run}" "RUNNING" "${profile_file}" "" "STARTING" || return $?
  reverse_requested="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.reverseTargetExport" 2>/dev/null || true)"
  if [[ "${reverse_requested,,}" == "true" || "${reverse_requested}" == "1" ]]; then
    reverse_profile="$(ftctl_dr_ablestack_checkpoint_dir "${plan}")/target-export-reverse-$(ftctl_dr_runtime_key "${run}").json"
    ftctl_dr_runtime_build_reverse_profile "${plan}" "${run}" "${profile_file}" "${reverse_profile}" "failback-target-export" || return $?
    profile_file="${reverse_profile}"
  fi
  disk_map="$(ftctl_dr_ablestack_disk_map_path "${plan}")"
  ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  host="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.targetHostAddress 2>/dev/null || true)"
  [[ -n "${host}" ]] || host="0.0.0.0"
  count="$(ftctl_dr_ablestack_disk_count "${disk_map}")" || return $?
  [[ "${count}" != "0" ]] || return 31
  manifest="$(ftctl_dr_ablestack_export_manifest_path "${plan}")"
  records="${manifest}.records"
  ftctl_ensure_dir "$(dirname "${manifest}")" "0755"
  : > "${records}"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
    target_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetType)"
    target_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetFormat)"
    size_bytes="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sizeBytes)"
    if [[ ! "${size_bytes}" =~ ^[1-9][0-9]*$ ]]; then
      ftctl_dr_ablestack_target_export_abort "${records}" "${manifest}"
      return 32
    fi
    case "${target_type}:${target_format}" in
      rbd:raw|rbd:)
        if ! ftctl_dr_ablestack_prepare_rbd_target "${target_path}" "${size_bytes}"; then
          ftctl_dr_ablestack_target_export_abort "${records}" "${manifest}"
          return 34
        fi
        if ! ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" spec; then
          ftctl_dr_ablestack_target_export_abort "${records}" "${manifest}"
          return 35
        fi
        target_format="raw"
        target_backend="rbd:${spec}"
        ;;
      file:qcow2)
        if ! ftctl_dr_ablestack_prepare_file_target "${target_path}" "${target_format}" "${size_bytes}"; then
          ftctl_dr_ablestack_target_export_abort "${records}" "${manifest}"
          return 34
        fi
        target_backend="${target_path}"
        ;;
      *)
        ftctl_dr_ablestack_target_export_abort "${records}" "${manifest}"
        return 32
        ;;
    esac
    name="dr-${plan//[^A-Za-z0-9]/}-${device//[^A-Za-z0-9]/}"
    pid_file="/run/ablestack-vm-ftctl/nbd-${plan//[^A-Za-z0-9]/}-${device//[^A-Za-z0-9]/}.pid"
    unit_name="$(ftctl_dr_ablestack_target_export_unit_name "${plan}" "${device}")"
    current_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ "${current_pid}" =~ ^[0-9]+$ ]] && kill -0 "${current_pid}" 2>/dev/null; then
      port="$(ss -lntp 2>/dev/null | awk -v pid="${current_pid}" '$0 ~ ("pid=" pid ",") {split($4,a,":"); print a[length(a)]; exit}')"
      if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        ftctl_dr_ablestack_target_export_abort "${records}" "${manifest}"
        return 93
      fi
    else
      rm -f "${pid_file}"
      if ! ftctl_dr_ablestack_target_export_pick_port "${plan}" "${device}" port; then
        ftctl_dr_ablestack_target_export_abort "${records}" "${manifest}"
        return 93
      fi
      out=""; err=""; rc=0
      if ftctl_dr_ablestack_target_export_systemd_available; then
        systemctl stop "${unit_name}" >/dev/null 2>&1 || true
        systemctl reset-failed "${unit_name}" >/dev/null 2>&1 || true
        ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
          systemd-run --quiet --collect --unit "${unit_name}" \
          --property=Restart=on-failure --property=RestartSec=2s --property=TimeoutStopSec=15s \
          qemu-nbd --persistent --shared=8 --cache=none --aio=io_uring \
          --bind "${host}" --port "${port}" --export-name "${name}" --format "${target_format:-raw}" \
          --pid-file "${pid_file}" "${target_backend}" || true
      else
        ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
          qemu-nbd --fork --persistent --shared=8 --cache=none --aio=io_uring \
          --bind "${host}" --port "${port}" --export-name "${name}" --format "${target_format:-raw}" \
          --pid-file "${pid_file}" "${target_backend}" || true
      fi
      if [[ "${rc}" != "0" ]]; then
        printf '%s\n' "${err}" >&2
        ftctl_dr_ablestack_target_export_abort "${records}" "${manifest}"
        return "${rc}"
      fi
      ready=0
      for _ in $(seq 1 50); do
        current_pid="$(cat "${pid_file}" 2>/dev/null || true)"
        if [[ "${current_pid}" =~ ^[0-9]+$ ]] && kill -0 "${current_pid}" 2>/dev/null \
          && ftctl_dr_ablestack_target_export_reachable "${host}" "${port}" 1; then
          ready=1
          break
        fi
        sleep 0.1
      done
      if [[ "${ready}" != "1" ]]; then
        ftctl_dr_ablestack_target_export_stop_item "$(printf '{"pidFile":"%s","unitName":"%s"}' "${pid_file}" "${unit_name}")"
        ftctl_dr_ablestack_target_export_abort "${records}" "${manifest}"
        return 93
      fi
    fi
    uri="nbd://${host}:${port}/${name}"
    python3 - "${records}" "${device}" "${host}" "${port}" "${name}" "${uri}" "${target_path}" "${pid_file}" "${unit_name}" "${target_type}" "${target_format}" <<'PY'
import json,sys
record = dict(zip(("device","host","port","name","uri","targetPath","pidFile","unitName","targetType","targetFormat"), sys.argv[2:]))
record["port"] = int(record["port"])
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  python3 - "${records}" "${manifest}" "${plan}" "${run}" <<'PY'
import json,os,sys
rows=[]
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        if line.strip(): rows.append(json.loads(line))
data={"schemaVersion":1,"controlMode":"site-agent","planUuid":sys.argv[3],"runUuid":sys.argv[4],"exports":rows}
tmp=sys.argv[2]+".tmp"
with open(tmp,"w",encoding="utf-8") as fh: json.dump(data,fh,sort_keys=True,separators=(",",":")); fh.write("\n")
os.replace(tmp,sys.argv[2])
PY
  rm -f "${records}"
  ftctl_dr_ablestack_export_persist_intent "${plan}" "${run}" "RUNNING" "${ownership_profile_file}" "${manifest}" "RUNNING" || return $?
  if [[ "${json}" == "1" ]]; then
    python3 - "${manifest}" "${export_generation}" "$(ftctl_dr_ablestack_export_persist_dir "${plan}")/ownership.json" <<'PY'
import json,sys,os
with open(sys.argv[1], encoding="utf-8") as fh: data=json.load(fh)
data.update({"ownershipProtocol":1,"exportGeneration":int(sys.argv[2])})
owner=json.load(open(sys.argv[3], encoding="utf-8")) if os.path.isfile(sys.argv[3]) else {}
if owner.get("scope"):
    data.update(ownershipProtocol=2,exportAuthorityScope=owner["scope"],exportDirection=owner["direction"])
data.update({"command":"dr-target-export-start","result":"ok","accepted":True,"state":"READY","step":"target-export-ready","progress":100})
print(json.dumps(data,separators=(",",":")))
PY
  else
    printf 'target exports ready: plan=%s count=%s\n' "${plan}" "${count}"
  fi
}

ftctl_dr_ablestack_reverse_baseline_state_path() {
  local plan="${1-}"
  printf '%s/reverse-baseline.state\n' "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")"
}

ftctl_dr_ablestack_source_baselines_ready() {
  local plan="${1-}" disk_map="${2-}" disk_json device source_path source_spec baseline snap
  [[ -n "${plan}" && -s "${disk_map}" ]] || return 1
  if ftctl_dr_ablestack_qcow2_source_provider "${disk_map}"; then
    ftctl_dr_ablestack_qcow2_source_baselines_ready "${plan}" "${disk_map}"
    return $?
  fi
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    ftctl_dr_ablestack_rbd_spec_from_path "${source_path}" source_spec || return 1
    baseline="$(ftctl_dr_ablestack_baseline_path "${plan}" "${device}")"
    [[ -s "${baseline}" ]] || return 1
    snap="$(head -n 1 "${baseline}")"
    [[ -n "${snap}" ]] || return 1
    rbd snap ls --format json "${source_spec}" 2>/dev/null \
      | jq -e --arg snap "${snap}" 'any(.[]; .name == $snap)' >/dev/null || return 1
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
}

ftctl_dr_ablestack_qcow2_bitmap_baseline_path() {
  local plan="${1-}" device="${2-}"
  printf '%s/baseline-%s.bitmap\n' "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")" "$(ftctl_dr_runtime_key "${device}")"
}

ftctl_dr_ablestack_qcow2_source_root() {
  local disk_map="${1-}" out_var="${2-}" resolved_root=""
  [[ -s "${disk_map}" && -n "${out_var}" ]] || return 2
  resolved_root="$(ftctl_dr_ablestack_json_field "${disk_map}" source.storagePath 2>/dev/null || true)"
  if [[ -z "${resolved_root}" ]]; then
    resolved_root="$(python3 - "${disk_map}" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
parents = set()
for disk in data.get("disks") or []:
    if str(disk.get("sourceType") or "").lower() != "file":
        raise SystemExit(1)
    path = str(disk.get("sourcePath") or "").strip()
    if not os.path.isabs(path):
        raise SystemExit(1)
    parents.add(os.path.realpath(os.path.dirname(path)))
if len(parents) != 1:
    raise SystemExit(1)
print(parents.pop())
PY
)" || return 113
  fi
  [[ -n "${resolved_root}" && "${resolved_root}" == /* ]] || return 113
  printf -v "${out_var}" '%s' "${resolved_root}"
}

ftctl_dr_ablestack_qcow2_source_baselines_ready() {
  local plan="${1-}" disk_map="${2-}" root="" disk_json device source_path bitmap baseline recorded tmp
  ftctl_dr_ablestack_qcow2_source_root "${disk_map}" root || return 1
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    bitmap="$(ftctl_dr_ablestack_qcow2_bitmap_name "${plan}" "${device}")"
    baseline="$(ftctl_dr_ablestack_qcow2_bitmap_baseline_path "${plan}" "${device}")"
    python3 "${FTCTL_LIB_BASE}/ftctl/qcow2_bitmap_baseline.py" \
      --path "${source_path}" --storage-root "${root}" --bitmap "${bitmap}" \
      --granularity "${FTCTL_DR_QCOW2_BITMAP_GRANULARITY:-65536}" --check-only \
      >/dev/null 2>&1 || return 1
    recorded="$(head -n 1 "${baseline}" 2>/dev/null || true)"
    if [[ "${recorded}" != "${bitmap}" ]]; then
      # The sidecar is worker-local cache. Rebuild it only after the qcow2
      # persistent bitmap itself proves the durable baseline is valid.
      ftctl_ensure_dir "$(dirname "${baseline}")" "0750"
      tmp="${baseline}.tmp.$$"
      printf '%s\n' "${bitmap}" > "${tmp}" || return 1
      mv -f "${tmp}" "${baseline}" || return 1
    fi
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
}

ftctl_dr_ablestack_qcow2_live_source_baselines_ready() {
  local plan="${1-}" disk_map="${2-}" vm_name="" qmp_path="" rc=0
  local disk_json device bitmap baseline recorded tmp
  [[ -n "${plan}" && -s "${disk_map}" ]] || return 2
  vm_name="$(ftctl_dr_ablestack_json_field "${disk_map}" sourceDomain 2>/dev/null || true)"
  [[ -n "${vm_name}" ]] \
    || vm_name="$(ftctl_dr_ablestack_json_field "${disk_map}" source.instanceName 2>/dev/null || true)"
  [[ -n "${vm_name}" ]] || return 3

  qmp_path="$(mktemp "${TMPDIR:-/tmp}/ftctl-dr-qcow2-baseline.XXXXXX.json")" || return 2
  trap 'rm -f -- "${qmp_path:-}"; trap - RETURN' RETURN
  if ! virsh -c "${FTCTL_PROFILE_PRIMARY_URI:-qemu:///system}" qemu-monitor-command \
      "${vm_name}" --pretty '{"execute":"query-named-block-nodes"}' > "${qmp_path}" 2>/dev/null; then
    return 3
  fi

  python3 - "${disk_map}" "${qmp_path}" "${plan}" \
      "${FTCTL_DR_QCOW2_BITMAP_GRANULARITY:-65536}" <<'PY' || rc=$?
import json
import os
import re
import subprocess
import sys

disk_map_path, qmp_path, plan, granularity_text = sys.argv[1:5]
with open(disk_map_path, encoding="utf-8") as handle:
    disk_map = json.load(handle)
with open(qmp_path, encoding="utf-8") as handle:
    response = json.load(handle)
nodes = response.get("return") if isinstance(response, dict) else None
if not isinstance(nodes, list):
    raise SystemExit(1)

granularity = int(granularity_text)
for disk in disk_map.get("disks") or []:
    if str(disk.get("sourceType") or "").lower() != "file" \
            or str(disk.get("sourceFormat") or "").lower() != "qcow2":
        raise SystemExit(1)
    source_path = os.path.normpath(str(disk.get("sourcePath") or "").strip())
    device = str(disk.get("device") or "").strip()
    if not source_path or not device:
        raise SystemExit(1)
    matches = []
    for node in nodes:
        if not isinstance(node, dict) or node.get("drv") != "qcow2" or node.get("active") is not True:
            continue
        filename = str((node.get("image") or {}).get("filename") or node.get("file") or "").strip()
        if filename and os.path.normpath(filename) == source_path:
            matches.append(node)
    if len(matches) != 1:
        raise SystemExit(1)
    checksum = subprocess.check_output(
        ["cksum"], input=f"{plan}:{device}".encode("utf-8")
    ).decode("utf-8").split()[0]
    safe_device = re.sub(r"[^A-Za-z0-9._-]", "_", device)
    bitmap_name = f"ftctl-dr-{checksum}-{safe_device}"
    bitmaps = [item for item in matches[0].get("dirty-bitmaps") or []
               if isinstance(item, dict) and item.get("name") == bitmap_name]
    if len(bitmaps) != 1:
        raise SystemExit(1)
    bitmap = bitmaps[0]
    if bitmap.get("persistent") is not True or bitmap.get("recording") is not True \
            or bitmap.get("busy") is True or bitmap.get("inconsistent") is True \
            or int(bitmap.get("granularity") or 0) != granularity:
        raise SystemExit(1)
PY
  [[ "${rc}" == "0" ]] || return 1

  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    bitmap="$(ftctl_dr_ablestack_qcow2_bitmap_name "${plan}" "${device}")"
    baseline="$(ftctl_dr_ablestack_qcow2_bitmap_baseline_path "${plan}" "${device}")"
    recorded="$(head -n 1 "${baseline}" 2>/dev/null || true)"
    if [[ "${recorded}" != "${bitmap}" ]]; then
      ftctl_ensure_dir "$(dirname "${baseline}")" "0750"
      tmp="${baseline}.tmp.$$"
      printf '%s\n' "${bitmap}" > "${tmp}" || return 1
      mv -f "${tmp}" "${baseline}" || return 1
    fi
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
}

ftctl_dr_ablestack_qcow2_source_baselines_ready_for_runtime() {
  local plan="${1-}" disk_map="${2-}" rc=0
  ftctl_dr_ablestack_qcow2_live_source_baselines_ready "${plan}" "${disk_map}" || rc=$?
  case "${rc}" in
    0) return 0 ;;
    3) ftctl_dr_ablestack_qcow2_source_baselines_ready "${plan}" "${disk_map}" ;;
    *) return "${rc}" ;;
  esac
}

ftctl_dr_ablestack_probe_offline_qcow2_sources() {
  local disk_map="${1-}" root="" disk_json source_path bitmap rc=0
  ftctl_dr_ablestack_qcow2_source_root "${disk_map}" root || return 113
  while IFS= read -r disk_json; do
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    bitmap="$(ftctl_dr_ablestack_qcow2_bitmap_name probe "$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)")"
    rc=0
    python3 "${FTCTL_LIB_BASE}/ftctl/qcow2_bitmap_baseline.py" \
      --path "${source_path}" --storage-root "${root}" --bitmap "${bitmap}" \
      --granularity "${FTCTL_DR_QCOW2_BITMAP_GRANULARITY:-65536}" --probe-only \
      >/dev/null || rc=$?
    [[ "${rc}" == "0" ]] || return "${rc}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
}

ftctl_dr_ablestack_initialize_qcow2_source_baselines() {
  local plan="${1-}" sequence="${2-}" disk_map="${3-}" reset="${4-0}"
  local root="" disk_json device source_path bitmap baseline tmp rc=0
  local -a reset_args=()
  : "${sequence}"
  [[ "${reset}" == "1" ]] && reset_args+=(--reset)
  ftctl_dr_ablestack_qcow2_source_root "${disk_map}" root || return 113
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    bitmap="$(ftctl_dr_ablestack_qcow2_bitmap_name "${plan}" "${device}")"
    rc=0
    python3 "${FTCTL_LIB_BASE}/ftctl/qcow2_bitmap_baseline.py" \
      --path "${source_path}" --storage-root "${root}" --bitmap "${bitmap}" \
      --granularity "${FTCTL_DR_QCOW2_BITMAP_GRANULARITY:-65536}" "${reset_args[@]}" \
      >/dev/null || rc=$?
    [[ "${rc}" == "0" ]] || return "${rc}"
    baseline="$(ftctl_dr_ablestack_qcow2_bitmap_baseline_path "${plan}" "${device}")"
    tmp="${baseline}.tmp.$$"
    printf '%s\n' "${bitmap}" > "${tmp}" || return 2
    mv -f "${tmp}" "${baseline}" || return 2
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  ftctl_dr_ablestack_qcow2_source_baselines_ready "${plan}" "${disk_map}"
}

ftctl_dr_ablestack_clear_qcow2_source_baselines() {
  local plan="${1-}" sequence="${2-}" disk_map="${3-}"
  ftctl_dr_ablestack_qcow2_source_baselines_ready "${plan}" "${disk_map}" || return 116
  ftctl_dr_ablestack_initialize_qcow2_source_baselines "${plan}" "${sequence}" "${disk_map}" 1
}

ftctl_dr_ablestack_prepare_reverse_baseline() {
  local plan="${1-}" run="${2-}" checkpoint_sequence="${3-}" profile_file state_path
  local reverse_profile reverse_disk_map prepared_run prepared_sequence prepared_state now
  [[ -n "${plan}" && -n "${run}" && "${checkpoint_sequence}" =~ ^[0-9]+$ ]] || return 2
  profile_file="$(ftctl_dr_ablestack_export_persist_profile_path "${plan}")"
  ftctl_dr_runtime_remote_source_transition "${profile_file}" || return 0
  state_path="$(ftctl_dr_ablestack_reverse_baseline_state_path "${plan}")"
  prepared_run="$(ftctl_state_read_kv "${state_path}" run_uuid 2>/dev/null || true)"
  prepared_sequence="$(ftctl_state_read_kv "${state_path}" checkpoint_sequence 2>/dev/null || true)"
  prepared_state="$(ftctl_state_read_kv "${state_path}" state 2>/dev/null || true)"
  reverse_disk_map="$(ftctl_state_read_kv "${state_path}" disk_map_path 2>/dev/null || true)"
  if [[ "${prepared_run}" == "${run}" && "${prepared_sequence}" == "${checkpoint_sequence}" \
        && "${prepared_state}" == "READY" ]] \
      && ftctl_dr_ablestack_source_baselines_ready "${plan}" "${reverse_disk_map}"; then
    return 0
  fi
  reverse_profile="$(ftctl_dr_ablestack_checkpoint_dir "${plan}")/reverse-profile-$(ftctl_dr_runtime_key "${run}").json"
  reverse_disk_map="$(ftctl_dr_ablestack_checkpoint_dir "${plan}")/reverse-disk-map-$(ftctl_dr_runtime_key "${run}").json"
  ftctl_dr_runtime_build_reverse_profile "${plan}" "${run}" "${profile_file}" "${reverse_profile}" "failback" || return $?
  ftctl_dr_ablestack_canonicalize_profile "${reverse_profile}" "${reverse_disk_map}" || return $?
  ftctl_dr_ablestack_initialize_source_baselines "${plan}" "reverse-${checkpoint_sequence}" "${reverse_disk_map}" || return $?
  ftctl_dr_ablestack_source_baselines_ready "${plan}" "${reverse_disk_map}" || return 116
  now="$(ftctl_now_iso8601)"
  ftctl_state_write_kv_all "${state_path}" \
    "version=1" "plan_uuid=${plan}" "run_uuid=${run}" \
    "checkpoint_sequence=${checkpoint_sequence}" "state=READY" \
    "reverse_profile_path=${reverse_profile}" "disk_map_path=${reverse_disk_map}" \
    "prepared_at=${now}" "updated_at=${now}" || return 2
  ftctl_log_event "dr-runtime" "dr.ablestack.reverse_baseline" "ok" "" "" \
    "plan=${plan} run=${run} checkpoint=${checkpoint_sequence} state=READY"
}

ftctl_dr_ablestack_reverse_baseline_status() {
  local plan="${1-}" run="${2-}" checkpoint_sequence="${3-}" state_path prepared_run prepared_sequence state disk_map
  state_path="$(ftctl_dr_ablestack_reverse_baseline_state_path "${plan}")"
  prepared_run="$(ftctl_state_read_kv "${state_path}" run_uuid 2>/dev/null || true)"
  prepared_sequence="$(ftctl_state_read_kv "${state_path}" checkpoint_sequence 2>/dev/null || true)"
  state="$(ftctl_state_read_kv "${state_path}" state 2>/dev/null || true)"
  disk_map="$(ftctl_state_read_kv "${state_path}" disk_map_path 2>/dev/null || true)"
  if [[ "${state}" == "READY" \
        && ( -z "${run}" || "${prepared_run}" == "${run}" ) \
        && ( -z "${checkpoint_sequence}" || "${prepared_sequence}" == "${checkpoint_sequence}" ) ]] \
      && ftctl_dr_ablestack_source_baselines_ready "${plan}" "${disk_map}"; then
    printf 'READY\n'
  else
    printf 'FULL_SEED_REQUIRED\n'
  fi
}

ftctl_dr_ablestack_reverse_preflight() {
  local plan="${1-}" profile_file="${2-}" operation_intent="${3-FAILBACK_FINAL}" requested_mode="${4-AUTO}" json="${5-0}"
  local disk_map="" disk_json source_path target_path source_spec size_bytes reverse_source_root="" qcow2_provider="0" observed_format=""
  local rc=0 ready=true baseline_state="FULL_SEED_REQUIRED" effective_mode="FULL_RESEED"
  local decision_code="DR_REVERSE_BASELINE_FULL_SEED_REQUIRED" initial_seed=true
  local source_disk_probe_state="READY" source_disk_count=0 estimated_virtual_bytes=0
  local target_writer_probe_state="AGENT_VALIDATION_REQUIRED"
  local target_backing_probe_state="REMOTE_AGENT_VALIDATION_REQUIRED" error_code=""
  [[ -n "${plan}" && -f "${profile_file}" ]] || return 2

  disk_map="$(mktemp "${TMPDIR:-/tmp}/ftctl-ablestack-reverse-map.XXXXXX.json")"
  trap 'rm -f -- "${disk_map:-}"; trap - RETURN' RETURN
  if ! ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${disk_map}"; then
    rc=67
    ready=false
    error_code="DR_REVERSE_DISK_MAP_INVALID"
    source_disk_probe_state="NOT_CHECKED"
  fi

  if [[ "${rc}" == "0" ]]; then
    source_disk_count="$(ftctl_dr_ablestack_disk_count "${disk_map}" 2>/dev/null || printf 0)"
    [[ "${source_disk_count}" =~ ^[0-9]+$ ]] || source_disk_count=0
    if [[ "${source_disk_count}" == "0" ]]; then
      rc=67
      ready=false
      error_code="DR_REVERSE_DISK_MAP_INVALID"
      source_disk_probe_state="NOT_READY"
    fi
  fi

  if [[ "${rc}" == "0" ]]; then
    if ftctl_dr_ablestack_qcow2_reverse_source_provider "${disk_map}"; then
      qcow2_provider="1"
      reverse_source_root="$(ftctl_dr_ablestack_json_field "${profile_file}" target.storagePath 2>/dev/null || true)"
      [[ -n "${reverse_source_root}" ]] \
        || reverse_source_root="$(ftctl_dr_ablestack_json_field "${disk_map}" target.storagePath 2>/dev/null || true)"
    fi
    while IFS= read -r disk_json; do
      source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
      target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
      size_bytes="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sizeBytes)"
      [[ "${size_bytes}" =~ ^[0-9]+$ ]] || size_bytes=0
      estimated_virtual_bytes=$((estimated_virtual_bytes + size_bytes))
      if [[ "${qcow2_provider}" == "1" ]]; then
        observed_format=""
        # The persisted Plan mapping is forward-oriented. During failback the
        # promoted target disk is the reverse source, matching the RBD branch.
        if [[ -z "${reverse_source_root}" || ! -f "${target_path}" ]] \
            || ! ftctl_dr_ablestack_qemu_info_value "${target_path}" format observed_format \
            || [[ "${observed_format}" != "qcow2" ]]; then
          rc=82
          ready=false
          error_code="DR_REVERSE_SOURCE_STORAGE_MISSING"
          source_disk_probe_state="NOT_READY"
          break
        fi
        target_writer_probe_state="READY"
      elif ! ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" source_spec \
          || ! rbd info "${source_spec}" >/dev/null 2>&1; then
        rc=82
        ready=false
        error_code="DR_REVERSE_SOURCE_STORAGE_MISSING"
        source_disk_probe_state="NOT_READY"
        break
      fi
    done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  fi

  if [[ "${rc}" == "0" ]]; then
    baseline_state="$(ftctl_dr_ablestack_reverse_baseline_status "${plan}" "" "")"
    if [[ "${baseline_state}" == "READY" ]]; then
      if [[ "${qcow2_provider}" == "1" ]]; then
        effective_mode="QCOW2_INCREMENTAL"
        decision_code="DR_REVERSE_QCOW2_BASELINE_READY"
      else
        effective_mode="RBD_INCREMENTAL"
        decision_code="DR_REVERSE_BASELINE_READY"
      fi
      initial_seed=false
    fi
  fi

  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-reverse-preflight","schema_version":2,"contract_version":"dr-reverse-preflight-v2","result":"%s","ready":%s,"status_evidence_contract_version":1,"status_evidence_publication_ready":true,"status_evidence_error_code":"","plan_uuid":"%s","operation_intent":"%s","requested_mode":"%s","effective_mode":"%s","mode_decision_code":"%s","initial_seed_required":%s,"baseline_file_state":"%s","source_domain_probe_state":"NOT_APPLICABLE","source_disk_probe_state":"%s","source_disk_count":%s,"target_writer_probe_state":"%s","target_backing_probe_state":"%s","estimated_virtual_bytes":%s,"error_code":"%s","exit_code":%s}\n' \
      "$( [[ "${ready}" == "true" ]] && printf ok || printf error )" "${ready}" "$(ftctl__json_escape "${plan}")" \
      "$(ftctl__json_escape "${operation_intent}")" "$(ftctl__json_escape "${requested_mode}")" "$(ftctl__json_escape "${effective_mode}")" \
      "$(ftctl__json_escape "${decision_code}")" "${initial_seed}" "$(ftctl__json_escape "${baseline_state}")" \
      "$(ftctl__json_escape "${source_disk_probe_state}")" "${source_disk_count}" "$(ftctl__json_escape "${target_writer_probe_state}")" \
      "$(ftctl__json_escape "${target_backing_probe_state}")" "${estimated_virtual_bytes}" "$(ftctl__json_escape "${error_code}")" "${rc}"
  else
    printf 'ready=%s baseline=%s requested=%s effective=%s decision=%s source_disks=%s writer=%s\n' \
      "${ready}" "${baseline_state}" "${requested_mode}" "${effective_mode}" "${decision_code}" "${source_disk_count}" "${target_writer_probe_state}"
  fi
  return "${rc}"
}

ftctl_dr_ablestack_target_export_stop() (
  local plan="${1-}" lock_path
  lock_path="$(ftctl_dr_ablestack_target_export_lock_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${lock_path}")" "0750"
  exec 203>"${lock_path}"
  flock -w "${FTCTL_DR_TARGET_EXPORT_LOCK_TIMEOUT_SEC:-30}" 203 || return 93
  ftctl_dr_ablestack_target_export_stop_unlocked "$@"
)

ftctl_dr_ablestack_target_export_stop_unlocked() {
  local plan="${1-}" json="${2-0}" run="${3-}" checkpoint_sequence="${4-}" profile_file="${5-}"
  local manifest item stopped=0 action_intent="" reverse_baseline_state="NOT_REQUESTED" baseline_rc=0
  manifest="$(ftctl_dr_ablestack_export_manifest_path "${plan}")"
  if [[ -f "${profile_file}" ]]; then
    action_intent="$(jq -r '.request.actionIntent // empty' "${profile_file}" 2>/dev/null || true)"
  fi
  local export_generation
  export_generation="$(python3 "${BASH_SOURCE[0]%/*}/dr_export_ownership.py" \
    "$(ftctl_dr_ablestack_export_persist_dir "${plan}")" STOP "${profile_file}")" || return $?
  ftctl_dr_ablestack_export_persist_intent "${plan}" "${run}" "STOPPED" "" "" "STOPPING" || return $?
  if [[ "${export_generation}" -gt 0 ]]; then
    local owned_records
    owned_records="$(python3 "${BASH_SOURCE[0]%/*}/dr_export_ownership.py" records "${plan}" \
      "$(ftctl_dr_ablestack_export_persist_dir "${plan}")" "${profile_file}" "${manifest}")" || return 93
    while IFS= read -r item; do
      [[ -n "${item}" ]] || continue
      ftctl_dr_ablestack_target_export_stop_item "${item}" || return $?
      stopped=$((stopped + 1))
    done <<< "${owned_records}"
    rm -f "${manifest}"
  elif [[ -f "${manifest}" ]]; then
    local legacy_records
    legacy_records="$(jq -c '.exports[]' "${manifest}")" || return 93
    while IFS= read -r item; do
      [[ -n "${item}" ]] || continue
      ftctl_dr_ablestack_target_export_stop_item "${item}" || return $?
      stopped=$((stopped + 1))
    done <<< "${legacy_records}"
    rm -f "${manifest}"
  fi
  ftctl_dr_ablestack_export_persist_intent "${plan}" "${run}" "STOPPED" "" "" "STOPPED" || return $?
  if [[ ! "${action_intent}" =~ ^TEST_FAILOVER$ && -n "${run}" && "${checkpoint_sequence}" =~ ^[0-9]+$ ]]; then
    ftctl_dr_ablestack_prepare_reverse_baseline "${plan}" "${run}" "${checkpoint_sequence}" || baseline_rc=$?
    if [[ "${baseline_rc}" != "0" ]]; then
      if [[ "${json}" == "1" ]]; then
        printf '{"command":"dr-target-export-stop","result":"error","accepted":false,"state":"STOPPED","step":"reverse-baseline-failed","progress":100,"stopped":%s,"reverse_baseline_state":"FAILED","error_code":"DR_REVERSE_BASELINE_PREPARE_FAILED","exit_code":%s}\n' \
          "${stopped}" "${baseline_rc}"
      else
        printf 'target exports stopped but reverse baseline preparation failed: plan=%s count=%s exit_code=%s\n' \
          "${plan}" "${stopped}" "${baseline_rc}" >&2
      fi
      return "${baseline_rc}"
    fi
    reverse_baseline_state="$(ftctl_dr_ablestack_reverse_baseline_status "${plan}" "${run}" "${checkpoint_sequence}")"
  fi
  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-target-export-stop","result":"ok","accepted":true,"state":"STOPPED","step":"target-export-stopped","progress":100,"ownershipProtocol":1,"exportGeneration":%s,"stopped":%s,"reverse_baseline_state":"%s"}\n' "${export_generation}" "${stopped}" "$(ftctl__json_escape "${reverse_baseline_state}")" | python3 -c 'import json,sys,os; result=json.load(sys.stdin); owner=json.load(open(sys.argv[1])) if os.path.isfile(sys.argv[1]) else {}; result.update({"ownershipProtocol":2,"exportAuthorityScope":owner["scope"],"exportDirection":owner["direction"]} if owner.get("scope") else {}); print(json.dumps(result,separators=(",",":")))' "$(ftctl_dr_ablestack_export_persist_dir "${plan}")/ownership.json"
  else
    printf 'target exports stopped: plan=%s count=%s reverse_baseline=%s\n' "${plan}" "${stopped}" "${reverse_baseline_state}"
  fi
}

ftctl_dr_ablestack_target_export_reconcile_all() {
  local json="${1-0}" root intent plan run desired profile manifest rc=0 restored=0 failed=0
  root="$(ftctl_dr_ablestack_export_persist_root)"
  [[ -d "${root}" ]] || return 0
  while IFS= read -r intent; do
    desired="$(jq -r '.desiredState // "STOPPED"' "${intent}" 2>/dev/null || printf STOPPED)"
    [[ "${desired}" == "RUNNING" ]] || continue
    plan="$(jq -r '.planUuid // empty' "${intent}" 2>/dev/null || true)"
    run="$(jq -r '.runUuid // "target-reconcile"' "${intent}" 2>/dev/null || true)"
    [[ -n "${plan}" ]] || continue
    profile="$(ftctl_dr_ablestack_export_persist_profile_path "${plan}")"
    manifest="$(ftctl_dr_ablestack_export_manifest_path "${plan}")"
    if [[ -f "$(ftctl_dr_ablestack_export_persist_dir "${plan}")/ownership.json" ]] \
      && [[ "$(jq -r '.operation' "$(ftctl_dr_ablestack_export_persist_dir "${plan}")/ownership.json")" == "STOP" ]]; then
      continue
    fi
    if [[ -f "${manifest}" ]] && python3 - "${manifest}" <<'PY'
import json, os, signal, socket, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data=json.load(fh)
items=data.get("exports") or []
if not items:
    raise SystemExit(1)
for item in items:
    pid_file=str(item.get("pidFile") or "")
    try:
        with open(pid_file, encoding="utf-8") as fh:
            pid=int(fh.read().strip())
        os.kill(pid, 0)
        with socket.create_connection((str(item.get("host") or "127.0.0.1"), int(item.get("port"))), timeout=1):
            pass
    except Exception:
        raise SystemExit(1)
PY
    then
      continue
    fi
    rm -f "${manifest}" 2>/dev/null || true
    if [[ -f "${profile}" ]] && ftctl_dr_ablestack_target_export_start "${plan}" "${run}" "${profile}" "0" >/dev/null; then
      restored=$((restored + 1))
      ftctl_log_event "dr-runtime" "dr.ablestack.target_export_reconcile" "ok" "" "" \
        "plan=${plan} run=${run} desired=RUNNING"
    else
      failed=$((failed + 1))
      rc=1
      ftctl_log_event "dr-runtime" "dr.ablestack.target_export_reconcile" "fail" "" "DR_TARGET_EXPORT_UNAVAILABLE" \
        "plan=${plan} run=${run} desired=RUNNING"
    fi
  done < <(find "${root}" -mindepth 2 -maxdepth 2 -type f -name intent.json -print 2>/dev/null | sort)
  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-target-export-reconcile","result":"%s","restored":%s,"failed":%s}\n' \
      "$([[ "${rc}" == "0" ]] && printf ok || printf partial)" "${restored}" "${failed}"
  fi
  return "${rc}"
}

ftctl_dr_ablestack_remote_rbd_path() {
  local target_path="${1-}" out_var="${2}" spec=""
  ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" spec || return 1
  printf -v "${out_var}" '/dev/rbd/%s' "${spec}"
}

ftctl_dr_ablestack_remote_nbd_stop() {
  local vm="${1-}" device="${2-}" port="${3-}" host="" user="" out="" err="" rc=0 pid_file=""
  ftctl_blockcopy_remote_target_host_user host user || return 2
  pid_file="/run/ablestack-vm-ftctl/nbd-${vm}-${device}.pid"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "$(cat <<EOF
set -euo pipefail
if [[ -f '${pid_file}' ]]; then
  pid=\$(cat '${pid_file}' 2>/dev/null || true)
  [[ -z \"\${pid}\" ]] || kill \"\${pid}\" >/dev/null 2>&1 || true
  rm -f '${pid_file}'
fi
for pid in \$(ss -lntp | awk '/:${port}[[:space:]]/ {while (match(\$0,/pid=[0-9]+/)){print substr(\$0,RSTART+4,RLENGTH-4);\$0=substr(\$0,RSTART+RLENGTH)}}' | sort -u); do
  kill \"\${pid}\" >/dev/null 2>&1 || true
done
EOF
)" || true
  [[ "${rc}" == "0" ]]
}

ftctl_dr_ablestack_append_disk_record() {
  local records_path="${1-}" disk_json="${2-}" source_format="${3-}" target_format="${4-}" resolved_size="${5-}" source_type="${6-}" target_type="${7-}"
  python3 - "${records_path}" "${disk_json}" "${source_format}" "${target_format}" "${resolved_size}" "${source_type}" "${target_type}" <<'PY'
import json
import sys

records_path, disk_json, source_format, target_format, resolved_size, source_type, target_type = sys.argv[1:8]
disk = json.loads(disk_json)
disk.update({
    "sourceFormat": source_format,
    "targetFormat": target_format,
    "sizeBytes": int(resolved_size or "0"),
    "sourceType": source_type,
    "targetType": target_type,
})
with open(records_path, "a", encoding="utf-8") as fh:
    json.dump(disk, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
PY
}

ftctl_dr_ablestack_rbd_spec_from_path() {
  local path="${1-}" out_var="${2}"
  local rbd_spec=""
  case "${path}" in
    rbd:*) rbd_spec="${path#rbd:}" ;;
    /dev/rbd/*/*) rbd_spec="${path#/dev/rbd/}" ;;
    rbd/*/*) rbd_spec="${path#rbd/}" ;;
    *) return 1 ;;
  esac
  [[ "${rbd_spec}" == */* && "${rbd_spec}" != */ ]] || return 1
  printf -v "${out_var}" '%s' "${rbd_spec}"
}

ftctl_dr_ablestack_qemu_info_value() {
  local path="${1-}" field="${2-}" out_var="${3}"
  local out="" err="" rc=0 value=""
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
    qemu-img info --force-share --output=json "${path}" || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi
  value="$(python3 -c 'import json,sys; obj=json.loads(sys.argv[1]); print(obj.get(sys.argv[2], ""))' "${out}" "${field}")" || return 1
  printf -v "${out_var}" '%s' "${value}"
}

ftctl_dr_ablestack_source_size_bytes() {
  local device="${1-}" source_path="${2-}" explicit_size="${3-}" out_var="${4}"
  local size=""
  if [[ "${explicit_size}" =~ ^[1-9][0-9]*$ ]]; then
    printf -v "${out_var}" '%s' "${explicit_size}"
    return 0
  fi
  ftctl_blockcopy_source_virtual_size_bytes "" "${device}" "${source_path}" size || return $?
  [[ "${size}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf -v "${out_var}" '%s' "${size}"
}

ftctl_dr_ablestack_qcow2_push_provider() {
  local disk_map="${1-}" disk_json source_type source_format target_type target_format count=0
  [[ -s "${disk_map}" ]] || return 1
  while IFS= read -r disk_json; do
    source_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceType)"
    source_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceFormat)"
    target_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetType)"
    target_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetFormat)"
    [[ "${source_type}" == "file" && "${source_format}" == "qcow2" ]] || return 1
    case "${target_type}:${target_format}" in
      file:qcow2|rbd:raw|rbd:) ;;
      *) return 1 ;;
    esac
    count=$((count + 1))
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  (( count > 0 ))
}

ftctl_dr_ablestack_qcow2_source_provider() {
  local disk_map="${1-}" disk_json source_type source_format count=0
  [[ -s "${disk_map}" ]] || return 1
  while IFS= read -r disk_json; do
    source_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceType)"
    source_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceFormat)"
    [[ "${source_type}" == "file" && "${source_format}" == "qcow2" ]] || return 1
    count=$((count + 1))
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  (( count > 0 ))
}

ftctl_dr_ablestack_cutover_source_supported() {
  local disk_map="${1-}" disk_json source_type source_format source_path count=0
  [[ -s "${disk_map}" ]] || return 1
  while IFS= read -r disk_json; do
    source_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceType)"
    source_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceFormat)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    case "${source_type,,}:${source_format,,}" in
      file:qcow2)
        [[ -n "${source_path}" ]] || return 1
        ;;
      rbd:raw|rbd:)
        [[ "${source_path}" == rbd:* ]] || return 1
        ;;
      *)
        return 1
        ;;
    esac
    count=$((count + 1))
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  (( count > 0 ))
}

ftctl_dr_ablestack_qcow2_runtime_ready() {
  local disk_map="${1-}" vm_name="${2-}" qmp_path rc=0
  [[ -s "${disk_map}" && -n "${vm_name}" ]] || return 1
  qmp_path="$(mktemp "${TMPDIR:-/tmp}/ftctl-dr-qcow2-runtime.XXXXXX.json")" || return 2
  trap 'rm -f -- "${qmp_path:-}"; trap - RETURN' RETURN
  virsh -c "${FTCTL_PROFILE_PRIMARY_URI:-qemu:///system}" qemu-monitor-command "${vm_name}" --pretty \
    '{"execute":"query-named-block-nodes"}' > "${qmp_path}" 2>/dev/null || return 1
  python3 - "${disk_map}" "${qmp_path}" <<'PY' || rc=$?
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    disk_map = json.load(fh)
with open(sys.argv[2], encoding="utf-8") as fh:
    response = json.load(fh)
nodes = response.get("return") if isinstance(response, dict) else None
if not isinstance(nodes, list):
    raise SystemExit(1)
active = {
    os.path.normpath(str((node.get("image") or {}).get("filename") or node.get("file") or ""))
    for node in nodes
    if isinstance(node, dict) and node.get("drv") == "qcow2" and node.get("active") is True
}
sources = {
    os.path.normpath(str(disk.get("sourcePath") or ""))
    for disk in disk_map.get("disks") or []
}
if not sources or "" in sources or not sources.issubset(active):
    raise SystemExit(1)
PY
  [[ "${rc}" == "0" ]]
}

ftctl_dr_ablestack_validate_configured_qcow2_sources() {
  local disk_map="${1-}" disk_json source_type source_format source_path actual_format count=0
  [[ -s "${disk_map}" ]] || return 1
  while IFS= read -r disk_json; do
    source_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceType)"
    source_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceFormat)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    [[ "${source_type}" == "file" && "${source_format}" == "qcow2" && -n "${source_path}" ]] || return 1
    [[ -f "${source_path}" ]] || return 1
    actual_format=""
    ftctl_dr_ablestack_qemu_info_value "${source_path}" format actual_format || return 1
    [[ "${actual_format,,}" == "qcow2" ]] || return 1
    count=$((count + 1))
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  (( count > 0 ))
}

ftctl_dr_ablestack_rebind_live_qcow2_sources() {
  local plan="${1-}" disk_map="${2-}" source_provider source_driver vm_name
  local qmp_path tmp_path result="" rebound_count="0"
  [[ -n "${plan}" && -s "${disk_map}" ]] || return 2

  source_provider="$(ftctl_dr_ablestack_json_field "${disk_map}" sourceProvider 2>/dev/null || true)"
  source_driver="$(ftctl_dr_ablestack_json_field "${disk_map}" sourceDriver 2>/dev/null || true)"
  [[ "${source_provider}" == "ABLESTACK" && "${source_driver}" == "KVM_QMP" ]] || return 0
  jq -e '.disks | length > 0 and all(.[];
      (.sourceType // "" | ascii_downcase) == "file"
      and ((.sourceFormat // "" | ascii_downcase) == "" or (.sourceFormat // "" | ascii_downcase) == "qcow2")
      and (.targetType // "" | ascii_downcase) == "file"
      and (.targetFormat // "" | ascii_downcase) == "qcow2")' "${disk_map}" >/dev/null 2>&1 || return 0

  vm_name="$(ftctl_dr_ablestack_json_field "${disk_map}" source.instanceName 2>/dev/null || true)"
  if [[ -z "${vm_name}" ]]; then
    ftctl_dr_ablestack_validate_configured_qcow2_sources "${disk_map}" || return 32
    return 0
  fi
  qmp_path="$(mktemp "${TMPDIR:-/tmp}/ftctl-dr-qcow2-nodes.XXXXXX.json")" || return 2
  tmp_path="${disk_map}.live-source.$$"
  trap 'rm -f -- "${qmp_path:-}" "${tmp_path:-}"; trap - RETURN' RETURN

  if ! virsh -c "${FTCTL_PROFILE_PRIMARY_URI:-qemu:///system}" qemu-monitor-command "${vm_name}" --pretty \
      '{"execute":"query-named-block-nodes"}' > "${qmp_path}" 2>/dev/null; then
    ftctl_dr_ablestack_validate_configured_qcow2_sources "${disk_map}" || return 32
    ftctl_log_event "dr-runtime" "dr.ablestack.qcow2_source_verified" "ok" "" "" \
      "plan=${plan} vm=${vm_name} source=profile runtime_probe=unavailable"
    return 0
  fi

  result="$(python3 - "${disk_map}" "${qmp_path}" "${tmp_path}" <<'PY'
import json
import os
import sys

disk_map_path, qmp_path, output_path = sys.argv[1:4]
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)
with open(qmp_path, "r", encoding="utf-8") as fh:
    response = json.load(fh)

nodes = response.get("return") if isinstance(response, dict) else None
if not isinstance(nodes, list):
    raise SystemExit("QMP named block node response is invalid")

candidates = []
for node in nodes:
    if not isinstance(node, dict) or node.get("drv") != "qcow2" or node.get("active") is not True:
        continue
    path = str((node.get("image") or {}).get("filename") or node.get("file") or "").strip()
    if path and os.path.isabs(path):
        candidates.append((os.path.normpath(path), int((node.get("image") or {}).get("virtual-size") or 0)))

rebound = []
for disk in disk_map.get("disks") or []:
    source_format = str(disk.get("sourceFormat") or "").lower()
    if str(disk.get("sourceType") or "").lower() != "file" or source_format not in ("", "qcow2"):
        continue
    configured = os.path.normpath(str(disk.get("sourcePath") or "").strip())
    exact = [item for item in candidates if item[0] == configured]
    if exact:
        disk["sourceType"] = "file"
        disk["sourceFormat"] = "qcow2"
        continue
    identity = str(disk.get("device") or "").strip()
    expected_size = int(disk.get("sizeBytes") or 0)
    matches = []
    for path, size in candidates:
        base = os.path.basename(path)
        identity_match = identity and (base == identity or base.startswith(identity + "-"))
        size_match = expected_size <= 0 or size <= 0 or size == expected_size
        if identity_match and size_match:
            matches.append((path, size))
    if len(matches) != 1:
        raise SystemExit(f"active qcow2 source path was not uniquely resolved for {identity or configured}")
    live_path = matches[0][0]
    rebound.append((identity, configured, live_path))
    disk["sourcePath"] = live_path
    disk["sourceType"] = "file"
    disk["sourceFormat"] = "qcow2"

with open(output_path, "w", encoding="utf-8") as fh:
    json.dump(disk_map, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
print(len(rebound))
for identity, old_path, live_path in rebound:
    print(f"{identity}\t{old_path}\t{live_path}")
PY
)" || return 32

  mv -f "${tmp_path}" "${disk_map}" || return 2
  rebound_count="$(head -n 1 <<< "${result}")"
  if [[ "${rebound_count}" =~ ^[1-9][0-9]*$ ]]; then
    while IFS=$'\t' read -r device old_path live_path; do
      [[ -n "${device}${old_path}${live_path}" ]] || continue
      ftctl_log_event "dr-runtime" "dr.ablestack.qcow2_source_rebound" "ok" "" "" \
        "plan=${plan} device=${device} configured=${old_path} live=${live_path}"
    done < <(tail -n +2 <<< "${result}")
  fi
}

ftctl_dr_ablestack_qmp_status() {
  local vm_name="${1-}" out_var="${2-}" out="" err="" rc=0 parsed_status=""
  [[ -n "${vm_name}" && -n "${out_var}" ]] || return 2
  ftctl_cmd_run "${FTCTL_DR_QMP_QUIESCE_TIMEOUT_SEC:-30}" out err rc -- \
    virsh -c "${FTCTL_PROFILE_PRIMARY_URI:-qemu:///system}" qemu-monitor-command \
      "${vm_name}" --pretty '{"execute":"query-status"}' || true
  [[ "${rc}" == "0" ]] || return 101
  parsed_status="$(jq -r '.return.status // ""' <<< "${out}" 2>/dev/null || true)"
  [[ -n "${parsed_status}" ]] || return 101
  printf -v "${out_var}" '%s' "${parsed_status}"
}

ftctl_dr_ablestack_qmp_lifecycle() {
  local vm_name="${1-}" command="${2-}" out="" err="" rc=0
  [[ -n "${vm_name}" && ( "${command}" == "stop" || "${command}" == "cont" ) ]] || return 2
  ftctl_cmd_run "${FTCTL_DR_QMP_QUIESCE_TIMEOUT_SEC:-30}" out err rc -- \
    virsh -c "${FTCTL_PROFILE_PRIMARY_URI:-qemu:///system}" qemu-monitor-command \
      "${vm_name}" --pretty "{\"execute\":\"${command}\"}" || true
  [[ "${rc}" == "0" ]] || return 101
  ! jq -e '.error != null' <<< "${out}" >/dev/null 2>&1
}

ftctl_dr_ablestack_wait_qmp_status() {
  local vm_name="${1-}" expected="${2-}" timeout_sec="${3-${FTCTL_DR_QMP_QUIESCE_TIMEOUT_SEC:-30}}"
  local started now status=""
  [[ -n "${vm_name}" && -n "${expected}" && "${timeout_sec}" =~ ^[1-9][0-9]*$ ]] || return 2
  started="$(date +%s)"
  while true; do
    status=""
    if ftctl_dr_ablestack_qmp_status "${vm_name}" status && [[ "${status}" == "${expected}" ]]; then
      return 0
    fi
    now="$(date +%s)"
    (( now - started < timeout_sec )) || return 102
    sleep 1
  done
}

ftctl_dr_ablestack_cutover_quiesce_required() {
  local profile_file="${1-}"
  [[ -s "${profile_file}" ]] || return 1
  jq -e '.request.sourceRuntimeQuiesceRequired == true
      and ((.request.sourceRuntimeQuiesceMode // "") == "QMP_STOP"
        or (.request.sourceRuntimeQuiesceMode // "") == "SOURCE_ALREADY_STOPPED")
      and ((.request.cutoverRunUuid // "") | length > 0)' \
    "${profile_file}" >/dev/null 2>&1
}

ftctl_dr_ablestack_cutover_quiesce_begin() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}"
  local disk_map frozen_map quiesce_path owner state mode vm_name qmp_state="" digest tmp now
  local requested_mode observed_power initial_state
  [[ -n "${plan}" && -n "${run}" && -s "${profile_file}" ]] || return 2
  ftctl_dr_ablestack_cutover_quiesce_required "${profile_file}" || return 0

  disk_map="$(ftctl_dr_ablestack_disk_map_path "${plan}")"
  frozen_map="$(ftctl_dr_ablestack_cutover_source_map_path "${plan}" "${run}")"
  quiesce_path="$(ftctl_dr_ablestack_cutover_quiesce_path "${plan}" "${run}")"
  requested_mode="$(jq -r '.request.sourceRuntimeQuiesceMode // ""' "${profile_file}" 2>/dev/null || true)"
  observed_power="$(jq -r '.request.sourceRuntimeObservedPowerState // ""' "${profile_file}" 2>/dev/null || true)"
  if [[ "${requested_mode}" == "SOURCE_ALREADY_STOPPED" && "${observed_power}" != "POWERED_OFF" ]]; then
    return 108
  fi
  ftctl_ensure_dir "$(dirname "${frozen_map}")" "0755"

  if [[ -s "${quiesce_path}" ]]; then
    owner="$(ftctl_state_read_kv "${quiesce_path}" owner_run 2>/dev/null || true)"
    state="$(ftctl_state_read_kv "${quiesce_path}" state 2>/dev/null || true)"
    mode="$(ftctl_state_read_kv "${quiesce_path}" mode 2>/dev/null || true)"
    [[ -z "${owner}" || "${owner}" == "${run}" ]] || return 79
    vm_name="$(ftctl_state_read_kv "${quiesce_path}" vm_name 2>/dev/null || true)"
    if [[ "${state}" == "PAUSED" ]] && ftctl_dr_ablestack_qmp_status "${vm_name}" qmp_state \
        && [[ "${qmp_state}" == "paused" ]]; then
      return 0
    fi
    if [[ "${state}" == "OFFLINE" && "${mode}" == "SOURCE_ALREADY_STOPPED" \
        && "${requested_mode}" == "SOURCE_ALREADY_STOPPED" && "${observed_power}" == "POWERED_OFF" ]]; then
      return 0
    fi
  fi

  ftctl_dr_ablestack_prepare_cycle_disk_map "${plan}" "${profile_file}" "${disk_map}" "PRE_CUTOVER_CAPTURE" || return $?
  ftctl_dr_ablestack_cutover_source_supported "${disk_map}" || return 90
  vm_name="$(ftctl_dr_ablestack_json_field "${disk_map}" source.instanceName 2>/dev/null || true)"
  [[ -n "${vm_name}" ]] || return 32
  if [[ "${requested_mode}" == "SOURCE_ALREADY_STOPPED" ]]; then
    ftctl_dr_ablestack_qcow2_source_baselines_ready "${plan}" "${disk_map}" || return 109
    qmp_state="powered-off-observed"
    initial_state="OFFLINE"
  else
    ftctl_dr_ablestack_qmp_status "${vm_name}" qmp_state || return $?
    [[ "${qmp_state}" == "running" || "${qmp_state}" == "paused" ]] || return 103
    if [[ "${qmp_state}" == "paused" && ! -s "${quiesce_path}" ]]; then
      return 103
    fi
    initial_state="QUIESCING"
  fi

  tmp="${frozen_map}.tmp.$$"
  cp -f "${disk_map}" "${tmp}" || return 2
  mv -f "${tmp}" "${frozen_map}" || return 2
  digest="$(sha256sum "${frozen_map}" | awk '{print $1}')"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 2
  now="$(ftctl_now_iso8601)"
  ftctl_state_write_kv_all "${quiesce_path}" \
    "plan=${plan}" "owner_run=${run}" "state=${initial_state}" "mode=${requested_mode}" \
    "vm_name=${vm_name}" "previous_status=${qmp_state}" \
    "frozen_map_path=${frozen_map}" "frozen_map_sha256=${digest}" \
    "updated_at=${now}" || return 2

  if [[ "${requested_mode}" == "SOURCE_ALREADY_STOPPED" ]]; then
    if [[ -n "${run_path}" ]]; then
      ftctl_dr_runtime_path_set "${run_path}" \
        "source_runtime_quiesce_state=OFFLINE" \
        "source_runtime_quiesce_mode=SOURCE_ALREADY_STOPPED" \
        "source_runtime_quiesce_owner_run=${run}" \
        "source_power_state=POWERED_OFF" \
        "cutover_source_disk_map_path=${frozen_map}" \
        "cutover_source_disk_map_sha256=${digest}" \
        "source_runtime_quiesced_at=${now}" || true
      [[ -n "${status_path}" ]] && cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    fi
    ftctl_log_event "dr-runtime" "dr.ablestack.source_quiesce" "ok" "" "" \
      "plan=${plan} run=${run} vm=${vm_name} mode=SOURCE_ALREADY_STOPPED map=${frozen_map} sha256=${digest}"
    return 0
  fi

  if [[ "${qmp_state}" != "paused" ]]; then
    ftctl_dr_ablestack_qmp_lifecycle "${vm_name}" stop || return $?
  fi
  if ! ftctl_dr_ablestack_wait_qmp_status "${vm_name}" paused; then
    ftctl_dr_ablestack_qmp_lifecycle "${vm_name}" cont >/dev/null 2>&1 || true
    ftctl_state_set_path "${quiesce_path}" "state=FAILED" "updated_at=$(ftctl_now_iso8601)" || true
    return 104
  fi

  now="$(ftctl_now_iso8601)"
  ftctl_state_set_path "${quiesce_path}" "state=PAUSED" "paused_at=${now}" "updated_at=${now}" || return 2
  if [[ -n "${run_path}" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "source_runtime_quiesce_state=PAUSED" \
      "source_runtime_quiesce_mode=QMP_STOP" \
      "source_runtime_quiesce_owner_run=${run}" \
      "cutover_source_disk_map_path=${frozen_map}" \
      "cutover_source_disk_map_sha256=${digest}" \
      "source_runtime_quiesced_at=${now}" || true
    [[ -n "${status_path}" ]] && cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  fi
  ftctl_log_event "dr-runtime" "dr.ablestack.source_quiesce" "ok" "" "" \
    "plan=${plan} run=${run} vm=${vm_name} mode=QMP_STOP map=${frozen_map} sha256=${digest}"
}

ftctl_dr_ablestack_cutover_quiesce_release() {
  local plan="${1-}" run="${2-}" run_path="${3-}" status_path="${4-}"
  local quiesce_path owner state mode vm_name qmp_state="" now
  [[ -n "${plan}" && -n "${run}" ]] || return 2
  quiesce_path="$(ftctl_dr_ablestack_cutover_quiesce_path "${plan}" "${run}")"
  [[ -s "${quiesce_path}" ]] || return 0
  owner="$(ftctl_state_read_kv "${quiesce_path}" owner_run 2>/dev/null || true)"
  [[ -z "${owner}" || "${owner}" == "${run}" ]] || return 79
  state="$(ftctl_state_read_kv "${quiesce_path}" state 2>/dev/null || true)"
  mode="$(ftctl_state_read_kv "${quiesce_path}" mode 2>/dev/null || true)"
  vm_name="$(ftctl_state_read_kv "${quiesce_path}" vm_name 2>/dev/null || true)"
  if [[ "${mode}" == "SOURCE_ALREADY_STOPPED" ]]; then
    qmp_state="powered-off"
  elif ftctl_dr_ablestack_qmp_status "${vm_name}" qmp_state; then
    if [[ "${qmp_state}" == "paused" ]]; then
      ftctl_dr_ablestack_qmp_lifecycle "${vm_name}" cont || return $?
      ftctl_dr_ablestack_wait_qmp_status "${vm_name}" running || return $?
      qmp_state="running"
    fi
  else
    qmp_state="domain-absent"
  fi
  now="$(ftctl_now_iso8601)"
  ftctl_state_set_path "${quiesce_path}" \
    "state=RELEASED" "released_status=${qmp_state}" "released_at=${now}" "updated_at=${now}" || return 2
  if [[ -n "${run_path}" && -f "${run_path}" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "source_runtime_quiesce_state=RELEASED" \
      "source_runtime_quiesce_released_at=${now}" || true
    [[ -n "${status_path}" ]] && cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  fi
  ftctl_log_event "dr-runtime" "dr.ablestack.source_quiesce" "ok" "" "" \
    "plan=${plan} run=${run} vm=${vm_name} action=release result=${qmp_state} previous=${state}"
}

ftctl_dr_ablestack_load_frozen_cutover_map() {
  local plan="${1-}" profile_file="${2-}" disk_map="${3-}"
  local owner frozen_map quiesce_path state mode observed_power recorded_digest actual_digest vm_name qmp_state="" tmp
  owner="$(jq -r '.request.cutoverRunUuid // ""' "${profile_file}" 2>/dev/null || true)"
  [[ -n "${owner}" ]] || return 105
  frozen_map="$(ftctl_dr_ablestack_cutover_source_map_path "${plan}" "${owner}")"
  quiesce_path="$(ftctl_dr_ablestack_cutover_quiesce_path "${plan}" "${owner}")"
  [[ -s "${frozen_map}" && -s "${quiesce_path}" ]] || return 105
  [[ "$(ftctl_state_read_kv "${quiesce_path}" owner_run 2>/dev/null || true)" == "${owner}" ]] || return 79
  state="$(ftctl_state_read_kv "${quiesce_path}" state 2>/dev/null || true)"
  mode="$(ftctl_state_read_kv "${quiesce_path}" mode 2>/dev/null || true)"
  observed_power="$(jq -r '.request.sourceRuntimeObservedPowerState // ""' "${profile_file}" 2>/dev/null || true)"
  [[ "${state}" == "PAUSED" || "${state}" == "OFFLINE" ]] || return 106
  recorded_digest="$(ftctl_state_read_kv "${quiesce_path}" frozen_map_sha256 2>/dev/null || true)"
  actual_digest="$(sha256sum "${frozen_map}" | awk '{print $1}')"
  [[ "${recorded_digest}" =~ ^[0-9a-f]{64}$ && "${actual_digest}" == "${recorded_digest}" ]] || return 107
  ftctl_dr_ablestack_cutover_source_supported "${frozen_map}" || return 90
  if [[ "${state}" == "OFFLINE" ]]; then
    [[ "${mode}" == "SOURCE_ALREADY_STOPPED" && "${observed_power}" == "POWERED_OFF" ]] || return 108
    ftctl_dr_ablestack_qcow2_source_baselines_ready "${plan}" "${frozen_map}" || return 109
  else
    [[ "${mode}" == "QMP_STOP" ]] || return 106
    vm_name="$(ftctl_state_read_kv "${quiesce_path}" vm_name 2>/dev/null || true)"
    ftctl_dr_ablestack_qmp_status "${vm_name}" qmp_state || return 101
    [[ "${qmp_state}" == "paused" ]] || return 106
  fi
  tmp="${disk_map}.frozen.$$"
  cp -f "${frozen_map}" "${tmp}" || return 2
  mv -f "${tmp}" "${disk_map}" || return 2
}

ftctl_dr_ablestack_prepare_cycle_disk_map() {
  local plan="${1-}" profile_file="${2-}" disk_map="${3-}" cycle_type="${4-}" rc=0 normalized_cycle_type
  normalized_cycle_type="$(ftctl_dr_ablestack_normalize_cycle_type "${cycle_type}")"
  if [[ "${normalized_cycle_type}" == "FAILOVER_FINAL" ]] \
      && ftctl_dr_ablestack_cutover_quiesce_required "${profile_file}"; then
    ftctl_dr_ablestack_load_frozen_cutover_map "${plan}" "${profile_file}" "${disk_map}" || {
      rc=$?
      ftctl_log_event "dr-runtime" "dr.ablestack.disk_map_refresh" "fail" "" "${rc}" \
        "plan=${plan} stage=load_frozen_cutover_source"
      return "${rc}"
    }
    return 0
  fi
  ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${disk_map}" || {
    rc=$?
    ftctl_log_event "dr-runtime" "dr.ablestack.disk_map_refresh" "fail" "" "${rc}" \
      "plan=${plan} stage=canonicalize_profile"
    return "${rc}"
  }
  ftctl_dr_ablestack_rebind_live_qcow2_sources "${plan}" "${disk_map}" || {
    rc=$?
    ftctl_log_event "dr-runtime" "dr.ablestack.disk_map_refresh" "fail" "" "${rc}" \
      "plan=${plan} stage=rebind_live_qcow2_source"
    return "${rc}"
  }
}

ftctl_dr_ablestack_qcow2_reverse_source_provider() {
  local disk_map="${1-}" disk_json target_type target_format count=0
  [[ -s "${disk_map}" ]] || return 1
  while IFS= read -r disk_json; do
    target_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetType)"
    target_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetFormat)"
    [[ "${target_type}" == "file" && "${target_format}" == "qcow2" ]] || return 1
    count=$((count + 1))
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  (( count > 0 ))
}

ftctl_dr_ablestack_qcow2_bitmap_name() {
  local plan="${1-}" device="${2-}" checksum
  checksum="$(printf '%s' "${plan}:${device}" | cksum | awk '{print $1}')"
  printf 'ftctl-dr-%s-%s\n' "${checksum}" "$(ftctl_dr_runtime_key "${device}")"
}

ftctl_dr_ablestack_qcow2_push_disk() {
  local plan="${1-}" run="${2-}" sequence="${3-}" mode="${4-}" vm_name="${5-}" disk_map="${6-}" disk_json="${7-}"
  local disk_index="${8-1}" disk_count="${9-1}" out_var="${10-}"
  local device source_path size_bytes host port name bitmap job_id target_node output="" rc=0 bandwidth
  device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
  source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
  size_bytes="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sizeBytes)"
  host="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" host)"
  port="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" port)"
  name="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" name)"
  [[ -n "${vm_name}" && -n "${source_path}" && "${size_bytes}" =~ ^[1-9][0-9]*$ ]] || return 32
  [[ -n "${host}" && "${port}" =~ ^[1-9][0-9]*$ && -n "${name}" ]] || return 100
  ftctl_dr_ablestack_target_export_reachable "${host}" "${port}" || return 100
  bitmap="$(ftctl_dr_ablestack_qcow2_bitmap_name "${plan}" "${device}")"
  job_id="ftctl-dr-$(printf '%s' "${run}:${device}" | cksum | awk '{print $1}')"
  target_node="ftctl-dr-target-$(printf '%s' "${plan}:${device}" | cksum | awk '{print $1}')"
  bandwidth="${FTCTL_DR_BANDWIDTH_LIMIT_MBPS:-0}"
  [[ "${bandwidth}" =~ ^[0-9]+$ ]] || bandwidth=0
  output="$(python3 "${FTCTL_LIB_BASE}/ftctl/qcow2_bitmap_backup.py" \
    --domain "${vm_name}" --source-path "${source_path}" \
    --target-host "${host}" --target-port "${port}" --target-export "${name}" \
    --bitmap "${bitmap}" --mode "${mode}" --job-id "${job_id}" --target-node "${target_node}" \
    --virtual-size "${size_bytes}" --timeout "${FTCTL_DR_FULL_SEED_TIMEOUT_SEC:-3600}" \
    --bandwidth-limit-mbps "${bandwidth}" --progress-path "${FTCTL_DR_TRANSFER_PROGRESS_PATH:-}" \
    --plan-uuid "${plan}" --run-uuid "${run}" \
    --cycle-sequence "${sequence:-0}" --disk-index "${disk_index}" --disk-count "${disk_count}" \
    --aggregate-total-bytes "${FTCTL_DR_TRANSFER_AGGREGATE_TOTAL_BYTES:-0}" \
    --aggregate-completed-bytes "${FTCTL_DR_TRANSFER_AGGREGATE_COMPLETED_BYTES:-0}")" || rc=$?
  [[ "${rc}" == "0" ]] || return "${rc}"
  [[ -z "${out_var}" ]] || printf -v "${out_var}" '%s' "${output}"
}

ftctl_dr_ablestack_qcow2_offline_push_disk() {
  local plan="${1-}" run="${2-}" sequence="${3-}" disk_map="${4-}" disk_json="${5-}"
  local disk_index="${6-1}" disk_count="${7-1}" out_var="${8-}"
  local device source_path size_bytes host port name bitmap job_id target_node output="" rc=0 bandwidth
  device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
  source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
  size_bytes="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sizeBytes)"
  host="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" host)"
  port="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" port)"
  name="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" name)"
  [[ -n "${source_path}" && "${size_bytes}" =~ ^[1-9][0-9]*$ ]] || return 32
  [[ -n "${host}" && "${port}" =~ ^[1-9][0-9]*$ && -n "${name}" ]] || return 100
  ftctl_dr_ablestack_target_export_reachable "${host}" "${port}" || return 100
  bitmap="$(ftctl_dr_ablestack_qcow2_bitmap_name "${plan}" "${device}")"
  job_id="ftctl-dr-offline-$(printf '%s' "${run}:${device}" | cksum | awk '{print $1}')"
  target_node="ftctl-dr-target-$(printf '%s' "${plan}:${device}" | cksum | awk '{print $1}')"
  bandwidth="${FTCTL_DR_BANDWIDTH_LIMIT_MBPS:-0}"
  [[ "${bandwidth}" =~ ^[0-9]+$ ]] || bandwidth=0
  output="$(python3 "${FTCTL_LIB_BASE}/ftctl/qcow2_bitmap_offline_backup.py" \
    --domain offline-storage-daemon --source-path "${source_path}" \
    --target-host "${host}" --target-port "${port}" --target-export "${name}" \
    --bitmap "${bitmap}" --mode incremental --job-id "${job_id}" --target-node "${target_node}" \
    --virtual-size "${size_bytes}" --timeout "${FTCTL_DR_FULL_SEED_TIMEOUT_SEC:-3600}" \
    --bandwidth-limit-mbps "${bandwidth}" --progress-path "${FTCTL_DR_TRANSFER_PROGRESS_PATH:-}" \
    --plan-uuid "${plan}" --run-uuid "${run}" \
    --cycle-sequence "${sequence:-0}" --disk-index "${disk_index}" --disk-count "${disk_count}" \
    --aggregate-total-bytes "${FTCTL_DR_TRANSFER_AGGREGATE_TOTAL_BYTES:-0}" \
    --aggregate-completed-bytes "${FTCTL_DR_TRANSFER_AGGREGATE_COMPLETED_BYTES:-0}")" || rc=$?
  [[ "${rc}" == "0" ]] || return "${rc}"
  [[ -z "${out_var}" ]] || printf -v "${out_var}" '%s' "${output}"
}

ftctl_dr_ablestack_prepare_file_target() {
  local target_path="${1-}" target_format="${2-}" size_bytes="${3-}"
  local out="" err="" rc=0 current_format="" current_size=""
  [[ -n "${target_path}" && -n "${target_format}" && "${size_bytes}" =~ ^[1-9][0-9]*$ ]] || return 2
  ftctl_ensure_dir "$(dirname "${target_path}")" "0755"
  if [[ ! -e "${target_path}" ]]; then
    ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
      qemu-img create -f "${target_format}" "${target_path}" "${size_bytes}" || true
    : "${out}${err}"
    return "${rc}"
  fi
  ftctl_dr_ablestack_qemu_info_value "${target_path}" "format" current_format || return $?
  ftctl_dr_ablestack_qemu_info_value "${target_path}" "virtual-size" current_size || return $?
  [[ -z "${current_format}" || "${current_format}" == "${target_format}" ]] || return 96
  [[ "${current_size}" =~ ^[0-9]+$ && "${current_size}" -ge "${size_bytes}" ]] || return 97
}

ftctl_dr_ablestack_prepare_block_target() {
  local target_path="${1-}" size_bytes="${2-}"
  local out="" err="" rc=0 current_size=""
  [[ -b "${target_path}" && "${size_bytes}" =~ ^[1-9][0-9]*$ ]] || return 2
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
    blockdev --getsize64 "${target_path}" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return "${rc}"
  current_size="$(awk 'NF {print $1; exit}' <<< "${out}")"
  [[ "${current_size}" =~ ^[0-9]+$ && "${current_size}" -ge "${size_bytes}" ]] || return 97
}

ftctl_dr_ablestack_prepare_rbd_target() {
  local target_path="${1-}" size_bytes="${2-}"
  local spec="" out="" err="" rc=0 size_mib
  ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" spec || return 2
  size_mib=$(( (size_bytes + 1048575) / 1048576 ))
  (( size_mib > 0 )) || size_mib=1
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
    rbd info --format json "${spec}" || true
  if [[ "${rc}" == "0" ]]; then
    return 0
  fi
  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
    rbd create --image-format 2 --size "${size_mib}" "${spec}" || true
  : "${out}${err}"
  return "${rc}"
}

ftctl_dr_ablestack_target_uri_for_qemu() {
  local target_path="${1-}" out_var="${2}"
  local spec=""
  if ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" spec; then
    printf -v "${out_var}" 'rbd:%s' "${spec}"
  else
    printf -v "${out_var}" '%s' "${target_path}"
  fi
}

ftctl_dr_ablestack_prepare_target() {
  local target_path="${1-}" target_format="${2-}" size_bytes="${3-}" target_type="${4-}"
  case "${target_type}" in
    rbd) ftctl_dr_ablestack_prepare_rbd_target "${target_path}" "${size_bytes}" ;;
    block) ftctl_dr_ablestack_prepare_block_target "${target_path}" "${size_bytes}" ;;
    file) ftctl_dr_ablestack_prepare_file_target "${target_path}" "${target_format}" "${size_bytes}" ;;
    *) return 2 ;;
  esac
}

ftctl_dr_ablestack_error_code_for_rc() {
  local rc="${1-}"
  case "${rc}" in
    31) printf 'DR_TARGET_DISK_MAPPING_INVALID\n' ;;
    32) printf 'DR_TARGET_DISK_TYPE_INVALID\n' ;;
    33) printf 'DR_TARGET_DISK_SIZE_UNRESOLVED\n' ;;
    34) printf 'DR_TARGET_DISK_PREPARE_FAILED\n' ;;
    35) printf 'DR_TARGET_STORAGE_UNRESOLVED\n' ;;
    110) printf 'DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE\n' ;;
    111) printf 'DR_QCOW2_BACKUP_FAILED\n' ;;
    112) printf 'DR_QCOW2_OFFLINE_SOURCE_BUSY\n' ;;
    113) printf 'DR_QCOW2_OFFLINE_BASELINE_FAILED\n' ;;
    114) printf 'DR_ABLESTACK_INCREMENTAL_APPLY_FAILED\n' ;;
    115) printf 'DR_QCOW2_OFFLINE_TRANSFER_FAILED\n' ;;
    116) printf 'DR_QCOW2_BASELINE_NOT_DURABLE\n' ;;
    100) printf 'DR_TARGET_EXPORT_UNAVAILABLE\n' ;;
    *) printf 'DR_ABLESTACK_DRIVER_FAILED\n' ;;
  esac
}

ftctl_dr_ablestack_mark_driver_error() {
  local state_path="${1-}" rc="${2-}" step="${3-}" message="${4-}"
  local error_code
  error_code="$(ftctl_dr_ablestack_error_code_for_rc "${rc}")"
  ftctl_dr_runtime_path_set "${state_path}" \
    "driver=ABLESTACK" \
    "driver_state=ERROR" \
    "state=ERROR" \
    "step=${step:-ablestack-driver-failed}" \
    "progress=100" \
    "accepted=false" \
    "error_code=${error_code}" \
    "error_message=${message:-ABLESTACK target driver failed}" \
    "driver_exit_code=${rc}" \
    "updated_at=$(ftctl_now_iso8601)" || true
}

ftctl_dr_ablestack_write_manifest() {
  local disk_map="${1-}" records_path="${2-}" manifest_path="${3-}" phase="${4-}"
  ftctl_ensure_dir "$(dirname "${manifest_path}")" "0755"
  python3 - "${disk_map}" "${records_path}" "${manifest_path}" "${phase}" "$(ftctl_now_iso8601)" "${FTCTL_DR_PRODUCER_RUN_UUID:-}" <<'PY'
import json
import os
import sys

disk_map_path, records_path, manifest_path, phase, now, producer_run = sys.argv[1:7]
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)

records = {}
if os.path.exists(records_path):
    with open(records_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                parts = line.split("\t")
                if len(parts) < 8:
                    continue
                record = {
                    "device": parts[0],
                    "sourcePath": parts[1],
                    "targetPath": parts[2],
                    "sourceFormat": parts[3],
                    "targetFormat": parts[4],
                    "sizeBytes": int(parts[5] or "0"),
                    "sourceType": parts[6],
                    "targetType": parts[7],
                }
            device = str(record.get("device") or "")
            if device:
                records[device] = record

disks = []
for disk in disk_map.get("disks") or []:
    device = str(disk.get("device") or "")
    item = dict(disk)
    item.update(records.get(device, {}))
    disks.append(item)

manifest = {
    "phase": phase,
    "generatedAt": now,
    "planUuid": disk_map.get("planUuid", ""),
    "runUuid": producer_run or disk_map.get("runUuid", ""),
    "sourceProvider": disk_map.get("sourceProvider", ""),
    "targetProvider": disk_map.get("targetProvider", ""),
    "target": disk_map.get("target", {}),
    "count": len(disks),
    "disks": disks,
}
tmp = manifest_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, manifest_path)
PY
}

ftctl_dr_ablestack_write_checkpoint() {
  local disk_map="${1-}" manifest_path="${2-}" checkpoint_path="${3-}" state="${4-}" source_at="${5-}" target_at="${6-}" rpo="${7-}"
  local requested_mode="${8-}" effective_mode="${9-}" incremental_verified="${10-}" changed_bytes="${11-}" reseed_reason="${12-}"
  local cycle_sequence="${13-}" nbd_source_count="${14-0}" nbd_target_count="${15-0}"
  ftctl_ensure_dir "$(dirname "${checkpoint_path}")" "0755"
  python3 - "${disk_map}" "${manifest_path}" "${checkpoint_path}" "${state}" "${source_at}" "${target_at}" "${rpo}" \
    "${requested_mode}" "${effective_mode}" "${incremental_verified}" "${changed_bytes}" "${reseed_reason}" \
    "${cycle_sequence}" "${nbd_source_count}" "${nbd_target_count}" "${FTCTL_DR_PRODUCER_RUN_UUID:-}" <<'PY'
import datetime
import json
import os
import sys
import uuid

disk_map_path, manifest_path, checkpoint_path, state, source_at, target_at, rpo, requested_mode, effective_mode, incremental_verified, changed_bytes, reseed_reason, cycle_sequence, nbd_source_count, nbd_target_count, producer_run = sys.argv[1:17]
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)
manifest = {}
if os.path.exists(manifest_path):
    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)

checkpoint = {
    "checkpointUuid": os.path.splitext(os.path.basename(checkpoint_path))[0],
    "state": state,
    "sourceCheckpointAt": source_at,
    "targetDurableAt": target_at,
    "targetReadyRpoSeconds": int(rpo) if str(rpo).isdigit() else None,
    "manifest": manifest_path,
    "planUuid": disk_map.get("planUuid", ""),
    "runUuid": producer_run or disk_map.get("runUuid", ""),
    "disks": manifest.get("disks", disk_map.get("disks", [])),
}
if requested_mode:
    checkpoint["requestedMode"] = requested_mode
if effective_mode:
    checkpoint["effectiveMode"] = effective_mode
if incremental_verified:
    checkpoint["incrementalVerified"] = incremental_verified.lower() == "true"
if str(changed_bytes).isdigit():
    checkpoint["changedBytes"] = int(changed_bytes)
    checkpoint["sourceReadBytes"] = int(changed_bytes)
    checkpoint["targetWrittenBytes"] = int(changed_bytes)
    checkpoint["transferPayloadBytes"] = int(changed_bytes)
if reseed_reason:
    checkpoint["reseedReason"] = reseed_reason
if str(cycle_sequence).isdigit():
    sequence = int(cycle_sequence)
    plan = str(checkpoint.get("planUuid") or "")
    if not plan:
        raise SystemExit("scheduler cycle checkpoint requires planUuid")
    checkpoint.update({
        "sequence": sequence,
        "cycleUuid": str(uuid.uuid5(uuid.NAMESPACE_URL, f"ablestack-dr:{plan}:{sequence}")),
        "cycleToken": f"{plan}:{sequence}",
        "baselineGeneration": sequence,
        "baselineState": "LOCAL_DURABLE",
        "cycleCommitState": "LOCAL_DURABLE",
        "trackerState": "LOCAL_DURABLE",
        "writerState": "DURABLE",
        "targetWritten": True,
        "writeVerified": True,
        "metricsEstimated": False,
        "nbdTeardownState": "DRAINED",
        "nbdSourceDeviceCount": int(nbd_source_count) if str(nbd_source_count).isdigit() else 0,
        "nbdTargetDeviceCount": int(nbd_target_count) if str(nbd_target_count).isdigit() else 0,
        "nbdQuarantinedDeviceCount": 0,
    })
    completed_at = target_at or source_at
    if completed_at:
        try:
            normalized_at = completed_at[:-1] + "+00:00" if completed_at.endswith("Z") else completed_at
            completed_ms = int(datetime.datetime.fromisoformat(normalized_at).timestamp() * 1000)
            checkpoint["nbdTeardownStartedAtEpochMs"] = completed_ms
            checkpoint["nbdTeardownCompletedAtEpochMs"] = completed_ms
            checkpoint["nbdTeardownDurationMs"] = 0
        except ValueError:
            pass
tmp = checkpoint_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(checkpoint, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, checkpoint_path)
PY
}

ftctl_dr_ablestack_full_seed_transferred_bytes() {
  local result_json="${1-}" fallback_bytes="${2-0}" transferred_bytes=""
  if [[ -n "${result_json}" ]]; then
    transferred_bytes="$(python3 -c \
      'import json,sys
value=json.loads(sys.argv[1])
mode=str(value.get("mode") or "").upper()
fields=("targetWrittenBytes","sourceReadBytes","bytesProcessed","transferPayloadBytes","changedBytes") if mode in ("FULL_SEED","FULL_RESEED") else ("changedBytes",)
values=[value.get(field) for field in fields]
positive=next((item for item in values if isinstance(item,int) and item > 0), None)
nonnegative=next((item for item in values if isinstance(item,int) and item >= 0), None)
print(positive if positive is not None else nonnegative if nonnegative is not None else "")' \
      "${result_json}" 2>/dev/null || true)"
  fi
  [[ "${transferred_bytes}" =~ ^[0-9]+$ ]] || transferred_bytes="${fallback_bytes}"
  [[ "${transferred_bytes}" =~ ^[0-9]+$ ]] || transferred_bytes="0"
  printf '%s\n' "${transferred_bytes}"
}

ftctl_dr_ablestack_prepare_targets() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" manifest_path="${5-}" checkpoint_path="${6-}"
  local records_path count disk_json device source_path target_path source_format target_format size_bytes source_type target_type resolved_size
  local source_at remote_transport="0"

  ftctl_dr_ablestack_prepare_cycle_disk_map "${plan}" "${profile_file}" "${disk_map}" || return $?
  if ftctl_dr_ablestack_remote_transport_load "${disk_map}" ||
     ftctl_dr_ablestack_site_agent_transport_load "${disk_map}"; then
    remote_transport="1"
  fi
  count="$(ftctl_dr_ablestack_disk_count "${disk_map}")" || return $?
  if [[ "${count}" == "0" ]]; then
    ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "warn" "" "" \
      "plan=${plan} run=${run} reason=missing_explicit_disk_map"
    return 30
  fi

  ftctl_ensure_dir "$(dirname "${manifest_path}")" "0755"
  records_path="${manifest_path}.records.jsonl"
  : > "${records_path}"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
    source_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceFormat)"
    target_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetFormat)"
    size_bytes="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sizeBytes)"
    source_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceType)"
    target_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetType)"
    [[ -n "${device}" ]] || continue
    if [[ -z "${source_path}" || -z "${target_path}" ]]; then
      ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "fail" "" "31" \
        "plan=${plan} run=${run} device=${device} reason=missing_source_or_target_path"
      return 31
    fi
    [[ -n "${target_format}" ]] || target_format="${source_format:-raw}"
    if [[ -z "${target_type}" ]]; then
      ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "fail" "" "32" \
        "plan=${plan} run=${run} device=${device} target=${target_path} reason=missing_target_type"
      return 32
    fi
    resolved_size=""
    if ! ftctl_dr_ablestack_source_size_bytes "${device}" "${source_path}" "${size_bytes}" resolved_size; then
      ftctl_log_event "dr-runtime" "dr.ablestack.source_size" "fail" "" "33" \
        "plan=${plan} run=${run} device=${device} source=${source_path} explicit_size=${size_bytes:-0}"
      return 33
    fi
    if [[ "${remote_transport}" != "1" ]] &&
       ! ftctl_dr_ablestack_prepare_target "${target_path}" "${target_format}" "${resolved_size}" "${target_type}"; then
      ftctl_log_event "dr-runtime" "dr.ablestack.target_prepare" "fail" "" "34" \
        "plan=${plan} run=${run} device=${device} target=${target_path} target_type=${target_type} size=${resolved_size}"
      return 34
    fi
    ftctl_dr_ablestack_append_disk_record "${records_path}" "${disk_json}" \
      "${source_format}" "${target_format}" "${resolved_size}" "${source_type}" "${target_type}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")

  ftctl_dr_ablestack_write_manifest "${disk_map}" "${records_path}" "${manifest_path}" "target-prepared" || return $?
  source_at="$(ftctl_now_iso8601)"
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_PREPARED" "${source_at}" "" "" || return $?
  ftctl_log_event "dr-runtime" "dr.ablestack.targets_prepared" "ok" "" "" \
    "plan=${plan} run=${run} disks=${count} manifest=${manifest_path} remote_transport=${remote_transport}"
}

ftctl_dr_ablestack_transfer_target_format() {
  local target_uri="${1-}" target_format="${2-}" out_var="${3-}"
  local transfer_format="${target_format:-raw}"
  case "${target_uri}" in
    nbd://*) transfer_format="raw" ;;
  esac
  printf -v "${out_var}" '%s' "${transfer_format}"
}

ftctl_dr_ablestack_full_seed_once() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" manifest_path="${5-}" checkpoint_path="${6-}"
  local requested_mode="${7-FULL_SEED}" effective_mode="${8-FULL_SEED}" reseed_reason="${9-}"
  local cycle_sequence="${10-}"
  local disk_json device source_path target_path source_format target_format transfer_target_format size_bytes source_type target_type resolved_size target_uri
  local out="" err="" rc=0 source_at target_at source_epoch target_epoch rpo="0"
  local remote_transport="0" remote_path="" export_name="" export_port="" export_host="" vm_name=""
  local qcow2_transfer_mode="generic" disk_count="0" disk_index=0 backup_result=""
  local disk_transferred_bytes="0" total_transferred_bytes="0"
  local FTCTL_DR_TRANSFER_AGGREGATE_TOTAL_BYTES="0" FTCTL_DR_TRANSFER_AGGREGATE_COMPLETED_BYTES="0"

  ftctl_dr_ablestack_prepare_targets "${plan}" "${run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || return $?
  local site_agent_transport="0"
  if ftctl_dr_ablestack_site_agent_transport_load "${disk_map}"; then
    remote_transport="1"
    site_agent_transport="1"
  elif ftctl_dr_ablestack_remote_transport_load "${disk_map}"; then
    remote_transport="1"
  fi
  vm_name="$(ftctl_dr_ablestack_json_field "${disk_map}" source.instanceName 2>/dev/null || true)"
  [[ -n "${vm_name}" ]] || vm_name="dr-${plan}"
  disk_count="$(ftctl_dr_ablestack_disk_count "${disk_map}")" || return $?
  FTCTL_DR_TRANSFER_AGGREGATE_TOTAL_BYTES="$(ftctl_dr_ablestack_disk_total_size_bytes "${disk_map}")" || return $?
  if [[ "${site_agent_transport}" == "1" ]] && ftctl_dr_ablestack_qcow2_push_provider "${disk_map}"; then
    if ftctl_dr_ablestack_qcow2_runtime_ready "${disk_map}" "${vm_name}"; then
      qcow2_transfer_mode="qmp"
    else
      ftctl_dr_ablestack_probe_offline_qcow2_sources "${disk_map}" || return $?
      ftctl_dr_ablestack_initialize_qcow2_source_baselines \
        "${plan}" "${cycle_sequence:-${run}}" "${disk_map}" 1 || return $?
      qcow2_transfer_mode="offline"
    fi
  fi
  ftctl_log_event "dr-runtime" "dr.ablestack.full_seed_mode" "ok" "" "" \
    "plan=${plan} run=${run} mode=${qcow2_transfer_mode} disks=${disk_count}"
  source_at="$(ftctl_now_iso8601)"
  while IFS= read -r disk_json; do
    disk_index=$((disk_index + 1))
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
    source_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceFormat)"
    target_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetFormat)"
    size_bytes="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sizeBytes)"
    source_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceType)"
    target_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetType)"
    [[ -n "${device}" ]] || continue
    : "${size_bytes}${source_type}${target_type}"
    [[ -n "${source_format}" ]] || source_format="raw"
    [[ -n "${target_format}" ]] || target_format="${source_format}"
    resolved_size=""
    ftctl_dr_ablestack_source_size_bytes "${device}" "${source_path}" "" resolved_size || return $?
    if [[ "${site_agent_transport}" == "1" ]]; then
      target_uri="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" uri)"
      export_host="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" host)"
      export_port="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" port)"
      [[ "${target_uri}" == nbd://* && -n "${export_host}" && "${export_port}" =~ ^[1-9][0-9]*$ ]] || return 94
      ftctl_dr_ablestack_target_export_reachable "${export_host}" "${export_port}" || return 100
    elif [[ "${remote_transport}" == "1" ]]; then
      ftctl_dr_ablestack_remote_rbd_path "${target_path}" remote_path || return 35
      FTCTL_PROFILE_DISK_MAP="${device}=${remote_path}"
      export_name="dr-${plan//[^A-Za-z0-9]/}-${device}"
      ftctl_blockcopy_remote_nbd_pick_port "${vm_name}" "${device}" export_port || return $?
      ftctl_blockcopy_remote_nbd_prepare_target "${vm_name}" "${device}" "${source_path}" \
        "${source_format}" "${remote_path}" "${export_name}" "${export_port}" || return $?
      target_uri="$(ftctl_blockcopy_remote_nbd_uri "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" "${export_port}" "${export_name}")"
    else
      ftctl_dr_ablestack_target_uri_for_qemu "${target_path}" target_uri
    fi
    out=""
    err=""
    rc=0
    ftctl_dr_ablestack_transfer_target_format "${target_uri}" "${target_format}" transfer_target_format
    if [[ "${qcow2_transfer_mode}" == "qmp" ]]; then
      backup_result=""
      FTCTL_DR_TRANSFER_AGGREGATE_COMPLETED_BYTES="${total_transferred_bytes}"
      ftctl_dr_ablestack_qcow2_push_disk "${plan}" "${run}" "${cycle_sequence}" full "${vm_name}" \
        "${disk_map}" "${disk_json}" "$((disk_index - 1))" "${disk_count}" backup_result || rc=$?
      out="${backup_result}"
    elif [[ "${qcow2_transfer_mode}" == "offline" ]]; then
      ftctl_cmd_run "${FTCTL_DR_FULL_SEED_TIMEOUT_SEC:-3600}" out err rc -- \
        qemu-img convert -p -n -S "${FTCTL_THIN_SPARSE_SIZE:-4k}" \
        -f "${source_format}" -O raw "${source_path}" "${target_uri}" || true
      [[ "${rc}" == "0" ]] || rc=115
    else
      ftctl_cmd_run "${FTCTL_DR_FULL_SEED_TIMEOUT_SEC:-3600}" out err rc -- \
        qemu-img convert --force-share -p -n -S "${FTCTL_THIN_SPARSE_SIZE:-4k}" \
        -f "${source_format}" -O "${transfer_target_format}" "${source_path}" "${target_uri}" || true
    fi
    : "${out}${err}${resolved_size}"
    if [[ "${remote_transport}" == "1" && "${site_agent_transport}" != "1" ]]; then
      ftctl_dr_ablestack_remote_nbd_stop "${vm_name}" "${device}" "${export_port}" || true
    fi
    [[ "${rc}" == "0" ]] || return "${rc}"
    disk_transferred_bytes="$(ftctl_dr_ablestack_full_seed_transferred_bytes "${backup_result}" "${resolved_size}")"
    total_transferred_bytes=$((total_transferred_bytes + disk_transferred_bytes))
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")

  if [[ "${qcow2_transfer_mode}" == "offline" ]]; then
    ftctl_dr_ablestack_qcow2_source_baselines_ready "${plan}" "${disk_map}" || return 113
  fi
  target_at="$(ftctl_now_iso8601)"
  source_epoch="$(ftctl_iso_to_epoch "${source_at}" 2>/dev/null || printf '0')"
  target_epoch="$(ftctl_iso_to_epoch "${target_at}" 2>/dev/null || printf '0')"
  if [[ "${source_epoch}" =~ ^[0-9]+$ && "${target_epoch}" =~ ^[0-9]+$ && "${target_epoch}" -ge "${source_epoch}" ]]; then
    rpo="$((target_epoch - source_epoch))"
  fi
  ftctl_dr_ablestack_write_manifest "${disk_map}" "${manifest_path}.records.jsonl" "${manifest_path}" "full-seed-complete" || return $?
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_READY" \
    "${source_at}" "${target_at}" "${rpo}" "${requested_mode}" "${effective_mode}" false \
    "${total_transferred_bytes}" "${reseed_reason}" "${cycle_sequence}" 0 0 || return $?
  if [[ "${remote_transport}" == "1" && "${qcow2_transfer_mode}" != "qmp" ]]; then
    if [[ "${qcow2_transfer_mode}" == "offline" ]]; then
      :
    elif [[ "${site_agent_transport}" == "1" ]]; then
      ftctl_dr_ablestack_initialize_source_baselines "${plan}" "${run}" "${disk_map}" || return $?
    else
      ftctl_dr_ablestack_initialize_baselines "${plan}" "${run}" "${disk_map}" || return $?
    fi
  fi
  ftctl_log_event "dr-runtime" "dr.ablestack.full_seed" "ok" "" "" \
    "plan=${plan} run=${run} checkpoint=${checkpoint_path} rpo=${rpo}"
}

ftctl_dr_ablestack_baseline_path() {
  local plan="${1-}" device="${2-}"
  printf '%s/baseline-%s.snap\n' "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")" "$(ftctl_dr_runtime_key "${device}")"
}

ftctl_dr_ablestack_snapshot_name() {
  local plan="${1-}" sequence="${2-}"
  printf 'ftctl-dr-%s-%s\n' "$(printf '%s' "${plan}" | cksum | awk '{print $1}')" "${sequence:-0}"
}

ftctl_dr_ablestack_remote_rbd_command() {
  local command_text="${1-}" out_var="${2}" err_var="${3}" rc_var="${4}" host="" user=""
  ftctl_blockcopy_remote_target_host_user host user || return 2
  ftctl_blockcopy_remote_exec "${host}" "${user}" "${out_var}" "${err_var}" "${rc_var}" "${command_text}" || true
}

ftctl_dr_ablestack_reset_baseline_snapshot() {
  local source_spec="${1-}" target_spec="${2-}" snap="${3-}" out="" err="" rc=0
  [[ -n "${source_spec}" && -n "${target_spec}" && -n "${snap}" ]] || return 2
  rbd snap rm "${source_spec}@${snap}" >/dev/null 2>&1 || true
  ftctl_dr_ablestack_remote_rbd_command \
    "rbd snap rm '${target_spec}@${snap}' >/dev/null 2>&1 || true" out err rc
  [[ "${rc}" == "0" ]]
}

ftctl_dr_ablestack_initialize_baselines() {
  local plan="${1-}" sequence="${2-}" disk_map="${3-}" snap="" disk_json device source_path target_path source_spec target_spec baseline previous
  local out="" err="" rc=0
  snap="$(ftctl_dr_ablestack_snapshot_name "${plan}" "${sequence}")"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
    ftctl_dr_ablestack_rbd_spec_from_path "${source_path}" source_spec || return 32
    ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" target_spec || return 32
    baseline="$(ftctl_dr_ablestack_baseline_path "${plan}" "${device}")"
    if [[ -s "${baseline}" ]]; then
      previous="$(head -n 1 "${baseline}")"
      ftctl_dr_ablestack_reset_baseline_snapshot "${source_spec}" "${target_spec}" "${previous}" || return $?
    fi
    ftctl_dr_ablestack_reset_baseline_snapshot "${source_spec}" "${target_spec}" "${snap}" || return $?
    rbd snap create "${source_spec}@${snap}" || return $?
    ftctl_dr_ablestack_remote_rbd_command "rbd snap create '${target_spec}@${snap}'" out err rc
    if [[ "${rc}" != "0" ]]; then
      rbd snap rm "${source_spec}@${snap}" >/dev/null 2>&1 || true
      return "${rc}"
    fi
    printf '%s\n' "${snap}" > "${baseline}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
}

ftctl_dr_ablestack_initialize_source_baselines() {
  local plan="${1-}" sequence="${2-}" disk_map="${3-}" snap disk_json device source_path source_spec baseline previous
  if ftctl_dr_ablestack_qcow2_source_provider "${disk_map}"; then
    ftctl_dr_ablestack_initialize_qcow2_source_baselines "${plan}" "${sequence}" "${disk_map}"
    return $?
  fi
  snap="$(ftctl_dr_ablestack_snapshot_name "${plan}" "${sequence}")"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    ftctl_dr_ablestack_rbd_spec_from_path "${source_path}" source_spec || return 32
    baseline="$(ftctl_dr_ablestack_baseline_path "${plan}" "${device}")"
    if [[ -s "${baseline}" ]]; then
      previous="$(head -n 1 "${baseline}")"
      rbd snap rm "${source_spec}@${previous}" >/dev/null 2>&1 || true
    fi
    rbd snap rm "${source_spec}@${snap}" >/dev/null 2>&1 || true
    rbd snap create "${source_spec}@${snap}" || return $?
    printf '%s\n' "${snap}" > "${baseline}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
}

ftctl_dr_ablestack_acquire_nbd_device() {
  local out_var="${1}" idx dev
  for ((idx=${FTCTL_DR_NBD_DEVICE_START:-16}; idx<=${FTCTL_DR_NBD_DEVICE_END:-31}; idx++)); do
    dev="/dev/nbd${idx}"
    if ftctl_dr_nbd_device_is_free "${dev}"; then
      printf -v "${out_var}" '%s' "${dev}"
      return 0
    fi
  done
  return 95
}

ftctl_dr_ablestack_apply_incremental_nbd() {
  local source_spec="${1-}" previous="${2-}" current="${3-}" host="${4-}" port="${5-}" name="${6-}" diff_json="${7-}"
  local source_dev="" target_dev="" lock_file="${FTCTL_DR_NBD_LOCK:-/run/ablestack-vm-ftctl/dr-runtime/nbd.lock}" rc=0
  ftctl_dr_ablestack_target_export_reachable "${host}" "${port}" || return 100
  exec 9>"${lock_file}"
  flock -x 9
  ftctl_dr_ablestack_acquire_nbd_device source_dev || { flock -u 9; return $?; }
  qemu-nbd --read-only --cache=none --aio=io_uring --connect="${source_dev}" --format=raw "rbd:${source_spec}@${current}" >/dev/null || {
    flock -u 9
    return $?
  }
  ftctl_dr_ablestack_acquire_nbd_device target_dev || {
    qemu-nbd --disconnect "${source_dev}" >/dev/null 2>&1 || true
    flock -u 9
    return $?
  }
  if ! nbd-client "${host}" "${port}" "${target_dev}" -N "${name}" >/dev/null; then
    qemu-nbd --disconnect "${source_dev}" >/dev/null 2>&1 || true
    flock -u 9
    ftctl_dr_ablestack_target_export_reachable "${host}" "${port}" || return 100
    return 96
  fi
  flock -u 9
  python3 "${FTCTL_LIB_BASE}/ftctl/rbd_extent_copy.py" --source "${source_dev}" --target "${target_dev}" --diff-json "${diff_json}" >/dev/null || rc=$?
  sync "${target_dev}" >/dev/null 2>&1 || true
  nbd-client -d "${target_dev}" >/dev/null 2>&1 || true
  qemu-nbd --disconnect "${source_dev}" >/dev/null 2>&1 || true
  return "${rc}"
}

ftctl_dr_ablestack_incremental_once() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" manifest_path="${5-}" checkpoint_path="${6-}" sequence="${7-}"
  local disk_json device source_path target_path source_spec target_spec baseline previous current host user ssh_host ssh_port ssh_port_args identity_args
  local out="" err="" rc=0 changed_bytes="0" total_changed_bytes="0" started_at completed_at effective_mode
  ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  ftctl_dr_ablestack_remote_transport_load "${disk_map}" || return 90
  ftctl_blockcopy_remote_target_host_user host user || return 2
  ftctl_blockcopy_split_ssh_host_port "${host}" ssh_host ssh_port
  ssh_port_args=""
  [[ -z "${ssh_port}" ]] || printf -v ssh_port_args -- '-p %q ' "${ssh_port}"
  ftctl_blockcopy_dr_ssh_identity_args identity_args "$(ftctl_dr_ablestack_json_field "${disk_map}" source.instanceName)" || true
  current="$(ftctl_dr_ablestack_snapshot_name "${plan}" "${sequence}")"
  started_at="$(ftctl_now_iso8601)"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
    ftctl_dr_ablestack_rbd_spec_from_path "${source_path}" source_spec || return 32
    ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" target_spec || return 32
    baseline="$(ftctl_dr_ablestack_baseline_path "${plan}" "${device}")"
    [[ -s "${baseline}" ]] || return 91
    previous="$(head -n 1 "${baseline}")"
    rbd snap create "${source_spec}@${current}" || return $?
    changed_bytes="$(rbd diff --from-snap "${previous}" --format json "${source_spec}@${current}" 2>/dev/null | python3 -c 'import json,sys; print(sum(int(x.get("length",0)) for x in json.load(sys.stdin)))' 2>/dev/null || printf '0')"
    total_changed_bytes="$((total_changed_bytes + changed_bytes))"
    ftctl_cmd_run "${FTCTL_DR_FULL_SEED_TIMEOUT_SEC:-3600}" out err rc -- bash -lc \
      "rbd export-diff --from-snap $(printf '%q' "${previous}") $(printf '%q' "${source_spec}@${current}") - | ssh ${ssh_port_args}${identity_args}-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30} $(printf '%q' "${user}@${ssh_host}") rbd import-diff - $(printf '%q' "${target_spec}")" || true
    if [[ "${rc}" != "0" ]]; then
      rbd snap rm "${source_spec}@${current}" >/dev/null 2>&1 || true
      ftctl_dr_ablestack_remote_rbd_command "rbd snap rollback '${target_spec}@${previous}' >/dev/null 2>&1 || true; rbd snap rm '${target_spec}@${current}' >/dev/null 2>&1 || true" out err rc
      return 114
    fi
    rbd snap rm "${source_spec}@${previous}" >/dev/null 2>&1 || true
    ftctl_dr_ablestack_remote_rbd_command "rbd snap rm '${target_spec}@${previous}' >/dev/null 2>&1 || true" out err rc
    printf '%s\n' "${current}" > "${baseline}"
    ftctl_log_event "dr-runtime" "dr.ablestack.incremental_disk" "ok" "" "" \
      "plan=${plan} run=${run} device=${device} from=${previous} to=${current} bytes=${changed_bytes}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  completed_at="$(ftctl_now_iso8601)"
  effective_mode="$(ftctl_dr_ablestack_incremental_effective_mode "${total_changed_bytes}")"
  ftctl_dr_ablestack_write_manifest "${disk_map}" "${manifest_path}.records.jsonl" "${manifest_path}" "incremental-complete" || return $?
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_READY" \
    "${started_at}" "${completed_at}" "0" CBT_INCREMENTAL "${effective_mode}" true "${total_changed_bytes}" "" \
    "${sequence}" 0 0 || return $?
}

ftctl_dr_ablestack_incremental_effective_mode() {
  local changed_bytes="${1-0}"
  [[ "${changed_bytes}" =~ ^[0-9]+$ ]] || changed_bytes=0
  if [[ "${changed_bytes}" == "0" ]]; then
    printf 'NO_CHANGE\n'
  else
    printf 'CBT_INCREMENTAL\n'
  fi
}

ftctl_dr_ablestack_qcow2_incremental_once() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" manifest_path="${5-}" checkpoint_path="${6-}" sequence="${7-}"
  local disk_json vm_name result changed_bytes total_changed_bytes=0 started_at completed_at disk_count disk_index=0 rc=0 effective_mode
  local transfer_mode="qmp" device
  : "${profile_file}"
  ftctl_dr_ablestack_site_agent_transport_load "${disk_map}" || return 90
  ftctl_dr_ablestack_qcow2_push_provider "${disk_map}" || return 90
  vm_name="$(ftctl_dr_ablestack_json_field "${disk_map}" source.instanceName 2>/dev/null || true)"
  [[ -n "${vm_name}" ]] || return 32
  disk_count="$(ftctl_dr_ablestack_disk_count "${disk_map}")" || return $?
  if ! ftctl_dr_ablestack_qcow2_runtime_ready "${disk_map}" "${vm_name}"; then
    ftctl_dr_ablestack_probe_offline_qcow2_sources "${disk_map}" || return $?
    ftctl_dr_ablestack_qcow2_source_baselines_ready "${plan}" "${disk_map}" || return 116
    transfer_mode="offline-qsd"
    ftctl_log_event "dr-runtime" "dr.ablestack.incremental_mode" "ok" "" "" \
      "plan=${plan} run=${run} mode=offline-qsd reason=source_runtime_unavailable"
  fi
  started_at="$(ftctl_now_iso8601)"
  while IFS= read -r disk_json; do
    disk_index=$((disk_index + 1))
    result=""
    rc=0
    if [[ "${transfer_mode}" == "offline-qsd" ]]; then
      ftctl_dr_ablestack_qcow2_offline_push_disk "${plan}" "${run}" "${sequence}" \
        "${disk_map}" "${disk_json}" "$((disk_index - 1))" "${disk_count}" result || rc=$?
    else
      ftctl_dr_ablestack_qcow2_push_disk "${plan}" "${run}" "${sequence}" incremental "${vm_name}" \
        "${disk_map}" "${disk_json}" "$((disk_index - 1))" "${disk_count}" result || rc=$?
    fi
    [[ "${rc}" == "0" ]] || return "${rc}"
    changed_bytes="$(python3 -c 'import json,sys; print(int(json.loads(sys.argv[1]).get("changedBytes",0)))' "${result}" 2>/dev/null || printf '0')"
    [[ "${changed_bytes}" =~ ^[0-9]+$ ]] || changed_bytes=0
    total_changed_bytes=$((total_changed_bytes + changed_bytes))
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    ftctl_log_event "dr-runtime" "dr.ablestack.incremental_disk" "ok" "" "" \
      "plan=${plan} run=${run} device=${device} bytes=${changed_bytes} transport=${transfer_mode}-qcow2-bitmap"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  if [[ "${transfer_mode}" == "offline-qsd" ]]; then
    # Offline sources cannot acquire new guest writes. Defer clearing every
    # bitmap until the complete disk set has reached durable target storage.
    ftctl_dr_ablestack_clear_qcow2_source_baselines "${plan}" "${sequence}" "${disk_map}" || return $?
  fi
  completed_at="$(ftctl_now_iso8601)"
  effective_mode="$(ftctl_dr_ablestack_incremental_effective_mode "${total_changed_bytes}")"
  ftctl_dr_ablestack_write_manifest "${disk_map}" "${manifest_path}.records.jsonl" "${manifest_path}" "incremental-complete" || return $?
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_READY" \
    "${started_at}" "${completed_at}" "0" CBT_INCREMENTAL "${effective_mode}" true "${total_changed_bytes}" "" \
    "${sequence}" "${disk_count}" "${disk_count}" || return $?
}

ftctl_dr_ablestack_site_agent_incremental_once() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" manifest_path="${5-}" checkpoint_path="${6-}" sequence="${7-}" cycle_type="${8-}"
  local disk_json device source_path source_spec baseline previous current host port name diff_json changed_bytes total_changed_bytes="0" started_at completed_at disk_count effective_mode
  # Provider dispatch must use the same live source mapping as the transfer.
  # A canceled KVM failover may leave an immutable profile pointing at a
  # deleted overlay while QEMU has resumed on the durable SharedMountPoint
  # volume. Classifying the stale canonical map first misroutes qcow2 to RBD.
  ftctl_dr_ablestack_prepare_cycle_disk_map "${plan}" "${profile_file}" "${disk_map}" "${cycle_type}" || return $?
  ftctl_dr_ablestack_site_agent_transport_load "${disk_map}" || return 90
  if ftctl_dr_ablestack_qcow2_push_provider "${disk_map}"; then
    ftctl_dr_ablestack_qcow2_incremental_once "${plan}" "${run}" "${profile_file}" "${disk_map}" \
      "${manifest_path}" "${checkpoint_path}" "${sequence}"
    return $?
  fi
  current="$(ftctl_dr_ablestack_snapshot_name "${plan}" "${sequence}")"
  started_at="$(ftctl_now_iso8601)"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    ftctl_dr_ablestack_rbd_spec_from_path "${source_path}" source_spec || return 32
    baseline="$(ftctl_dr_ablestack_baseline_path "${plan}" "${device}")"
    [[ -s "${baseline}" ]] || return 91
    previous="$(head -n 1 "${baseline}")"
    host="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" host)"
    port="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" port)"
    name="$(ftctl_dr_ablestack_export_value "${disk_map}" "${device}" name)"
    # A missing Plan-owned export is a retryable control-plane contract gap,
    # not evidence that a local kernel NBD device is busy.
    [[ -n "${host}" && "${port}" =~ ^[0-9]+$ && -n "${name}" ]] || return 100
    ftctl_dr_ablestack_target_export_reachable "${host}" "${port}" || return 100
    rbd snap rm "${source_spec}@${current}" >/dev/null 2>&1 || true
    rbd snap create "${source_spec}@${current}" || return $?
    diff_json="$(ftctl_dr_ablestack_checkpoint_dir "${plan}")/diff-$(ftctl_dr_runtime_key "${device}")-${sequence}.json"
    rbd diff --from-snap "${previous}" --format json "${source_spec}@${current}" > "${diff_json}" || return $?
    changed_bytes="$(python3 -c 'import json,sys; print(sum(int(x.get("length",0)) for x in json.load(open(sys.argv[1]))))' "${diff_json}")"
    total_changed_bytes="$((total_changed_bytes + changed_bytes))"
    local apply_rc=0
    ftctl_dr_ablestack_apply_incremental_nbd "${source_spec}" "${previous}" "${current}" "${host}" "${port}" "${name}" "${diff_json}" || apply_rc=$?
    if [[ "${apply_rc}" != "0" ]]; then
      rbd snap rm "${source_spec}@${current}" >/dev/null 2>&1 || true
      rm -f "${diff_json}"
      [[ "${apply_rc}" == "100" ]] && return 100
      return 114
    fi
    rm -f "${diff_json}"
    rbd snap rm "${source_spec}@${previous}" >/dev/null 2>&1 || true
    printf '%s\n' "${current}" > "${baseline}"
    ftctl_log_event "dr-runtime" "dr.ablestack.incremental_disk" "ok" "" "" \
      "plan=${plan} run=${run} device=${device} from=${previous} to=${current} bytes=${changed_bytes} transport=site-agent-nbd"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  completed_at="$(ftctl_now_iso8601)"
  disk_count="$(ftctl_dr_ablestack_disk_count "${disk_map}")" || return $?
  effective_mode="$(ftctl_dr_ablestack_incremental_effective_mode "${total_changed_bytes}")"
  ftctl_dr_ablestack_write_manifest "${disk_map}" "${manifest_path}.records.jsonl" "${manifest_path}" "incremental-complete" || return $?
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_READY" \
    "${started_at}" "${completed_at}" "0" CBT_INCREMENTAL "${effective_mode}" true "${total_changed_bytes}" "" \
    "${sequence}" "${disk_count}" "${disk_count}" || return $?
}

ftctl_dr_ablestack_normalize_cycle_type() {
  local cycle_type="${1-}"
  cycle_type="${cycle_type^^}"
  cycle_type="${cycle_type//-/_}"
  printf '%s\n' "${cycle_type}"
}

ftctl_dr_ablestack_cycle_incremental_capable() {
  local normalized_cycle_type
  normalized_cycle_type="$(ftctl_dr_ablestack_normalize_cycle_type "${1-}")"
  [[ "${normalized_cycle_type}" == *INCREMENTAL* || "${normalized_cycle_type}" == "FAILOVER_FINAL" ]]
}

ftctl_dr_ablestack_replication_cycle() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" sequence="${4-}" cycle_type="${5-}"
  local disk_map manifest_path checkpoint_path cycle_run normalized_cycle_type
  # The scheduler producer survives profile/control Run changes during a cycle.
  local -x FTCTL_DR_PRODUCER_RUN_UUID="${run}"

  [[ -n "${plan}" && -n "${run}" && -n "${profile_file}" ]] || return 2
  cycle_run="${run}-cycle-${sequence:-0}"
  disk_map="$(ftctl_dr_ablestack_disk_map_path "${plan}")"
  manifest_path="$(ftctl_dr_ablestack_manifest_path "${plan}" "${cycle_run}")"
  checkpoint_path="$(ftctl_dr_ablestack_checkpoint_path "${plan}" "${cycle_run}")"
  normalized_cycle_type="$(ftctl_dr_ablestack_normalize_cycle_type "${cycle_type}")"
  if ftctl_dr_ablestack_cycle_incremental_capable "${normalized_cycle_type}"; then
    # Worker-local disk maps are disposable placement cache. Rebuild the map
    # from the recovery profile before choosing the post-relocation transport.
    ftctl_dr_ablestack_prepare_cycle_disk_map "${plan}" "${profile_file}" "${disk_map}" \
      "${normalized_cycle_type}" || return $?
  fi
  if ftctl_dr_ablestack_cycle_incremental_capable "${normalized_cycle_type}" &&
     { ftctl_dr_ablestack_site_agent_transport_load "${disk_map}" 2>/dev/null ||
       ftctl_dr_ablestack_remote_transport_load "${disk_map}" 2>/dev/null; }; then
    local incremental_rc=0
    if ftctl_dr_ablestack_site_agent_transport_load "${disk_map}" 2>/dev/null; then
      ftctl_dr_ablestack_site_agent_incremental_once "${plan}" "${cycle_run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" "${sequence}" "${normalized_cycle_type}" || incremental_rc=$?
    else
      ftctl_dr_ablestack_incremental_once "${plan}" "${cycle_run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" "${sequence}" || incremental_rc=$?
    fi
    if [[ "${incremental_rc}" == "91" ]]; then
      ftctl_log_event "dr-runtime" "dr.ablestack.incremental_fallback" "warn" "" "" \
        "plan=${plan} run=${cycle_run} reason=baseline_unavailable"
      ftctl_dr_ablestack_full_seed_once "${plan}" "${cycle_run}" "${profile_file}" "${disk_map}" \
        "${manifest_path}" "${checkpoint_path}" CBT_INCREMENTAL FULL_SEED baseline_unavailable "${sequence}" || return $?
    elif [[ "${incremental_rc}" != "0" ]]; then
      ftctl_log_event "dr-runtime" "dr.ablestack.incremental" "fail" "" "${incremental_rc}" \
        "plan=${plan} run=${cycle_run} reason=incremental_transfer_failed"
      return "${incremental_rc}"
    fi
  else
    ftctl_dr_ablestack_full_seed_once "${plan}" "${cycle_run}" "${profile_file}" "${disk_map}" \
      "${manifest_path}" "${checkpoint_path}" FULL_SEED FULL_SEED "" "${sequence}" || return $?
  fi
  printf '%s\t%s\n' "${manifest_path}" "${checkpoint_path}"
}

ftctl_dr_ablestack_profile_bool() {
  local profile_file="${1-}" field="${2-}"
  local value
  value="$(ftctl_dr_runtime_profile_value "${profile_file}" "${field}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  [[ "${value}" == "true" || "${value}" == "1" || "${value}" == "yes" ]]
}

ftctl_dr_ablestack_sync_start() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" wait_value="${5-}"
  local disk_map manifest_path checkpoint_path count now source_provider target_provider missing_config preflight_error rc

  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  ftctl_dr_ablestack_profile_involves_ablestack "${profile_file}" || return 0
  source_provider="$(ftctl_dr_ablestack_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_ablestack_profile_provider "${profile_file}" target)"

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  ftctl_ensure_dir "$(ftctl_dr_ablestack_manifest_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")" "0755"
  disk_map="$(ftctl_dr_ablestack_disk_map_path "${plan}")"
  manifest_path="$(ftctl_dr_ablestack_manifest_path "${plan}" "${run}")"
  checkpoint_path="$(ftctl_dr_ablestack_checkpoint_path "${plan}" "${run}")"

  ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  count="$(ftctl_dr_ablestack_disk_count "${disk_map}")" || count="0"
  ftctl_dr_runtime_path_set "${state_path}" \
    "driver=ABLESTACK" \
    "driver_state=TARGET_MAP_READY" \
    "step=ablestack-target-map-ready" \
    "progress=2" \
    "disk_map_path=${disk_map}" \
    "target_disk_map_path=${disk_map}" \
    "disk_map_role=target" \
    "target_disk_count=${count}" \
    "target_disk_invalid_count=0" \
    "updated_at=$(ftctl_now_iso8601)" || true
  if [[ "${target_provider}" != "ABLESTACK" ]]; then
    ftctl_log_event "dr-runtime" "dr.ablestack.source_metadata" "ok" "" "" \
      "plan=${plan} run=${run} source=${source_provider:-unknown} target=${target_provider:-unknown} disks=${count}"
    return 0
  fi

  if [[ "${count}" == "0" ]]; then
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=ABLESTACK" \
      "driver_state=WAITING_FOR_DISK_MAP" \
      "step=ablestack-disk-map-pending" \
      "progress=1" \
      "disk_map_path=${disk_map}" \
      "target_disk_map_path=${disk_map}" \
      "disk_map_role=target" \
      "target_disk_count=0" \
      "target_disk_invalid_count=1" \
      "accepted=false" \
      "error_code=DR_TARGET_DISK_MAPPING_INVALID" \
      "error_message=missing explicit target disk map"
    ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "warn" "" "" \
      "plan=${plan} run=${run} reason=missing_explicit_disk_map"
    return 31
  fi

  missing_config="$(ftctl_dr_ablestack_missing_config "${disk_map}" || true)"
  if [[ -n "${missing_config}" ]]; then
    rc=31
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=ABLESTACK" \
      "driver_state=CONFIG_INCOMPLETE" \
      "state=CONFIG_INCOMPLETE" \
      "step=ablestack-target-config-incomplete" \
      "progress=1" \
      "disk_map_path=${disk_map}" \
      "target_disk_map_path=${disk_map}" \
      "disk_map_role=target" \
      "target_disk_count=${count}" \
      "target_disk_invalid_count=${count:-1}" \
      "accepted=false" \
      "error_code=DR_TARGET_MAPPING_INVALID" \
      "error_message=${missing_config}" \
      "last_error=DR_TARGET_MAPPING_INVALID:${missing_config}"
    ftctl_log_event "dr-runtime" "dr.ablestack.config_incomplete" "warn" "" "" \
      "plan=${plan} run=${run} reason=${missing_config}"
    return "${rc}"
  fi

  preflight_error="$(ftctl_dr_ablestack_disk_preflight_error "${disk_map}" || true)"
  if [[ -n "${preflight_error}" ]]; then
    rc="$(ftctl_dr_ablestack_disk_preflight_rc "${preflight_error}")"
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=ABLESTACK" \
      "driver_state=TARGET_MAP_INVALID" \
      "state=ERROR" \
      "step=ablestack-target-map-invalid" \
      "progress=100" \
      "disk_map_path=${disk_map}" \
      "target_disk_map_path=${disk_map}" \
      "disk_map_role=target" \
      "target_disk_count=${count}" \
      "target_disk_invalid_count=1" \
      "accepted=false" \
      "error_code=$(ftctl_dr_ablestack_error_code_for_rc "${rc}")" \
      "error_message=${preflight_error}" \
      "driver_exit_code=${rc}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    ftctl_log_event "dr-runtime" "dr.ablestack.target_map_preflight" "fail" "" "${rc}" \
      "plan=${plan} run=${run} reason=${preflight_error}"
    return "${rc}"
  fi

  if [[ "${FTCTL_DR_ABLESTACK_FULL_SEED_ON_START}" == "1" ]] ||
      { [[ "${wait_value}" != "false" ]] && ftctl_dr_ablestack_profile_bool "${profile_file}" "request.performFullSeed"; }; then
    rc=0
    ftctl_dr_ablestack_full_seed_once "${plan}" "${run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      ftctl_dr_ablestack_mark_driver_error "${state_path}" "${rc}" "ablestack-full-seed-failed" \
        "ABLESTACK full seed failed before target durable checkpoint"
      return "${rc}"
    fi
    now="$(ftctl_now_iso8601)"
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=ABLESTACK" \
      "driver_state=TARGET_READY" \
      "state=READY" \
      "step=ablestack-full-seed-complete" \
      "progress=100" \
      "disk_map_path=${disk_map}" \
      "manifest_path=${manifest_path}" \
      "checkpoint_path=${checkpoint_path}" \
      "last_target_durable_at=${now}" \
      "target_ready_rpo_seconds=0"
    return 0
  fi

  rc=0
  ftctl_dr_ablestack_prepare_targets "${plan}" "${run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    ftctl_dr_ablestack_mark_driver_error "${state_path}" "${rc}" "ablestack-target-prepare-failed" \
      "ABLESTACK target preparation failed before target VM materialization"
    return "${rc}"
  fi
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${state_path}" \
    "driver=ABLESTACK" \
    "driver_state=TARGET_PREPARED" \
    "step=ablestack-targets-prepared" \
    "progress=5" \
    "disk_map_path=${disk_map}" \
    "manifest_path=${manifest_path}" \
    "checkpoint_path=${checkpoint_path}" \
    "last_source_checkpoint_at=${now}"
}
