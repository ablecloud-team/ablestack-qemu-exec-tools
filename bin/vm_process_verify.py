#!/usr/bin/env python3
"""Host-side Linux RPC and harmless I/O verification; never certifies adapter readiness."""
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# You may obtain a copy at https://www.apache.org/licenses/LICENSE-2.0
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import subprocess
import stat
import time
import uuid

RPCS = ('guest-exec', 'guest-exec-status', 'guest-file-open', 'guest-file-close',
        'guest-file-read', 'guest-file-write', 'guest-file-seek', 'guest-file-flush')


class Verifier:
    def __init__(self, vm):
        self.deadline = time.monotonic() + 20
        self.vm = self.virsh('domuuid', vm).strip()
        if str(uuid.UUID(self.vm)) != self.vm: raise ValueError('Invalid VM UUID')
        self.pid = None
        self.path = '/var/lib/qemu-ga/ablestack-process-probe/' + uuid.uuid4().hex + '.tmp'

    def virsh(self, *args):
        budget = min(3, self.deadline - time.monotonic())
        if budget <= 0: raise TimeoutError('Verification deadline exceeded')
        environment = dict(os.environ, LC_ALL='C')
        result = subprocess.run(['virsh', '-c', 'qemu:///system', *args],
                                capture_output=True, text=True, timeout=budget, env=environment)
        if result.returncode: raise RuntimeError('Host RPC failed: ' + result.stderr.strip()[:180])
        if len(result.stdout) > 1048576: raise RuntimeError('Host response exceeded size limit')
        return result.stdout

    def rpc(self, command, arguments=None):
        payload = {'execute': command}
        if arguments is not None: payload['arguments'] = arguments
        result = json.loads(self.virsh('qemu-agent-command', self.vm, '--timeout', '3', json.dumps(payload)))
        if 'error' in result or 'return' not in result: raise RuntimeError('QGA rejected ' + command)
        return result['return']

    def execute(self, executable, args):
        self.pid = self.rpc('guest-exec', {'path': executable, 'arg': args, 'capture-output': True})['pid']
        while True:
            result = self.rpc('guest-exec-status', {'pid': self.pid})
            if result.get('exited') is True:
                if result.get('exitcode') != 0 or result.get('signal') or result.get('out-truncated') or result.get('err-truncated'):
                    raise RuntimeError('Guest probe failed')
                self.pid = None
                return base64.b64decode(result.get('out-data', ''), validate=True)
            time.sleep(0.1)

    def verify(self, result):
        info = self.rpc('guest-info')
        commands = {item['name']: item['enabled'] for item in info['supported_commands']}
        result['rpcs'] = {name: 'ENABLED' if commands.get(name) is True else 'DISABLED' if name in commands else 'UNSUPPORTED' for name in RPCS}
        result['qgaVersion'] = info['version']
        if set(result['rpcs'].values()) != {'ENABLED'}: raise RuntimeError('Required RPC unavailable')
        marker = ('ablestack-process-' + uuid.uuid4().hex).encode()
        if self.execute('/usr/bin/printf', ['%s', marker.decode()]) != marker:
            raise RuntimeError('Execution output mismatch')
        handle = None
        primary_error = None
        try:
            handle = self.rpc('guest-file-open', {'path': self.path, 'mode': 'w+'})
            written = self.rpc('guest-file-write', {'handle': handle, 'buf-b64': base64.b64encode(marker).decode()})
            if written['count'] != len(marker): raise RuntimeError('Short guest-file write')
            self.rpc('guest-file-flush', {'handle': handle})
            self.rpc('guest-file-seek', {'handle': handle, 'offset': 0, 'whence': 0})
            read = self.rpc('guest-file-read', {'handle': handle, 'count': len(marker)})
            if base64.b64decode(read['buf-b64'], validate=True) != marker: raise RuntimeError('File probe mismatch')
        except Exception as error:
            primary_error = error
        finally:
            # Cleanup gets its own bounded budget even after a main probe timeout.
            self.deadline = time.monotonic() + 6
            if handle is not None:
                try: self.rpc('guest-file-close', {'handle': handle})
                except Exception as error: primary_error = primary_error or error
            try:
                self.execute('/usr/bin/rm', ['-f', '--', self.path])
                result['fileCleaned'] = True
            except Exception as error:
                primary_error = primary_error or error
                result['fileCleaned'] = False
        if primary_error: raise primary_error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('vm', help='Current libvirt domain name')
    args = parser.parse_args()
    result = {'schemaVersion': 1, 'status': 'CHECK_FAILED', 'featureReady': False, 'fileCleaned': None}
    lock = None
    verifier = None
    code = 3
    try:
        if os.geteuid() != 0: raise RuntimeError('Host root is required')
        verifier = Verifier(args.vm)
        root = Path('/run/ablestack-vm-operations')
        locks = root / 'locks'
        for directory in (root, locks):
            directory.mkdir(mode=0o700, exist_ok=True)
            if directory.is_symlink() or directory.stat().st_uid != 0 or directory.stat().st_mode & 0o077:
                raise RuntimeError('Unsafe host operation directory')
        path = locks / (verifier.vm + '.lock')
        lock = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        metadata = os.fstat(lock)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_uid != 0 or metadata.st_mode & 0o022:
            raise RuntimeError('Unsafe VM operation lock')
        lease = root / verifier.vm
        if lease.is_symlink() or (lease.exists() and any(lease.iterdir())): raise RuntimeError('VM operation lease is active or unresolved')
        if verifier.virsh('domstate', verifier.vm).strip() != 'running': raise RuntimeError('VM is not running')
        if verifier.virsh('domjobinfo', verifier.vm).split() != ['Job', 'type:', 'None']:
            raise RuntimeError('VM job active or unknown')
        jobs = json.loads(verifier.virsh('qemu-monitor-command', verifier.vm, '{"execute":"query-block-jobs"}'))
        if jobs.get('return') != []: raise RuntimeError('Block job active or unknown')
        result['vmUuid'] = verifier.vm
        verifier.verify(result)
        result['status'] = 'RPC_PROBES_PASSED'
        code = 0
    except Exception as error:
        result['error'] = str(error)[:255]
        if verifier: result['guestExecPid'] = verifier.pid
    finally:
        if lock is not None: os.close(lock)
    print(json.dumps(result))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
