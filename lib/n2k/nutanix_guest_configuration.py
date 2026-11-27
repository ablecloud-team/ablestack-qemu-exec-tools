#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Fixed source collectors over authenticated SSH/WinRM; runtime secrets only."""
import argparse,base64,hashlib,json,os,shlex,sys,time,uuid
from pathlib import Path

def collect(manifest,common):
    vm=manifest['source']['vm']; expected=str(uuid.UUID(vm['uuid']))
    host=os.environ.get('N2K_SOURCE_GUEST_HOST','')
    if not host:
        addresses={ip for nic in vm.get('nics',[]) for ip in nic.get('ip_addresses',[])}
        if len(addresses)!=1:raise ValueError('SOURCE_GUEST_ADDRESS_REQUIRED')
        host=next(iter(addresses))
    user=os.environ['N2K_SOURCE_GUEST_USER']; password=os.environ['N2K_SOURCE_GUEST_PASSWORD']
    if user.lower().split('\\')[-1]=='administrator':
        import winrm
        session=winrm.Session('http://'+host+':5985/wsman',auth=(user,password),transport='ntlm',operation_timeout_sec=60,read_timeout_sec=75)
        script=(common/'guest-config/source-windows.ps1').read_text(encoding='utf-8-sig')
        script=script.replace('param([Parameter(Mandatory=$true)][string]$OutputPath)','')
        script=script.replace("$r|ConvertTo-Json -Depth 10 -Compress|Out-File -LiteralPath $OutputPath -Encoding UTF8", "$r.source_vm_uuid=(Get-CimInstance Win32_ComputerSystemProduct).UUID.ToLower();$r|ConvertTo-Json -Depth 10 -Compress")
        reply=session.run_ps(script)
        if reply.status_code:raise ValueError('SOURCE_GUEST_PROBE_FAILED')
        raw=reply.std_out
    else:
        import paramiko
        client=paramiko.SSHClient();client.load_system_host_keys()
        pin=os.environ.get('N2K_SOURCE_GUEST_HOSTKEY_SHA256','')
        class Pin(paramiko.MissingHostKeyPolicy):
            def missing_host_key(self,client,hostname,key):
                if not pin or hashlib.sha256(key.asbytes()).hexdigest()!=pin:raise ValueError('SOURCE_GUEST_HOST_KEY_REQUIRED')
        client.set_missing_host_key_policy(Pin())
        client.connect(host,username=user,password=password,allow_agent=False,look_for_keys=False,timeout=10,auth_timeout=15)
        try:
            script=(common/'guest-config/source-linux.py').read_text()
            script=script.replace("'root_fs_uuid':root_uuid,", "'root_fs_uuid':root_uuid,'source_vm_uuid':Path('/sys/class/dmi/id/product_uuid').read_text().strip().lower(),")
            inp,out,err=client.exec_command("sudo -S -p '' /usr/bin/python3 -c "+shlex.quote(script),timeout=90)
            inp.write(password+'\n');inp.flush();inp.channel.shutdown_write()
            raw=out.read(1048577)
            if out.channel.recv_exit_status():raise ValueError('SOURCE_GUEST_PROBE_FAILED')
        finally:client.close()
    if len(raw)>1048576:raise ValueError('SOURCE_CONFIG_TOO_LARGE')
    result=json.loads(raw.decode('utf-8-sig'))
    if str(uuid.UUID(result.get('source_vm_uuid','')))!=expected:raise ValueError('SOURCE_GUEST_IDENTITY_MISMATCH')
    result['source_vm_uuid']=expected;result['collected_at']=int(time.time())
    return result

def request_shutdown(manifest):
    import winrm, requests
    expected=str(uuid.UUID(manifest['source']['vm']['uuid']))
    host=os.environ['N2K_SOURCE_GUEST_HOST'];user=os.environ['N2K_SOURCE_GUEST_USER'];password=os.environ['N2K_SOURCE_GUEST_PASSWORD']
    session=winrm.Session('http://'+host+':5985/wsman',auth=(user,password),transport='ntlm',operation_timeout_sec=20,read_timeout_sec=30)
    check=session.run_ps('(Get-CimInstance Win32_ComputerSystemProduct).UUID.ToLower()')
    if check.status_code or str(uuid.UUID(check.std_out.decode().strip()))!=expected:raise ValueError('SOURCE_GUEST_IDENTITY_MISMATCH')
    try:
        reply=session.run_ps("$ErrorActionPreference='Stop'; Stop-Computer -Force")
        if reply.status_code:raise ValueError('SOURCE_GUEST_SHUTDOWN_FAILED')
    except requests.exceptions.ConnectionError:
        pass
    # This is a request receipt only. Prism OFF confirmation remains mandatory.
    print(json.dumps({'guest_shutdown_requested':True,'source_vm_uuid':expected,'verified_off':False}))

def main():
    p=argparse.ArgumentParser();p.add_argument('--manifest');p.add_argument('--common-dir');p.add_argument('--host-key-host');p.add_argument('--request-shutdown',action='store_true');a=p.parse_args()
    if a.host_key_host:
        import paramiko
        transport=paramiko.Transport((a.host_key_host,22))
        try:
            transport.start_client(timeout=10);print(hashlib.sha256(transport.get_remote_server_key().asbytes()).hexdigest());return
        finally:transport.close()
    if not a.manifest or not a.common_dir:p.error('--manifest and --common-dir are required')
    manifest=json.loads(Path(a.manifest).read_text())
    if a.request_shutdown:request_shutdown(manifest);return
    print(json.dumps(collect(manifest,Path(a.common_dir))))
if __name__=='__main__':
    try:main()
    except Exception as e:
        print(str(e) if isinstance(e,ValueError) and str(e).startswith('SOURCE_') else 'SOURCE_CONFIG_REQUIRED: '+type(e).__name__,file=sys.stderr);sys.exit(44)
