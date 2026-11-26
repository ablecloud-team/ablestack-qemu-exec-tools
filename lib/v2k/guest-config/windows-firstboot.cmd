@echo off
REM Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
REM One firstboot entry: offline MSI then SYSTEM startup task; one framework reboot.
setlocal
set "V2KROOT=C:\ProgramData\ABLECLOUD\V2K\GuestConfig"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "%V2KROOT%\bootstrap.ps1" -PrepareOnly
if errorlevel 1 exit /b 1
msiexec.exe /i "%V2KROOT%\payload\qemu-ga-x86_64.msi" /qn /norestart /l*v "%V2KROOT%\qga-install.log"
set "V2KRC=%ERRORLEVEL%"
if not "%V2KRC%"=="0" if not "%V2KRC%"=="3010" exit /b 1
sc.exe query QEMU-GA >nul 2>&1
if errorlevel 1 exit /b 1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "%V2KROOT%\bootstrap.ps1"
if errorlevel 1 exit /b 1
exit /b 0
