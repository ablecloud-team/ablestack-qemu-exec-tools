#!/usr/bin/env python3
"""Read-only Linux process snapshot. No command lines, signals or service mutations."""
# Copyright 2026 ABLECLOUD. Apache-2.0.
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

MAX_WIRE = 1024 * 1024
MAX_ROWS = 10000


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def stat_record(text):
    start, end = text.index('('), text.rindex(')')
    fields = text[end + 2:].split()
    return int(text[:start].strip()), text[start + 1:end], fields[0], int(fields[1]), fields[19], max(0, int(fields[21])), int(fields[11]) + int(fields[12])


def utc(value):
    return value.isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def new_snapshot(request, boot):
    now = dt.datetime.now(dt.timezone.utc)
    return dict(schemaVersion='1.0', kind='snapshot', requestId=request['requestId'],
                authority=request['authority'], snapshotId=str(uuid.uuid4()), bootId=boot,
                observedAt=utc(now), expiresAt=utc(now + dt.timedelta(seconds=10)),
                status='OK', truncated=False, totalKnown=None, processes=[])


def add_row(snapshot, row, size, limit=MAX_WIRE):
    used = len(compact(row).encode('utf-8')) + 1
    if len(snapshot['processes']) >= MAX_ROWS or size + used > limit - 1024:
        snapshot.update(status='PARTIAL', truncated=True)
        return size, False
    snapshot['processes'].append(row)
    return size + used, True


class Deadline(Exception):
    pass


def expired(*_):
    raise Deadline()


def service_configuration(props):
    # systemctl renders runtime pid/status/timestamps after ignore_errors.
    # Those must not change a configuration identity when a service restarts.
    command = re.sub(r"( ; ignore_errors=(?:yes|no)) ; start_time=.*?(?= \})", r"\1", props.get('ExecStart', ''))
    return {'account': props.get('User', ''), 'canStart': props.get('CanStart') == 'yes',
            'canStop': props.get('CanStop') == 'yes', 'command': command,
            'requires': sorted(props.get('Requires', '').split()), 'wants': sorted(props.get('Wants', '').split())}


def service_map(deadline):
    """Ask systemd for effective properties in one bounded call; never parse ps tables."""
    properties = 'Id,MainPID,ExecStart,User,Requires,Wants,CanStart,CanStop'
    budget = min(0.7, deadline - time.monotonic())
    if budget <= 0:
        raise Deadline()
    # Temporary output is not used: bounded pipe reader aborts at 256 KiB.
    import selectors
    process = subprocess.Popen(['/usr/bin/systemctl', 'show', '--all', '--type=service',
                                '--property=' + properties, '--no-pager'],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    data = bytearray(); end = time.monotonic() + budget
    try:
        while selector.get_map():
            if time.monotonic() >= end: raise Deadline()
            for key, _ in selector.select(min(0.05, max(0, end - time.monotonic()))):
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk: selector.unregister(key.fileobj); break
                data.extend(chunk)
                if len(data) > 262144: raise ValueError('service output bound')
        if process.wait(timeout=max(0.001, end-time.monotonic())) != 0: raise ValueError('service query unavailable')
    finally:
        selector.close()
        if process.poll() is None: os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=0.2)
        process.stdout.close()
    result = {}
    for block in data.decode('utf-8', 'strict').strip().split('\n\n'):
        props = dict(line.split('=', 1) for line in block.splitlines() if '=' in line)
        if not props.get('MainPID', '0').isdigit() or int(props.get('MainPID', '0')) <= 0: continue
        name = props.get('Id', '')
        if not name.endswith('.service') or len(name) > 256: continue
        # Hash only; never return service command/arguments or accounts in the service DTO.
        config = service_configuration(props)
        digest = hashlib.sha256(json.dumps(config, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        result.setdefault(int(props['MainPID']), []).append({'manager': 'systemd', 'name': name, 'configurationHash': digest})
    return result


def collect(request, proc=Path('/proc'), services=None, max_wire=MAX_WIRE):
    boot = 'linux:' + str(uuid.UUID((proc / 'sys/kernel/random/boot_id').read_bytes().decode().strip()))
    snapshot = new_snapshot(request, boot)
    deadline = time.monotonic() + min(request['budgetMs'], 3000) / 1000
    owners = {}
    try:
        for line in Path('/etc/passwd').read_bytes().decode().splitlines():
            fields = line.split(':')
            if len(fields) == 7: owners[int(fields[2])] = fields[0]
    except (OSError, ValueError): pass
    try:
        pids = sorted(int(p.name) for p in proc.iterdir() if p.name.isascii() and p.name.isdigit() and int(p.name) > 0)
        # Sample once before service discovery, then compare only the same PID/start identity.
        first_cpu = {}
        for pid in pids:
            if time.monotonic() >= deadline - 0.3: break
            try:
                record = stat_record((proc / str(pid) / 'stat').read_bytes().decode(errors='replace'))
                if record[0] == pid: first_cpu[pid] = (record[4], record[6], time.monotonic())
            except (OSError, ValueError, IndexError): pass
        if services is None:
            try: services = service_map(deadline)
            except (OSError, ValueError, Deadline, subprocess.TimeoutExpired):
                services = {}; snapshot['status'] = 'PARTIAL'
        # A short interval makes an idle process report zero while preserving the 3s budget.
        if first_cpu and time.monotonic() < deadline - 0.3:
            earliest = min(sample[2] for sample in first_cpu.values())
            time.sleep(min(max(0, 0.25 - (time.monotonic() - earliest)), max(0, deadline - time.monotonic() - 0.3)))
        clock_ticks = os.sysconf('SC_CLK_TCK')
        size = len(compact(snapshot).encode())
        for pid in pids:
            if time.monotonic() >= deadline:
                snapshot.update(status='PARTIAL', truncated=True); break
            path = proc / str(pid)
            try:
                first = stat_record((path / 'stat').read_bytes().decode(errors='replace'))
                uid = path.stat().st_uid
                owner = owners.get(uid, str(uid))[:256]
                second = stat_record((path / 'stat').read_bytes().decode(errors='replace'))
                if first[0] != pid or first[4] != second[4]:
                    snapshot['status'] = 'PARTIAL'; continue
                cpu = None
                sample = first_cpu.get(pid)
                if sample and sample[0] == second[4] and second[6] >= sample[1] and clock_ticks > 0:
                    elapsed = time.monotonic() - sample[2]
                    if elapsed >= 0.25:
                        cpu = round((second[6] - sample[1]) * 100.0 / (clock_ticks * elapsed), 2)
                mapping = services.get(pid, [])
                if len(mapping) > 128: snapshot['status'] = 'PARTIAL'
                row = {'identity': {'vmUuid': request['authority']['vmUuid'], 'bootId': boot, 'pid': pid, 'startTicks': first[4]},
                       'ppid': first[3], 'name': first[1][:256] or '?', 'owner': owner, 'state': first[2],
                       'memoryBytes': min(first[5] * os.sysconf('SC_PAGE_SIZE'), 9007199254740991),
                       'cpuPercent': cpu, 'services': mapping[:128], 'allowedActions': []}
                size, fits = add_row(snapshot, row, size, max_wire)
                if not fits: break
            except (OSError, ValueError, IndexError): snapshot['status'] = 'PARTIAL'
        if snapshot['status'] == 'OK': snapshot['totalKnown'] = len(snapshot['processes'])
        if 'linux:' + (proc / 'sys/kernel/random/boot_id').read_bytes().decode().strip() != boot: raise ValueError('boot changed')
    except Deadline:
        snapshot.update(status='PARTIAL', truncated=True, totalKnown=None)
    return snapshot


def main():
    if len(sys.argv) != 3 or sys.argv[1] != '--request-base64': return 2
    raw = base64.b64decode(sys.argv[2], validate=True)
    if len(raw) > 65536: return 2
    request = json.loads(raw.decode())
    if request.get('operation') != 'process.list' or request.get('schemaVersion') != '1.0': return 2
    if type(request.get('budgetMs')) is not int or not 1 <= request['budgetMs'] <= 10000: return 2
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, min(3.5, request['budgetMs']/1000 + 0.2))
    try:
        result = collect(request)
    except (OSError, ValueError, Deadline):
        result = dict(schemaVersion='1.0', kind='failure', requestId=request['requestId'], authority=request['authority'],
                      error=dict(code='CHECK_FAILED', message='Guest process observation unavailable', retryMode='READ_ONLY'))
    finally: signal.setitimer(signal.ITIMER_REAL, 0)
    wire = compact(result).encode('utf-8')
    if len(wire) > MAX_WIRE: return 3
    sys.stdout.buffer.write(wire + b'\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
