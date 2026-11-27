#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
N2K_MIGRATION_LIB_DIR="${N2K_MIGRATION_LIB_DIR:-${N2K_LIB_DIR}/migration}"
[[ -d "$N2K_MIGRATION_LIB_DIR" ]] || N2K_MIGRATION_LIB_DIR="${N2K_LIB_DIR}/../v2k"

# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/cloud_handoff.sh"

# Operators may provision a private guest transport runtime without changing Mold.
if [[ -z "${N2K_PYTHON_BIN:-}" && -x "$N2K_LIB_DIR/runtime/bin/python" ]]; then
  export N2K_PYTHON_BIN="$N2K_LIB_DIR/runtime/bin/python"
fi
