#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Apache-2.0.
# Run only on a GitHub Actions runner. Each directory is an offline guest repo.
set -euo pipefail
out=$(realpath -m "${1:?output directory required}")
command -v docker >/dev/null || { echo 'Docker is required on the Actions runner' >&2; exit 2; }
mkdir -p "$out"

for major in 8 9 10; do
    dest="$out/rocky/$major"
    mkdir -p "$dest"
    packages=(qemu-guest-agent policycoreutils policycoreutils-python-utils)
    if [[ $major == 8 ]]; then packages+=(python39); else packages+=(python3); fi
    docker run --rm -v "$dest:/out" "rockylinux/rockylinux:$major" \
        bash -euo pipefail -c '
          dnf -y install dnf-plugins-core createrepo_c
          dnf download --resolve --alldeps --destdir=/out "$@"
          ls /out/qemu-guest-agent-*.rpm >/dev/null
          createrepo_c /out
        ' bash "${packages[@]}"
done

for spec in ubuntu:22.04 ubuntu:24.04 ubuntu:26.04 debian:12 debian:13; do
    family=${spec%%:*}
    version=${spec#*:}
    dest="$out/$family/$version"
    mkdir -p "$dest"
    docker run --rm -v "$dest:/out" "$spec" bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends dpkg-dev
      apt-get clean
      apt-get --download-only install -y --reinstall qemu-guest-agent python3
      cp /var/cache/apt/archives/*.deb /out/
      ls /out/qemu-guest-agent_*.deb >/dev/null
      cd /out
      dpkg-scanpackages . /dev/null | gzip -9 > Packages.gz
    '
done

for family in rocky ubuntu debian; do
    test -n "$(find "$out/$family" -type f \( -name '*.rpm' -o -name '*.deb' \) -print -quit)"
done
