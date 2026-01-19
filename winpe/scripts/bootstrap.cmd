@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ================================================================
REM ABLESTACK V2K WinPE Bootstrap (Minimum Working Template)
REM - Auto driver injection (offline DISM)
REM - Required drivers:
REM   vioserial, vioscsi, viostor, netkvm, balloon
REM - OS support OSIDs:
REM   2k25, 2k22, 2k19, 2k16, 2k12, 2k12r2, w11, w10
REM - Output:
REM   <OS>:\ablestack\bootstrap\bootstrap.log
REM   <OS>:\ablestack\bootstrap\DONE.marker
REM   <OS>:\ablestack\bootstrap\FAILED.marker
REM - End: shutdown
REM ================================================================

call X:\ablestack\scripts\lib_find.cmd

set "NOW_UTC="
for /f "usebackq delims=" %%t in (`powershell -NoProfile -Command "(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')"` 2^>nul) do set "NOW_UTC=%%t"
if "%NOW_UTC%"=="" set "NOW_UTC=unknown-utc"

REM Wait policy for VirtIO ISO attach (host will attach after WinPE boot)
set "WAIT_TIMEOUT_SEC=300"
set "WAIT_INTERVAL_SEC=5"

REM Temp log on WinPE ramdisk until OS volume is discoverable.
REM (Migrated Windows disk may not be visible before drvload of VirtIO storage drivers.)
set "LOG_FILE=X:\ablestack-bootstrap.log"
set "DONE_FILE="
set "FAIL_FILE="

call :log_console "[bootstrap] %NOW_UTC% starting..."
call :log_file "============================================================"
call :log_file "[bootstrap] start: %NOW_UTC%"
call :log_file "[bootstrap] WAIT_TIMEOUT_SEC=%WAIT_TIMEOUT_SEC% WAIT_INTERVAL_SEC=%WAIT_INTERVAL_SEC%"

REM 1) Wait for VirtIO ISO root (host attaches after WinPE boot)
call :log_file "[bootstrap] Waiting for VirtIO ISO to be attached..."
call :wait_for_virtio
if "%VIRTIO_DRIVE%"=="" (
  call :log_file "[bootstrap] ERROR: VirtIO ISO not found after waiting."
  call :fail_and_shutdown "VirtIO ISO not found (timeout)"
)
call :log_file "[bootstrap] VIRTIO_DRIVE=%VIRTIO_DRIVE% VIRTIO_ROOT=%VIRTIO_ROOT%"

REM 2) drvload VirtIO storage drivers into WinPE so the migrated OS disk becomes visible
call :drvload_storage_drivers

REM 3) Discover OS volume (may require assigning drive letters)
call :find_os_drive_wrapper
if "%OS_DRIVE%"=="" (
  call :log_file "[bootstrap] OS drive not found yet. Trying to assign drive letters..."
  call :ensure_volume_letters
  call :find_os_drive_wrapper
)
if "%OS_DRIVE%"=="" (
  call :log_file "[bootstrap] ERROR: OS drive not found even after drvload/letter assignment."
  call :fail_and_shutdown "OS drive not found"
)

REM Promote logs/markers to OS volume
call :prepare_os_paths

REM 4) Detect offline Windows version (best-effort) and derive OSID hint
call :detect_offline_os_version
call :derive_osid_hint

REM 5) Select OSID (prefer hint, fallback to probing VirtIO ISO)
set "OSID="
if not "%OSID_HINT%"=="" (
  call :log_file "[bootstrap] OSID_HINT=%OSID_HINT%"
  call :probe_osid "%OSID_HINT%"
)
if "%OSID%"=="" (
  for %%O in (2k25 2k22 2k19 2k16 2k12r2 2k12 w11 w10) do (
    call :probe_osid "%%O"
    if not "!OSID!"=="" goto :osid_selected
  )
)

:osid_selected
if "%OSID%"=="" (
  call :log_file "[bootstrap] ERROR: Could not determine OSID under VirtIO ISO."
  call :fail_and_shutdown "OSID not found in VirtIO ISO"
)

call :log_file "[bootstrap] Selected OSID=%OSID%"

REM 6) Build driver paths (must exist)
set "DRV_VIOSCSI=%VIRTIO_ROOT%vioscsi\%OSID%\amd64"
set "DRV_VIOSTOR=%VIRTIO_ROOT%viostor\%OSID%\amd64"
set "DRV_VIOSERIAL=%VIRTIO_ROOT%vioserial\%OSID%\amd64"
set "DRV_NETKVM=%VIRTIO_ROOT%NetKVM\%OSID%\amd64"
set "DRV_BALLOON=%VIRTIO_ROOT%Balloon\%OSID%\amd64"

REM 7) Validate required paths and inject in order
set "ALL_OK=1"

call :inject_driver "vioscsi" "%DRV_VIOSCSI%"
if errorlevel 1 set "ALL_OK=0"

call :inject_driver "viostor" "%DRV_VIOSTOR%"
if errorlevel 1 set "ALL_OK=0"

call :inject_driver "vioserial" "%DRV_VIOSERIAL%"
if errorlevel 1 set "ALL_OK=0"

call :inject_driver "netkvm" "%DRV_NETKVM%"
if errorlevel 1 set "ALL_OK=0"

call :inject_driver "balloon" "%DRV_BALLOON%"
if errorlevel 1 set "ALL_OK=0"

if "%ALL_OK%"=="1" (
  call :log_file "[bootstrap] SUCCESS: all drivers injected."
  echo %NOW_UTC% OSID=%OSID% RESULT=SUCCESS > "%DONE_FILE%"
  if exist "%FAIL_FILE%" del /f /q "%FAIL_FILE%" >nul 2>&1
) else (
  call :log_file "[bootstrap] FAILURE: one or more driver injections failed."
  echo %NOW_UTC% OSID=%OSID% RESULT=FAILED > "%FAIL_FILE%"
  if exist "%DONE_FILE%" del /f /q "%DONE_FILE%" >nul 2>&1
)

call :log_file "[bootstrap] End: shutting down WinPE."
call :log_console "[bootstrap] Done. Shutting down."
wpeutil shutdown
exit /b 0

REM ------------------------
REM Wait for VirtIO ISO (attach happens on host side)
REM ------------------------
:wait_for_virtio
set "VIRTIO_DRIVE="
set "VIRTIO_ROOT="
set /a "ELAPSED=0"

:wait_loop
call :find_virtio_root_wrapper
if not "%VIRTIO_DRIVE%"=="" (
  call :log_file "[bootstrap] VirtIO ISO detected: %VIRTIO_DRIVE%"
  goto :eof
)

if %ELAPSED% GEQ %WAIT_TIMEOUT_SEC% (
  call :log_file "[bootstrap] VirtIO wait timeout reached (%WAIT_TIMEOUT_SEC%s)."
  goto :eof
)

call :log_file "[bootstrap] VirtIO not found yet. rescan and wait... elapsed=%ELAPSED%s"

REM Force rescan to pick up newly attached CDROM/volumes
(
  echo rescan
  echo exit
) | diskpart >> "%LOG_FILE%" 2>>&1

ping -n %WAIT_INTERVAL_SEC% >nul
set /a "ELAPSED+=WAIT_INTERVAL_SEC"
goto :wait_loop

REM ------------------------
REM Wrappers (because lib_find.cmd uses setlocal)
REM ------------------------
:find_os_drive_wrapper
set "OS_DRIVE="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if exist "%%D:\Windows\System32\Config\SYSTEM" (
    set "OS_DRIVE=%%D:"
    goto :eof
  )
)
goto :eof

:find_virtio_root_wrapper
set "VIRTIO_DRIVE="
set "VIRTIO_ROOT="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if exist "%%D:\vioscsi\"  goto :virtio_found_%%D
  if exist "%%D:\viostor\"  goto :virtio_found_%%D
  if exist "%%D:\vioserial\" goto :virtio_found_%%D
  if exist "%%D:\NetKVM\"   goto :virtio_found_%%D
  if exist "%%D:\Balloon\"  goto :virtio_found_%%D
)
goto :eof

:virtio_found_C
set "VIRTIO_DRIVE=C:" & set "VIRTIO_ROOT=C:\" & goto :eof
:virtio_found_D
set "VIRTIO_DRIVE=D:" & set "VIRTIO_ROOT=D:\" & goto :eof
:virtio_found_E
set "VIRTIO_DRIVE=E:" & set "VIRTIO_ROOT=E:\" & goto :eof
:virtio_found_F
set "VIRTIO_DRIVE=F:" & set "VIRTIO_ROOT=F:\" & goto :eof
:virtio_found_G
set "VIRTIO_DRIVE=G:" & set "VIRTIO_ROOT=G:\" & goto :eof
:virtio_found_H
set "VIRTIO_DRIVE=H:" & set "VIRTIO_ROOT=H:\" & goto :eof
:virtio_found_I
set "VIRTIO_DRIVE=I:" & set "VIRTIO_ROOT=I:\" & goto :eof
:virtio_found_J
set "VIRTIO_DRIVE=J:" & set "VIRTIO_ROOT=J:\" & goto :eof
:virtio_found_K
set "VIRTIO_DRIVE=K:" & set "VIRTIO_ROOT=K:\" & goto :eof
:virtio_found_L
set "VIRTIO_DRIVE=L:" & set "VIRTIO_ROOT=L:\" & goto :eof
:virtio_found_M
set "VIRTIO_DRIVE=M:" & set "VIRTIO_ROOT=M:\" & goto :eof
:virtio_found_N
set "VIRTIO_DRIVE=N:" & set "VIRTIO_ROOT=N:\" & goto :eof
:virtio_found_O
set "VIRTIO_DRIVE=O:" & set "VIRTIO_ROOT=O:\" & goto :eof
:virtio_found_P
set "VIRTIO_DRIVE=P:" & set "VIRTIO_ROOT=P:\" & goto :eof
:virtio_found_Q
set "VIRTIO_DRIVE=Q:" & set "VIRTIO_ROOT=Q:\" & goto :eof
:virtio_found_R
set "VIRTIO_DRIVE=R:" & set "VIRTIO_ROOT=R:\" & goto :eof
:virtio_found_S
set "VIRTIO_DRIVE=S:" & set "VIRTIO_ROOT=S:\" & goto :eof
:virtio_found_T
set "VIRTIO_DRIVE=T:" & set "VIRTIO_ROOT=T:\" & goto :eof
:virtio_found_U
set "VIRTIO_DRIVE=U:" & set "VIRTIO_ROOT=U:\" & goto :eof
:virtio_found_V
set "VIRTIO_DRIVE=V:" & set "VIRTIO_ROOT=V:\" & goto :eof
:virtio_found_W
set "VIRTIO_DRIVE=W:" & set "VIRTIO_ROOT=W:\" & goto :eof
:virtio_found_Y
set "VIRTIO_DRIVE=Y:" & set "VIRTIO_ROOT=Y:\" & goto :eof
:virtio_found_Z
set "VIRTIO_DRIVE=Z:" & set "VIRTIO_ROOT=Z:\" & goto :eof

REM ------------------------
REM Functions
REM ------------------------

REM ------------------------------------------------------------------
REM prepare_os_paths
REM - After OS_DRIVE is known, move log/markers to OS volume.
REM ------------------------------------------------------------------
:prepare_os_paths
set "BOOT_DIR=%OS_DRIVE%\ablestack\bootstrap"
set "NEW_LOG=%BOOT_DIR%\bootstrap.log"
set "DONE_FILE=%BOOT_DIR%\DONE.marker"
set "FAIL_FILE=%BOOT_DIR%\FAILED.marker"

if not exist "%OS_DRIVE%\ablestack" mkdir "%OS_DRIVE%\ablestack" >nul 2>&1
if not exist "%BOOT_DIR%" mkdir "%BOOT_DIR%" >nul 2>&1

REM Promote existing temp log (best-effort)
if exist "%LOG_FILE%" (
  type "%LOG_FILE%" >> "%NEW_LOG%" 2>nul
  del /f /q "%LOG_FILE%" >nul 2>&1
)
set "LOG_FILE=%NEW_LOG%"

call :log_file "[bootstrap] OS_DRIVE=%OS_DRIVE%"
call :log_file "[bootstrap] VIRTIO_DRIVE=%VIRTIO_DRIVE% VIRTIO_ROOT=%VIRTIO_ROOT%"
exit /b 0

REM ------------------------------------------------------------------
REM probe_osid <candidate>
REM - If required driver folders exist for candidate, set OSID.
REM ------------------------------------------------------------------
:probe_osid
set "CAND=%~1"
if "%CAND%"=="" exit /b 0

if exist "%VIRTIO_ROOT%vioscsi\%CAND%\amd64\" (
  set "OSID=%CAND%"
  exit /b 0
)
if exist "%VIRTIO_ROOT%viostor\%CAND%\amd64\" (
  set "OSID=%CAND%"
  exit /b 0
)
if exist "%VIRTIO_ROOT%vioserial\%CAND%\amd64\" (
  set "OSID=%CAND%"
  exit /b 0
)
if exist "%VIRTIO_ROOT%NetKVM\%CAND%\amd64\" (
  set "OSID=%CAND%"
  exit /b 0
)
if exist "%VIRTIO_ROOT%Balloon\%CAND%\amd64\" (
  set "OSID=%CAND%"
  exit /b 0
)
exit /b 0

REM ------------------------------------------------------------------
REM drvload_storage_drivers
REM - Load VirtIO storage drivers into WinPE so OS disk becomes visible.
REM - We try multiple OSIDs because we don't know the migrated OS yet.
REM ------------------------------------------------------------------
:drvload_storage_drivers
set "LOADED_ANY=0"
for %%O in (2k25 w11 2k22 w10 2k19 2k16 2k12r2 2k12) do (
  if exist "%VIRTIO_ROOT%vioscsi\%%O\amd64\" (
    call :drvload_from_dir "vioscsi" "%VIRTIO_ROOT%vioscsi\%%O\amd64" && set "LOADED_ANY=1"
  )
  if exist "%VIRTIO_ROOT%viostor\%%O\amd64\" (
    call :drvload_from_dir "viostor" "%VIRTIO_ROOT%viostor\%%O\amd64" && set "LOADED_ANY=1"
  )
)

REM Always rescan after drvload attempts
(
  echo rescan
  echo exit
) | diskpart >> "%LOG_FILE%" 2>>&1

if "%LOADED_ANY%"=="1" (
  call :log_file "[bootstrap] drvload storage drivers: attempted"
) else (
  call :log_file "[bootstrap] drvload storage drivers: no candidate dirs found (continuing)"
)
exit /b 0

:drvload_from_dir
set "TAG=%~1"
set "DIR=%~2"
set "OK=0"
if "%DIR%"=="" exit /b 1

for %%I in ("%DIR%\*.inf") do (
  call :log_file "[drvload] %TAG% drvload %%~fI"
  drvload "%%~fI" >> "%LOG_FILE%" 2>>&1
  if "%ERRORLEVEL%"=="0" set "OK=1"
)

if "%OK%"=="1" exit /b 0
exit /b 1

REM ------------------------------------------------------------------
REM ensure_volume_letters
REM - Assign drive letters to volumes that have none, using diskpart in
REM   non-interactive mode.
REM - This is best-effort: we assign letters sequentially from a safe pool.
REM ------------------------------------------------------------------
:ensure_volume_letters
set "FREE_LETTERS=R S T U V W Y Z"
set "DP_LIST=%TEMP%\dp_listvol.txt"
set "DP_ASSIGN=%TEMP%\dp_assign.txt"

del /f /q "%DP_LIST%" "%DP_ASSIGN%" >nul 2>&1

(
  echo list volume
  echo exit
) > "%DP_LIST%"

for /f "usebackq tokens=1,2,3" %%A in (`diskpart /s "%DP_LIST%" ^| find /I "Volume "`) do (
  set "VOLNUM=%%B"
  set "COL3=%%C"
  call :_is_letter "!COL3!" HASLTR
  if "!HASLTR!"=="0" (
    call :_next_letter LTR
    if not "!LTR!"=="" (
      >> "%DP_ASSIGN%" echo select volume !VOLNUM!
      >> "%DP_ASSIGN%" echo assign letter=!LTR!
    )
  )
)

if exist "%DP_ASSIGN%" (
  call :log_file "[bootstrap] diskpart assigning letters (best-effort)"
  diskpart /s "%DP_ASSIGN%" >> "%LOG_FILE%" 2>>&1
)

(
  echo rescan
  echo exit
) | diskpart >> "%LOG_FILE%" 2>>&1

exit /b 0

:_next_letter
set "%~1="
for /f "tokens=1,*" %%a in ("!FREE_LETTERS!") do (
  set "%~1=%%a"
  set "FREE_LETTERS=%%b"
)
exit /b 0

:_is_letter
set "VAL=%~1"
set "OUT=0"
for %%L in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  if /I "%%L"=="%VAL%" set "OUT=1"
)
set "%~2=%OUT%"
exit /b 0

REM ------------------------------------------------------------------
REM detect_offline_os_version
REM - Read ProductName/Build from offline SOFTWARE hive (best-effort).
REM ------------------------------------------------------------------
:detect_offline_os_version
set "OS_PRODUCT="
set "OS_BUILD="
set "OS_DISPLAYVER="

set "HIVE=%OS_DRIVE%\Windows\System32\config\SOFTWARE"
if not exist "%HIVE%" (
  call :log_file "[bootstrap] offline SOFTWARE hive not found: %HIVE%"
  exit /b 0
)

reg load HKLM\OFFSOFT "%HIVE%" >> "%LOG_FILE%" 2>>&1
if not "%ERRORLEVEL%"=="0" (
  call :log_file "[bootstrap] reg load OFFSOFT failed (continuing)"
  exit /b 0
)

for /f "tokens=1,2,*" %%a in ('reg query "HKLM\OFFSOFT\Microsoft\Windows NT\CurrentVersion" /v ProductName 2^>nul ^| find /I "ProductName"') do set "OS_PRODUCT=%%c"
for /f "tokens=1,2,*" %%a in ('reg query "HKLM\OFFSOFT\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild 2^>nul ^| find /I "CurrentBuild"') do set "OS_BUILD=%%c"
for /f "tokens=1,2,*" %%a in ('reg query "HKLM\OFFSOFT\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2^>nul ^| find /I "DisplayVersion"') do set "OS_DISPLAYVER=%%c"
if "%OS_DISPLAYVER%"=="" (
  for /f "tokens=1,2,*" %%a in ('reg query "HKLM\OFFSOFT\Microsoft\Windows NT\CurrentVersion" /v ReleaseId 2^>nul ^| find /I "ReleaseId"') do set "OS_DISPLAYVER=%%c"
)

call :log_file "[bootstrap] Offline OS ProductName=%OS_PRODUCT%"
call :log_file "[bootstrap] Offline OS Build=%OS_BUILD% DisplayVersion=%OS_DISPLAYVER%"

reg unload HKLM\OFFSOFT >> "%LOG_FILE%" 2>>&1
exit /b 0

REM ------------------------------------------------------------------
REM derive_osid_hint
REM - Map ProductName to VirtIO ISO directory OSID.
REM ------------------------------------------------------------------
:derive_osid_hint
set "OSID_HINT="
if "%OS_PRODUCT%"=="" exit /b 0

echo %OS_PRODUCT% | find /I "Server" >nul && (
  echo %OS_PRODUCT% | find /I "2025" >nul && set "OSID_HINT=2k25"
  echo %OS_PRODUCT% | find /I "2022" >nul && set "OSID_HINT=2k22"
  echo %OS_PRODUCT% | find /I "2019" >nul && set "OSID_HINT=2k19"
  echo %OS_PRODUCT% | find /I "2016" >nul && set "OSID_HINT=2k16"
  echo %OS_PRODUCT% | find /I "2012 R2" >nul && set "OSID_HINT=2k12r2"
  if "%OSID_HINT%"=="" (
    echo %OS_PRODUCT% | find /I "2012" >nul && set "OSID_HINT=2k12"
  )
) || (
  echo %OS_PRODUCT% | find /I "Windows 11" >nul && set "OSID_HINT=w11"
  if "%OSID_HINT%"=="" (
    echo %OS_PRODUCT% | find /I "Windows 10" >nul && set "OSID_HINT=w10"
  )
)

exit /b 0

:inject_driver
set "NAME=%~1"
set "PATH=%~2"

if "%PATH%"=="" (
  call :log_file "[dism] %NAME% path empty"
  exit /b 1
)

if not exist "%PATH%\" (
  call :log_file "[dism] %NAME% path not found: %PATH%"
  exit /b 1
)

call :log_file "[dism] Inject %NAME% from %PATH%"
call :log_file "[dism] dism /Image:%OS_DRIVE%\ /Add-Driver /Driver:%PATH% /Recurse"

dism /Image:%OS_DRIVE%\ /Add-Driver /Driver:"%PATH%" /Recurse >> "%LOG_FILE%" 2>>&1
set "RC=%ERRORLEVEL%"
call :log_file "[dism] %NAME% ExitCode=%RC%"
if not "%RC%"=="0" exit /b 1
exit /b 0

:log_console
echo %~1
exit /b 0

:log_file
echo %~1>> "%LOG_FILE%"
exit /b 0

:fail_and_shutdown
set "REASON=%~1"
if "%FAIL_FILE%"=="" set "FAIL_FILE=X:\ablestack-bootstrap.FAILED.marker"
echo %NOW_UTC% OSID=%OSID% RESULT=FAILED REASON=%REASON% > "%FAIL_FILE%"
call :log_file "[bootstrap] FAIL: %REASON%"
call :log_console "[bootstrap] FAIL: %REASON%"
call :log_file "[bootstrap] shutting down WinPE."
wpeutil shutdown
exit /b 1
