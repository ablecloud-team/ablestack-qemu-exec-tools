#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Apache-2.0.
set -euo pipefail
[ "$(id -u)" = 0 ] || exit 2
here="$(cd "$(dirname "$0")" && pwd -P)"
. /etc/os-release
case "$ID:$VERSION_ID:$(uname -m)" in rocky:9.[678]:x86_64|rocky:10.2:x86_64|ubuntu:22.04:x86_64|ubuntu:24.04:x86_64|ubuntu:26.04:x86_64) ;; *) echo unsupported >&2; exit 2;; esac
if command -v selinuxenabled >/dev/null && selinuxenabled; then
  python3 "$here/action_policy.py" --apply --payload "$here"
else
  # The same root-owned package transaction is used without SELinux operations.
  python3 "$here/action_policy_plain.py" "$here"
fi
