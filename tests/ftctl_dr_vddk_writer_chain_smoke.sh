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

set -euo pipefail
base="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${base}/lib/ftctl/dr_kvm_vmware_mover.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
nbdkit() { printf '%s\n' "$@" > "${work}/args"; }
ftctl_kvm_vmware_start_writer "vc.example" "test-user" "${work}/password" true "" "" \
  "vm-test" "[datastore] test/test-000001.vmdk" "${work}/writer.sock" "${work}/writer.log" >/dev/null
wait
grep -Fxq 'single-link=false' "${work}/args"
! grep -Fxq 'single-link=true' "${work}/args"
grep -Fxq 'file=[datastore] test/test-000001.vmdk' "${work}/args"
grep -Fxq 'vm=moref=vm-test' "${work}/args"
grep -Fxq "password=+${work}/password" "${work}/args"
printf 'PASS: reverse writer opens complete snapshot chain and preserves password-file transport\n'
