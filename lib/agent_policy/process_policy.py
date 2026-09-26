#!/usr/bin/env python3
"""Conservative guest-side QGA filter repair. Host verification is mandatory."""
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# You may obtain a copy at https://www.apache.org/licenses/LICENSE-2.0
import argparse
import configparser
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import uuid

REQUIRED = ('guest-exec', 'guest-exec-status', 'guest-file-open', 'guest-file-close',
            'guest-file-read', 'guest-file-write', 'guest-file-seek', 'guest-file-flush',
            'guest-info', 'guest-ping', 'guest-get-osinfo', 'guest-sync', 'guest-sync-delimited')
ROOT = Path('/var/lib/ablestack-qemu-exec-tools/process-policy')


def run(args, env=None):
    result = subprocess.run(args, capture_output=True, text=True, timeout=20, env=env)
    if result.returncode:
        raise RuntimeError('Command failed: ' + args[0])
    if len(result.stdout) > 1048576:
        raise RuntimeError('Command output too large')
    return result.stdout


def digest(data):
    return hashlib.sha256(data).hexdigest()


def rpc_list(value):
    items = value.split(',') if value else []
    if any(not re.fullmatch(r'guest-[a-z0-9-]+', item) for item in items):
        raise ValueError('Unsupported RPC filter syntax')
    return items


def extend(value, allow):
    items = rpc_list(value)
    if allow:
        items += [rpc for rpc in REQUIRED if rpc not in items]
    else:
        items = [rpc for rpc in items if rpc not in REQUIRED]
    return ','.join(items)


def rewrite_args(args):
    """Retain order and unrelated args. Never evaluate an environment file."""
    result = list(args)
    seen = set()
    index = 0
    while index < len(result):
        word = result[index]
        key, sep, value = word.partition('=')
        if key in ('--allow-rpcs', '--block-rpcs', '-a', '-b'):
            allow = key in ('--allow-rpcs', '-a')
            if allow in seen:
                raise ValueError('Duplicate RPC filter option')
            seen.add(allow)
            if sep:
                result[index] = key + '=' + extend(value, allow)
            else:
                index += 1
                if index == len(result):
                    raise ValueError('Missing filter value')
                result[index] = extend(result[index], allow)
        elif 'rpcs' in key or key in ('--blacklist', '--whitelist'):
            raise ValueError('Unsupported vendor RPC option')
        index += 1
    return result


def rewrite_environment(text):
    lines = text.splitlines(keepends=True)
    indexes = [n for n, line in enumerate(lines) if re.match(r'^\s*FILTER_RPC_ARGS\s*=', line)]
    if len(indexes) != 1:
        raise ValueError('Expected one FILTER_RPC_ARGS assignment')
    index = indexes[0]
    raw = lines[index].split('=', 1)[1].strip()
    outer = shlex.split(raw, comments=True)
    if len(outer) != 1 and outer != []:
        raise ValueError('Ambiguous environment assignment')
    args = shlex.split(outer[0] if outer else '')
    if any('$' in value or '\\' in value or '\n' in value for value in args):
        raise ValueError('Unsupported environment expansion')
    updated = rewrite_args(args)
    if args == updated:
        return text, args
    # EnvironmentFile is not a shell script: encode only the supported literal grammar.
    value = ' '.join(updated)
    if any(c in value for c in ('"', "'", '$', '\\', '\n')):
        raise ValueError('Unsafe environment serialization')
    match = re.fullmatch(r'(\s*FILTER_RPC_ARGS\s*=\s*)[\"\'].*?[\"\'](\s*(?:#.*)?)(?:\r?\n)?', lines[index])
    prefix = match[1] if match else 'FILTER_RPC_ARGS='
    suffix = match[2].rstrip('\r\n') if match else ''
    lines[index] = prefix + '"' + value + '"' + suffix + '\n'
    return ''.join(lines), args


def rewrite_ini(text):
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.read_string(text)
    if not parser.has_section('general'):
        raise ValueError('Missing general section')
    lines = text.splitlines(keepends=True)
    general = False
    for n, line in enumerate(lines):
        if line.strip().startswith('['):
            general = line.strip() == '[general]'
        match = re.match(r'^(\s*)(allow-rpcs|block-rpcs)\s*=\s*([^#;\r\n]*)(.*)$', line.rstrip('\r\n'))
        if general and match:
            old = match[3].strip()
            new = extend(old, match[2] == 'allow-rpcs')
            if old != new:
                lines[n] = match[1] + match[2] + '=' + new + match[4] + '\n'
    return ''.join(lines)


def effective():
    pid = int(run(['systemctl', 'show', 'qemu-guest-agent', '-p', 'MainPID', '--value']).strip())
    if pid <= 0:
        raise RuntimeError('QGA is not running; install/start QGA before repair')
    args = Path('/proc/%s/cmdline' % pid).read_bytes().split(b'\0')
    args = [a.decode() for a in args[:-1]]
    binary = Path('/proc/%s/exe' % pid).resolve()
    if binary.name != 'qemu-ga':
        raise RuntimeError('Unexpected QGA executable')
    environment = dict(os.environ)
    environment.pop('QGA_CONF', None)
    for value in Path('/proc/%s/environ' % pid).read_bytes().split(b'\0'):
        if value.startswith(b'QGA_CONF='):
            environment['QGA_CONF'] = value.split(b'=', 1)[1].decode()
    dumped = run([str(binary), *args[1:], '--dump-conf'], env=environment)
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.read_string(dumped)
    section = parser['general']
    # dump-conf prints an empty allow-rpcs even when no allowlist was configured.
    allow = rpc_list(section['allow-rpcs']) if section.get('allow-rpcs') else None
    for index, value in enumerate(args):
        if value == '--allow-rpcs=' or (value in ('-a', '--allow-rpcs') and index + 1 < len(args) and args[index + 1] == ''):
            allow = []
    block = rpc_list(section.get('block-rpcs', ''))
    missing = [rpc for rpc in REQUIRED if (allow is not None and rpc not in allow) or rpc in block]
    return args[1:], environment.get('QGA_CONF'), missing, dumped


def regular(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_uid != 0 or path.stat().st_mode & 0o022:
        raise RuntimeError('Configuration must be a root-owned non-writable regular file')


def plan(args, config):
    changes = {}
    unit = run(['systemctl', 'cat', 'qemu-guest-agent'])
    filters = any(x.split('=')[0] in ('-a', '-b', '--allow-rpcs', '--block-rpcs') for x in args)
    if filters:
        source = Path('/etc/sysconfig/qemu-ga')
        if '/etc/sysconfig/qemu-ga' not in unit or not any(token in unit for token in ('$FILTER_RPC_ARGS', '${FILTER_RPC_ARGS}')):
            raise RuntimeError('Custom ExecStart filter requires administrator review')
        regular(source)
        before = source.read_text()
        after, configured = rewrite_environment(before)
        # Actual runtime filter values must match the file we are about to edit.
        runtime_filters = [x for x in args if x.startswith('--allow-rpcs=') or x.startswith('--block-rpcs=')]
        configured_filters = [x for x in configured if x.startswith('--allow-rpcs=') or x.startswith('--block-rpcs=')]
        if runtime_filters != configured_filters or not runtime_filters:
            raise RuntimeError('Runtime filter differs from supported environment assignment')
        if before != after:
            changes[source] = after.encode()
    for index, arg in enumerate(args):
        if arg in ('-c', '--config'):
            config = args[index + 1]
        elif arg.startswith('--config='):
            config = arg.split('=', 1)[1]
    if config:
        source = Path(config)
        if not source.is_absolute():
            raise RuntimeError('Relative QGA configuration is unsupported')
        regular(source)
        before = source.read_text()
        after = rewrite_ini(before)
        if after != before:
            changes[source] = after.encode()
    if not changes:
        raise RuntimeError('Effective restriction has no supported configuration source')
    return changes


def replace(path, content):
    regular(path)
    old = path.stat()
    fd, temporary = tempfile.mkstemp(prefix='.ablestack-process-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(content); handle.flush(); os.fsync(handle.fileno())
        shutil.copystat(path, temporary)
        os.chmod(temporary, old.st_mode & 0o777)
        os.chown(temporary, old.st_uid, old.st_gid)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def restart():
    run(['systemctl', 'restart', 'qemu-guest-agent'])
    run(['systemctl', 'is-active', '--quiet', 'qemu-guest-agent'])


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.parent.stat().st_uid != 0 or path.parent.stat().st_mode & 0o022:
        raise RuntimeError('Unsafe policy parent directory')
    if path.is_symlink() or path.stat().st_uid != 0 or path.stat().st_mode & 0o077:
        raise RuntimeError('Unsafe policy state directory')


def apply(changes):
    private_directory(ROOT)
    backup = ROOT / ('backup-' + uuid.uuid4().hex)
    backup.mkdir(mode=0o700)
    manifest = []
    for index, (path, after) in enumerate(changes.items()):
        before = path.read_bytes()
        (backup / str(index)).write_bytes(before)
        manifest.append({'path': str(path), 'saved': str(index), 'before': digest(before), 'after': digest(after)})
    (backup / 'manifest.json').write_text(json.dumps(manifest))
    try:
        for entry in manifest:
            path = Path(entry['path'])
            if digest(path.read_bytes()) != entry['before']: raise RuntimeError('Concurrent configuration change')
            replace(path, changes[path])
        restart()
        if effective()[2]: raise RuntimeError('Applied policy remains restricted')
    except Exception:
        try:
            restore(backup, allow_original=True)
        except Exception as error:
            raise RuntimeError('ROLLBACK_REQUIRED ' + backup.name + ': ' + str(error)) from error
        raise RuntimeError('Repair failed; original policy restored; ' + backup.name)
    return backup.name


def restore(backup, allow_original=False):
    private_directory(ROOT)
    if backup.parent != ROOT or not re.fullmatch(r'backup-[a-f0-9]{32}', backup.name) or backup.is_symlink():
        raise ValueError('Invalid backup ID')
    manifest = json.loads((backup / 'manifest.json').read_text())
    for entry in manifest:
        path = Path(entry['path']); regular(path)
        current = digest(path.read_bytes())
        if current != entry['after'] and not (allow_original and current == entry['before']):
            raise RuntimeError('Refusing to overwrite newer administrator configuration')
        content = (backup / entry['saved']).read_bytes()
        if digest(content) != entry['before']: raise RuntimeError('Backup checksum mismatch')
    for entry in manifest:
        replace(Path(entry['path']), (backup / entry['saved']).read_bytes())
    restart()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--policy', choices=['process-management'], default='process-management')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--apply', action='store_true')
    modes.add_argument('--restore', metavar='BACKUP_ID')
    modes.add_argument('--check', action='store_true')
    parser.add_argument('--json', action='store_true')
    opts = parser.parse_args()
    result = {'schemaVersion': 1, 'profile': 'process-management', 'status': 'CHECK_FAILED',
              'changed': False, 'restartPerformed': False, 'hostVerificationRequired': True,
              'featureReady': False, 'backupId': None}
    code = 4
    lock = None
    locked = False
    try:
        if os.geteuid() != 0: raise RuntimeError('Root privileges are required')
        private_directory(ROOT)
        lock = os.open(ROOT / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        locked = True
        if opts.restore:
            result.update(changed=None, restartPerformed=None)
            restore(ROOT / opts.restore)
            result.update(status='RESTORED_PENDING_HOST_VERIFY', changed=True, restartPerformed=True)
            code = 0
        else:
            args, config, missing, dumped = effective()
            result['effectivePolicyHash'] = digest(dumped.encode())
            result['configuredMissingRpcs'] = missing
            if missing and not opts.apply:
                result['status'] = 'POLICY_REPAIR_REQUIRED'; code = 5
            else:
                if missing:
                    changes = plan(args, config)
                    result.update(changed=None, restartPerformed=None)
                    result['backupId'] = apply(changes)
                    result.update(changed=True, restartPerformed=True,
                                  previousMissingRpcs=missing, configuredMissingRpcs=[])
                    result['effectivePolicyHash'] = digest(effective()[3].encode())
                result['status'] = 'POLICY_CONFIGURED_PENDING_HOST_VERIFY'; code = 0
    except Exception as error:
        result['status'] = 'CHECK_FAILED'
        result['error'] = str(error)[:255]
        code = 4
    finally:
        # Publish atomically while holding the policy lock, never through a symlink.
        if locked:
            temporary = None
            try:
                fd, temporary = tempfile.mkstemp(prefix='.result-', dir=str(ROOT))
                with os.fdopen(fd, 'w') as handle:
                    handle.write(json.dumps(result, ensure_ascii=False) + '\n')
                os.replace(temporary, ROOT / 'last-result.json')
            except Exception:
                result.update(status='CHECK_FAILED', error='Unable to persist policy result')
                code = 4
            finally:
                if temporary and os.path.exists(temporary): os.unlink(temporary)
        if lock is not None: os.close(lock)
    print(json.dumps(result, ensure_ascii=False))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
