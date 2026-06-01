#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: $1" >&2
    exit 2
  }
}

require_cmd jq

output='kernel/drivers/virtio/virtio_pci.ko.xz kernel/drivers/scsi/virtio_scsi.ko.xz'

summary="$(jq -nc \
  --arg output "${output}" \
  --argjson modules '["virtio_pci","virtio_scsi","virtio_blk","scsi_mod"]' \
  '
    reduce $modules[] as $mod (
      {present:[],missing:[]};
      if ($output | contains($mod)) then
        .present += [$mod]
      else
        .missing += [$mod]
      end
    )
  ')"

jq -e '
  (.present | index("virtio_pci") != null)
  and (.present | index("virtio_scsi") != null)
  and (.missing | index("virtio_blk") != null)
  and (.missing | index("scsi_mod") != null)
' <<<"${summary}" >/dev/null

echo "[OK] v2k initramfs module summary jq expression"
