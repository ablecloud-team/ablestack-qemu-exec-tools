#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Provision an offline private WinRM client without changing host Python/crypto."""
import argparse
import hashlib
from pathlib import Path
import subprocess

WHEELS = {
    'pywinrm-0.5.0-py3-none-any.whl': 'c267046d281de613fc7c8a528cdd261564d9b99bdb7c2926221eff3263b700c8',
    'requests_ntlm-1.3.0-py3-none-any.whl': '4c7534a7d0e482bb0928531d621be4b2c74ace437e88c5a357ceb7452d25a510',
    'pyspnego-0.12.0-py3-none-any.whl': '84cc8dae6ad21e04b37c50c1d3c743f05f193e39498f6010cc68ec1146afd007',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wheel-dir', required=True, type=Path)
    args = parser.parse_args()
    # Validate every supplied payload before creating or changing the runtime.
    paths = []
    for name, digest in WHEELS.items():
        path = args.wheel_dir / name
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('SOURCE_RUNTIME_WHEEL_HASH_MISMATCH: ' + name)
        paths.append(str(path.resolve()))
    root = Path(__file__).resolve().parent / 'runtime'
    if not (root / 'bin/python').exists():
        subprocess.run(['python3', '-m', 'venv', '--system-site-packages', str(root)], check=True)
    python = str(root / 'bin/python')
    # Wheels stay operator supplied; no package index or global pip modification.
    subprocess.run([python, '-m', 'pip', 'install', '--no-index', '--no-deps', *paths], check=True)
    subprocess.run([python, '-c', 'import winrm,spnego,requests_ntlm,xmltodict,paramiko,yaml; '
                    'from importlib.metadata import version; '
                    'assert version("pywinrm")=="0.5.0"; '
                    'assert version("requests-ntlm")=="1.3.0"; '
                    'assert version("pyspnego")=="0.12.0"'], check=True)
    print('Qualified private source runtime: ' + python)


if __name__ == '__main__':
    main()
