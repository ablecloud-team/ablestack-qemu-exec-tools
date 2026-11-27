#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Qualify the installed signed VirtIO serial package before clone staging."""
import hashlib,os,shutil,subprocess
from pathlib import Path

def payloads():
 directory=Path(os.environ.get('V2K_GUEST_CONFIG_WINDOWS_DRIVERS','/usr/share/virtio-win/drivers/by-driver/vioserial/2k22/amd64'))
 files=[directory/name for name in ['vioser.inf','vioser.sys','vioser.cat']]
 if any(not p.is_file() or p.is_symlink() for p in files):raise ValueError('WINDOWS_SERIAL_DRIVER_PAYLOAD_REQUIRED')
 tool=shutil.which('aspkg') or shutil.which('rpm')
 if not tool:raise ValueError('WINDOWS_SERIAL_DRIVER_PROVENANCE_REQUIRED')
 package=subprocess.check_output([tool,'-qf',str(files[0])],text=True,timeout=30).strip()
 if not package.startswith('virtio-win-') or '\n' in package:raise ValueError('WINDOWS_SERIAL_DRIVER_PROVENANCE_REQUIRED')
 records=subprocess.check_output([tool,'-q','--dump',package],text=True,timeout=45)
 expected={line.split()[0]:line.split()[3] for line in records.splitlines() if len(line.split())>=4}
 hashes={}
 for p in files:
  wanted=expected.get(str(p),'');data=p.read_bytes()
  algorithm='sha256' if len(wanted)==64 else 'md5' if len(wanted)==32 else None
  if not algorithm or hashlib.new(algorithm,data).hexdigest()!=wanted:raise ValueError('WINDOWS_SERIAL_DRIVER_PACKAGE_CHANGED')
  hashes[p.name]=hashlib.sha256(data).hexdigest()
 return files,{'package':package,'provenance':'installed-rpm-file-digests-and-enforced-windows-catalog','sha256':hashes}
