@echo off
REM Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
REM One firstboot entry: offline MSI then SYSTEM startup task; one framework reboot.
setlocal
REM The service runner can be 32-bit. Use native tools and Storage cmdlets.
if not exist "%SystemRoot%\Sysnative\cmd.exe" goto V2K_NATIVE_PROCESS
"%SystemRoot%\Sysnative\cmd.exe" /c ""%~f0" %*"
exit /b
:V2K_NATIVE_PROCESS
set "V2KROOT=C:\ProgramData\ABLECLOUD\V2K\GuestConfig"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "%V2KROOT%\bootstrap.ps1" -PrepareOnly
if errorlevel 1 exit /b 1
if not exist "%V2KROOT%\payload\vioserial\vioser.inf" goto V2K_SERIAL_READY
pnputil.exe /add-driver "%V2KROOT%\payload\vioserial\vioser.inf" /install
set "V2KRC=%ERRORLEVEL%"
if not "%V2KRC%"=="0" if not "%V2KRC%"=="3010" exit /b 1
:V2K_SERIAL_READY
msiexec.exe /i "%V2KROOT%\payload\qemu-ga-x86_64.msi" /qn /norestart /l*v "%V2KROOT%\qga-install.log"
set "V2KRC=%ERRORLEVEL%"
if not "%V2KRC%"=="0" if not "%V2KRC%"=="3010" exit /b 1
sc.exe query QEMU-GA >nul 2>&1
if errorlevel 1 exit /b 1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "%V2KROOT%\bootstrap.ps1"
if errorlevel 1 exit /b 1
exit /b 0
