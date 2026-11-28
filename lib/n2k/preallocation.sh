#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# Bundled in each standalone tool package; the parity test prevents drift.
# Resolver globals are part of the caller API.
# shellcheck disable=SC2034

image_preallocation_error() { printf 'Preallocation: %s\n' "$*" >&2; return 2; }

image_preallocation_enum() {
  case "${1-}" in off|metadata|falloc|full) return 0 ;; esac
  image_preallocation_error 'expected --target-preallocation off|metadata|falloc|full'
}

image_preallocation_has_targets() {
  local manifest="$1" path
  jq -e '(.phases.base_sync.done // false) or (.runtime.split.phase1.done // false)
    or any(.disks[]?; (.transfer.base_done // false)
      or (.transfer.preallocation.started // false) or (.transfer.preallocation.created // false))' \
    "$manifest" >/dev/null && return 0
  while IFS= read -r path; do
    [[ ! -e "$path" && ! -L "$path" ]] || return 0
  done < <(jq -r '.disks[]?.transfer.target_path // empty' "$manifest")
  return 1
}

# Pure resolver: result globals are consumed by CLI/wizard/manifest callers.
image_preallocation_resolve() {
  local storage="$1" format="$2" requested="${3-}" explicit="${4:-0}" manifest="${5:-}" hint="${6:-cli}"
  local saved="" existing=0
  IMAGE_PREALLOCATION_MODE=""
  IMAGE_PREALLOCATION_SOURCE=default
  if [[ "$explicit" == 1 ]]; then image_preallocation_enum "$requested" || return $?; fi
  case "$storage" in file|rbd|block) ;; *) image_preallocation_error "unknown storage: $storage"; return 2 ;; esac
  if [[ -n "$manifest" && -f "$manifest" ]]; then
    if [[ "$(jq -r '.target.storage.type // "file"' "$manifest")" != "$storage" || "$(jq -r '.target.format // "qcow2"' "$manifest")" != "$format" ]]; then
      image_preallocation_error 'target storage/format conflicts with the existing manifest'; return 2
    fi
    existing=1
    if [[ "$storage" == file ]]; then
      if jq -e '.target.storage | has("preallocation")' "$manifest" >/dev/null; then
        saved="$(jq -r '.target.storage.preallocation' "$manifest")"
        IMAGE_PREALLOCATION_SOURCE=manifest
      else
        saved=off
        IMAGE_PREALLOCATION_SOURCE=legacy
      fi
      image_preallocation_enum "$saved" || return $?
    fi
  fi
  if [[ "$storage" != file ]]; then
    if [[ "$explicit" == 1 && "$requested" != off ]]; then
      image_preallocation_error "$storage does not support file preallocation; omit the option or use off"; return 2
    fi
    [[ "$existing" == 0 ]] || IMAGE_PREALLOCATION_SOURCE=manifest
    return 0
  fi
  IMAGE_PREALLOCATION_MODE="${saved:-falloc}"
  if [[ "$explicit" == 1 ]]; then
    if [[ "$existing" == 1 && "$requested" != "$saved" ]] && image_preallocation_has_targets "$manifest"; then
      image_preallocation_error "cannot change $saved to $requested after target creation; use a new workdir"; return 2
    fi
    IMAGE_PREALLOCATION_MODE="$requested"
    IMAGE_PREALLOCATION_SOURCE="$hint"
  fi
  if [[ "$format" == raw && "$IMAGE_PREALLOCATION_MODE" == metadata ]]; then
    image_preallocation_error 'metadata preallocation requires qcow2'; return 2
  fi
}

image_preallocation_from_manifest() {
  local manifest="$1"
  image_preallocation_resolve "$(jq -r '.target.storage.type // "file"' "$manifest")" \
    "$(jq -r '.target.format // "qcow2"' "$manifest")" '' 0 "$manifest"
}

image_preallocation_store() {
  local manifest="$1" mode="$2" origin="$3" tmp
  tmp="$(mktemp "${manifest}.preallocation.XXXXXX")" || return $?
  if jq --arg mode "$mode" --arg origin "$origin" \
    '.target.storage.preallocation = (if $mode == "" then null else $mode end)
     | .target.storage.preallocation_source = $origin' "$manifest" > "$tmp"; then
    mv -- "$tmp" "$manifest"
  else
    rm -f -- "$tmp"; return 2
  fi
}

image_preallocation_choices() {
  printf 'falloc\tfalloc\tReserve file space (default)\n'
  printf 'off\toff\tSparse allocation\n'
  [[ "$1" != qcow2 ]] || printf 'metadata\tmetadata\tPreallocate qcow2 metadata only\n'
  printf 'full\tfull\tAllocate and initialize file space\n'
}

image_preallocation_check_tools() {
  local format="$1" mode="$2" method="${3:-convert}" help
  command -v qemu-img >/dev/null || { image_preallocation_error 'qemu-img is required'; return 2; }
  help="$(qemu-img create -f "$format" -o help file:/dev/null 2>&1)" || return $?
  [[ "$help" == *preallocation* ]] || { image_preallocation_error "qemu-img lacks $format preallocation support"; return 2; }
  if [[ "$method" == nbdcopy ]]; then
    command -v qemu-nbd >/dev/null || { image_preallocation_error 'qemu-nbd is required for file targets'; return 2; }
    command -v nbdcopy >/dev/null || { image_preallocation_error 'nbdcopy is required; select V2K_BASE_METHOD=convert if unavailable'; return 2; }
    if [[ "$mode" == falloc || "$mode" == full ]]; then
      help="$(nbdcopy --help 2>&1)" || return $?
      if [[ "$help" != *--allocated* ]]; then
        image_preallocation_error 'nbdcopy lacks allocation preservation flags; select V2K_BASE_METHOD=convert'; return 2
      fi
    fi
  fi
}

image_preallocation_record() {
  local manifest="$1" idx="$2" mode="$3" method="$4" state="$5" allocated="${6:-0}" tmp
  [[ -n "$manifest" && -f "$manifest" ]] || return 0
  tmp="$(mktemp "${manifest}.preallocation.XXXXXX")" || return $?
  if jq --argjson idx "$idx" --arg mode "$mode" --arg method "$method" --arg state "$state" --argjson allocated "$allocated" '
    .disks[$idx].transfer.preallocation = ((.disks[$idx].transfer.preallocation // {})
      + {mode:$mode,method:$method,started:true}
      + (if $state == "started" then {created:false,verified:false}
         elif $state == "created" then {created:true,verified:false}
         else {created:true,verified:true,allocated_bytes:$allocated} end))' "$manifest" > "$tmp"; then
    mv -- "$tmp" "$manifest"
  else
    rm -f -- "$tmp"; return 2
  fi
}

# Never overwrite an unknown or partially copied file, including dangling links.
image_preallocation_claim() {
  local manifest="$1" idx="$2" path="$3" mode="$4" method="$5"
  [[ ! -e "$path" && ! -L "$path" ]] || { image_preallocation_error "target already exists; preserved: $path"; return 2; }
  mkdir -p -- "$(dirname "$path")" || return $?
  (set -o noclobber; : > "$path") || return $?
  image_preallocation_record "$manifest" "$idx" "$mode" "$method" started
}

image_preallocation_verify() {
  local manifest="$1" idx="$2" path="$3" format="$4" size="$5" mode="$6" method="$7" info allocated
  info="$(qemu-img info --output=json "$path")" || return $?
  if ! jq -e --arg format "$format" --argjson size "$size" \
    '.format == $format and .["virtual-size"] == $size' <<< "$info" >/dev/null; then
    image_preallocation_error "target format/size verification failed: $path"; return 2
  fi
  allocated="$(stat -c '%b' -- "$path")" || return $?
  allocated=$((allocated * 512))
  if [[ ( "$mode" == falloc || "$mode" == full ) && "$allocated" -lt "$size" ]]; then
    image_preallocation_error "reserved allocation was lost: $path ($allocated < $size)"; return 2
  fi
  image_preallocation_record "$manifest" "$idx" "$mode" "$method" verified "$allocated"
}

image_preallocation_resolve_args() {
  local manifest="$1" hint="$2" storage=file format=qcow2 requested="" explicit=0 storage_set=0 format_set=0
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-storage) storage="${2-}"; storage_set=1; shift ;;
      --target-format) format="${2-}"; format_set=1; shift ;;
      --target-preallocation)
        image_preallocation_enum "${2-}" || return $?
        requested="$2"; explicit=1; shift ;;
    esac
    shift || true
  done
  if [[ "$storage" == qcow2 ]]; then storage="file"; format="qcow2"; fi
  if [[ -n "$manifest" && -f "$manifest" ]]; then
    if [[ "$storage_set" == 1 && "$storage" != "$(jq -r '.target.storage.type // "file"' "$manifest")" ]] ||
       [[ "$format_set" == 1 && "$format" != "$(jq -r '.target.format // "qcow2"' "$manifest")" ]]; then
      image_preallocation_error 'target storage/format conflicts with the existing manifest'; return 2
    fi
    storage="$(jq -r '.target.storage.type // "file"' "$manifest")"
    format="$(jq -r '.target.format // "qcow2"' "$manifest")"
  fi
  image_preallocation_resolve "$storage" "$format" "$requested" "$explicit" "$manifest" "$hint" || return $?
}

# Pure policy selection; the actual run/init owns all manifest mutations.
image_preallocation_wizard() {
  local tool="$1" storage="$2" format="$3" requested="$4" explicit="$5" manifest="$6" yes="$7" print_only="$8" selected
  image_preallocation_resolve "$storage" "$format" "$requested" "$explicit" "$manifest" || return $?
  if [[ "$storage" == file && "$explicit" == 0 && ! -f "$manifest" && "$yes" == 0 && "$print_only" == 0 ]]; then
    selected="$("${tool}_interactive_select_tsv" 'target preallocation' "$(image_preallocation_choices "$format")" '' 0 1)" || return $?
    image_preallocation_resolve "$storage" "$format" "$selected" 1 '' wizard || return $?
  fi
}
