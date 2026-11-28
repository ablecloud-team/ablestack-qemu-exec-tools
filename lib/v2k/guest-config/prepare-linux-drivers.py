#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Run inside the isolated offline guest, never activate guest LVM on the host."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

BASE = Path('/var/lib/ablestack-v2k/guest-config')
MODULES = ['ahci', 'virtio_pci', 'virtio_scsi', 'virtio_blk', 'sd_mod', 'dm_mod']


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=240)
    if result.returncode:
        raise RuntimeError('INITRAMFS_PREPARATION_FAILED: ' + args[0] + ': ' + result.stderr[-800:])
    return result.stdout


def verify_modules(kernel, listing):
    for module in MODULES:
        # Older kmod prints a name header before the builtin marker even when
        # a single output field was requested.
        filename = run('modinfo', '-k', kernel, '-F', 'filename', module).strip().splitlines()[-1]
        # Module aliases normalize '-' and '_'; archive filenames need not.
        expected = Path(filename).name.split('.ko', 1)[0] + '.ko'
        if filename != '(builtin)' and expected not in listing:
            raise ValueError('INITRAMFS_MODULE_MISSING: ' + module + ' (' + filename + ')')


def main():
    plan = json.loads((BASE / 'plan.json').read_text())
    if plan['os'] != 'linux' or plan['os_id'] not in ['ubuntu', 'rocky']:
        raise ValueError('INITRAMFS_GUEST_UNSUPPORTED')
    controller = json.loads((BASE / 'controller-plan.json').read_text())
    if controller['hash'] != plan['controller_plan_hash'] or not all(d['target']['bus'] in ['sata', 'scsi'] for d in controller['disks']):
        raise ValueError('INITRAMFS_CONTROLLER_UNSUPPORTED')
    kernels = sorted(p.name for p in Path('/lib/modules').iterdir()
                     if p.is_dir() and Path('/boot/vmlinuz-' + p.name).is_file())
    if not kernels:
        raise ValueError('INITRAMFS_KERNEL_REQUIRED')
    evidence = []
    for kernel in kernels:
        if plan['os_id'] == 'rocky':
            image = '/boot/initramfs-' + kernel + '.img'
            run('dracut', '--force', '--no-hostonly', '--add', 'lvm', '--add-drivers',
                ' '.join(MODULES), image, kernel)
            listing = run('lsinitrd', image)
            if 'lvm' not in run('lsinitrd', '-m', image).split():
                raise ValueError('INITRAMFS_LVM_MISSING')
        else:
            # Explicit modules survive later kernel updates as part of this clone.
            modules = Path('/etc/initramfs-tools/modules')
            previous = modules.read_text() if modules.exists() else ''
            missing = [m for m in MODULES if m not in previous.splitlines()]
            if missing:
                modules.write_text(previous.rstrip() + '\n' + '\n'.join(missing) + '\n')
            image = '/boot/initrd.img-' + kernel
            run('update-initramfs', '-u', '-k', kernel)
            listing = run('lsinitramfs', image)
        verify_modules(kernel, listing)
        evidence.append({'kernel': kernel, 'image': image, 'modules': MODULES,
                         'sha256': hashlib.sha256(Path(image).read_bytes()).hexdigest()})
    report = {'version': 1, 'status': 'VERIFIED', 'controller_plan_hash': plan['controller_plan_hash'],
              'kernels': evidence, 'adapter': 'isolated-guest-initramfs-v1'}
    target = BASE / 'driver-preparation.json'
    temporary = target.with_suffix('.new')
    with temporary.open('w') as stream:
        os.chmod(temporary, 0o600)
        json.dump(report, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, target)


if __name__ == '__main__':
    main()
