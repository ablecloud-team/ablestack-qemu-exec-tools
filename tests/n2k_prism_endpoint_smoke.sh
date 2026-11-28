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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/n2k/nutanix_api.sh
source "${ROOT_DIR}/lib/n2k/nutanix_api.sh"

assert_endpoint() {
  local actual
  actual="$(n2k_nutanix_pc_base_url "$1")"
  if [[ "${actual}" != "$2" ]]; then
    printf 'Expected %s, got %s for %s\n' "$2" "${actual}" "$1" >&2
    return 1
  fi
}

assert_endpoint '192.0.2.9' 'https://192.0.2.9:9440'
assert_endpoint '192.0.2.9:9440' 'https://192.0.2.9:9440'
assert_endpoint 'prism.example.test:10443/' 'https://prism.example.test:10443'
assert_endpoint 'https://prism.example.test:10443/' 'https://prism.example.test:10443'
assert_endpoint '[2001:db8::9]:10443' 'https://[2001:db8::9]:10443'
assert_endpoint '[2001:db8::9]' 'https://[2001:db8::9]:9440'
assert_endpoint '2001:db8::9' 'https://[2001:db8::9]:9440'
printf 'Prism endpoint cases passed\n'
