#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# Build in a private tree. Never replace a host libguestfs library or tools.
set -euo pipefail
output="${1:?Usage: build-guest-config-native.sh output-directory}"
mkdir -p "$output"
output="$(realpath "$output")"
work="$(mktemp -d)"
# The caller may retain a failed build for diagnostics. No source-tree cleanup.
version=1.58.1
sha=1b8e5b4ef43e86302c3cedcb6fbc014be5bca5e85ca2875ef17c3cf67c671180
url="https://download.libguestfs.org/1.58-stable/libguestfs-${version}.tar.gz"
curl --fail --location --proto '=https' --tlsv1.2 --output "$work/source.tar.gz" "$url"
printf '%s  %s\n' "$sha" "$work/source.tar.gz" | sha256sum -c -
mkdir "$work/source"
tar -xzf "$work/source.tar.gz" --strip-components=1 -C "$work/source"
cd "$work/source"
./configure --prefix=/usr/share/ablestack/v2k/guest-config/native \
  --disable-appliance --disable-daemon --disable-ocaml --disable-perl \
  --disable-python --disable-ruby --disable-haskell --disable-php \
  --disable-erlang --disable-lua --disable-golang --disable-gobject \
  --disable-rust --disable-fuse --disable-nls --without-libvirt
make -j"${V2K_BUILD_JOBS:-4}" SUBDIRS="gnulib/lib common/errnostring common/protocol common/qemuopts common/utils common/structs include lib common/edit common/options common/progress fish"
mkdir -p "$output/bin" "$output/lib" "$output/licenses"
install -m 0755 fish/.libs/guestfish "$output/bin/guestfish"
install -m 0755 lib/.libs/libguestfs.so.0 "$output/lib/libguestfs.so.0"
cp COPYING COPYING.LIB "$output/licenses/"
python3 - "$output" "$sha" "$url" <<'PY'
import hashlib,json,platform,sys
from pathlib import Path
out=Path(sys.argv[1])
files={p:hashlib.sha256((out/p).read_bytes()).hexdigest() for p in ['bin/guestfish','lib/libguestfs.so.0']}
(out/'assets.json').write_text(json.dumps({'version':'1.58.1','source_sha256':sys.argv[2],'source_url':sys.argv[3],'arch':platform.machine(),'files':files},indent=2)+'\n')
PY
