#!/bin/bash
#
# Copyright 2025-2026 ABLECLOUD
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail
script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
prefix="$(dirname "$(dirname "$script_path")")"
# Source checkout, RPM (/usr/libexec), DEB/make (/usr/local/lib) and relocation.
for library in "$prefix/lib/vm_exec.py" \
    "$prefix/libexec/ablestack-qemu-exec-tools/vm_exec.py" \
    "$prefix/lib/ablestack-qemu-exec-tools/vm_exec.py"; do
    if [[ -r "$library" ]]; then
        exec python3 "$library" "$@"
    fi
done
printf '%s\n' 'vm_exec: matching vm_exec.py library is missing; reinstall the same version' >&2
exit 3
